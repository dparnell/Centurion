/**
 * This module implements a MUX serial board channel.
 *
 * The CPU side is a small register file; the line side is a transmitter and a receiver
 * running off the 27MHz bit clock. See the Centurion wiki for the board itself:
 * https://github.com/Nakazoto/CenturionComputer/wiki
 *
 * cpu_clock and bit_clock are the same net in this design, which is what lets the CPU
 * side raise tx_request and the transmitter clear it with a plain flag. Separating them
 * would need a real handshake across the two domains.
 */
module MUX #(
    // The interrupt counters at the bottom are a bring-up instrument, not part
    // of the card. They cost about 3% of the device's LUT4s, which is the
    // difference between 81% and 84%, so they are excluded from the netlist
    // rather than merely left unread. "make DIAG_TRACE=1" puts them back.
    parameter DEBUG = 0,
    // The bit clock's frequency. Every baud rate divider derives from it, and
    // so does the divider's width: the slowest rate, 75 baud, needs the most
    // bits. Nothing about this board lives in here.
    parameter integer CLOCK_HZ = 27_000_000
) (
    input wire bit_clock, // 27Mhz clock
    input wire cpu_clock,
    input wire cpu_enable,      // one pulse per CPU clock, so a bus write happens once
    input wire reset,           // synchronous, and shared with the core
    input uart_rx,
    output uart_tx,    
    input wire selected,
    input wire [4:0] address, 
    input wire write_en, 
    // The cycle in which the core actually latches the bus. This design has no
    // read strobe of its own - the address register simply stays where the
    // microcode last left it - so without this a read of the data register is
    // taken to be happening on every enabled cycle that the address happens to
    // point here, and a byte arriving in that window is cleared before anyone
    // has seen it. That is characters going missing from the terminal.
    input wire read_strobe,
    input wire [7:0] data_in,
    // M13 bit 7 in the core: the CPU telling the board its interrupt has been taken
    input wire interrupt_ack,
    output reg [7:0] data_out,
    output wire int_reqn,
    output wire [3:0] irq_number,
    // For the board level status dump: is a byte waiting, and what was it
    output wire dbg_byte_ready,
    output wire [7:0] dbg_rx_byte,
    // The card's interrupt state, for the board level dump. The operating
    // system's console is interrupt driven and none of this is visible from
    // outside: a machine whose cause register keeps answering "channel 0,
    // receive" behaves exactly like one that really is being typed at.
    output wire [7:0] dbg_mux_state,
    output wire [7:0] dbg_last_cause,
    output wire [15:0] dbg_acks,
    output wire [15:0] dbg_rx_chars,
    output wire [15:0] dbg_cause_rx,
    output wire [15:0] dbg_cause_tx
);

// common stuff - default to 9600 7E1

// Wide enough for the slowest rate: at 27MHz that is 27_000_000/75 = 360000, which
// did not fit in the 16 bits this used to have.
localparam integer DIV_BITS = $clog2(CLOCK_HZ / 75 + 1);
reg [DIV_BITS-1:0] divider = CLOCK_HZ / 9600;
reg parity = 1;                 // 1 = even, 0 = odd
reg parity_enabled = 1;
reg [3:0] data_bits = 7;
reg stop_bits = 0;

reg [7:0] output_data;      // byte handed to the transmitter
reg interrupts_enabled = 0;
reg [3:0] interrupt_level = 0;

// Character length, clamped so a nonsense control register write cannot make the shift
// alignment below meaningless.
wire [3:0] char_bits = (data_bits > 8) ? 4'd8 : ((data_bits < 5) ? 4'd5 : data_bits);

// The CPU raises this by writing the data register; the transmitter clears it via
// tx_taken. Both live in the bit clock domain, which is the same net as cpu_clock.
reg tx_request = 0;
reg tx_taken = 0;
wire tx_idle;

// The board is a four channel card and this design wires only channel 0, but the
// interrupt machinery belongs to the card rather than to a channel: software
// finds out which channel wants attention, and whether it was a receive or a
// transmit, by reading the cause register at offset 15. tx_int is one bit per
// channel, so one bit here.
reg tx_int = 0;             // channel 0 has finished sending a character
reg mux_cause = 0;          // this card raised the request, and has not said why
reg overrun = 0;            // a byte arrived on top of one nobody had read
reg tx_complete = 0;        // one cycle as the transmitter returns to idle

// A read of the data register consumes the received byte. Which makes it
// dangerous, because this bus has no read strobe of its own: the address
// register simply stays where it was until something needs it again. So the
// cycles after the CPU *writes* the transmit register still have that register
// on the address bus with write_en gone, and the next read strobe then reads as
// the CPU taking a received byte - discarding whatever had arrived. Every
// character the machine printed could eat one it had been sent, which looks
// exactly like input being lost while the machine is busy, and is why typing at
// a terminal never showed it: a person cannot type inside one character time.
//
// So once the data register has been written, ignore reads of it until the
// address bus points somewhere else. A genuine read is always preceded by the
// instruction fetch that issued it, so it is never inhibited.
reg wrote_data = 0;
always @(posedge cpu_clock) begin
    if (reset) wrote_data <= 0;
    else if (cpu_enable && selected) begin
        if (write_en && address == 1) wrote_data <= 1;
        else if (address != 1) wrote_data <= 0;
    end else if (cpu_enable && !selected) wrote_data <= 0;
end

wire read_data_register = cpu_enable & selected & ~write_en & read_strobe
                          & (address == 1) & ~wrote_data;
// Reading the cause register and reading a channel register both have side
// effects, so they need the same protection from this bus having no read strobe
// of its own that the data register needs. wrote_data only tracks the data
// register, so track the last written address as well.
reg wrote_any = 0;
reg [4:0] wrote_addr = 0;
always @(posedge cpu_clock) begin
    if (reset) begin wrote_any <= 0; wrote_addr <= 0; end
    else if (cpu_enable && selected) begin
        if (write_en) begin wrote_any <= 1; wrote_addr <= address; end
        else if (address != wrote_addr) wrote_any <= 0;
    end else if (cpu_enable && !selected) wrote_any <= 0;
end
wire real_read = cpu_enable & selected & ~write_en & read_strobe
                 & ~(wrote_any & (address == wrote_addr));
wire read_cause_register = real_read & (address == 15);
// Writing 12 forces a transmit interrupt for the channels in the low bits, and
// writing 15 resets the card. Both are strobes rather than state, so that
// everything that touches tx_int can live in one always block.
wire write_strobe = cpu_enable & selected & write_en;
wire force_tx_int = write_strobe & (address == 5'd12) & data_in[0];
wire card_reset   = write_strobe & (address == 5'd15);
wire read_channel_register = real_read & (address < 8);

// CPU interface
always @(posedge cpu_clock) begin
    if (reset) begin
        // Back to the 9600 7E1 power on defaults. Without this the channel keeps its
        // configuration and its pending state across a reset of the core, and diag comes
        // back up talking to a MUX that is still mid-character or still holding a byte.
        divider <= CLOCK_HZ / 9600;
        parity <= 1;
        parity_enabled <= 1;
        data_bits <= 7;
        stop_bits <= 0;
        interrupts_enabled <= 0;
        interrupt_level <= 0;
        output_data <= 0;
        tx_request <= 0;
    end else begin
    if (tx_taken) begin
        tx_request <= 0;
    end
    if (cpu_enable && selected) begin
        if(write_en) begin
            case(address) 
                0: begin  // control register
                    parity <= data_in[0];
                    data_bits <= 5 + data_in[3:1];
                    parity_enabled <= data_in[4];
                    stop_bits <= data_in[5];

                    case (data_in[7:5])
                        0: divider <= CLOCK_HZ / 75;
                        1: divider <= CLOCK_HZ / 300;
                        2: divider <= CLOCK_HZ / 1200;
                        3: divider <= CLOCK_HZ / 2400;
                        4: divider <= CLOCK_HZ / 4800;
                        5: divider <= CLOCK_HZ / 9600;
                        6: divider <= CLOCK_HZ / 19200;
                        7: divider <= CLOCK_HZ / 38400;
                    endcase
                end

                1: begin // data register: load the byte and start sending it
                    output_data <= data_in;
                    tx_request <= 1;
                end

                10: begin // interrupt level
                    interrupt_level <= data_in[3:0];
                end

                // 8 is the RTS control and 11 is unknown; the operating
                // system writes both during its console setup. There are no
                // flow control pins on this board and the reference emulator
                // does not model 11 either, so both are deliberately ignored
                // rather than merely unimplemented.

                13: interrupts_enabled <= 0;
                14: interrupts_enabled <= 1;
                15: begin
                    divider <= CLOCK_HZ / 9600;
                    parity <= 1;
                    parity_enabled <= 1;
                    data_bits <= 7;
                    stop_bits <= 0;
                    interrupts_enabled <= 0;
                    interrupt_level <= 0;
                end
            endcase
        end
    end
    end
end

// rx

localparam RX_IDLE   = 0;
localparam RX_START  = 1;
localparam RX_DATA   = 2;
localparam RX_PARITY = 3;
localparam RX_STOP   = 4;

// uart_rx arrives from outside with no relation to this clock, so synchronise it
// before the state machine looks at it.
reg [2:0] uart_rx_sync = 3'b111;
always @(posedge bit_clock) uart_rx_sync <= { uart_rx_sync[1:0], uart_rx };
wire uart_rx_s = uart_rx_sync[2];

reg [2:0] rxState = RX_IDLE;
reg [DIV_BITS-1:0] rxCounter = 0;
reg [3:0] rxBitNumber = 0;
reg [7:0] rxShift = 0;
reg [7:0] dataIn = 0;
reg byteReady = 0;

always @(posedge bit_clock) begin
    if (reset) begin
        rxState <= RX_IDLE;
        rxCounter <= 0;
        rxBitNumber <= 0;
        rxShift <= 0;
        dataIn <= 0;
        byteReady <= 0;
        overrun <= 0;
    end else begin
    // Clearing comes first so that a byte arriving in the same cycle the CPU reads the
    // data register still leaves byteReady set, rather than being lost.
    if (read_data_register) begin
        byteReady <= 0;
        overrun <= 0;
    end

    case (rxState)
        RX_IDLE: begin
            rxCounter <= 0;
            if (uart_rx_s == 0) begin
                rxState <= RX_START;
            end
        end
        RX_START: begin
            // Wait half a bit and check the line is still low, so a glitch on an idle
            // line is not mistaken for a start bit.
            rxCounter <= rxCounter + 1;
            if (rxCounter == divider[DIV_BITS-1:1]) begin
                rxCounter <= 0;
                rxBitNumber <= 0;
                rxShift <= 0;
                rxState <= (uart_rx_s == 0) ? RX_DATA : RX_IDLE;
            end
        end
        RX_DATA: begin
            rxCounter <= rxCounter + 1;
            if (rxCounter == divider) begin
                rxCounter <= 0;
                rxShift <= { uart_rx_s, rxShift[7:1] };
                if (rxBitNumber + 1 == char_bits) begin
                    rxState <= parity_enabled ? RX_PARITY : RX_STOP;
                end else begin
                    rxBitNumber <= rxBitNumber + 1;
                end
            end
        end
        RX_PARITY: begin
            // The parity bit is consumed but not checked; there is no status bit to
            // report an error in.
            rxCounter <= rxCounter + 1;
            if (rxCounter == divider) begin
                rxCounter <= 0;
                rxState <= RX_STOP;
            end
        end
        RX_STOP: begin
            rxCounter <= rxCounter + 1;
            if (rxCounter == divider) begin
                rxCounter <= 0;
                rxState <= RX_IDLE;
                // Bits shift in from the top, so a character shorter than 8 bits has to
                // be shifted down to be right aligned.
                dataIn <= rxShift >> (8 - char_bits);
                byteReady <= 1;
                // A character landing on top of one nobody has read is an
                // overrun, and the card reports it in the channel status.
                if (byteReady && !read_data_register) overrun <= 1;
            end
        end
    endcase
    end
end

// tx

localparam TX_IDLE   = 0;
localparam TX_START  = 1;
localparam TX_DATA   = 2;
localparam TX_PARITY = 3;
localparam TX_STOP   = 4;
localparam TX_STOP2  = 5;

reg [2:0] txState = TX_IDLE;
reg [DIV_BITS-1:0] txCounter = 0;
reg txPinRegister = 1;
reg [3:0] txBitNumber = 0;
reg [7:0] txShift = 0;
reg txParity = 0;

assign uart_tx = txPinRegister;
assign tx_idle = (txState == TX_IDLE) && !tx_request;

always @(posedge bit_clock) begin
    if (reset) begin
        txState <= TX_IDLE;
        txCounter <= 0;
        txPinRegister <= 1;
        txBitNumber <= 0;
        txShift <= 0;
        txParity <= 0;
        tx_taken <= 0;
        tx_complete <= 0;
    end else begin
    tx_taken <= 0;
    // The card raises an interrupt when a character has finished going out on
    // the wire, not when the CPU hands it over. That is what paces an
    // interrupt driven output queue: one character sent, one interrupt, the
    // next character taken from the queue.
    tx_complete <= 0;

    case (txState)
        TX_IDLE: begin
            txPinRegister <= 1;
            txCounter <= 0;
            if (tx_request) begin
                txShift <= output_data;
                txParity <= 0;
                txBitNumber <= 0;
                tx_taken <= 1;
                txState <= TX_START;
            end
        end
        TX_START: begin
            txPinRegister <= 0;
            txCounter <= txCounter + 1;
            if (txCounter == divider) begin
                txCounter <= 0;
                txState <= TX_DATA;
            end
        end
        TX_DATA: begin
            txPinRegister <= txShift[0];
            txCounter <= txCounter + 1;
            if (txCounter == divider) begin
                txCounter <= 0;
                txShift <= { 1'b0, txShift[7:1] };
                txParity <= txParity ^ txShift[0];
                if (txBitNumber + 1 == char_bits) begin
                    txState <= parity_enabled ? TX_PARITY : TX_STOP;
                end else begin
                    txBitNumber <= txBitNumber + 1;
                end
            end
        end
        TX_PARITY: begin
            // parity is 1 for even, so the bit is the running XOR, inverted for odd
            txPinRegister <= parity ? txParity : ~txParity;
            txCounter <= txCounter + 1;
            if (txCounter == divider) begin
                txCounter <= 0;
                txState <= TX_STOP;
            end
        end
        TX_STOP: begin
            txPinRegister <= 1;
            txCounter <= txCounter + 1;
            if (txCounter == divider) begin
                txCounter <= 0;
                txState <= stop_bits ? TX_STOP2 : TX_IDLE;
                if (!stop_bits) tx_complete <= 1;
            end
        end
        TX_STOP2: begin
            txPinRegister <= 1;
            txCounter <= txCounter + 1;
            if (txCounter == divider) begin
                txCounter <= 0;
                txState <= TX_IDLE;
                tx_complete <= 1;
            end
        end
    endcase
    end
end

// The interrupt request is active low and is a level, not a pulse. A one clock pulse at
// 27MHz would be missed by a 5MHz CPU, which only samples every fifth or sixth clock.
//
// It used to be byteReady itself, which meant the request was still asserted when the
// handler returned unless the handler had read the data register, so the CPU took the
// same interrupt again immediately. Here one arriving character raises one request, and
// the request is dropped when the CPU reads the byte out of the data register or
// acknowledges the interrupt.
//
// Both the set and the acknowledge are edges. The acknowledge is a latch bit rather than
// a strobe, so if the microcode ever leaves it set, a level sensitive clear here would
// hold interrupts off for good.
reg int_pending = 0;
reg byte_ready_d = 0;
reg interrupt_ack_d = 0;

always @(posedge bit_clock) begin
    byte_ready_d <= byteReady;
    interrupt_ack_d <= interrupt_ack;

    if (reset) begin
        int_pending <= 0;
        byte_ready_d <= 0;
        interrupt_ack_d <= 0;
    end else begin
        // A received character, a transmitted one, and a forced interrupt all
        // raise the request; the CPU's acknowledge is what drops it. Reading a
        // channel register raises it again while a transmit interrupt is still
        // unreported, which is how the card makes sure a second completion is
        // not lost behind the first.
        if (card_reset) begin
            int_pending <= 0;
            mux_cause <= 0;
            tx_int <= 0;
        end else begin
            if (interrupt_ack && !interrupt_ack_d) int_pending <= 0;
            if (read_data_register) int_pending <= 0;

            if (tx_complete) tx_int <= 1;
            if (force_tx_int) tx_int <= 1;
            // The cause register reports a waiting character first and a
            // completed transmission second, and taking a transmit cause
            // clears it - so one completion is reported exactly once.
            if (read_cause_register && mux_cause && !byteReady && tx_int)
                tx_int <= 0;

            if (tx_complete || force_tx_int ||
                (byteReady && !byte_ready_d) ||
                (read_channel_register && tx_int)) begin
                int_pending <= 1;
                mux_cause <= 1;
            end else if (read_cause_register) begin
                mux_cause <= 0;
            end
        end
    end
end

// interrupts_enabled gates the request rather than the pending flag, exactly as
// the card does: software can turn interrupts off without losing what happened
// while they were off.
assign int_reqn = ~(int_pending & interrupts_enabled);
// Counters, not levels. The dump is edge triggered on a character arriving, so
// anything sampled at the moment a dump is asked for has byteReady set and the
// trigger byte in the data register - by construction. Only totals taken over
// the whole run say anything about what the machine does when nobody is looking.
generate if (DEBUG) begin : mux_debug
reg [7:0] last_cause = 0;
reg [15:0] data_reads = 0, rx_chars = 0, cause_rx = 0, cause_tx = 0;
always @(posedge cpu_clock) begin
    if (reset) begin
        last_cause <= 0; data_reads <= 0; rx_chars <= 0;
        cause_rx <= 0; cause_tx <= 0;
    end else begin
        if (read_cause_register) begin
            last_cause <= data_out;
            // Every cause read, not only the ones with a cause pending: a read
            // that answers 00 because nothing is pending is indistinguishable
            // to software from "channel 0 has a character", and counting only
            // the pending ones hid exactly that.
            if (data_out == 8'h00) cause_rx <= cause_rx + 1;
            if (data_out == 8'h01) cause_tx <= cause_tx + 1;
        end
        // Does the CPU ever acknowledge? int_pending is dropped by the
        // acknowledge and by a read of the data register, and by nothing else,
        // so if the microcode never raises M13 bit 7 the request stands for
        // ever and the handler is re-entered the instant it returns.
        if (interrupt_ack && !interrupt_ack_d) data_reads <= data_reads + 1;
        if (byteReady && !byte_ready_d) rx_chars <= rx_chars + 1;
    end
end
assign dbg_last_cause = last_cause;
assign dbg_acks = data_reads;
assign dbg_rx_chars = rx_chars;
assign dbg_cause_rx = cause_rx;
assign dbg_cause_tx = cause_tx;
end else begin : no_mux_debug
assign dbg_last_cause = 0;
assign dbg_acks = 0;
assign dbg_rx_chars = 0;
assign dbg_cause_rx = 0;
assign dbg_cause_tx = 0;
end endgenerate
// The levels are free: they are registers the card needs anyway.
assign dbg_mux_state = { byteReady, tx_int, mux_cause, int_pending,
                         interrupts_enabled, overrun, tx_idle, 1'b0 };
assign irq_number = interrupt_level;
assign dbg_byte_ready = byteReady;
assign dbg_rx_byte = dataIn;

// CPU read port. The CPU samples the data bus in the same cycle that it drives the
// address, so the read has to be combinational.
always @(*) begin
    data_out = 8'h00;
    if (selected && !write_en) begin
        case (address)
            // Channel status: bit 5 clear to send, bit 4 overrun, bit 1 the
            // transmitter is free, bit 0 a character is waiting. The line here
            // is a terminal that is always ready, so CTS is tied on.
            0: data_out = { 2'b00, 1'b1, overrun, 2'b00, tx_idle, byteReady };
            1: data_out = dataIn;                              // received byte
            // The interrupt cause: which channel, and whether it was a receive
            // or a transmit. Bit 0 set means a transmission completed; bits 2:1
            // are the channel, and only channel 0 is wired here. Zero when this
            // card did not raise the request, which is also what an unasked
            // question should answer.
            15: data_out = mux_cause ? (byteReady ? 8'h00
                                        : (tx_int ? 8'h01 : 8'h00))
                                     : 8'h00;
        endcase
    end
end

endmodule

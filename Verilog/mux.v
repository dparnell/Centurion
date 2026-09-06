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
module MUX(
    input wire bit_clock, // 27Mhz clock
    input wire cpu_clock,
    input wire cpu_enable,      // one pulse per CPU clock, so a bus write happens once
    input wire reset,           // synchronous, and shared with the core
    input uart_rx,
    output uart_tx,    
    input wire selected,
    input wire [4:0] address, 
    input wire write_en, 
    input wire [7:0] data_in,
    output reg [7:0] data_out,
    output wire int_reqn,
    output wire [3:0] irq_number,
    // For the board level status dump: is a byte waiting, and what was it
    output wire dbg_byte_ready,
    output wire [7:0] dbg_rx_byte
);

// common stuff - default to 9600 7E1

// 20 bits, because the slowest rate needs 27_000_000/75 = 360000 and that does not fit
// in the 16 bits this used to have.
reg [19:0] divider = 27_000_000 / 9600;
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

// A read of the data register consumes the received byte
wire read_data_register = cpu_enable & selected & ~write_en & (address == 1);

// CPU interface
always @(posedge cpu_clock) begin
    if (reset) begin
        // Back to the 9600 7E1 power on defaults. Without this the channel keeps its
        // configuration and its pending state across a reset of the core, and diag comes
        // back up talking to a MUX that is still mid-character or still holding a byte.
        divider <= 27_000_000 / 9600;
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
                        0: divider <= 27_000_000 / 75;
                        1: divider <= 27_000_000 / 300;
                        2: divider <= 27_000_000 / 1200;
                        3: divider <= 27_000_000 / 2400;
                        4: divider <= 27_000_000 / 4800;
                        5: divider <= 27_000_000 / 9600;
                        6: divider <= 27_000_000 / 19200;
                        7: divider <= 27_000_000 / 38400;
                    endcase
                end

                1: begin // data register: load the byte and start sending it
                    output_data <= data_in;
                    tx_request <= 1;
                end

                10: begin // interrupt level
                    interrupt_level <= data_in[3:0];
                end

                13: interrupts_enabled <= 0;
                14: interrupts_enabled <= 1;
                15: begin
                    divider <= 27_000_000 / 9600;
                    parity <= 1;
                    parity_enabled <= 1;
                    data_bits <= 7;
                    stop_bits <= 0;
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
reg [19:0] rxCounter = 0;
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
    end else begin
    // Clearing comes first so that a byte arriving in the same cycle the CPU reads the
    // data register still leaves byteReady set, rather than being lost.
    if (read_data_register) begin
        byteReady <= 0;
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
            if (rxCounter == divider[19:1]) begin
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
reg [19:0] txCounter = 0;
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
    end else begin
    tx_taken <= 0;

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
            end
        end
        TX_STOP2: begin
            txPinRegister <= 1;
            txCounter <= txCounter + 1;
            if (txCounter == divider) begin
                txCounter <= 0;
                txState <= TX_IDLE;
            end
        end
    endcase
    end
end

// The interrupt request is active low and is a level, not a pulse. A one clock pulse at
// 27MHz would be missed by a 5MHz CPU, which only samples every fifth or sixth clock.
// It clears when the CPU reads the byte out of the data register.
assign int_reqn = ~(interrupts_enabled & byteReady);
assign irq_number = interrupt_level;
assign dbg_byte_ready = byteReady;
assign dbg_rx_byte = dataIn;

// CPU read port. The CPU samples the data bus in the same cycle that it drives the
// address, so the read has to be combinational.
always @(*) begin
    data_out = 8'h00;
    if (selected && !write_en) begin
        case (address)
            0: data_out = { 6'b000000, tx_idle, byteReady };   // status register
            1: data_out = dataIn;                              // received byte
        endcase
    end
end

endmodule

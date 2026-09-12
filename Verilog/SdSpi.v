/*
 * A microSD card over SPI: initialisation, and single block reads and writes.
 *
 * The Tang Nano 9K brings out four of the card's pins - clk, cmd, dat0 and dat3
 * - so four bit SD mode is not available and this has to be SPI. That is no
 * loss: SPI at 13.5MHz is about 1.7MB/s, far more than a 5MHz CPU driving a
 * 1970s disk controller can consume.
 *
 * The SPI clock is an *enable* derived from the 27MHz pin, never a clock
 * generated in fabric. A divided clock on general routing cost this project a
 * hold time violation and then a board that did not run at all, and the rule
 * that came out of it applies here as much as anywhere.
 *
 * Initialisation is the standard sequence and every step of it exists for a
 * reason a card will enforce:
 *
 *   80 clocks with CS high      the card needs them before it will listen
 *   CMD0   with CS low          go idle, and that is what selects SPI mode
 *   CMD8   0x1aa                say we are 2.7-3.6V. A card that rejects this
 *                               is pre-SDHC; we do not support those.
 *   ACMD41 with HCS set         start initialisation, repeated until it clears
 *                               the idle bit, which can take hundreds of ms
 *   CMD58                       read the OCR, whose bit 30 says whether the
 *                               card addresses by block or by byte
 *
 * CRC is off in SPI mode but the card still checks it on CMD0 and CMD8, before
 * it has been told to stop, so those two carry their known constants.
 *
 * The byte addressing case matters and is easy to get wrong: a standard
 * capacity card takes a *byte* address, so the block number has to be shifted
 * left by nine. Everything above this module deals in blocks only.
 */
module SdSpi #(
    // The board clock. The two SPI rates and the timeout derive from it.
    parameter integer CLOCK_HZ = 27_000_000,
    // Board clocks per SPI half period during initialisation. The card must see
    // between 100 and 400kHz until it is out of idle, and the SPI clock is
    // CLOCK_HZ / (2 * SLOW_DIV): 770kHz in the divisor gives 35 at 27MHz, which
    // is the value this has always used, 386kHz - and 64 at 50MHz, 129 at
    // 100MHz, all just under 400kHz.
    parameter integer SLOW_DIV = CLOCK_HZ / 770_000,
    // And afterwards: CLOCK_HZ / (2 * FAST_DIV). 13.5MHz at 27MHz, 25MHz at
    // 50MHz - within every card's 25MHz limit up to a 50MHz board clock. A
    // faster board has to raise this.
    parameter integer FAST_DIV = 1,
    // How long to keep retrying ACMD41 before giving up: one second.
    parameter integer INIT_TIMEOUT = CLOCK_HZ
) (
    input wire clock,                   // 27MHz board clock
    input wire reset,

    output reg sd_clk,
    output reg sd_mosi,
    input wire sd_miso,
    output reg sd_cs_n,

    // Command interface. Raise read or write with block set and hold nothing;
    // busy goes high on the next clock and low when the transfer is over.
    input wire read,
    input wire write,
    input wire [31:0] block,
    output reg busy,
    output reg ready,                   // the card finished initialising
    output reg error,                   // the last command failed

    // Read data comes out a byte at a time as it arrives: rx_strobe pulses for
    // one clock with rx_index and rx_byte valid. Write data is asked for with
    // tx_request, and tx_index then stays put until the byte has been consumed,
    // so a caller can simply wire tx_byte to a memory read of tx_index.
    output reg rx_strobe,
    output reg [8:0] rx_index,
    output reg [7:0] rx_byte,
    output reg tx_request,
    output reg [8:0] tx_index,
    input wire [7:0] tx_byte,

    // For the bring-up dump: how far initialisation got, and the last response.
    output wire [7:0] dbg_state,
    output reg [7:0] dbg_r1,
    output reg dbg_block_addressing
);
    // ---------------------------------------------------------------- bit engine
    // One byte in and one byte out per transaction, SPI mode 0: the card samples
    // MOSI on the rising edge and we sample MISO on the same edge, so MOSI is set
    // up on the falling edge before it.
    // Kicked by the command engine below. Its start logic has to live in the
    // same always block as the engine itself: driving shift_out, bit_count,
    // byte_active, divider and sd_mosi from two blocks is two drivers on one
    // register, which simulation resolves happily and yosys reports as a
    // driver-driver conflict and then ties to a constant. That is the same trap
    // that once silently deleted this design's program RAM.
    reg start_byte;
    reg [7:0] start_data;

    reg [15:0] divider;
    reg [15:0] div_limit;
    reg [3:0] bit_count;
    reg [7:0] shift_out, shift_in;
    reg byte_active;
    reg byte_done;
    reg [7:0] byte_in;

    always @(posedge clock) begin
        byte_done <= 0;
        if (reset) begin
            divider <= 0; bit_count <= 0; byte_active <= 0;
            sd_clk <= 0; sd_mosi <= 1;
        end else if (byte_active) begin
            if (divider != 0) divider <= divider - 1;
            else begin
                divider <= div_limit;
                if (!sd_clk) begin
                    // About to rise: the data has been stable for a half period,
                    // so this is where both ends sample.
                    sd_clk <= 1;
                    shift_in <= { shift_in[6:0], sd_miso };
                end else begin
                    sd_clk <= 0;
                    if (bit_count == 1) begin
                        byte_active <= 0;
                        // shift_in already holds all eight bits: they were taken
                        // on the eight rising edges. Sampling sd_miso once more
                        // here shifts every byte left by one, which reads an R1
                        // of 0x01 as 0x03 and looks exactly like a card fault.
                        byte_in <= shift_in;
                        byte_done <= 1;
                        sd_mosi <= 1;
                    end else begin
                        bit_count <= bit_count - 1;
                        shift_out <= { shift_out[6:0], 1'b1 };
                        sd_mosi <= shift_out[6];
                    end
                end
            end
        end else if (start_byte) begin
            shift_out <= start_data;
            sd_mosi <= start_data[7];
            bit_count <= 8;
            divider <= div_limit;
            byte_active <= 1;
        end
    end


    // ------------------------------------------------------------ command engine
    localparam [7:0]
        S_RESET      = 0,  S_POWERUP   = 1,  S_CMD0      = 2,  S_CMD8      = 3,
        S_CMD8_TAIL  = 4,  S_CMD55     = 5,  S_ACMD41    = 6,  S_CMD58     = 7,
        S_CMD58_TAIL = 8,  S_IDLE      = 9,  S_CMD17     = 10, S_TOKEN     = 11,
        S_RX         = 12, S_RX_CRC    = 13, S_CMD24     = 14, S_TX_TOKEN  = 15,
        S_TX         = 16, S_TX_CRC    = 17, S_TX_RESP   = 18, S_BUSY      = 19,
        S_DONE       = 20, S_FAIL      = 21, S_SEND      = 22, S_R1        = 23;

    reg [7:0] state, return_state;
    assign dbg_state = state;

    // The command being sent, and where to come back to.
    reg [5:0] cmd_index;
    reg [31:0] cmd_arg;
    reg [7:0] cmd_crc;
    reg [3:0] send_step;
    reg [15:0] wait_count;
    reg [31:0] init_timer;
    reg [8:0] byte_index;
    reg [31:0] ocr;

    // A card that has not answered in this many byte times has gone away. The
    // specification allows a write to take 250ms, so this is generous.
    localparam integer RESPONSE_LIMIT = 65000;

    task send_byte(input [7:0] b);
        begin
            start_data <= b;
            start_byte <= 1;
        end
    endtask

    initial begin
        state = S_RESET; sd_cs_n = 1; sd_clk = 0; sd_mosi = 1;
        busy = 0; ready = 0; error = 0; rx_strobe = 0; tx_request = 0;
        div_limit = SLOW_DIV; dbg_r1 = 8'hff; dbg_block_addressing = 0;
        start_byte = 0; start_data = 8'hff;
    end

    always @(posedge clock) begin
        rx_strobe <= 0;
        tx_request <= 0;
        if (start_byte && byte_active) start_byte <= 0;

        if (reset) begin
            state <= S_RESET;
            sd_cs_n <= 1;
            busy <= 0; ready <= 0; error <= 0;
            div_limit <= SLOW_DIV;
            start_byte <= 0;
            init_timer <= 0;
            dbg_block_addressing <= 0;
        end else case (state)
        S_RESET: begin
            sd_cs_n <= 1;
            wait_count <= 10;              // ten bytes is eighty clocks
            init_timer <= INIT_TIMEOUT;
            busy <= 1;
            state <= S_POWERUP;
            send_byte(8'hff);
        end

        // Eighty clocks with CS high, which is what puts the card in a state
        // where it will accept CMD0 at all.
        S_POWERUP: if (byte_done) begin
            if (wait_count == 1) begin
                sd_cs_n <= 0;
                cmd_index <= 0; cmd_arg <= 0; cmd_crc <= 8'h95;
                return_state <= S_CMD0;
                state <= S_SEND; send_step <= 0;
            end else begin
                wait_count <= wait_count - 1;
                send_byte(8'hff);
            end
        end

        S_CMD0: if (dbg_r1 == 8'h01) begin
            cmd_index <= 8; cmd_arg <= 32'h000001aa; cmd_crc <= 8'h87;
            return_state <= S_CMD8;
            state <= S_SEND; send_step <= 0;
        end else state <= S_FAIL;

        // CMD8's R7 is R1 plus four more bytes; the last two echo the voltage
        // and the check pattern we sent.
        S_CMD8: if (dbg_r1 == 8'h01) begin
            wait_count <= 4;
            state <= S_CMD8_TAIL;
            send_byte(8'hff);
        end else state <= S_FAIL;    // a pre-SDHC card, which we do not support

        S_CMD8_TAIL: if (byte_done) begin
            ocr <= { ocr[23:0], byte_in };
            if (wait_count == 1) begin
                if (byte_in != 8'haa) state <= S_FAIL;
                else begin
                    cmd_index <= 55; cmd_arg <= 0; cmd_crc <= 8'h01;
                    return_state <= S_CMD55;
                    state <= S_SEND; send_step <= 0;
                end
            end else begin
                wait_count <= wait_count - 1;
                send_byte(8'hff);
            end
        end

        S_CMD55: if (dbg_r1[7:1] == 0) begin
            cmd_index <= 41; cmd_arg <= 32'h40000000; cmd_crc <= 8'h01;
            return_state <= S_ACMD41;
            state <= S_SEND; send_step <= 0;
        end else state <= S_FAIL;

        // ACMD41 answers 0x01 - still initialising - for as long as it likes.
        S_ACMD41:
            if (dbg_r1 == 8'h00) begin
                cmd_index <= 58; cmd_arg <= 0; cmd_crc <= 8'h01;
                return_state <= S_CMD58;
                state <= S_SEND; send_step <= 0;
            end else if (dbg_r1 == 8'h01 && init_timer != 0) begin
                cmd_index <= 55; cmd_arg <= 0; cmd_crc <= 8'h01;
                return_state <= S_CMD55;
                state <= S_SEND; send_step <= 0;
            end else state <= S_FAIL;

        S_CMD58: if (dbg_r1 == 8'h00) begin
            wait_count <= 4;
            state <= S_CMD58_TAIL;
            send_byte(8'hff);
        end else state <= S_FAIL;

        S_CMD58_TAIL: if (byte_done) begin
            ocr <= { ocr[23:0], byte_in };
            if (wait_count == 1) begin
                // OCR bit 30, CCS: set means the card takes block addresses,
                // clear means byte addresses and the block number needs shifting.
                dbg_block_addressing <= ocr[22];   // bit 30 of the assembled word
                sd_cs_n <= 1;
                div_limit <= FAST_DIV;
                ready <= 1;
                busy <= 0;
                state <= S_IDLE;
            end else begin
                wait_count <= wait_count - 1;
                send_byte(8'hff);
            end
        end

        S_IDLE: begin
            busy <= 0;
            if (read || write) begin
                busy <= 1;
                error <= 0;
                sd_cs_n <= 0;
                cmd_arg <= dbg_block_addressing ? block : (block << 9);
                cmd_index <= read ? 17 : 24;
                cmd_crc <= 8'h01;
                return_state <= read ? S_CMD17 : S_CMD24;
                state <= S_SEND; send_step <= 0;
            end
        end

        S_CMD17: if (dbg_r1 == 8'h00) begin
            wait_count <= RESPONSE_LIMIT;
            state <= S_TOKEN;
            send_byte(8'hff);
        end else state <= S_FAIL;

        // The card sends 0xff until its data is ready, then 0xfe. Anything else
        // with the top three bits clear is an error token.
        S_TOKEN: if (byte_done) begin
            if (byte_in == 8'hfe) begin
                byte_index <= 0;
                state <= S_RX;
                send_byte(8'hff);
            end else if (byte_in[7:4] == 0 || wait_count == 1) state <= S_FAIL;
            else begin
                wait_count <= wait_count - 1;
                send_byte(8'hff);
            end
        end

        S_RX: if (byte_done) begin
            rx_byte <= byte_in;
            rx_index <= byte_index;
            rx_strobe <= 1;
            byte_index <= byte_index + 1;
            if (byte_index == 511) begin
                wait_count <= 2;
                state <= S_RX_CRC;
            end
            send_byte(8'hff);
        end

        S_RX_CRC: if (byte_done) begin
            if (wait_count == 1) state <= S_DONE;
            else begin
                wait_count <= wait_count - 1;
                send_byte(8'hff);
            end
        end

        S_CMD24: if (dbg_r1 == 8'h00) begin
            state <= S_TX_TOKEN;
            send_byte(8'hff);          // one byte gap before the data token
        end else state <= S_FAIL;

        S_TX_TOKEN: if (byte_done) begin
            byte_index <= 0;
            tx_index <= 0;
            tx_request <= 1;           // ask for byte 0 while the token goes out
            state <= S_TX;
            send_byte(8'hfe);
        end

        S_TX: if (byte_done) begin
            send_byte(tx_byte);
            if (byte_index == 511) begin
                wait_count <= 2;
                state <= S_TX_CRC;
            end else begin
                byte_index <= byte_index + 1;
                tx_index <= byte_index + 1;
                tx_request <= 1;
            end
        end

        S_TX_CRC: if (byte_done) begin
            if (wait_count == 1) begin
                wait_count <= RESPONSE_LIMIT;
                state <= S_TX_RESP;
            end else wait_count <= wait_count - 1;
            send_byte(8'hff);
        end

        // The data response's low five bits are 00101 for accepted.
        S_TX_RESP: if (byte_done) begin
            if (byte_in[4:0] == 5'b00101) begin
                wait_count <= RESPONSE_LIMIT;
                state <= S_BUSY;
                send_byte(8'hff);
            end else if (byte_in != 8'hff || wait_count == 1) state <= S_FAIL;
            else begin
                wait_count <= wait_count - 1;
                send_byte(8'hff);
            end
        end

        // The card holds MISO low while it writes.
        S_BUSY: if (byte_done) begin
            if (byte_in == 8'hff) state <= S_DONE;
            else if (wait_count == 1) state <= S_FAIL;
            else begin
                wait_count <= wait_count - 1;
                send_byte(8'hff);
            end
        end

        S_DONE: begin
            sd_cs_n <= 1;
            busy <= 0;
            state <= S_IDLE;
        end

        S_FAIL: begin
            sd_cs_n <= 1;
            busy <= 0;
            error <= 1;
            state <= ready ? S_IDLE : S_FAIL;
        end

        // ---------------------------------------------------------- send a command
        // Six bytes, then read R1: the card answers with 0xff until it is ready
        // and then a byte with the top bit clear.
        S_SEND: if (byte_done || send_step == 0) begin
            case (send_step)
                0: begin send_byte({ 2'b01, cmd_index }); send_step <= 1; end
                1: begin send_byte(cmd_arg[31:24]);       send_step <= 2; end
                2: begin send_byte(cmd_arg[23:16]);       send_step <= 3; end
                3: begin send_byte(cmd_arg[15:8]);        send_step <= 4; end
                4: begin send_byte(cmd_arg[7:0]);         send_step <= 5; end
                5: begin send_byte(cmd_crc);              send_step <= 6; end
                default: begin
                    wait_count <= RESPONSE_LIMIT;
                    state <= S_R1;
                    send_byte(8'hff);
                end
            endcase
        end

        S_R1: if (byte_done) begin
            if (!byte_in[7]) begin
                dbg_r1 <= byte_in;
                state <= return_state;
            end else if (wait_count == 1) state <= S_FAIL;
            else begin
                wait_count <= wait_count - 1;
                send_byte(8'hff);
            end
        end

        default: state <= S_FAIL;
        endcase

        // The ACMD41 retry loop needs a wall clock bound of its own, because a
        // card that answers 0x01 promptly for ever would otherwise never time out.
        if (!reset && !ready && init_timer != 0) init_timer <= init_timer - 1;
    end
endmodule

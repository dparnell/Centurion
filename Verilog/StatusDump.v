
/**
 * Prints CPU state over the serial line while a button is held.
 *
 * diag's mapping RAM test does not stall the machine, it sends it into the weeds: the
 * program counter ends up at 0x0016 to 0x0030, the CPU's own register space, while the
 * same code in simulation runs at 0x8exx. So the interesting moment is when the machine
 * leaves its code, not where it ends up.
 *
 * This prints a marker character and five 16 bit values as hex:
 *
 *     F 0017 8f22 8f1e 8f1a 0003
 *
 * The top level decides what they mean. It uses 19200 7N1, which is what diag
 * configures, so a terminal already talking to diag needs no changes, and it drives the
 * UART pin directly, which is safe because the machine is only worth interrogating once
 * it has stopped printing.
 */
module StatusDump #(
    parameter DIVIDER = 27_000_000 / 19200
) (
    input wire clock,
    input wire trigger,                     // held, not an edge
    input wire [7:0] marker,
    input wire [79:0] payload,
    output reg tx,
    output wire active
);
    reg running;
    reg [4:0] char_index;
    reg [79:0] latch;
    reg [7:0] marker_latch;
    reg [19:0] counter;
    reg [3:0] bit_index;
    reg [8:0] shifter;                      // stop bit, 7 data bits, start bit

    assign active = running;

    function [7:0] hex(input [3:0] n);
        hex = (n < 10) ? (8'h30 + n) : (8'h61 + n - 8'd10);
    endfunction

    // marker, then five groups of "<space>xxxx", then CR LF: 28 characters
    reg [7:0] ch;
    reg [4:0] nibble_index;
    always @(*) begin
        nibble_index = 5'd0;
        case (char_index)
            5'd0:  ch = marker_latch;
            5'd1, 5'd6, 5'd11, 5'd16, 5'd21: ch = " ";
            5'd26: ch = 8'h0d;
            5'd27: ch = 8'h0a;
            default: begin
                // 2..5, 7..10, 12..15, 17..20, 22..25 are the hex digits, four per
                // group with a space between groups
                nibble_index = (char_index - 5'd2) - ((char_index - 5'd2) / 5'd5);
                ch = hex(latch[(79 - (nibble_index * 4)) -: 4]);
            end
        endcase
    end

    initial begin
        tx = 1;
        running = 0;
        char_index = 0;
        latch = 0;
        marker_latch = "L";
        counter = 0;
        bit_index = 0;
        shifter = 9'h1ff;
    end

    always @(posedge clock) begin
        if (!running) begin
            tx <= 1;
            counter <= 0;
            bit_index <= 0;
            char_index <= 0;
            shifter <= 9'h1ff;
            if (trigger) begin
                latch <= payload;
                marker_latch <= marker;
                running <= 1;
            end
        end else if (counter == DIVIDER) begin
            counter <= 0;
            tx <= shifter[0];
            if (bit_index == 0) begin
                shifter <= { 1'b1, ch[6:0], 1'b0 };
                bit_index <= 9;
            end else begin
                shifter <= { 1'b1, shifter[8:1] };
                bit_index <= bit_index - 1;
                if (bit_index == 1) begin
                    if (char_index == 27) begin
                        char_index <= 0;
                        running <= trigger;         // another line while held
                        latch <= payload;           // sampled afresh each line
                        marker_latch <= marker;
                    end else begin
                        char_index <= char_index + 1;
                    end
                end
            end
        end else begin
            counter <= counter + 1;
        end
    end
endmodule

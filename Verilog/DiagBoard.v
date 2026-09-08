/**
 * The Centurion Diag board.
 *
 * A small board carrying a two digit hexadecimal display with four decimal
 * points, and a bank of DIP switches. The CPU writes a progress code to the
 * display as it boots, and reads the switches to decide what to run. It lives
 * at physical 0x3f100 and answers seventeen addresses:
 *
 *   0x3f106  unblank the display        0x3f10a  set decimal point 2
 *   0x3f107  blank the display          0x3f10b  clear decimal point 2
 *   0x3f108  set decimal point 1        0x3f10c  set decimal point 3
 *   0x3f109  clear decimal point 1      0x3f10d  clear decimal point 3
 *                                       0x3f10e  set decimal point 4
 *                                       0x3f10f  clear decimal point 4
 *   0x3f110  write: the display value; read: the DIP switches
 *
 * Everything but 0x3f110 is a "touch" register: the side effect happens on a
 * read as much as on a write, and the data is ignored. That is how Meisaka's
 * emulator models it, and it is why diag can clear the decimal points with a
 * store of anything at all.
 *
 * The switches matter more than the display. diag masks the value it reads to
 * four bits and uses it to index a jump table at 0x8055, after special casing
 * 0x0d to the auxiliary test menu, so the switches choose what the machine
 * does out of reset:
 *
 *   0x11, 0x13  DMA tests            0x1a  TOS, the machine code monitor
 *   0x16        MUX interrupt test   0x1d  the auxiliary test menu
 *   0x17..0x19  Hawk disk tests
 *
 * Bit 7 must be clear: diag reads the raw value at 0x8045 and restarts if it
 * is negative.
 *
 * The side effects are idempotent, so they do not need to be edge detected -
 * a bus cycle spanning more than one enabled clock simply sets the same bit
 * twice.
 */
module DiagBoard(input wire clock, input wire enable, input wire selected,
    input wire [4:0] address, input wire write_en, input wire [7:0] data_in,
    input wire [7:0] dip_switches, output reg [7:0] data_out,
    output reg [7:0] hex_display, output reg [3:0] points, output reg blank);

    initial begin
        hex_display = 0;
        points = 0;
        blank = 0;
    end

    always @(posedge clock) begin
        if (enable && selected) begin
            case (address)
                5'h06: blank <= 0;
                5'h07: blank <= 1;
                5'h08: points[0] <= 1;
                5'h09: points[0] <= 0;
                5'h0a: points[1] <= 1;
                5'h0b: points[1] <= 0;
                5'h0c: points[2] <= 1;
                5'h0d: points[2] <= 0;
                5'h0e: points[3] <= 1;
                5'h0f: points[3] <= 0;
                5'h10: if (write_en) hex_display <= data_in;
                default: ;
            endcase
        end
    end

    // The CPU samples the data bus in the same cycle it drives the address, so
    // the read has to be combinational, as in mux.v.
    always @(*) begin
        data_out = 8'h00;
        if (selected && !write_en && address == 5'h10)
            data_out = dip_switches;
    end
endmodule


/**
 * Prints the CPU's position over the serial line while a button is held.
 *
 * diag's mapping RAM test locks the machine in a loop rather than halting it, so the
 * watchdog stays quiet and there is nothing to see. This transmits a line of the form
 *
 *     MA=1234 UC=567
 *
 * giving the memory address, which during a fetch is effectively the program counter,
 * and the microcode ROM address. It repeats for as long as the button is held, taking a
 * fresh sample each time, so the addresses a loop covers can be read straight off the
 * terminal and compared against a simulation of the same code.
 *
 * The line settings match what diag configures, 19200 7N1, so the terminal does not
 * need touching. It drives the UART pin directly, which is safe because a locked up
 * machine is not printing anything.
 */
module StatusDump #(
    parameter DIVIDER = 27_000_000 / 19200
) (
    input wire clock,
    input wire trigger,                     // held, not edge
    input wire [15:0] memory_address,
    input wire [10:0] uc_address,
    output reg tx,
    output wire active
);
    reg running;
    reg [3:0] char_index;
    reg [15:0] ma_latch;
    reg [10:0] uc_latch;
    reg [19:0] counter;
    reg [3:0] bit_index;
    reg [8:0] shifter;                      // stop, 7 data bits, start

    assign active = running;

    function [7:0] hex(input [3:0] n);
        hex = (n < 10) ? (8'h30 + n) : (8'h61 + n - 8'd10);
    endfunction

    reg [7:0] ch;
    always @(*) begin
        case (char_index)
            0:  ch = "M";
            1:  ch = "A";
            2:  ch = "=";
            3:  ch = hex(ma_latch[15:12]);
            4:  ch = hex(ma_latch[11:8]);
            5:  ch = hex(ma_latch[7:4]);
            6:  ch = hex(ma_latch[3:0]);
            7:  ch = " ";
            8:  ch = "U";
            9:  ch = "C";
            10: ch = "=";
            11: ch = hex({1'b0, uc_latch[10:8]});
            12: ch = hex(uc_latch[7:4]);
            13: ch = hex(uc_latch[3:0]);
            14: ch = 8'h0d;
            default: ch = 8'h0a;
        endcase
    end

    initial begin
        tx = 1;
        running = 0;
        char_index = 0;
        ma_latch = 0;
        uc_latch = 0;
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
                ma_latch <= memory_address;
                uc_latch <= uc_address;
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
                    if (char_index == 15) begin
                        char_index <= 0;
                        running <= trigger;         // another line while still held
                        ma_latch <= memory_address; // fresh sample each line
                        uc_latch <= uc_address;
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

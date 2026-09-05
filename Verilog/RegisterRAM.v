
/**
 * This module implements the register file (D13/D14).
 *
 * The array is read asynchronously so that it becomes LUTRAM rather than a block RAM,
 * and the value is then held in an ordinary flip flop gated by the CPU clock enable.
 *
 * The obvious alternative, a synchronous read, makes this a block RAM whose output IS
 * the held value, and a block RAM output is not a register the design can hold: with
 * the clock enable on it the value is never refreshed while the CPU is stalled between
 * enabled cycles. That is the same fault the microcode ROM had. LUTRAM has no output
 * register, so there is nothing to decay, and the flip flop below holds the value for
 * the whole CPU cycle exactly as before.
 *
 * Note this is not the same as simply free running the read: a write lands in the array
 * on an enabled edge, and a free running read would then expose the new value part way
 * through the same CPU cycle.
 */
module RegisterRAM(input wire clock, input wire enable, input wire write_en, input wire [7:0] address, input wire [7:0] data_in,
    output reg [7:0] data_out);

    // Force LUTRAM. Without this yosys merges the read register back into a block RAM
    // and gates it with the clock enable, which is exactly the failure this avoids.
    (* ram_style = "distributed" *)
    reg [7:0] memory[0:255];

    integer i;
    initial begin
        for (i=0; i<256; i=i+1) memory[i] = 8'h00;
    end

    wire [7:0] register0 = memory[0];
    wire [7:0] register1 = memory[1];

    // Asynchronous read, so the array maps to LUTRAM
    wire [7:0] read_data = memory[address];

    always @(posedge clock) begin
        if (enable) begin
            data_out <= read_data;
            if (write_en == 1) begin
                memory[address] <= data_in;
            end
        end
    end
endmodule

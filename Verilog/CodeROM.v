
/**
 * This module implements the CPU6 microcode ROM.
 * Microcode is loaded from a text file, which is synthesizable.
 *
 * The read is registered and deliberately has NO clock enable. This ROM becomes a
 * block RAM, and a block RAM's output is not a register the design can hold. When the
 * read was async, yosys absorbed CPU6's pipeline register into the block RAM and gated
 * it with the CPU clock enable, so between enabled cycles the microcode control word
 * was never refreshed and the sequencer ran on whatever the output decayed to. On the
 * board that showed up as the microcode wandering to a different place every run.
 *
 * So read every clock and let CPU6 hold the control word in real flip flops. That costs
 * one cycle of latency through the ROM, which is why the CPU clock enable must leave at
 * least two clocks between enabled cycles.
 */
module CodeROM(input wire clock, input wire [10:0] address, output reg [55:0] data);
    reg [55:0] memory[0:2047];
    initial begin
        $readmemh("roms/CodeROM.txt", memory);
    end

    always @(posedge clock) begin
        data <= memory[address];
    end
endmodule

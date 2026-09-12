/**
 * The memory's parity bit.
 *
 * The real machine stores a parity bit beside every byte of RAM and the CPU
 * checks it on every read. F11 bit 5 makes a write store the WRONG parity on
 * purpose, which is the only way to test that the checking works at all, and
 * the operating system does exactly that during startup: it poisons physical
 * 0x144 upward two bytes at a time, reads each back expecting a fault, and
 * prints PARITY CIRCUITRY INOPERATIVE and gives up if none arrives.
 *
 * So the three things worth checking are that a normal write reads back clean,
 * that a forced write reads back faulted, and that rewriting it normally clears
 * the fault - and that in all three cases the byte itself is unchanged, because
 * a parity bit that corrupted the data would be far worse than no parity at all.
 */
`timescale 1 ns/10 ps
`include "BoardMemory.v"

module ParityTB;
    reg clock = 0;
    always #18.5185 clock = ~clock;

    reg enable = 0, write_en = 0, parity_force = 0;
    reg [18:0] address = 0;
    reg [7:0] data_in = 0;
    wire [7:0] data_out;
    wire parity_bad;

    BoardMemory #(.DIAG_ROM(0)) mem(clock, enable, address, write_en, data_in,
                                    data_out, parity_force, parity_bad);

    integer failures = 0;
    task check(input [80*8:1] what, input expected_bad, input [7:0] expected_data);
        begin
            if (parity_bad !== expected_bad) begin
                $display("FAIL: %0s - parity_bad is %b, expected %b",
                         what, parity_bad, expected_bad);
                failures = failures + 1;
            end else if (data_out !== expected_data) begin
                $display("FAIL: %0s - read %02x, expected %02x",
                         what, data_out, expected_data);
                failures = failures + 1;
            end else
                $display("ok: %0s", what);
        end
    endtask

    // One enabled cycle, the way the board gives the memory one.
    task poke(input [18:0] a, input [7:0] d, input force_bad);
        begin
            address = a; data_in = d; parity_force = force_bad;
            write_en = 1; enable = 1; @(posedge clock); #1;
            write_en = 0; enable = 0; @(posedge clock); #1;
        end
    endtask
    task peek(input [18:0] a);
        begin
            address = a; @(posedge clock); #1; @(posedge clock); #1;
        end
    endtask

    // Two addresses: 0x144 is one the operating system actually poisons, in the
    // low RAM, and 0x0b100 is in the other writable region, so both are covered.
    initial begin
        #200;
        poke(19'h00144, 8'h5a, 0); peek(19'h00144);
        check("a byte written normally reads back with good parity", 0, 8'h5a);

        poke(19'h00144, 8'h5a, 1); peek(19'h00144);
        check("the same byte written with forced bad parity faults", 1, 8'h5a);

        poke(19'h00144, 8'h5a, 0); peek(19'h00144);
        check("rewriting it normally clears the fault", 0, 8'h5a);

        // An odd-parity byte as well, so a fault cannot be an artifact of the
        // data happening to have even parity.
        poke(19'h00146, 8'h07, 1); peek(19'h00146);
        check("an odd parity byte faults when forced too", 1, 8'h07);

        poke(19'h0b100, 8'hff, 1); peek(19'h0b100);
        check("the working RAM carries a parity bit as well", 1, 8'hff);

        peek(19'h00148);
        check("a location nothing has written is clean", 0, 8'h00);

        // Poisoning one location must not poison its neighbour.
        poke(19'h0014a, 8'h01, 1);
        poke(19'h0014c, 8'h01, 0);
        peek(19'h0014a);
        check("the poisoned byte is still poisoned", 1, 8'h01);
        peek(19'h0014c);
        check("the byte next to it is not", 0, 8'h01);

        if (failures == 0)
            $display("ok: memory parity works, and the force bit is what sets it");
        else
            $display("FAIL: %0d parity checks failed", failures);
        $finish;
    end
endmodule

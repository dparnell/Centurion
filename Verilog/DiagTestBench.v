`timescale 1 ns/10 ps
// Stubs for the Gowin hard blocks so the real top level can be simulated. The PSRAM
// controller is not driven by anything, so its DDR buffers only need to elaborate.
module rPLL #(parameter FCLKIN="100", parameter DYN_IDIV_SEL="false", parameter IDIV_SEL=0,
  parameter DYN_FBDIV_SEL="false", parameter FBDIV_SEL=0, parameter DYN_ODIV_SEL="false",
  parameter ODIV_SEL=8, parameter PSDA_SEL="0000", parameter DYN_DA_EN="false",
  parameter DUTYDA_SEL="1000", parameter CLKOUT_FT_DIR=1'b1, parameter CLKOUTP_FT_DIR=1'b1,
  parameter CLKOUT_DLY_STEP=0, parameter CLKOUTP_DLY_STEP=0, parameter CLKFB_SEL="internal",
  parameter CLKOUT_BYPASS="false", parameter CLKOUTP_BYPASS="false",
  parameter CLKOUTD_BYPASS="false", parameter DYN_SDIV_SEL=2, parameter CLKOUTD_SRC="CLKOUT",
  parameter CLKOUTD3_SRC="CLKOUT", parameter DEVICE="GW1NR-9C")
 (output CLKOUT, output LOCK, output CLKOUTP, output CLKOUTD, output CLKOUTD3,
  input RESET, input RESET_P, input CLKIN, input CLKFB,
  input [5:0] FBDSEL, input [5:0] IDSEL, input [5:0] ODSEL,
  input [3:0] PSDA, input [3:0] DUTYDA, input [3:0] FDLY);
    assign CLKOUT = CLKIN; assign CLKOUTP = CLKIN;
    assign CLKOUTD = CLKIN; assign CLKOUTD3 = CLKIN; assign LOCK = 1'b1;
endmodule
module ODDR(input CLK, input D0, input D1, input TX, output Q0, output Q1);
    assign Q0 = D0; assign Q1 = TX;
endmodule
module IDDR(input CLK, input D, output Q0, output Q1);
    assign Q0 = D; assign Q1 = D;
endmodule
module BUFG(input I, output O); assign O = I; endmodule

`include "tangnano9k.v"

/**
 * Boots diag on the real top level, waits for its prompt, types a test number over the
 * genuine serial link and prints what comes back.
 *
 * This is how the CPU-6 mapping RAM test was reproduced and then shown to pass. It is
 * not part of "make test" because it simulates hundreds of milliseconds of a 27MHz
 * board and takes minutes. Run it with "make diagtest", and change TEST to pick a
 * different entry from the menu.
 */
module DiagTestTB;
    parameter [7:0] TEST = "2";
    reg in_clk = 0;
    always #18.5185 in_clk = ~in_clk;
    reg reset_btn = 1, btn2 = 1;
    wire L1,L2,L3,L4,L5,L6,L7,L8;
    wire uart_tx;
    reg  uart_rx = 1;

    tangnano9k dut(in_clk, reset_btn, btn2, L1,L2,L3,L4,L5,L6,L7,L8, uart_tx, uart_rx);

    // diag reconfigures the channel to 19200 7N1
    localparam BITP = 27_000_000/19200 + 1;

    integer i;
    reg [7:0] ch;
    integer n = 0;
    reg prompt_seen = 0;
    initial begin
        forever begin
            @(negedge uart_tx);
            repeat (BITP + BITP/2) @(posedge in_clk);
            ch = 0;
            for (i = 0; i < 7; i = i + 1) begin
                ch[i] = uart_tx;
                repeat (BITP) @(posedge in_clk);
            end
            n = n + 1;
            if (ch == ":") prompt_seen = 1;
            $write("%s", ch);
        end
    end

    task send(input [7:0] c);
    integer k;
    begin
        uart_rx = 0;                                   // start bit
        repeat (BITP) @(posedge in_clk);
        for (k = 0; k < 7; k = k + 1) begin
            uart_rx = c[k];
            repeat (BITP) @(posedge in_clk);
        end
        uart_rx = 1;                                   // stop bit
        repeat (BITP*2) @(posedge in_clk);
    end
    endtask

    // Regression check for the mapping RAM window. diag loads the whole mapping RAM by
    // writing physical 0x100 to 0x1ff as ordinary memory. When the CPU did not decode
    // that window those writes went to the bus instead, the translation never changed,
    // and the test relocated itself through a stale mapping and ran off into empty
    // memory below 0x0100. A healthy run never executes down there at all.
    // Hardware failed the mapping RAM compare on pass 24704 (0x6080), well past the
    // 2649 passes reached so far, so run out to it. When the test takes its compare
    // failure branch, dump the mapping RAM against the reference copy the test keeps at
    // physical 0x200 and print only the entries that differ.
    integer passes = 0;
    reg caught = 0;
    integer j, diffs;
    reg [7:0] ent, ref;
    always @(posedge dut.clock) begin
        if (dut.instruction_fetch) begin
            if (dut.dbg_memory_address == 16'h8e88) passes = passes + 1;
            if (dut.dbg_memory_address == 16'h8f02 && !caught) begin
                caught = 1;
                $display("*** compare failed on pass %0d at %0t", passes, $time);
                diffs = 0;
                for (j = 0; j < 256; j = j + 1) begin
                    ent = { dut.cpu.page_table_hi[j], dut.cpu.page_table_lo[j] };
                    ref = dut.ram.low_ram_cells[16'h200 + j];
                    if (ent !== ref) begin
                        diffs = diffs + 1;
                        if (diffs <= 20)
                            $display("    entry %02x (table %0d page %02x): map %02x, reference %02x",
                                     j, j >> 5, j & 5'h1f, ent, ref);
                    end
                end
                $display("*** %0d of 256 entries differ", diffs);
            end
        end
    end

    integer low_count = 0;
    reg [15:0] last_low = 16'hffff;
    always @(posedge dut.clock) begin
        if (dut.instruction_fetch && dut.dbg_memory_address < 16'h0100) begin
            low_count = low_count + 1;
            last_low = dut.dbg_memory_address;
        end
    end

    initial begin
        wait (prompt_seen);                // wait for "ENTER TEST NUMBER:"
        #2000000;
        $display("");
        $display("--- typing '%s' to select a test ---", TEST);
        send(TEST);
        send(8'h0d);
        // The mapping RAM test runs until it is interrupted, so let it grind for a
        // while and then ask it to stop the way its own banner says to.
        #46000000000;
        $display("");
        $display("--- %0d characters total ---", n);
        $display("--- reached pass %0d ---", passes);
        if (low_count == 0)
            $display("ok: the machine never executed below 0x0100");
        else
            $display("FAIL: %0d instruction fetches below 0x0100, last at %04x",
                     low_count, last_low);
        $finish;
    end
endmodule

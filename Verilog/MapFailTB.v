`timescale 1 ns/10 ps
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
module IOBUF(output O, inout IO, input I, input OEN);
    assign IO = OEN ? 1'bz : I;
    assign O = IO;
endmodule

`include "tangnano9k.v"
`include "HyperRamModel.v"

/**
 * Runs diag's CPU-6 mapping RAM test until its compare fails, then reports.
 *
 * The failure only happens with real memory behind the page mappings - with the
 * block RAM alone every page the test maps outside the few backed regions reads
 * as 00 - so this testbench attaches the HyperRAM model like the board has one.
 *
 * It is slow: the failure is thousands of passes in. It stops the moment diag
 * branches to its compare-failure handler, which is the whole point, because
 * simulation can then say what led up to it and the board cannot.
 *
 * "make mapfail"
 */
module MapFailTB;
    reg in_clk = 0;
    always #18.5185 in_clk = ~in_clk;
    reg reset_btn = 1, btn2 = 1;
    wire L1,L2,L3,L4,L5,L6,L7,L8;
    wire uart_tx;
    reg  uart_rx = 1;

    wire [1:0] psram_ck, psram_ck_n, psram_cs_n, psram_reset_n;
    wire [1:0] psram_rwds;
    wire [15:0] psram_dq;
    HyperRamModel #(.ADDR_BITS(18)) die(
        .ck(psram_ck[0]), .cs_n(psram_cs_n[0]), .resetn(psram_reset_n[0]),
        .rwds(psram_rwds[0]), .dq(psram_dq[7:0]));

    tangnano9k dut(in_clk, reset_btn, btn2, L1,L2,L3,L4,L5,L6,L7,L8, uart_tx, uart_rx,
                   psram_ck, psram_ck_n, psram_cs_n, psram_reset_n, psram_rwds, psram_dq);

    // Still the documented minimum of two board clocks between enabled cycles, so
    // cycle level behaviour is unchanged; it just gets there sooner.
    defparam dut.cpu_clock_enable.TICKS = 13;

    localparam BITP = 27_000_000/19200 + 1;

    integer i;
    reg [7:0] ch;
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
            if (ch == ":") prompt_seen = 1;
            $write("%s", ch);
        end
    end

    task send(input [7:0] c);
    integer k;
    begin
        uart_rx = 0;
        repeat (BITP) @(posedge in_clk);
        for (k = 0; k < 7; k = k + 1) begin
            uart_rx = c[k];
            repeat (BITP) @(posedge in_clk);
        end
        uart_rx = 1;
        repeat (BITP*2) @(posedge in_clk);
    end
    endtask

    // Progress, so a run that is going nowhere can be told from one that is simply
    // long. diag's own output stops once the test starts.
    integer last_report = 0;
    always @(posedge dut.clock) begin
        if (dut.pass_count != 0 && dut.pass_count % 500 == 0
            && dut.pass_count != last_report) begin
            last_report = dut.pass_count;
            $display("... pass %0d at %0t", dut.pass_count, $time);
        end
    end

    // The invariant this design depends on: at least two board clocks between
    // enabled cycles, because the microcode ROM, the register file and the board
    // memory are block RAMs that read every clock and need one to settle.
    // ClockEnable respects it on its own; PsramBus hands back a withheld pulse
    // wherever the access happens to finish, so it has to be made to respect it too.
    integer adjacent = 0;
    reg en_d = 0;
    always @(posedge dut.clock) begin
        en_d <= dut.cpu_en;
        if (dut.cpu_en && en_d) adjacent = adjacent + 1;
    end
    integer report_at = 0;
    always @(posedge dut.clock) begin
        if (dut.pass_count != 0 && dut.pass_count % 200 == 0
            && dut.pass_count != report_at) begin
            report_at = dut.pass_count;
            $display("pass %0d: adjacent enabled cycles so far = %0d",
                     dut.pass_count, adjacent);
        end
    end

    // A ring of the last 32 enabled cycles, so the trigger below can print what led
    // up to it rather than only the moment itself. The whole difficulty with this
    // failure on the board is that a status dump says what state things ended in and
    // nothing about how they got there.
    localparam RING = 32;
    reg [10:0] r_uc   [0:RING-1];
    reg [55:0] r_pipe [0:RING-1];
    reg [2:0]  r_base [0:RING-1];
    reg [15:0] r_mar  [0:RING-1];
    reg [7:0]  r_res  [0:RING-1];
    reg [18:0] r_pa   [0:RING-1];
    reg [7:0]  r_din  [0:RING-1];
    reg        r_we   [0:RING-1];
    reg        r_stall[0:RING-1];
    integer r_head = 0;
    integer k;
    always @(posedge dut.clock) if (dut.cpu_en) begin
        r_uc[r_head]   <= dut.cpu.dbg_uc_address;
        r_pipe[r_head] <= dut.cpu.pipeline;
        r_base[r_head] <= dut.dbg_page_table_base;
        r_mar[r_head]  <= dut.dbg_memory_address;
        r_res[r_head]  <= dut.cpu.result_register;
        r_pa[r_head]   <= dut.addressBus;
        r_din[r_head]  <= dut.dbg_data_in;
        r_we[r_head]   <= dut.writeEnBus;
        r_stall[r_head]<= dut.psram_select;
        r_head <= (r_head + 1) % RING;
    end

    task report;
    begin
        $display("  # uc    k11 e6 e7 h11 d2d3 base MAR    result  PA      din we ps");
        for (k = 0; k < RING; k = k + 1) begin: pr
            integer i;
            i = (r_head + k) % RING;
            $display("  %2d %03x   %0d   %0d  %0d   %0d   %2d    %0d  %04x   %02x     %05x   %02x  %0d  %0d",
                     k - RING, r_uc[i],
                     r_pipe[i][9:7], r_pipe[i][6:4], r_pipe[i][14:13],
                     r_pipe[i][12:10], r_pipe[i][3:0],
                     r_base[i], r_mar[i], r_res[i], r_pa[i], r_din[i],
                     r_we[i], r_stall[i]);
        end
    end
    endtask

    // The anomaly, seen on the board: a page table entry written as zero when its
    // index is not zero. It happens a few hundred passes in rather than thousands,
    // so this stops early and prints the whole run up to it.
    reg caught = 0;
    always @(posedge dut.clock) begin
        if (!caught && dut.cpu_en && dut.dbg_pt_write
            && dut.dbg_pt_value == 8'h00 && dut.dbg_pt_index != 8'h00) begin
            caught <= 1;
            $display("");
            $display("=== page table entry %02x written as 00 on pass %0d ===",
                     dut.dbg_pt_index, dut.pass_count);
            $display("base=%0d MAR=%04x result=%02x PA=%05x",
                     dut.dbg_page_table_base, dut.dbg_memory_address,
                     dut.cpu.result_register, dut.addressBus);
            report;
            $finish;
        end
    end

    initial begin
        wait (prompt_seen);
        #2000000;
        $display("\n--- selecting test 02 ---");
        send("0"); send("2"); send(" ");

        wait (dut.compare_failed);
        #200000;
        $display("");
        $display("=== compare failed on pass %0d, in map %0d ===",
                 dut.fail_pass, dut.fail_base);
        $display("last four buffer reads: [%03x]=%02x [%03x]=%02x [%03x]=%02x [%03x]=%02x",
                 dut.f3[17:8], dut.f3[7:0], dut.f2[17:8], dut.f2[7:0],
                 dut.f1[17:8], dut.f1[7:0], dut.f0[17:8], dut.f0[7:0]);
        $display("branched from %04x", dut.fail_from);
        $finish;
    end

    initial begin
        #160000000;                    // 160ms, enough to boot and run the test a while
        $display("=== 160ms: %0d adjacent enabled cycles over %0d passes ===",
                 adjacent, dut.pass_count);
        $finish;
    end

    initial begin
        #40000000000;                  // 40 seconds of simulated board time
        $display("\nFAIL: no compare failure after %0d passes", dut.pass_count);
        $finish;
    end
endmodule

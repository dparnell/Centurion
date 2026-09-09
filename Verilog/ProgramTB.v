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
 * Runs a program on the whole simulated board and talks to it over the serial
 * line, so that writing machine code for this machine is a one second loop
 * rather than a three minute build, load and capture on hardware.
 *
 *   vvp ProgramTB +prog=programs/forth.txt +in=t.txt +for=200
 *
 *   +prog=FILE   the ROM image, one hex byte per line
 *   +in=FILE     characters to type at it once it has said something
 *   +for=N       milliseconds of simulated board time to run for
 *   +quiet       do not echo what the machine prints
 *   +hex         echo it as hex bytes instead, for when it is not text
 *
 * The whole board is here, PSRAM included, so a program can use all of the
 * memory and the MMU exactly as it would on the real thing.
 */
module ProgramTB;
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

    // Still at least two board clocks between enabled cycles, so cycle level
    // behaviour is unchanged; it just gets there sooner.
    defparam dut.cpu_clock_enable.TICKS = 13;

    localparam BITP = 27_000_000/19200 + 1;      // 19200 7N1, as diag uses

    integer i, nprinted = 0;
    reg [7:0] ch;
    reg quiet = 0;
    reg hex = 0;
    // How long the machine has been silent, in board clocks. Typing has to wait
    // for it to stop talking: the MUX holds one byte, so anything sent while a
    // banner is still printing is lost except the last of it.
    integer quiet_for = 0;
    always @(posedge in_clk) quiet_for = quiet_for + 1;
    reg said_something = 0;
    initial begin
        forever begin
            @(negedge uart_tx);
            repeat (BITP + BITP/2) @(posedge in_clk);
            ch = 0;
            for (i = 0; i < 7; i = i + 1) begin
                ch[i] = uart_tx;
                repeat (BITP) @(posedge in_clk);
            end
            said_something = 1;
            quiet_for = 0;
            nprinted = nprinted + 1;
            if (hex) $write("%02x ", ch);
            else if (!quiet) $write("%s", ch);
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
        repeat (BITP) @(posedge in_clk);
    end
    endtask

    integer fd, c, ms;
    reg [8*64:1] infile;
    initial begin
        if ($test$plusargs("quiet")) quiet = 1;
        if ($test$plusargs("hex")) hex = 1;
        if (!$value$plusargs("for=%d", ms)) ms = 100;
        if ($value$plusargs("in=%s", infile)) begin
            // Wait until the machine has printed something and then stopped,
            // so that input is not typed over the top of a banner.
            wait (said_something);
            wait (quiet_for > 27000 * 20);
            fd = $fopen(infile, "r");
            if (fd == 0) begin
                $display("\ncannot open %0s", infile);
                $finish;
            end
            // Typed at something like a human speed. The MUX holds one byte,
            // so sending a file at full line rate loses most of it while the
            // program is busy with the character before.
            c = $fgetc(fd);
            while (c != -1) begin
                send(c[7:0]);
                repeat (BITP * 12) @(posedge in_clk);
                if (c == 10 || c == 13)
                    repeat (BITP * 400) @(posedge in_clk);
                c = $fgetc(fd);
            end
            $fclose(fd);
        end
    end

    initial begin
        #(ms * 1000000);
        $display("\n--- %0d characters printed in %0dms ---", nprinted, ms);
        $finish;
    end
endmodule

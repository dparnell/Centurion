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

/**
 * Boots the real top level with a chosen Diag board DIP switch setting and prints
 * whatever the machine says. 0x1d is the auxiliary test menu, 0x1a is TOS - the
 * machine code monitor. Type characters by putting them in the KEYS string.
 */
module DipTB;
    parameter [7:0] DIP = 8'h1a;
    parameter [8*8:1] KEYS = "M";
    reg in_clk = 0;
    always #18.5185 in_clk = ~in_clk;
    reg reset_btn = 1, btn2 = 1;
    wire L1,L2,L3,L4,L5,L6,L7,L8;
    wire uart_tx;
    reg  uart_rx = 1;

    tangnano9k #(.DIAG_DIP_SWITCHES(DIP)) dut(in_clk, reset_btn, btn2,
                                              L1,L2,L3,L4,L5,L6,L7,L8, uart_tx, uart_rx);
    defparam dut.cpu_clock_enable.TICKS = 13;

    localparam BITP = 27_000_000/19200 + 1;
    integer i;
    reg [7:0] ch;
    integer n = 0;
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
            if (ch >= 32 && ch < 127) $write("%c", ch);
            else if (ch == 13) $write("\n");
            else if (ch != 10) $write(".");
            $fflush;
        end
    end

    task send(input [7:0] b);
        begin
            uart_rx = 0;
            repeat (BITP) @(posedge in_clk);
            for (i = 0; i < 7; i = i + 1) begin
                uart_rx = b[i];
                repeat (BITP) @(posedge in_clk);
            end
            uart_rx = 1;
            repeat (BITP*2) @(posedge in_clk);
        end
    endtask

    integer k;
    initial begin
        $display("--- DIP switches = %02x ---", DIP);
        #0 reset_btn = 1; #100000 reset_btn = 0; #200000 reset_btn = 1;
        repeat (120) #1000000;
        for (k = 8; k >= 1; k = k - 1) begin
            if (KEYS[k*8 -: 8] != 0) begin
                $display("\n--- typing %c ---", KEYS[k*8 -: 8]);
                send(KEYS[k*8 -: 8]);
                repeat (60) #1000000;
            end
        end
        $display("\n--- %0d characters ---", n);
        $display("--- hex display %02x, points %b, blank %b ---",
                 dut.diag_hex, dut.diag_points, dut.diag_blank);
        $finish;
    end
endmodule

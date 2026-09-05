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
 * Simulates the real tangnano9k top level, rather than a hand built replica of it.
 *
 * Every other board level testbench instantiates the modules itself, so a wiring
 * mistake in tangnano9k.v would not show up in any of them. This one drives the actual
 * top level ports and watches the actual UART pin and LEDs.
 */
module TopTB;
    reg in_clk = 0;
    always #18.5185 in_clk = ~in_clk;      // 27MHz
    reg reset_btn = 1, btn2 = 1;           // pulled up, not pressed
    wire L1,L2,L3,L4,L5,L6,L7,L8;
    wire uart_tx;
    reg  uart_rx = 1;

    tangnano9k dut(in_clk, reset_btn, btn2, L1,L2,L3,L4,L5,L6,L7,L8, uart_tx, uart_rx);

    integer edges = 0;
    always @(uart_tx) edges = edges + 1;

    // Decode the pin at 9600 8N1, which is what the test pattern generator sends
    localparam BITP = 27_000_000/9600 + 1;
    integer i;
    reg [7:0] ch;
    integer pattern_ok = 0, pattern_bad = 0;
    integer high;
    task decode_pattern;
    begin
        repeat (4) begin
            // 0x55 alternates, so a bare negedge lands mid character. Wait for the line
            // to sit idle high for more than a bit time first, then the next falling
            // edge really is a start bit.
            high = 0;
            while (high < (3*BITP)/2) begin
                @(posedge in_clk);
                high = uart_tx ? high + 1 : 0;
            end
            @(negedge uart_tx);
            repeat (BITP + BITP/2) @(posedge in_clk);
            for (i = 0; i < 8; i = i + 1) begin
                ch[i] = uart_tx;
                repeat (BITP) @(posedge in_clk);
            end
            if (ch == 8'h55) pattern_ok = pattern_ok + 1;
            else pattern_bad = pattern_bad + 1;
        end
    end
    endtask

    initial begin
        #40000000;                          // 40ms of the CPU driving the pin
        $display("uart_tx transitions in 40ms: %0d", edges);
        $display("LEDs (LED1..LED6, lit=1): %b%b%b%b%b%b", ~L1,~L2,~L3,~L4,~L5,~L6);
        if (edges == 0) $display("FAIL: the top level never drives the UART pin");
        else $display("ok: the top level drives the UART pin from the MUX");

        // Now hold btn2 and check the standalone pattern generator takes over
        btn2 = 0;
        decode_pattern;
        $display("btn2 held: %0d bytes decoded as 0x55, %0d wrong", pattern_ok, pattern_bad);
        if (pattern_ok == 4 && pattern_bad == 0)
            $display("ok: the test pattern generator sends 0x55 at 9600 8N1");
        else
            $display("FAIL: the test pattern is wrong");
        $finish;
    end
endmodule

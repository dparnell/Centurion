/*
 * The Gowin hard blocks, for simulation. Five testbenches used to carry their
 * own identical copies of these; the rPLL stub in particular has to be right
 * now that the PSRAM has a clock of its own, and five copies of a thing that
 * has to be right is four too many.
 */
`ifndef SIM_PRIMITIVES_V
`define SIM_PRIMITIVES_V

// The rPLL, as far as a simulation needs one: it measures the period of its
// input and generates an output at FCLKOUT = FCLKIN * (FBDIV_SEL+1) /
// (IDIV_SEL+1). The stub this replaces passed the input straight through, which
// is fine for a design with one clock and useless for one with two - a clock
// domain crossing whose two clocks are the same edge for edge is not being
// tested at all.
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
    real t0, in_period, out_half;
    reg out = 0;
    reg locked = 0;
    initial begin
        @(posedge CLKIN); t0 = $realtime;
        @(posedge CLKIN); in_period = $realtime - t0;
        out_half = (in_period * (IDIV_SEL + 1)) / ((FBDIV_SEL + 1) * 2);
        locked = 1;
        forever #(out_half) out = ~out;
    end
    assign CLKOUT = out;
    assign CLKOUTP = out;
    assign CLKOUTD = out;
    assign CLKOUTD3 = out;
    assign LOCK = locked;
endmodule

module ODDR(input CLK, input D0, input D1, input TX, output Q0, output Q1);
    assign Q0 = D0; assign Q1 = TX;
endmodule
module IDDR(input CLK, input D, output Q0, output Q1);
    assign Q0 = D; assign Q1 = D;
endmodule
module BUFG(input I, output O); assign O = I; endmodule
// OEN is active low.
module IOBUF(output O, inout IO, input I, input OEN);
    assign IO = OEN ? 1'bz : I;
    assign O = IO;
endmodule

`endif

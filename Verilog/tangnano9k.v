`include "CPU6.v"
`include "LEDPanel.v"
`include "psram_controller.v"
`include "mux.v"

/**
 * This file contains the top level Centurion CPU synthesizable on an Tang Nano 9K FGPA board.
 */


module Gowin_rPLL (clkout, clkoutp, clkin);

output clkout;
output clkoutp;
input clkin;

wire lock_o;
wire clkoutd_o;
wire clkoutd3_o;
wire gw_vcc;
wire gw_gnd;

assign gw_vcc = 1'b1;
assign gw_gnd = 1'b0;

rPLL rpll_inst (
    .CLKOUT(clkout),
    .LOCK(lock_o),
    .CLKOUTP(clkoutp),
    .CLKOUTD(clkoutd_o),
    .CLKOUTD3(clkoutd3_o),
    .RESET(gw_gnd),
    .RESET_P(gw_gnd),
    .CLKIN(clkin),
    .CLKFB(gw_gnd),
    .FBDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .IDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .ODSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .PSDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .DUTYDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .FDLY({gw_vcc,gw_vcc,gw_vcc,gw_vcc})
);

defparam rpll_inst.FCLKIN = "27";
defparam rpll_inst.DYN_IDIV_SEL = "false";
// 81 Mhz, LATENCY=3
defparam rpll_inst.FBDIV_SEL = 2;
defparam rpll_inst.IDIV_SEL = 0;       
defparam rpll_inst.ODIV_SEL = 8;

defparam rpll_inst.DYN_FBDIV_SEL = "false";
defparam rpll_inst.DYN_ODIV_SEL = "false";
defparam rpll_inst.PSDA_SEL = "0100";
defparam rpll_inst.DYN_DA_EN = "false";
defparam rpll_inst.DUTYDA_SEL = "1000";
defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL = "internal";
defparam rpll_inst.CLKOUT_BYPASS = "false";
defparam rpll_inst.CLKOUTP_BYPASS = "false";
defparam rpll_inst.CLKOUTD_BYPASS = "false";
defparam rpll_inst.DYN_SDIV_SEL = 2;
defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
defparam rpll_inst.DEVICE = "GW1NR-9C";

endmodule //Gowin_rPLL

// Change PLL and here to choose another speed.
localparam FREQ = 81_000_000;           
localparam LATENCY = 3;

module BlockRAM(input wire clock, input wire [18:0] address, input wire write_en, input wire [7:0] data_in,
    output wire [7:0] data_out);

    initial begin
        $readmemh("programs/blink.txt", ram_cells);
    end

    reg [7:0] ram_cells[0:255];

    wire [7:0] mapped_address = address[7:0];
    assign data_out = ram_cells[mapped_address]; 

    always @(posedge clock) begin
        if (write_en == 1 && address[15:8] == 8'hff) begin
            ram_cells[mapped_address] <= data_in;
        end
    end
endmodule


module tangnano9k(input in_clk, input reset_btn, output LED1, output LED2, output LED3, output LED4, output LED5, output LED6, output LED7, output LED8, input uartTx, output uartRx);
    initial begin
        reset = 0;
    end

    assign {LED1, LED2, LED3, LED4, LED5, LED6, LED7, LED8} = ~display_leds;
    
    reg reset;

    wire int_reqn;
    wire [3:0] irq_number;

    wire writeEnBus;
    wire [7:0] data_c2r, data_r2c;
    wire [18:0] addressBus;
    wire [7:0] leds;
    wire [7:0] display_leds;
    wire instruction_start;
    wire cpu_alive;

    Gowin_rPLL pll(
        .clkout(ram_clk),        // 81MHZ psram clock
        .clkoutp(ram_clk_p),     // 81MHZ psram clock phase shifted (90 degrees)
        .clkin(in_clk)      // 27Mhz system clock
    );

    // Memory Controller ---------------------------
    reg read, readd, write, byte_write;
    reg [21:0] address;
    reg [15:0] din;
    wire [15:0] dout;
    wire [7:0] dout_byte = address[0] ? dout[15:8] : dout[7:0];

    PsramController #(
        .LATENCY(LATENCY)
    ) mem_ctrl (
        .clk(ram_clk), .clk_p(ram_clk_p), .resetn(reset_btn), .read(read), .write(write), .byte_write(byte_write),
        .addr(address), .din(din), .dout(dout), .busy(busy),
        .O_psram_ck(O_psram_ck), .IO_psram_rwds(IO_psram_rwds), .IO_psram_dq(IO_psram_dq),
        .O_psram_cs_n(O_psram_cs_n)
    );

    // The divided CPU clock must be driven onto a global clock network. Left on general
    // routing it picks up ~2.4ns of skew across the die, which shows up as hold time
    // violations at the register file block RAM (cpu.reg_ram.memory.*.CLK).
    wire clock_div;
    wire clock;
    Divide4 div(in_clk, clock_div);
    BUFG clock_bufg(.I(clock_div), .O(clock));
    BlockRAM ram(clock, addressBus, writeEnBus, data_c2r, data_r2c);
    LEDPanel panel(clock, addressBus, writeEnBus, data_c2r, data_r2c, leds);
    MUX mux0(in_clk, clock, uartTx, uartRx, addressBus & 19'hffff0 == 19'h0f200 ? 1 : 0, address[3:0], writeEnBus, data_c2r, data_r2c, int_reqn, irq_number);

    CPU6 cpu (reset, clock, data_r2c, int_reqn, irq_number, writeEnBus, addressBus, data_c2r, instruction_start);

    Watchdog watchdog(in_clk, instruction_start, leds, display_leds, cpu_alive);

	always @ (posedge clock) begin
        reset <= ~reset_btn;
    end
endmodule


/**
 * CPU liveness watchdog.
 *
 * Runs entirely in the free running 27MHz input clock domain so that it keeps working
 * even when the divided CPU clock is stopped or the core is wedged. The CPU pulses
 * heartbeat once per instruction (microcode address 0x101). If no heartbeat arrives
 * for TIMEOUT input clocks the core is considered dead, and the LEDs are taken over
 * by a slow blink of all eight LEDs instead of showing the LED panel register.
 *
 * A steady ~1Hz blink of all eight LEDs therefore means "the bitstream is loaded and
 * the board is clocking, but the CPU6 is not executing instructions".
 */
module Watchdog #(
    parameter TIMEOUT = 13_500_000,     // 0.5s at 27MHz with no instruction executed
    parameter BLINK   = 13_500_000      // 0.5s half period, so a 1Hz blink
) (
    input wire clock_in,                // 27MHz, always running
    input wire heartbeat,               // pulses once per instruction, CPU clock domain
    input wire [7:0] leds_in,           // normal LED panel value
    output wire [7:0] leds_out,
    output wire alive
);
    // The CPU clock is derived from clock_in, so the heartbeat only needs edge detection
    // rather than a full clock domain crossing.
    reg heartbeat_d;
    wire heartbeat_edge = heartbeat & ~heartbeat_d;

    reg [23:0] stall_counter;
    reg [23:0] blink_counter;
    reg blink;
    reg stalled;

    initial begin
        heartbeat_d = 0;
        stall_counter = 0;
        blink_counter = 0;
        blink = 0;
        stalled = 0;
    end

    always @(posedge clock_in) begin
        heartbeat_d <= heartbeat;

        if (heartbeat_edge) begin
            stall_counter <= 0;
            stalled <= 0;
        end else if (stall_counter == TIMEOUT) begin
            stalled <= 1;
        end else begin
            stall_counter <= stall_counter + 1;
        end

        if (blink_counter == BLINK) begin
            blink_counter <= 0;
            blink <= ~blink;
        end else begin
            blink_counter <= blink_counter + 1;
        end
    end

    assign alive = ~stalled;
    assign leds_out = stalled ? {8{blink}} : leds_in;
endmodule

module Divide4(input wire clock_in, output reg clock_out);
    reg [1:0] counter;
    
    always @(posedge clock_in) begin
        counter <= counter + 1;
        if (counter == 2'b11)
            clock_out <= ~clock_out;
    end
endmodule

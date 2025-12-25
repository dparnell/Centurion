
`include "CPU6.v"
`include "LEDPanel.v"

/**
 * This file contains the top level Centurion CPU synthesizable on an Tang Nano 9K FGPA board.
 */
module BlockRAM(input wire clock, input wire [18:0] address, input wire write_en, input wire [7:0] data_in,
    output wire [7:0] data_out);

    initial begin
        $readmemh("programs/cylon.txt", ram_cells);
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


module tangnano9k(input in_clk, output LED1, output LED2, output LED3, output LED4, output LED5, output LED6, output LED7, output LED8);
    initial begin
        reset = 1;
    end

    assign {LED1, LED2, LED3, LED4, LED5, LED6, LED7, LED8} = leds;
    
    reg reset;

    wire writeEnBus;
    wire [7:0] data_c2r, data_r2c;
    wire [18:0] addressBus;
    wire [7:0] leds;
    wire clock20MHz, locked, clock;


    // See: https://juj.github.io/gowin_fpga_code_generators/pll_calculator.html
    rPLL #( // For GW1NR-9C C6/I5 (Tang Nano 9K proto dev board)
    .FCLKIN("27"),
    .IDIV_SEL(3), // -> PFD = 6.75 MHz (range: 3-400 MHz)
    .FBDIV_SEL(2), // -> CLKOUT = 20.25 MHz (range: 3.125-600 MHz)
    .ODIV_SEL(32) // -> VCO = 648 MHz (range: 400-1200 MHz)
    ) pll (.CLKOUTP(), .CLKOUTD(), .CLKOUTD3(), .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0), .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0),
    .CLKIN(in_clk), // 27 MHz
    .CLKOUT(clock20MHz), // 20.25 MHz
    .LOCK(locked)
    );

    Divide4 div(clock20MHz, clock);
    BlockRAM ram(clock, addressBus, writeEnBus, data_c2r, data_r2c);
    LEDPanel panel(clock, addressBus, writeEnBus, data_c2r, data_r2c, leds);
    CPU6 cpu (reset, clock, data_r2c, writeEnBus, addressBus, data_c2r);

	always @ (posedge clock) begin
		if (reset == 1 && locked == 1) begin
			reset <= 0;
		end
    end
endmodule

module Divide4(input wire clock_in, output wire clock_out);
    reg [1:0] counter;
    assign clock_out = counter[1];
    always @(posedge clock_in) begin
        counter <= counter + 1;
    end
endmodule

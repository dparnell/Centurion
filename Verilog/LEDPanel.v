
/**
 * The LED panel found on Alchitry Cu FPGA boards.
 * See ice40_alchitry_cu.pcf for pin configurations.
 */
/**
 * The LED panel is write only, so it deliberately has no data_out port. It used to
 * declare one and never drive it, which put an undriven wire on the shared CPU read
 * bus.
 */
module LEDPanel(input wire clock, input wire enable, input wire [18:0] address, input wire write_en, input wire [7:0] data_in,
    output reg [7:0] leds);

    initial begin
        leds = 0;
    end

    always @(posedge clock) begin
        if (enable && write_en == 1) begin
            if (address == 19'h5c00) begin
                $display("leds set: %x", data_in);
                leds <= data_in;
            end
        end
    end
endmodule

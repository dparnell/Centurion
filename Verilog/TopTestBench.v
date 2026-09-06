`timescale 1 ns/10 ps
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
    reg reset_btn = 1;                     // pulled up, not pressed
    wire L1,L2,L3,L4,L5,L6,L7,L8;
    wire uart_tx;
    reg  uart_rx = 1;

    tangnano9k dut(in_clk, reset_btn, L1,L2,L3,L4,L5,L6,L7,L8, uart_tx, uart_rx);

    integer edges = 0;
    always @(uart_tx) edges = edges + 1;

    initial begin
        #40000000;                          // 40ms of the CPU driving the pin
        $display("uart_tx transitions in 40ms: %0d", edges);
        $display("LEDs (LED1..LED6, lit=1): %b%b%b%b%b%b", ~L1,~L2,~L3,~L4,~L5,~L6);
        if (edges == 0) $display("FAIL: the top level never drives the UART pin");
        else $display("ok: the top level drives the UART pin from the MUX");

        $finish;
    end
endmodule

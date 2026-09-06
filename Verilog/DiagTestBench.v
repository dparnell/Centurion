`timescale 1 ns/10 ps
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
    reg reset_btn = 1;
    wire L1,L2,L3,L4,L5,L6,L7,L8;
    wire uart_tx;
    reg  uart_rx = 1;

    tangnano9k dut(in_clk, reset_btn, L1,L2,L3,L4,L5,L6,L7,L8, uart_tx, uart_rx);

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

    initial begin
        wait (prompt_seen);                // wait for "ENTER TEST NUMBER:"
        #2000000;
        $display("");
        $display("--- typing '%s' to select a test ---", TEST);
        send(TEST);
        send(8'h0d);
        #1400000000;
        $display("");
        $display("--- %0d characters total ---", n);
        $finish;
    end
endmodule

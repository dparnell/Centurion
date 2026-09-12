`timescale 1 ns/10 ps
// Stubs for the Gowin hard blocks so the real top level can be simulated. The PSRAM
// controller is not driven by anything, so its DDR buffers only need to elaborate.
`include "SimPrimitives.v"


`include "tangnano9k.v"
`include "HyperRamModel.v"
`include "SdCardModel.v"

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

    
    // The embedded HyperRAM, which now backs most of the machine's 256K of
    // physical memory. ADDR_BITS is 18 because that is all the CPU6 has.
    wire [1:0] psram_ck, psram_ck_n, psram_cs_n, psram_reset_n;
    wire [1:0] psram_rwds;
    wire [15:0] psram_dq;

    // The microSD slot, with a card in it. A design that mounts an image at
    // power up has to have something to mount, and a floating MISO makes the
    // mounter's state machine wander rather than simply failing.
    wire sd_clk, sd_mosi, sd_cs_n;
    wire sd_miso;
    pullup(sd_miso);
    SdCardModel #(.BLOCKS(133120), .FILL(8'h00)) sdcard(sd_clk, sd_cs_n, sd_mosi, sd_miso);
    reg [8*64:1] sd_image;
    initial begin
        if (!$value$plusargs("sd=%s", sd_image)) sd_image = "sd_fat32.hex";
        #1 $readmemh(sd_image, sdcard.mem);
    end
    HyperRamModel #(.ADDR_BITS(18)) die(
        .ck(psram_ck[0]), .cs_n(psram_cs_n[0]), .resetn(psram_reset_n[0]),
        .rwds(psram_rwds[0]), .dq(psram_dq[7:0]));

    tangnano9k dut(in_clk, reset_btn, btn2, L1,L2,L3,L4,L5,L6,L7,L8, uart_tx, uart_rx, psram_ck, psram_ck_n, psram_cs_n, psram_reset_n, psram_rwds, psram_dq,
                   sd_clk, sd_mosi, sd_miso, sd_cs_n);

    integer edges = 0;
    always @(uart_tx) edges = edges + 1;

    localparam DBITP = 27_000_000/19200 + 1;
    integer di, dump_chars = 0;
    reg [7:0] dch;
    task decode_dump;
    begin
        repeat (60) begin
            @(negedge uart_tx);
            repeat (DBITP + DBITP/2) @(posedge in_clk);
            dch = 0;
            for (di = 0; di < 7; di = di + 1) begin
                dch[di] = uart_tx;
                repeat (DBITP) @(posedge in_clk);
            end
            dump_chars = dump_chars + 1;
            $write("%s", dch);
        end
    end
    endtask

    // diag reconfigures the channel to 19200 7N1, so send at that. Getting this wrong
    // makes the receiver report two bytes of nonsense for one sent, which looks exactly
    // like a broken receiver and is not.
    localparam RBITP = 27_000_000/19200 + 1;
    integer rb;
    task send_char(input [7:0] c);
    integer k;
    reg p;
    begin
        p = 0;
        uart_rx = 0; repeat (RBITP) @(posedge in_clk);
        for (k = 0; k < 7; k = k + 1) begin
            uart_rx = c[k]; p = p ^ c[k];
            repeat (RBITP) @(posedge in_clk);
        end
        uart_rx = 1;                       // no parity, straight to the stop bit
        repeat (RBITP*3) @(posedge in_clk);
    end
    endtask

    // The invariant the whole design rests on: at least two board clocks between
    // enabled cycles. The microcode ROM, the register file and the board memory are
    // block RAMs that read every clock and need one to settle, so two enabled edges
    // in a row hand the core a stale byte. ClockEnable respects this on its own;
    // PsramBus has to be made to, because it hands back a withheld enable wherever
    // the memory access happens to finish. Without its guard this counts 14021
    // violations in 160ms of MapFailTB.
    integer adjacent_enables = 0;
    reg cpu_en_d = 0;
    always @(posedge dut.clock) begin
        cpu_en_d <= dut.cpu_en;
        if (dut.cpu_en && cpu_en_d) adjacent_enables = adjacent_enables + 1;
    end
    initial begin
        #39000000;
        if (adjacent_enables == 0)
            $display("ok: no two enabled cycles were adjacent");
        else
            $display("FAIL: %0d pairs of adjacent enabled cycles", adjacent_enables);
    end

    initial begin
        #40000000;                          // 40ms of the CPU driving the pin
        $display("uart_tx transitions in 40ms: %0d", edges);
        $display("LEDs (LED1..LED6, lit=1): %b%b%b%b%b%b", ~L1,~L2,~L3,~L4,~L5,~L6);
        if (edges == 0) $display("FAIL: the top level never drives the UART pin");
        else $display("ok: the top level drives the UART pin from the MUX");

        $display("received byte count before sending: %0d", dut.instruments.rx_count);
        send_char("A");
        $display("received byte count after sending 'A': %0d (last byte %02x)",
                 dut.instruments.rx_count, dut.dbg_rx_byte);
        if (dut.instruments.rx_count == 0) $display("FAIL: the receive counter did not move");

        // Hold btn2 and decode the status dump, at diag's 19200 7N1
        btn2 = 0;
        $write("status dump: ");
        decode_dump;
        $display("");
        if (dump_chars < 30) $display("FAIL: the status dump produced almost nothing");
        else $display("ok: the status dump printed %0d characters", dump_chars);
        $finish;
    end
endmodule

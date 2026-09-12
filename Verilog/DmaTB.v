`timescale 1 ns/10 ps
`include "SimPrimitives.v"

`include "tangnano9k.v"
`include "HyperRamModel.v"
`include "SdCardModel.v"

/**
 * The DMA path, end to end and self checking.
 *
 * asm/dmatest.s runs a transfer each way over a 64 byte buffer against
 * DmaTest.v, which generates or checks pattern(N) = N ^ 0x5a rather than storing
 * anything. On the board you read the answer off the serial line; here the
 * device's own registers and the memory behind the buffer are both visible, so
 * this checks them directly and stops as soon as the second transfer finishes
 * rather than waiting for the machine to finish saying so at 19200 baud.
 *
 * What it is actually guarding. A DMA byte takes three enabled cycles on this
 * design because writeEnBus is a registered output: a two phase engine steps the
 * address before the write strobe reaches the bus and puts every byte one place
 * too far along, which is invisible from inside the core - the trace of what the
 * DMA engine intended is perfectly correct - and only shows up in memory.
 *
 * "make dmatest"
 */
module DmaTB;
    reg in_clk = 0;
    always #18.5185 in_clk = ~in_clk;
    reg reset_btn = 1, btn2 = 1;
    wire L1,L2,L3,L4,L5,L6,L7,L8;
    wire uart_tx;
    reg  uart_rx = 1;

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

    tangnano9k #(.PROGRAM("programs/dmatest.txt"), .DMA_TEST(1)) dut(
                   in_clk, reset_btn, btn2, L1,L2,L3,L4,L5,L6,L7,L8, uart_tx, uart_rx,
                   psram_ck, psram_ck_n, psram_cs_n, psram_reset_n, psram_rwds, psram_dq,
                   sd_clk, sd_mosi, sd_miso, sd_cs_n);

    // The same 13 tick core the other long testbenches use: still the documented
    // minimum of two board clocks between enabled cycles, so nothing about the
    // cycle level behaviour changes, it just gets there sooner.
    defparam dut.cpu_clock_enable.TICKS = 13;

    localparam LEN = 64;
    localparam BUF = 19'h01000;     // map 0 makes virtual 0x1000 physical too

    integer i, wrong;
    reg [7:0] got, want;
    integer transfers = 0;
    reg last_done = 0;
    integer failures = 0;

    // Physical 0x1000 is above the 4K of low RAM, so the buffer lives in the
    // PSRAM and the transfer goes through the memory bridge, its cache and its
    // write buffer. That is the arrangement worth testing: reading the die's own
    // array afterwards says whether the bytes really landed, independently of
    // anything the bridge might be holding.
    task check_buffer;
        begin
            // Let the bridge's posted writes drain first. Without this the last
            // byte of the transfer is still sitting in the write buffer and the
            // die reads ff for it - a failure of the instrument, not of the DMA,
            // and one that points at exactly the wrong place.
            while (!dut.machine.psram_bus.wbuf_empty || dut.machine.psram_bus.busy)
                @(posedge in_clk);
            wrong = 0;
            for (i = 0; i < LEN; i = i + 1) begin
                got = die.mem[BUF + i];
                want = (i & 8'hff) ^ 8'h5a;
                if (got !== want) begin
                    if (wrong < 4)
                        $display("FAIL: buffer[%0d] is %h, wanted %h", i, got, want);
                    wrong = wrong + 1;
                end
            end
            if (wrong == 0) $display("ok: the device wrote all %0d bytes where they belong", LEN);
            else begin
                $display("FAIL: %0d of %0d bytes wrong", wrong, LEN);
                failures = failures + 1;
            end
        end
    endtask

    always @(posedge in_clk) begin
        if (dut.machine.dma_test_device.dmatest.done && !last_done) begin
            transfers = transfers + 1;
            if (dut.machine.dma_test_device.dmatest.offset !== LEN) begin
                $display("FAIL: transfer %0d moved %0d bytes, not %0d",
                         transfers, dut.machine.dma_test_device.dmatest.offset, LEN);
                failures = failures + 1;
            end
            if (transfers == 1) begin
                // Device to memory: nothing has checked the bytes yet, so we do.
                check_buffer;
            end else begin
                // Memory to device: the device checked every byte as it arrived.
                if (dut.machine.dma_test_device.dmatest.bad_count !== 0) begin
                    $display("FAIL: the device saw %0d wrong bytes, first at %0d: wanted %h got %h",
                             dut.machine.dma_test_device.dmatest.bad_count, dut.machine.dma_test_device.dmatest.bad_offset,
                             dut.machine.dma_test_device.dmatest.bad_want, dut.machine.dma_test_device.dmatest.bad_got);
                    failures = failures + 1;
                end else
                    $display("ok: the device read back all %0d bytes it wrote", LEN);
                if (failures == 0) $display("ok: DMA works in both directions");
                $finish;
            end
        end
        last_done <= dut.machine.dma_test_device.dmatest.done;
    end

    initial begin
        #200_000_000;               // 200ms, several times what the run needs
        $display("FAIL: only %0d of 2 transfers finished", transfers);
        $finish;
    end
endmodule

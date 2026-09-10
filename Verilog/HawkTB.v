`timescale 1 ns/10 ps
`include "SimPrimitives.v"

`include "tangnano9k.v"
`include "HyperRamModel.v"
`include "SdCardModel.v"

/**
 * The Hawk disk controller, end to end and self checking.
 *
 * asm/hawktest.s writes a sector out over DMA and reads it back into a different
 * buffer, and prints what it finds. Here the controller's own registers and its
 * sector buffer are visible, so this checks them directly rather than parsing
 * the serial output, and stops as soon as the read completes.
 *
 * What it is guarding, beyond "the bytes came back": that the controller ends up
 * holding the right 400 bytes rather than merely returning what it was handed,
 * that the sector address the transfer leaves behind has advanced by exactly one
 * sector, and that the drive reports on-cylinder and seek-complete after a seek.
 *
 * "make hawktest"
 */
module HawkTB;
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
    HyperRamModel #(.ADDR_BITS(23)) die(
        .ck(psram_ck[0]), .cs_n(psram_cs_n[0]), .resetn(psram_reset_n[0]),
        .rwds(psram_rwds[0]), .dq(psram_dq[7:0]));

    tangnano9k #(.PROGRAM("programs/hawktest.txt")) dut(
                   in_clk, reset_btn, btn2, L1,L2,L3,L4,L5,L6,L7,L8, uart_tx, uart_rx,
                   psram_ck, psram_ck_n, psram_cs_n, psram_reset_n, psram_rwds, psram_dq,
                   sd_clk, sd_mosi, sd_miso, sd_cs_n);

    defparam dut.cpu_clock_enable.TICKS = 13;

    localparam LEN = 400;
    localparam SECTOR = 16'h0005;   // the sector the transfers use
    localparam OUTBUF = 19'h01000;
    localparam INBUF  = 19'h01400;

    integer i, wrong;
    integer failures = 0;
    integer commands = 0;
    reg [7:0] got, want;
    reg last_busy = 0;

    task check_sector_buffer;
        begin
            wrong = 0;
            for (i = 0; i < LEN; i = i + 1) begin
                got = dut.hawk.sector_buf[i];
                want = (i & 8'hff) ^ 8'h5a;
                if (got !== want) begin
                    if (wrong < 4)
                        $display("FAIL: the controller holds %h at offset %0d, not %h",
                                 got, i, want);
                    wrong = wrong + 1;
                end
            end
            if (wrong == 0)
                $display("ok: the controller took all %0d bytes of the sector", LEN);
            else begin
                $display("FAIL: %0d of %0d bytes wrong in the sector buffer", wrong, LEN);
                failures = failures + 1;
            end
        end
    endtask

    task check_memory;
        begin
            // The buffers are above the 4K of low RAM, so they live in the PSRAM
            // and this goes through the bridge. Let its posted writes drain first
            // or the last byte is still in the write buffer and reads ff.
            while (!dut.psram_bus.wbuf_empty || dut.psram_bus.busy)
                @(posedge in_clk);
            wrong = 0;
            for (i = 0; i < LEN; i = i + 1) begin
                got = die.mem[INBUF + i];
                want = die.mem[OUTBUF + i];
                if (got !== want) begin
                    if (wrong < 4)
                        $display("FAIL: read back %h at offset %0d, wrote %h", got, i, want);
                    wrong = wrong + 1;
                end
            end
            if (wrong == 0)
                $display("ok: all %0d bytes came back from the sector unchanged", LEN);
            else begin
                $display("FAIL: %0d of %0d bytes differ after the round trip", wrong, LEN);
                failures = failures + 1;
            end
        end
    endtask

    // Every command ends with busy falling. 1 is the seek, 2 the write, 3 the read.
    always @(posedge in_clk) begin
        if (last_busy && !dut.hawk.busy) begin
            commands = commands + 1;
            case (commands)
                1: begin
                    if (dut.hawk.seek_done !== 1'b1 || dut.hawk.seeking !== 1'b0) begin
                        $display("FAIL: after the seek, seek_done=%b seeking=%b",
                                 dut.hawk.seek_done, dut.hawk.seeking);
                        failures = failures + 1;
                    end else
                        $display("ok: the seek completed and the drive is on cylinder");
                end
                2: begin
                    check_sector_buffer;
                    // A transfer of exactly one sector leaves the address on the
                    // next one, which is what lets a longer DMA stream through
                    // consecutive sectors.
                    if (dut.hawk.sector_addr !== SECTOR + 1) begin
                        $display("FAIL: after writing one sector the address is %h, not %h",
                                 dut.hawk.sector_addr, SECTOR + 1);
                        failures = failures + 1;
                    end else
                        $display("ok: the sector address stepped on by exactly one");
                end
                3: begin
                    check_memory;
                    check_image;
                    if (failures == 0)
                        $display("ok: the Hawk controller works over DMA in both directions");
                    $finish;
                end
            endcase
        end
        last_busy <= dut.hawk.busy;
    end

    // Where the image lives in the part: DiskImage's own base, plus the sector.
    localparam IMAGE_BASE = 23'h040000;
    task check_image;
        begin
            while (dut.image.busy) @(posedge in_clk);
            wrong = 0;
            for (i = 0; i < 400; i = i + 1) begin
                got = die.mem[IMAGE_BASE + SECTOR * 512 + i];
                want = (i & 8'hff) ^ 8'h5a;
                if (got !== want) begin
                    if (wrong < 3)
                        $display("FAIL: the cached image holds %h at sector byte %0d, not %h",
                                 got, i, want);
                    wrong = wrong + 1;
                end
            end
            if (wrong == 0)
                $display("ok: the written sector really reached the image in PSRAM");
            else begin
                $display("FAIL: %0d of 400 bytes of the cached sector are wrong", wrong);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        #250_000_000;
        $display("FAIL: only %0d of 3 commands finished", commands);
        $finish;
    end
endmodule

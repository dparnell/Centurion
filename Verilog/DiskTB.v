`timescale 1 ns/10 ps
`include "SimPrimitives.v"
`include "SdSpi.v"
`include "SdCardModel.v"
`include "Fat32.v"
`include "PsramSdr.v"
`include "HyperRamModel.v"
`include "DiskImage.v"

/**
 * The whole storage stack with no CPU and no bus: card, filesystem, cache.
 *
 * A real FAT32 volume made by mkfs.vfat, a real image file inside it, a
 * behavioural HyperRAM die, and DiskImage between them. It stands in for the
 * controller by owning the sector buffer itself, which is the same 512 bytes
 * HawkDisk has, so what is tested here is exactly what the controller will get.
 *
 * The checks that matter:
 *
 *   - a block fetched from the card holds that block's data, which the image's
 *     contents encode, so a wrong block is caught rather than merely wrong bytes
 *   - the second read of the same block does not touch the card at all, which is
 *     the entire point of the cache and is invisible from the data alone
 *   - a block written and read back comes back changed, and the card has *not*
 *     changed until it is flushed
 *   - after a flush the card holds it, and the writes went to the right LBA -
 *     which for the fragmented image is not the one arithmetic would give
 *
 * "make disktest"
 */
module DiskTB;
    reg clock = 0;
    always #18.5185 clock = ~clock;         // 27MHz
    reg reset = 1;

    // ------------------------------------------------------------- the card
    wire sd_clk, sd_mosi, sd_cs_n;
    wire sd_miso;
    pullup(sd_miso);

    wire fat_read;
    wire [31:0] fat_block;
    wire img_read, img_write;
    wire [31:0] img_block;
    wire sd_busy, sd_ready, sd_error;
    wire rx_strobe, tx_request;
    wire [8:0] rx_index, tx_index;
    wire [7:0] rx_byte, tx_byte;
    wire [7:0] sd_state, sd_r1;
    wire sd_block_addressing;

    // The mounter and the image layer both drive the card; the mounter only ever
    // does so before the image layer starts, so a plain or is enough here.
    wire card_read  = fat_read | img_read;
    wire card_write = img_write;
    wire [31:0] card_block = fat_read ? fat_block : img_block;

    SdSpi sd(clock, reset, sd_clk, sd_mosi, sd_miso, sd_cs_n,
             card_read, card_write, card_block, sd_busy, sd_ready, sd_error,
             rx_strobe, rx_index, rx_byte, tx_request, tx_index, tx_byte,
             sd_state, sd_r1, sd_block_addressing);

    reg [8*64:1] image_file;
    initial if (!$value$plusargs("image=%s", image_file)) image_file = "sd_fat32.hex";
    SdCardModel #(.BLOCKS(133120), .FILL(8'h00)) card(sd_clk, sd_cs_n, sd_mosi, sd_miso);
    initial #1 $readmemh(image_file, card.mem);

    // ------------------------------------------------------ the filesystem
    reg mount = 0;
    wire mounted, mount_failed;
    wire [3:0] fail_reason;
    wire [15:0] file_blocks;
    wire map_req, map_valid;
    wire [15:0] map_block;
    wire [31:0] map_lba;
    wire [7:0] fat_state, fat_extents;
    wire fat_fallback;

    Fat32 #(.FILENAME("HAWK0   IMG")) fat(
        clock, reset, mount, mounted, mount_failed, fail_reason,
        fat_read, fat_block, sd_busy, sd_ready, sd_error,
        rx_strobe, rx_index, rx_byte,
        file_blocks, map_req, map_block, map_valid, map_lba,
        fat_state, fat_extents, fat_fallback);

    // ------------------------------------------------------------- the PSRAM
    wire [1:0] ps_ck, ps_ck_n, ps_cs_n, ps_rst_n, ps_rwds;
    wire [15:0] ps_dq;
    HyperRamModel #(.ADDR_BITS(23)) die(
        .ck(ps_ck[0]), .cs_n(ps_cs_n[0]), .resetn(ps_rst_n[0]),
        .rwds(ps_rwds[0]), .dq(ps_dq[7:0]));

    wire ps_read, ps_write, ps_byte_write;
    wire [22:0] ps_addr;
    wire [15:0] ps_din;
    wire [63:0] ps_dout;
    wire ps_busy;
    PsramSdr #(.DEBUG_SCAN(0)) psram(
        .clk(clock), .sample_clk(clock), .resetn(!reset),
        .read(ps_read), .write(ps_write), .addr(ps_addr), .din(ps_din),
        .byte_write(ps_byte_write), .dout(ps_dout), .busy(ps_busy),
        .O_psram_ck(ps_ck), .O_psram_ck_n(ps_ck_n), .O_psram_cs_n(ps_cs_n),
        .O_psram_reset_n(ps_rst_n), .IO_psram_rwds(ps_rwds), .IO_psram_dq(ps_dq));

    // -------------------------------------------- the image, and a sector buffer
    // The buffer is the controller's in the real design; here the testbench owns
    // it, with the same registered read HawkDisk's has.
    reg [7:0] sector_buf [0:511];
    reg [7:0] buf_q;
    wire buf_wr;
    wire [8:0] buf_addr;
    wire [7:0] buf_wdata;
    always @(posedge clock) begin
        if (buf_wr) sector_buf[buf_addr] <= buf_wdata;
        buf_q <= sector_buf[buf_addr];
    end

    reg img_req = 0, img_store = 0, do_flush = 0;
    reg [15:0] img_req_block = 0;
    wire img_busy, img_failed, img_flushing;
    wire [7:0] img_state;
    wire [15:0] img_fetches, img_hits, img_writebacks;

    DiskImage #(.MAX_BLOCKS(256), .META_BITS(8)) image(
        clock, reset, mounted, file_blocks,
        map_req, map_block, map_valid, map_lba,
        img_read, img_write, img_block, sd_busy, sd_error,
        rx_strobe, rx_index, rx_byte, tx_request, tx_index, tx_byte,
        ps_read, ps_write, ps_byte_write, ps_addr, ps_din, ps_dout, ps_busy,
        img_req, img_store, img_req_block, img_busy, img_failed,
        buf_wr, buf_addr, buf_wdata, buf_q,
        do_flush, img_flushing,
        img_state, img_fetches, img_hits, img_writebacks);

    // ----------------------------------------------------------------- checks
    // Where block 5 really lives, taken from the mounter rather than assumed,
    // because for the fragmented image it is not where arithmetic would put it.
    reg [31:0] block5_lba = 0;
    always @(posedge clock)
        if (map_valid && map_block == 5) block5_lba <= map_lba;

    integer failures = 0;
    integer i, wrong, countdown, reads_before;

    task do_op(input store, input [15:0] b);
        begin
            @(negedge clock);
            img_req_block = b; img_store = store; img_req = 1;
            while (!img_busy) @(posedge clock);
            @(negedge clock);
            img_req = 0;
            countdown = 5_000_000;
            while (img_busy && countdown != 0) begin @(posedge clock); countdown = countdown - 1; end
            if (img_busy) begin
                $display("FAIL: the image layer never finished (state %0d)", img_state);
                failures = failures + 1;
                $finish;
            end
        end
    endtask

    // With +raw= the expected contents are a real disk image rather than the
    // synthetic pattern, which is what proves the controller reads real sectors
    // from real offsets and not merely something self consistent.
    reg [7:0] raw [0:256*512-1];
    reg use_raw = 0;
    reg [8*64:1] raw_file;
    initial if ($value$plusargs("raw=%s", raw_file)) begin
        $readmemh(raw_file, raw);
        use_raw = 1;
    end

    function [7:0] expected(input [15:0] b, input integer off, input integer bias);
        // In raw mode the bias perturbs the real data rather than being
        // ignored, so "write then read back" still tests something: without it
        // the written block is identical to what was already there and the
        // check passes whatever happened.
        expected = use_raw ? (raw[b * 512 + off] ^ bias[7:0])
                           : ((b * 13 + off + bias) & 8'hff);
    endfunction

    task expect_buffer(input [15:0] b, input integer bias);
        begin
            wrong = 0;
            for (i = 0; i < 512; i = i + 1)
                if (sector_buf[i] !== expected(b, i, bias)) begin
                    if (wrong < 3)
                        $display("FAIL: buffer[%0d] is %h, wanted %h",
                                 i, sector_buf[i], expected(b, i, bias));
                    wrong = wrong + 1;
                end
            if (wrong != 0) begin
                $display("FAIL: %0d of 512 bytes wrong for block %0d", wrong, b);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        repeat (20) @(posedge clock);
        reset = 0;
        countdown = 3_000_000;
        while (!(sd_ready && !img_busy) && countdown != 0) begin
            @(posedge clock); countdown = countdown - 1;
        end
        if (!sd_ready) begin $display("FAIL: the card never initialised"); $finish; end

        @(negedge clock); mount = 1; @(negedge clock); mount = 0;
        countdown = 20_000_000;
        while (!mounted && !mount_failed && countdown != 0) begin
            @(posedge clock); countdown = countdown - 1;
        end
        if (!mounted) begin
            $display("FAIL: mount failed (reason %0d)", fail_reason);
            $finish;
        end
        $display("ok: mounted %0d blocks in %0d extent%0s",
                 file_blocks, fat_extents, fat_extents == 1 ? "" : "s");

        // ---- a cold read comes off the card and holds the right block
        do_op(0, 5);
        expect_buffer(5, 0);
        if (failures == 0) $display("ok: block 5 read from the card holds block 5's data");

        // ---- and a second read of it does not touch the card at all
        reads_before = card.reads_done;
        do_op(0, 5);
        expect_buffer(5, 0);
        if (card.reads_done != reads_before)
            $display("FAIL: the second read of block 5 went to the card %0d more time(s)",
                     card.reads_done - reads_before);
        else
            $display("ok: the second read of block 5 was served from PSRAM, card untouched");
        if (img_hits != 1) begin
            $display("FAIL: the cache reports %0d hits, not 1", img_hits);
            failures = failures + 1;
        end

        // ---- a different block still goes to the card
        reads_before = card.reads_done;
        do_op(0, 100);
        expect_buffer(100, 0);
        if (card.reads_done == reads_before) begin
            $display("FAIL: block 100 was never fetched but came back anyway");
            failures = failures + 1;
        end else
            $display("ok: block 100 is a miss and is fetched, so the cache is per block");

        // ---- write a block: PSRAM changes, the card does not
        for (i = 0; i < 512; i = i + 1) sector_buf[i] = expected(5, i, 77);
        do_op(1, 5);
        for (i = 0; i < 512; i = i + 1) sector_buf[i] = 8'hee;
        do_op(0, 5);
        expect_buffer(5, 77);
        if (failures == 0) $display("ok: a written block reads back changed");
        if (card.writes_done != 0) begin
            $display("FAIL: %0d card writes happened before any flush", card.writes_done);
            failures = failures + 1;
        end else
            $display("ok: nothing has been written to the card yet");

        // ---- flush, and the card now holds it at the right LBA
        @(negedge clock); do_flush = 1;
        while (!img_busy) @(posedge clock);
        @(negedge clock); do_flush = 0;
        countdown = 20_000_000;
        while (img_busy && countdown != 0) begin @(posedge clock); countdown = countdown - 1; end
        if (img_busy) begin
            $display("FAIL: the flush never finished (state %0d)", img_state);
            $finish;
        end
        $display("ok: flushed, %0d block(s) written back", img_writebacks);
        if (img_writebacks != 1) begin
            $display("FAIL: one block was dirty but %0d were written back", img_writebacks);
            failures = failures + 1;
        end

        // Where block 5 really lives - which for the fragmented image is not
        // where arithmetic on the first LBA would put it.
        @(negedge clock);
        wrong = 0;
        for (i = 0; i < 512; i = i + 1)
            if (card.mem[block5_lba * 512 + i] !== expected(5, i, 77)) wrong = wrong + 1;
        if (wrong == 0)
            $display("ok: the card holds the new block 5 at LBA %0d", block5_lba);
        else begin
            $display("FAIL: %0d of 512 bytes at LBA %0d are not the written block",
                     wrong, block5_lba);
            failures = failures + 1;
        end

        $display("cache: %0d fetches, %0d hits, %0d write backs; card: %0d reads, %0d writes",
                 img_fetches, img_hits, img_writebacks, card.reads_done, card.writes_done);
        if (failures == 0) $display("ok: the SD card, FAT32 and the PSRAM cache work together");
        else $display("FAIL: %0d checks failed", failures);
        $finish;
    end

    initial begin
        #4_000_000_000;
        $display("FAIL: the disk test did not finish; image state %0d, card state %0d",
                 img_state, sd_state);
        $finish;
    end
endmodule

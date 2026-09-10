`timescale 1 ns/10 ps
`include "SdSpi.v"
`include "SdCardModel.v"
`include "Fat32.v"

/**
 * The FAT32 reader, against a volume made by mkfs.vfat and mcopy.
 *
 * Building the test image with the real tools rather than by hand is the point:
 * the parser is judged against what a card formatted on a PC genuinely looks
 * like, not against my own reading of the specification. That image has an MBR
 * with a type 0x0c partition at LBA 2048, two FATs of 1009 sectors, a volume
 * label entry sitting in front of the file in the root directory, and HAWK0.IMG
 * at cluster 3 running contiguously to cluster 130.
 *
 * The file's contents encode their own block number, so this can check not just
 * that the extents look plausible but that block N of the file really does
 * resolve to a sector holding block N.
 *
 * "make fat32test"
 */
module Fat32TB;
    reg clock = 0;
    always #18.5185 clock = ~clock;
    reg reset = 1;

    wire sd_clk, sd_mosi, sd_cs_n;
    wire sd_miso;
    pullup(sd_miso);

    wire fat_read;
    wire [31:0] fat_block;
    wire busy, ready, error;
    wire rx_strobe, tx_request;
    wire [8:0] rx_index, tx_index;
    wire [7:0] rx_byte;
    wire [7:0] dbg_state, dbg_r1, fat_state, fat_extents;
    wire fat_fallback;
    wire dbg_block_addressing;

    // The parser never writes, so the transmit side is unused.
    wire [7:0] tx_byte = 8'hff;

    // A direct read port for the testbench's own checking, muxed in front of the
    // parser so both can drive the card.
    reg tb_read = 0;
    reg [31:0] tb_block = 0;
    wire sd_read_w = fat_read | tb_read;
    wire [31:0] sd_block_w = tb_read ? tb_block : fat_block;

    SdSpi sd(clock, reset, sd_clk, sd_mosi, sd_miso, sd_cs_n,
             sd_read_w, 1'b0, sd_block_w, busy, ready, error,
             rx_strobe, rx_index, rx_byte, tx_request, tx_index, tx_byte,
             dbg_state, dbg_r1, dbg_block_addressing);

    // +image= picks the volume, so the same testbench runs against the
    // contiguous image and the deliberately fragmented one.
    reg [8*64:1] image_file;
    initial if (!$value$plusargs("image=%s", image_file)) image_file = "sd_fat32.hex";
    SdCardModel #(.BLOCKS(133120), .FILL(8'h00)) card(
        sd_clk, sd_cs_n, sd_mosi, sd_miso);
    initial #1 $readmemh(image_file, card.mem);

    reg mount = 0;
    wire mounted, failed;
    wire [3:0] fail_reason;
    wire [15:0] file_blocks;
    reg map_req = 0;
    reg [15:0] map_block = 0;
    wire map_valid;
    wire [31:0] map_lba;

    Fat32 #(.FILENAME("HAWK0   IMG")) fat(
        clock, reset, mount, mounted, failed, fail_reason,
        fat_read, fat_block, busy, ready, error,
        rx_strobe, rx_index, rx_byte,
        file_blocks, map_req, map_block, map_valid, map_lba,
        fat_state, fat_extents, fat_fallback);

    reg [7:0] buffer [0:511];
    reg tb_read_active = 0;
    always @(posedge clock) if (rx_strobe && tb_read_active) buffer[rx_index] <= rx_byte;

    reg [7:0] last_fs = 8'hff;
    always @(posedge clock) if ($test$plusargs("fattrace") && fat_state !== last_fs) begin
        $display("%0t fat state %0d -> %0d (part_lba=%0d fat0=%0d data0=%0d spc=%0d found=%b want=%0d n_ext=%0d)",
                 $time, last_fs, fat_state, fat.part_lba, fat.fat0, fat.data0,
                 fat.spc, fat.found, fat.want, fat.n_extents);
        last_fs <= fat_state;
    end

    integer failures = 0;
    integer i, wrong, countdown;

    task check_block(input [31:0] n);
        begin
            @(negedge clock);
            map_req = 1; map_block = n;
            @(negedge clock);
            map_req = 0;
            countdown = 100;
            while (!map_valid && countdown != 0) begin @(posedge clock); countdown = countdown - 1; end
            if (!map_valid) begin
                $display("FAIL: block %0d of the file did not map to an LBA", n);
                failures = failures + 1;
            end else begin
                @(negedge clock);
                tb_block = map_lba; tb_read_active = 1; tb_read = 1;
                while (!busy) @(posedge clock);
                @(negedge clock);
                tb_read = 0;
                while (busy) @(posedge clock);
                tb_read_active = 0;
                wrong = 0;
                for (i = 0; i < 512; i = i + 1)
                    if (buffer[i] !== ((n * 13 + i) & 8'hff)) wrong = wrong + 1;
                if (wrong == 0)
                    $display("ok: block %0d of the file is at LBA %0d and holds block %0d's data",
                             n, map_lba, n);
                else begin
                    $display("FAIL: block %0d mapped to LBA %0d but %0d of 512 bytes are not block %0d's",
                             n, map_lba, wrong, n);
                    failures = failures + 1;
                end
            end
        end
    endtask

    initial begin
        repeat (20) @(posedge clock);
        reset = 0;
        countdown = 2_000_000;
        while (!ready && countdown != 0) begin @(posedge clock); countdown = countdown - 1; end
        if (!ready) begin $display("FAIL: the card never initialised"); $finish; end

        @(negedge clock);
        mount = 1;
        @(negedge clock);
        mount = 0;
        countdown = 20_000_000;
        while (!mounted && !failed && countdown != 0) begin
            @(posedge clock); countdown = countdown - 1;
        end
        if (failed) begin
            $display("FAIL: mount failed, reason %0d (state %0d)", fail_reason, fat_state);
            $finish;
        end
        if (!mounted) begin
            $display("FAIL: mount never finished, parser state %0d, card state %0d",
                     fat_state, dbg_state);
            $finish;
        end
        $display("ok: mounted %0s - %0d blocks in %0d extent%0s",
                 fat_fallback ? "the only file in the root" : "HAWK0.IMG",
                 file_blocks, fat_extents, fat_extents == 1 ? "" : "s");
        // A long named file is stored under a generated 8.3 alias, so the
        // configured name cannot match and the fallback is the only way in.
        if ($test$plusargs("longname") && !fat_fallback) begin
            $display("FAIL: the long named image was matched by name, so the fallback was not tested");
            failures = failures + 1;
        end
        if (!$test$plusargs("longname") && fat_fallback) begin
            $display("FAIL: HAWK0.IMG is present by name but the fallback was used");
            failures = failures + 1;
        end

        if (file_blocks !== 128) begin
            $display("FAIL: the file is %0d blocks, not the 128 that were copied in", file_blocks);
            failures = failures + 1;
        end
        // The contiguous image must come back as exactly one extent; the
        // fragmented one must come back as more than one, or the fragmented
        // case is not being tested at all and the run proves nothing.
        if ($test$plusargs("fragmented")) begin
            if (fat_extents < 2) begin
                $display("FAIL: the fragmented image resolved to %0d extent(s), so nothing was tested",
                         fat_extents);
                failures = failures + 1;
            end
        end else if (fat_extents !== 1) begin
            $display("FAIL: a freshly copied file should be one extent, not %0d", fat_extents);
            failures = failures + 1;
        end

        // The first, a middle one, and the last: an off by one in the extent
        // arithmetic shows up at the ends, a wrong base everywhere.
        check_block(0);
        check_block(1);
        check_block(64);
        check_block(127);

        // One past the end must be refused rather than read as something.
        @(negedge clock);
        map_req = 1; map_block = 128;
        @(negedge clock);
        map_req = 0;
        countdown = 100;
        while (countdown != 0) begin @(posedge clock); countdown = countdown - 1; end
        if (map_valid) begin
            $display("FAIL: block 128 is past the end of a 128 block file but mapped to LBA %0d", map_lba);
            failures = failures + 1;
        end else
            $display("ok: a block past the end of the file is refused");

        $display("card: %0d reads, %0d commands rejected", card.reads_done, card.failed_commands);
        if (failures == 0) $display("ok: FAT32 mount and block mapping work");
        else $display("FAIL: %0d checks failed", failures);
        $finish;
    end

    initial begin
        #2_000_000_000;
        $display("FAIL: the FAT32 test did not finish; parser state %0d", fat_state);
        $finish;
    end
endmodule

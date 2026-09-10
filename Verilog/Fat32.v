/*
 * A FAT32 reader that runs once, at mount time, and then gets out of the way.
 *
 * The observation the whole design rests on: **use the filesystem to locate the
 * file, then stop using it.** This walks MBR to partition to boot sector to root
 * directory, finds an image by its 8.3 name and follows its cluster chain, and
 * turns the result into a short table of extents - a base LBA and a length. From
 * that moment on every access is a raw block number and no filesystem structure
 * is touched again.
 *
 * That is what makes writes work in place. The image file never changes length,
 * so the FAT and the directory entry never need updating, and cluster
 * allocation, chain maintenance, directory updates, free space accounting and
 * all the crash consistency problems that come with them simply do not arise.
 * The card's metadata is read once and is thereafter read only. Nothing in here
 * can write to the card.
 *
 * It is a *streaming* parser: it never buffers a sector. Every field it wants is
 * at a known offset, so it picks bytes out of the byte stream as they go past
 * and keeps only the handful of values that matter. That costs no block RAM at
 * all, which on this device is the resource with the disk controllers still to
 * come.
 *
 * Following the chain streams too. When the successor of the cluster being
 * looked up lies in the FAT sector already going past, it is picked up in the
 * same pass - so a contiguous file, which is what a freshly copied image is,
 * costs one FAT sector read per 128 clusters instead of one per cluster. The
 * 128 cluster test image needs two.
 *
 * Deliberately not supported, per the design note: long file names (every long
 * named file has a short alias, so the entries are skipped), FAT16 and FAT12,
 * and exFAT, which is a substantially bigger job - the answer there is to tell
 * the user to format the card FAT32. A card with no MBR signature is reported as
 * such rather than guessed at.
 */
module Fat32 #(
    // The 8.3 name to look for, padded to eleven characters exactly as it is
    // stored in the directory: name left justified in eight, extension in three.
    parameter [87:0] FILENAME = "HAWK0   IMG",
    parameter integer MAX_EXTENTS = 16
) (
    input wire clock,
    input wire reset,

    input wire start,                   // pulse to mount
    output reg mounted,
    output reg failed,
    output reg [3:0] fail_reason,

    // The card, driven through SdSpi.
    output reg sd_read,
    output reg [31:0] sd_block,
    input wire sd_busy,
    input wire sd_ready,
    input wire sd_error,
    input wire rx_strobe,
    input wire [8:0] rx_index,
    input wire [7:0] rx_byte,

    // The answer: how big the file is, and where any block of it lives.
    output reg [31:0] file_blocks,
    input wire map_req,
    input wire [31:0] map_block,
    output reg map_valid,
    output reg [31:0] map_lba,

    output wire [7:0] dbg_state,
    output reg [7:0] dbg_extents
);
    localparam [3:0]
        FAIL_NONE = 0, FAIL_NO_MBR = 1, FAIL_NO_PARTITION = 2, FAIL_NOT_FAT32 = 3,
        FAIL_SECTOR_SIZE = 4, FAIL_NO_FILE = 5, FAIL_TOO_FRAGMENTED = 6,
        FAIL_CARD = 7, FAIL_EMPTY_FILE = 8;

    localparam [7:0]
        S_IDLE = 0, S_READ = 1, S_WAIT = 2, S_MBR = 3, S_BPB = 4,
        S_DIR = 5, S_DIR_NEXT = 6, S_CHAIN = 7, S_CHAIN_STEP = 8,
        S_DONE = 9, S_FAILED = 10, S_MAP = 11, S_DIR_ADVANCE = 12;

    reg [7:0] state, after_read;
    assign dbg_state = state;

    // Volume geometry, all of it from the BPB.
    reg [31:0] part_lba, fat0, data0, fat_sectors;
    reg [7:0]  spc;                     // sectors per cluster, a power of two
    reg [2:0]  spc_log2;
    reg [7:0]  num_fats;
    reg [15:0] reserved, bytes_per_sector;
    reg [31:0] root_cluster;

    // Scratch for the field being assembled out of the stream.
    reg [31:0] acc;
    reg part_found;
    reg pe_take;
    wire [3:0] pe_off = rx_index[3:0] - 4'd14;   // the entries start at 446

    // Directory scan.
    reg name_ok, dir_end, found;
    reg [31:0] found_cluster, found_size;
    reg [31:0] dir_cluster;
    reg [7:0]  dir_sector;              // which sector within the cluster

    // Chain walking. want is the cluster whose successor we are after; the
    // parser updates it in place as the FAT sector streams by, so a run of
    // consecutive clusters is followed without reading the sector again.
    reg [31:0] want;
    reg chain_done;                     // the chain genuinely ended
    reg chain_halt;                     // stop following within this sector
    reg [7:0] chain_return;
    // What the sector being read is being read *for*. This used to be inferred
    // from after_read, which had to mean two things at once.
    reg [7:0] parse_mode;
    // A corrupt FAT can point a cluster at itself. Nothing else bounds the walk.
    reg [31:0] steps;
    localparam integer MAX_STEPS = 1 << 20;

    // Extents.
    reg [31:0] ext_lba  [0:MAX_EXTENTS-1];
    reg [31:0] ext_len  [0:MAX_EXTENTS-1];
    reg [7:0]  n_extents;
    reg [31:0] run_start, run_len, run_first_cluster;

    // Map lookup: walk the table an entry per clock. This only happens once per
    // block moved, against a transfer that takes thousands of clocks, so a
    // sequential walk costs nothing and saves a sixteen way comparator.
    reg [7:0] map_i;
    reg [31:0] map_left;

    integer e;

    function [7:0] name_byte(input [3:0] i);
        name_byte = FILENAME >> (8 * (10 - i));
    endfunction

    // cluster -> LBA. spc is a power of two so this is a shift.
    function [31:0] cluster_lba(input [31:0] c);
        cluster_lba = data0 + ((c - 32'd2) << spc_log2);
    endfunction

    initial begin
        state = S_IDLE; mounted = 0; failed = 0; fail_reason = FAIL_NONE;
        sd_read = 0; sd_block = 0; file_blocks = 0; map_valid = 0; map_lba = 0;
        n_extents = 0; dbg_extents = 0;
    end

    always @(posedge clock) begin
        sd_read <= 0;
        if (reset) begin
            state <= S_IDLE;
            mounted <= 0; failed <= 0; fail_reason <= FAIL_NONE;
            n_extents <= 0; file_blocks <= 0; map_valid <= 0;
            dbg_extents <= 0;
        end else case (state)

        S_IDLE: begin
            map_valid <= 0;
            if (start && sd_ready) begin
                mounted <= 0; failed <= 0; fail_reason <= FAIL_NONE;
                part_found <= 0; found <= 0; n_extents <= 0;
                acc <= 0;
                sd_block <= 0;
                after_read <= S_MBR;
                parse_mode <= S_MBR;
                steps <= 0;
                state <= S_READ;
            end else if (map_req && mounted) begin
                map_i <= 0;
                map_left <= map_block;
                map_valid <= 0;
                state <= S_MAP;
            end
        end

        // ------------------------------------------------------- read a sector
        S_READ: begin
            sd_read <= 1;
            if (sd_busy) begin
                sd_read <= 0;
                state <= S_WAIT;
            end
        end

        S_WAIT: if (!sd_busy) begin
            if (sd_error) begin
                fail_reason <= FAIL_CARD;
                state <= S_FAILED;
            end else state <= after_read;
        end

        // -------------------------------------------------------------- MBR
        // Signature at 510, then four sixteen byte partition entries from 446.
        // The first FAT32 LBA entry - type 0x0b or 0x0c - wins.
        S_MBR: begin
            if (!part_found) begin
                // Do not overwrite a missing signature, which is the more
                // specific and more useful answer.
                if (fail_reason == FAIL_NONE) fail_reason <= FAIL_NO_PARTITION;
                state <= S_FAILED;
            end else begin
                sd_block <= part_lba;
                after_read <= S_BPB;
                parse_mode <= S_BPB;
                state <= S_READ;
            end
        end

        // -------------------------------------------------------------- BPB
        S_BPB: begin
            if (bytes_per_sector != 512) begin
                fail_reason <= FAIL_SECTOR_SIZE;
                state <= S_FAILED;
            end else if (fat_sectors == 0 || spc == 0) begin
                // A zero 32 bit FAT size means FAT12 or FAT16, whose layout is
                // different enough that guessing would be worse than refusing.
                fail_reason <= FAIL_NOT_FAT32;
                state <= S_FAILED;
            end else begin
                fat0 <= part_lba + reserved;
                data0 <= part_lba + reserved + num_fats * fat_sectors;
                dir_cluster <= root_cluster;
                dir_sector <= 0;
                state <= S_DIR_NEXT;
            end
        end

        // ------------------------------------------------- the root directory
        S_DIR_NEXT: begin
            sd_block <= cluster_lba(dir_cluster) + dir_sector;
            after_read <= S_DIR;
            parse_mode <= S_DIR;
            name_ok <= 0; dir_end <= 0;
            state <= S_READ;
        end

        S_DIR: begin
            if (found) begin
                if (found_size == 0) begin
                    fail_reason <= FAIL_EMPTY_FILE;
                    state <= S_FAILED;
                end else begin
                    // Start the chain walk at the file's first cluster.
                    want <= found_cluster;
                    run_start <= cluster_lba(found_cluster);
                    run_len <= spc;
                    n_extents <= 0;
                    chain_return <= S_CHAIN_STEP;
                    state <= S_CHAIN;
                end
            end else if (dir_end) begin
                fail_reason <= FAIL_NO_FILE;
                state <= S_FAILED;
            end else if (dir_sector + 1 < spc) begin
                dir_sector <= dir_sector + 1;
                state <= S_DIR_NEXT;
            end else begin
                // On to the next cluster of the root directory, which needs the
                // FAT, so borrow the chain walker.
                want <= dir_cluster;
                chain_return <= S_DIR_ADVANCE;
                state <= S_CHAIN;
            end
        end

        // ------------------------------------------------- follow the chain
        // Read the FAT sector holding want's entry. While it streams past, any
        // successor that also lives in this sector is picked up in the same
        // pass, so a contiguous run costs one read per 128 clusters.
        // Read the FAT sector holding want's entry. The parser follows as far
        // through that sector as it can, updating want and the run as it goes,
        // so a contiguous file costs one read per 128 clusters rather than one
        // per cluster: the 128 cluster test image needs two.
        S_CHAIN: begin
            sd_block <= fat0 + want[31:7];
            after_read <= chain_return;
            parse_mode <= S_CHAIN;
            chain_done <= 0;
            chain_halt <= 0;
            state <= S_READ;
        end

        // The sector ran out. Either the chain ended in it, or want now names a
        // cluster whose entry is somewhere else, so go round again.
        S_CHAIN_STEP:
            if (chain_done) state <= S_DONE;
            else if (steps > MAX_STEPS) begin
                fail_reason <= FAIL_TOO_FRAGMENTED;
                state <= S_FAILED;
            end else state <= S_CHAIN;

        // The same, for walking the root directory's own chain.
        S_DIR_ADVANCE:
            if (chain_done) begin
                fail_reason <= FAIL_NO_FILE;   // ran out of directory
                state <= S_FAILED;
            end else begin
                dir_cluster <= want;
                dir_sector <= 0;
                state <= S_DIR_NEXT;
            end

        S_DONE: begin
            // Close the run that was still open, and clamp to the file's real
            // length: the last cluster is usually only partly used.
            if (n_extents < MAX_EXTENTS) begin
                ext_lba[n_extents] <= run_start;
                ext_len[n_extents] <= run_len;
                n_extents <= n_extents + 1;
                dbg_extents <= n_extents + 1;
                file_blocks <= found_size[31:9] + (found_size[8:0] != 0);
                mounted <= 1;
                state <= S_IDLE;
            end else begin
                fail_reason <= FAIL_TOO_FRAGMENTED;
                state <= S_FAILED;
            end
        end

        S_FAILED: begin
            failed <= 1;
            mounted <= 0;
            state <= S_IDLE;
        end

        // ------------------------------------------------------ block -> LBA
        S_MAP: begin
            if (map_i >= n_extents) begin
                map_valid <= 0;             // past the end of the file
                state <= S_IDLE;
            end else if (map_left < ext_len[map_i]) begin
                map_lba <= ext_lba[map_i] + map_left;
                map_valid <= 1;
                state <= S_IDLE;
            end else begin
                map_left <= map_left - ext_len[map_i];
                map_i <= map_i + 1;
            end
        end

        default: state <= S_FAILED;
        endcase

        // ------------------------------------------------ the streaming parser
        // Everything above decides what to read; this pulls the fields out of
        // the bytes as they arrive, which is why no sector is ever buffered.
        if (rx_strobe) case (parse_mode)
        S_MBR: begin
            if (rx_index == 510 && rx_byte != 8'h55) begin
                part_found <= 0;
                fail_reason <= FAIL_NO_MBR;
            end
            if (rx_index >= 446 && rx_index < 510) begin
                if (pe_off[3:0] == 4 && !part_found &&
                    (rx_byte == 8'h0b || rx_byte == 8'h0c)) pe_take <= 1;
                if (pe_off[3:0] == 8  && pe_take) acc[7:0]   <= rx_byte;
                if (pe_off[3:0] == 9  && pe_take) acc[15:8]  <= rx_byte;
                if (pe_off[3:0] == 10 && pe_take) acc[23:16] <= rx_byte;
                if (pe_off[3:0] == 11 && pe_take) begin
                    part_lba <= { rx_byte, acc[23:0] };
                    part_found <= 1;
                    pe_take <= 0;
                end
                if (pe_off[3:0] == 15) pe_take <= 0;
            end
        end

        S_BPB: begin
            case (rx_index)
                11: bytes_per_sector[7:0]  <= rx_byte;
                12: bytes_per_sector[15:8] <= rx_byte;
                13: begin
                    spc <= rx_byte;
                    // log2 of a power of two, which is what sectors per cluster
                    // always is.
                    spc_log2 <= rx_byte[7] ? 3'd7 : rx_byte[6] ? 3'd6 :
                                rx_byte[5] ? 3'd5 : rx_byte[4] ? 3'd4 :
                                rx_byte[3] ? 3'd3 : rx_byte[2] ? 3'd2 :
                                rx_byte[1] ? 3'd1 : 3'd0;
                end
                14: reserved[7:0]  <= rx_byte;
                15: reserved[15:8] <= rx_byte;
                16: num_fats <= rx_byte;
                36: fat_sectors[7:0]   <= rx_byte;
                37: fat_sectors[15:8]  <= rx_byte;
                38: fat_sectors[23:16] <= rx_byte;
                39: fat_sectors[31:24] <= rx_byte;
                44: root_cluster[7:0]   <= rx_byte;
                45: root_cluster[15:8]  <= rx_byte;
                46: root_cluster[23:16] <= rx_byte;
                47: root_cluster[31:24] <= rx_byte;
                default: ;
            endcase
        end

        S_DIR: if (!found) begin
            // Sixteen thirty two byte entries. A zero first byte ends the
            // directory; 0xe5 is a deleted entry; attribute 0x0f is a long name
            // fragment and bit 3 is the volume label, and both are skipped.
            case (rx_index[4:0])
                0: begin
                    name_ok <= (rx_byte == name_byte(0));
                    if (rx_byte == 0) dir_end <= 1;
                end
                11: begin
                    if (rx_byte[3] || rx_byte == 8'h0f) name_ok <= 0;
                end
                20: acc[23:16] <= rx_byte;
                21: acc[31:24] <= rx_byte;
                26: acc[7:0]  <= rx_byte;
                27: acc[15:8] <= rx_byte;
                28: found_size[7:0]   <= rx_byte;
                29: found_size[15:8]  <= rx_byte;
                30: found_size[23:16] <= rx_byte;
                31: begin
                    found_size[31:24] <= rx_byte;
                    if (name_ok) begin
                        found_cluster <= acc;
                        found <= 1;
                    end
                end
                default:
                    if (rx_index[4:0] < 11)
                        name_ok <= name_ok && (rx_byte == name_byte(rx_index[3:0]));
            endcase
        end

        // A FAT sector going past. Entries arrive in increasing order, so once
        // want's successor is known and it lies later in this same sector - which
        // is exactly the contiguous case - the walk simply continues here.
        S_CHAIN: if (!chain_done && !chain_halt && rx_index[8:2] == want[6:0]) begin
            case (rx_index[1:0])
                0: acc[7:0]   <= rx_byte;
                1: acc[15:8]  <= rx_byte;
                2: acc[23:16] <= rx_byte;
                3: follow({ 4'b0, rx_byte[3:0], acc[23:0] });
            endcase
        end
        default: ;
        endcase
    end

    // One step of the chain. Extends the current run of consecutive clusters, or
    // closes it and opens another, and leaves `want' naming the cluster whose
    // entry is wanted next - which the caller either finds later in this same
    // sector or reads.
    task follow(input [31:0] nxt);
        begin
            steps <= steps + 1;
            if (nxt >= 32'h0ffffff8 || nxt < 2) begin
                chain_done <= 1;
            end else begin
                want <= nxt;
                if (chain_return == S_CHAIN_STEP) begin
                    if (nxt == want + 1) run_len <= run_len + spc;
                    else begin
                        if (n_extents < MAX_EXTENTS) begin
                            ext_lba[n_extents] <= run_start;
                            ext_len[n_extents] <= run_len;
                            n_extents <= n_extents + 1;
                        end
                        run_start <= cluster_lba(nxt);
                        run_len <= spc;
                    end
                end else begin
                    // Walking the root directory's chain: take exactly one step
                    // and stop, because the caller goes back to scanning
                    // directory entries with it rather than building a run.
                    chain_halt <= 1;
                end
            end
        end
    endtask
endmodule

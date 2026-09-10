/*
 * A disk image on the SD card, cached in PSRAM.
 *
 * This is the seam the SD design note calls BlockStore: everything above it
 * addresses blocks within an image, everything below addresses blocks on a card.
 * Fat32.v turns a file name into extents at mount time and this turns a block
 * number into bytes, and neither touches a filesystem structure again.
 *
 * Why cache in PSRAM at all. An SD card is not a disk: a 512 byte read is
 * usually well under a millisecond, but a card can stall for a hundred
 * milliseconds or more doing its own internal housekeeping, at a moment of its
 * choosing, and a controller model with realistic timeouts will not tolerate
 * that in the middle of a transfer. PSRAM never does it. The throughput argument
 * is much weaker and worth stating honestly - a block is about 210us out of
 * PSRAM against about 350us off the card - so the real reason is predictability.
 * Both are already faster than the millisecond a real Hawk takes to bring a
 * sector round.
 *
 * The image lives above the CPU's own memory. The MMU's physical address is
 * eighteen bits, so the machine can only reach the bottom 256K of an 8MB part;
 * everything from 0x40000 up is unreachable by any program and free for this. A
 * whole Hawk platter - 400 cylinders, two heads, sixteen sectors at a 512 byte
 * stride - is 6.55MB and fits.
 *
 * Blocks are demand paged rather than loaded in one go: a platter would be 12800
 * card reads and four and a half seconds before the machine could do anything.
 * Two bits per block say whether PSRAM holds it and whether the card is behind.
 *
 * Those two bits have to live in a block RAM with a *synchronous* read. As a
 * plain register array they are 25600 flip flops on a device that has 6480, and
 * an asynchronous read forces exactly that or an equally impossible amount of
 * LUTRAM. Hence the explicit look-up state.
 */
module DiskImage #(
    // Above the 256K the CPU can address, and sized for a Hawk platter.
    parameter [22:0] IMAGE_BASE = 23'h040000,
    parameter integer MAX_BLOCKS = 12800,
    parameter integer META_BITS = 14        // $clog2(MAX_BLOCKS) rounded up
) (
    input wire clock,
    input wire reset,

    // The mounter.
    input wire mounted,
    // Blocks in the image. Sixteen bits is a 32MB image, which covers every
    // drive this machine had - a Hawk platter is 12800 blocks.
    input wire [15:0] file_blocks,
    output reg map_req,
    output reg [15:0] map_block,
    input wire map_valid,
    input wire [31:0] map_lba,

    // The card.
    output reg sd_read,
    output reg sd_write,
    output wire [31:0] sd_block,
    input wire sd_busy,
    input wire sd_error,
    input wire rx_strobe,
    input wire [8:0] rx_index,
    input wire [7:0] rx_byte,
    input wire tx_request,
    input wire [8:0] tx_index,
    output wire [7:0] tx_byte,

    // The PSRAM, through the arbiter the CPU's bridge also goes through.
    output reg ps_read,
    output reg ps_write,
    output reg ps_byte_write,
    output reg [22:0] ps_addr,
    output reg [15:0] ps_din,
    input wire [63:0] ps_dout,
    input wire ps_busy,

    // The controller: raise req with a block number. store writes the buffer
    // back into the image, otherwise the block is brought into the buffer.
    input wire req,
    input wire req_store,
    input wire [15:0] req_block,
    output reg busy,
    output reg failed,

    // The controller's sector buffer. buf_addr is driven from here throughout,
    // and buf_rdata is that buffer's registered read - one clock behind.
    output reg buf_wr,
    output reg [8:0] buf_addr,
    output reg [7:0] buf_wdata,
    input wire [7:0] buf_rdata,

    // Push every dirty block back to the card.
    input wire flush,
    output reg flushing,

    output wire [7:0] dbg_state,
    output reg [15:0] dbg_fetches,
    output reg [15:0] dbg_hits,
    output reg [15:0] dbg_writebacks
);
    localparam [7:0]
        S_CLEAR   = 0,
        S_IDLE    = 1,
        S_LOOKUP  = 2,  S_LOOKUP2 = 3,
        S_MAP     = 4,
        S_CARD_RD = 5,  S_CARD_RD_W = 6,
        // buffer -> PSRAM, a sixteen bit word at a time
        S_FILL_A  = 7,  S_FILL_LO = 8, S_FILL_HI = 9, S_FILL_W = 10,
        S_FILL_GO = 20,
        // PSRAM -> buffer, eight bytes per burst
        S_DRAW    = 11, S_DRAW_W = 12, S_DRAIN = 13,
        S_CARD_WR = 14, S_CARD_WR_W = 15,
        S_SCAN    = 16, S_SCAN_W = 21, S_SCAN2 = 17,
        S_DONE    = 18, S_FAIL = 19;

    reg [7:0] state, after_fill, after_drain;
    assign dbg_state = state;

    // present in bit 0, dirty in bit 1.
    reg [1:0] meta [0:MAX_BLOCKS-1];
    reg [1:0] meta_q;
    reg meta_wr;
    reg [1:0] meta_wdata;
    reg [META_BITS-1:0] meta_addr;
    always @(posedge clock) begin
        if (meta_wr) meta[meta_addr] <= meta_wdata;
        meta_q <= meta[meta_addr];
    end

    // Card block numbers are 26 bits here as in Fat32 - a 32GB card - because
    // every adder and comparator in this module is one of them.
    localparam integer LBA = 26;
    reg [15:0] block;
    reg [9:0]  index;               // 0..512, so ten bits
    reg [7:0]  lo_byte;
    // Fat32 answers with map_valid high for exactly one clock, and the flush
    // path issues its request before a PSRAM read that takes hundreds of
    // microseconds - so the answer arrives long before anything is waiting for
    // it. Latch it wherever we are and let S_MAP wait on the latch.
    reg [LBA-1:0] lba;
    reg lba_valid;
    reg [15:0] map_timer;
    reg [7:0]  hold [0:7];
    reg [2:0]  hold_i;
    reg [META_BITS-1:0] scan;
    reg storing;                    // this pass is a write, not a read
    reg [15:0] clear_i;

    assign tx_byte = buf_rdata;
    // The card interface is 32 bits wide because a card can be; everything in
    // here is narrower, so widen on the way out.
    assign sd_block = { {(32-LBA){1'b0}}, lba };
    wire [22:0] block_base = IMAGE_BASE + { block, 9'b0 };

    integer i;
    initial begin
        state = S_CLEAR; busy = 1; failed = 0; flushing = 0;
        sd_read = 0; sd_write = 0; ps_read = 0; ps_write = 0; ps_byte_write = 0;
        map_req = 0; buf_wr = 0; meta_wr = 0; clear_i = 0;
        dbg_fetches = 0; dbg_hits = 0; dbg_writebacks = 0;
        for (i = 0; i < MAX_BLOCKS; i = i + 1) meta[i] = 2'b00;
    end

    always @(posedge clock) begin
        buf_wr <= 0;
        map_req <= 0;
        meta_wr <= 0;

        if (reset) begin
            state <= S_CLEAR; clear_i <= 0;
            busy <= 1; failed <= 0; flushing <= 0;
            sd_read <= 0; sd_write <= 0; ps_read <= 0; ps_write <= 0;
            dbg_fetches <= 0; dbg_hits <= 0; dbg_writebacks <= 0;
        end else case (state)

        // Nothing else can clear a block RAM, and a reset that leaves the
        // metadata behind would serve the previous image's blocks. This costs
        // 12800 clocks, half a millisecond, inside the part's own 300us wake up.
        S_CLEAR: begin
            meta_addr <= clear_i[META_BITS-1:0];
            meta_wdata <= 2'b00;
            meta_wr <= 1;
            if (clear_i == MAX_BLOCKS - 1) begin
                busy <= 0;
                state <= S_IDLE;
            end else clear_i <= clear_i + 1;
        end

        S_IDLE: begin
            busy <= 0;
            if (req && mounted && req_block >= file_blocks) begin
                // Past the end of the image. Saying so at once beats waiting out
                // the map timeout for an answer that is never coming.
                busy <= 1;
                failed <= 1;
                state <= S_FAIL;
            end else if (req && mounted) begin
                busy <= 1;
                failed <= 0;
                block <= req_block;
                storing <= req_store;
                meta_addr <= req_block[META_BITS-1:0];
                state <= S_LOOKUP;
            end else if (flush && mounted) begin
                busy <= 1;
                flushing <= 1;
                scan <= 0;
                state <= S_SCAN;
            end
        end

        // meta_q is one clock behind meta_addr.
        S_LOOKUP: state <= S_LOOKUP2;

        S_LOOKUP2: begin
            index <= 0;
            if (storing) begin
                // A write never needs the card: into PSRAM, and mark it dirty.
                after_fill <= S_DONE;
                buf_addr <= 0;
                state <= S_FILL_A;
            end else if (meta_q[0]) begin
                dbg_hits <= dbg_hits + 1;
                after_drain <= S_DONE;
                state <= S_DRAW;
            end else begin
                dbg_fetches <= dbg_fetches + 1;
                map_block <= block;
                map_req <= 1;
                lba_valid <= 0;
                map_timer <= 16'hffff;
                state <= S_MAP;
            end
        end

        // A block past the end of the file simply gets no answer, so the wait
        // is bounded rather than trusting the mounter to say so.
        S_MAP:
            if (lba_valid) state <= flushing ? S_CARD_WR : S_CARD_RD;
            else if (map_timer == 0) begin
                failed <= 1;
                state <= S_FAIL;
            end else map_timer <= map_timer - 1;

        // ------------------------------------------------ read from the card
        S_CARD_RD: begin
            sd_read <= 1;
            if (sd_busy) begin
                sd_read <= 0;
                state <= S_CARD_RD_W;
            end
        end

        // The bytes go straight into the controller's buffer as they arrive;
        // see the rx_strobe block below. Then copy the buffer into PSRAM so the
        // next read of this block does not need the card.
        S_CARD_RD_W: if (!sd_busy) begin
            if (sd_error) begin failed <= 1; state <= S_FAIL; end
            else begin
                index <= 0;
                buf_addr <= 0;
                after_fill <= S_DONE;
                state <= S_FILL_A;
            end
        end

        // ------------------------------------- the buffer into PSRAM, by words
        // Two bytes per access rather than one: a byte write costs a whole
        // access, so writing bytes would double an already slow copy.
        // buf_rdata is the buffer's *registered* output, so an address set this
        // clock is not readable until the clock after next: buf_q takes the old
        // buf_addr on the edge that loads the new one. Getting this wrong put
        // every even byte one place late, which reads as a plausible sector and
        // is only caught by contents that encode their own offset.
        S_FILL_A: begin
            buf_addr <= index[8:0];
            state <= S_FILL_LO;
        end

        S_FILL_LO: begin
            buf_addr <= index[8:0] + 9'd1;
            state <= S_FILL_HI;
        end

        S_FILL_HI: begin
            lo_byte <= buf_rdata;           // now this really is byte `index'
            state <= S_FILL_GO;
        end

        S_FILL_GO: begin
            ps_addr <= block_base + index;
            // The byte at the lower address goes in the *high* half of the
            // word: that is HyperBus's own order and it is what PsramBus's cache
            // already assumes. Reversing it here is invisible end to end,
            // because the read path would reverse it back, and only shows up
            // when something else looks at the image in memory.
            ps_din <= { lo_byte, buf_rdata };
            ps_byte_write <= 0;
            ps_write <= 1;
            if (ps_busy) begin
                ps_write <= 0;
                state <= S_FILL_W;
            end
        end

        S_FILL_W: if (!ps_busy) begin
            if (index >= 510) begin
                // present, and dirty only if this came from the controller
                // rather than from the card.
                meta_addr <= block[META_BITS-1:0];
                meta_wdata <= { storing, 1'b1 };
                meta_wr <= 1;
                state <= after_fill;
            end else begin
                index <= index + 2;
                state <= S_FILL_A;
            end
        end

        // ------------------------------------- PSRAM into the buffer, by bursts
        S_DRAW: begin
            ps_addr <= block_base + index;
            ps_read <= 1;
            if (ps_busy) begin
                ps_read <= 0;
                state <= S_DRAW_W;
            end
        end

        S_DRAW_W: if (!ps_busy) begin
            hold[0] <= ps_dout[15:8];  hold[1] <= ps_dout[7:0];
            hold[2] <= ps_dout[31:24]; hold[3] <= ps_dout[23:16];
            hold[4] <= ps_dout[47:40]; hold[5] <= ps_dout[39:32];
            hold[6] <= ps_dout[63:56]; hold[7] <= ps_dout[55:48];
            hold_i <= 0;
            state <= S_DRAIN;
        end

        S_DRAIN: begin
            buf_addr <= index[8:0] + { 6'b0, hold_i };
            buf_wdata <= hold[hold_i];
            buf_wr <= 1;
            if (hold_i == 7) begin
                if (index >= 504) state <= after_drain;
                else begin
                    index <= index + 8;
                    state <= S_DRAW;
                end
            end else hold_i <= hold_i + 1;
        end

        // ----------------------------------------------- write back to the card
        S_CARD_WR: begin
            sd_write <= 1;
            if (sd_busy) begin
                sd_write <= 0;
                state <= S_CARD_WR_W;
            end
        end

        S_CARD_WR_W: if (!sd_busy) begin
            if (sd_error) begin failed <= 1; state <= S_FAIL; end
            else begin
                dbg_writebacks <= dbg_writebacks + 1;
                meta_addr <= block[META_BITS-1:0];
                meta_wdata <= 2'b01;            // still present, no longer dirty
                meta_wr <= 1;
                scan <= scan + 1;
                state <= S_SCAN;
            end
        end

        // ---------------------------------------------------------- flushing
        S_SCAN:
            if (scan >= file_blocks[META_BITS-1:0] || scan >= MAX_BLOCKS - 1) begin
                flushing <= 0;
                busy <= 0;
                state <= S_IDLE;
            end else begin
                meta_addr <= scan;
                state <= S_SCAN_W;
            end

        // meta_q is one clock behind meta_addr, exactly as in S_LOOKUP. Without
        // this the scan reads the previous block's bits and flushes the wrong
        // sector - which lands real data at a real LBA and looks like a
        // corrupted image rather than a mis-timed read.
        S_SCAN_W: state <= S_SCAN2;

        S_SCAN2:
            if (!meta_q[1]) begin
                scan <= scan + 1;
                state <= S_SCAN;
            end else begin
                // Dirty: pull it out of PSRAM into the buffer, then send it.
                block <= scan;
                map_block <= { {(16-META_BITS){1'b0}}, scan };
                map_req <= 1;
                lba_valid <= 0;
                map_timer <= 16'hffff;
                index <= 0;
                after_drain <= S_MAP;
                state <= S_DRAW;
            end

        S_DONE: begin
            busy <= 0;
            state <= S_IDLE;
        end

        S_FAIL: begin
            busy <= 0;
            flushing <= 0;
            state <= S_IDLE;
        end

        default: state <= S_IDLE;
        endcase

        if (map_valid) begin
            lba <= map_lba[LBA-1:0];
            lba_valid <= 1;
        end

        // A card read streams straight into the controller's buffer.
        if (rx_strobe && state == S_CARD_RD_W) begin
            buf_addr <= rx_index;
            buf_wdata <= rx_byte;
            buf_wr <= 1;
        end

        // And a card write reads out of it: the card asks a byte ahead, and
        // tx_byte is the buffer's registered output, so it arrives in time.
        if (tx_request) buf_addr <= tx_index;
    end
endmodule

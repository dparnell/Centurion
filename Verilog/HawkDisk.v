/*
 * The CDC Hawk disk controller, as the Centurion sees it.
 *
 * This models the *controller board*, not the drive: the CPU sees the registers
 * the real board presents and this turns commands into DMA transfers. Emulating
 * drive level serial data would be a great deal of work to arrive at the same
 * place.
 *
 * The register map is from the Nakazoto archive's Drives/Hawk Drive/HawkMMIO.txt,
 * which is a dump of the real board's behaviour, cross checked against the DSK2
 * class in Meisaka's emulator. Where the two disagree it is noted below.
 *
 *   f140  unit select               f144  read status (error bits)
 *   f141  sector address high       f145  drive status
 *   f142  sector address low        f148  command on write, busy on read
 *   f143  write bit mask            f14c-f  interrupt control
 *
 * The sector address is packed 00CC CCCC CCCH SSSS - nine bits of cylinder, one
 * of head, four of sector - which for a 400 cylinder two platter drive with
 * sixteen 400 byte sectors per track is the whole 5MB. Taken as a flat number it
 * is also the sector index, so this design stores sectors at a stride of 512:
 * that wastes 112 bytes a sector and buys two things worth much more, an address
 * that is a shift rather than a multiply by 400, and one sector to one SD block
 * when the medium arrives, which is the sector size mismatch the SD design note
 * worried about simply not arising.
 *
 * The medium is a disk image on the SD card, cached in PSRAM - see DiskImage.v.
 * The controller asks for a sector before a read and hands one back after a
 * write, and holds the DMA still across a sector boundary while that happens.
 * With nothing mounted it falls back to serving reads out of its own sector
 * buffer and writes into it, which is what it did before there was a medium at
 * all and is still the honest behaviour of a drive with no cartridge in it.
 *
 * As in mux.v, the CPU side is gated by the CPU's clock enable, because a bus
 * write lasts several board clocks and would otherwise be seen several times;
 * the transfer and timing side runs off the board clock.
 */
module HawkDisk(
    input wire clock,
    input wire cpu_enable,          // one pulse per CPU clock
    input wire reset,               // synchronous, shared with the core
    // CPU register interface
    input wire selected,
    input wire [3:0] address,
    input wire write_en,
    input wire [7:0] data_in,
    output reg [7:0] data_out,

    // To the core's DMA engine, which is where the bytes actually move: this
    // board does not master the bus, it borrows the CPU's address registers.
    output wire dma_req,
    output wire dma_write,          // 1 = we supply a byte, memory takes it
    output wire [7:0] dma_wdata,
    input wire dma_step,
    input wire [7:0] dma_rdata,
    input wire dma_end,
    output wire dma_int,
    // Holds the core's DMA engine still without dropping the request, which is
    // what a sector boundary needs: the microcode's wait loop watches the
    // request, so dropping it would tell the microcode the transfer had
    // finished. Nothing else can pause a transfer in flight.
    output wire dma_hold,

    // The medium.
    input wire img_mounted,
    output reg img_req,
    output reg img_store,
    output reg [15:0] img_block,
    input wire img_busy,
    input wire img_failed,
    // The image layer's port into this board's sector buffer.
    input wire ext_wr,
    input wire [8:0] ext_addr,
    input wire [7:0] ext_wdata,
    output wire [7:0] ext_rdata
);
    localparam integer SECTOR = 400;        // bytes the drive actually holds
    localparam integer STRIDE = 512;        // bytes we reserve per sector

    // How long a command takes, in board clocks at 27MHz. These are not the real
    // drive's times - a Hawk seek is tens of milliseconds - but they are long
    // enough that a driver polling the busy bit sees it set, which is the
    // behaviour being modelled. A real seek time can go in later if anything
    // turns out to care.
    localparam integer T_TRANSFER = 27;     // 1us, the transfer itself is DMA paced
    localparam integer T_SEEK     = 27_000; // 1ms
    localparam integer T_RTZ      = 54_000; // 2ms

    localparam [2:0] CMD_READ = 0, CMD_WRITE = 1, CMD_SEEK = 2,
                     CMD_RTZ  = 3, CMD_VERIFY = 4;

    reg [3:0] unit;
    reg [15:0] sector_addr;
    reg [7:0] wpmask;
    reg [2:0] command;
    reg busy, seeking, seek_done;
    reg [31:0] busy_time;
    reg int_enabled, int_pending;

    // Where we are within the sector being transferred. bytes_left counts down
    // from SECTOR; when it reaches zero the next sector is started, exactly as
    // the emulator's sect_remain does, so one DMA can span sectors.
    reg [9:0] bytes_left;
    reg [8:0] buf_index;
    reg transferring;
    // Waiting for the medium: either bringing a sector in before a read or
    // handing one back after a write. The DMA is held, not dropped, throughout.
    reg waiting;
    reg saw_busy;
    reg media_error;
    // Which sector the buffer currently holds or is being filled with, and a
    // flag saying one just finished. The decision about what to do at a boundary
    // has to wait a cycle for dma_end, because for any whole number of sectors -
    // which is the ordinary case - the end of the transfer and a sector boundary
    // are the same moment, and acting on the boundary alone prefetches a sector
    // nobody wants and then never finishes.
    reg [15:0] cur_sector;
    reg boundary;
    reg [1:0] wait_kind;
    localparam [1:0] W_PREP = 0, W_MID = 1, W_FINAL = 2;
    // The command moves data out of memory and onto the disk.
    wire disk_write = (command == CMD_WRITE) || (command == CMD_VERIFY);

    // One sector buffer. 512 bytes is one block RAM, and this must read every
    // clock with the value held in fabric flops - a block RAM output is not a
    // register and decays if its clock enable is held low.
    reg [7:0] sector_buf [0:STRIDE-1];
    reg [7:0] buf_q;
    integer j;

    // Two things address the buffer and never at the same time: the DMA while a
    // transfer runs, and the image layer while one is held. They have to share
    // *one* write port, muxed here - a memory written from two places is not a
    // block RAM, and yosys builds it out of flip flops and a 512 way multiplexer
    // without a word of complaint. That is 4096 flops and twelve thousand LUT4
    // on a device with 6480 and 8640, and the only sign of it is the design
    // failing to place.
    wire [8:0] buf_read_addr = waiting ? ext_addr : buf_index;
    wire       buf_write     = ext_wr || (transferring && dma_step && !dma_write);
    wire [8:0] buf_waddr     = ext_wr ? ext_addr  : buf_index;
    wire [7:0] buf_wdata_mux = ext_wr ? ext_wdata : dma_rdata;
    assign ext_rdata = buf_q;

    initial begin
        unit = 0; sector_addr = 0; wpmask = 0; command = 0;
        busy = 0; seeking = 0; seek_done = 0; busy_time = 0;
        int_enabled = 0; int_pending = 0;
        bytes_left = 0; buf_index = 0; transferring = 0;
        waiting = 0; saw_busy = 0; media_error = 0;
        cur_sector = 0; boundary = 0; wait_kind = 0;
        img_req = 0; img_store = 0; img_block = 0;
        buf_q = 0; data_out = 0;
        for (j = 0; j < STRIDE; j = j + 1) sector_buf[j] = 8'h00;
    end

    wire write_protected = wpmask[unit[2:0]];

    assign dma_req = transferring;
    assign dma_hold = waiting;
    assign dma_write = (command == CMD_READ);   // read from disk = write to memory
    assign dma_wdata = buf_q;
    assign dma_int = int_pending;

    always @(posedge clock) begin
        if (buf_write) sector_buf[buf_waddr] <= buf_wdata_mux;
        buf_q <= sector_buf[buf_read_addr];
    end

    always @(posedge clock) begin
        if (reset) begin
            unit <= 0; sector_addr <= 0; wpmask <= 0; command <= 0;
            busy <= 0; seeking <= 0; seek_done <= 0; busy_time <= 0;
            int_enabled <= 0; int_pending <= 0;
            bytes_left <= 0; buf_index <= 0; transferring <= 0;
            waiting <= 0; saw_busy <= 0; media_error <= 0;
            boundary <= 0;
            img_req <= 0; img_store <= 0;
        end else begin
            // ------------------------------------------------ the transfer side
            boundary <= 0;
            if (transferring && dma_step) begin
                // The byte itself goes in through the shared write port above.
                if (bytes_left == 1) begin
                    // Off the end of this sector. The drive steps its own
                    // address; the CPU's DMA counters decide when the whole
                    // transfer stops, and that is only known next cycle.
                    bytes_left <= SECTOR;
                    buf_index <= 0;
                    sector_addr <= sector_addr + 1;
                    boundary <= 1;
                end else begin
                    bytes_left <= bytes_left - 1;
                    buf_index <= buf_index + 1;
                end
            end

            if (boundary) begin
                if (dma_end) begin
                    transferring <= 0;
                    if (img_mounted && disk_write) begin
                        // Hand the last sector back before saying we are done.
                        img_block <= cur_sector;
                        img_store <= 1;
                        img_req <= 1;
                        waiting <= 1; saw_busy <= 0; wait_kind <= W_FINAL;
                    end else busy_time <= T_TRANSFER;
                end else if (img_mounted) begin
                    // More to come: put this sector away, or bring the next one
                    // in. Hold the DMA rather than dropping the request, which
                    // the microcode's wait loop reads as "finished".
                    img_block <= disk_write ? cur_sector : sector_addr;
                    img_store <= disk_write;
                    img_req <= 1;
                    cur_sector <= sector_addr;
                    waiting <= 1; saw_busy <= 0; wait_kind <= W_MID;
                end else cur_sector <= sector_addr;
            end

            // A transfer that ends without crossing a boundary - which needs a
            // length that is not a whole number of sectors - still has to stop.
            if (transferring && dma_end && !boundary && !waiting) begin
                transferring <= 0;
                busy_time <= T_TRANSFER;
            end

            // Waiting on the medium.
            if (waiting) begin
                if (img_busy) begin
                    img_req <= 0;
                    saw_busy <= 1;
                end
                if (saw_busy && !img_busy) begin
                    waiting <= 0;
                    saw_busy <= 0;
                    if (img_failed) media_error <= 1;
                    case (wait_kind)
                        W_PREP: begin
                            transferring <= 1;
                            bytes_left <= SECTOR;
                            buf_index <= 0;
                        end
                        W_FINAL: busy_time <= T_TRANSFER;
                        default: ;      // mid transfer: just carry on
                    endcase
                end
            end

            // -------------------------------------------------- command timing
            if (busy_time != 0) begin
                busy_time <= busy_time - 1;
                if (busy_time == 1) begin
                    busy <= 0;
                    if (command == CMD_SEEK || command == CMD_RTZ) begin
                        seeking <= 0;
                        seek_done <= 1;
                    end
                    if (int_enabled) int_pending <= 1;
                end
            end

            // ------------------------------------------------ the register side
            if (cpu_enable && selected && write_en) begin
                case (address)
                    4'h0: unit <= data_in[3:0];
                    4'h1: sector_addr[15:8] <= data_in;
                    4'h2: sector_addr[7:0] <= data_in;
                    4'h3: wpmask <= data_in;
                    4'h8: begin
                        command <= data_in[2:0];
                        seek_done <= 0;
                        busy <= 1;
                        case (data_in[2:0])
                            CMD_READ: begin
                                media_error <= 0;
                                cur_sector <= sector_addr;
                                if (img_mounted) begin
                                    // Bring the sector in before anything moves.
                                    img_block <= sector_addr;
                                    img_store <= 0;
                                    img_req <= 1;
                                    waiting <= 1; saw_busy <= 0;
                                    wait_kind <= W_PREP;
                                end else begin
                                    transferring <= 1;
                                    bytes_left <= SECTOR;
                                    buf_index <= 0;
                                end
                            end
                            CMD_WRITE, CMD_VERIFY: begin
                                // A write protected unit accepts the command and
                                // does nothing, which is what the real board does
                                // and what the emulator models.
                                media_error <= 0;
                                cur_sector <= sector_addr;
                                if (!write_protected) begin
                                    transferring <= 1;
                                    bytes_left <= SECTOR;
                                    buf_index <= 0;
                                end else
                                    busy_time <= T_TRANSFER;
                            end
                            CMD_SEEK: begin
                                seeking <= 1;
                                busy_time <= T_SEEK;
                            end
                            CMD_RTZ: begin
                                seeking <= 1;
                                sector_addr <= 0;
                                busy_time <= T_RTZ;
                            end
                            default: busy_time <= T_TRANSFER;
                        endcase
                    end
                    4'hc: if (int_enabled) int_pending <= 1;  // force
                    4'hd: begin int_enabled <= 0; int_pending <= 0; end
                    4'he: int_enabled <= 1;
                    4'hf: int_pending <= 0;
                    default: ;
                endcase
            end
        end
    end

    always @(*) begin
        case (address)
            // The archive says this reads back with F in the high nibble; the
            // emulator returns the bare unit number. Following the archive,
            // because it is a dump of the real board.
            4'h0: data_out = { 4'hf, unit };
            4'h1: data_out = sector_addr[15:8];
            4'h2: data_out = sector_addr[7:0];
            4'h3: data_out = wpmask;
            // Read status: bits 4 to 7 are format, sector address, CRC and
            // timeout errors, none of which this controller can produce. Bit 0
            // is busy, which the archive does not mention and the emulator
            // returns; it costs nothing to supply both readings.
            // Bit 7 is the timeout error, which is the closest the real board's
            // status has to "the medium did not answer".
            4'h4: data_out = { media_error, 3'b000, 3'b000, busy | seeking };
            // Drive status: seek complete per drive in the low nibble, then
            // ready, on cylinder, write enable, write protect.
            4'h5: data_out = { write_protected, ~write_protected, ~seeking, 1'b1,
                               3'b000, seek_done };
            4'h8: data_out = { 7'b0, busy | seeking };
            default: data_out = 8'h00;
        endcase
    end
endmodule

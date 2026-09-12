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
module HawkDisk #(
    // Which unit the mounted image is in. There is one image, so there is one
    // drive, and the documented way to boot an operating system off it is "H1"
    // - device H, unit 1 - which is also where the emulator's verified CENTOS
    // procedure mounts it.
    parameter [3:0] IMAGE_UNIT = 1
) (
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
    // The address steps within its low byte and does not carry into the
    // cylinder, which is what the emulator does: a transfer runs on through the
    // sectors of one track rather than walking off the end of it.
    wire [15:0] next_sector = { sector_addr[15:8], sector_addr[7:0] + 8'd1 };
    // A drive that is busy with nothing outstanding never becomes ready again,
    // and the operating system's wait loop spins on exactly that bit. Every
    // command arms busy_time except a read, which relies on a DMA transfer
    // completing - so any path where that transfer does not run wedges the
    // controller for good. This is the same rule PsramBus already follows: never
    // let a device stall the machine in a way it cannot recover from.
    reg [23:0] stuck;
    localparam integer STUCK_LIMIT = 27_000_000 / 4;   // a quarter of a second
    // One clock between the buffer being addressed and the transfer starting.
    // buf_q is the sector buffer's *registered* output, so it does not hold
    // sector_buf[buf_index] until the clock after buf_read_addr selects it.
    // Starting the DMA in the same cycle that sets buf_index to 0 handed it
    // whatever buf_q was left holding by the fill, so the first byte of every
    // sector was stale - the image file's 00 arrived as ff and the operating
    // system's list walk read that as an end-of-list marker. Every byte after
    // the first was correct, which is why this looked like anything but an
    // off-by-one in the buffer's read timing.
    reg priming;
    reg verify_fail;
    reg [1:0] wait_kind;
    localparam [1:0] W_PREP = 0, W_MID = 1, W_FINAL = 2;
    // Three different questions the one old "disk_write" flag was answering at
    // once, which is how verify came to write the medium. VERIFY takes its bytes
    // out of memory exactly as a write does, and that is the only thing the two
    // have in common: it compares them against what is on the disk and reports a
    // mismatch. It must never store. Getting this wrong overwrites a sector of
    // the image with whatever the driver happened to be holding, and the
    // operating system's boot issues nearly three hundred of them.
    // Only a write puts anything back. A read and a verify both need the sector
    // brought in first; a write and a verify both take their bytes from memory.
    wire store_to_medium = (command == CMD_WRITE);

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
    wire       buf_write     = ext_wr ||
                               (transferring && dma_step && command == CMD_WRITE);
    wire [8:0] buf_waddr     = ext_wr ? ext_addr  : buf_index;
    wire [7:0] buf_wdata_mux = ext_wr ? ext_wdata : dma_rdata;
    assign ext_rdata = buf_q;

    initial begin
        unit = 0; sector_addr = 0; wpmask = 0; command = 0;
        busy = 0; seeking = 0; seek_done = 0; busy_time = 0;
        int_enabled = 0; int_pending = 0;
        bytes_left = 0; buf_index = 0; transferring = 0;
        waiting = 0; saw_busy = 0; media_error = 0;
        cur_sector = 0; boundary = 0; wait_kind = 0; stuck = 0;
        verify_fail = 0; priming = 0;
        img_req = 0; img_store = 0; img_block = 0;
        buf_q = 0; data_out = 0;
        for (j = 0; j < STRIDE; j = j + 1) sector_buf[j] = 8'h00;
    end

    // Register 3 is a write *permit* mask, not a protect mask, despite the name
    // everything uses for it: a bit has to be SET before the corresponding unit
    // can be written, and the drive status reports it in bit 6, "write enable".
    // Meisaka's emulator suppresses the transfer unless the bit is set, and an
    // operating system boot leaves this register at 00 throughout while issuing
    // twelve write commands - so with the sense inverted, twelve sectors of the
    // image are overwritten on every boot that the real machine would refuse.
    // The safe polarity is also the faithful one: nothing is writable until
    // software says so.
    wire write_enabled = wpmask[unit[2:0]];

    // The request has to stand from the moment the command is accepted, not
    // from the moment the first byte is ready. Microcode word 0x65a tests this
    // with k9 == 5 and treats a low request as "the transfer has finished" -
    // and W_PREP, the fetch of the sector from the medium that a read does
    // before any byte moves, used to drop it. The microcode then walked out of
    // its DMA wait and on into the interrupt entry sequence, which loads a
    // level nothing had prepared, and the machine ended up executing the
    // register file. The mid-transfer waits never had the problem because
    // transferring stays set across them; only the one before the first byte
    // did. This is the rule the comment on W_MID already states: hold the DMA,
    // do not drop the request.
    //
    // W_FINAL is deliberately not included: by then dma_end has been seen and
    // the transfer really is over, so the request must fall.
    assign dma_req = transferring || priming || (waiting && wait_kind == W_PREP);
    assign dma_hold = waiting || priming;
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
            verify_fail <= 0; priming <= 0;
            boundary <= 0;
            stuck <= 0;
            img_req <= 0; img_store <= 0;
        end else begin
            // ------------------------------------------------ the transfer side
            boundary <= 0;
            if (transferring && dma_step) begin
                // The byte itself goes in through the shared write port above.
                // On a verify nothing is stored anywhere: the byte out of memory
                // is compared against the one the medium gave us, and the first
                // difference is latched. buf_q is the disk byte at buf_index,
                // one clock behind the address exactly as the read path relies
                // on, so the two line up without any extra delay.
                if (command == CMD_VERIFY && dma_rdata != buf_q) verify_fail <= 1;
                if (bytes_left == 1) begin
                    // Off the end of this sector. The drive steps its own
                    // address, but only when a byte for the *next* sector is
                    // actually asked for - so the step happens in the boundary
                    // handling below, which knows whether the transfer ended
                    // here. Stepping it now instead leaves the address one
                    // sector past the last one really transferred, and the
                    // driver reads that register back: after the boot PROM
                    // loads the fourteen sectors of WIPL the reference reports
                    // 000d and this used to report 000e.
                    bytes_left <= SECTOR;
                    buf_index <= 0;
                    boundary <= 1;
                end else begin
                    bytes_left <= bytes_left - 1;
                    buf_index <= buf_index + 1;
                end
            end

            if (boundary) begin
                if (dma_end) begin
                    transferring <= 0;
                    if (img_mounted && store_to_medium) begin
                        // Hand the last sector back before saying we are done.
                        img_block <= cur_sector;
                        img_store <= 1;
                        img_req <= 1;
                        waiting <= 1; saw_busy <= 0; wait_kind <= W_FINAL;
                    end else busy_time <= T_TRANSFER;
                end else if (img_mounted) begin
                    // More to come, so the drive steps now. Put this sector
                    // away, or bring the next one in. Hold the DMA rather than
                    // dropping the request, which the microcode's wait loop
                    // reads as "finished".
                    sector_addr <= next_sector;
                    img_block <= store_to_medium ? cur_sector : next_sector;
                    img_store <= store_to_medium;
                    img_req <= 1;
                    cur_sector <= next_sector;
                    waiting <= 1; saw_busy <= 0; wait_kind <= W_MID;
                end else begin
                    sector_addr <= next_sector;
                    cur_sector <= next_sector;
                end
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
                            priming <= 1;
                            buf_index <= 0;
                        end
                        W_FINAL: busy_time <= T_TRANSFER;
                        // Mid transfer the DMA is already running and buf_index
                        // was reset at the boundary, so its first byte after the
                        // wait needs the same clock of settling.
                        default: priming <= 1;
                    endcase
                end
            end

            // The buffer output has settled: start, or resume, moving bytes.
            if (priming) begin
                priming <= 0;
                if (!transferring) begin
                    transferring <= 1;
                    bytes_left <= SECTOR;
                end
            end

            // ------------------------------------------------- the stuck guard
            // Every state the controller can sit in with a command outstanding
            // has to be able to give up, not just the idle-but-busy one. This
            // used to stop counting whenever the controller was transferring or
            // waiting - and those are exactly the states it gets stuck in, since
            // a read depends on its DMA transfer running and a fetch from the
            // medium depends on the image layer answering. Parked in either, the
            // guard never counted at all, busy stayed set for ever, and the
            // operating system's driver spun on that bit with no way to give up.
            // A quarter of a second is orders of magnitude longer than any real
            // transfer here, so counting through those states costs nothing.
            if (!busy) stuck <= 0;
            else if (stuck == STUCK_LIMIT - 1) begin
                busy <= 0;
                media_error <= 1;       // reported as a timeout, which it is
                // Put the controller back in a state it can take a command from,
                // rather than leaving it half way through one nobody will finish.
                transferring <= 0;
                waiting <= 0;
                saw_busy <= 0;
                img_req <= 0;
                stuck <= 0;
            end else stuck <= stuck + 1;

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
                        // Any command clears the error bits, which is what the
                        // emulator's clear_errors() does on every command write.
                        media_error <= 0;
                        verify_fail <= 0;
                        case (data_in[2:0])
                            CMD_READ: begin
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
                            CMD_WRITE: begin
                                // A write protected unit accepts the command and
                                // does nothing, which is what the real board does
                                // and what the emulator models.
                                cur_sector <= sector_addr;
                                if (write_enabled) begin
                                    transferring <= 1;
                                    bytes_left <= SECTOR;
                                    buf_index <= 0;
                                end else
                                    busy_time <= T_TRANSFER;
                            end
                            CMD_VERIFY: begin
                                // A verify needs the sector in hand to compare
                                // against, so it starts the same way a read
                                // does. It is not gated on write protect,
                                // because it does not write.
                                cur_sector <= sector_addr;
                                if (img_mounted) begin
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
            4'h4: data_out = { media_error, verify_fail, 2'b00, 3'b000,
                               busy | seeking };
            // Drive status: seek complete per drive in the low nibble, then
            // ready, on cylinder, write enable, write protect.
            // Bit 7 is the medium's own write protect tab, which an image
            // mounted off the card does not have, and bit 6 is the permit mask
            // for this unit. They are independent in the emulator and a write
            // needs the tab clear and the mask bit set.
            //
            // Bit 4 is "ready", meaning this unit has a medium in it. Reporting
            // it for every unit says the machine has sixteen drives all loaded,
            // which is not a cosmetic lie: the boot walks the units and
            // recalibrates each one it believes is there, so it issues eight
            // RTZs where a real machine issues one, and whatever counts drives
            // later counts sixteen. There is one image, on one unit.
            4'h5: data_out = { 1'b0, write_enabled, ~seeking,
                               img_mounted && unit == IMAGE_UNIT,
                               3'b000, seek_done };
            4'h8: data_out = { 7'b0, busy | seeking };
            default: data_out = 8'h00;
        endcase
    end
endmodule

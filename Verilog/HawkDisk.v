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
 * There is no medium yet. The controller has one 512 byte sector buffer and
 * serves reads from it and writes into it, so a sector written can be read back
 * and everything above this - the registers, the command timing, the DMA, the
 * interrupt - can be exercised and judged. Giving it a real 5MB of PSRAM behind
 * that buffer is the next step and does not change anything here.
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
    output wire dma_int
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

    // One sector buffer. 512 bytes is one block RAM, and this must read every
    // clock with the value held in fabric flops - a block RAM output is not a
    // register and decays if its clock enable is held low.
    reg [7:0] sector_buf [0:STRIDE-1];
    reg [7:0] buf_q;
    integer j;

    initial begin
        unit = 0; sector_addr = 0; wpmask = 0; command = 0;
        busy = 0; seeking = 0; seek_done = 0; busy_time = 0;
        int_enabled = 0; int_pending = 0;
        bytes_left = 0; buf_index = 0; transferring = 0;
        buf_q = 0; data_out = 0;
        for (j = 0; j < STRIDE; j = j + 1) sector_buf[j] = 8'h00;
    end

    wire write_protected = wpmask[unit[2:0]];

    assign dma_req = transferring;
    assign dma_write = (command == CMD_READ);   // read from disk = write to memory
    assign dma_wdata = buf_q;
    assign dma_int = int_pending;

    always @(posedge clock)
        buf_q <= sector_buf[buf_index];

    always @(posedge clock) begin
        if (reset) begin
            unit <= 0; sector_addr <= 0; wpmask <= 0; command <= 0;
            busy <= 0; seeking <= 0; seek_done <= 0; busy_time <= 0;
            int_enabled <= 0; int_pending <= 0;
            bytes_left <= 0; buf_index <= 0; transferring <= 0;
        end else begin
            // ------------------------------------------------ the transfer side
            if (transferring && dma_step) begin
                if (!dma_write) sector_buf[buf_index] <= dma_rdata;
                if (bytes_left == 1) begin
                    // Off the end of this sector and on to the next one. The
                    // drive steps its own address; the CPU's DMA counters are
                    // what decide when the whole transfer stops.
                    bytes_left <= SECTOR;
                    buf_index <= 0;
                    sector_addr <= sector_addr + 1;
                end else begin
                    bytes_left <= bytes_left - 1;
                    buf_index <= buf_index + 1;
                end
            end
            if (transferring && dma_end) begin
                transferring <= 0;
                busy_time <= T_TRANSFER;
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
                                transferring <= 1;
                                bytes_left <= SECTOR;
                                buf_index <= 0;
                            end
                            CMD_WRITE, CMD_VERIFY: begin
                                // A write protected unit accepts the command and
                                // does nothing, which is what the real board does
                                // and what the emulator models.
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
            4'h4: data_out = { 4'h0, 3'b000, busy | seeking };
            // Drive status: seek complete per drive in the low nibble, then
            // ready, on cylinder, write enable, write protect.
            4'h5: data_out = { write_protected, ~write_protected, ~seeking, 1'b1,
                               3'b000, seek_done };
            4'h8: data_out = { 7'b0, busy | seeking };
            default: data_out = 8'h00;
        endcase
    end
endmodule

`include "CPU6.v"
`include "StatusDump.v"
`include "DiagBoard.v"
`include "PsramBus.v"
`include "MemoryArbiter.v"
`include "DmaTest.v"
`include "HawkDisk.v"
`include "SdSpi.v"
`include "Fat32.v"
`include "DiskImage.v"
`include "BoardMemory.v"
`include "Instruments.v"
`include "FinchCard.v"
`include "LEDPanel.v"
`include "mux.v"

/**
 * The Centurion, as a machine: the CPU6 and everything on its bus.
 *
 * Nothing in this file knows what board it is on. It takes a clock and an
 * enable that paces the core to 5MHz, a reset, the front panel switches, a
 * console serial line, an SD card's SPI pins, and one external memory port -
 * and it gives back the LED panel and the same serial line with the debugger's
 * dump multiplexed onto it. Retargeting this design to another FPGA means
 * writing a board file that provides those and nothing else; see tangnano9k.v
 * for the one that exists.
 *
 * THE MEMORY PORT is the whole of the contract with whatever memory the board
 * has. It is one client speaking one protocol:
 *
 *     raise read or write, with addr and din, and hold them until busy rises;
 *     then wait for busy to fall. dout is valid when it has fallen. A read
 *     returns FOUR consecutive 16 bit words, the one at addr first, because
 *     the CPU's bridge caches a line of four; byte_write means only the byte
 *     din[7:0] of the word at addr is to be stored.
 *
 * On the Tang Nano 9K that port is Psram.v, over the HyperRAM in the package.
 * The machine has two clients for it - the CPU's bridge and the disk image's
 * cache - and shares them itself, in MemoryArbiter, so the board sees one.
 * A board whose memory is fast enough could answer in a clock; one whose
 * memory takes a microsecond stalls the core for that long through the enable,
 * which to CPU6 is just a long bus cycle. Nothing else changes.
 *
 * What lives here, in the order it appears: the peripheral read bus and the
 * address decode; the DMA port and the two devices that share it; the page
 * table initialiser; the memory bridge; the board memory with its parity bit;
 * the LED panel, the Diag board, the Finch, the MUX and the DMA test device;
 * the storage stack - SD card, FAT32, the image cache and the Hawk; the CPU;
 * and the instruments, which are the debugger and read all of the above.
 */
/**
 * Peripheral decode for the CPU's 19 bit physical address bus.
 *
 * The LED panel does its own decode because it is write only and never drives the
 * read bus. Everything that can be read has to be decoded here so that exactly one
 * device drives data_r2c.
 */
module AddressDecode #(parameter DIAG_ROM = 1) (input wire [18:0] address,
    output wire mux_select, output wire diag_select, output wire ram_select,
    output wire dma_select, output wire hawk_select, output wire finch_select,
    output wire psram_select);

    // MUX serial board, 16 registers. This matches the Diag MUX addresses used by
    // CPU6TestBench.v (status 0x3f200, data 0x3f201) and by programs/hellorld.txt.
    assign mux_select = (address & 19'h7fff0) == 19'h3f200;

    // The Diag board: hex display, decimal points and DIP switches at 0x3f100.
    assign diag_select = (address & 19'h7ffe0) == 19'h3f100;

    // The DMA test device, sixteen registers at 0x3f300.
    assign dma_select = (address & 19'h7fff0) == 19'h3f300;

    // The Hawk disk controller, sixteen registers at 0x3f140. That is inside the
    // Diag board's page but clear of its window at 0x3f100, which is where the
    // real machine puts it too.
    assign hawk_select = (address & 19'h7fff0) == 19'h3f140;
    // The Finch floppy controller's mailbox, two registers at 0x3f800. The
    // operating system talks to it during startup because a Finch is in the
    // configuration on the pack, and sits waiting forever if nothing answers.
    assign finch_select = (address & 19'h7fffe) == 19'h3f800;

    // The block RAM regions, which must go on answering rather than being folded
    // into the PSRAM: they are about fourteen times faster, and everything the
    // machine runs today lives in them. These have to match BoardMemory.v.
    // With the diag ROMs out, this 8K is ordinary memory and the PSRAM takes it.
    wire rom_region      = DIAG_ROM[0] && (address[18:13] == 6'd4);  // 0x08000
    wire ram_region      = address[18:12] == 7'h0b
                         || address[18:12] == 7'h0c;               // 0x0b000
    wire low_ram_region  = address[18:12] == 7'h00;                // 0x00000
    wire boot_region     = address[18:9]  == 10'h1fe;              // 0x3fc00
    assign ram_select = ~(mux_select | diag_select | dma_select | hawk_select
                          | finch_select);

    // The PSRAM fills the rest of the machine's 256K of physical memory. The top
    // 4K page is left alone entirely: that is the I/O page, and the boot PROM,
    // the MUX and the Diag board all live in it.
    wire io_page = address[18:12] == 7'h3f;
    assign psram_select = ~(io_page | rom_region | ram_region | low_ram_region
                          | boot_region) && address < 19'h40000;
endmodule

module Centurion #(
    // Which program the ROM holds; see BoardMemory.v.
    parameter PROGRAM = "programs/diag.txt",
    // Whether the diag board's ROMs are fitted at 0x08000. They have to be
    // out to boot the operating system, which loads code there.
    parameter DIAG_ROM = 1,
    // The DMA pattern device at 0x3f300 - a test device that costs real
    // logic, so a normal build leaves it out; DmaTB turns it on.
    parameter DMA_TEST = 0,
    // The mapping RAM failure instrumentation and the MUX's interrupt
    // counters: several hundred logic cells of scaffolding, off by default.
    parameter DIAG_TRACE = 0,
    // Whether a parity error is reported to the microcode at all.
    parameter PARITY_CHECK = 1,
    // See CPU6.v: K13 case 1 and the interrupt conditions.
    parameter K13_INTERRUPTS = 1,
    // The 8.3 name of the image file on the card: eight characters then three.
    parameter [87:0] DISK_IMAGE = "HAWK0   IMG",
    // The board clock, for everything that counts time.
    parameter integer CLOCK_HZ = 27_000_000,
    // Testbench use only; see PsramBus.v.
    parameter SPACING = 1,
    // The board's memory is running its own self test instead of serving
    // the machine, so the bridge must not touch it and the dump reports the
    // test instead of the disk.
    parameter MEMORY_SELFTEST = 0
) (
    input wire clock,
    // The core's pace: the board raises this 5 times a microsecond. The
    // memory bridge withholds it while an access is in flight, and what comes
    // out is the enable everything on the bus actually runs on.
    input wire cpu_en_free,
    output wire cpu_en,
    input wire reset,

    // The front panel
    input wire [7:0] dip_switches,
    input wire [3:0] sense_switches,
    output wire [7:0] display_leds,
    input wire btn2,                        // hold for a status dump

    // The console
    input wire uart_rx,
    output wire uart_tx,

    // The SD card, SPI
    output wire sd_clk, output wire sd_mosi, input wire sd_miso, output wire sd_cs_n,

    // The external memory: one port, described above
    output wire mem_read, output wire mem_write, output wire mem_byte_write,
    output wire [22:0] mem_addr, output wire [15:0] mem_din,
    input wire [63:0] mem_dout,
    input wire mem_busy,

    // What the board's memory would like shown in the status dump. A board
    // with nothing to say ties these to zero.
    input wire [3:0] mem_dbg_state,
    input wire [4:0] mem_dbg_match,
    input wire [15:0] mem_dbg_echo,
    input wire [15:0] mem_dbg_nonff,
    input wire mem_test_done,
    input wire mem_test_pass,
    input wire [2:0] mem_test_stage,
    input wire [15:0] mem_test_read0,
    input wire [15:0] mem_test_read1
);
    // The names the instruments and the bridge have always used for the
    // memory's side of things.
    wire busy = mem_busy, read = mem_read, write = mem_write;
    wire [63:0] dout = mem_dout;
    wire [3:0] sdr_state = mem_dbg_state;
    wire [4:0] sdr_match = mem_dbg_match;
    wire [15:0] sdr_echo = mem_dbg_echo, sdr_nonff = mem_dbg_nonff;
    wire psram_done = mem_test_done, psram_pass = mem_test_pass;
    wire [2:0] psram_stage = mem_test_stage;
    wire [15:0] psram_read0 = mem_test_read0, psram_read1 = mem_test_read1;
    wire in_clk = clock;                    // the MUX's bit clock is the same net

    wire int_reqn;
    wire [3:0] irq_number;

    wire writeEnBus;
    wire [7:0] data_c2r, data_r2c;
    wire [18:0] addressBus;
    wire [7:0] leds;
    wire mux_uart_tx;
    wire [15:0] dbg_memory_address;
    wire [10:0] dbg_uc_address;
    wire dbg_byte_ready;
    wire [7:0] dbg_rx_byte;
    wire [2:0] dbg_page_table_base;
    wire [3:0] dbg_d2d3;
    wire [7:0] dbg_f11;
    wire [7:0] dbg_page_table_out;
    wire [1:0] dbg_e7;
    wire [7:0] dbg_data_in;
    wire [7:0] dbg_entry0;
    wire dbg_e0_write, dbg_e0_via_window;
    wire dbg_pt_write, dbg_pt_via_window;
    wire [7:0] dbg_pt_index, dbg_pt_value;
    wire [7:0] dbg_e0_value;
    wire dump_tx, dump_active;
    wire instruction_start;
    wire cpu_alive;

    // The disk image's side of the memory, arbitrated with the CPU's below.
    wire disk_read, disk_write, disk_byte_write;
    wire [22:0] disk_addr;
    wire [15:0] disk_din;
    wire disk_busy_view, bus_busy_view;
    // The bus side. PsramBus owns the core's clock enable, because stalling the
    // core is how a 2.8us memory access is made to fit in a bus cycle.
    wire bus_read, bus_write, bus_byte_write;
    wire [22:0] bus_addr;
    wire [15:0] bus_din;
    wire [7:0] psram_data;
    wire [15:0] dbg_psram_accesses, dbg_psram_timeouts;
    wire [2:0] dbg_psram_where;
    wire [1:0] dbg_bus_state;
    wire dbg_bus_need;
    wire [18:0] dbg_psram_addr;
    wire [7:0] dbg_psram_data;


    // Peripheral read bus ---------------------------
    // Every readable peripheral drives its own data_out, and this module picks one.
    // Previously BlockRAM, LEDPanel and MUX were all wired straight onto data_r2c.
    // Simulation resolved the undriven outputs as z and let the RAM value through, but
    // yosys reported a driver-driver conflict, resolved it to a constant and dropped
    // ram_cells entirely, so on hardware the CPU only ever read 'x' (decoded as HLT).
    wire mux_select, diag_select, ram_select, dma_select, hawk_select, finch_select;
    wire psram_select_raw;
    wire [7:0] ram_data, mux_data, diag_data, finch_data;

    // The DMA device and the core's side of it. The device stores nothing: it
    // generates or checks a pattern, which is enough to test the path and keeps
    // the block RAM free for the disk controllers' sector buffers.
    wire test_req, test_write, test_int, test_hold;
    wire hawk_req, hawk_write, hawk_int, hawk_hold;
    wire [7:0] test_wdata, dma_rdata, dma_data, hawk_wdata, hawk_data;
    wire dma_step, dma_end;

    // Two devices on one DMA port. The core has a single request, direction and
    // data path, so whichever device is asking drives them - the Hawk first, on
    // the principle that a real transfer outranks a test one. A step only counts
    // for the device that asked for it. More devices would want a proper rotating
    // arbiter; two want this.
    wire dma_req = hawk_req | test_req;
    wire dma_device_write = hawk_req ? hawk_write : test_write;
    wire [7:0] dma_wdata = hawk_req ? hawk_wdata : test_wdata;
    wire dma_int = hawk_int | test_int;
    // Only a device that is actually transferring may hold the core still.
    wire dma_hold = hawk_req & hawk_hold;
    wire hawk_step = dma_step & hawk_req;
    wire test_step = dma_step & test_req & ~hawk_req;

    AddressDecode #(.DIAG_ROM(DIAG_ROM)) decode(addressBus, mux_select, diag_select, ram_select,
                         dma_select, hawk_select, finch_select, psram_select_raw);

    // With the self test running the CPU must not touch the memory at all, or the
    // two would fight over the controller and the core would stall for ever.
    wire psram_select = psram_select_raw && (MEMORY_SELFTEST == 0);

    assign data_r2c = mux_select   ? mux_data :
                      diag_select  ? diag_data :
                      dma_select   ? dma_data :
                      hawk_select  ? hawk_data :
                      finch_select ? finch_data :
                      psram_select ? psram_data : ram_data;

    // M13 bit 7, from the core back to the serial board so it can drop its request.
    wire interrupt_ack;

    // Page table initialiser. diag does not build its own map: the strobe that looked
    // like it did, K11 output 1, turns out to break the instruction test when treated
    // as a page file write. So this stays.
    reg [7:0] ptinit_addr;
    wire ptinit_write = reset;
    initial ptinit_addr = 0;
    always @(posedge clock) begin
        if (ptinit_write) ptinit_addr <= ptinit_addr + 1;
    end

    MemoryArbiter arbiter(
        .clock(clock), .reset(reset),
        .a_read(bus_read), .a_write(bus_write), .a_byte_write(bus_byte_write),
        .a_addr(bus_addr), .a_din(bus_din), .a_busy(bus_busy_view),
        .b_read(disk_read), .b_write(disk_write), .b_byte_write(disk_byte_write),
        .b_addr(disk_addr), .b_din(disk_din), .b_busy(disk_busy_view),
        .mem_read(mem_read), .mem_write(mem_write), .mem_byte_write(mem_byte_write),
        .mem_addr(mem_addr), .mem_din(mem_din), .mem_busy(mem_busy));

    PsramBus #(.ENFORCE_SPACING(SPACING)) psram_bus(
        .clock(clock), .reset(reset), .cpu_en(cpu_en_free), .select(psram_select),
        .address(addressBus), .write_en(writeEnBus), .data_in(data_c2r),
        .data_out(psram_data), .cpu_en_out(cpu_en),
        .read(bus_read), .write(bus_write), .byte_write(bus_byte_write),
        .addr(bus_addr), .din(bus_din), .dout(dout), .busy(bus_busy_view),
        .dbg_accesses(dbg_psram_accesses), .dbg_last_addr(dbg_psram_addr),
        .dbg_last_data(dbg_psram_data), .dbg_timeouts(dbg_psram_timeouts),
        .dbg_timeout_where(dbg_psram_where), .dbg_state(dbg_bus_state),
        .dbg_need(dbg_bus_need));

    // F11 bit 5 asks for a write with deliberately wrong parity, and the fault
    // comes straight back out to CPU6's k9 == 6. Only the block RAM regions
    // carry a parity bit; an address the PSRAM answers never faults, which is
    // correct as far as anything can tell, because parity is only ever wrong
    // when the CPU has asked for it to be and the operating system only asks in
    // low memory. Storing a bit per byte for the whole 256K would mean a second
    // memory access on every cycle.
    wire parity_bad;
    BoardMemory #(.PROGRAM(PROGRAM), .DIAG_ROM(DIAG_ROM)) ram(
        clock, cpu_en, addressBus, writeEnBus & ram_select, data_c2r, ram_data,
        dbg_f11[5], parity_bad);
    LEDPanel panel(clock, cpu_en, addressBus, writeEnBus, data_c2r, leds);
    // The Diag board. Its DIP switches choose what diag does out of reset; see
    // DiagBoard.v for the settings. 0x1d is the auxiliary test menu and 0x1a is TOS,
    // the machine code monitor.
    wire [7:0] diag_hex;
    wire [3:0] diag_points;
    wire diag_blank;
    DiagBoard diag(clock, cpu_en, diag_select, addressBus[4:0], writeEnBus, data_c2r,
                   dip_switches, diag_data, diag_hex, diag_points, diag_blank);

    // e7 == 3 latches the bus, but that is only a device read when h11 == 1
    // began one - the rest are the CPU latching its own write data. Peripherals
    // whose read has a side effect need both, or they lose state to a latch that
    // was never a read: the MUX's data register was discarding a received
    // character on roughly one bus latch in twelve.
    wire dbg_bus_read_cycle;
    wire bus_read_strobe = (dbg_e7 == 2'd3) && dbg_bus_read_cycle;

    // The Finch floppy controller's mailbox. Only the host interface is here;
    // see FinchCard.v for what that does and does not model.
    FinchCard finch(clock, cpu_en, reset, finch_select, addressBus[0], writeEnBus,
                    bus_read_strobe, data_c2r, finch_data);

    wire [7:0] dbg_mux_state, dbg_last_cause;
    wire [15:0] dbg_acks, dbg_rx_chars, dbg_cause_rx, dbg_cause_tx;

    MUX #(.DEBUG(DIAG_TRACE), .CLOCK_HZ(CLOCK_HZ)) mux0(in_clk, clock, cpu_en, reset, uart_rx, mux_uart_tx, mux_select,
             { 1'b0, addressBus[3:0] }, writeEnBus, bus_read_strobe, data_c2r,
             interrupt_ack, mux_data, int_reqn, irq_number,
             dbg_byte_ready, dbg_rx_byte, dbg_mux_state, dbg_last_cause,
             dbg_acks, dbg_rx_chars, dbg_cause_rx, dbg_cause_tx);

    // The DMA test device: a pattern generator and checker with no storage.
    generate if (DMA_TEST) begin : dma_test_device
    DmaTest dmatest(clock, cpu_en, reset, dma_select, addressBus[3:0], writeEnBus,
                    data_c2r, dma_data,
                    test_req, test_write, test_wdata,
                    test_step, dma_rdata, dma_end, test_int, test_hold);
    end else begin : no_dma_test_device
        assign test_req = 0;
        assign test_write = 0;
        assign test_wdata = 0;
        assign test_int = 0;
        assign test_hold = 0;
        assign dma_data = 0;
    end endgenerate

    // ----------------------------------------------------------- the storage
    // The card, the filesystem and the PSRAM cache, in that order. Fat32 finds
    // the image once at power up; DiskImage then deals only in block numbers.
    wire sd_ready, sd_error, sd_busy;
    wire fat_read, img_sd_read, img_sd_write;
    wire [31:0] fat_lba, img_lba;
    wire sd_rx_strobe, sd_tx_request;
    wire [8:0] sd_rx_index, sd_tx_index;
    wire [7:0] sd_rx_byte, sd_tx_byte;
    wire [7:0] sd_dbg_state, sd_dbg_r1;
    wire sd_block_addressing;

    // Only the mounter reads the card before mounting and only the image layer
    // afterwards, so an or is the whole arbitration.
    wire card_read = fat_read | img_sd_read;
    wire [31:0] card_lba = fat_read ? fat_lba : img_lba;

    SdSpi #(.CLOCK_HZ(CLOCK_HZ)) sd(clock, reset, sd_clk, sd_mosi, sd_miso, sd_cs_n,
             card_read, img_sd_write, card_lba, sd_busy, sd_ready, sd_error,
             sd_rx_strobe, sd_rx_index, sd_rx_byte,
             sd_tx_request, sd_tx_index, sd_tx_byte,
             sd_dbg_state, sd_dbg_r1, sd_block_addressing);

    // Mount once, as soon as the card is ready.
    reg mount_pulse = 0, mount_done = 0;
    wire img_mounted, mount_failed;
    wire [3:0] mount_reason;
    wire [15:0] file_blocks;
    wire map_req, map_valid;
    wire [15:0] map_block;
    wire [31:0] map_lba;
    wire [7:0] fat_dbg_state, fat_extents;
    wire fat_fallback;
    always @(posedge clock) begin
        mount_pulse <= 0;
        if (reset) mount_done <= 0;
        else if (sd_ready && !mount_done) begin
            mount_pulse <= 1;
            mount_done <= 1;
        end
    end

    Fat32 #(.FILENAME(DISK_IMAGE)) fat(
        clock, reset, mount_pulse, img_mounted, mount_failed, mount_reason,
        fat_read, fat_lba, sd_busy, sd_ready, sd_error,
        sd_rx_strobe, sd_rx_index, sd_rx_byte,
        file_blocks, map_req, map_block, map_valid, map_lba,
        fat_dbg_state, fat_extents, fat_fallback);

    wire img_req, img_store, img_busy, img_failed, img_flushing;
    wire [2:0] img_fail_why;
    wire [15:0] img_block;
    wire hawk_ext_wr;
    wire [8:0] hawk_ext_addr;
    wire [7:0] hawk_ext_wdata, hawk_ext_rdata;
    wire [7:0] img_dbg_state;
    wire [15:0] img_fetches, img_hits, img_writebacks;

    DiskImage image(
        clock, reset, img_mounted, file_blocks,
        map_req, map_block, map_valid, map_lba,
        img_sd_read, img_sd_write, img_lba, sd_busy, sd_error,
        sd_rx_strobe, sd_rx_index, sd_rx_byte,
        sd_tx_request, sd_tx_index, sd_tx_byte,
        disk_read, disk_write, disk_byte_write, disk_addr, disk_din, dout, disk_busy_view,
        img_req, img_store, img_block, img_busy, img_failed, img_fail_why,
        hawk_ext_wr, hawk_ext_addr, hawk_ext_wdata, hawk_ext_rdata,
        1'b0, img_flushing,
        img_dbg_state, img_fetches, img_hits, img_writebacks);

    // The Hawk disk controller.
    HawkDisk #(.CLOCK_HZ(CLOCK_HZ)) hawk(clock, cpu_en, reset, hawk_select, addressBus[3:0], writeEnBus,
                  data_c2r, hawk_data,
                  hawk_req, hawk_write, hawk_wdata,
                  hawk_step, dma_rdata, dma_end, hawk_int, hawk_hold,
                  img_mounted, img_req, img_store, img_block, img_busy, img_failed,
                  hawk_ext_wr, hawk_ext_addr, hawk_ext_wdata, hawk_ext_rdata);

    CPU6 #(.K13_INTERRUPTS(K13_INTERRUPTS)) cpu (reset, clock, cpu_en, data_r2c, int_reqn, irq_number, writeEnBus, addressBus, data_c2r, instruction_start,
              ptinit_write, ptinit_addr, ptinit_addr, sense_switches,
              dma_req, dma_device_write, dma_wdata, dma_step, dma_rdata, dma_end,
              dma_int, dma_hold,
              dbg_memory_address, dbg_uc_address, dbg_page_table_base, dbg_page_table_out,
              dbg_d2d3, dbg_f11,
              dbg_e7, dbg_data_in, dbg_entry0,
              dbg_e0_write, dbg_e0_value, dbg_e0_via_window,
              dbg_pt_write, dbg_pt_index, dbg_pt_value, dbg_pt_via_window, interrupt_ack,
              parity_bad & PARITY_CHECK[0], dbg_bus_read_cycle);

    // The status dump, its payloads and the watchdog: the debugger, not the
    // machine. See Instruments.v. It takes the UART pin over while a dump is
    // going out, which is safe because the machine is only worth interrogating
    // when it has stopped printing.
    Instruments #(.CLOCK_HZ(CLOCK_HZ), .DIAG_TRACE(DIAG_TRACE),
                  .MEMORY_SELFTEST(MEMORY_SELFTEST), .PARITY_CHECK(PARITY_CHECK)) instruments(
        .in_clk(in_clk),
        .clock(clock),
        .reset(reset),
        .cpu_en(cpu_en),
        .btn2(btn2),
        .addressBus(addressBus),
        .data_c2r(data_c2r),
        .writeEnBus(writeEnBus),
        .bus_read_strobe(bus_read_strobe),
        .mux_select(mux_select),
        .parity_bad(parity_bad),
        .instruction_start(instruction_start),
        .interrupt_ack(interrupt_ack),
        .dbg_memory_address(dbg_memory_address),
        .dbg_uc_address(dbg_uc_address),
        .dbg_page_table_base(dbg_page_table_base),
        .dbg_d2d3(dbg_d2d3),
        .dbg_f11(dbg_f11),
        .dbg_e7(dbg_e7),
        .dbg_data_in(dbg_data_in),
        .dbg_page_table_out(dbg_page_table_out),
        .dbg_entry0(dbg_entry0),
        .dbg_e0_write(dbg_e0_write),
        .dbg_e0_value(dbg_e0_value),
        .dbg_e0_via_window(dbg_e0_via_window),
        .dbg_pt_via_window(dbg_pt_via_window),
        .dbg_pt_write(dbg_pt_write),
        .dbg_pt_index(dbg_pt_index),
        .dbg_pt_value(dbg_pt_value),
        .dbg_byte_ready(dbg_byte_ready),
        .dbg_rx_byte(dbg_rx_byte),
        .psram_select(psram_select),
        .busy(busy),
        .read(read),
        .write(write),
        .dbg_psram_accesses(dbg_psram_accesses),
        .dbg_psram_timeouts(dbg_psram_timeouts),
        .dbg_psram_addr(dbg_psram_addr),
        .dbg_psram_data(dbg_psram_data),
        .dbg_bus_state(dbg_bus_state),
        .dbg_bus_need(dbg_bus_need),
        .sdr_state(sdr_state),
        .sdr_match(sdr_match),
        .sdr_echo(sdr_echo),
        .sdr_nonff(sdr_nonff),
        .psram_done(psram_done),
        .psram_pass(psram_pass),
        .psram_stage(psram_stage),
        .psram_read0(psram_read0),
        .psram_read1(psram_read1),
        .sd_dbg_state(sd_dbg_state),
        .sd_dbg_r1(sd_dbg_r1),
        .sd_ready(sd_ready),
        .sd_error(sd_error),
        .sd_block_addressing(sd_block_addressing),
        .mount_done(mount_done),
        .mount_failed(mount_failed),
        .mount_reason(mount_reason),
        .fat_dbg_state(fat_dbg_state),
        .fat_extents(fat_extents),
        .fat_fallback(fat_fallback),
        .file_blocks(file_blocks),
        .img_mounted(img_mounted),
        .img_req(img_req),
        .img_busy(img_busy),
        .img_failed(img_failed),
        .img_dbg_state(img_dbg_state),
        .img_fetches(img_fetches),
        .hawk_req(hawk_req),
        .hawk_hold(hawk_hold),
        .leds(leds),
        .dump_tx(dump_tx),
        .dump_active(dump_active),
        .display_leds(display_leds));
    assign uart_tx = dump_active ? dump_tx : mux_uart_tx;
endmodule

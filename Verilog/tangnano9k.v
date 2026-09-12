`include "CPU6.v"
`include "StatusDump.v"
`include "DiagBoard.v"
`include "PsramTest.v"
`include "PsramSdr.v"
`include "PsramBus.v"
`include "Psram.v"
`include "DmaTest.v"
`include "HawkDisk.v"
`include "SdSpi.v"
`include "Fat32.v"
`include "DiskImage.v"
// psram_controller.v is no longer built: it drives the bus through apicula's
// ODDR/IDDR, which is exactly what does not work here. Kept in the tree for
// reference, and because its four implicit declaration warnings are noise.
`include "BoardMemory.v"
`include "Instruments.v"
`include "FinchCard.v"
`include "LEDPanel.v"
`include "mux.v"

/**
 * This file contains the top level Centurion CPU synthesizable on an Tang Nano 9K FGPA board.
 */







/**
 * CPU clock enable.
 *
 * The original CPU6 ran at about 5MHz: DLY takes 22725 cycles and 4.55ms, which puts
 * it at 4.995MHz. The board clock is 27MHz, which is not a multiple of 5MHz, so rather
 * than dividing, accumulate. Add TICKS every clock and emit an enable whenever the
 * accumulator reaches PERIOD, carrying the remainder forward. That gives exactly TICKS
 * enables every PERIOD clocks, so 5 every 27 is exactly 5.000MHz on average and DLY
 * takes exactly 4.545ms. An individual cycle is up to one 27MHz period (37ns) early or
 * late, which a synchronous design cannot see.
 *
 * An enable rather than a divided clock keeps the whole design in the one clock domain
 * that arrives from the input pin. Generating a second clock in fabric is what stopped
 * the CPU running on hardware before.
 */
module ClockEnable #(
    parameter TICKS  = 5,       // CPU MHz
    parameter PERIOD = 27       // board clock MHz. TICKS + PERIOD must be under 256.
) (
    input wire clock,
    output reg enable
);
    reg [7:0] acc;

    initial begin
        acc = 0;
        enable = 0;
    end

    always @(posedge clock) begin
        if (acc + TICKS >= PERIOD) begin
            acc <= acc + TICKS - PERIOD;
            enable <= 1;
        end else begin
            acc <= acc + TICKS;
            enable <= 0;
        end
    end
endmodule





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

module tangnano9k #(parameter [7:0] DIAG_DIP_SWITCHES = 8'h1d,
                    parameter [3:0] SENSE_SWITCHES = 4'b0001,
                    // Run the PSRAM's own self test instead of giving the memory
                    // to the CPU. See PsramTest.v.
                    parameter PSRAM_SELFTEST = 0,
                    // Testbench use only; see PsramBus.v.
                    parameter SPACING = 1,
                    // Which program the ROM holds; see BoardMemory.v.
                    parameter PROGRAM = "programs/diag.txt",
                    // How much faster than the board clock the PSRAM runs. The
                    // PHY builds CK from four phases of its clock, so 1 gives
                    // the 6.75MHz it has always run at, 2 gives 13.5MHz and 4
                    // gives 27MHz - and a read is 22 CK whatever the rate.
                    //
                    // What limits this is not the protocol but the margin the
                    // PHY samples with. It captures a byte one phase after the
                    // CK edge, and that phase has to cover the round trip: the
                    // FPGA driving CK, the die responding, and the data getting
                    // back to a fabric flip flop. One phase is 37ns at 1, 18.5
                    // at 2 and 9.3 at 4. Simulation cannot answer where that
                    // stops working, because the behavioural die has no timing
                    // - only the board can, which is what maptest.s is for.
                    parameter PSRAM_MULT = 2,
                    // Where in the cycle the memory's incoming bytes are
                    // captured, in sixteenths of the PSRAM clock period - so
                    // 0.58ns a step at 108MHz. "0000" samples where it always
                    // has; larger values move the capture later, to wherever the
                    // data has actually arrived by. This is the knob 4x needs,
                    // and the only way to find its value is to sweep it on the
                    // board and watch maptest.
                    //
                    // It has to be a string, and a real one. apycula reads this
                    // with int(parm, 2), so it wants the four characters "1100"
                    // and not a value that happens to spell them: build it with
                    // arithmetic and yosys forgets it was ever a string, writes
                    // the ASCII bits into the netlist, and apycula parses those
                    // thirty two bits as the number instead. Every phase then
                    // programs the same garbage, which looks exactly like the
                    // knob having no effect - a whole sweep of it here before I
                    // looked at what actually reached the netlist.
                    parameter PSRAM_PHASE = "0000",
                    // Whole phases, on top of PSRAM_PHASE's sixteenths. The two
                    // together are a coarse and a fine control over one thing:
                    // where in the cycle the pins are looked at.
                    parameter integer PSRAM_LATE = 0,
                    // Which pair of captured phases makes up a word. 2 is what
                    // the PHY has always effectively used; moving it shifts the
                    // capture a whole phase at a time, which is what a byte
                    // landing the far side of a cycle boundary needs and no
                    // amount of phase shifting can give.
                    parameter integer PSRAM_TAP = 2,
                    parameter [4:0] PSRAM_LATENCY = 6,
                    // The 8.3 name of the image file on the card, as it is
                    // stored in the directory: eight characters then three.
                    parameter [87:0] DISK_IMAGE = "HAWK0   IMG",
                    // The DMA pattern device at 0x3f300. It is a test device and
                    // costs real logic, so a normal build leaves it out; DmaTB
                    // turns it on. Like PSRAM_SELFTEST, this is a build time
                    // choice that no file records, so build.stamp tracks it.
                    parameter DMA_TEST = 0,
                    // The mapping RAM failure instrumentation: pass counters,
                    // the frozen compare pair, who wrote which buffer byte. It
                    // found that bug and the bug is fixed, so it is off, and
                    // switching it off is what makes room for the storage stack
                    // - it is several hundred logic cells of scaffolding on a
                    // device that is now 84% full. "make DIAG_TRACE=1" for it.
                    parameter DIAG_TRACE = 0,
                    // Whether a parity error is reported to the microcode at
                    // all. Storing the parity bit costs nothing either way;
                    // this only gates k9 == 6, so "make PARITY_CHECK=0" asks
                    // whether a fault this design reports is what aborts the
                    // operating system, without changing anything else.
                    parameter PARITY_CHECK = 1,
                    // Whether the diag board's ROMs are fitted at 0x08000. They
                    // have to be out to boot the operating system, which loads
                    // code there; see BoardMemory.v.
                    parameter DIAG_ROM = 1,
                    // See CPU6.v: K13 case 1 and the interrupt conditions.
                    parameter K13_INTERRUPTS = 1)
                 (input in_clk, input reset_btn, input btn2, output LED1, output LED2, output LED3, output LED4, output LED5, output LED6, output LED7, output LED8, output uart_tx, input uart_rx,
                  // The HyperRAM die shares the package. nextpnr places these on the
                  // dedicated pads by name, so the names have to be exactly these.
                  output [1:0] O_psram_ck, output [1:0] O_psram_ck_n,
                  output [1:0] O_psram_cs_n, output [1:0] O_psram_reset_n,
                  inout [1:0] IO_psram_rwds, inout [15:0] IO_psram_dq,
                  // The microSD slot. Only four of the card's pins are brought
                  // out on this board, so this is SPI and not four bit SD mode.
                  output sd_clk, output sd_mosi, input sd_miso, output sd_cs_n);

    reg reset;
    // reset_btn is a mechanical input with no relation to the clock, and it feeds the
    // reset of the whole core, so sample it through a synchroniser rather than directly.
    reg [2:0] reset_btn_sync;
    reg [9:0] por_counter;

    // por_done is the most trustworthy "is the CPU clock running" indicator available:
    // it is an ordinary fabric counter on the CPU clock, so it can only have expired if
    // that clock actually ticked 255 times.
    wire por_done = por_counter == 10'h3ff;   // 1024 clocks, four times what the
                                              // page table initialiser needs

    // Power on reset. The board's reset button only asserts reset while it is held,
    // so without this the core never runs its own reset sequence and depends entirely
    // on the global set/reset leaving every flip flop at zero.
    initial begin
        reset = 1;
        por_counter = 0;
        reset_btn_sync = 3'b111;
    end

    wire int_reqn;
    wire [3:0] irq_number;

    wire writeEnBus;
    wire [7:0] data_c2r, data_r2c;
    wire [18:0] addressBus;
    wire [7:0] leds;
    wire [7:0] display_leds;
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

    // Re-initialised on every reset, not just at power up. The mapping test leaves the
    // page table full of its own patterns, and nothing else puts it back, so after a
    // reset diag was starting up against whatever the previous run had left behind.



    // The LEDs are active low
    assign {LED1, LED2, LED3, LED4, LED5, LED6, LED7, LED8} = ~display_leds;
    wire instruction_start;
    wire cpu_alive;

    // The CPU runs directly from the 27MHz input pin, which arrives on a real global
    // clock network. It used to run from Divide4 through a BUFG, but a fabric driven
    // global is exactly what went wrong on hardware: the watchdog reported the divided
    // clock dead and reset stuck asserted, because the reset flop is clocked by it.
    // Timing closes at about 44MHz for this domain, so 27MHz has plenty of margin.
    // The core itself is slowed to the original 5MHz by ClockEnable below rather than
    // by a second clock.
    //
    // This has to be declared before anything uses it. Deleting it by accident, while
    // the PSRAM block below was being rewritten, made yosys declare `clock' implicitly
    // at its first use - an undriven net - which stopped the whole design's clock and
    // silently optimised the CPU away to 15 LUTs. The only outward sign was the
    // watchdog's crash blink on the LEDs, and the only sign in the log was one
    // "Identifier is implicitly declared" warning.
    wire clock = in_clk;

    // The memory. Everything HyperBus-specific - the PLL, the PHY and its pads,
    // the die's 600us wake up, the arbitration between the CPU's bridge and the
    // disk's cache, and the bring-up self test - is inside Psram. Out here
    // there are two ports, each speaking the same protocol: hold read or write
    // until busy rises, then wait for it to fall.
    wire [63:0] dout;          // four words: see PsramSdr's BURST
    wire psram_ready;
    // The disk image's side of the memory, arbitrated with the CPU's inside.
    wire disk_read, disk_write, disk_byte_write;
    wire [22:0] disk_addr;
    wire [15:0] disk_din;
    wire disk_busy_view, bus_busy_view;
    // What the instruments watch.
    wire busy, read, write;
    wire [3:0] sdr_state;
    wire [4:0] sdr_match;
    wire [15:0] sdr_echo, sdr_nonff;
    wire psram_done, psram_pass;
    wire [2:0] psram_stage;
    wire [15:0] psram_read0, psram_read1;

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
    wire cpu_en_free, cpu_en;


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
    wire psram_select = psram_select_raw && (PSRAM_SELFTEST == 0);

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

    // The core is enabled 5 clocks in every 27, giving the original CPU6's 5MHz -
    // except that PsramBus withholds the enable while a PSRAM access runs, so the
    // core sees a long bus cycle rather than a stall it has to understand.
    ClockEnable cpu_clock_enable(clock, cpu_en_free);

    Psram #(.PSRAM_MULT(PSRAM_MULT), .PSRAM_PHASE(PSRAM_PHASE), .PSRAM_LATE(PSRAM_LATE),
            .PSRAM_TAP(PSRAM_TAP), .PSRAM_LATENCY(PSRAM_LATENCY),
            .PSRAM_SELFTEST(PSRAM_SELFTEST)) psram(
        .clock(clock), .button_n(reset_btn_sync[2]), .reset(reset),
        .a_read(bus_read), .a_write(bus_write), .a_byte_write(bus_byte_write),
        .a_addr(bus_addr), .a_din(bus_din), .a_busy(bus_busy_view),
        .b_read(disk_read), .b_write(disk_write), .b_byte_write(disk_byte_write),
        .b_addr(disk_addr), .b_din(disk_din), .b_busy(disk_busy_view),
        .dout(dout), .ready(psram_ready),
        .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n), .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_rwds(IO_psram_rwds), .IO_psram_dq(IO_psram_dq),
        .dbg_busy(busy), .dbg_read(read), .dbg_write(write),
        .dbg_sdr_state(sdr_state), .dbg_sdr_match(sdr_match),
        .dbg_sdr_echo(sdr_echo), .dbg_sdr_nonff(sdr_nonff),
        .dbg_test_done(psram_done), .dbg_test_pass(psram_pass),
        .dbg_test_stage(psram_stage),
        .dbg_test_read0(psram_read0), .dbg_test_read1(psram_read1));

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
                   DIAG_DIP_SWITCHES, diag_data, diag_hex, diag_points, diag_blank);

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

    MUX #(.DEBUG(DIAG_TRACE)) mux0(in_clk, clock, cpu_en, reset, uart_rx, mux_uart_tx, mux_select,
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

    SdSpi sd(clock, reset, sd_clk, sd_mosi, sd_miso, sd_cs_n,
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
    HawkDisk hawk(clock, cpu_en, reset, hawk_select, addressBus[3:0], writeEnBus,
                  data_c2r, hawk_data,
                  hawk_req, hawk_write, hawk_wdata,
                  hawk_step, dma_rdata, dma_end, hawk_int, hawk_hold,
                  img_mounted, img_req, img_store, img_block, img_busy, img_failed,
                  hawk_ext_wr, hawk_ext_addr, hawk_ext_wdata, hawk_ext_rdata);

    CPU6 #(.K13_INTERRUPTS(K13_INTERRUPTS)) cpu (reset, clock, cpu_en, data_r2c, int_reqn, irq_number, writeEnBus, addressBus, data_c2r, instruction_start,
              ptinit_write, ptinit_addr, ptinit_addr, SENSE_SWITCHES,
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
    Instruments #(.DIAG_TRACE(DIAG_TRACE), .PSRAM_SELFTEST(PSRAM_SELFTEST),
                  .PARITY_CHECK(PARITY_CHECK)) instruments(
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

	always @ (posedge clock) begin
        reset_btn_sync <= { reset_btn_sync[1:0], reset_btn };
        if (!por_done || !psram_ready) begin
            if (!por_done) por_counter <= por_counter + 1;
            reset <= 1;
        end else if (cpu_en_free) begin
            // Release reset only on an enabled cycle, so the core always leaves reset
            // on a CPU clock edge whatever phase the clock enable happens to be in.
            // On the free running enable, not the one PsramBus gates: reset must not
            // depend on a signal the memory can withhold.
            reset <= ~reset_btn_sync[2];
        end
    end
endmodule



/**
 * CPU liveness watchdog.
 *
 * Runs in the free running 27MHz input clock domain so that it keeps working even when
 * the core is wedged. CPU6 pulses heartbeat once per instruction, at microcode address
 * 0x101. If none arrives for TIMEOUT clocks the core is considered dead and all eight
 * LEDs blink together at 1Hz instead of showing the LED panel, so a stopped machine is
 * obvious at a glance.
 */


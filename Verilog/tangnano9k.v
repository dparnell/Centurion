`include "CPU6.v"
`include "StatusDump.v"
`include "DiagBoard.v"
`include "PsramTest.v"
`include "PsramSdr.v"
`include "PsramBus.v"
// psram_controller.v is no longer built: it drives the bus through apicula's
// ODDR/IDDR, which is exactly what does not work here. Kept in the tree for
// reference, and because its four implicit declaration warnings are noise.
`include "BoardMemory.v"
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
module AddressDecode(input wire [18:0] address,
    output wire mux_select, output wire diag_select, output wire ram_select,
    output wire psram_select);

    // MUX serial board, 16 registers. This matches the Diag MUX addresses used by
    // CPU6TestBench.v (status 0x3f200, data 0x3f201) and by programs/hellorld.txt.
    assign mux_select = (address & 19'h7fff0) == 19'h3f200;

    // The Diag board: hex display, decimal points and DIP switches at 0x3f100.
    assign diag_select = (address & 19'h7ffe0) == 19'h3f100;

    // The block RAM regions, which must go on answering rather than being folded
    // into the PSRAM: they are about fourteen times faster, and everything the
    // machine runs today lives in them. These have to match BoardMemory.v.
    wire rom_region      = address[18:13] == 6'd4;                 // 0x08000
    wire ram_region      = address[18:12] == 7'h0b
                         || address[18:12] == 7'h0c;               // 0x0b000
    wire low_ram_region  = address[18:12] == 7'h00;                // 0x00000
    wire boot_region     = address[18:9]  == 10'h1fe;              // 0x3fc00
    assign ram_select = ~(mux_select | diag_select);

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
                    parameter PSRAM_MULT = 2)
                 (input in_clk, input reset_btn, input btn2, output LED1, output LED2, output LED3, output LED4, output LED5, output LED6, output LED7, output LED8, output uart_tx, input uart_rx,
                  // The HyperRAM die shares the package. nextpnr places these on the
                  // dedicated pads by name, so the names have to be exactly these.
                  output [1:0] O_psram_ck, output [1:0] O_psram_ck_n,
                  output [1:0] O_psram_cs_n, output [1:0] O_psram_reset_n,
                  inout [1:0] IO_psram_rwds, inout [15:0] IO_psram_dq);

    // PsramSdr drives all of these itself, including RESET#, which it pulses low at
    // start up the way the part wants rather than simply tying it high.

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
    reg [15:0] rx_count;
    reg byte_ready_d;
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

    // The PSRAM's clock, and the only thing in this design that is not the pin.
    // Everything else stays on `clock': the core cannot go faster - nextpnr puts
    // this design at about 50MHz and the page table lookup is the critical path
    // - so the memory is given its own domain and crossed into with a handshake
    // rather than dragging the whole machine up with it.
    //
    // FCLKOUT = FCLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1), and ODIV_SEL sets the VCO,
    // which has to land between 400MHz and 1200MHz: 27 * 2 * 16 is 864, and
    // 27 * 4 * 8 is the same.
    wire psram_clk;
    wire psram_lock;
    generate
    if (PSRAM_MULT == 1) begin: no_pll
        assign psram_clk = clock;
        assign psram_lock = 1'b1;
    end else begin: pll
        rPLL #(.FCLKIN("27"), .IDIV_SEL(0), .FBDIV_SEL(PSRAM_MULT-1),
               .ODIV_SEL(PSRAM_MULT == 2 ? 16 : 8), .DEVICE("GW1NR-9C"))
            psram_pll(.CLKOUT(psram_clk), .LOCK(psram_lock),
                      .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
                      .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clock), .CLKFB(1'b0),
                      .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
                      .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0));
    end
    endgenerate

    // The PSRAM runs from the board clock with no PLL at all: PsramSdr builds its
    // 6.75MHz bus clock from four phases of the 27MHz clock in fabric, because
    // apicula's ODDR/IDDR cannot be used here. That keeps the whole design in one
    // clock domain and sidesteps the apicula PLL packing bug as a bonus.
    wire read, write, byte_write;
    wire [21:0] address;
    wire [15:0] din;
    wire [63:0] dout;          // four words: see PsramSdr's BURST
    // ClockEnable's output before the PSRAM has had a chance to hold it back.
    wire [3:0] sdr_state;
    wire [4:0] sdr_match;
    wire [15:0] sdr_first, sdr_echo, sdr_nonff;

    // Crossing back out of the PSRAM's domain. busy is a level that changes
    // slowly compared with either clock and dout is stable by the time it falls,
    // so two flip flops on busy is the whole of it: everything else in the
    // protocol is already held steady across the handshake.
    wire busy_raw;
    reg [1:0] busy_sync;
    // Busy until proven otherwise. Starting these at zero says the memory is
    // ready before anything has asked it, and psram_ready is set from exactly
    // this signal - so the core left reset while the part was still in its
    // 300us wake up, and its first access sat there until the bridge gave up.
    // Three timeouts in eleven thousand accesses, all of them at boot.
    initial busy_sync = 2'b11;
    always @(posedge clock) busy_sync <= { busy_sync[0], busy_raw };
    wire busy = busy_sync[1];

    PsramSdr psram(
        .clk(psram_clk), .resetn(reset_btn & psram_lock),
        .read(read), .write(write), .addr(address), .din(din),
        .byte_write(byte_write), .dout(dout), .busy(busy_raw),
        .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n), .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_rwds(IO_psram_rwds), .IO_psram_dq(IO_psram_dq),
        .dbg_state(sdr_state), .dbg_match(sdr_match), .dbg_first(sdr_first),
        .dbg_nonff(sdr_nonff), .dbg_ca_echo(sdr_echo));

    // The bring-up self test. Held in reset and disconnected from the bus unless
    // PSRAM_SELFTEST is set, which is how to answer "is the memory itself still
    // good" without having to reason about the CPU at the same time. Build it
    // with "make PSRAM_SELFTEST=1"; the status dump then reports its result
    // instead of the bus counters.
    wire tst_read, tst_write, tst_byte_write;
    wire [21:0] tst_addr;
    wire [15:0] tst_din;
    // The part needs 600us to come out of its own reset, and the core's power on
    // reset is only 1024 clocks, so without this the CPU reaches the memory before
    // the memory exists. That is not a slow start, it is a hang: the bridge holds
    // the core's clock enable until the access completes, so the machine sits dead
    // with the watchdog blinking and even the status dump gone, because the request
    // for one is only noticed on an enabled cycle. Holding reset until the memory
    // answers is what the real machine's power on sequence does anyway.
    //
    // This latches rather than following busy, which goes high on every access.
    reg psram_ready;
    initial psram_ready = 0;
    always @(posedge clock) begin
        if (!reset_btn_sync[2]) psram_ready <= 0;   // the button resets the part too
        else if (!busy) psram_ready <= 1;
    end

    wire psram_done, psram_pass;
    wire [15:0] psram_got, psram_want;
    wire [21:0] psram_failed_at;
    wire [2:0] psram_stage, psram_index;
    wire psram_saw_idle;
    wire [15:0] psram_cycles, psram_read0, psram_read1;
    PsramTest psram_test(clock, reset_btn & (PSRAM_SELFTEST != 0),
                         tst_read, tst_write, tst_byte_write, tst_addr, tst_din,
                         dout[15:0], busy, psram_done, psram_pass,
                         psram_got, psram_want, psram_failed_at,
                         psram_stage, psram_index, psram_saw_idle, psram_cycles,
                         psram_read0, psram_read1);

    // The bus side. PsramBus owns the core's clock enable, because stalling the
    // core is how a 2.8us memory access is made to fit in a bus cycle.
    wire bus_read, bus_write, bus_byte_write;
    wire [21:0] bus_addr;
    wire [15:0] bus_din;
    wire [7:0] psram_data;
    wire [15:0] dbg_psram_accesses, dbg_psram_timeouts;
    wire [2:0] dbg_psram_where;
    wire [1:0] dbg_bus_state;
    wire dbg_bus_need;
    wire [18:0] dbg_psram_addr;
    wire [7:0] dbg_psram_data;
    wire cpu_en_free, cpu_en;

    assign read       = PSRAM_SELFTEST ? tst_read       : bus_read;
    assign write      = PSRAM_SELFTEST ? tst_write      : bus_write;
    assign byte_write = PSRAM_SELFTEST ? tst_byte_write : bus_byte_write;
    assign address    = PSRAM_SELFTEST ? tst_addr       : bus_addr;
    assign din        = PSRAM_SELFTEST ? tst_din        : bus_din;

    // Peripheral read bus ---------------------------
    // Every readable peripheral drives its own data_out, and this module picks one.
    // Previously BlockRAM, LEDPanel and MUX were all wired straight onto data_r2c.
    // Simulation resolved the undriven outputs as z and let the RAM value through, but
    // yosys reported a driver-driver conflict, resolved it to a constant and dropped
    // ram_cells entirely, so on hardware the CPU only ever read 'x' (decoded as HLT).
    wire mux_select, diag_select, ram_select, psram_select_raw;
    wire [7:0] ram_data, mux_data, diag_data;

    AddressDecode decode(addressBus, mux_select, diag_select, ram_select,
                         psram_select_raw);

    // With the self test running the CPU must not touch the memory at all, or the
    // two would fight over the controller and the core would stall for ever.
    wire psram_select = psram_select_raw && (PSRAM_SELFTEST == 0);

    assign data_r2c = mux_select   ? mux_data :
                      diag_select  ? diag_data :
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

    PsramBus #(.ENFORCE_SPACING(SPACING)) psram_bus(
        .clock(clock), .reset(reset), .cpu_en(cpu_en_free), .select(psram_select),
        .address(addressBus), .write_en(writeEnBus), .data_in(data_c2r),
        .data_out(psram_data), .cpu_en_out(cpu_en),
        .read(bus_read), .write(bus_write), .byte_write(bus_byte_write),
        .addr(bus_addr), .din(bus_din), .dout(dout), .busy(busy),
        .dbg_accesses(dbg_psram_accesses), .dbg_last_addr(dbg_psram_addr),
        .dbg_last_data(dbg_psram_data), .dbg_timeouts(dbg_psram_timeouts),
        .dbg_timeout_where(dbg_psram_where), .dbg_state(dbg_bus_state),
        .dbg_need(dbg_bus_need));

    BoardMemory #(.PROGRAM(PROGRAM)) ram(
        clock, cpu_en, addressBus, writeEnBus & ram_select, data_c2r, ram_data);
    LEDPanel panel(clock, cpu_en, addressBus, writeEnBus, data_c2r, leds);
    // The Diag board. Its DIP switches choose what diag does out of reset; see
    // DiagBoard.v for the settings. 0x1d is the auxiliary test menu and 0x1a is TOS,
    // the machine code monitor.
    wire [7:0] diag_hex;
    wire [3:0] diag_points;
    wire diag_blank;
    DiagBoard diag(clock, cpu_en, diag_select, addressBus[4:0], writeEnBus, data_c2r,
                   DIAG_DIP_SWITCHES, diag_data, diag_hex, diag_points, diag_blank);

    // e7 == 3 is the only cycle in which CPU6 latches the bus, so it is this
    // design's read strobe. Peripherals whose read has a side effect need it.
    wire bus_read_strobe = (dbg_e7 == 2'd3);

    MUX mux0(in_clk, clock, cpu_en, reset, uart_rx, mux_uart_tx, mux_select,
             { 1'b0, addressBus[3:0] }, writeEnBus, bus_read_strobe, data_c2r,
             interrupt_ack, mux_data, int_reqn, irq_number,
             dbg_byte_ready, dbg_rx_byte);

    CPU6 cpu (reset, clock, cpu_en, data_r2c, int_reqn, irq_number, writeEnBus, addressBus, data_c2r, instruction_start,
              ptinit_write, ptinit_addr, ptinit_addr, SENSE_SWITCHES,
              dbg_memory_address, dbg_uc_address, dbg_page_table_base, dbg_page_table_out,
              dbg_d2d3, dbg_f11,
              dbg_e7, dbg_data_in, dbg_entry0,
              dbg_e0_write, dbg_e0_value, dbg_e0_via_window,
              dbg_pt_write, dbg_pt_index, dbg_pt_value, dbg_pt_via_window, interrupt_ack);

    // Holding btn2 prints the CPU's position over the serial line, repeatedly. See
    // StatusDump.v. It takes the UART pin over, which is safe because the machine is
    // only worth interrogating when it has stopped printing.
    //
    // Freezes the last instruction fetch when the machine stops printing for two
    // seconds. Held down, btn2 then prints
    //     F 87b0 87ad 87b0 7e00 010d
    // which is
    //     1,2  the two most recent instruction fetches, still live, so a short loop
    //          shows up as the pair changing from line to line
    //     1,2  the two most recent instruction fetches, live
    //     3    the pass the mapping test has reached, still counting
    //     4    the pass its compare first failed on, 0000 if it never has
    //     5    0001 if the compare has failed, 0000 if not
    // A leading L means the machine has not gone quiet yet.
    //
    // The live pair is the point. The frozen fetch says where it stopped printing, but
    // it says nothing about where it went afterwards, and the mapping RAM test moves
    // the machine around on purpose.
    reg [15:0] pc_hist0, pc_hist1, pc_hist2, pc_hist3;
    reg [15:0] pc_live0, pc_live1;
    reg [7:0] last_io_page;

    // Bring-up aid for diag's mapping RAM test, which is the test being brought up, so
    // these two addresses are that program's and nothing else's. Its main loop starts
    // at 0x8e88 and it branches to 0x8f02 when the mapping RAM does not read back what
    // was written. Counting passes and freezing the count at the first failure says
    // whether the failure happens at the same point every run, which separates a bug in
    // the design from something marginal in the hardware.
    localparam [15:0] DIAG_LOOP_TOP = 16'h8e88;
    localparam [15:0] DIAG_COMPARE_FAILED = 16'h8f02;
    reg [15:0] pass_count;
    reg [15:0] fail_pass;
    reg compare_failed;
    // diag's block compare walks the mapping RAM copy at physical 0x100..0x1ff against
    // its reference at 0x200..0x2ff and branches on the first difference, so the last
    // low address it touched before branching names the entry that mismatched.
    reg [9:0] last_low_addr;
    // The one question the compare mismatch leaves open: at buffer offset 0 the PAGE
    // store wrote 00 where diag's reference holds 01. Either the store read the entry
    // wrongly, or the load never wrote 01 into it. Recording the byte the store put at
    // physical 0x100 together with the table entry it came from separates the two.
    reg [7:0] wr100_val, wr100_e0, wr200_val;
    reg [7:0] fwr100_val, fwr100_e0, fwr200_val;
    // Who writes the reference. Physical 0x200 offset 0 holds 01 at the failure while
    // everything on the store's side of the compare says 00, so the byte has to be
    // arriving from an instruction other than the one assumed.
    reg [15:0] wr100_pc, wr200_pc, wr200_count;
    reg [15:0] fwr100_pc, fwr200_pc, fwr200_count;
    // Which parts of diag's loop actually execute. The last three writes to table
    // index 0 all came from 0x8f04 and index 0 is written exactly once per pass, so
    // the load at 0x8ed1 - same map, same count, only a different source address -
    // appears never to write it. Count the fetches and find out whether it runs.
    // Characters the CPU hands to the MUX data register. diag's output arrives at the
    // terminal in bursts that line up with keystrokes rather than with the machine
    // reaching the code that prints, and this separates the two possible causes: if
    // this count runs ahead of what the host receives the MUX is not sending, and if it
    // does not move then diag never wrote the characters at all.
    reg [15:0] tx_chars;
    // diag's mapping test finishes without printing *** PASS ***. That message is at
    // 0x8f74 and is reached only if the BNZ at 0x8f72 falls through; taken, it goes to
    // 0x8fa6. The branch is gated on a word LDBW reads from 0x07dd, which nothing in
    // the ROM ever writes. Count the three fetches and capture what 0x07dd reads.
    // Where the mapping test goes once its outer loop finally exits at 0x8ea4. The
    // guesses made from a hand disassembly of 0x8f61..0x8f74 were wrong - none of that
    // code is ever fetched - so record the next four instruction addresses instead.
    reg [15:0] e0_, e1_, e2_, e3_;
    reg [2:0]  ecnt;
    reg        earm;
    reg [15:0] n_8ea7, n_8ec4, n_8ecc, n_8ed1, n_8f04;
    reg [15:0] fn_8ea7, fn_8ec4, fn_8ecc, fn_8ed1, fn_8f04;
    // The loop is: poke, load the whole table from 0x100, store it back to 0x100,
    // compare 0x100 against 0x200. So the value the table should end up holding at
    // index 0 arrives as a byte written to physical 0x100. Record every write there
    // that is not zero: if there are none, diag never poked the buffer and expects the
    // 01 to come from somewhere else entirely.
    reg [15:0] nzb_pc, nzb_count;
    reg [7:0]  nzb_val;
    reg [9:0]  nzb_addr, fnzb_addr;
    // Physical 0x200 - the first byte of diag's reference - is written exactly twice
    // in a whole run. Record both, with the pass each happened on. If the second is at
    // pass 57345 then diag is changing its expectation there and the table is supposed
    // to follow; if both are at the start then the reference has read 01 all along and
    // the compare should have failed on pass 1, which would mean the mismatching pair
    // has been misread.
    // diag pokes one byte per pass: LALY reads it through Y, INAL increments it, then
    // SALY writes it back through Y and SALZ mirrors it through Z. One of those two
    // stores is not landing where diag means it to. Record the physical address and
    // value of each.
    reg [15:0] saly_addr, salz_addr, fsaly_addr, fsalz_addr;
    reg [15:0] saly_va, salz_va, fsaly_va, fsalz_va;
    reg [7:0]  saly_val, salz_val, fsaly_val, fsalz_val;
    // Y walks one byte per pass over a large region, and the compare only covers the
    // 256 bytes at 0x200. Recording where the walk starts and which way it steps says
    // why the compare survives 57344 passes and then does not.
    reg [15:0] y_at1, y_at2, y_at3;
    reg [15:0] fy_at1, fy_at2, fy_at3;
    reg [15:0] w2p1, w2p2;
    reg [7:0]  w2v1, w2v2;
    reg [15:0] fw2p1, fw2p2;
    reg [7:0]  fw2v1, fw2v2;
    reg [15:0] fnzb_pc, fnzb_count;
    reg [7:0]  fnzb_val, fld_src;
    reg [7:0]  ld_src, last_rd_1xx;
    // Table index 0x00 is map 0 page 0, the entry the compare mismatches on. Count
    // every write to it, and separately remember the last write that put a non-zero
    // value there. diag's reference says the entry should read 01; if nothing ever
    // writes 01 into it then the 01 in the reference came from somewhere else and the
    // store's indexing is wrong, not the load's.
    // What the PAGE store actually reads. d2d3 == 8 puts a table entry on the DP bus;
    // record the index and value each time, then freeze whatever was read last when
    // the store writes buffer offset 0 at physical 0x100. That says which entry the
    // first byte of diag's snapshot really came from.
    reg [7:0] sr_index, sr_value, fsr_index, fsr_value;
    reg [15:0] idx0_count, nz0_count, nz0_pc;
    reg [7:0]  nz0_val;
    reg [15:0] fidx0_count, fnz0_count, fnz0_pc;
    reg [7:0]  fnz0_val;
    reg [9:0] fail_addr;
    // The map in use when the compare failed. diag runs its own code in map 0 but
    // tests maps 1 to 7 and then 0, so this says which invocation went wrong.
    reg [2:0] fail_base;
    // Which instruction reaches the PSRAM, and through which map. Nothing diag does
    // during this test should leave page 0 of map 0 - its code, its stack and its
    // buffers are all identity mapped into the block RAM - so any access that lands
    // in the PSRAM at all is already wrong, and the map it went through names the
    // culprit. Frozen at the compare failure like everything else.
    reg [15:0] ps_pc, ps_va;
    reg [18:0] ps_pa;
    reg [2:0]  ps_base;
    reg [15:0] ps_count;
    reg [15:0] fps_pc, fps_va;
    reg [18:0] fps_pa;
    reg [2:0]  fps_base;
    reg [15:0] fps_count;
    // Bus writes that went through a map other than 0. diag runs entirely in map 0 -
    // its code, its stack and its buffers are all there - and the PAGE instruction is
    // supposed to put the base back before its own memory side access. So every one of
    // these is a store landing at the wrong physical address, and the count says
    // whether that is happening at all before any theory about why.
    reg [15:0] wb_pc, wb_va;
    reg [18:0] wb_pa;
    reg [2:0]  wb_base;
    reg [15:0] wb_count;
    reg [15:0] fwb_pc, fwb_va;
    reg [18:0] fwb_pa;
    reg [2:0]  fwb_base;
    reg [15:0] fwb_count;
    // The load half of PAGE reads a byte from memory and writes it into a page table
    // entry. Every failure so far is an entry that came back 00 when its source byte
    // held its identity value, so catch the write that puts a zero into a non-zero
    // entry and record the buffer byte read immediately before it - that is the
    // source the load had in hand.
    reg [7:0]  z0_index, z0_value, z0_src;
    reg [9:0]  z0_src_addr;
    reg [15:0] z0_pc, z0_count;
    reg [7:0]  fz0_index, fz0_value, fz0_src;
    reg [9:0]  fz0_src_addr;
    reg [15:0] fz0_pc, fz0_count;
    // The most recent read out of the buffer page, live: {address, value}.
    reg [17:0] buf_rd;

    reg [15:0] rb_pc, rb_va;
    reg [18:0] rb_pa;
    reg [2:0]  rb_base;
    reg [15:0] rb_count;
    reg [15:0] frb_pc, frb_va;
    reg [18:0] frb_pa;
    reg [2:0]  frb_base;
    reg [15:0] frb_count;
    // Both of diag's verdict messages are printed by a JSR to virtual 0x07cc, and
    // nothing has ever come out of it. Capture what that address resolved to the first
    // time it is fetched: the page table base in use and the entry for page 0. An entry
    // pointing into ROM means the routine is real code; 0x00 means it is empty RAM.
    localparam [15:0] DIAG_PRINT = 16'h07cc;
    reg [7:0] print_entry;
    reg [2:0] print_base;
    reg print_seen;
    // Which instruction jumped to 0x8f02. diag branches there from 0x8e97 when its
    // mapping RAM compare fails; arriving from anywhere else means the test finished
    // its loop normally and 0x8f02 is on the completion path, not the failure path.
    // That distinction decides whether the test is passing, and the dump has never
    // been able to answer it because diag's own verdict never prints.
    reg [15:0] fail_from;
    // Ring of the last four writes to entry 0 of the running map, frozen at the failure.
    reg [7:0] e0v0, e0v1, e0v2, e0v3;
    reg e0w0, e0w1, e0w2, e0w3;
    reg [7:0] fe0v0, fe0v1, fe0v2, fe0v3;
    reg fe0w0, fe0w1, fe0w2, fe0w3;
    // Writes whose value is not the entry's own identity value. If diag's test pattern
    // ever reaches the table, it shows up here; if this stays empty, the pattern never
    // gets written at all.
    // Every write to table index 0x00 exactly, which is map 0 page 0: the entry diag's
    // compare fails on. Value, instruction and path for the last three, frozen at the
    // failure.
    reg [7:0] z_v0, z_v1, z_v2;
    reg [15:0] z_p0, z_p1, z_p2;
    reg z_w0, z_w1, z_w2;
    reg [7:0] fz_v0, fz_v1, fz_v2;
    reg [15:0] fz_p0, fz_p1, fz_p2;
    reg fz_w0, fz_w1, fz_w2;
    reg [7:0] ni_i0, ni_i1, ni_i2, ni_v0, ni_v1, ni_v2;
    reg [15:0] ni_pc, ni_count;
    reg [7:0] fni_i0, fni_i1, fni_i2, fni_v0, fni_v1, fni_v2;
    reg [15:0] fni_pc, fni_count;
    reg [15:0] e0p0, e0p1, e0p2, e0p3;      // the instruction doing each write
    reg [15:0] fe0p0, fe0p1, fe0p2, fe0p3;
    // diag's compare walks the buffer at physical 0x100 against its reference at 0x200
    // and stops at the first difference. Capture the last byte read from each region,
    // so the dump reports the mismatching pair itself rather than just where it stopped.
    reg [7:0] last_buf, last_ref;
    reg [7:0] fail_buf, fail_ref;
    reg [17:0] rd0, rd1, rd2, rd3;        // {address[9:0], value[7:0]}
    reg [17:0] f0, f1, f2, f3;            // frozen at the branch
    reg [7:0] fentry0;                    // entry 0 of the running map, frozen too
    reg fault_caught;
    reg [26:0] quiet_counter;
    initial begin
        pc_hist0 = 0; pc_hist1 = 0; pc_hist2 = 0; pc_hist3 = 0;
        pc_live0 = 0; pc_live1 = 0;
        last_io_page = 0;
        pass_count = 0; fail_pass = 0; compare_failed = 0;
        last_low_addr = 0; fail_addr = 0;
        print_entry = 0; print_base = 0; print_seen = 0;
        fail_from = 0;
        e0v0=0; e0v1=0; e0v2=0; e0v3=0; e0w0=0; e0w1=0; e0w2=0; e0w3=0;
        fe0v0=0; fe0v1=0; fe0v2=0; fe0v3=0; fe0w0=0; fe0w1=0; fe0w2=0; fe0w3=0;
        e0p0=0; e0p1=0; e0p2=0; e0p3=0; fe0p0=0; fe0p1=0; fe0p2=0; fe0p3=0;
        rd0=0; rd1=0; rd2=0; rd3=0; f0=0; f1=0; f2=0; f3=0;
        z_v0=0; z_v1=0; z_v2=0; z_p0=0; z_p1=0; z_p2=0; z_w0=0; z_w1=0; z_w2=0;
        fz_v0=0; fz_v1=0; fz_v2=0; fz_p0=0; fz_p1=0; fz_p2=0; fz_w0=0; fz_w1=0; fz_w2=0;
        ni_i0=0; ni_i1=0; ni_i2=0; ni_v0=0; ni_v1=0; ni_v2=0; ni_pc=0; ni_count=0;
        fni_i0=0; fni_i1=0; fni_i2=0; fni_v0=0; fni_v1=0; fni_v2=0; fni_pc=0; fni_count=0;
        last_buf = 0; last_ref = 0; fail_buf = 0; fail_ref = 0;
        rd0 = 0; rd1 = 0; rd2 = 0; rd3 = 0;
        f0 = 0; f1 = 0; f2 = 0; f3 = 0; fentry0 = 0;
        fault_caught = 0;
        quiet_counter = 0;
    end

    // What the last access to the page holding the serial board actually mapped to.
    // 0xf200 is the MUX, so its virtual page is 0xf200 >> 11, and the board is at
    // physical 0x3f200, so a healthy mapping reads back 0x3f200 >> 11 = 0x7e.
    always @(posedge clock) begin
        if (cpu_en && dbg_memory_address[15:11] == 5'h1e) begin
            last_io_page <= dbg_page_table_out;
        end
    end
    wire instruction_fetch = cpu_en & instruction_start;
    wire uart_written = cpu_en & writeEnBus & mux_select & (addressBus[3:0] == 4'd1);

    always @(posedge clock) begin
        // This has to follow the core's reset like everything else with state. It did
        // not, and compare_failed latches high for good, so after a reset fail_pass
        // still held the value from the first run after configuration and could never
        // update again. Every reading taken after a reset was the first run's number
        // repeated back, which made an unrepeated measurement look repeatable across
        // four different designs.
        if (reset) begin
            pass_count <= 0;
            fail_pass <= 0;
            compare_failed <= 0;
            last_low_addr <= 0;
            fail_addr <= 0;
            fail_base <= 0;
            ps_pc <= 0; ps_va <= 0; ps_pa <= 0; ps_base <= 0; ps_count <= 0;
            fps_pc <= 0; fps_va <= 0; fps_pa <= 0; fps_base <= 0; fps_count <= 0;
            wb_pc <= 0; wb_va <= 0; wb_pa <= 0; wb_base <= 0; wb_count <= 0;
            fwb_pc <= 0; fwb_va <= 0; fwb_pa <= 0; fwb_base <= 0; fwb_count <= 0;
            z0_index <= 0; z0_value <= 0; z0_src <= 0; z0_src_addr <= 0;
            z0_pc <= 0; z0_count <= 0; buf_rd <= 0;
            fz0_index <= 0; fz0_value <= 0; fz0_src <= 0; fz0_src_addr <= 0;
            fz0_pc <= 0; fz0_count <= 0;
            rb_pc <= 0; rb_va <= 0; rb_pa <= 0; rb_base <= 0; rb_count <= 0;
            frb_pc <= 0; frb_va <= 0; frb_pa <= 0; frb_base <= 0; frb_count <= 0;
            print_entry <= 0;
            print_base <= 0;
            print_seen <= 0;
            fail_from <= 0;
            e0v0<=0; e0v1<=0; e0v2<=0; e0v3<=0; e0w0<=0; e0w1<=0; e0w2<=0; e0w3<=0;
            fe0v0<=0; fe0v1<=0; fe0v2<=0; fe0v3<=0; fe0w0<=0; fe0w1<=0; fe0w2<=0; fe0w3<=0;
            e0p0<=0; e0p1<=0; e0p2<=0; e0p3<=0; fe0p0<=0; fe0p1<=0; fe0p2<=0; fe0p3<=0;
            rd0<=0; rd1<=0; rd2<=0; rd3<=0; f0<=0; f1<=0; f2<=0; f3<=0;
            z_v0<=0; z_v1<=0; z_v2<=0; z_p0<=0; z_p1<=0; z_p2<=0; z_w0<=0; z_w1<=0; z_w2<=0;
            fz_v0<=0; fz_v1<=0; fz_v2<=0; fz_p0<=0; fz_p1<=0; fz_p2<=0; fz_w0<=0; fz_w1<=0; fz_w2<=0;
            ni_i0<=0; ni_i1<=0; ni_i2<=0; ni_v0<=0; ni_v1<=0; ni_v2<=0; ni_pc<=0; ni_count<=0;
            fni_i0<=0; fni_i1<=0; fni_i2<=0; fni_v0<=0; fni_v1<=0; fni_v2<=0; fni_pc<=0; fni_count<=0;
            last_buf <= 0; last_ref <= 0; fail_buf <= 0; fail_ref <= 0;
            wr100_val <= 0; wr100_e0 <= 0; wr200_val <= 0;
            fwr100_val <= 0; fwr100_e0 <= 0; fwr200_val <= 0;
            sr_index <= 0; sr_value <= 0; fsr_index <= 0; fsr_value <= 0;
            nzb_pc <= 0; nzb_count <= 0; nzb_val <= 0;
            nzb_addr <= 0; fnzb_addr <= 0;
            saly_addr <= 0; salz_addr <= 0; fsaly_addr <= 0; fsalz_addr <= 0;
            saly_va <= 0; salz_va <= 0; fsaly_va <= 0; fsalz_va <= 0;
            y_at1 <= 0; y_at2 <= 0; y_at3 <= 0;
            fy_at1 <= 0; fy_at2 <= 0; fy_at3 <= 0;
            saly_val <= 0; salz_val <= 0; fsaly_val <= 0; fsalz_val <= 0;
            w2p1 <= 0; w2p2 <= 0; w2v1 <= 0; w2v2 <= 0;
            fw2p1 <= 0; fw2p2 <= 0; fw2v1 <= 0; fw2v2 <= 0;
            fnzb_pc <= 0; fnzb_count <= 0; fnzb_val <= 0; fld_src <= 0;
            ld_src <= 0; last_rd_1xx <= 0;
            tx_chars <= 0;
            e0_ <= 0; e1_ <= 0; e2_ <= 0; e3_ <= 0; ecnt <= 0; earm <= 0;
            n_8ea7 <= 0; n_8ec4 <= 0; n_8ecc <= 0; n_8ed1 <= 0; n_8f04 <= 0;
            fn_8ea7 <= 0; fn_8ec4 <= 0; fn_8ecc <= 0; fn_8ed1 <= 0; fn_8f04 <= 0;
            wr100_pc <= 0; wr200_pc <= 0; wr200_count <= 0;
            fwr100_pc <= 0; fwr200_pc <= 0; fwr200_count <= 0;
            idx0_count <= 0; nz0_count <= 0; nz0_pc <= 0; nz0_val <= 0;
            fidx0_count <= 0; fnz0_count <= 0; fnz0_pc <= 0; fnz0_val <= 0;
            rd0 <= 0; rd1 <= 0; rd2 <= 0; rd3 <= 0;
            f0 <= 0; f1 <= 0; f2 <= 0; f3 <= 0; fentry0 <= 0;
            fault_caught <= 0;
            quiet_counter <= 0;
            pc_hist0 <= 0; pc_hist1 <= 0; pc_hist2 <= 0; pc_hist3 <= 0;
            pc_live0 <= 0; pc_live1 <= 0;
        end else begin
        if (cpu_en && !compare_failed && dbg_e7 == 3
            && addressBus[18:10] == 9'd0 && addressBus[9:8] != 2'b00) begin
            rd3 <= rd2; rd2 <= rd1; rd1 <= rd0;
            rd0 <= { addressBus[9:0], dbg_data_in };
        end
        if (cpu_en && !compare_failed && dbg_pt_write && dbg_pt_index == 8'h00) begin
            idx0_count <= idx0_count + 1;
            if (dbg_pt_value != 8'h00) begin
                nz0_count <= nz0_count + 1;
                nz0_pc <= pc_live0;
                nz0_val <= dbg_pt_value;
            end
            z_v2 <= z_v1; z_v1 <= z_v0; z_v0 <= dbg_pt_value;
            z_p2 <= z_p1; z_p1 <= z_p0; z_p0 <= pc_live0;
            z_w2 <= z_w1; z_w1 <= z_w0; z_w0 <= dbg_pt_via_window;
        end
        if (cpu_en && !compare_failed && dbg_pt_write && dbg_pt_value != dbg_pt_index) begin
            ni_i2 <= ni_i1; ni_i1 <= ni_i0; ni_i0 <= dbg_pt_index;
            ni_v2 <= ni_v1; ni_v1 <= ni_v0; ni_v0 <= dbg_pt_value;
            ni_pc <= pc_live0;
            ni_count <= ni_count + 1;
        end
        if (cpu_en && !compare_failed && dbg_e0_write) begin
            e0v3 <= e0v2; e0v2 <= e0v1; e0v1 <= e0v0; e0v0 <= dbg_e0_value;
            e0w3 <= e0w2; e0w2 <= e0w1; e0w1 <= e0w0; e0w0 <= dbg_e0_via_window;
            e0p3 <= e0p2; e0p2 <= e0p1; e0p1 <= e0p0; e0p0 <= pc_live0;
        end
        if (cpu_en && !compare_failed && addressBus[18:10] == 9'd0)
            last_low_addr <= addressBus[9:0];

        if (cpu_en && !compare_failed && dbg_e7 == 2'd3 && addressBus[18:10] == 9'd0)
            buf_rd <= { addressBus[9:0], dbg_data_in };

        if (cpu_en && !compare_failed && dbg_pt_write
            && dbg_pt_value == 8'h00 && dbg_pt_index != 8'h00) begin
            z0_index <= dbg_pt_index;
            z0_value <= dbg_pt_value;
            z0_src <= buf_rd[7:0];
            z0_src_addr <= buf_rd[17:8];
            z0_pc <= pc_live0;
            z0_count <= z0_count + 1;
        end

        // A real bus read - e7 == 3 is the only cycle in which CPU6 latches the bus -
        // taken through a map other than 0. The bridge fetches speculatively whenever
        // the MAR happens to point into the PSRAM, so an access at a wrong-map address
        // proves nothing on its own; this is the one that the microcode actually
        // consumed.
        if (cpu_en && !compare_failed && dbg_e7 == 2'd3 && dbg_page_table_base != 3'd0) begin
            rb_pc <= pc_live0;
            rb_va <= dbg_memory_address;
            rb_pa <= addressBus;
            rb_base <= dbg_page_table_base;
            rb_count <= rb_count + 1;
        end

        if (cpu_en && !compare_failed && writeEnBus && dbg_page_table_base != 3'd0) begin
            wb_pc <= pc_live0;
            wb_va <= dbg_memory_address;
            wb_pa <= addressBus;
            wb_base <= dbg_page_table_base;
            wb_count <= wb_count + 1;
        end

        if (cpu_en && !compare_failed && psram_select) begin
            ps_pc <= pc_live0;
            ps_va <= dbg_memory_address;
            ps_pa <= addressBus;
            ps_base <= dbg_page_table_base;
            ps_count <= ps_count + 1;
        end

        // Every byte the CPU reads out of the buffer page, and the one that was in
        // hand when the table's index 0 was last written.
        if (cpu_en && !compare_failed && dbg_e7 == 3 && addressBus[18:8] == 11'h001)
            last_rd_1xx <= dbg_data_in;
        if (cpu_en && !compare_failed && dbg_pt_write && dbg_pt_index == 8'h00)
            ld_src <= last_rd_1xx;

        // Widened from physical 0x100 to the whole buffer region. Nothing ever wrote a
        // non-zero byte to 0x100 itself, so diag's poke of the pattern is landing at
        // some other address and this says which.
        if (cpu_en && !compare_failed && writeEnBus
            && addressBus[18:10] == 9'd0 && addressBus[9:8] != 2'b00
            && data_c2r != 8'h00) begin
            nzb_pc <= pc_live0;
            nzb_val <= data_c2r;
            nzb_addr <= addressBus[9:0];
            nzb_count <= nzb_count + 1;
        end

        if (uart_written) tx_chars <= tx_chars + 1;



        if (cpu_en && !compare_failed && dbg_d2d3 == 4'd8) begin
            sr_index <= dbg_pt_index;
            sr_value <= dbg_page_table_out;
        end

        if (cpu_en && !compare_failed && writeEnBus && pc_live0 == 16'h8e8a) begin
            saly_addr <= addressBus[15:0];
            saly_va   <= dbg_memory_address;
            saly_val  <= data_c2r;
            if (pass_count == 16'd1) y_at1 <= dbg_memory_address;
            if (pass_count == 16'd2) y_at2 <= dbg_memory_address;
            if (pass_count == 16'd3) y_at3 <= dbg_memory_address;
        end
        if (cpu_en && !compare_failed && writeEnBus && pc_live0 == 16'h8e8b) begin
            salz_addr <= addressBus[15:0];
            salz_va   <= dbg_memory_address;
            salz_val  <= data_c2r;
        end

        if (cpu_en && !compare_failed && writeEnBus) begin
            if (addressBus == 19'h00100) begin
                wr100_val <= data_c2r;
                wr100_e0  <= dbg_entry0;
                wr100_pc  <= pc_live0;
                fsr_index <= sr_index;
                fsr_value <= sr_value;
            end
            if (addressBus == 19'h00200) begin
                wr200_val   <= data_c2r;
                wr200_pc    <= pc_live0;
                wr200_count <= wr200_count + 1;
                w2p2 <= w2p1; w2v2 <= w2v1;
                w2p1 <= pass_count; w2v1 <= data_c2r;
            end
        end

        // Keep the last four bytes read out of the compare's buffers, address and value
        // together, and freeze them when it branches. Guessing which pair matters has
        // not worked: watching only 0x1xx against 0x2xx produced nothing, and there is a
        // second compare and a second pair of PAGE buffers at 0x300. Recording whatever
        // it actually read last avoids having to know in advance.
        if (cpu_en && !compare_failed && dbg_e7 == 3
            && addressBus[18:10] == 9'd0 && addressBus[9:8] != 2'b00) begin
            rd3 <= rd2;
            rd2 <= rd1;
            rd1 <= rd0;
            rd0 <= { addressBus[9:0], dbg_data_in };
        end

        if (instruction_fetch) begin
            pc_live0 <= dbg_memory_address;
            pc_live1 <= pc_live0;
            if (dbg_memory_address == DIAG_LOOP_TOP) pass_count <= pass_count + 1;
            if (dbg_memory_address == 16'h8ea4 && !earm) earm <= 1;
            else if (earm && ecnt != 3'd4) begin
                ecnt <= ecnt + 1;
                case (ecnt)
                    0: e0_ <= dbg_memory_address;
                    1: e1_ <= dbg_memory_address;
                    2: e2_ <= dbg_memory_address;
                    3: e3_ <= dbg_memory_address;
                endcase
            end
            if (!compare_failed) begin
                // 8e9d INRW Y and 8ea1 DCX are the outer loop; 8ea4 POP is the exit
                // past the BNZ at 8ea2. The outer loop should run 224 times, once per
                // byte of the table image from 0x120 to 0x1ff.
                if (dbg_memory_address == 16'h8e99) n_8ea7 <= n_8ea7 + 1;
                if (dbg_memory_address == 16'h8e9d) n_8ec4 <= n_8ec4 + 1;
                if (dbg_memory_address == 16'h8ea1) n_8ecc <= n_8ecc + 1;
                if (dbg_memory_address == 16'h8ea2) n_8ed1 <= n_8ed1 + 1;
                if (dbg_memory_address == 16'h8ea4) n_8f04 <= n_8f04 + 1;
            end
            if (dbg_memory_address == DIAG_PRINT && !print_seen) begin
                print_seen <= 1;
                print_entry <= dbg_page_table_out;
                print_base <= dbg_page_table_base;
            end
            if (dbg_memory_address == DIAG_COMPARE_FAILED && !compare_failed) begin
                compare_failed <= 1;
                fail_pass <= pass_count;
                fail_from <= pc_live0;   // the instruction that jumped to 0x8f02
                fail_base <= dbg_page_table_base;
                fps_pc <= ps_pc; fps_va <= ps_va; fps_pa <= ps_pa;
                fps_base <= ps_base; fps_count <= ps_count;
                fwb_pc <= wb_pc; fwb_va <= wb_va; fwb_pa <= wb_pa;
                fwb_base <= wb_base; fwb_count <= wb_count;
                frb_pc <= rb_pc; frb_va <= rb_va; frb_pa <= rb_pa;
                frb_base <= rb_base; frb_count <= rb_count;
                fz0_index <= z0_index; fz0_value <= z0_value; fz0_src <= z0_src;
                fz0_src_addr <= z0_src_addr; fz0_pc <= z0_pc; fz0_count <= z0_count;
                fe0v0 <= e0v0; fe0v1 <= e0v1; fe0v2 <= e0v2; fe0v3 <= e0v3;
                fe0w0 <= e0w0; fe0w1 <= e0w1; fe0w2 <= e0w2; fe0w3 <= e0w3;
                fe0p0 <= e0p0; fe0p1 <= e0p1; fe0p2 <= e0p2; fe0p3 <= e0p3;
                fni_i0 <= ni_i0; fni_i1 <= ni_i1; fni_i2 <= ni_i2;
                fni_v0 <= ni_v0; fni_v1 <= ni_v1; fni_v2 <= ni_v2;
                fni_pc <= ni_pc; fni_count <= ni_count;
                f0 <= rd0; f1 <= rd1; f2 <= rd2; f3 <= rd3;
                fz_v0 <= z_v0; fz_v1 <= z_v1; fz_v2 <= z_v2;
                fz_p0 <= z_p0; fz_p1 <= z_p1; fz_p2 <= z_p2;
                fz_w0 <= z_w0; fz_w1 <= z_w1; fz_w2 <= z_w2;
                fentry0 <= dbg_entry0;
                fwr100_val <= wr100_val; fwr100_e0 <= wr100_e0;
                fwr200_val <= wr200_val;
                fnzb_pc <= nzb_pc; fnzb_val <= nzb_val; fnzb_count <= nzb_count;
                fnzb_addr <= nzb_addr;
                fy_at1 <= y_at1; fy_at2 <= y_at2; fy_at3 <= y_at3;
                fsaly_va <= saly_va; fsalz_va <= salz_va;
                fsaly_addr <= saly_addr; fsaly_val <= saly_val;
                fsalz_addr <= salz_addr; fsalz_val <= salz_val;
                fw2p1 <= w2p1; fw2v1 <= w2v1;
                fw2p2 <= w2p2; fw2v2 <= w2v2;
                fld_src <= ld_src;
                fn_8ea7 <= n_8ea7; fn_8ec4 <= n_8ec4; fn_8ecc <= n_8ecc;
                fn_8ed1 <= n_8ed1; fn_8f04 <= n_8f04;
                fwr100_pc <= wr100_pc; fwr200_pc <= wr200_pc;
                fwr200_count <= wr200_count;
                fidx0_count <= idx0_count; fnz0_count <= nz0_count;
                fnz0_pc <= nz0_pc; fnz0_val <= nz0_val;
            end
            if (!fault_caught) begin
                pc_hist0 <= dbg_memory_address;
                pc_hist1 <= pc_hist0;
                pc_hist2 <= pc_hist1;
                pc_hist3 <= pc_hist2;
            end
        end

        // Freeze when the machine has printed nothing for two seconds while still
        // executing. Running below 0x0100 is NOT a fault: the mapping test relocates
        // itself into the register file region on purpose, because that is the one
        // place unaffected by the mapping RAM it is rewriting. Going quiet is.
        // Freeze on the compare failure too, not just on going quiet, so the frozen
        // fetch is the failure itself rather than wherever it wandered afterwards.
        if (instruction_fetch && dbg_memory_address == DIAG_COMPARE_FAILED)
            fault_caught <= 1;

        if (uart_written || fault_caught) begin
            quiet_counter <= 0;
        end else if (quiet_counter == 54_000_000 - 1) begin
            fault_caught <= 1;
        end else begin
            quiet_counter <= quiet_counter + 1;
        end
        end
    end

    // Count every byte the receiver has ever completed, so a dead receive path shows up
    // as a count that does not move when a key is pressed.
    initial begin
        rx_count = 0;
        byte_ready_d = 0;
    end
    always @(posedge clock) begin
        byte_ready_d <= dbg_byte_ready;
        if (dbg_byte_ready && !byte_ready_d) rx_count <= rx_count + 1;
    end

    // Verdict for diag's mapping RAM test, and deliberately not routed through diag's
    // own output. The serial text is not a reliable oracle here: the banner and the
    // verdict arrive long after the event, so "nothing was printed" cannot be read as
    // "nothing went wrong". Believing it once cost a wrong conclusion. These five
    // words come straight off the core.
    //
    // Before the failure, live state so a running test can be told from a hung one:
    //
    //   0  live program counter          3  passes completed so far
    //   1  microcode address             4  0000
    //   2  passes completed so far
    //
    // After it, the compare that failed. f0 is the last byte diag's compare read out
    // of physical 0x100..0x3ff and f1 the one before, which is the mismatching pair:
    //
    //   0  address of the newest read    3  the pass it failed on
    //   1  {newest byte, previous byte}  4  0001
    //   2  address of the previous read
    // After the failure: the last three writes to table index 0x00, newest first, as
    // the instruction that did the write and the value it wrote. Index 0 is map 0
    // page 0, the entry the compare mismatches on.
    //
    //   0  instruction of the newest write   3  value of the previous write
    //   1  value of the newest write         4  value of the one before that
    //   2  instruction of the previous write
    // After the failure: the last three table writes whose value was not the entry's
    // own index, newest first, and how many such writes there have been. An identity
    // write tells us nothing; these are the test's pattern going in.
    //
    //   0  instruction of the newest      3  {index, value} of the third newest
    //   1  {index, value} of the newest   4  count of non-identity writes
    //   2  {index, value} of the previous
    // After the failure:
    //
    //   0  byte the store last wrote to physical 0x100 (buffer offset 0)
    //   1  table entry 0 of the running map at that moment
    //   2  byte last written to physical 0x200 (reference offset 0)
    //   3  the pass it failed on
    //   4  table entry 0 frozen at the failure
    //
    // If word 1 already reads 00 the load never put 01 in the entry; if it reads 01
    // while word 0 reads 00 the store's read path is at fault.
    // After the failure:
    //
    //   0  instruction of the last write that put a non-zero value in table index 0
    //   1  the value that write put there
    //   2  how many non-zero writes to index 0 there have been
    //   3  how many writes to index 0 there have been at all
    //   4  the pass it failed on
    // After the failure, the store's own view of buffer offset 0:
    //
    //   0  table index the store last read before writing physical 0x100
    //   1  the entry value it read there
    //   2  the byte it actually wrote to physical 0x100
    //   3  the byte at physical 0x200, which is what diag expects
    //   4  the pass it failed on
    // After the failure, who wrote each side of the mismatching pair:
    //
    //   0  instruction that last wrote physical 0x200, the reference
    //   1  {byte it wrote there, byte last written to physical 0x100}
    //   2  how many writes to physical 0x200 there have been
    //   3  instruction that last wrote physical 0x100, the buffer
    //   4  the pass it failed on
    // After the failure, how often each part of diag's loop ran, against a pass count
    // of 57345:
    //
    //   0  8ea7  store map 0 -> 0x300     3  8ed1  load map 0 <- 0x300
    //   1  8ec4  MVF                      4  8f04  load map 0 <- 0x100
    //   2  8ecc  store map 1 -> 0x300
    // After the failure:
    //
    //   0  instruction of the last non-zero write to physical 0x100, the buffer
    //   1  {value it wrote, byte in hand when table index 0 was last written}
    //   2  how many non-zero writes to physical 0x100 there have been
    //   3  {value last written to table index 0, byte last written to 0x200}
    //   4  the pass it failed on
    // After the failure, the last non-zero byte written anywhere in the buffer region
    // physical 0x100..0x3ff:
    //
    //   0  the instruction that wrote it     3  how many such writes there have been
    //   1  the physical address it wrote     4  the pass it failed on
    //   2  {the value, value last written to table index 0}
    // After the failure, both writes physical 0x200 ever received:
    //
    //   0  the pass the newest happened on   3  {value of the older}
    //   1  {value of the newest}             4  the pass it failed on
    //   2  the pass the older happened on
    // After the failure, where diag's two pokes actually went:
    //
    //   0  physical address SALY last wrote     3  {value SALZ wrote}
    //   1  {value SALY wrote}                   4  the pass it failed on
    //   2  physical address SALZ last wrote
    // After the failure, diag's two pokes as asked for and as delivered:
    //
    //   0  virtual address SALY used      3  physical address SALZ reached
    //   1  physical address SALY reached  4  the pass it failed on
    //   2  virtual address SALZ used
    // After the failure, where diag's walking pointer Y was on the first three passes
    // and on the last:
    //
    //   0  Y on pass 1     2  Y on pass 3        4  the pass it failed on
    //   1  Y on pass 2     3  Y at the failure
    // After the failure, how many times each step of diag's loops ran:
    //
    //   0  8e99 DCR, the inner counter    3  8ea2 BNZ, the outer test
    //   1  8e9d INRW Y, the outer step    4  8ea4 POP, the exit
    //   2  8ea1 DCX, the outer counter
    //   0  live program counter                3  passes completed
    //   1  microcode address                    4  0001 if the compare has ever failed
    //   2  characters handed to the MUX so far
    //   0  fetches of 0x8f72, the branch before *** PASS ***
    //   1  fetches of 0x8f74, the PASS message itself
    //   2  fetches of 0x8fa6, where the branch goes when taken
    //   3  {byte at 0x07dd, byte at 0x07de} as last read
    //   4  passes completed
    // PSRAM bring-up result. See PsramTest.v and PsramSdr.v.
    //
    // Exactly 80 bits, as five 16 bit words. Counting this wrongly once already
    // shifted a whole dump by a byte and produced nonsense, so count it again
    // after any change: 4 + 3 + 1 + 1 + 5 + 2 padding is the first word.
    //
    // With PSRAM_SELFTEST set:
    //   0  {PsramSdr state, test stage, done, pass, scan match index}
    //   1  the scan window: one bit per CK after the command, set where the bus
    //      was not idle high. The first set bit is the read latency, whatever
    //      the data there turns out to be, so this reads the part's latency off
    //      the board rather than taking the datasheet's word for it.
    //   2  the command loopback, which is a000 if the pins are really driven
    //   3  the word read back from address 0, which should be 5aa5
    //   4  the word read back from address 2, which should be 5aa7. Two
    //      different values rules out a read path that returns the same thing
    //      whatever was written.
    // Otherwise, diag's verdict and the CPU's view of the memory together. Both
    // have to be in the one dump: diag's mapping RAM test never prints a verdict,
    // because it does that through a JSR to virtual 0x07cc which lands in low RAM
    // that nothing ever writes, so silence on the terminal means nothing at all
    // and the pass counters below are the only honest answer.
    //   0  {PsramSdr state, 0000, this address is PSRAM, controller busy,
    //      read, write, bridge state, bridge is stalling the core, 0}
    //   1  passes of diag's mapping RAM loop completed. Its verdict never
    //      reaches the terminal - it prints through a JSR to virtual 0x07cc,
    //      which lands in low RAM that nothing ever writes - so silence there
    //      means nothing and this counter is the only honest answer.
    //   2  page table entries written as zero when their index was not zero. This
    //      is live rather than frozen so it can be compared between a build with
    //      the PSRAM on the bus and one without.
    //   3  the last physical address accessed, low half
    //   4  {the compare failed at all, PSRAM accesses that gave up waiting -
    //      any at all is a fault - the address's high bits, the byte there}
    // Saturated to a nibble: any timeout at all is a fault, so the exact count
    // past fifteen is not worth a whole word of the dump.
    wire [3:0] timeouts_shown = (dbg_psram_timeouts > 16'd15)
                                ? 4'hf : dbg_psram_timeouts[3:0];
    // Once the compare has failed there is one question worth the whole dump: which
    // pair of bytes differed, and where they were read from. f0 to f3 are the last
    // four reads out of the buffer page, frozen at the failure, as {address, value} -
    // diag's copy lives at physical 0x100 and its reference at 0x200, so the pair
    // names both the offset that mismatched and what each side held. The dump marks
    // this form with a C so it can be told from the running summary.
    wire [79:0] fail_payload = { f3, f2, f1, f0, 5'b0, fail_base };

    // The last PSRAM access before the failure: the instruction, the virtual address
    // it asked for, the physical address that came out and the map it went through.
    // The last bus read the microcode actually consumed that went through a map
    // other than 0, and how many there have been.
    wire [79:0] psram_payload = { frb_pc, frb_va, frb_pa, frb_base, frb_count,
                                  10'b0 };

    // The last page table entry written as zero when its index was not zero, with
    // the buffer byte the load had just read.
    wire [79:0] wrongmap_payload = { fz0_index, fz0_src_addr, fz0_src, fz0_pc,
                                     fz0_count, 22'b0 };


    // The PSRAM self test's own result, on its own dump form. It used to replace the
    // summary in a PSRAM_SELFTEST build, which made the two builds report different
    // things and cost two rounds of misreading one as the other while comparing them.
    wire [79:0] selftest_payload =
        { sdr_state, psram_stage, psram_done, psram_pass, sdr_match, 2'b0,
          sdr_nonff, sdr_echo, psram_read0, psram_read1 };

    wire [79:0] dump_payload =
        { sdr_state, 4'b0, psram_select, busy, read, write,
            dbg_bus_state, dbg_bus_need, 1'b0,
          pass_count,
          z0_count,
          dbg_psram_addr[15:0],
          compare_failed, timeouts_shown, dbg_psram_addr[18:16], dbg_psram_data };

    // Trigger on btn2 as before, and also automatically a few seconds after diag's
    // compare has failed, so the board can be driven without anyone holding a button.
    //
    // The delay matters. The dump takes the UART pin away from the machine, so an
    // automatic trigger that fired whenever things went quiet would also fire at the
    // idle prompt and eat diag's own output, including any verdict it managed to print.
    // Waiting for a failure and then giving the machine three seconds to say whatever
    // it is going to say keeps the dump out of the way.
    // Sending 0x02 down the serial line asks for one status dump. That is better than
    // any automatic trigger: the dump takes the UART pin away from the machine, so
    // anything that fires on its own eventually eats diag's own output. This way the
    // dump only ever happens when it has been asked for, and exactly one line comes
    // back per request. Not 0xff, because the channel is running seven data bits and
    // the eighth never arrives. Not 0x7f either, because DEL is wanted for line
    // editing. It was NUL for a while and NUL is a bad choice: at 7N1 a zero byte is a
    // start bit followed by seven zero data bits, which is eight low bit times and
    // close enough to a break that the receiver often does not frame it. Dumps went
    // missing at random until the character was changed. This whole trigger is
    // scaffolding and should come out once the machine is being driven by something
    // other than a debugger.
    //
    // The request is cleared as the dump starts, not when it ends: StatusDump does
    // "running <= trigger" at the end of a line, so running never drops between lines
    // while the trigger is held and a falling edge never arrives.
    reg dump_request;
    reg rx_ready_d;
    reg dump_active_d;
    initial begin dump_request = 0; rx_ready_d = 0; dump_active_d = 0; end
    always @(posedge clock) begin
        rx_ready_d <= dbg_byte_ready;
        dump_active_d <= dump_active;
        if (reset) begin
            dump_request <= 0;
        end else begin
            if (dump_active)
                dump_request <= 0;   // consumed as the line starts
            else if (dbg_byte_ready && !rx_ready_d && dbg_rx_byte == 8'h02)
                dump_request <= 1;
            // A level triggered fallback was tried here, so that a machine which has
            // stopped reading the data register could still be asked for a dump. It
            // takes the UART pin away from the MUX permanently as soon as a trigger
            // byte is left sitting in the receiver, and the machine then looks dead
            // when it is running perfectly well. Do not add one.
        end
    end

    // One dump carries 80 bits, and after a failure there are two things worth
    // knowing, so alternate. The marker letter says which one arrived. This has to
    // sit below dump_active_d rather than with the other failure state: iverilog
    // will not take a declaration after its use, and this file has been bitten by
    // that several times.
    reg [1:0] dump_form;
    initial dump_form = 0;
    always @(posedge clock) begin
        if (reset) dump_form <= 0;
        else if (dump_active && !dump_active_d)
            dump_form <= (dump_form == 2'd2) ? 2'd0 : dump_form + 1;
    end

    StatusDump dump(clock, ~btn2 | dump_request,
                    compare_failed ? (dump_form == 2'd0 ? "C"
                                    : dump_form == 2'd1 ? "P" : "W")
                                   : (dump_form == 2'd1 ? "S"
                                    : fault_caught ? "F" : "L"),
                    compare_failed ? (dump_form == 2'd0 ? fail_payload
                                    : dump_form == 2'd1 ? psram_payload
                                    : wrongmap_payload)
                                   : (dump_form == 2'd1 ? selftest_payload
                                                        : dump_payload),
                    dump_tx, dump_active);
    assign uart_tx = dump_active ? dump_tx : mux_uart_tx;

    // Bring-up aid. diag never writes the LED panel, so while the core is alive the
    // LEDs would sit dark and tell us nothing. Until something does write the panel,
    // show a count of the bytes handed to the MUX data register instead: that says
    // whether the core is getting as far as talking to the serial channel, without
    // needing a terminal to be connected and correctly configured.
    Watchdog watchdog(in_clk, instruction_start, leds, display_leds, cpu_alive);

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


// CLKOUT = CLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1), and the VCO, which is CLKOUT *
// ODIV_SEL, has to land between 400 and 1200MHz. CLKOUTP is the same clock shifted by
// PSDA_SEL sixteenths of a period, so "0100" is the 90 degrees the PSRAM controller
// wants for driving CK.
//
//   81MHz: FBDIV 2, ODIV 8      (VCO 648)
//   54MHz: FBDIV 1, ODIV 12     (VCO 648)
//   27MHz: FBDIV 0, ODIV 16     (VCO 432)
module Gowin_rPLL #(parameter FBDIV = 2, parameter ODIV = 8)
                   (clkout, clkoutp, clkin);

output clkout;
output clkoutp;
input clkin;

wire lock_o;
wire clkoutd_o;
wire clkoutd3_o;
wire gw_vcc;
wire gw_gnd;

assign gw_vcc = 1'b1;
assign gw_gnd = 1'b0;

rPLL rpll_inst (
    .CLKOUT(clkout),
    .LOCK(lock_o),
    .CLKOUTP(clkoutp),
    .CLKOUTD(clkoutd_o),
    .CLKOUTD3(clkoutd3_o),
    .RESET(gw_gnd),
    .RESET_P(gw_gnd),
    .CLKIN(clkin),
    .CLKFB(gw_gnd),
    .FBDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .IDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .ODSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .PSDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .DUTYDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .FDLY({gw_vcc,gw_vcc,gw_vcc,gw_vcc})
);

defparam rpll_inst.FCLKIN = "27";
defparam rpll_inst.DYN_IDIV_SEL = "false";
// 81 Mhz, LATENCY=3
defparam rpll_inst.FBDIV_SEL = FBDIV;
defparam rpll_inst.IDIV_SEL = 0;
defparam rpll_inst.ODIV_SEL = ODIV;

defparam rpll_inst.DYN_FBDIV_SEL = "false";
defparam rpll_inst.DYN_ODIV_SEL = "false";
defparam rpll_inst.PSDA_SEL = "0100";
defparam rpll_inst.DYN_DA_EN = "false";
defparam rpll_inst.DUTYDA_SEL = "1000";
defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL = "internal";
defparam rpll_inst.CLKOUT_BYPASS = "false";
defparam rpll_inst.CLKOUTP_BYPASS = "false";
defparam rpll_inst.CLKOUTD_BYPASS = "false";
defparam rpll_inst.DYN_SDIV_SEL = 2;
defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
defparam rpll_inst.DEVICE = "GW1NR-9C";

endmodule //Gowin_rPLL

/**
 * CPU liveness watchdog.
 *
 * Runs in the free running 27MHz input clock domain so that it keeps working even when
 * the core is wedged. CPU6 pulses heartbeat once per instruction, at microcode address
 * 0x101. If none arrives for TIMEOUT clocks the core is considered dead and all eight
 * LEDs blink together at 1Hz instead of showing the LED panel, so a stopped machine is
 * obvious at a glance.
 */
module Watchdog #(
    parameter TIMEOUT = 13_500_000,     // 0.5s at 27MHz with no instruction executed
    parameter BLINK   = 13_500_000      // 0.5s half period, so a 1Hz blink
) (
    input wire clock_in,                // 27MHz, always running
    input wire heartbeat,               // pulses once per instruction
    input wire [7:0] leds_in,           // normal LED panel value
    output wire [7:0] leds_out,
    output wire alive
);
    // The CPU clock and clock_in are the same net, so the heartbeat only needs edge
    // detection rather than a full clock domain crossing.
    reg heartbeat_d;
    wire heartbeat_edge = heartbeat & ~heartbeat_d;

    reg [23:0] stall_counter;
    reg [23:0] blink_counter;
    reg blink;
    reg stalled;

    initial begin
        heartbeat_d = 0;
        stall_counter = 0;
        blink_counter = 0;
        blink = 0;
        stalled = 0;
    end

    always @(posedge clock_in) begin
        heartbeat_d <= heartbeat;

        if (heartbeat_edge) begin
            stall_counter <= 0;
            stalled <= 0;
        end else if (stall_counter == TIMEOUT) begin
            stalled <= 1;
        end else begin
            stall_counter <= stall_counter + 1;
        end

        if (blink_counter == BLINK) begin
            blink_counter <= 0;
            blink <= ~blink;
        end else begin
            blink_counter <= blink_counter + 1;
        end
    end

    assign alive = ~stalled;
    assign leds_out = stalled ? {8{blink}} : leds_in;
endmodule

module Divide4(input wire clock_in, output reg clock_out);
    reg [1:0] counter;
    
    always @(posedge clock_in) begin
        counter <= counter + 1;
        if (counter == 2'b11)
            clock_out <= ~clock_out;
    end
endmodule

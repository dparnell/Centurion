`include "ClockEnable.v"
`include "Centurion.v"
`include "Psram.v"
`include "PsramSdr.v"
`include "PsramTest.v"

/**
 * The Centurion on a Tang Nano 9K.
 *
 * This file is the board and only the board: the pins and their polarities,
 * the 27MHz crystal, the power-on reset and the button, the HyperRAM that
 * shares the package, and one instance of the machine. Nothing about the
 * Centurion itself is in here - that is Centurion.v, and it does not know what
 * board it is on.
 *
 * TO RETARGET THIS DESIGN to another FPGA board, write a file like this one
 * that gives Centurion what its port list asks for:
 *
 *   - a clock, and CLOCK_HZ stated once; everything that counts time takes
 *     it as a parameter
 *   - an enable pulsing 5 times a microsecond, from ClockEnable with PERIOD
 *     set to the clock in MHz
 *   - a reset held until the memory can answer (see psram_ready below: reaching
 *     the memory before it exists is not a slow start but a hang)
 *   - the DIP and sense switches, as constants or from real switches
 *   - a serial line, and the SD card's four SPI pins
 *   - ONE memory port with the protocol Centurion.v's header describes, which
 *     is Psram.v's port list. A board with SDRAM, SRAM or block RAM writes a
 *     module with that port list, and nothing on the machine's side changes.
 *
 * What is Gowin-specific in here: the rPLL primitive inside Psram, and the
 * PSRAM pad names, which nextpnr matches to the dedicated pads by name.
 */

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


    // Re-initialised on every reset, not just at power up. The mapping test leaves the
    // page table full of its own patterns, and nothing else puts it back, so after a
    // reset diag was starting up against whatever the previous run had left behind.



    // The LEDs are active low
    wire [7:0] display_leds;
    assign {LED1, LED2, LED3, LED4, LED5, LED6, LED7, LED8} = ~display_leds;

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
    // This board's crystal. Everything that counts time - baud rates, timeouts,
    // the watchdog's blink, the instructions-per-second window - takes it as a
    // parameter, so nothing below this file knows what the clock is.
    localparam integer CLOCK_HZ = 27_000_000;

    // The core's pace: 5 enables in every 27 clocks is the original CPU6's
    // 5MHz, exactly and without drift. The machine's memory bridge withholds
    // it while an access is in flight, so the core sees a long bus cycle
    // rather than a stall it has to understand.
    wire cpu_en_free, cpu_en;
    ClockEnable #(.TICKS(5), .PERIOD(CLOCK_HZ / 1_000_000)) cpu_clock_enable(clock, cpu_en_free);

    // The board's memory: the HyperRAM in the package, presented as the one
    // port the machine wants. Everything HyperBus-specific is inside Psram.
    wire mem_read, mem_write, mem_byte_write, mem_busy, psram_ready;
    wire [22:0] mem_addr;
    wire [15:0] mem_din;
    wire [63:0] mem_dout;
    wire [3:0] sdr_state;
    wire [4:0] sdr_match;
    wire [15:0] sdr_echo, sdr_nonff;
    wire psram_done, psram_pass;
    wire [2:0] psram_stage;
    wire [15:0] psram_read0, psram_read1;
    Psram #(.PSRAM_MULT(PSRAM_MULT), .PSRAM_PHASE(PSRAM_PHASE), .PSRAM_LATE(PSRAM_LATE),
            .PSRAM_TAP(PSRAM_TAP), .PSRAM_LATENCY(PSRAM_LATENCY),
            .PSRAM_SELFTEST(PSRAM_SELFTEST)) psram(
        .clock(clock), .button_n(reset_btn_sync[2]),
        .mem_read(mem_read), .mem_write(mem_write), .mem_byte_write(mem_byte_write),
        .mem_addr(mem_addr), .mem_din(mem_din), .mem_busy(mem_busy),
        .dout(mem_dout), .ready(psram_ready),
        .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n), .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_rwds(IO_psram_rwds), .IO_psram_dq(IO_psram_dq),
        .dbg_busy(), .dbg_read(), .dbg_write(),
        .dbg_sdr_state(sdr_state), .dbg_sdr_match(sdr_match),
        .dbg_sdr_echo(sdr_echo), .dbg_sdr_nonff(sdr_nonff),
        .dbg_test_done(psram_done), .dbg_test_pass(psram_pass),
        .dbg_test_stage(psram_stage),
        .dbg_test_read0(psram_read0), .dbg_test_read1(psram_read1));

    // The machine. See Centurion.v: everything from here down the bus is the
    // same on any board.
    Centurion #(.PROGRAM(PROGRAM), .DIAG_ROM(DIAG_ROM), .DMA_TEST(DMA_TEST),
                .DIAG_TRACE(DIAG_TRACE), .PARITY_CHECK(PARITY_CHECK),
                .K13_INTERRUPTS(K13_INTERRUPTS), .DISK_IMAGE(DISK_IMAGE),
                .CLOCK_HZ(CLOCK_HZ), .SPACING(SPACING),
                .MEMORY_SELFTEST(PSRAM_SELFTEST)) machine(
        .clock(clock), .cpu_en_free(cpu_en_free), .cpu_en(cpu_en), .reset(reset),
        .dip_switches(DIAG_DIP_SWITCHES), .sense_switches(SENSE_SWITCHES),
        .display_leds(display_leds), .btn2(btn2),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .mem_read(mem_read), .mem_write(mem_write), .mem_byte_write(mem_byte_write),
        .mem_addr(mem_addr), .mem_din(mem_din), .mem_dout(mem_dout), .mem_busy(mem_busy),
        .mem_dbg_state(sdr_state), .mem_dbg_match(sdr_match),
        .mem_dbg_echo(sdr_echo), .mem_dbg_nonff(sdr_nonff),
        .mem_test_done(psram_done), .mem_test_pass(psram_pass),
        .mem_test_stage(psram_stage),
        .mem_test_read0(psram_read0), .mem_test_read1(psram_read1));

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


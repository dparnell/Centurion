`include "CPU6.v"
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
    output wire mux_select, output wire ram_select);

    // MUX serial board, 16 registers. This matches the Diag MUX addresses used by
    // CPU6TestBench.v (status 0x3f200, data 0x3f201) and by programs/hellorld.txt.
    assign mux_select = (address & 19'h7fff0) == 19'h3f200;

    // The block RAM answers everything else. It aliases its 256 bytes across the
    // whole address space, which is what lets the reset vector fetch land on the
    // start of the loaded program.
    assign ram_select = ~mux_select;
endmodule

module tangnano9k(input in_clk, input reset_btn, output LED1, output LED2, output LED3, output LED4, output LED5, output LED6, output LED7, output LED8, output uart_tx, input uart_rx);
    reg reset;
    // reset_btn is a mechanical input with no relation to the clock, and it feeds the
    // reset of the whole core, so sample it through a synchroniser rather than directly.
    reg [2:0] reset_btn_sync;
    reg [7:0] por_counter;

    // por_done is the most trustworthy "is the CPU clock running" indicator available:
    // it is an ordinary fabric counter on the CPU clock, so it can only have expired if
    // that clock actually ticked 255 times.
    wire por_done = por_counter == 8'hff;

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

    reg [7:0] ptinit_addr;
    reg ptinit_done;
    wire ptinit_write = !ptinit_done;
    initial begin
        ptinit_addr = 0;
        ptinit_done = 0;
    end



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
    wire clock = in_clk;
    // Peripheral read bus ---------------------------
    // Every readable peripheral drives its own data_out, and this module picks one.
    // Previously BlockRAM, LEDPanel and MUX were all wired straight onto data_r2c.
    // Simulation resolved the undriven outputs as z and let the RAM value through, but
    // yosys reported a driver-driver conflict, resolved it to a constant and dropped
    // ram_cells entirely, so on hardware the CPU only ever read 'x' (decoded as HLT).
    wire mux_select, ram_select;
    wire [7:0] ram_data, mux_data;

    AddressDecode decode(addressBus, mux_select, ram_select);

    assign data_r2c = mux_select ? mux_data : ram_data;

    // The core is enabled 5 clocks in every 27, giving the original CPU6's 5MHz.
    wire cpu_en;
    ClockEnable cpu_clock_enable(clock, cpu_en);

    BoardMemory ram(clock, cpu_en, addressBus, writeEnBus & ram_select, data_c2r, ram_data);
    LEDPanel panel(clock, cpu_en, addressBus, writeEnBus, data_c2r, leds);
    MUX mux0(in_clk, clock, cpu_en, uart_rx, uart_tx, mux_select, { 1'b0, addressBus[3:0] }, writeEnBus, data_c2r, mux_data, int_reqn, irq_number);

    CPU6 cpu (reset, clock, cpu_en, data_r2c, int_reqn, irq_number, writeEnBus, addressBus, data_c2r, instruction_start,
              ptinit_write, ptinit_addr, ptinit_addr);

    /*
     * Page table initialiser.
     *
     * The self test that used to live here wrote every entry with its own address and
     * held the core in reset while it did so, and removing it made diag's mapping RAM
     * test fail every time rather than occasionally. Whether that is the entries'
     * starting contents or simply the longer reset is not yet known, so this restores
     * both, without the read address mux that made the self test the critical path.
     */
    always @(posedge clock) begin
        if (ptinit_write) ptinit_addr <= ptinit_addr + 1;
        if (ptinit_addr == 255) ptinit_done <= 1;
    end




    // Bring-up aid. diag never writes the LED panel, so while the core is alive the
    // LEDs would sit dark and tell us nothing. Until something does write the panel,
    // show a count of the bytes handed to the MUX data register instead: that says
    // whether the core is getting as far as talking to the serial channel, without
    // needing a terminal to be connected and correctly configured.
    Watchdog watchdog(in_clk, instruction_start, leds, display_leds, cpu_alive);

	always @ (posedge clock) begin
        reset_btn_sync <= { reset_btn_sync[1:0], reset_btn };
        if (!por_done || ptinit_write) begin
            if (!por_done) por_counter <= por_counter + 1;
            reset <= 1;
        end else if (cpu_en) begin
            // Release reset only on an enabled cycle, so the core always leaves reset
            // on a CPU clock edge whatever phase the clock enable happens to be in.
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

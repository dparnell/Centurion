`include "CPU6.v"
`include "BoardMemory.v"
`include "LEDPanel.v"
`include "psram_controller.v"
`include "mux.v"

/**
 * This file contains the top level Centurion CPU synthesizable on an Tang Nano 9K FGPA board.
 */


module Gowin_rPLL (clkout, clkoutp, clkin);

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
defparam rpll_inst.FBDIV_SEL = 2;
defparam rpll_inst.IDIV_SEL = 0;       
defparam rpll_inst.ODIV_SEL = 8;

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
 * The original 256 byte memory, aliased across the whole address space, kept so the
 * board can be put back to a configuration that is known to have worked. It reads
 * asynchronously, so it becomes LUTRAM rather than block RAM. Only the small demo
 * programs fit; diag needs BoardMemory.
 */
module BlockRAM(input wire clock, input wire enable, input wire [18:0] address, input wire write_en, input wire [7:0] data_in,
    output wire [7:0] data_out);

    reg [7:0] ram_cells[0:255];

    initial begin
        $readmemh("programs/serial.txt", ram_cells);
    end

    wire [7:0] mapped_address = address[7:0];
    assign data_out = ram_cells[mapped_address];

    always @(posedge clock) begin
        if (enable && write_en == 1 && address[15:8] == 8'hff) begin
            ram_cells[mapped_address] <= data_in;
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

module tangnano9k(input in_clk, input reset_btn, input btn2, output LED1, output LED2, output LED3, output LED4, output LED5, output LED6, output LED7, output LED8, output uart_tx, input uart_rx);
    // Change the PLL and these together to choose another PSRAM speed. These used to
    // sit at file scope, which is not legal Verilog and meant iverilog could not
    // elaborate this file, so the top level had never been simulated as a whole.
    localparam FREQ = 81_000_000;
    localparam LATENCY = 3;

    reg reset;
    reg [7:0] por_counter;
    reg full_speed_d;

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
        full_speed_d = 0;
    end

    wire int_reqn;
    wire [3:0] irq_number;

    wire writeEnBus;
    wire [7:0] data_c2r, data_r2c;
    wire [18:0] addressBus;
    wire [7:0] leds;
    wire [7:0] display_leds;

    // The LEDs are active low
    assign {LED1, LED2, LED3, LED4, LED5, LED6, LED7, LED8} = ~display_leds;
    wire instruction_start;
    wire [10:0] uc_address;
    wire cpu_alive;

    Gowin_rPLL pll(
        .clkout(ram_clk),        // 81MHZ psram clock
        .clkoutp(ram_clk_p),     // 81MHZ psram clock phase shifted (90 degrees)
        .clkin(in_clk)      // 27Mhz system clock
    );

    // Memory Controller ---------------------------
    reg read, readd, write, byte_write;
    reg [21:0] address;
    reg [15:0] din;
    wire [15:0] dout;
    wire [7:0] dout_byte = address[0] ? dout[15:8] : dout[7:0];

    PsramController #(
        .LATENCY(LATENCY)
    ) mem_ctrl (
        .clk(ram_clk), .clk_p(ram_clk_p), .resetn(reset_btn), .read(read), .write(write), .byte_write(byte_write),
        .addr(address), .din(din), .dout(dout), .busy(busy),
        .O_psram_ck(O_psram_ck), .IO_psram_rwds(IO_psram_rwds), .IO_psram_dq(IO_psram_dq),
        .O_psram_cs_n(O_psram_cs_n)
    );

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
    //
    // Holding btn2 runs it at the full 27MHz board clock instead. That is a bring-up
    // aid: one bitstream can then say whether a fault depends on the clock enable,
    // without reflashing to find out. Changing modes restarts the power on reset so
    // the core always begins from a clean state.
    wire cpu_en_slow;
    ClockEnable cpu_clock_enable(clock, cpu_en_slow);

    // btn2 runs the core faster for bring-up. It cannot simply ungate the enable: the
    // microcode ROM and register file read every clock and the control word is held in
    // CPU6's pipeline register, so there must be at least two clocks between enabled
    // cycles. One in two gives 13.5MHz, which is plenty to tell a speed related fault
    // from any other kind.
    reg half;
    initial half = 0;
    always @(posedge clock) half <= ~half;

    wire full_speed = ~btn2;            // buttons are active low
    wire cpu_en = full_speed ? half : cpu_en_slow;

    // Bisecting a board fault: the UART stopped working when the memory changed, and
    // nothing in the RTL, the netlist or the pin placement explains it. BlockRAM is the
    // 256 byte memory serial.txt printed correctly from; BoardMemory is the real map
    // diag needs. Swap these two lines to move between them.
    BlockRAM ram(clock, cpu_en, addressBus, writeEnBus & ram_select, data_c2r, ram_data);
    // BoardMemory ram(clock, cpu_en, addressBus, writeEnBus & ram_select, data_c2r, ram_data);
    LEDPanel panel(clock, cpu_en, addressBus, writeEnBus, data_c2r, leds);
    MUX mux0(in_clk, clock, cpu_en, uart_rx, uart_tx, mux_select, { 1'b0, addressBus[3:0] }, writeEnBus, data_c2r, mux_data, int_reqn, irq_number);

    CPU6 cpu (reset, clock, cpu_en, data_r2c, int_reqn, irq_number, writeEnBus, addressBus, data_c2r, instruction_start, uc_address);

    // Bring-up aid. diag never writes the LED panel, so while the core is alive the
    // LEDs would sit dark and tell us nothing. Until something does write the panel,
    // show a count of the bytes handed to the MUX data register instead: that says
    // whether the core is getting as far as talking to the serial channel, without
    // needing a terminal to be connected and correctly configured.
    // The count of bytes written to the MUX said writes happen but nothing about what
    // is in them, so latch the first byte instead and hold it. LED6 lights once a byte
    // has been captured, and LED1..LED5 are bits 7..3 of it. serial.txt sends 'H'
    // (0x48) first, which reads as LED2, LED5 and LED6 lit. Everything dark except
    // LED6 means the core wrote a zero, which points at the memory rather than at the
    // serial channel.
    reg [7:0] first_uart_byte;
    reg got_first;
    reg led_panel_used;
    initial begin
        first_uart_byte = 0;
        got_first = 0;
        led_panel_used = 0;
    end
    always @(posedge clock) begin
        if (cpu_en && writeEnBus && mux_select && addressBus[3:0] == 4'd1 && !got_first) begin
            first_uart_byte <= data_c2r;
            got_first <= 1;
        end
        if (cpu_en && writeEnBus && addressBus == 19'h05c00)
            led_panel_used <= 1;
    end
    wire [7:0] alive_leds = led_panel_used ? leds
                                           : { first_uart_byte[7:3], got_first, 2'b00 };

    Watchdog watchdog(in_clk, reset_btn, reset, por_done, instruction_start, uc_address, alive_leds, display_leds, cpu_alive);

	always @ (posedge clock) begin
        full_speed_d <= full_speed;
        if (full_speed != full_speed_d) begin
            // Speed changed, so run the core through reset again
            por_counter <= 0;
            reset <= 1;
        end else if (!por_done) begin
            por_counter <= por_counter + 1;
            reset <= 1;
        end else if (cpu_en) begin
            // Release reset only on an enabled cycle, so the core always leaves reset
            // on a CPU clock edge whatever phase the clock enable happens to be in.
            reset <= ~reset_btn;
        end
    end
endmodule


/**
 * CPU liveness watchdog and bring-up display.
 *
 * Runs entirely in the free running 27MHz input clock domain so that it keeps working
 * even when the core is wedged. The CPU pulses heartbeat once per instruction
 * (microcode address 0x101). If no heartbeat arrives for TIMEOUT input clocks the core
 * is considered dead and the LEDs are taken over by a diagnostic display instead of
 * the LED panel register.
 *
 * Every diagnostic input is an ordinary fabric signal. An earlier version sampled the
 * CPU clock net itself, which nextpnr could not route to a LUT data input
 * ("Failed to route net 'clock' ... to X1Y16/D2 using dedicated routing"), so that bit
 * could not be trusted. por_done replaces it: it is a plain counter clocked by the CPU
 * clock, so it can only be set if that clock is really running.
 *
 * The Tang Nano 9K has six LEDs and the top level maps display_leds[7] to LED1 down to
 * display_leds[2] to LED6:
 *
 *   LED1  slow blink   the watchdog has taken over, the core is not executing
 *   LED2  lit          reset is asserted right now
 *   LED3-6             uc_max[10:7], the highest microcode address reached since reset,
 *                      as a 4 bit number, so the address is roughly that times 128
 *
 * The board is currently in a state where the clock runs, reset is released and the
 * microcode address keeps changing, but the instruction fetch at 0x101 is never
 * reached. LED3-6 say how far it gets. 0000 means it never leaves the first 128 words,
 * so it is stuck at the very start of the reset sequence. 0010 is the 0x100 region,
 * where the instruction fetch entry lives, so it gets all the way there and turns back.
 * A large or drifting value means the control word is being corrupted and the
 * sequencer is wandering the ROM, which points at the clock enable rather than at the
 * microcode.
 */
module Watchdog #(
    parameter TIMEOUT = 13_500_000,     // 0.5s at 27MHz with no instruction executed
    parameter BLINK   = 13_500_000,     // 0.5s half period, so a 1Hz blink
    parameter UC_DEAD = 6_750_000       // 0.25s without the microcode address moving
) (
    input wire clock_in,                // 27MHz, always running
    input wire reset_btn,               // raw button pin, active low
    input wire cpu_reset,               // reset as presented to CPU6
    input wire por_done,                // the power on reset counter has expired
    input wire heartbeat,               // pulses once per instruction
    input wire [10:0] uc_address,       // microcode ROM address
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

    reg [10:0] uc_address_d;
    reg [23:0] uc_timer;
    reg uc_moving;
    reg beat_seen;

    // Highest microcode address reached since the last reset. The core is known to be
    // sequencing microcode without ever reaching the instruction fetch at 0x101, and
    // this says where it actually gets to, which tells a core stuck waiting on
    // something early apart from one whose control word is being corrupted and is
    // wandering all over the ROM.
    reg [10:0] uc_max;

    initial begin
        heartbeat_d = 0;
        stall_counter = 0;
        blink_counter = 0;
        blink = 0;
        stalled = 0;
        uc_address_d = 0;
        uc_timer = 0;
        uc_moving = 0;
        beat_seen = 0;
        uc_max = 0;
    end

    always @(posedge clock_in) begin
        heartbeat_d <= heartbeat;

        if (heartbeat_edge) begin
            stall_counter <= 0;
            stalled <= 0;
            beat_seen <= 1;
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

        if (cpu_reset) uc_max <= 0;
        else if (uc_address > uc_max) uc_max <= uc_address;

        // Is the microsequencer still moving?
        uc_address_d <= uc_address;
        if (uc_address_d != uc_address) begin
            uc_timer <= 0;
            uc_moving <= 1;
        end else if (uc_timer == UC_DEAD) begin
            uc_moving <= 0;
        end else begin
            uc_timer <= uc_timer + 1;
        end
    end

    assign alive = ~stalled;
    assign leds_out = stalled ? { blink, cpu_reset, uc_max[10:7], 2'b00 }
                              : leds_in;
endmodule

module Divide4(input wire clock_in, output reg clock_out);
    reg [1:0] counter;
    
    always @(posedge clock_in) begin
        counter <= counter + 1;
        if (counter == 2'b11)
            clock_out <= ~clock_out;
    end
endmodule

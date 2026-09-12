/**
 * The board's PSRAM, as the machine sees it: two ports over one die.
 *
 * Everything HyperBus-specific lives here and nowhere else - the PLL that
 * multiplies the board clock up for the PHY, the PHY itself and its dedicated
 * pads, the synchroniser that brings busy back across, the latch that says the
 * die has come out of its own 600us reset, the arbiter that shares one die
 * between two clients, and the bring-up self test that can take the die over
 * instead. The machine side sees two identical ports and a protocol:
 *
 *     hold read or write until busy rises, then wait for it to fall;
 *     dout is valid when it has fallen, for whoever owned the access.
 *
 * That is exactly what PsramBus and DiskImage have always spoken, so neither
 * knows this module exists - and a testbench could put a plain block RAM
 * behind the same two ports.
 *
 * The arbitration is a grant that lasts a whole access, and a per client VIEW
 * of busy - which is the part that matters and the part that is easy to get
 * wrong. A loser that saw the real busy would watch the winner's access rise
 * and fall and conclude that its own request had been served, and take the
 * winner's data. So a client that does not hold the grant sees busy low, which
 * leaves it holding its request exactly where it was - which is also how the
 * arbiter knows it still wants one. Getting this wrong lost four bytes of a
 * sector, at the two places where the CPU and the disk happened to collide,
 * and looked like a memory fault rather than an arbiter fault.
 *
 * Port A is served first when both ask at once, because stalling the CPU costs
 * a bus cycle and the disk is standing in for a drive that takes a millisecond
 * a sector - but the two alternate when both want it, so neither starves.
 */
module Psram #(
    // How much faster than the board clock the PSRAM runs. The PHY builds CK
    // from four phases of its clock, so 1 gives 6.75MHz, 2 gives 13.5MHz and 4
    // gives 27MHz - and a read is 22 CK whatever the rate.
    //
    // What limits this is not the protocol but the margin the PHY samples with.
    // It captures a byte one phase after the CK edge, and that phase has to
    // cover the round trip: the FPGA driving CK, the die responding, and the
    // data getting back to a fabric flip flop. One phase is 37ns at 1, 18.5 at
    // 2 and 9.3 at 4. Simulation cannot answer where that stops working,
    // because the behavioural die has no timing - only the board can, which is
    // what maptest.s is for.
    parameter PSRAM_MULT = 2,
    // Where in the cycle the memory's incoming bytes are captured, in
    // sixteenths of the PSRAM clock period. "0000" samples where it always
    // has; larger values move the capture later. It has to be a string, and a
    // real one: apycula reads this with int(parm, 2), so it wants the four
    // characters and not a value that happens to spell them. Built with
    // arithmetic, yosys forgets it was ever a string and apycula parses the
    // ASCII bits as the number - every phase then programs the same garbage,
    // which looks exactly like the knob having no effect.
    parameter PSRAM_PHASE = "0000",
    // Whole phases, on top of PSRAM_PHASE's sixteenths.
    parameter integer PSRAM_LATE = 0,
    // Which pair of captured phases makes up a word. 2 is what the PHY has
    // always effectively used; moving it shifts the capture a whole phase at a
    // time, which is what a byte landing the far side of a cycle boundary
    // needs and no amount of phase shifting can give.
    parameter integer PSRAM_TAP = 2,
    // The part's initial latency in CK. The real die comes up at 6; a
    // simulation can shorten it to make a long boot affordable, and anything
    // found that way has to be confirmed at 6 before it is believed.
    parameter [4:0] PSRAM_LATENCY = 6,
    // Run the bring-up self test instead of serving the two ports. Excluded
    // from the netlist rather than merely held in reset, because hardware that
    // is switched off still takes logic. See PsramTest.v.
    parameter PSRAM_SELFTEST = 0
) (
    input wire clock,
    // The board's reset button, synchronised. It resets the die as well as the
    // machine, which is why it is a separate input from the core's reset.
    input wire button_n,
    input wire reset,

    // Port A: the CPU's memory bridge.
    input wire a_read, input wire a_write, input wire a_byte_write,
    input wire [22:0] a_addr, input wire [15:0] a_din,
    output wire a_busy,
    // Port B: the disk image's cache.
    input wire b_read, input wire b_write, input wire b_byte_write,
    input wire [22:0] b_addr, input wire [15:0] b_din,
    output wire b_busy,
    // The data read, shared: valid once busy has fallen, for the port that
    // owned the access. Four words - see PsramSdr's BURST.
    output wire [63:0] dout,
    // The die has answered at least once since the button was released. The
    // part needs 600us to come out of its own reset and the core's power on
    // reset is only 1024 clocks, so the board holds the core in reset until
    // this rises: reaching the memory before the memory exists is not a slow
    // start but a hang, because the bridge holds the clock enable until the
    // access completes.
    output wire ready,

    // The HyperRAM die shares the package. nextpnr places these on the
    // dedicated pads by name, so the names have to be exactly these.
    output wire [1:0] O_psram_ck, output wire [1:0] O_psram_ck_n,
    output wire [1:0] O_psram_cs_n, output wire [1:0] O_psram_reset_n,
    inout wire [1:0] IO_psram_rwds, inout wire [15:0] IO_psram_dq,

    // For the instruments: what the die is being asked, and the PHY's and the
    // self test's state.
    output wire dbg_busy, output wire dbg_read, output wire dbg_write,
    output wire [3:0] dbg_sdr_state, output wire [4:0] dbg_sdr_match,
    output wire [15:0] dbg_sdr_echo, output wire [15:0] dbg_sdr_nonff,
    output wire dbg_test_done, output wire dbg_test_pass,
    output wire [2:0] dbg_test_stage,
    output wire [15:0] dbg_test_read0, output wire [15:0] dbg_test_read1
);

    // ------------------------------------------------------------ the clock
    // FCLKOUT = FCLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1), and ODIV_SEL sets the
    // VCO, which has to land between 400MHz and 1200MHz: 27 * 2 * 16 is 864,
    // and 27 * 4 * 8 is the same. At a multiplier of 1 there is no PLL at all,
    // which keeps the whole design in one clock domain and sidesteps the
    // apicula PLL packing bug as a bonus.
    wire psram_clk, psram_sample_clk, psram_lock;
    generate
    if (PSRAM_MULT == 1) begin: no_pll
        assign psram_clk = clock;
        assign psram_sample_clk = clock;
        assign psram_lock = 1'b1;
    end else begin: pll
        rPLL #(.FCLKIN("27"), .IDIV_SEL(0), .FBDIV_SEL(PSRAM_MULT-1),
               .ODIV_SEL(PSRAM_MULT == 2 ? 16 : 8), .DEVICE("GW1NR-9C"),
               .PSDA_SEL(PSRAM_PHASE), .DYN_DA_EN("false"))
            psram_pll(.CLKOUT(psram_clk), .LOCK(psram_lock),
                      .CLKOUTP(psram_sample_clk), .CLKOUTD(), .CLKOUTD3(),
                      .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clock), .CLKFB(1'b0),
                      .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
                      .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0));
    end
    endgenerate

    // -------------------------------------------------------------- the PHY
    wire read, write, byte_write;
    wire [22:0] address;
    wire [15:0] din;

    // Crossing back out of the PSRAM's domain. busy is a level that changes
    // slowly compared with either clock and dout is stable by the time it
    // falls, so two flip flops on busy is the whole of it: everything else in
    // the protocol is already held steady across the handshake.
    //
    // Busy until proven otherwise. Starting these at zero says the memory is
    // ready before anything has asked it, and ready is set from exactly this
    // signal - so the core left reset while the part was still in its 300us
    // wake up, and its first access sat there until the bridge gave up. Three
    // timeouts in eleven thousand accesses, all of them at boot.
    wire busy_raw;
    reg [1:0] busy_sync;
    initial busy_sync = 2'b11;
    always @(posedge clock) busy_sync <= { busy_sync[0], busy_raw };
    wire busy = busy_sync[1];

    // The PHY drives all of the pads itself, including RESET#, which it pulses
    // low at start up the way the part wants rather than simply tying it high.
    PsramSdr #(.RX_TAP(PSRAM_TAP), .RESET_CLOCKS(8100 * PSRAM_MULT),
               .LATENCY(PSRAM_LATENCY),
               .DEBUG_SCAN(PSRAM_MULT >= 4 ? 0 : 1)) phy(
        .clk(psram_clk), .sample_clk(psram_sample_clk),
        .resetn(button_n & psram_lock),
        .read(read), .write(write), .addr(address), .din(din),
        .byte_write(byte_write), .dout(dout), .busy(busy_raw),
        .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n),
        .O_psram_cs_n(O_psram_cs_n), .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_rwds(IO_psram_rwds), .IO_psram_dq(IO_psram_dq),
        .dbg_state(dbg_sdr_state), .dbg_match(dbg_sdr_match),
        .dbg_first(), .dbg_nonff(dbg_sdr_nonff), .dbg_ca_echo(dbg_sdr_echo));

    // This latches rather than following busy, which goes high on every access.
    reg ready_r;
    initial ready_r = 0;
    always @(posedge clock) begin
        if (!button_n) ready_r <= 0;        // the button resets the part too
        else if (!busy) ready_r <= 1;
    end
    assign ready = ready_r;

    // -------------------------------------------------------- the self test
    wire tst_read, tst_write, tst_byte_write;
    wire [22:0] tst_addr;
    wire [15:0] tst_din;
    generate if (PSRAM_SELFTEST) begin : self_test
        wire [15:0] got, want, cycles;
        wire [22:0] failed_at;
        wire [2:0] index;
        wire saw_idle;
        PsramTest test(clock, button_n,
                       tst_read, tst_write, tst_byte_write, tst_addr, tst_din,
                       dout[15:0], busy, dbg_test_done, dbg_test_pass,
                       got, want, failed_at,
                       dbg_test_stage, index, saw_idle, cycles,
                       dbg_test_read0, dbg_test_read1);
    end else begin : no_self_test
        assign tst_read = 0; assign tst_write = 0; assign tst_byte_write = 0;
        assign tst_addr = 0; assign tst_din = 0;
        assign dbg_test_done = 0; assign dbg_test_pass = 0;
        assign dbg_test_stage = 0;
        assign dbg_test_read0 = 0; assign dbg_test_read1 = 0;
    end endgenerate

    // ----------------------------------------------------------- the arbiter
    localparam OWNER_A = 1'b0, OWNER_B = 1'b1;
    reg grant_held, grant_owner, grant_seen, last_owner;
    wire a_wants = a_read | a_write;
    wire b_wants = b_read | b_write;
    initial begin grant_held = 0; grant_owner = 0; grant_seen = 0; last_owner = 1; end
    always @(posedge clock) begin
        if (reset) begin
            grant_held <= 0; grant_seen <= 0; last_owner <= OWNER_B;
        end else if (!grant_held) begin
            if (!busy && (a_wants || b_wants)) begin
                grant_owner <= (a_wants && b_wants) ? ~last_owner :
                               a_wants ? OWNER_A : OWNER_B;
                last_owner  <= (a_wants && b_wants) ? ~last_owner :
                               a_wants ? OWNER_A : OWNER_B;
                grant_held <= 1;
                grant_seen <= 0;
            end
        end else if (busy) grant_seen <= 1;
        else if (grant_seen) begin
            grant_held <= 0;
            grant_seen <= 0;
        end
    end

    wire a_owns = grant_held && grant_owner == OWNER_A;
    wire b_owns = grant_held && grant_owner == OWNER_B;
    assign a_busy = a_owns ? busy : 1'b0;
    assign b_busy = b_owns ? busy : 1'b0;

    // With the self test running the ports must not reach the die at all, or
    // the two would fight over it and the core would stall for ever.
    assign read       = PSRAM_SELFTEST ? tst_read       : b_owns ? b_read       : a_owns ? a_read  : 1'b0;
    assign write      = PSRAM_SELFTEST ? tst_write      : b_owns ? b_write      : a_owns ? a_write : 1'b0;
    assign byte_write = PSRAM_SELFTEST ? tst_byte_write : b_owns ? b_byte_write : a_byte_write;
    assign address    = PSRAM_SELFTEST ? tst_addr       : b_owns ? b_addr       : a_addr;
    assign din        = PSRAM_SELFTEST ? tst_din        : b_owns ? b_din        : a_din;

    assign dbg_busy = busy;
    assign dbg_read = read;
    assign dbg_write = write;
endmodule

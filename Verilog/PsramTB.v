`timescale 1 ns/10 ps
`include "SimPrimitives.v"

`include "PsramSdr.v"
`include "PsramTest.v"
`include "HyperRamModel.v"

/**
 * Runs PsramTest against PsramSdr and a behavioural HyperRAM die.
 *
 * This proves the PHY's plumbing only - the model has no timing and agrees with
 * the controller about the latency by construction, so a pass here does not mean
 * the board will work. It does mean that every byte goes on the right clock
 * edge, that the command and address are formed the way the bus wants them, and
 * that a returned word is reassembled from the right pair of samples.
 *
 * "make psramtest"
 */
module PsramTB;
    reg clk = 0;
    always #18.5185 clk = ~clk;          // 27MHz
    reg resetn = 0;

    wire read, write, byte_write;
    wire [22:0] addr;
    wire [15:0] din;
    wire [63:0] dout;
    wire busy;
    wire done, pass;
    wire [15:0] got, want;
    wire [22:0] failed_at;
    wire [2:0] stage, index;
    wire saw_idle;
    wire [15:0] stage_cycles, read0, read1;

    wire [1:0] ck, ck_n, cs_n, rst_n;
    wire [1:0] rwds;
    wire [15:0] dq;
    wire [3:0] dbg_state;
    wire [4:0] dbg_match;
    wire [15:0] dbg_first, dbg_ca_echo;
    wire [15:0] dbg_nonff;

    // The power up wait is 300us on the board; shorten it so the test does not
    // spend its whole run waiting for a part that is modelled as always ready.
    PsramSdr #(.RESET_CLOCKS(16)) dut(
        .clk(clk), .sample_clk(clk), .resetn(resetn),
        .read(read), .write(write), .addr(addr), .din(din),
        .byte_write(byte_write), .dout(dout), .busy(busy),
        .O_psram_ck(ck), .O_psram_ck_n(ck_n), .O_psram_cs_n(cs_n),
        .O_psram_reset_n(rst_n), .IO_psram_rwds(rwds), .IO_psram_dq(dq),
        .dbg_state(dbg_state), .dbg_match(dbg_match), .dbg_first(dbg_first),
        .dbg_nonff(dbg_nonff), .dbg_ca_echo(dbg_ca_echo));

    PsramTest tester(clk, resetn, read, write, byte_write, addr, din, dout[15:0], busy,
                     done, pass, got, want, failed_at,
                     stage, index, saw_idle, stage_cycles, read0, read1);

    HyperRamModel #(.ADDR_BITS(23)) die(.ck(ck[0]), .cs_n(cs_n[0]), .resetn(rst_n[0]),
                      .rwds(rwds[0]), .dq(dq[7:0]));

    // How long an access actually takes, which is the whole point of making it
    // faster. Timed from busy rising to busy falling, in board clocks.
    integer clocks = 0, t0 = 0;
    integer nread = 0, nwrite = 0, tread = 0, twrite = 0;
    reg busy_d = 0, was_read = 0;
    always @(posedge clk) begin
        clocks = clocks + 1;
        busy_d <= busy;
        if (busy && !busy_d) begin t0 = clocks; was_read = dut.is_read; end
        if (!busy && busy_d) begin
            if (was_read) begin nread = nread + 1; tread = tread + clocks - t0; end
            else begin nwrite = nwrite + 1; twrite = twrite + clocks - t0; end
        end
    end

    initial begin
        #500 resetn = 1;
        wait (done);
        #1000;
        if (nread) $display("read:  %0d accesses, %0d clocks each, %0d ns",
                            nread, tread/nread, (tread/nread) * 1000 / 27);
        if (nwrite) $display("write: %0d accesses, %0d clocks each, %0d ns",
                             nwrite, twrite/nwrite, (twrite/nwrite) * 1000 / 27);
        $display("bursts=%0d bytes written=%0d bytes read=%0d",
                 die.bursts, die.bytes_written, die.bytes_read);
        $display("read0=%04x read1=%04x  scan first=%04x match=%0d nonff=%016b echo=%04x",
                 read0, read1, dbg_first, dbg_match, dbg_nonff, dbg_ca_echo);
        if (die.bursts == 0)
            $display("FAIL: the die was never selected");
        else if (pass)
            $display("ok: 6 words and a word built from two byte writes all read back correctly");
        else
            $display("FAIL: at %06x wanted %04x got %04x", failed_at, want, got);
        $finish;
    end

    initial begin
        #40000000;
        $display("FAIL: timed out in stage %0d index %0d (saw_idle=%b, %0d cycles)",
                 stage, index, saw_idle, stage_cycles);
        $finish;
    end
endmodule

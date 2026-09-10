/**
 * HyperRAM controller with an SDR PHY built from fabric flip flops.
 *
 * The Tang Nano 9K's embedded HyperRAM cannot be driven through apicula's
 * ODDR/IDDR primitives: they carry roughly 2.5 cycles of data path delay, so
 * the data never lines up with the clock however the protocol is configured.
 * That is why the vendor controller in psram_controller.v fails here, and why
 * its author's own test fails too when built with this toolchain - both use
 * IOLOGIC. The approach below is the one sabas0ba/hello_veryl documents and has
 * working on this board with these tools: drive everything from ordinary fabric
 * flops and run the bus slowly enough that plain flip flops have ample margin.
 *
 * One HyperBus cycle is four phases of the 27MHz clock, so CK is 6.75MHz:
 *
 *   phase   0        1        2        3
 *   CK      low      low      high     high      rises 1->2, falls 3->0
 *   DQ      byte B   byte A   byte A   byte B    driven at 0->1 and 2->3
 *   sample           byte B'           byte A'   one phase after each CK edge
 *
 * Two bytes still move per CK, so this is ordinary HyperBus DDR data with the
 * whole interface clocked from fabric at a quarter rate. Driving a byte one
 * phase before the CK edge that latches it gives the die half a CK of setup,
 * and sampling one phase after an edge gives the same margin coming back.
 *
 * Note that byte A - the one on the rising edge - is the *even* byte of the
 * halfword, and byte B on the falling edge is the odd one. A word is therefore
 * assembled as { rising, falling }, and the two samples that make it up are
 * taken in different CK cycles: byte B of cycle N is only latched during phase 0
 * of cycle N+1. rx_word below carries the previous cycle's word for that reason,
 * and getting this wrong is invisible in a waveform of the pins - both bytes are
 * there and correct, just paired with the wrong neighbour.
 *
 * No configuration register write is needed to bring this up. The part powers on
 * with CR0 = 8f1f: fixed latency with an initial latency of six clocks. Fixed
 * latency means the die always inserts twice that whatever the row state, so
 * RWDS never has to be sampled during the command to tell 1x from 2x apart.
 *
 * The interface matches PsramController so the two can be swapped.
 */
module PsramSdr #(
    parameter RESET_CLOCKS = 8100,       // 300us at 27MHz, comfortably past the
                                         // 150us the part wants after power up
    parameter [4:0] LATENCY = 6,         // initial latency, in CK; fixed means 2x
    // How many CK a read samples for. It only has to reach the cycle the data is
    // in, which is what the default is; widening it turns a read into a scan
    // that reports where the data really turned up, which is how the latency was
    // established in the first place - one run instead of a build per guess.
    //
    // It also sets how long CS# stays low, which the part limits to 4us. At the
    // bring-up value of 16 a read was 3 command + 16 + 2 CK, 3.3us at 6.75MHz,
    // which is both close to that limit and three CK longer than it needs to be.
    // How many words a read brings back. The latency is per access, not per
    // word - the die keeps handing over halfwords for as long as CS# stays low
    // - so a burst of four costs three extra CK rather than three more reads.
    // What limits it is that CS# may not stay low for more than 4us: at
    // 6.75MHz, 3 command + 12 latency + BURST + 2 tail is 3.1us at four and
    // over the limit at eight.
    parameter integer BURST = 4,
    parameter [4:0] SCAN_CK = 2*LATENCY + BURST
) (
    input wire clk,                      // 27MHz, the board clock
    input wire resetn,
    input wire read,                     // hold until busy rises
    input wire write,
    input wire [21:0] addr,              // byte address
    input wire [15:0] din,               // for a byte write, the byte is din[7:0]
    input wire byte_write,               // write only the byte addr[0] selects
    // BURST words, the one at addr in the low half. A write still takes one.
    output reg [16*BURST-1:0] dout,
    output wire busy,

    output wire [1:0] O_psram_ck,
    output wire [1:0] O_psram_ck_n,
    output wire [1:0] O_psram_cs_n,
    output wire [1:0] O_psram_reset_n,
    inout wire [1:0] IO_psram_rwds,
    inout wire [15:0] IO_psram_dq,

    output wire [3:0] dbg_state,
    output reg [4:0] dbg_match,          // scan index that held din; 5'h1f is none
    output reg [15:0] dbg_first,         // scan word 0, the CK right after the command
    // One bit per scanned CK, set where the bus was not idle high. The data
    // boundary shows up as the first set bit whatever the value there is, which
    // is what makes this readable without knowing what was stored.
    output reg [15:0] dbg_nonff,
    // Loopback: what the input path sees while we are driving the command. The
    // first command word of a read of address 0 is a000, so that is what this
    // should read if the pins are really being driven. yosys warns that its
    // support for tri-state logic is limited, so this is worth proving.
    output reg [15:0] dbg_ca_echo
);
    // Where the first data word lands in the scan, counting CK from the command.
    localparam [4:0] DATA_IDX = 2*LATENCY;

    // Four phases make one CK. The state machine only ever advances on phase 3,
    // so every output is stable across the whole CK cycle it belongs to.
    reg [1:0] ph;
    initial ph = 0;
    always @(posedge clk) ph <= ph + 1;
    wire step = (ph == 2'd3);

    localparam [3:0] S_RESET = 0, S_WAIT = 1, S_IDLE = 2, S_CA = 3,
                     S_LATENCY = 4, S_DATA = 5, S_TAIL = 6, S_END = 7;
    reg [3:0] state;
    reg [13:0] delay;                    // reset and power up timer, in clocks
    reg [4:0] count;                     // CK cycles left in the current phase
    reg is_read;
    reg [47:0] ca;
    reg [15:0] wdata;
    reg wbyte, wodd;
    reg [4:0] scan_idx;

    reg [7:0] rx_a, rx_b, rx_a_held;
    reg cs_n, ck_en, dq_oe, rwds_oe, rst_n;
    reg [15:0] tx;                       // the two bytes for this CK cycle
    reg [1:0] tx_mask;                   // and their RWDS write masks, A then B
    reg [7:0] dq_drive;
    reg rwds_drive;

    // The same values the reset branch below sets, given at configuration.
    // On the board these come for free - the FPGA zeroes every flip flop when
    // it is configured, and `resetn' is the reset button, which is pulled up
    // and never pressed - so the part is initialised by the state machine
    // walking out of S_RESET on its own. Simulation gets no such favour: the
    // board level testbenches hold the button released, the reset branch never
    // runs, and every one of these registers stays x for the whole run. RESET#
    // being x is enough on its own to make the die ignore the bus completely,
    // and then every read comes back as z - which reaches the CPU as a byte of
    // x, poisons the address it is used to compute, and stops the machine dead
    // with no memory access ever having been attempted.
    initial begin
        state = S_RESET; delay = 0; count = 0;
        cs_n = 1; ck_en = 0; dq_oe = 0; rwds_oe = 0; rst_n = 0;
        dout = 0; is_read = 0; wbyte = 0; wodd = 0;
        ca = 0; wdata = 0; tx = 0; tx_mask = 0; dq_drive = 0; rwds_drive = 0;
        rx_a = 0; rx_b = 0; rx_a_held = 0;
        dbg_match = 5'h1f; dbg_first = 0; dbg_nonff = 0;
        scan_idx = 0; dbg_ca_echo = 0;
    end

    assign busy = (state != S_IDLE);
    assign dbg_state = state;

    // CK high through phases 2 and 3: computed from the pre-edge phase, so it
    // rises on 1->2 and falls on 3->0.
    reg ck_r;
    always @(posedge clk) ck_r <= ck_en && (ph == 2'd1 || ph == 2'd2);

    assign O_psram_ck   = { 1'b0, ck_r };
    assign O_psram_ck_n = { 1'b1, ~ck_r };
    assign O_psram_cs_n = { 1'b1, cs_n };
    assign O_psram_reset_n = { 1'b1, rst_n };

    // Byte A takes effect at the 0->1 edge and byte B at 2->3, so each is valid
    // across the CK edge that latches it. Registering B at phase 2 also carries
    // it through phase 0 of the next cycle, which is where it belongs.
    always @(posedge clk) begin
        if (ph == 2'd0) begin dq_drive <= tx[15:8]; rwds_drive <= tx_mask[1]; end
        if (ph == 2'd2) begin dq_drive <= tx[7:0];  rwds_drive <= tx_mask[0]; end
    end

    // Explicit IOBUF primitives rather than "assign io = oe ? d : 1'bz". yosys
    // warns that its support for tri-state logic is limited, and the working
    // reference design instantiates IOBUFs, so do the same rather than rely on
    // inference. OEN is active low.
    wire [7:0] dq_in;
    wire rwds_in;
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin: dq_buf
            IOBUF dq_io(.O(dq_in[i]), .IO(IO_psram_dq[i]),
                        .I(dq_drive[i]), .OEN(~dq_oe));
        end
        // The second die's half of the bus is never driven. Its CK, CS# and
        // RESET# above are held inactive to match.
        for (i = 8; i < 16; i = i + 1) begin: dq_buf_hi
            IOBUF dq_io_hi(.O(), .IO(IO_psram_dq[i]), .I(1'b0), .OEN(1'b1));
        end
    endgenerate
    IOBUF rwds_io(.O(rwds_in), .IO(IO_psram_rwds[0]),
                  .I(rwds_drive), .OEN(~rwds_oe));
    IOBUF rwds_io_hi(.O(), .IO(IO_psram_rwds[1]), .I(1'b0), .OEN(1'b1));

    // One phase after each CK edge, by a plain flop. This is the whole point of
    // the design: no IOLOGIC anywhere on the input path. rx_a is held as byte B
    // is captured so that the two halves of one CK cycle's word are available
    // together, one cycle after that word went past.
    always @(posedge clk) begin
        if (ph == 2'd2) rx_a <= dq_in;
        if (ph == 2'd0) begin rx_b <= dq_in; rx_a_held <= rx_a; end
    end
    wire [15:0] rx_word = { rx_a_held, rx_b };   // the previous CK cycle's word

    // Crossing into this domain. The clock here is the board clock multiplied,
    // so read and write arrive from a slower domain of their own; two flip flops
    // settle them. Nothing else needs crossing, because the protocol already
    // holds everything steady: addr, din and byte_write do not move until busy
    // has risen, by which time the request has been seen here.
    reg [1:0] read_sync, write_sync;
    initial begin read_sync = 0; write_sync = 0; end
    always @(posedge clk) begin
        read_sync <= { read_sync[0], read };
        write_sync <= { write_sync[0], write };
    end
    wire read_s = read_sync[1];
    wire write_s = write_sync[1];

    always @(posedge clk) begin
        if (!resetn) begin
            state <= S_RESET; delay <= 0; count <= 0;
            cs_n <= 1; ck_en <= 0; dq_oe <= 0; rwds_oe <= 0; rst_n <= 0;
            dout <= 0; is_read <= 0; wbyte <= 0; wodd <= 0;
            dbg_match <= 5'h1f; dbg_first <= 0; dbg_nonff <= 0;
            scan_idx <= 0; dbg_ca_echo <= 0;
        end else begin
            case (state)
                // Hold RESET# low, then leave the part alone while it wakes up.
                S_RESET: begin
                    rst_n <= 0;
                    delay <= delay + 1;
                    if (delay == RESET_CLOCKS[13:0]) begin
                        delay <= 0;
                        state <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    rst_n <= 1;
                    delay <= delay + 1;
                    if (delay == RESET_CLOCKS[13:0]) state <= S_IDLE;
                end

                S_IDLE: if (step && (read_s || write_s)) begin
                    is_read <= read_s;
                    wdata <= din;
                    wbyte <= byte_write;
                    wodd <= addr[0];
                    // CA: read/write, memory space, linear burst, then the
                    // halfword address split the way the bus wants it.
                    ca <= { read_s, 2'b01, 11'b0, addr[21:4], 13'b0, addr[3:1] };
                    cs_n <= 0;
                    ck_en <= 1;
                    dq_oe <= 1;
                    count <= 3;                  // three CK of command
                    scan_idx <= 0;
                    if (read_s) begin
                        dbg_match <= 5'h1f;
                        dbg_nonff <= 0;
                    end
                    state <= S_CA;
                end

                S_CA: if (step) begin
                    // rx_word lags one CK, so the step that leaves the second
                    // command cycle is the one that can see the first.
                    if (count == 2) dbg_ca_echo <= rx_word;
                    ca <= { ca[31:0], 16'b0 };
                    count <= count - 1;
                    if (count == 1) begin
                        dq_oe <= ~is_read;       // let go early for a read
                        // A read starts sampling immediately and scans for the
                        // data; a write has to sit out the whole latency first.
                        count <= is_read ? 5'd1 : DATA_IDX;
                        state <= S_LATENCY;
                    end
                end

                S_LATENCY: if (step) begin
                    count <= count - 1;
                    if (count == 1) begin
                        rwds_oe <= ~is_read;     // RWDS is the write mask
                        count <= is_read ? SCAN_CK : 5'd1;
                        state <= S_DATA;
                    end
                end

                // A write drives its one word. A read walks a window of CK
                // cycles, takes the data from where the latency says it is, and
                // records what it saw everywhere else.
                S_DATA: if (step) begin
                    if (is_read) begin
                        if (scan_idx == 0) dbg_first <= rx_word;
                        // Each word shifts in at the top, so when the last one
                        // arrives the first is sitting in the low half.
                        if (scan_idx >= DATA_IDX && scan_idx < DATA_IDX + BURST)
                            dout <= { rx_word, dout[16*BURST-1:16] };
                        if (rx_word != 16'hffff) dbg_nonff[scan_idx[3:0]] <= 1;
                        if (rx_word == wdata && dbg_match == 5'h1f)
                            dbg_match <= scan_idx;
                        scan_idx <= scan_idx + 1;
                    end
                    count <= count - 1;
                    if (count == 1) begin
                        ck_en <= 0;
                        state <= S_TAIL;
                    end
                end

                // The clock is already stopped by the time the bus is released
                // and CS# goes high, and the order matters. Raising CS# on the
                // same edge that produced the last CK edge violates the part's
                // CS# hold time, and it also left one CK edge pair happening
                // while RWDS floated - which a write burst reads as "write this
                // byte too", so every write silently put an extra word of
                // rubbish into the next location.
                S_TAIL: if (step) begin
                    dq_oe <= 0;
                    rwds_oe <= 0;
                    cs_n <= 1;
                    state <= S_END;
                end

                S_END: if (step) state <= S_IDLE;   // CS# high for one CK

                default: state <= S_IDLE;
            endcase
        end
    end

    // What to drive this CK cycle: the command, then the data on a write. A byte
    // write puts the same byte on both edges and lets RWDS pick which one lands.
    always @(*) begin
        tx = 16'b0;
        tx_mask = 2'b11;                 // 1 means leave this byte alone
        if (state == S_CA) tx = ca[47:32];
        else if (state == S_DATA && !is_read) begin
            tx = wbyte ? { wdata[7:0], wdata[7:0] } : wdata;
            tx_mask = wbyte ? { wodd, ~wodd } : 2'b00;
        end
    end
endmodule

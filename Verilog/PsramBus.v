/**
 * Puts the PSRAM on the CPU's bus.
 *
 * A HyperBus access is about 2.8us - roughly fourteen CPU bus cycles at 5MHz -
 * so the core has to be held still while one runs. That is done by withholding
 * its clock enable and handing it back once the access is complete, which keeps
 * the whole design in one clock domain and needs no handshake with the core: to
 * CPU6 a stalled cycle is simply a long one, and every signal it drives stays
 * put because it is the enable that would have moved them.
 *
 * Two things make this affordable. The block RAM still answers the ROM, the low
 * RAM and the working RAM, which is where everything the machine currently runs
 * lives, so none of it slows down at all. And a one word cache collapses the
 * repeated reads of one address that a microcoded machine does constantly: the
 * MAR sits still for most of an instruction, and without the cache every single
 * cycle it spent pointing into PSRAM would cost a full access whether the
 * microcode wanted the data or not. There is no read strobe on this bus to tell
 * the difference.
 *
 * The cache is only correct because everything that writes memory does so
 * through this port. That includes DMA: on this machine a device does not master
 * the bus, it borrows the core's address registers and its write strobe, so a
 * DMA write arrives here as an ordinary write and drops the line like any other.
 * A device that drove the memory itself would have to invalidate separately.
 */
module PsramBus #(
    // Only ever cleared by a testbench, to show what the spacing guard below is
    // for. With it off the core can be handed two enabled edges one board clock
    // apart, which this design's block RAMs cannot survive.
    parameter ENFORCE_SPACING = 1
) (
    input wire clock,
    input wire reset,                    // the core's reset, which this follows
    input wire cpu_en,                   // ClockEnable's ungated output
    input wire select,                   // this address belongs to the PSRAM
    input wire [18:0] address,
    input wire write_en,
    input wire [7:0] data_in,
    output wire [7:0] data_out,
    output wire cpu_en_out,              // what the core and the peripherals run on

    // To PsramSdr.
    output reg read, output reg write, output reg byte_write,
    output reg [22:0] addr, output reg [15:0] din,
    input wire [63:0] dout, input wire busy,

    // How many accesses have been made, and where the last one went. Zero
    // accesses means the CPU has never addressed the PSRAM at all, which is a
    // different fault from the data coming back wrong.
    output reg [15:0] dbg_accesses,
    output reg [18:0] dbg_last_addr,
    output reg [7:0] dbg_last_data,
    output reg [15:0] dbg_timeouts,
    // What the bridge was doing when it last gave up: {busy, state}. That says
    // whether the controller never accepted the request or never finished it.
    output reg [2:0] dbg_timeout_where,
    // Live state, so a dump taken at any moment says what the bridge is doing
    // rather than only what it did when it last gave up.
    output wire [1:0] dbg_state,
    output wire dbg_need
);
    // How long to wait for the controller before giving up on an access. A read is
    // about 88 clocks, so this is fifty times longer than anything healthy.
    localparam [12:0] TIMEOUT = 13'd4095;
    localparam S_IDLE = 0, S_REQ = 1, S_WAIT = 2;
    reg [1:0] state;

    // A small direct mapped cache of four word lines, which is what PsramSdr
    // brings back in a single burst. The latency is per access rather than per
    // word, so the other three words are very nearly free, and anything walking
    // memory in order pays it once every eight bytes instead of every two.
    //
    // More than one line matters as soon as anything *runs* from the PSRAM. A
    // twelve byte loop spans two lines, so with a single line every crossing
    // misses: measured against the address stream probe21.s produces, one line
    // hits 79.9% of the time and two hit 99.9%. Four is two doublings of margin
    // over that for the price of a wider multiplexer, and the real test is an
    // operating system with a working set far larger than a loop.
    // Sixteen lines of four words: 128 bytes, where four lines held 32.
    //
    // Deliberately modest. This lives in LUTRAM, which the disk controllers
    // still to be built are unlikely to want much of, and it leaves the block
    // RAM alone: the floppy, Finch and Hawk controllers all need sector buffers
    // - a Hawk sector is about 400 bytes - and only eight of the device's
    // twenty six BSRAM blocks are still free. Growing this is a one line change
    // if a workload ever justifies it, but those blocks are spoken for.
    // Sixteen, not the thirty two this was grown to. That was sized for a 256
    // byte loop running out of PSRAM and bought about one percent of stall time
    // over sixteen; the storage stack needs the room more than the benchmark
    // does, and the machine's own working set is in block RAM either way.
    // Halving it again to eight was tried and saved 44 LUT4 out of 7300, which
    // is not where the logic is.
    localparam integer LINES = 16;
    localparam integer IDXBITS = 4;      // must be $clog2(LINES)
    reg [15-IDXBITS:0] cache_tag [0:LINES-1];
    reg [63:0] cache_data [0:LINES-1];
    reg [LINES-1:0] cache_valid;
    wire [IDXBITS-1:0] idx = address[2+IDXBITS:3];
    wire [15-IDXBITS:0] tag = address[18:3+IDXBITS];
    wire [63:0] cache_line = cache_data[idx];
    // Writes are posted. The core hands one over and carries on; the bridge puts
    // it away in its own time. Waiting for a write to reach the memory cost the
    // core 2.55us every time, and nothing about a store needs it to wait - the
    // burst and the cache both help reads only, so this is the writes' turn.
    //
    // What makes it safe is that a read drains the buffer first. A read that
    // missed the cache could otherwise overtake a write still sitting here and
    // fetch the old contents of the line. It costs little in practice, because a
    // write patches the cache on its way in, so a read of what was just written
    // hits and never reaches the memory at all.
    localparam integer WBUF = 8;
    localparam integer WPTR = 3;         // must be $clog2(WBUF)
    reg [18:0] wbuf_addr [0:WBUF-1];
    reg [7:0]  wbuf_data [0:WBUF-1];
    reg [WPTR:0] wr_in, wr_out;          // one bit wider than the index, so that
                                         // full and empty can be told apart
    reg wr_done;                         // this CPU cycle's write has been made
    reg is_read_acc;                     // the access in flight is a read
    reg [12:0] elapsed;                  // clocks spent on the access in flight

    integer k;
    initial begin
        state = S_IDLE; cache_valid = 0; wr_in = 0; wr_out = 0;
        for (k = 0; k < LINES; k = k + 1) begin
            cache_tag[k] = 0; cache_data[k] = 0;
        end
        wr_done = 0; is_read_acc = 0;
        read = 0; write = 0; byte_write = 0; addr = 0; din = 0;
        dbg_accesses = 0; dbg_last_addr = 0; dbg_last_data = 0; dbg_timeouts = 0;
        dbg_timeout_where = 0; elapsed = 0;
    end

    // Nothing is asked of the memory while the core is in reset. The core needs
    // its enable during reset - the sequence is counted in enabled cycles - so
    // stalling it there would be wrong as well as pointless.
    wire wbuf_empty = (wr_in == wr_out);
    wire wbuf_full = (wr_in[WPTR-1:0] == wr_out[WPTR-1:0]) && (wr_in[WPTR] != wr_out[WPTR]);

    wire active = select && !reset;
    wire hit = cache_valid[idx] && (cache_tag[idx] == tag);
    // A read waits for the buffer to empty; a write only waits if it is full.
    wire want_read  = active && !write_en && !hit;
    wire want_write = active &&  write_en && !wr_done;
    // A read stalls the core until it is satisfied; a write only stalls it when
    // there is nowhere to put it.
    wire need = want_read || (want_write && wbuf_full);
    // Something for the memory to do: a read once the buffer is clear, or a
    // buffered write whenever there is one.
    wire issue_read = want_read && wbuf_empty;
    wire issue_write = !wbuf_empty;

    // The access in flight refers to the address latched when it started, not
    // to wherever the core has since pointed.
    wire [IDXBITS-1:0] acc_idx = addr[2+IDXBITS:3];
    wire [15-IDXBITS:0] acc_tag = addr[18:3+IDXBITS];

    assign dbg_state = state;
    assign dbg_need = need;

    // Byte A of a HyperBus word is the even byte, so it is the high half here.
    wire [15:0] cache_word = (address[2:1] == 2'd0) ? cache_line[15:0]  :
                             (address[2:1] == 2'd1) ? cache_line[31:16] :
                             (address[2:1] == 2'd2) ? cache_line[47:32] :
                                                      cache_line[63:48];
    assign data_out = address[0] ? cache_word[7:0] : cache_word[15:8];

    // The core's enable, withheld while an access runs and handed back after.
    // ClockEnable free runs, so a withheld pulse has to be remembered rather than
    // waited for: at 5MHz in 27 the next one is only five clocks away, but an
    // access is nearer eighty, and simply masking the enable would hand the core
    // whichever pulse happened to land first after the stall ended.
    //
    // The spacing guard is not optional. This design has a hard floor of two board
    // clocks between enabled cycles, because the microcode ROM, the register file
    // and the board's memory are all block RAMs that read every clock and need one
    // to settle. ClockEnable respects that on its own - five enables in twenty
    // seven are never adjacent - but handing back a withheld pulse does not: the
    // grant lands wherever the access happens to finish, and if that is one clock
    // before ClockEnable's next pulse the core takes two enabled edges in a row and
    // reads a block RAM that has not caught up. The result is one wrong byte, very
    // occasionally, which in diag's mapping test arrives as a page table entry that
    // reads back as zero - about one pass in four hundred, and only ever with the
    // PSRAM on the bus, because without it nothing is ever withheld.
    reg owed;
    reg [1:0] since_en;
    initial begin owed = 0; since_en = 2'd3; end
    wire spaced = (since_en >= 2'd2) || (ENFORCE_SPACING == 0);
    assign cpu_en_out = !need && spaced && (cpu_en || owed);
    always @(posedge clock) begin
        if (cpu_en_out) owed <= 0;
        else if (cpu_en) owed <= 1;

        if (cpu_en_out) since_en <= 0;
        else if (since_en != 2'd3) since_en <= since_en + 1;
    end

    always @(posedge clock) begin
      if (reset) begin
        // Like everything else with state in this design, this follows the core's
        // reset. Leaving the cache valid across a reset would hand the restarted
        // machine one stale byte from the previous run, which is exactly the class
        // of fault that made diag's mapping test pass once and then fail for ever.
        state <= S_IDLE;
        cache_valid <= 0;
        // Everything with state follows the core's reset, the buffer included:
        // a write left over from before a reset would land in a machine that
        // has forgotten asking for it.
        wr_in <= 0;
        wr_out <= 0;
        wr_done <= 0;
        read <= 0;
        write <= 0;
        elapsed <= 0;
      end else begin
        if (cpu_en_out) wr_done <= 0;    // the core moves on to the next cycle

        // Take the core's write into the buffer and let it go. The cache is
        // patched here rather than when the write reaches the memory, so that a
        // read of what was just written hits immediately instead of waiting for
        // the buffer to drain.
        if (active && write_en && !wr_done && !wbuf_full) begin
            wbuf_addr[wr_in[WPTR-1:0]] <= address;
            wbuf_data[wr_in[WPTR-1:0]] <= data_in;
            wr_in <= wr_in + 1;
            wr_done <= 1;
            // Drop the line rather than patching the byte into it. Patching
            // is a read-modify-write of one byte inside a sixty four bit word,
            // which is not something LUTRAM can do, so yosys built the whole
            // cache out of flip flops and a thirty two way multiplexer instead
            // - 94% of the LUT4 on the device, with three disk controllers
            // still to find room for. Invalidating is correct because a read
            // drains the write buffer before it is issued, so the refetch sees
            // the write that just went past.
            if (cache_valid[idx] && cache_tag[idx] == tag)
                cache_valid[idx] <= 0;
        end

        // A memory that stops answering must not be able to wedge the machine.
        // The core is held still by withholding its clock enable, so anything
        // that leaves `need' asserted for ever is a permanent stall - and a
        // permanent stall is not merely slow, it is silent: the watchdog blinks
        // the LEDs, diag stops printing, and even the status dump goes away,
        // because the request for one is noticed by logic that only advances on
        // the core's enable. There is then nothing left to ask what went wrong.
        //
        // So time the whole of `need', not just an access in flight. Waiting in
        // S_IDLE for a controller that never becomes idle stalls exactly as hard
        // as an access that never finishes, and the first version of this timer
        // only covered the second case.
        // Time the memory being busy as well as the core being stalled. A
        // posted write drains while the core runs on, so a write that never
        // finished would otherwise go unnoticed until the buffer filled.
        if (need || state != S_IDLE) elapsed <= elapsed + 1;
        else elapsed <= 0;

        if ((need || state != S_IDLE) && elapsed == TIMEOUT) begin
            dbg_timeouts <= dbg_timeouts + 1;
            dbg_timeout_where <= { busy, state };
            read <= 0;
            write <= 0;
            // Satisfy the cycle from the live request rather than the registered
            // one: the timeout can fire before anything was ever latched.
            cache_data[idx] <= {64{1'b1}};
            cache_tag[idx] <= tag;
            cache_valid[idx] <= want_read;
            wr_done <= want_write;
            // Drop whatever was in flight, or the same access is retried for
            // ever and the buffer never empties.
            if (state != S_IDLE && !is_read_acc) wr_out <= wr_out + 1;
            state <= S_IDLE;
        end else

        case (state)
            // Only start when the controller is actually idle. It is not idle for
            // the first 600us after configuration, while it resets the part and
            // waits for it to wake up, and without this guard the request is never
            // taken: PsramSdr only samples read and write from its own idle state,
            // so S_REQ below would see the *initialisation's* busy, conclude the
            // access had been accepted, and hand the CPU whatever dout happened to
            // hold. If that byte is an instruction the machine executes rubbish,
            // which is intermittent because it depends on whether the CPU reaches
            // PSRAM before the part has finished waking up.
            // Buffered writes go first, which is what keeps a read from
            // overtaking one. issue_read already requires an empty buffer, so
            // the two can never both be asking.
            S_IDLE: if ((issue_write || issue_read) && !busy) begin
                if (issue_write) begin
                    addr <= { 3'b0, wbuf_addr[wr_out[WPTR-1:0]] };
                    din <= { 8'h00, wbuf_data[wr_out[WPTR-1:0]] };
                    byte_write <= 1;
                    read <= 0;
                    write <= 1;
                    is_read_acc <= 0;
                end else begin
                    // A read fetches the whole line, so it asks for its start.
                    addr <= { 3'b0, address[18:3], 3'b000 };
                    byte_write <= 0;
                    read <= 1;
                    write <= 0;
                    is_read_acc <= 1;
                end
                state <= S_REQ;
            end

            S_REQ: if (busy) begin       // the controller has taken it
                read <= 0;
                write <= 0;
                state <= S_WAIT;
            end

            S_WAIT: if (!busy) begin
                dbg_accesses <= dbg_accesses + 1;
                dbg_last_addr <= addr[18:0];
                if (is_read_acc) begin
                    cache_data[acc_idx] <= dout;
                    cache_tag[acc_idx] <= acc_tag;
                    cache_valid[acc_idx] <= 1;
                    dbg_last_data <= dout[15:8];
                end else begin
                    wr_out <= wr_out + 1;
                    dbg_last_data <= din[7:0];
                    // Keep the cache coherent rather than dropping it: a store
                    // followed by a load of the same byte is common enough that
                    // invalidating would double the cost of it.
                    if (cache_valid[acc_idx] && cache_tag[acc_idx] == acc_tag) begin
                        case ({ addr[2:1], addr[0] })
                            3'b000: cache_data[acc_idx][15:8]  <= din[7:0];
                            3'b001: cache_data[acc_idx][7:0]   <= din[7:0];
                            3'b010: cache_data[acc_idx][31:24] <= din[7:0];
                            3'b011: cache_data[acc_idx][23:16] <= din[7:0];
                            3'b100: cache_data[acc_idx][47:40] <= din[7:0];
                            3'b101: cache_data[acc_idx][39:32] <= din[7:0];
                            3'b110: cache_data[acc_idx][63:56] <= din[7:0];
                            3'b111: cache_data[acc_idx][55:48] <= din[7:0];
                        endcase
                    end
                end
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
      end
    end
endmodule

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
 * The cache is only correct because the CPU is the sole writer. A write to the
 * cached word patches it in place; a write anywhere else leaves it alone. If DMA
 * ever writes memory, this needs invalidating from that side too.
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
    output reg [21:0] addr, output reg [15:0] din,
    input wire [15:0] dout, input wire busy,

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

    reg [17:0] cache_addr;               // the word address held below
    reg [15:0] cache_word;
    reg cache_valid;
    reg wr_done;                         // this CPU cycle's write has been made
    reg is_read_acc;                     // the access in flight is a read
    reg [12:0] elapsed;                  // clocks spent on the access in flight

    initial begin
        state = S_IDLE; cache_addr = 0; cache_word = 0; cache_valid = 0;
        wr_done = 0; is_read_acc = 0;
        read = 0; write = 0; byte_write = 0; addr = 0; din = 0;
        dbg_accesses = 0; dbg_last_addr = 0; dbg_last_data = 0; dbg_timeouts = 0;
        dbg_timeout_where = 0; elapsed = 0;
    end

    // Nothing is asked of the memory while the core is in reset. The core needs
    // its enable during reset - the sequence is counted in enabled cycles - so
    // stalling it there would be wrong as well as pointless.
    wire active = select && !reset;
    wire hit = cache_valid && (cache_addr == address[18:1]);
    wire want_read  = active && !write_en && !hit;
    wire want_write = active &&  write_en && !wr_done;
    wire need = want_read || want_write;

    assign dbg_state = state;
    assign dbg_need = need;

    // Byte A of a HyperBus word is the even byte, so it is the high half here.
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
        wr_done <= 0;
        read <= 0;
        write <= 0;
        elapsed <= 0;
      end else begin
        if (cpu_en_out) wr_done <= 0;    // the core moves on to the next cycle

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
        if (need) elapsed <= elapsed + 1;
        else elapsed <= 0;

        if (need && elapsed == TIMEOUT) begin
            dbg_timeouts <= dbg_timeouts + 1;
            dbg_timeout_where <= { busy, state };
            read <= 0;
            write <= 0;
            // Satisfy the cycle from the live request rather than the registered
            // one: the timeout can fire before anything was ever latched.
            cache_word <= 16'hffff;
            cache_addr <= address[18:1];
            cache_valid <= want_read;
            wr_done <= want_write;
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
            S_IDLE: if (need && !busy) begin
                addr <= { 3'b0, address };
                din <= { 8'h00, data_in };
                byte_write <= want_write;
                read <= want_read;
                write <= want_write;
                is_read_acc <= want_read;
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
                    cache_word <= dout;
                    cache_addr <= addr[18:1];
                    cache_valid <= 1;
                    dbg_last_data <= addr[0] ? dout[7:0] : dout[15:8];
                end else begin
                    wr_done <= 1;
                    dbg_last_data <= din[7:0];
                    // Keep the cache coherent rather than dropping it: a store
                    // followed by a load of the same byte is common enough that
                    // invalidating would double the cost of it.
                    if (cache_valid && cache_addr == addr[18:1]) begin
                        if (addr[0]) cache_word[7:0]  <= din[7:0];
                        else         cache_word[15:8] <= din[7:0];
                    end
                end
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
      end
    end
endmodule

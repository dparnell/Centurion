/**
 * Bring-up self test for the PSRAM.
 *
 * Runs entirely in the PSRAM controller's own clock domain with no CPU
 * involvement, writes a handful of words spread across the die and reads them
 * back. This is deliberately the first step: the SD card design note in
 * docs/ argues for proving a memory layer standalone before wiring it to the
 * bus, because when something then does not work there is one fewer thing it
 * could be. There is no HyperRAM model in this repository, so simulation
 * cannot answer whether the controller talks to a real part - only hardware
 * can - but PsramTB runs this same test against a behavioural die, which is
 * where the plumbing faults get found.
 *
 * The addresses are chosen to catch the usual faults: two adjacent words, a
 * word a page away, and words at 4K, 64K and the top of the first die, so that
 * an address line stuck or swapped shows up as an alias rather than passing.
 * The data is a function of the address for the same reason.
 */
module PsramTest(input wire clk, input wire resetn,
    output reg read, output reg write, output reg byte_write,
    output reg [21:0] addr, output reg [15:0] din,
    input wire [15:0] dout, input wire busy,
    output reg done, output reg pass,
    output reg [15:0] got, output reg [15:0] want, output reg [21:0] failed_at,
    // Bring-up visibility: which step it reached, and whether the controller ever
    // became idle at all - that is, whether it finished its own initialisation.
    output wire [2:0] stage, output reg [2:0] index, output reg saw_idle,
    // How long the current step has been waiting. A saturating count, so a stuck
    // handshake shows up as a large number rather than a wrapped small one.
    output reg [15:0] stage_cycles,
    // The first two words read back, recorded unconditionally. If every read
    // returns the same value regardless of what was written, the read path is not
    // returning device data at all; if they differ, the write path is the suspect.
    output reg [15:0] read0, output reg [15:0] read1);

    localparam N = 6;

    function [21:0] test_addr(input [2:0] i);
        case (i)
            0: test_addr = 22'h000000;
            1: test_addr = 22'h000002;
            2: test_addr = 22'h000800;
            3: test_addr = 22'h001000;
            4: test_addr = 22'h010000;
            default: test_addr = 22'h3ffffe;
        endcase
    endfunction

    // Address dependent, so that an aliased access fails rather than passing.
    function [15:0] test_data(input [21:0] a);
        test_data = { a[15:8] ^ 8'h5a, a[7:0] ^ 8'ha5 };
    endfunction

    // A word built out of two byte writes, one to each half. The CPU is byte
    // addressed, so this path carries most of its traffic and is worth proving
    // here rather than discovering through the CPU.
    localparam [21:0] BYTE_ADDR = 22'h000100;
    localparam [15:0] BYTE_WANT = 16'ha53c;

    function [21:0] byte_step_addr(input [1:0] b);
        byte_step_addr = (b == 2'd2) ? BYTE_ADDR + 1 : BYTE_ADDR;
    endfunction

    function [15:0] byte_step_data(input [1:0] b);
        case (b)
            2'd1: byte_step_data = { 8'h00, BYTE_WANT[15:8] };
            2'd2: byte_step_data = { 8'h00, BYTE_WANT[7:0] };
            // On the read, din is what the controller's bring-up scan looks for,
            // so give it the answer rather than leaving the scan with nothing to
            // match against on the last access of the run.
            2'd3: byte_step_data = BYTE_WANT;
            default: byte_step_data = 16'h0000;   // clear the word first
        endcase
    endfunction

    localparam S_INIT = 0, S_WRITE = 1, S_WDONE = 2,
               S_READ = 3, S_RDONE = 4, S_BYTE = 5, S_BDONE = 6, S_DONE = 7;
    reg [2:0] state;
    reg [2:0] i;
    reg [1:0] b;
    assign stage = state;

    initial begin
        read = 0; write = 0; byte_write = 0; addr = 0; din = 0;
        done = 0; pass = 1; got = 0; want = 0; failed_at = 0;
        state = S_INIT; i = 0; b = 0; index = 0; saw_idle = 0; stage_cycles = 0;
        read0 = 0; read1 = 0;
    end

    always @(posedge clk) begin
        if (!resetn) begin
            read <= 0; write <= 0; byte_write <= 0;
            done <= 0; pass <= 1; got <= 0; want <= 0; failed_at <= 0;
            state <= S_INIT; i <= 0; b <= 0; index <= 0; saw_idle <= 0; stage_cycles <= 0;
        end else begin
            if (!busy) saw_idle <= 1;
            index <= i;
            if (stage_cycles != 16'hffff) stage_cycles <= stage_cycles + 1;
            case (state)
                // The controller holds busy through its 150us power on
                // initialisation, so the first idle is the part being ready.
                S_INIT: if (!busy) begin
                    i <= 0;
                    state <= S_WRITE;
                    stage_cycles <= 0;
                end

                S_WRITE: begin
                    addr <= test_addr(i);
                    din <= test_data(test_addr(i));
                    byte_write <= 0;
                    write <= 1;
                    if (busy) begin           // request taken
                        write <= 0;
                        state <= S_WDONE;
                        stage_cycles <= 0;
                    end
                end

                S_WDONE: if (!busy) begin
                    if (i == N-1) begin i <= 0; state <= S_READ; end
                    else begin i <= i + 1; state <= S_WRITE; end
                end

                S_READ: begin
                    addr <= test_addr(i);
                    din <= test_data(test_addr(i));   // what the PHY should find
                    read <= 1;
                    if (busy) begin
                        read <= 0;
                        state <= S_RDONE;
                    end
                end

                S_RDONE: if (!busy) begin
                    if (i == 0) read0 <= dout;
                    if (i == 1) read1 <= dout;
                    if (dout != test_data(test_addr(i)) && pass) begin
                        pass <= 0;
                        got <= dout;
                        want <= test_data(test_addr(i));
                        failed_at <= test_addr(i);
                    end
                    if (i == N-1) begin b <= 0; state <= S_BYTE; end
                    else begin i <= i + 1; state <= S_READ; end
                end

                // Clear a word, write each of its bytes on its own, then read
                // the word back. Getting the two halves the wrong way round
                // still passes a whole-word test, so nothing above catches it.
                S_BYTE: begin
                    addr <= byte_step_addr(b);
                    din <= byte_step_data(b);
                    byte_write <= (b == 2'd1) || (b == 2'd2);
                    write <= (b != 2'd3);
                    read <= (b == 2'd3);
                    if (busy) begin
                        write <= 0;
                        read <= 0;
                        state <= S_BDONE;
                        stage_cycles <= 0;
                    end
                end

                S_BDONE: if (!busy) begin
                    if (b == 2'd3) begin
                        if (dout != BYTE_WANT && pass) begin
                            pass <= 0;
                            got <= dout;
                            want <= BYTE_WANT;
                            failed_at <= BYTE_ADDR;
                        end
                        state <= S_DONE;
                    end else begin
                        b <= b + 1;
                        state <= S_BYTE;
                    end
                end

                S_DONE: done <= 1;
                default: state <= S_INIT;
            endcase
        end
    end
endmodule

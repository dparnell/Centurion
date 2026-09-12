/**
 * Behavioural HyperRAM (HyperBus) die, enough of one to bring a controller up.
 *
 * Simulation only, and deliberately not a datasheet model: it implements the
 * command/address decode, fixed read and write latency, the RWDS write mask and
 * linear bursts in memory space, plus the ID registers in register space. It
 * does not model any timing parameter, refresh, wrapped bursts or the
 * configuration registers being written.
 *
 * The point of having it at all is that the PHY's plumbing - which byte goes on
 * which clock edge, how a returned word is reassembled, where the latency
 * boundary falls - is exactly the sort of thing that is tedious to find with a
 * three minute build-load-capture cycle on the board and trivial to find here.
 * What it cannot answer is anything physical, so the hardware scan in PsramSdr
 * still earns its place.
 */
module HyperRamModel #(
    parameter [7:0] FILL = 8'hff,    // what unwritten memory reads back as
    parameter LATENCY = 6,           // initial latency in clocks; fixed latency
                                     // means the die always inserts twice this
    parameter [15:0] ID0 = 16'h0c86, // what a register space read of 0 returns
    parameter integer ADDR_BITS = 22
) (
    input wire ck,
    input wire cs_n,
    input wire resetn,
    inout wire rwds,
    inout wire [7:0] dq
);
    localparam integer SIZE = 1 << ADDR_BITS;
    reg [7:0] mem [0:SIZE-1];

    reg [7:0] dq_out;
    reg       dq_oe;
    reg       rwds_out;
    reg       rwds_oe;
    assign dq   = dq_oe   ? dq_out   : 8'bz;
    assign rwds = rwds_oe ? rwds_out : 1'bz;

    reg [47:0] ca;
    reg is_read, is_reg;
    reg [ADDR_BITS-1:0] byteaddr;
    integer i;

    // Counts of what actually happened, so a testbench can say "the die was
    // never selected" rather than only "the data was wrong".
    integer bursts = 0, bytes_written = 0, bytes_read = 0;

    initial begin
        dq_oe = 0; rwds_oe = 0; dq_out = 0; rwds_out = 0;
        ca = 0; is_read = 0; is_reg = 0; byteaddr = 0;
        // What an unwritten byte reads back as. A real part comes up holding
        // arbitrary data and 0xff is the honest default, but the reference
        // emulator's memory starts at zero - and that difference is visible in
        // the boot, where a list walk reads a flag byte out of memory the
        // operating system has not filled yet and stops on bit 7. FILL makes the
        // two comparable so the dependence can be measured rather than argued
        // about.
        for (i = 0; i < SIZE; i = i + 1) mem[i] = FILL;
    end

    // CS# rising ends the burst wherever it had got to.
    always @(posedge cs_n) begin
        disable burst;
        dq_oe = 0;
        rwds_oe = 0;
    end

    always @(negedge cs_n) begin: burst
        if (resetn !== 1'b1) disable burst;
        dq_oe = 0;
        rwds_oe = 0;
        bursts = bursts + 1;

        // 48 bits of command and address, one byte per clock edge.
        for (i = 0; i < 3; i = i + 1) begin
            @(posedge ck) ca = { ca[39:0], dq };
            @(negedge ck) ca = { ca[39:0], dq };
        end
        is_read = ca[47];
        is_reg  = ca[46];
        // HyperBus addresses are halfwords: CA[44:16] is the address above bit 3
        // and CA[2:0] is the rest of it, with the bits between reserved.
        byteaddr = { ca[16 +: (ADDR_BITS-4)], ca[2:0], 1'b0 };

        // Fixed latency: the die always inserts twice the initial latency,
        // counted in whole clocks after the command.
        for (i = 0; i < 2*LATENCY; i = i + 1) begin
            @(posedge ck);
            @(negedge ck);
        end

        if (is_read) begin
            forever begin
                @(posedge ck);
                dq_oe = 1; rwds_oe = 1;
                dq_out = is_reg ? ID0[15:8] : mem[byteaddr];
                rwds_out = 1;
                bytes_read = bytes_read + 1;
                @(negedge ck);
                dq_out = is_reg ? ID0[7:0] : mem[byteaddr+1];
                rwds_out = 0;
                bytes_read = bytes_read + 1;
                byteaddr = byteaddr + 2;
            end
        end else begin
            forever begin
                // RWDS is the write mask: high means leave this byte alone.
                @(posedge ck);
                if (rwds !== 1'b1) begin
                    mem[byteaddr] = dq;
                    bytes_written = bytes_written + 1;
                end
                @(negedge ck);
                if (rwds !== 1'b1) begin
                    mem[byteaddr+1] = dq;
                    bytes_written = bytes_written + 1;
                end
                byteaddr = byteaddr + 2;
            end
        end
    end
endmodule

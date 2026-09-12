/**
 * Two clients, one memory port.
 *
 * Both clients and the port speak the same protocol - hold read or write until
 * busy rises, then wait for it to fall; dout is valid when it has fallen - so
 * the arbitration is a grant that lasts a whole access, and a per client VIEW
 * of busy.
 *
 * The view is the part that matters and the part that is easy to get wrong.
 * A loser that saw the real busy would watch the winner's access rise and fall
 * and conclude that its own request had been served, and take the winner's
 * data. So a client that does not hold the grant sees busy low, which leaves
 * it holding its request exactly where it was - which is also how the arbiter
 * knows it still wants one. Getting this wrong lost four bytes of a sector, at
 * the two places where the CPU and the disk happened to collide, and looked
 * like a memory fault rather than an arbiter fault.
 *
 * Port A is served first when both ask at once - in the machine that is the
 * CPU's bridge, where stalling costs a bus cycle, against the disk's cache,
 * which is standing in for a drive that takes a millisecond a sector - but the
 * two alternate when both want it, so neither starves. More clients would want
 * a proper rotating arbiter; two want this.
 */
module MemoryArbiter(
    input wire clock,
    input wire reset,
    // Client A
    input wire a_read, input wire a_write, input wire a_byte_write,
    input wire [22:0] a_addr, input wire [15:0] a_din,
    output wire a_busy,
    // Client B
    input wire b_read, input wire b_write, input wire b_byte_write,
    input wire [22:0] b_addr, input wire [15:0] b_din,
    output wire b_busy,
    // The memory
    output wire mem_read, output wire mem_write, output wire mem_byte_write,
    output wire [22:0] mem_addr, output wire [15:0] mem_din,
    input wire mem_busy
);
    localparam OWNER_A = 1'b0, OWNER_B = 1'b1;
    reg grant_held, grant_owner, grant_seen, last_owner;
    wire a_wants = a_read | a_write;
    wire b_wants = b_read | b_write;
    initial begin grant_held = 0; grant_owner = 0; grant_seen = 0; last_owner = 1; end
    always @(posedge clock) begin
        if (reset) begin
            grant_held <= 0; grant_seen <= 0; last_owner <= OWNER_B;
        end else if (!grant_held) begin
            if (!mem_busy && (a_wants || b_wants)) begin
                grant_owner <= (a_wants && b_wants) ? ~last_owner :
                               a_wants ? OWNER_A : OWNER_B;
                last_owner  <= (a_wants && b_wants) ? ~last_owner :
                               a_wants ? OWNER_A : OWNER_B;
                grant_held <= 1;
                grant_seen <= 0;
            end
        end else if (mem_busy) grant_seen <= 1;
        else if (grant_seen) begin
            grant_held <= 0;
            grant_seen <= 0;
        end
    end

    wire a_owns = grant_held && grant_owner == OWNER_A;
    wire b_owns = grant_held && grant_owner == OWNER_B;
    assign a_busy = a_owns ? mem_busy : 1'b0;
    assign b_busy = b_owns ? mem_busy : 1'b0;

    assign mem_read       = b_owns ? b_read       : a_owns ? a_read  : 1'b0;
    assign mem_write      = b_owns ? b_write      : a_owns ? a_write : 1'b0;
    assign mem_byte_write = b_owns ? b_byte_write : a_byte_write;
    assign mem_addr       = b_owns ? b_addr       : a_addr;
    assign mem_din        = b_owns ? b_din        : a_din;
endmodule

/*
 * A DMA device that stores nothing.
 *
 * The thing under test is the DMA path - the request, the byte by byte
 * transfer, the address stepping, where it stops, and whether the memory
 * bridge's cache notices someone else writing - and none of that needs a
 * device that keeps data. Leaving the storage out keeps all eight of the
 * remaining block RAMs for the sector buffers the floppy, Finch and Hawk
 * controllers will want.
 *
 * Instead the byte at offset N of a transfer is f(N). Going out to memory this
 * generates it; coming in from memory it checks it. That is the trick maptest
 * uses: the value encodes where it should be, so a byte that arrives at the
 * wrong offset is unambiguous rather than merely wrong, which is what catches a
 * dropped byte, a doubled one, stepping the wrong way, or stopping in the wrong
 * place. The first mismatch is latched with its offset and both values, because
 * a count on its own says only that something went wrong somewhere.
 *
 * The CPU side follows mux.v: its registers are gated by the CPU's clock
 * enable, because a bus write lasts several board clocks and would otherwise be
 * seen several times, while the transfer side runs off the board clock.
 */
module DmaTest(
    input wire clock,
    input wire cpu_enable,       // one pulse per CPU clock
    input wire reset,            // synchronous, shared with the core
    // CPU register interface
    input wire selected,
    input wire [3:0] address,
    input wire write_en,
    input wire [7:0] data_in,
    output reg [7:0] data_out,

    // To the core's DMA engine. req says there is work to do; write says which
    // way the byte goes. step is the core telling us one byte moved: on a write
    // it took wdata, on a read rdata is what it fetched. end_of_transfer is the
    // core's own end condition, the work address register wrapping.
    output wire dma_req,
    output wire dma_write,
    output wire [7:0] dma_wdata,
    input wire dma_step,
    input wire [7:0] dma_rdata,
    input wire dma_end
);
    // What the byte at offset N should be. Any function of N would do; this one
    // is cheap and makes a wrong offset obvious by eye in a trace.
    function [7:0] pattern(input [15:0] n);
        pattern = n[7:0] ^ 8'h5a;
    endfunction

    localparam [1:0] CMD_IDLE = 2'd0, CMD_TO_DEVICE = 2'd1, CMD_TO_MEMORY = 2'd2;

    reg [1:0] cmd;
    reg busy, done;
    reg [15:0] offset;           // how many bytes have moved
    reg [15:0] bad_count;
    reg [15:0] bad_offset;
    reg [7:0] bad_want, bad_got;

    initial begin
        cmd = CMD_IDLE; busy = 0; done = 0;
        offset = 0; bad_count = 0; bad_offset = 0; bad_want = 0; bad_got = 0;
        data_out = 0;
    end

    assign dma_req = busy;
    assign dma_write = (cmd == CMD_TO_MEMORY);
    assign dma_wdata = pattern(offset);

    always @(posedge clock) begin
        if (reset) begin
            cmd <= CMD_IDLE; busy <= 0; done <= 0;
            offset <= 0; bad_count <= 0; bad_offset <= 0;
            bad_want <= 0; bad_got <= 0;
        end else begin
            // The transfer side, which runs whether or not the CPU is enabled:
            // the core steps us when it moves a byte.
            if (busy && dma_step) begin
                if (cmd == CMD_TO_DEVICE && dma_rdata != pattern(offset)) begin
                    if (bad_count == 0) begin
                        bad_offset <= offset;
                        bad_want <= pattern(offset);
                        bad_got <= dma_rdata;
                    end
                    bad_count <= bad_count + 1;
                end
                offset <= offset + 1;
            end
            if (busy && dma_end) begin
                busy <= 0;
                done <= 1;
            end

            // The register side, gated so one bus write is one write.
            if (cpu_enable && selected && write_en) begin
                case (address)
                    4'h0: begin
                        cmd <= data_in[1:0];
                        if (data_in[1:0] == CMD_IDLE) begin
                            busy <= 0;
                        end else begin
                            busy <= 1;
                            done <= 0;
                            offset <= 0;
                            bad_count <= 0;
                            bad_offset <= 0;
                            bad_want <= 0;
                            bad_got <= 0;
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    always @(*) begin
        case (address)
            4'h0: data_out = { 5'b0, bad_count != 0, done, busy };
            4'h1: data_out = bad_count[7:0];
            4'h2: data_out = bad_count[15:8];
            4'h3: data_out = bad_offset[7:0];
            4'h4: data_out = bad_offset[15:8];
            4'h5: data_out = bad_want;
            4'h6: data_out = bad_got;
            4'h7: data_out = offset[7:0];
            4'h8: data_out = offset[15:8];
            default: data_out = 8'h00;
        endcase
    end
endmodule

`timescale 1 ns/10 ps
/*
 * A behavioural SDHC card on SPI, backed by an image loaded with $readmemh.
 *
 * The SD design note argues for one of these and it is right: without it
 * `make diagtest` cannot run a disk test at all and every change has to be
 * judged on hardware, which this project has repeatedly shown is the slow and
 * error prone way round. A build, load and capture cycle on the board is about
 * three minutes; this is a second.
 *
 * It is deliberately a *strict* card. It rejects a command whose start bits are
 * wrong, checks the CRC on CMD0 and CMD8 exactly as a real card does before CRC
 * is turned off, refuses to answer anything until it has seen its 74 clocks with
 * CS high, and stays in idle for a configurable number of ACMD41s. Every one of
 * those is a rule a real card enforces and a controller can accidentally depend
 * on not being enforced.
 *
 * It can also be told to go busy for a long time on demand, because that is the
 * failure mode real cards have and the one a controller model is most likely to
 * get wrong.
 */
module SdCardModel #(
    parameter IMAGE = "",                   // $readmemh file, one hex byte per line
    parameter integer BLOCKS = 8192,        // 4MB of model card
    parameter integer ACMD41_TRIES = 3,     // how long to stay in idle
    parameter integer WRITE_BUSY_BYTES = 4  // how long MISO is held low after a write
) (
    input wire clk,
    input wire cs_n,
    input wire mosi,
    output wire miso
);
    localparam integer BYTES = BLOCKS * 512;
    reg [7:0] mem [0:BYTES-1];

    reg [7:0] out_byte = 8'hff;
    reg [2:0] out_bit = 7;
    assign miso = cs_n ? 1'bz : out_byte[out_bit];

    reg [7:0] in_byte = 0;
    reg [3:0] in_count = 0;

    integer clocks_seen = 0;                // clocks received with CS high
    reg initialised = 0;                    // CMD0 accepted
    reg idle = 1;
    integer acmd41_seen = 0;
    reg app_cmd = 0;                        // the last command was CMD55

    // Command assembly
    reg [7:0] cmd [0:5];
    integer cmd_len = 0;
    reg in_command = 0;

    // What we are streaming back, if anything
    localparam [3:0] O_NONE = 0, O_R1 = 1, O_R3 = 2, O_R7 = 3,
                     O_READ = 4, O_WRITE = 5, O_WBUSY = 6;
    reg [3:0] out_mode = O_NONE;
    integer out_index = 0;
    reg [31:0] out_extra = 0;
    reg [31:0] cur_block = 0;

    integer failed_commands = 0;
    integer reads_done = 0, writes_done = 0;

    integer i;
    initial begin
        for (i = 0; i < BYTES; i = i + 1) mem[i] = 8'hff;
        if (IMAGE != "") $readmemh(IMAGE, mem);
    end

    // CRC7, which the card checks on CMD0 and CMD8 whatever else it ignores.
    function [7:0] crc7(input [39:0] data);
        integer b;
        reg [6:0] c;
        begin
            c = 0;
            for (b = 39; b >= 0; b = b - 1)
                c = { c[5:0], 1'b0 } ^ ((c[6] ^ data[b]) ? 7'h09 : 7'h00);
            crc7 = { c, 1'b1 };
        end
    endfunction

    task answer_r1;
        begin
            out_mode = O_R1;
            out_index = 0;
            out_byte = idle ? 8'h01 : 8'h00;
            out_bit = 7;
        end
    endtask

    // A byte has arrived on MOSI. Everything the card does is driven from here.
    task got_byte(input [7:0] b);
        begin
            if (out_mode == O_WRITE) begin
                // Streaming a block in: wait for the token, then 512 + 2 CRC.
                if (out_index == 0) begin
                    if (b == 8'hfe) out_index = 1;
                end else if (out_index <= 512) begin
                    mem[cur_block * 512 + out_index - 1] = b;
                    out_index = out_index + 1;
                end else if (out_index <= 514) begin
                    out_index = out_index + 1;
                end else begin
                    out_byte = 8'h05;            // data accepted
                    out_bit = 7;
                    out_mode = O_WBUSY;
                    out_index = 0;
                    writes_done = writes_done + 1;
                end
            end else if (b[7:6] == 2'b01 || in_command) begin
                if (!in_command) begin
                    in_command = 1;
                    cmd_len = 0;
                end
                cmd[cmd_len] = b;
                cmd_len = cmd_len + 1;
                if (cmd_len == 6) begin
                    in_command = 0;
                    run_command;
                end
            end
        end
    endtask

    task run_command;
        reg [5:0] index;
        reg [31:0] arg;
        reg [7:0] want;
        begin
            index = cmd[0][5:0];
            arg = { cmd[1], cmd[2], cmd[3], cmd[4] };
            want = crc7({ cmd[0], cmd[1], cmd[2], cmd[3], cmd[4] });
            if (clocks_seen < 74 && !initialised) begin
                // The card has not been given its power up clocks and simply
                // does not answer.
                failed_commands = failed_commands + 1;
                out_mode = O_NONE;
                out_byte = 8'hff;
            end else if (index == 0) begin
                if (cmd[5] !== want) begin
                    failed_commands = failed_commands + 1;
                    out_byte = 8'h09;            // CRC error, illegal command
                    out_bit = 7; out_mode = O_R1;
                end else begin
                    initialised = 1; idle = 1; acmd41_seen = 0;
                    answer_r1;
                end
            end else if (!initialised) begin
                failed_commands = failed_commands + 1;
                out_byte = 8'h05; out_bit = 7; out_mode = O_R1;
            end else if (index == 8) begin
                if (cmd[5] !== want) begin
                    failed_commands = failed_commands + 1;
                    out_byte = 8'h09; out_bit = 7; out_mode = O_R1;
                end else begin
                    // R7: R1 then the echoed voltage and check pattern.
                    out_mode = O_R7;
                    out_extra = { 16'h0000, 8'h01, arg[7:0] };
                    out_index = 0;
                    out_byte = 8'h01; out_bit = 7;
                end
            end else if (index == 55) begin
                app_cmd = 1;
                answer_r1;
            end else if (index == 41 && app_cmd) begin
                app_cmd = 0;
                acmd41_seen = acmd41_seen + 1;
                if (acmd41_seen > ACMD41_TRIES) idle = 0;
                answer_r1;
            end else if (index == 58) begin
                // R3: R1 then the OCR. Bit 30 set says this is a high capacity
                // card and takes block addresses; bit 31 says power up is done.
                out_mode = O_R3;
                out_extra = 32'hc0ff8000;
                out_index = 0;
                out_byte = idle ? 8'h01 : 8'h00; out_bit = 7;
            end else if (index == 17 && !idle) begin
                app_cmd = 0;
                if (arg >= BLOCKS) begin
                    failed_commands = failed_commands + 1;
                    out_byte = 8'h40; out_bit = 7; out_mode = O_R1;   // parameter error
                end else begin
                    cur_block = arg;
                    out_mode = O_READ;
                    out_index = 0;                 // 0 is the R1, then the token
                    out_byte = 8'h00; out_bit = 7;
                    reads_done = reads_done + 1;
                end
            end else if (index == 24 && !idle) begin
                app_cmd = 0;
                if (arg >= BLOCKS) begin
                    failed_commands = failed_commands + 1;
                    out_byte = 8'h40; out_bit = 7; out_mode = O_R1;
                end else begin
                    cur_block = arg;
                    out_mode = O_WRITE;
                    out_index = 0;
                    out_byte = 8'h00; out_bit = 7;
                end
            end else begin
                failed_commands = failed_commands + 1;
                out_byte = 8'h04; out_bit = 7; out_mode = O_R1;  // illegal command
            end
        end
    endtask

    // What goes out next, once the byte being shifted has finished.
    task next_out_byte;
        begin
            case (out_mode)
                O_R7, O_R3: begin
                    out_byte = out_extra[31:24];
                    out_extra = { out_extra[23:0], 8'hff };
                    out_index = out_index + 1;
                    if (out_index == 4) out_mode = O_NONE;
                end
                O_READ: begin
                    // A gap, then the data token, then the block and two CRC
                    // bytes. The gap is what a controller must not assume away.
                    if (out_index < 2) out_byte = 8'hff;
                    else if (out_index == 2) out_byte = 8'hfe;
                    else if (out_index < 515) out_byte = mem[cur_block * 512 + out_index - 3];
                    else if (out_index < 517) out_byte = 8'hff;
                    else begin out_byte = 8'hff; out_mode = O_NONE; end
                    out_index = out_index + 1;
                end
                O_WBUSY: begin
                    // MISO held low while the card writes.
                    out_index = out_index + 1;
                    if (out_index > WRITE_BUSY_BYTES) begin
                        out_byte = 8'hff;
                        out_mode = O_NONE;
                    end else out_byte = 8'h00;
                end
                default: out_byte = 8'hff;
            endcase
        end
    endtask

    always @(posedge clk) begin
        if (cs_n) clocks_seen = clocks_seen + 1;
        else begin
            in_byte = { in_byte[6:0], mosi };
            in_count = in_count + 1;
        end
    end

    always @(negedge clk) begin
        if (!cs_n) begin
            if (in_count == 8) begin
                in_count = 0;
                got_byte(in_byte);
                if (out_bit == 0) next_out_byte;
                out_bit = 7;
            end else out_bit = out_bit - 1;
        end
    end

    always @(posedge cs_n) begin
        in_count = 0;
        out_bit = 7;
        if (out_mode != O_WRITE) out_mode = O_NONE;
        out_byte = 8'hff;
    end
endmodule

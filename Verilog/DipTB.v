`timescale 1 ns/10 ps
// Stubs for the Gowin hard blocks so the real top level can be simulated. The PSRAM
// controller is not driven by anything, so its DDR buffers only need to elaborate.
`include "SimPrimitives.v"


`include "tangnano9k.v"
`include "HyperRamModel.v"
`include "SdCardModel.v"

/**
 * Boots diag on the real top level, waits for its prompt, types a test number over the
 * genuine serial link and prints what comes back.
 *
 * This is how the CPU-6 mapping RAM test was reproduced and then shown to pass. It is
 * not part of "make test" because it simulates hundreds of milliseconds of a 27MHz
 * board and takes minutes. Run it with "make diagtest", and change TEST to pick a
 * different entry from the menu.
 */

/**
 * Boots the real top level with a chosen Diag board DIP switch setting and prints
 * whatever the machine says. 0x1d is the auxiliary test menu, 0x1a is TOS - the
 * machine code monitor. Type characters by putting them in the KEYS string.
 */
module DipTB;
    parameter [7:0] DIP = 8'h1a;
    parameter [8*8:1] KEYS = "";
    parameter [3:0] SENSE = 4'b0001;
    // Milliseconds of simulated time to let the machine run after the last key.
    // Booting an operating system is not a prompt-and-answer affair: it wants
    // long enough to read what it needs off the disk and say something.
    parameter integer HOLD = 60;
    reg in_clk = 0;
    always #18.5185 in_clk = ~in_clk;
    reg reset_btn = 1, btn2 = 1;
    wire L1,L2,L3,L4,L5,L6,L7,L8;
    wire uart_tx;
    reg  uart_rx = 1;

    // The embedded HyperRAM. It is the full 23 bits now, not the CPU's 18: the
    // disk image lives above the machine's own memory.
    wire [1:0] psram_ck, psram_ck_n, psram_cs_n, psram_reset_n;
    wire [1:0] psram_rwds;
    wire [15:0] psram_dq;
    HyperRamModel #(.ADDR_BITS(23)) die(
        .ck(psram_ck[0]), .cs_n(psram_cs_n[0]), .resetn(psram_reset_n[0]),
        .rwds(psram_rwds[0]), .dq(psram_dq[7:0]));

    // The microSD slot with a card in it. +sd= chooses the volume; the default
    // has a synthetic image, and a real Centurion pack can be dropped in with
    // "make hawk" in MakeSdImage.py.
    wire sd_clk, sd_mosi, sd_cs_n;
    wire sd_miso;
    pullup(sd_miso);
    SdCardModel #(.BLOCKS(133120), .FILL(8'h00)) sdcard(sd_clk, sd_cs_n, sd_mosi, sd_miso);
    reg [8*64:1] sd_image;
    initial begin
        if (!$value$plusargs("sd=%s", sd_image)) sd_image = "sd_fat32.hex";
        #1 $readmemh(sd_image, sdcard.mem);
    end

    tangnano9k #(.DIAG_DIP_SWITCHES(DIP), .SENSE_SWITCHES(SENSE)) dut(in_clk, reset_btn, btn2,
                                              L1,L2,L3,L4,L5,L6,L7,L8, uart_tx, uart_rx,
                                              psram_ck, psram_ck_n, psram_cs_n,
                                              psram_reset_n, psram_rwds, psram_dq,
                                              sd_clk, sd_mosi, sd_miso, sd_cs_n);
    defparam dut.cpu_clock_enable.TICKS = 13;

    // +pctrace: every instruction fetch. Booting is a short sequence that either
    // reaches the loaded code or does not, and the serial line says nothing about
    // which.
    always @(posedge in_clk) if ($test$plusargs("pctrace"))
        if (dut.instruction_fetch) $display("pc %h", dut.pc_live0);

    localparam BITP = 27_000_000/19200 + 1;
    integer i;
    reg [7:0] ch;
    integer n = 0;
    initial begin
        forever begin
            @(negedge uart_tx);
            repeat (BITP + BITP/2) @(posedge in_clk);
            ch = 0;
            for (i = 0; i < 7; i = i + 1) begin
                ch[i] = uart_tx;
                repeat (BITP) @(posedge in_clk);
            end
            n = n + 1;
            if (ch >= 32 && ch < 127) $write("%c", ch);
            else if (ch == 13) $write("\n");
            else if (ch != 10) $write(".");
            $fflush;
        end
    end

    task send(input [7:0] b);
        begin
            uart_rx = 0;
            repeat (BITP) @(posedge in_clk);
            for (i = 0; i < 7; i = i + 1) begin
                uart_rx = b[i];
                repeat (BITP) @(posedge in_clk);
            end
            uart_rx = 1;
            repeat (BITP*2) @(posedge in_clk);
        end
    endtask

    integer k;
    initial begin
        $display("--- DIP switches = %02x ---", DIP);
        #0 reset_btn = 1; #100000 reset_btn = 0; #200000 reset_btn = 1;
        repeat (120) #1000000;
        for (k = 8; k >= 1; k = k - 1) begin
            if (KEYS[k*8 -: 8] != 0) begin
                $display("\n--- typing %c ---", KEYS[k*8 -: 8]);
                send(KEYS[k*8 -: 8]);
                repeat (HOLD) #1000000;
            end
        end
        repeat (HOLD) #1000000;
        $display("\n--- %0d characters ---", n);
        $display("--- hawk: sector %04h, status %02h; image: %0d fetches, %0d hits ---",
                 dut.hawk.sector_addr, dut.hawk.data_out,
                 dut.image.dbg_fetches, dut.image.dbg_hits);
        $display("--- hex display %02x, points %b, blank %b ---",
                 dut.diag_hex, dut.diag_points, dut.diag_blank);
        $finish;
    end
endmodule

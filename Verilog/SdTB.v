`timescale 1 ns/10 ps
`include "SdSpi.v"
`include "SdCardModel.v"

/**
 * The SD layer on its own, with no CPU and no bus.
 *
 * This project's own rule, learned twice over on the PSRAM: prove a storage
 * layer standalone before wiring it to anything, because when it is on the bus
 * every failure looks like every other failure. The card model here is
 * deliberately strict - it refuses commands before its power up clocks, checks
 * the CRC on CMD0 and CMD8, and stays in idle for several ACMD41s - so passing
 * this means the initialisation sequence is right, not merely tolerated.
 *
 * "make sdtest"
 */
module SdTB;
    reg clock = 0;
    always #18.5185 clock = ~clock;         // 27MHz
    reg reset = 1;

    wire sd_clk, sd_mosi, sd_cs_n;
    wire sd_miso;
    pullup(sd_miso);                        // the card releases MISO with CS high

    reg do_read = 0, do_write = 0;
    reg [31:0] block_no = 0;
    wire busy, ready, error;
    wire rx_strobe, tx_request;
    wire [8:0] rx_index, tx_index;
    wire [7:0] rx_byte;
    wire [7:0] dbg_state, dbg_r1;
    wire dbg_block_addressing;

    reg [7:0] buffer [0:511];
    reg [7:0] tx_buffer [0:511];
    wire [7:0] tx_byte = tx_buffer[tx_index];

    // Initialisation is a whole second of card time at worst, and the model
    // makes us ask several times, so keep the timeout generous but bounded.
    SdSpi #(.INIT_TIMEOUT(27_000_000)) sd(
        clock, reset, sd_clk, sd_mosi, sd_miso, sd_cs_n,
        do_read, do_write, block_no, busy, ready, error,
        rx_strobe, rx_index, rx_byte, tx_request, tx_index, tx_byte,
        dbg_state, dbg_r1, dbg_block_addressing);

    SdCardModel #(.IMAGE("sd_pattern.hex"), .BLOCKS(64)) card(
        sd_clk, sd_cs_n, sd_mosi, sd_miso);

    always @(posedge clock) if (rx_strobe) buffer[rx_index] <= rx_byte;

    integer failures = 0;
    integer i, wrong;
    integer countdown;

    task read_block(input [31:0] n);
        begin
            @(posedge clock);
            block_no = n;
            do_read = 1;
            @(posedge clock);
            while (!busy) @(posedge clock);
            do_read = 0;
            while (busy) @(posedge clock);
        end
    endtask

    task write_block(input [31:0] n);
        begin
            @(posedge clock);
            block_no = n;
            do_write = 1;
            @(posedge clock);
            while (!busy) @(posedge clock);
            do_write = 0;
            while (busy) @(posedge clock);
        end
    endtask

    task expect_block(input [31:0] n, input [1023:0] what);
        begin
            wrong = 0;
            for (i = 0; i < 512; i = i + 1)
                if (buffer[i] !== card.mem[n*512 + i]) begin
                    if (wrong < 3)
                        $display("FAIL: block %0d byte %0d read %h, card holds %h",
                                 n, i, buffer[i], card.mem[n*512 + i]);
                    wrong = wrong + 1;
                end
            if (wrong == 0) $display("ok: %0s", what);
            else begin
                $display("FAIL: %0d of 512 bytes wrong reading block %0d", wrong, n);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        repeat (20) @(posedge clock);
        reset = 0;

        // Initialisation. The model refuses everything until it has had its 74
        // clocks and stays in idle for three ACMD41s, so this really is the
        // sequence and not a card being forgiving.
        countdown = 2_000_000;
        while (!ready && countdown != 0) begin
            @(posedge clock);
            countdown = countdown - 1;
        end
        if (!ready) begin
            $display("FAIL: the card never became ready, stuck in state %0d (r1=%h)",
                     dbg_state, dbg_r1);
            $finish;
        end
        $display("ok: the card initialised (r1=%h, %0s addressing)",
                 dbg_r1, dbg_block_addressing ? "block" : "byte");

        if (card.failed_commands != 0) begin
            $display("FAIL: the card rejected %0d commands during initialisation",
                     card.failed_commands);
            failures = failures + 1;
        end else
            $display("ok: the card rejected nothing - CRCs and ordering are right");

        read_block(0);
        if (error) begin $display("FAIL: reading block 0 reported an error"); failures = failures + 1; end
        expect_block(0, "block 0 read back exactly");
        if (buffer[0] !== 8'h53 || buffer[1] !== 8'h44) begin
            $display("FAIL: block 0 starts %h %h, not the image's 53 44", buffer[0], buffer[1]);
            failures = failures + 1;
        end

        // A different block, to catch an address that is ignored or shifted.
        read_block(17);
        expect_block(17, "block 17 read back exactly, so the address is used");

        // And a block that is all zeros, which catches a stale buffer.
        read_block(1);
        expect_block(1, "block 1, all zeros, did not come back as the last block");

        // Write and read back.
        for (i = 0; i < 512; i = i + 1) tx_buffer[i] = (i * 3 + 11) & 8'hff;
        write_block(9);
        if (error) begin $display("FAIL: writing block 9 reported an error"); failures = failures + 1; end
        wrong = 0;
        for (i = 0; i < 512; i = i + 1)
            if (card.mem[9*512 + i] !== tx_buffer[i]) wrong = wrong + 1;
        if (wrong == 0) $display("ok: 512 bytes written and the card holds them");
        else begin
            $display("FAIL: %0d of 512 written bytes wrong on the card", wrong);
            failures = failures + 1;
        end
        read_block(9);
        expect_block(9, "the written block read back the same way");

        $display("card: %0d reads, %0d writes, %0d commands rejected",
                 card.reads_done, card.writes_done, card.failed_commands);
        if (failures == 0) $display("ok: the SD layer initialises, reads and writes");
        else $display("FAIL: %0d checks failed", failures);
        $finish;
    end

    initial begin
        #500_000_000;
        $display("FAIL: the SD test did not finish; state %0d r1 %h", dbg_state, dbg_r1);
        $finish;
    end
endmodule

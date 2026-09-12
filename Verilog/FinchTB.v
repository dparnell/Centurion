/**
 * The Finch card's mailbox, against the exact byte sequence the operating
 * system performs during startup.
 *
 * That sequence was measured in Meisaka's emulator, which boots CENTOS: the
 * fourteen reads and two writes below are the whole of the traffic to the card
 * before the console prompt appears. Replaying it here is the only check that
 * means anything, because the card behind the mailbox is not modelled - so the
 * question is not "does the controller work" but "does this answer the host
 * exactly as the reference's does".
 */
`timescale 1 ns/10 ps
`include "FinchCard.v"

module FinchTB;
    reg clock = 0;
    always #18.5185 clock = ~clock;

    reg enable = 0, reset = 1, selected = 0, address = 0, write_en = 0;
    reg read_strobe = 0;
    reg [7:0] data_in = 0;
    wire [7:0] data_out;

    FinchCard card(clock, enable, reset, selected, address, write_en,
                   read_strobe, data_in, data_out);

    integer failures = 0, step = 0;

    task rd(input a, input [7:0] expected);
        begin
            step = step + 1;
            selected = 1; address = a; write_en = 0; read_strobe = 1; enable = 1;
            #1;
            if (data_out !== expected) begin
                $display("FAIL step %0d: R%0d read %02x, the reference reads %02x",
                         step, a, data_out, expected);
                failures = failures + 1;
            end
            @(posedge clock); #1;
            selected = 0; read_strobe = 0; enable = 0; @(posedge clock); #1;
        end
    endtask

    task wr(input a, input [7:0] d);
        begin
            step = step + 1;
            selected = 1; address = a; write_en = 1; data_in = d; enable = 1;
            @(posedge clock); #1;
            selected = 0; write_en = 0; enable = 0; @(posedge clock); #1;
        end
    endtask

    initial begin
        #200; reset = 0; @(posedge clock); #1;

        // The reference's sequence, in order. R0 is the data register and R1 the
        // status; status bit 0 is "the card has a byte for you" and bit 3 is busy.
        rd(0, 8'h00);                    // R0=>00 @295d
        rd(1, 8'h00);                    // R1=>00 @2b79
        rd(1, 8'h00);                    // R1=>00
        wr(0, 8'hff);                    // W0=ff @2b2f   identify
        rd(1, 8'h01);                    // R1=>01        a reply is waiting
        rd(1, 8'h01);
        rd(1, 8'h01);                    // R1=>01 @2b55
        rd(0, 8'h12);                    // R0=>12 @2b43  the reply
        rd(1, 8'h00);                    // R1=>00        nothing waiting now
        rd(1, 8'h00);
        wr(0, 8'h52);                    // W0=52 @2b2f   status
        rd(1, 8'h09);                    // R1=>09        busy, and a reply waiting
        rd(1, 8'h09);                    // R1=>09 @2b55
        rd(0, 8'hb0);                    // R0=>b0 @297c  first reply byte
        rd(1, 8'h01);                    // R1=>01        second still waiting
        rd(0, 8'h00);                    // R0=>00 @2985  second reply byte
        rd(1, 8'h00);                    // and the card is idle again

        // Writing the status register resets the card, so a reply in flight is
        // dropped rather than delivered to whoever asks next.
        wr(0, 8'hff); wr(1, 8'h00); rd(1, 8'h00);

        // A command for the medium is answered with silence, not an invention.
        wr(0, 8'h01); rd(1, 8'h00);

        if (failures == 0)
            $display("ok: the Finch mailbox answers the operating system's startup handshake byte for byte");
        else
            $display("FAIL: %0d of the card's answers differ from the reference", failures);
        $finish;
    end
endmodule

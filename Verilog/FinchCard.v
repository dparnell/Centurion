/**
 * The Finch floppy controller's host interface, at physical 0x3f800.
 *
 * WHAT THIS IS AND IS NOT. The real board is an intelligent controller with its
 * own processor: the CPU hands it command bytes through a two register mailbox
 * and reads replies back the same way, and everything about the medium - the
 * sector format, the CRC, the servo timing - happens on the far side of that
 * mailbox. The mailbox is modelled here exactly, from Meisaka's emulator:
 *
 *     read  offset 0   the data register, and taking the byte clears card_to_cpu
 *     read  offset 1   status: bit 3 busy, bit 2 flag2,
 *                              bit 1 cpu_to_card, bit 0 card_to_cpu
 *     write offset 0   the data register, which sets cpu_to_card
 *     write offset 1   reset the card
 *
 * The card behind it is NOT modelled. What is here answers the identify
 * handshake the operating system performs during startup and nothing else,
 * because the reference implements the real card at bit level - its own
 * sequencer, ALU, CRC generator and track format - and this project has no
 * specification for the firmware that would make a faithful version possible.
 *
 * That handshake is the whole of the traffic to reach the console prompt,
 * measured in the reference: fourteen reads and two writes. The CPU writes 0xff
 * and the card answers 0x12; the CPU writes 0x52 and the card answers 0xb0 then
 * 0x00. Until that conversation completes the operating system sits in a wait
 * at 0x2b52 forever, because a Finch is in the configuration on the pack.
 *
 * So: a real mailbox with a canned correspondent. Anything that asks this card
 * to touch a medium will not get an answer, and the day a Finch image is wanted
 * this file is where the controller goes.
 */
module FinchCard(
    input wire clock,
    input wire enable,              // one pulse per CPU clock
    input wire reset,
    input wire selected,
    input wire address,             // offset 0 or 1 within the card
    input wire write_en,
    // A read of the data register takes the byte, so it needs the same genuine
    // read strobe the MUX does: this bus has no read strobe of its own and a
    // cycle that merely leaves the address here is not a read.
    input wire read_strobe,
    input wire [7:0] data_in,
    output reg [7:0] data_out
);

    reg [7:0] sys_data;
    reg busy, flag2, cpu_to_card, card_to_cpu;
    // The second byte of a two byte reply. One is all the identify handshake
    // needs; a real controller would be computing these rather than holding them.
    reg [7:0] reply1;
    reg reply_pending;

    wire real_read    = enable & selected & ~write_en & read_strobe;
    wire read_data    = real_read & (address == 1'b0);
    wire write_strobe = enable & selected & write_en;
    wire identify     = write_strobe & ~address & (data_in == 8'hff);
    wire status_cmd   = write_strobe & ~address & (data_in == 8'h52);

    always @(*) begin
        data_out = 8'h00;
        if (selected && !write_en)
            data_out = address ? { 4'b0000, busy, flag2, cpu_to_card, card_to_cpu }
                               : sys_data;
    end

    always @(posedge clock) begin
        if (reset) begin
            sys_data <= 0; busy <= 0; flag2 <= 0;
            cpu_to_card <= 0; card_to_cpu <= 0;
            reply1 <= 0; reply_pending <= 0;
        end else if (write_strobe && address) begin
            // Writing the status register resets the card.
            sys_data <= 0; busy <= 0; flag2 <= 0;
            cpu_to_card <= 0; card_to_cpu <= 0; reply_pending <= 0;
        end else if (write_strobe) begin
            // A command byte. This card answers at once, which is the one place
            // it differs from a real controller - there the reply arrives after
            // the card has done some work, and the operating system's wait loop
            // is written for that. Answering immediately is simply the fastest
            // card that protocol allows, so the wait is satisfied rather than
            // skipped.
            cpu_to_card <= 0;                   // taken
            if (identify) begin
                sys_data <= 8'h12; card_to_cpu <= 1; reply_pending <= 0; busy <= 0;
            end else if (status_cmd) begin
                sys_data <= 8'hb0; reply1 <= 8'h00;
                card_to_cpu <= 1; reply_pending <= 1; busy <= 1;
            end else begin
                // Anything else is a command for the medium, which is not here.
                // Say so by answering nothing rather than by inventing a reply.
                sys_data <= data_in; card_to_cpu <= 0; reply_pending <= 0; busy <= 0;
            end
        end else if (read_data) begin
            if (reply_pending) begin
                sys_data <= reply1;             // a second byte is still owed
                reply_pending <= 0;
                busy <= 0;
            end else
                card_to_cpu <= 0;               // that was the last of it
        end
    end
endmodule

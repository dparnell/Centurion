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
    // Milliseconds between one key and the next. HOLD is how long to watch the
    // machine after the last of them, and using it between keys too makes a long
    // run unusable: booting an operating system wants seconds of simulated time
    // at the end and a few milliseconds between the two characters of "H1",
    // and waiting the first between them costs hours for nothing.
    parameter integer GAP = 20;
    // The diag board's ROMs shadow 8K the operating system loads code into, so
    // booting it needs them out. See BoardMemory.v.
    parameter DIAG_ROM = 1;
    parameter integer TICKS = 13;
    parameter [7:0] PSRAM_FILL = 8'hff;
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
    // PSRAM_FILL makes the experiment above runnable: 00 matches the reference
    // emulator's zeroed memory, ff is what a real part looks like out of reset.
    HyperRamModel #(.ADDR_BITS(23), .FILL(PSRAM_FILL)) die(
        .ck(psram_ck[0]), .cs_n(psram_cs_n[0]), .resetn(psram_reset_n[0]),
        .rwds(psram_rwds[0]), .dq(psram_dq[7:0]));

    // The microSD slot with a card in it. +sd= chooses the volume; the default
    // has a synthetic image, and a real Centurion pack can be dropped in with
    // "make hawk" in MakeSdImage.py.
    wire sd_clk, sd_mosi, sd_cs_n;
    wire sd_miso;
    pullup(sd_miso);
    SdCardModel #(.BLOCKS(133120), .FILL(8'h00)) sdcard(sd_clk, sd_cs_n, sd_mosi, sd_miso);
    // Declared up here rather than beside the trace that maintains it: several
    // instruments below want the disk command count to line their output up
    // against the reference, and iverilog will not take a declaration after use.
    integer hawk_cmds = 0;
    reg [8*64:1] sd_image;
    initial begin
        if (!$value$plusargs("sd=%s", sd_image)) sd_image = "sd_fat32.hex";
        #1 $readmemh(sd_image, sdcard.mem);
    end

    tangnano9k #(.DIAG_DIP_SWITCHES(DIP), .SENSE_SWITCHES(SENSE),
                 .DIAG_ROM(DIAG_ROM)) dut(in_clk, reset_btn, btn2,
                                              L1,L2,L3,L4,L5,L6,L7,L8, uart_tx, uart_rx,
                                              psram_ck, psram_ck_n, psram_cs_n,
                                              psram_reset_n, psram_rwds, psram_dq,
                                              sd_clk, sd_mosi, sd_miso, sd_cs_n);
    // The core's speed. 13 runs it at about 13MHz instead of the real 5, which
    // is a 2.6x different ratio between the CPU and everything it waits for -
    // the disk, the memory, the serial line. That is fine for reproducing
    // something quickly and wrong for reproducing a race, so TICKS=5 when the
    // question is why the hardware behaves differently from the simulation.
    defparam dut.cpu_clock_enable.TICKS = TICKS;

    // +bustrace: every bus address the machine touches while the PC is in the
    // disk wait routine. "It is polling a status register" is only half an
    // answer; which register is the other half, and the base is in Z where
    // nothing outside the core can see it.
    reg [15:0] seen_pc = 0;
    always @(posedge in_clk) if ($test$plusargs("bustrace")) begin
        if (dut.instruction_fetch) seen_pc <= dut.pc_live0;
        if (dut.cpu_en && dut.addressBus[18:4] == 15'h3f14)
            $display("hawk %01x %s %02x  busy=%b seeking=%b seek_done=%b busy_time=%0d",
                     dut.addressBus[3:0], dut.writeEnBus ? "<=" : "=>",
                     dut.writeEnBus ? dut.data_c2r : dut.hawk_data,
                     dut.hawk.busy, dut.hawk.seeking, dut.hawk.seek_done,
                     dut.hawk.busy_time);
        if (dut.cpu_en && dut.addressBus[18:4] == 15'h3f14)
            $display("     hawk: waiting=%b transferring=%b dma_req=%b bytes_left=%0d cmd=%0d | f11=%02h dma_on=%b",
                     dut.hawk.waiting, dut.hawk.transferring, dut.hawk_req,
                     dut.hawk.bytes_left, dut.hawk.command,
                     dut.cpu.f11, dut.cpu.dma_on);
    end

    // The write-tracked page bit, counted. The operating system installs a map
    // and then stores into it, and the reference traps to level 15 on that
    // store - so either the bit is never set in the table, or it is set and the
    // microcode never branches on it. These three counters tell the two apart
    // without a trace of any kind.
    integer pt_writes = 0, pt_writes_bit7 = 0, pt_read_bit7 = 0;
    always @(posedge in_clk) if (dut.cpu_en) begin
        if (dut.cpu.k11 == 3'd5) begin
            pt_writes = pt_writes + 1;
            if (dut.cpu.result_register[7]) pt_writes_bit7 = pt_writes_bit7 + 1;
            // Only 134 of these happen in a whole boot, so log them all rather
            // than counting. The reference ends up with exactly one entry
            // carrying the write-tracked bit - map 0 entry 31, value 0x81 - and
            // this design ends up with none, so the question is what it writes
            // to entry 31 instead and where that value comes from.
            if ($test$plusargs("pttrace"))
                $display("PT [%0d] (base %0d page %0d) <= %02h   at pc=%04h uc=%03h dp=%0d",
                         dut.cpu.page_address, dut.cpu.page_table_base,
                         dut.cpu.page_address[4:0], dut.cpu.result_register,
                         dut.pc_live0, dut.dbg_uc_address, dut.cpu.d2d3);
        end
        if (dut.cpu.page_table_out[7]) pt_read_bit7 = pt_read_bit7 + 1;
    end

    // +leveltrace: every change of the CPU's interrupt level, with enough state
    // to say what caused it. A trap is invisible from everything else: the
    // fetch trail just shows control arriving somewhere unexpected, and if the
    // level being trapped to has a zero P register - which level 15 does, since
    // nothing has ever set it - that somewhere is 0x0000 and the machine then
    // executes the register file.
    // Where does the disk data actually land? A histogram of DMA write
    // destinations by 2K physical page. The sector reads all match the
    // reference's, so the bytes are being fetched; if they are not reaching
    // 0x0cf00 then either the destination address is wrong or they are going
    // somewhere else entirely, and this says which.
    integer dma_page [0:127];
    integer dpi, dma_writes = 0;
    initial for (dpi = 0; dpi < 128; dpi = dpi + 1) dma_page[dpi] = 0;
    always @(posedge in_clk)
        if (dut.cpu_en && dut.writeEnBus && dut.cpu.dma_on) begin
            dma_page[dut.addressBus[17:11]] = dma_page[dut.addressBus[17:11]] + 1;
            dma_writes = dma_writes + 1;
        end

    // The same census for the CPU's own writes. The sector data lands in a
    // staging buffer at 0x0e800 and something must copy it to where the code
    // is supposed to live; if that copy is running but landing elsewhere, this
    // says where. Split by whether the write came from the MVF block copy at
    // 0xef2a or from anywhere else.
    integer cpu_page [0:127];
    integer mvf_page [0:127];
    integer cpi, cpu_writes = 0, mvf_writes = 0;
    initial for (cpi = 0; cpi < 128; cpi = cpi + 1) begin
        cpu_page[cpi] = 0; mvf_page[cpi] = 0;
    end
    always @(posedge in_clk)
        if (dut.cpu_en && dut.writeEnBus && !dut.cpu.dma_on) begin
            cpu_page[dut.addressBus[17:11]] = cpu_page[dut.addressBus[17:11]] + 1;
            cpu_writes = cpu_writes + 1;
            if (dut.pc_live0 == 16'hef2a) begin
                mvf_page[dut.addressBus[17:11]] = mvf_page[dut.addressBus[17:11]] + 1;
                mvf_writes = mvf_writes + 1;
            end
        end

    // The sixteen bytes the machine actually trapped on. The earlier per-address
    // log was capped at forty entries, so "nothing writes here" was not yet
    // established - this counts them with no cap, and records the highest
    // address the block copy reaches in that page, which says whether the copy
    // is short or aimed somewhere else.
    integer cf40_writes = 0;
    reg [18:0] mvf_lo_c8 = 19'h7ffff, mvf_hi_c8 = 0;
    always @(posedge in_clk)
        if (dut.cpu_en && dut.writeEnBus) begin
            if (dut.addressBus >= 19'h0cf40 && dut.addressBus <= 19'h0cf4f)
                cf40_writes = cf40_writes + 1;
            if (dut.addressBus[18:11] == 8'h19) begin
                if (dut.addressBus < mvf_lo_c8) mvf_lo_c8 = dut.addressBus;
                if (dut.addressBus > mvf_hi_c8) mvf_hi_c8 = dut.addressBus;
            end
        end

    // Each MVF copy as a range rather than as bytes: where it started, where it
    // ended and how many bytes it moved, with the disk command count so it lines
    // up against the reference. The reference writes 0x0cf40 during the copies
    // at commands 155 and 157; this design's copies cover the page all around
    // those bytes and never on them, so comparing the ranges says whether a copy
    // is missing, short, or aimed somewhere else.
    reg [18:0] run_lo = 0, run_last = 0;
    integer run_n = 0, run_printed = 0;
    reg in_run = 0;
    always @(posedge in_clk) begin
        if (dut.cpu_en && dut.writeEnBus && dut.pc_live0 == 16'hef2a) begin
            if (in_run && dut.addressBus == run_last + 1) begin
                run_last <= dut.addressBus; run_n = run_n + 1;
            end else begin
                if (in_run && run_printed < 300 && hawk_cmds >= 140) begin
                    run_printed = run_printed + 1;
                    $display("MVF %05h..%05h  %0d bytes  (%0d disk commands)",
                             run_lo, run_last, run_n, hawk_cmds);
                end
                run_lo <= dut.addressBus; run_last <= dut.addressBus; run_n = 1;
                in_run <= 1;
            end
        end
    end

    // How far across the staging page the DMA actually writes. The reference
    // reads list records at 0x0ed55, 0x0edd2, 0x0ee4f and 0x0eecc, so its
    // staging area spans most of the page; if this design's sector writes only
    // ever cover the first 400 bytes then every read is landing on top of the
    // last one and the destination is not advancing.
    reg [18:0] dma_lo_e8 = 19'h7ffff, dma_hi_e8 = 0;
    integer dma_e8 = 0;
    always @(posedge in_clk)
        if (dut.cpu_en && dut.writeEnBus && dut.cpu.dma_on &&
            dut.addressBus[18:11] == 8'h1d) begin
            dma_e8 = dma_e8 + 1;
            if (dut.addressBus < dma_lo_e8) dma_lo_e8 = dut.addressBus;
            if (dut.addressBus > dma_hi_e8) dma_hi_e8 = dut.addressBus;
        end

    // Every access to the one byte the walk reads wrongly, writes and reads
    // alike, in order. It sits inside the DMA's span so it is written at some
    // point; reading ff from it means either the write had not happened yet or
    // the read did not see it - a posted write buffer or a stale cache line -
    // and the ordering here tells the two apart.
    integer e55_n = 0;
    always @(posedge in_clk)
        if ($test$plusargs("e55") && dut.cpu_en && dut.addressBus == 19'h0ed55 &&
            e55_n < 60) begin
            if (dut.writeEnBus) begin
                e55_n = e55_n + 1;
                $display("E55 WRITE <= %02h  (%0d disk commands) dma_on=%b",
                         dut.data_c2r, hawk_cmds, dut.cpu.dma_on);
            end else if (dut.bus_read_strobe) begin
                e55_n = e55_n + 1;
                $display("E55 READ  => %02h  (%0d disk commands) pc=%04h",
                         dut.data_r2c, hawk_cmds, dut.pc_live0);
            end
        end

    // Per read command: did the image layer actually fetch the block from the
    // card, or did it report a cache hit? A hit on a block that was never
    // fetched hands back uninitialised PSRAM, which reads 0xff - and 0xff is
    // exactly what the failing sectors deliver, where the image file holds 00.
    integer prev_fetch = 0, prev_hit = 0, ic_n = 0;
    always @(posedge in_clk)
        if ($test$plusargs("imgcache") && dut.cpu_en && dut.writeEnBus &&
            dut.addressBus == 19'h3f148 && dut.data_c2r[2:0] == 3'd0 &&
            hawk_cmds >= 148 && ic_n < 30) begin
            ic_n = ic_n + 1;
            $display("IMG read sector %04h at cmd %0d: fetches=%0d (+%0d) hits=%0d (+%0d)",
                     dut.hawk.sector_addr, hawk_cmds,
                     dut.image.dbg_fetches, dut.image.dbg_fetches - prev_fetch,
                     dut.image.dbg_hits, dut.image.dbg_hits - prev_hit);
            prev_fetch = dut.image.dbg_fetches;
            prev_hit = dut.image.dbg_hits;
        end

    // Each DMA transfer as a destination range. The staging area is two 400 byte
    // buffers at 0x0ebc5 and 0x0ed55, and the list walk reads a flag byte from
    // the second one; if this design's transfers are a different length, or land
    // in the other buffer, the walk reads the wrong sector's record. That is the
    // surviving explanation for reading ff where the image holds 00.
    reg [18:0] dr_lo = 0, dr_last = 0;
    integer dr_n = 0, dr_printed = 0;
    reg dr_in = 0;
    always @(posedge in_clk) begin
        if (dut.cpu_en && dut.writeEnBus && dut.cpu.dma_on) begin
            if (dr_in && dut.addressBus == dr_last + 1) begin
                dr_last <= dut.addressBus; dr_n = dr_n + 1;
            end else begin
                if (dr_in && dr_printed < 40 && hawk_cmds >= 146) begin
                    dr_printed = dr_printed + 1;
                    $display("DMAXFER %05h..%05h  %0d bytes  (sector %04h, %0d disk commands)",
                             dr_lo, dr_last, dr_n, dut.hawk.sector_addr, hawk_cmds);
                end
                dr_lo <= dut.addressBus; dr_last <= dut.addressBus; dr_n = 1;
                dr_in <= 1;
            end
        end
    end

    // The first bytes of one sector's DMA, against what the image file holds.
    // Sector 0x4b8 begins 00 15 ce 9e 7b 06 91 01 in CENTOS_13.IMG. If this
    // design writes ff followed by those bytes, the transfer is shifted by one
    // and the first byte is a stale buffer output - the same one-clock block RAM
    // mistake that produced three bugs in DiskImage.
    integer fb_n = 0;
    always @(posedge in_clk)
        if (dut.cpu_en && dut.writeEnBus && dut.cpu.dma_on &&
            dut.hawk.sector_addr == 16'h04b8 && fb_n < 10) begin
            fb_n = fb_n + 1;
            $display("SECBYTE %0d: %05h <= %02h  (buf_index=%0d)",
                     fb_n - 1, dut.addressBus, dut.data_c2r, dut.hawk.buf_index);
        end

    // And a count of writes anywhere in the 0x0c000 page, so "nothing writes the
    // page at all" is told apart from "the page is written but not this part".
    integer page_c_writes = 0;
    always @(posedge in_clk)
        if (dut.cpu_en && dut.writeEnBus && dut.addressBus[18:12] == 7'h0c)
            page_c_writes = page_c_writes + 1;

    // The last 32 microcode words before the first level change. The fetch trail
    // says which instruction was running; this says which microcode path got
    // into the entry sequence, and the conditional branch that chose it. That
    // is the question here, because the reference takes no level change at this
    // point in the boot at all.
    reg [10:0] uc_ring [0:255];
    reg [7:0] uc_head = 0;
    integer ui;
    initial for (ui = 0; ui < 256; ui = ui + 1) uc_ring[ui] = 11'h7ff;
    always @(posedge in_clk) if (dut.cpu_en) begin
        uc_ring[uc_head] <= dut.dbg_uc_address;
        uc_head <= uc_head + 1;
    end
    reg uc_shown = 0;

    // The comparison can only notice the change on the cycle AFTER it, so the
    // signals that caused it have to be delayed by one too - otherwise the
    // trace shows e6 = 0 for a load that only happens at e6 == 3, and an F bus
    // that does not contain the level that was loaded.
    reg [3:0] lvl_prev = 0;
    reg [2:0] p_e6, p_d2d3_hi;
    reg [3:0] p_d2d3;
    reg [7:0] p_dp, p_f1, p_f0;
    reg [10:0] p_uc;
    reg [15:0] p_pc;
    always @(posedge in_clk) if (dut.cpu_en) begin
        p_e6 <= dut.cpu.e6; p_d2d3 <= dut.cpu.d2d3; p_dp <= dut.cpu.DPBus;
        p_f1 <= dut.cpu.alu1_yout; p_f0 <= dut.cpu.alu0_yout;
        p_uc <= dut.dbg_uc_address; p_pc <= dut.pc_live0;
        lvl_prev <= dut.cpu.interrupt_level;
        if (dut.cpu.interrupt_level !== lvl_prev && $test$plusargs("leveltrace")) begin
            // The level is loaded from the F bus at e6 == 3, and the F bus
            // comes from whichever DP source d2d3 names - so d2d3, the DP bus
            // and the F bus together say where the new level came from, which
            // the level number alone does not. dma_req matters because k9 == 7,
            // "anything wants attention", ORs it in without gating it on the
            // interrupt enable, so a DMA request can start the entry path on a
            // machine whose interrupts are off.
            $display("LEVEL %0d -> %0d at pc=%04h uc=%03h mar=%04h | d2d3=%0d dp=%02h f=%02h%02h e6=%0d | e7=%0d k13=%0d k9en=%b k9=%0d | f11=%02h dma_req=%b int_reqn=%b entry=%02h",
                     lvl_prev, dut.cpu.interrupt_level, p_pc,
                     p_uc, dut.cpu.dbg_memory_address,
                     p_d2d3, p_dp, p_f1, p_f0, p_e6,
                     dut.cpu.e7, dut.cpu.k13, dut.cpu.k9_enable, dut.cpu.k9,
                     dut.cpu.f11, dut.cpu.dma_req, dut.int_reqn,
                     dut.cpu.page_table_out);
            if (!uc_shown) begin
                uc_shown <= 1;
                // What the machine actually has at the instruction it trapped on.
            // The reference has 0x32 there - CLR - and this design's microcode
            // entered at 0x18b, the dispatcher for 00/0f/2e/2f, so the opcode
            // byte it fetched is not the one that should be there. Physical
            // 0x0cf46 lives in the board's own RAM block, not the PSRAM.
            $display("     writes into physical 0x0c000-0x0cfff so far: %0d", page_c_writes);
            $display("     writes into 0x0cf40-0x0cf4f: %0d   |  writes in page 0x0c800 span %05h to %05h",
                     cf40_writes, mvf_lo_c8, mvf_hi_c8);
            $display("     %0d DMA writes into the staging page span %05h to %05h",
                     dma_e8, dma_lo_e8, dma_hi_e8);
            $write("     %0d CPU writes, by 2K physical page:", cpu_writes);
            for (dpi = 0; dpi < 128; dpi = dpi + 1)
                if (cpu_page[dpi] != 0) $write(" %05h:%0d", dpi * 2048, cpu_page[dpi]);
            $write("\n     %0d of them from the MVF copy at 0xef2a:", mvf_writes);
            for (dpi = 0; dpi < 128; dpi = dpi + 1)
                if (mvf_page[dpi] != 0) $write(" %05h:%0d", dpi * 2048, mvf_page[dpi]);
            $write("\n");
            $write("     %0d DMA writes, by 2K physical page:", dma_writes);
            for (dpi = 0; dpi < 128; dpi = dpi + 1)
                if (dma_page[dpi] != 0) $write(" %05h:%0d", dpi * 2048, dma_page[dpi]);
            $write("\n");
            $write("     memory at physical 0x0cf40:");
            for (ui = 0; ui < 16; ui = ui + 1)
                $write(" %02h", dut.ram.ram_cells[13'h0f40 + ui]);
            $write("   (the reference has 49 15 e5 65 a1 09 32 c0 47 9c ef 00 00 10 55 ba)\n");
            $write("     the 256 microcode words before it, oldest first:");
                for (ui = 0; ui < 256; ui = ui + 1) begin
                    if (ui % 16 == 0) $write("\n      ");
                    $write(" %03h", uc_ring[(uc_head + ui) % 256]);
                end
                $write("\n");
            end
        end
    end

    // Register file writes aimed at a level other than the one running. That is
    // how software prepares a level before switching to it, so if the operating
    // system sets up level 9 before entering it, the writes are here; if none
    // is ever recorded, the level it enters was never going to have a program
    // counter.
    integer other_level_writes = 0;
    always @(posedge in_clk) if (dut.cpu_en && dut.cpu.k11 == 3'd4) begin
        if (dut.cpu.reg_addr_hi != dut.cpu.interrupt_level) begin
            other_level_writes = other_level_writes + 1;
            if ($test$plusargs("regtrace") && other_level_writes < 60)
                $display("REG level %0d reg %0d <= %02h  (running level %0d) at pc=%04h",
                         dut.cpu.reg_addr_hi, dut.cpu.register_index[3:1],
                         dut.cpu.result_register, dut.cpu.interrupt_level,
                         dut.pc_live0);
        end
    end

    // +heartbeat: where the machine is, once every simulated 100ms. A boot takes
    // tens of minutes of wall clock and says nothing while it runs, so "is it
    // stuck, is it slow, or is it fine" has repeatedly been answered by waiting
    // another half hour. This answers it in one line.
    integer beat = 0, beat_instr = 0;
    always @(posedge in_clk) if ($test$plusargs("heartbeat")) begin
        if (dut.instruction_fetch) beat_instr = beat_instr + 1;
        beat = beat + 1;
        if (beat == 2_700_000) begin        // 100ms at 27MHz
            beat = 0;
            $display("[%0t] pc=%04h uc=%03h instructions=%0d disk commands=%0d timeouts=%0d",
                     $time, dut.pc_live0, dut.dbg_uc_address, beat_instr, hawk_cmds,
                     dut.dbg_psram_timeouts);
        end
    end

    // +waittrace: what the loader's wait-for-the-disk loop actually reads. The
    // reference leaves that loop after nine passes; this design spins in it and
    // then takes a level change. "It is waiting on the busy bit" is only half an
    // answer - which address it reads and what comes back is the other half, and
    // Z is inside the CPU where nothing outside can see it.
    integer wt = 0;
    always @(posedge in_clk) if ($test$plusargs("waittrace") && dut.cpu_en)
        if (dut.pc_live0 >= 16'h04f5 && dut.pc_live0 <= 16'h04f9 &&
            dut.bus_read_strobe && wt < 40) begin
            wt = wt + 1;
            $display("WAIT pc=%04h reads %05h => %02h | hawk busy=%b cmd=%0d xfer=%b waiting=%b kind=%0d left=%0d stuck=%0d | dma req=%b hold=%b on=%b f11=%02h | img busy=%b state=%0d failed=%b | sd state=%0d r1=%02h lba=%0d read=%b err=%b | psram busy=%b | shifter idx=%0d active=%b bits=%0d div=%0d start=%b done=%b cs=%b clk=%b miso=%b",
                     dut.pc_live0, dut.addressBus, dut.data_r2c,
                     dut.hawk.busy, dut.hawk.command,
                     dut.hawk.transferring, dut.hawk.waiting, dut.hawk.wait_kind,
                     dut.hawk.bytes_left, dut.hawk.stuck,
                     dut.hawk_req, dut.hawk_hold, dut.cpu.dma_on, dut.cpu.f11,
                     dut.image.busy, dut.image.dbg_state, dut.image.failed,
                     dut.sd_dbg_state, dut.sd_dbg_r1, dut.card_lba,
                     dut.img_sd_read, dut.sd_error, dut.busy_raw,
                     dut.sd.byte_index, dut.sd.byte_active, dut.sd.bit_count,
                     dut.sd.divider, dut.sd.start_byte, dut.sd.byte_done,
                     dut.sd_cs_n, dut.sd_clk, dut.sd_miso);
        end

    // Every read of the Hawk's read-status register, with what came back and what
    // the register actually held at that instant. The driver leaves its wait loop
    // after one poll while busy is measurably still set, so the question is
    // whether the poll returns a stale byte - this bus has no read strobe of its
    // own and the address register simply stays where it was, which has bitten
    // twice before.
    integer sr_n = 0;
    always @(posedge in_clk)
        if ($test$plusargs("statustrace") && dut.cpu_en && dut.bus_read_strobe &&
            dut.addressBus == 19'h3f144 &&
            dut.pc_live0 == 16'hefee && sr_n < 80) begin
            sr_n = sr_n + 1;
            $display("STAT pc=%04h bus=%02h  hawk: busy=%b seeking=%b real_stat4=%02h cmd=%0d xfer=%b waiting=%b",
                     dut.pc_live0, dut.data_r2c,
                     dut.hawk.busy, dut.hawk.seeking,
                     { dut.hawk.media_error, dut.hawk.verify_fail, 6'b0 } |
                       { 7'b0, dut.hawk.busy | dut.hawk.seeking },
                     dut.hawk.command, dut.hawk.transferring, dut.hawk.waiting);
        end

    // Every write into the page the missing code belongs in. The reference has
    // real instructions at physical 0x0cf40 by 195 disk commands and this design
    // has zeros, so either nothing ever writes there or the writes are landing
    // somewhere else. Logs the CPU's own writes and the DMA's alike, since the
    // sector data arrives by DMA.
    integer wr_n = 0;
    always @(posedge in_clk)
        if ($test$plusargs("cfwrite") && dut.cpu_en && dut.writeEnBus &&
            dut.addressBus >= 19'h0cf00 && dut.addressBus <= 19'h0cfff && wr_n < 40) begin
            wr_n = wr_n + 1;
            $display("CFWR %05h <= %02h  at pc=%04h uc=%03h dma_on=%b",
                     dut.addressBus, dut.data_c2r, dut.pc_live0,
                     dut.dbg_uc_address, dut.cpu.dma_on);
        end
    // The same list walk this design gets wrong. ef39 is LDBB [Z++]; the
    // reference reads 00, 00, 00 then 80 - bit 7 set is the end of the list -
    // from records 125 bytes apart in the staging buffer. If this design sees a
    // set bit sooner, the buffer's contents differ rather than the flag being
    // wrong, and the bytes are the ones the DMA just delivered.
    integer lw_n = 0;
    always @(posedge in_clk)
        if ($test$plusargs("listwalk") && dut.cpu_en && dut.bus_read_strobe &&
            dut.pc_live0 == 16'hef39 && hawk_cmds >= 150 && lw_n < 80) begin
            lw_n = lw_n + 1;
            $display("LIST %05h => %02h   (%0d disk commands)  cc=%04b flags=%08b",
                     dut.addressBus, dut.data_r2c, hawk_cmds,
                     dut.cpu.condition_codes, dut.cpu.flags_register);
        end

    // +busytrace: how long the controller actually holds busy for each command,
    // and what the driver's first poll of the status register sees. The
    // reference spins in its wait loop for several passes after a read; this
    // design was leaving it on the first poll, which means the driver carries on
    // as though the sector were already in memory.
    reg prev_busy = 0;
    integer busy_start = 0, bt_n = 0;
    always @(posedge in_clk) if ($test$plusargs("busytrace")) begin
        prev_busy <= dut.hawk.busy;
        if (dut.hawk.busy && !prev_busy) busy_start = $time / 10;
        if (!dut.hawk.busy && prev_busy && bt_n < 40) begin
            bt_n = bt_n + 1;
            $display("BUSY cmd=%0d adr=%04h held for %0d clocks | xfer=%b waiting=%b kind=%0d left=%0d | img state=%0d fetches=%0d",
                     dut.hawk.command, dut.hawk.sector_addr,
                     ($time / 10 - busy_start) / 37,
                     dut.hawk.transferring, dut.hawk.waiting, dut.hawk.wait_kind,
                     dut.hawk.bytes_left, dut.image.dbg_state, dut.image.dbg_fetches);
        end
    end

    // +hawkseq: one line per disk command, in the same shape as the trace the
    // reference emulator prints. A boot that works issues a definite sequence -
    // 301 commands to reach the MAX DISK# prompt - so the first line where the
    // two disagree is the first thing this machine does differently, which is a
    // far sharper question than "it stopped somewhere". A bus write is asserted
    // across two enabled cycles, hence the edge detect.
    reg cmd_seen = 0;
    always @(posedge in_clk) begin
        if (dut.cpu_en && dut.writeEnBus && dut.addressBus[18:0] == 19'h3f148) begin
            if (!cmd_seen) begin
                hawk_cmds = hawk_cmds + 1;
                if ($test$plusargs("hawkseq"))
                    $display("cmd=%02h unit=%01h adr=%04h wpm=%02h PC=%04h",
                             dut.data_c2r, dut.hawk.unit, dut.hawk.sector_addr,
                             dut.hawk.wpmask, dut.pc_live0);
            end
            cmd_seen <= 1;
        end else cmd_seen <= 0;
    end

    // ... and one line when each finishes, with the status the driver is about
    // to read. "The sequence diverges after the first read" is only half an
    // answer; whether that read reported an error is the other half, and it is
    // invisible from the command stream alone.
    reg was_busy = 0;
    always @(posedge in_clk) if ($test$plusargs("hawkseq")) begin
        was_busy <= dut.hawk.busy;
        if (was_busy && !dut.hawk.busy)
            $display("   done cmd=%0d adr=%04h stat4=%02h stat5=%02h  img failed=%b why=%0d fetches=%0d",
                     dut.hawk.command, dut.hawk.sector_addr,
                     { dut.hawk.media_error, dut.hawk.verify_fail, 6'b0 } |
                       { 7'b0, dut.hawk.busy | dut.hawk.seeking },
                     { 1'b0, dut.hawk.write_enabled, ~dut.hawk.seeking, 1'b1,
                       3'b000, dut.hawk.seek_done },
                     dut.image.failed, dut.image.fail_why, dut.image.dbg_fetches);
    end

    // +maptrace: the block-to-LBA lookup, both sides. DiskImage pulses map_req
    // for one clock and Fat32 only notices it in its idle state, so a request
    // that arrives at the wrong moment is simply lost and the image layer times
    // out and reports a media error - which the driver sees as a bad disk.
    always @(posedge in_clk) if ($test$plusargs("maptrace")) begin
        if (dut.map_req)
            $display("map req block=%0d  fat_state=%0d %s", dut.map_block,
                     dut.fat_dbg_state,
                     dut.fat_dbg_state == 0 ? "" : "<-- LOST, Fat32 is not idle");
        if (dut.map_valid)
            $display("map ans lba=%0d", dut.map_lba);
        if (dut.sd_error)
            $display("SD ERROR: card state=%0d r1=%02h  lba=%0d  (fat_read=%b img_read=%b img_write=%b)",
                     dut.sd_dbg_state, dut.sd_dbg_r1, dut.card_lba,
                     dut.fat_read, dut.img_sd_read, dut.img_sd_write);
        // req_block, not block: the failure branch does not latch block, so
        // printing that shows whatever the *last successful* request was and
        // sends you looking in the wrong place entirely.
        if (dut.image.failed && dut.image.dbg_state == 19)
            $display("image FAILED wanted block=%0d of %0d  why=%0d (%0s)",
                     dut.hawk.img_block, dut.file_blocks, dut.image.fail_why,
                     dut.image.fail_why == 1 ? "past the end of the image" :
                     dut.image.fail_why == 2 ? "lookup never answered" :
                     dut.image.fail_why == 3 ? "card read error" :
                     dut.image.fail_why == 4 ? "card write error" : "?");
    end

    // Does the microcode ever rejoin the fetch sequence at 0x102 without going
    // through 0x101? instruction_start is `== 11'h101' exactly, so if it does,
    // that signal misses real instructions - and the watchdog and every
    // instruction counter would read "stopped" on a machine that is running.
    integer at_101 = 0, at_102 = 0, skipped_101 = 0;
    reg [10:0] uc_prev = 0;
    always @(posedge in_clk) if (dut.cpu_en) begin
        uc_prev <= dut.dbg_uc_address;
        if (dut.dbg_uc_address == 11'h101) at_101 = at_101 + 1;
        if (dut.dbg_uc_address == 11'h102) begin
            at_102 = at_102 + 1;
            if (uc_prev != 11'h101) skipped_101 = skipped_101 + 1;
        end
    end

    // The last 64 instruction fetches. "Where did it stop" is only half an
    // answer when the machine has run off into memory that holds nothing: the
    // other half is the last address it was executing something real at, and
    // the jump that took it away from there. A single latched PC cannot show
    // that, and +pctrace over a whole boot is tens of thousands of lines.
    reg [15:0] pc_ring [0:63];
    reg [5:0] pc_head = 0;
    integer pk;
    initial for (pk = 0; pk < 64; pk = pk + 1) pc_ring[pk] = 16'hffff;
    // dbg_memory_address, not pc_live0: pc_live0 is latched from it on this same
    // edge, so reading pc_live0 here stores the *previous* fetch and the whole
    // ring lags by one.
    always @(posedge in_clk) if (dut.instruction_fetch) begin
        pc_ring[pc_head] <= dut.dbg_memory_address;
        pc_head <= pc_head + 1;
    end

    // The two instruments must agree on every fetch, not just at the end of the
    // run: pc_live0 inside the top level and this ring are both latched from
    // dbg_memory_address on the same edge. One run reported a trail whose newest
    // entry was 0000 while pc_live0 read 0506, which cannot both be true, and
    // waiting until the end to notice loses the cycle it happened on. This says
    // so once, immediately.
    reg mismatch_said = 0;
    always @(posedge in_clk) if (dut.instruction_fetch && !mismatch_said) begin
        if (pc_head != 0 && dut.pc_live0 !== pc_ring[(pc_head + 63) % 64]) begin
            $display("INSTRUMENT MISMATCH at %0t: pc_live0=%04h but the ring's newest is %04h (head %0d, fetching %04h)",
                     $time, dut.pc_live0, pc_ring[(pc_head + 63) % 64],
                     pc_head, dut.dbg_memory_address);
            mismatch_said <= 1;
        end
    end

    // The reference emulator never executes at 0xa080-0xa200 during its whole
    // boot - counted directly, zero steps - and this design ends up looping
    // there. So the interesting moment is not the loop, it is the *first* fetch
    // in that range: the sixty-four fetches before it are the path that took the
    // machine somewhere the real one does not go. Printed once, then the run
    // carries on.
    reg diverged = 0;
    integer dv;
    always @(posedge in_clk)
        if (dut.instruction_fetch && !diverged &&
            dut.dbg_memory_address >= 16'ha080 && dut.dbg_memory_address <= 16'ha200) begin
            diverged <= 1;
            $display("\n*** FIRST FETCH IN 0xa080-0xa200: %04h, after %0d instructions and %0d disk commands ***",
                     dut.dbg_memory_address, at_101, hawk_cmds);
            $write("  the 64 fetches before it, oldest first:");
            for (dv = 0; dv < 64; dv = dv + 1) begin
                if (dv % 8 == 0) $write("\n   ");
                $write(" %04h", pc_ring[(pc_head + dv) % 64]);
            end
            $write("\n");
        end

    // Progress, not just liveness. The machine can be executing forty thousand
    // instructions a second and still be going round; what says it has stopped
    // making headway is that no new disk command has been issued for a long
    // time. Dump where it is spending that time and stop, rather than running
    // to the end of HOLD with nothing to show.
    integer since_cmd = 0, last_cmds = 0;
    reg [15:0] loop_hits [0:15];
    integer lh;
    initial for (lh = 0; lh < 16; lh = lh + 1) loop_hits[lh] = 0;
    always @(posedge in_clk) if (dut.img_mounted) begin
        if (hawk_cmds != last_cmds) begin
            last_cmds = hawk_cmds;
            since_cmd = 0;
        end else since_cmd = since_cmd + 1;
        if (since_cmd == 400_000_000) begin      // ~15 seconds of simulated time
            $display("\n*** NO DISK COMMAND FOR 15 SIMULATED SECONDS ***");
            $display("  %0d disk commands, %0d instructions, pc=%04h uc=%03h",
                     hawk_cmds, at_101, dut.pc_live0, dut.dbg_uc_address);
            $write("  the last 64 fetches, oldest first:");
            for (dv = 0; dv < 64; dv = dv + 1) begin
                if (dv % 8 == 0) $write("\n   ");
                $write(" %04h", pc_ring[(pc_head + dv) % 64]);
            end
            $write("\n");
            $finish;
        end
    end

    // Stop the moment the core stops fetching, rather than at a fixed time. A
    // hang can be a long way in, and running to a wall clock limit either stops
    // short of it or wastes hours past it. This ends the run exactly when the
    // thing being looked for happens, and says where.
    reg mounted_seen = 0;
    integer idle_clocks = 0;
    always @(posedge in_clk) if (dut.img_mounted) mounted_seen <= 1;
    always @(posedge in_clk) begin
        if (dut.instruction_fetch) idle_clocks <= 0;
        else if (mounted_seen) idle_clocks <= idle_clocks + 1;
        if (idle_clocks == 20_000_000) begin       // three quarters of a second
            $display("\n*** THE CORE STOPPED FETCHING ***");
            $display("  last instruction %04h, opcode %02h, microcode %03h, MAR %04h",
                     dut.pc_live0, dut.last_opcode, dut.dbg_uc_address,
                     dut.cpu.dbg_memory_address);
            $display("  f11=%02h dma_on=%b hawk: req=%b hold=%b busy=%b cmd=%0d sector=%04h",
                     dut.cpu.f11, dut.cpu.dma_on, dut.hawk_req, dut.hawk_hold,
                     dut.hawk.busy, dut.hawk.command, dut.hawk.sector_addr);
            $display("  image: state=%0d busy=%b failed=%b why=%0d fetches=%0d",
                     dut.image.dbg_state, dut.image.busy, dut.image.failed,
                     dut.image.fail_why, dut.img_fetches);
            // A jump to 0x0000 in the fetch trail is the signature of an
            // interrupt taken to a level whose P register is zero, so the state
            // that decides whether one could have been taken belongs in the
            // report. int_enabled is f11 bit 0; dma_req and dma_int reach the
            // "anything wants attention" condition by different routes, and
            // only one of them is gated on int_enabled.
            $display("  interrupts: level=%0d f11[0]=%b int_reqn=%b dma_int=%b dmaint=%b   hawk int: en=%b pend=%b   mux int pend=%b",
                     dut.cpu.interrupt_level, dut.cpu.int_enabled, dut.int_reqn,
                     dut.cpu.dma_int, dut.cpu.dmaint,
                     dut.hawk.int_enabled, dut.hawk.int_pending,
                     dut.mux0.int_pending);
            $display("  register writes aimed at another level: %0d", other_level_writes);
            $display("  page table: %0d entries written, %0d of them with the write-tracked bit set; the bit read set on %0d cycles",
                     pt_writes, pt_writes_bit7, pt_read_bit7);
            // The bridge gives up after 4095 clocks and, when it does, fills the
            // cache line with ff and marks it valid - so a timed-out read
            // returns ff and so does every later read of the same line. That is
            // exactly what the failing list walk sees, so the count matters.
            $display("  bridge timeouts: %0d (last where: %0h)",
                     dut.dbg_psram_timeouts, dut.psram_bus.dbg_timeout_where);
            $display("  bridge: need=%b state=%0d   instructions so far %0d",
                     dut.psram_bus.dbg_need, dut.psram_bus.dbg_state, at_101);
            // Both instruments, side by side. They are built from the same
            // instruction_fetch but in different files, so a disagreement means
            // one of them is wrong and it matters which: the board's trail is
            // what the hardware reports on trigger byte 0x05.
            $display("  pc_live1=%04h pc_live0=%04h   board trail %04h %04h %04h %04h %04h (head %0d)",
                     dut.pc_live1, dut.pc_live0,
                     dut.fh4, dut.fh3, dut.fh2, dut.fh1, dut.fh0, pc_head);
            $write("  the last 64 instruction fetches, oldest first:");
            for (pk = 0; pk < 64; pk = pk + 1) begin
                if (pk % 8 == 0) $write("\n   ");
                $write(" %04h", pc_ring[(pc_head + pk) % 64]);
            end
            $write("\n");
            $finish;
        end
    end

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
                repeat (GAP) #1000000;
            end
        end
        repeat (HOLD) #1000000;
        // The code the machine ended up in, so it can be disassembled. It came
        // off the disk, so it is nowhere in this repository and the only way to
        // read it is out of the memory it was loaded into.
        $write("--- memory at 0x0efe0 ---");
        for (i = 0; i < 64; i = i + 1) begin
            if (i % 16 == 0) $write("\n%05x:", 19'h0efe0 + i);
            $write(" %02x", die.mem[19'h0efe0 + i]);
        end
        $display("");
        // The fetch trail the board reports on trigger byte 0x05 is a shift
        // register in the top level, and a dump taken while diag is printing
        // collides with its output, so the serial line cannot check it. Check it
        // against the testbench's own ring instead, which is built from the same
        // instruction_fetch but independently.
        if ({dut.fh4, dut.fh3, dut.fh2, dut.fh1, dut.fh0} !==
            {pc_ring[(pc_head + 59) % 64], pc_ring[(pc_head + 60) % 64],
             pc_ring[(pc_head + 61) % 64], pc_ring[(pc_head + 62) % 64],
             pc_ring[(pc_head + 63) % 64]})
            $display("FAIL: the fetch trail disagrees with the testbench's ring:\n  board %04h %04h %04h %04h %04h\n  ring  %04h %04h %04h %04h %04h",
                     dut.fh4, dut.fh3, dut.fh2, dut.fh1, dut.fh0,
                     pc_ring[(pc_head + 59) % 64], pc_ring[(pc_head + 60) % 64],
                     pc_ring[(pc_head + 61) % 64], pc_ring[(pc_head + 62) % 64],
                     pc_ring[(pc_head + 63) % 64]);
        else
            $display("ok: the fetch trail matches, last five fetches %04h %04h %04h %04h %04h",
                     dut.fh4, dut.fh3, dut.fh2, dut.fh1, dut.fh0);
        $display("microcode: reached 0x101 %0d times, 0x102 %0d times, of which %0d did NOT come from 0x101",
                 at_101, at_102, skipped_101);
        $display("\n--- %0d characters ---", n);
        $display("--- hawk: sector %04h, status %02h; image: %0d fetches, %0d hits ---",
                 dut.hawk.sector_addr, dut.hawk.data_out,
                 dut.image.dbg_fetches, dut.image.dbg_hits);
        $display("--- hex display %02x, points %b, blank %b ---",
                 dut.diag_hex, dut.diag_points, dut.diag_blank);
        $finish;
    end
endmodule

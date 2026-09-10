`timescale 1 ns/10 ps
`include "SimPrimitives.v"

`include "tangnano9k.v"
`include "HyperRamModel.v"

/**
 * Runs a program on the whole simulated board and talks to it over the serial
 * line, so that writing machine code for this machine is a one second loop
 * rather than a three minute build, load and capture on hardware.
 *
 *   vvp ProgramTB +prog=programs/forth.txt +in=t.txt +for=200
 *
 *   +prog=FILE   the ROM image, one hex byte per line
 *   +in=FILE     characters to type at it once it has said something
 *   +for=N       milliseconds of simulated board time to run for
 *   +quiet       do not echo what the machine prints
 *   +hex         echo it as hex bytes instead, for when it is not text
 *
 * The whole board is here, PSRAM included, so a program can use all of the
 * memory and the MMU exactly as it would on the real thing.
 */
module ProgramTB;
    reg in_clk = 0;
    always #18.5185 in_clk = ~in_clk;
    reg reset_btn = 1, btn2 = 1;
    wire L1,L2,L3,L4,L5,L6,L7,L8;
    wire uart_tx;
    reg  uart_rx = 1;

    wire [1:0] psram_ck, psram_ck_n, psram_cs_n, psram_reset_n;
    wire [1:0] psram_rwds;
    wire [15:0] psram_dq;
    HyperRamModel #(.ADDR_BITS(18)) die(
        .ck(psram_ck[0]), .cs_n(psram_cs_n[0]), .resetn(psram_reset_n[0]),
        .rwds(psram_rwds[0]), .dq(psram_dq[7:0]));

    tangnano9k dut(in_clk, reset_btn, btn2, L1,L2,L3,L4,L5,L6,L7,L8, uart_tx, uart_rx,
                   psram_ck, psram_ck_n, psram_cs_n, psram_reset_n, psram_rwds, psram_dq);

    // Still at least two board clocks between enabled cycles, so cycle level
    // behaviour is unchanged; it just gets there sooner.
    defparam dut.cpu_clock_enable.TICKS = 13;

    localparam BITP = 27_000_000/19200 + 1;      // 19200 7N1, as diag uses

    integer i, nprinted = 0;
    reg [7:0] ch;
    reg quiet = 0;
    reg hex = 0;
    // How long the machine has been silent, in board clocks. Typing has to wait
    // for it to stop talking: the MUX holds one byte, so anything sent while a
    // banner is still printing is lost except the last of it.
    integer quiet_for = 0;
    always @(posedge in_clk) quiet_for = quiet_for + 1;
    reg said_something = 0;
    initial begin
        forever begin
            @(negedge uart_tx);
            repeat (BITP + BITP/2) @(posedge in_clk);
            ch = 0;
            for (i = 0; i < 7; i = i + 1) begin
                ch[i] = uart_tx;
                repeat (BITP) @(posedge in_clk);
            end
            said_something = 1;
            quiet_for = 0;
            nprinted = nprinted + 1;
            if (hex) $write("%02x ", ch);
            else if (!quiet) $write("%s", ch);
        end
    end

    // Wait for the machine to take the byte the receiver is holding. The MUX
    // holds exactly one, so anything sent before it has been read is lost, and
    // that is the whole reason typing has to be paced at all. Waiting on the
    // flag itself is exact where a delay is a guess: a delay long enough for
    // the slowest line - compiling one colon definition here takes over 200ms,
    // because every word on it is a linear walk of the dictionary - would be
    // wasted on every other line, and one tuned to the common case silently
    // truncates the slow ones, which reads exactly like the definition having
    // failed rather than like dropped input.
    // Both halves are needed. Waiting only for the flag to clear is not a
    // handshake at all: the receiver sets it as the stop bit completes, so a
    // moment after send() returns it is still low, the next send() sees a free
    // receiver that is not free, and transmits on top of a byte the machine has
    // not taken. That loses characters in bursts exactly when the machine is
    // busiest, which reads like the program mis-parsing its input.
    // Waiting on the flag's level does not work in either direction. Waiting
    // only for it to clear is not a handshake at all - the receiver sets it as
    // the stop bit completes, so a moment after send() returns it is still low,
    // the next send() sees a receiver that is not really free, and transmits on
    // top of a byte the machine has not taken. And waiting for it to be set
    // after sending hangs, because the program can read the byte out within a
    // few cycles of its arriving, long before the sending task looks again.
    //
    // So pair the level with the count, which only ever goes up: wait for the
    // receiver to be empty before sending, and for the count to move before
    // calling the byte delivered. Both waits are bounded, so a machine that has
    // stopped reading costs a delay rather than a hang.
    task waitempty;
    integer k;
    begin
        k = 0;
        while (dut.mux0.byteReady && k < 27000 * 500) begin
            @(posedge in_clk);
            k = k + 1;
        end
    end
    endtask

    task waitcount(input [15:0] was);
    integer k;
    begin
        k = 0;
        while (dut.rx_count == was && k < 27000 * 500) begin
            @(posedge in_clk);
            k = k + 1;
        end
    end
    endtask

    task send(input [7:0] c);
    integer k;
    reg [15:0] before;
    begin
        waitempty;                           // the last byte has been taken
        before = dut.rx_count;
        if ($test$plusargs("typetrace")) $write("<%s>", c);
        uart_rx = 0;
        repeat (BITP) @(posedge in_clk);
        for (k = 0; k < 7; k = k + 1) begin
            uart_rx = c[k];
            repeat (BITP) @(posedge in_clk);
        end
        uart_rx = 1;
        repeat (BITP) @(posedge in_clk);
        waitcount(before);                   // and this one has arrived
    end
    endtask

    integer fd, c, ms;
    reg [8*64:1] infile;
    initial begin
        if ($test$plusargs("quiet")) quiet = 1;
        if ($test$plusargs("hex")) hex = 1;
        if (!$value$plusargs("for=%d", ms)) ms = 100;
        if ($value$plusargs("in=%s", infile)) begin
            // Wait until the machine has printed something and then stopped,
            // so that input is not typed over the top of a banner.
            wait (said_something);
            wait (quiet_for > 27000 * 20);
            fd = $fopen(infile, "r");
            if (fd == 0) begin
                $display("\ncannot open %0s", infile);
                $finish;
            end
            // send() paces itself against the machine's own receiver, so
            // the file can simply be fed in a byte at a time.
            c = $fgetc(fd);
            while (c != -1) begin
                send(c[7:0]);
                if (c == 10 || c == 13) wait (quiet_for > 27000 * 5);
                c = $fgetc(fd);
            end
            $fclose(fd);
        end
    end

    // +addrtrace=FILE: every address the PSRAM bridge is asked for, one per
    // line, whether it hits or misses. Modelling cache geometries against a real
    // address stream is far cheaper than building each one and measuring it.
    integer atf = 0;
    reg [18:0] last_addr = 0;
    reg last_valid = 0;
    reg [8*64:1] atname;
    initial if ($value$plusargs("addrtrace=%s", atname)) atf = $fopen(atname, "w");
    always @(posedge in_clk) if (atf) begin
        if (dut.cpu_en && dut.psram_select) begin
            // One line per bus cycle the core spends pointing at the PSRAM, but
            // only when the address moves: the address register simply stays
            // where it was, so the same cycle repeats and would swamp the trace.
            if (!last_valid || dut.addressBus !== last_addr) begin
                $fwrite(atf, "%0d %h\n", dut.writeEnBus, dut.addressBus);
                last_addr <= dut.addressBus;
                last_valid <= 1;
            end
        end
    end

    // +rxtrace: every read of the MUX data register, with the program counter
    // that caused it and whether a byte was waiting. A read consumes whatever
    // the receiver is holding, so a read the program did not ask for loses a
    // character.
    always @(posedge in_clk) if ($test$plusargs("rxtrace"))
        if (dut.mux0.read_data_register)
            $display("\nrx read at pc=%h mar=%h ready=%b", dut.pc_live0,
                     dut.addressBus, dut.mux0.byteReady);

    // +dmatrace: the DMA path, which is otherwise entirely invisible - the CPU
    // executes the same wait loop whether a byte moved or not. This prints the
    // latch bits the transfer is gated on when they change, then a line per byte.
    reg [7:0] last_f11 = 8'hxx;
    always @(posedge in_clk) if ($test$plusargs("dmatrace")) begin
        if (dut.cpu.f11 !== last_f11) begin
            $display("f11 %b -> %b (dma_on needs bit4 set, bit2 clear) req=%b",
                     last_f11, dut.cpu.f11, dut.cpu.dma_req);
            last_f11 = dut.cpu.f11;
        end
        if (dut.cpu.dma_step)
            $display("dma %s mar=%h war=%h data=%h",
                     dut.cpu.dma_device_write ? "wr" : "rd",
                     dut.cpu.memory_address, dut.cpu.work_address,
                     dut.cpu.dma_device_write ? dut.cpu.dma_wdata : dut.cpu.dma_rdata);
    end

    // +uctrace: the microsequencer itself, one line per enabled cycle, with the
    // condition inputs the DMA wait loop turns on. A machine stuck inside one
    // instruction shows nothing at all through +pctrace.
    always @(posedge in_clk) if ($test$plusargs("uctrace"))
        if (dut.cpu_en)
            $display("uc %h k9en=%b k9=%d k13=%d jsr_=%b or=%b f11=%b req=%b",
                     dut.dbg_uc_address, dut.cpu.k9_enable, dut.cpu.k9,
                     dut.cpu.k13, dut.cpu.jsr_, dut.cpu.seq0_orin,
                     dut.cpu.f11, dut.cpu.dma_req);

    // +pctrace: one line per instruction fetch, so a machine that stops can be
    // told from a machine that is stuck in a loop, and the address named.
    always @(posedge in_clk) if ($test$plusargs("pctrace"))
        if (dut.instruction_fetch) $display("pc %h", dut.pc_live0);

    // +psramtrace: say what the PSRAM bridge is doing when it holds the core
    // still for a long time, and report every timeout. A stall here is silent
    // from outside - the machine simply stops - so there is nothing to see
    // without this.
    integer stuck = 0;
    integer stalled = 0, ran = 0;
    reg [31:0] last_timeouts = 0;
    always @(posedge in_clk) begin
        ran = ran + 1;
        if (dut.psram_bus.dbg_need) stalled = stalled + 1;
    end
    always @(posedge in_clk) if ($test$plusargs("psramtrace")) begin
        // Count clocks since the last instruction fetch, not since the bridge
        // last wanted something: a core that has stopped fetching is the
        // symptom, and the bridge is only one of the things that can cause it.
        if (!dut.instruction_fetch) begin
            stuck = stuck + 1;
            if (stuck % 20000 == 0)
                $display("\nno fetch for %0d clocks: pc=%h uc=%h mar=%h e7=%b | psram need=%b state=%0d busy=%b addr=%h we=%b sdr=%0d",
                         stuck, dut.pc_live0, dut.cpu.dbg_uc_address,
                         dut.cpu.dbg_memory_address, dut.cpu.dbg_e7,
                         dut.psram_bus.dbg_need, dut.psram_bus.dbg_state,
                         dut.psram_bus.busy, dut.psram_bus.address,
                         dut.psram_bus.write_en, dut.psram.state);
        end else stuck = 0;
        if (dut.psram_bus.dbg_timeouts != last_timeouts) begin
            last_timeouts = dut.psram_bus.dbg_timeouts;
            $display("\npsram timeout #%0d where=%h", last_timeouts,
                     dut.psram_bus.dbg_timeout_where);
        end
    end

    initial begin
        #(ms * 1000000);
        $display("\n--- %0d characters printed in %0dms ---", nprinted, ms);
        if ($test$plusargs("psramtrace")) begin
            $display("die: %0d bursts, %0d bytes read, %0d written; bridge: %0d accesses, %0d timeouts",
                     die.bursts, die.bytes_read, die.bytes_written,
                     dut.dbg_psram_accesses, dut.dbg_psram_timeouts);
            // What the memory actually costs the machine: the core is held
            // still for every one of these clocks.
            $display("psram: core stalled %0d of %0d clocks, %0d%%",
                     stalled, ran, (stalled * 100) / (ran ? ran : 1));
        end
        $finish;
    end
endmodule

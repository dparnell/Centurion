
// `define TRACE_I // trace instructions
// `define TRACE_WR // trace bus writes
// `define TRACE_RD // trace bus reads
// `define TRACE_UC // trace microcode

`timescale 1 ns/10 ps  // time-unit = 1 ns, precision = 10 ps
`include "CPU6.v"
`include "Clock.v"
`include "LEDPanel.v"

/**
 * This file contains a test bench for the CPU6.
 * It includes two RAM banks and one ROM.
 * Writing to the MUX UART prints to the console.
 */
module Memory(input wire clock, input wire enable, input wire [18:0] address, input wire write_en, input wire [7:0] data_in,
    output reg [7:0] data_out);

    reg [7:0] rom_cells[0:8191];
    reg [7:0] ram_cells[0:8191];
    reg [7:0] low_ram_cells[0:4095];

    integer i;
    initial begin
        for (i=0; i<8192; i=i+1) ram_cells[i] = 8'h00;
        for (i=0; i<4096; i=i+1) low_ram_cells[i] = 8'h00;
    end

    wire rom_select = address[18:13] == 4;
    // 8K covering physical 0x0b000 to 0x0cfff, matching BoardMemory.v. It has to
    // reach 0x0c000 because that is where a program's stack ends up, and CPU6's JSR
    // pushes the old X, so calls made with an unbacked stack return with X zeroed.
    wire ram_select = address[18:12] == 7'h0b || address[18:12] == 7'h0c;
    wire low_ram_select = address[18:12] == 0;
    wire [12:0] low13 = address[12:0];
    wire [11:0] low12 = address[11:0];
    wire [12:0] ram_addr = { address[12], address[11:0] };

    always @(*) begin
        data_out = 0;
        //$display("address = %x", address);

        case (address)
            19'h3fd00: data_out = 8'h71; // Reset vector, JMP 8001
            19'h3fd01: data_out = 8'h80;
            19'h3fd02: data_out = 8'h01;
            19'h3f200: data_out = 8'h02; // Diag MUX 0 status
            19'h3f110: data_out = 8'h0d; // Diag DIP switches
            default:
                begin
                    if (rom_select) data_out = rom_cells[low13];
                    if (ram_select) data_out = ram_cells[ram_addr];
                    if (low_ram_select) data_out = low_ram_cells[low12];
                end
        endcase
    end

    always @(posedge clock) begin
        if (enable && write_en) begin
            if (ram_select) ram_cells[ram_addr] <= data_in;
            if (low_ram_select) low_ram_cells[low12] <= data_in;
        end
    end
endmodule

module CPU6TestBench;

    reg [8*64:1] ramfile;
    wire writeEnBus;
    wire [7:0] data_c2r, data_r2c;
    wire [18:0] addressBus;
    wire clock;
    reg int_reqn;
    reg [3:0] irq_number;
    reg [7:0] led_reg;
    wire [7:0] leds;

    assign leds = led_reg;

    Clock cg0(clock);
    // The core is driven through a clock enable here too. It cannot be tied high: the
    // microcode ROM and register file read every clock and CPU6 holds the control word
    // in its pipeline register, so enabled cycles must be at least two clocks apart.
    // One in two keeps simulation fast while matching the board's timing relationship.
    reg cpu_en = 0;
    always @(posedge clock) cpu_en <= ~cpu_en;

    Memory ram(clock, cpu_en, addressBus, writeEnBus, data_c2r, data_r2c);
    reg reset;
    LEDPanel panel(clock, cpu_en, addressBus, writeEnBus, data_c2r, leds);

    // The microcode never puts k11 == 7 (latch the write data) and h11 == 2
    // (begin the bus write cycle) in the same word - 47 words do the first, 32
    // the second, none does both - so which of the two this design uses as its
    // write strobe is a real question. Meisaka's emulator commits the write on
    // h11 == 2, with k11 == 7 only latching the data; this design commits on
    // k11 == 7 and leaves h11 == 2 a stub.
    integer n_k11_7 = 0, n_h11_2 = 0, n_h11_2_after = 0;
    reg prev_k11_7 = 0;
    // The same question for the READ strobe. This design treats every e7 == 3 as
    // a bus read, but the emulator only reads a device if h11 == 1 began a read
    // cycle - the rest are the CPU latching its own write data. A device whose
    // read has a side effect, which is every one of them on this bus, sees the
    // difference: the MUX's data register loses a received character to it.
    integer n_h11_1 = 0, n_e7_3 = 0, n_e7_3_after_read = 0;
    reg pending_read = 0;
    always @(posedge clock) if (cpu_en) begin
        prev_k11_7 <= (cpu.k11 == 3'd7);
        if (cpu.k11 == 3'd7) n_k11_7 = n_k11_7 + 1;
        if (cpu.h11 == 3'd2) begin
            n_h11_2 = n_h11_2 + 1;
            if (prev_k11_7) n_h11_2_after = n_h11_2_after + 1;
        end
        if (cpu.h11 == 3'd1) begin n_h11_1 = n_h11_1 + 1; pending_read <= 1; end
        if (cpu.e7 == 2'd3) begin
            n_e7_3 = n_e7_3 + 1;
            if (pending_read) n_e7_3_after_read = n_e7_3_after_read + 1;
            pending_read <= 0;
        end
    end

    CPU6 cpu(reset, clock, cpu_en, data_r2c, int_reqn, irq_number, writeEnBus, addressBus, data_c2r,
             , 1'b0, 8'h00, 8'h00, 4'b0001,
             // No DMA device here: request low, and the three outputs unused.
             // These have to be given explicitly, because leaving dma_req to
             // float makes jsr_ x in the interrupt condition and the machine
             // stops on the first instruction with no clue why.
             1'b0, 1'b0, 8'h00, , , , 1'b0, 1'b0,
             , , , , , , , , , , , , , , , , , 1'b0, );
    reg sim_end;
    wire [7:0] cc = data_c2r & 8'h7f;


    initial begin
        $dumpfile("CPUTestBench.vcd");
        $dumpvars(0, CPU6TestBench);

        int_reqn = 1;

        $readmemh("programs/hellorld.txt", ram.rom_cells);
        $write("hellorld: ");
        sim_end = 0; #0 reset = 0; #50 reset = 1; #1000 reset = 0;
        wait(sim_end == 1);

        $readmemh("programs/bnz_test.txt", ram.rom_cells);
        $write("bnz_test: ");
        sim_end = 0; #0 reset = 0; #50 reset = 1; #1000 reset = 0;
        wait(sim_end == 1);

        $readmemh("programs/alu_test.txt", ram.rom_cells);
        $write("alu_test: ");
        sim_end = 0; #0 reset = 0; #50 reset = 1; #1000 reset = 0;
        wait(sim_end == 1);

        $readmemh("programs/dcx_test.txt", ram.rom_cells);
        $write("dcx_test: ");
        sim_end = 0; #0 reset = 0; #50 reset = 1; #1000 reset = 0;
        wait(sim_end == 1);

        $readmemh("programs/jsr_test.txt", ram.rom_cells);
        $write("jsr_test: ");
        sim_end = 0; #0 reset = 0; #50 reset = 1; #1000 reset = 0;
        wait(sim_end == 1);

        // $readmemh("programs/diag.txt", ram.rom_cells);
        // sim_end = 0; #0 reset = 0; #50 reset = 1; #1000 reset = 0;
        // #17000000 $finish;

        // $readmemh("programs/inst_test.txt", ram.rom_cells);
        // sim_end = 0; #0 reset = 0; #50 reset = 1; #1000 reset = 0;
        // #4100000 $finish;

        // $readmemh("programs/cylon.txt", ram.rom_cells);
        // sim_end = 0; #0 reset = 0; #50 reset = 1; #1000 reset = 0;

        //$readmemh("programs/blink.txt", ram.rom_cells);
        //$display("running blink...");
        //sim_end = 0; #0 reset = 0; #50 reset = 1; #1000 reset = 0; #200000000; sim_end = 1;
        //wait(sim_end == 1);

        $display("write strobes: k11==7 fired %0d times, h11==2 fired %0d times, %0d of those right after a k11==7",
                 n_k11_7, n_h11_2, n_h11_2_after);
        $display("read strobes: h11==1 fired %0d times, e7==3 fired %0d times, %0d of those after an h11==1",
                 n_h11_1, n_e7_3, n_e7_3_after_read);
        $display("All done!");
        $finish;
    end



    always @(posedge clock) begin
        if (cpu_en && writeEnBus == 1) begin
            // Pretend there's a UART here :-)
            if (addressBus == 19'h3f201) begin
                if ((cc >= 32) || (cc == 9) || (cc == 10) || (cc == 13)) begin
                    $write("%s", cc);
                end
            end

            // A hack to stop simulation
            if (addressBus == 19'h3f900 && data_c2r == 8'h01) begin
                sim_end <= 1;
            end
        end
    end
endmodule

/*

TotalSeconds      : 1.0773913
TotalMilliseconds : 1077.3913
4.9 ms simulation time = 220 times slower than hardware Centurion
About 22.75 kHz clock simulated

First instruction is fetched about 40 uS after reset.

Cycle counts

Opcode: 0x01, cycles:     4
Opcode: 0x02, cycles:     5
Opcode: 0x03, cycles:     5
Opcode: 0x04, cycles:     8
Opcode: 0x05, cycles:     8
Opcode: 0x06, cycles:     5
Opcode: 0x07, cycles:     5
Opcode: 0x08, cycles:     5
Opcode: 0x09, cycles:    22
Opcode: 0x0a, cycles:    31
Opcode: 0x0b, cycles:    44
Opcode: 0x0c, cycles:     6
Opcode: 0x0d, cycles:     9
Opcode: 0x0e, cycles: 22725
Opcode: 0x0f, cycles:    42

Opcode: 0x21, cycles:    12

Opcode: 0x38, cycles:     7
Opcode: 0x39, cycles:     7
Opcode: 0x3a, cycles:     6
Opcode: 0x3b, cycles:     7
Opcode: 0x3c, cycles:    10
Opcode: 0x3d, cycles:     8
Opcode: 0x3e, cycles:    10
Opcode: 0x3f, cycles:    10
Opcode: 0x81, cycles:     8
Opcode: 0x83, cycles:    18

01 NOP 4
05 DI 8
3A CLAW 6
22 CLR 11
a1 STAL 18
b1 STAW 22
90 LDAW 12
5f XASW 8
81 LDAL 18
c1 LDBL 18
c0 LDBL 8
99 LAWB 19
42 AND 11
40 ADD 11
58 AABW 9
49 SABL 8
3d SLAW 8
71 JMP 14
14 BZ 9 (branch not taken)
15 BNZ 18 (branch taken)

 */

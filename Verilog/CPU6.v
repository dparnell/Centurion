
`include "Am2909.v"
`include "Am2911.v"
`include "Am2901.v"
`include "CodeROM.v"
`include "MapROM.v"
`include "RegisterRAM.v"

// Include instruction names for simulation instruction tracing
`ifdef TRACE_I
    `include "Instructions.v"
`endif

/**
 * This module implements the Centurion CPU6.
 * The original Centurion used a clock with three difference phases.
 * This design requires only a single phase.
 *
 * See https://github.com/Nakazoto/CenturionComputer/wiki/CPU6-Board
 */
module CPU6 #(
    // Whether the clock tick obeys M13 bits 5 and 2. See rtc_active below: the
    // faithful reading hangs the operating system, so this is off until the
    // reason is understood.
    parameter RTC_GATED = 0,
    // Whether K13 case 1 ORs the interrupt conditions into the sequencer. The
    // emulator does, and with nothing pending that means *both* bits high where
    // the stub left them low - the opposite. Under test: the operating system
    // freezes on one microcode word at 0x73d, which is a K13 case 1 word.
    parameter K13_INTERRUPTS = 1
) (input wire reset, input wire clock, input wire enable, input wire [7:0] dataInBus,
    input wire int_reqn, input wire [3:0] irq_number,
    output reg writeEnBus, output wire [18:0] addressBus, output wire [7:0] dataOutBus,
    output wire instruction_start,
    // Page table initialiser. Only the write path is muxed: the read path is the
    // critical path of the whole design and must not gain a mux.
    input wire ptinit_write, input wire [7:0] ptinit_addr, input wire [7:0] ptinit_data,
    input wire [3:0] sense_switches,
    // A DMA device. It does not drive the bus: it borrows these address
    // registers, which is what DMA means on this machine. req says it has work,
    // write says which way the byte goes, and step tells it one moved - on a
    // write we took wdata, on a read rdata is what came back. end is this
    // machine's own end condition, the work address register wrapping.
    input wire dma_req, input wire dma_device_write, input wire [7:0] dma_wdata,
    output wire dma_step, output wire [7:0] dma_rdata, output wire dma_end,

    // Separate from the request above: this is the device saying a transfer it
    // was asked for has finished, so that a driver need not poll. Meisaka's
    // emulator calls it dma_12, after the controller register that raises it.
    // Several devices would simply be OR-ed onto it.
    input wire dma_int,

    // A device that cannot supply or take a byte right now raises this instead
    // of dropping its request. Dropping it is not an option: the microcode's
    // DMA wait loop watches the request, so lowering it says the transfer is
    // over. This is what lets a disk controller cross a sector boundary.
    input wire dma_hold,
    // Page table initialiser. Only the write path is muxed: the read path is the
    // critical path of the whole design and must not gain a mux.
    // For the board level status dump: where the machine is, at both levels.
    output wire [15:0] dbg_memory_address, output wire [10:0] dbg_uc_address,
    output wire [2:0] dbg_page_table_base, output wire [7:0] dbg_page_table_out,
    output wire [3:0] dbg_d2d3,
    output wire [7:0] dbg_f11,
    // e7 == 3 is where a bus read is latched, and dataInCPU is the byte latched. These
    // are brought out as ports because the top level needs them for instrumentation and
    // a hierarchical reference into the core is not synthesisable.
    output wire [1:0] dbg_e7, output wire [7:0] dbg_data_in,
    // Entry 0 of the current map, for instrumentation. The mapping RAM test fails on
    // this entry and it is the one the test's own buffers are addressed through.
    output wire [7:0] dbg_entry0,
    // Every write to entry 0 of the running map: the value, and whether it arrived
    // through the memory window at 0x100..0x1ff or through the microcode's own k11 == 5
    // page file write. That entry is the one diag's mapping test fails on.
    output wire dbg_e0_write, output wire [7:0] dbg_e0_value, output wire dbg_e0_via_window,
    // Any page table write: which entry, what value, and by which path.
    output wire dbg_pt_write, output wire [7:0] dbg_pt_index, output wire [7:0] dbg_pt_value,
    output wire dbg_pt_via_window,
    // M13 bit 7. Without it an enabled interrupt is never acknowledged and the request
    // stands, so the handler is re-entered for ever.
    output wire interrupt_ack,
    // The byte now on the read bus disagrees with the parity that was stored
    // beside it. Added at the end of the list on purpose: every instantiation
    // of this module connects its ports positionally.
    input wire parity_error,
    // This cycle's bus latch is a device READ rather than the CPU latching its
    // own write data - see bus_read_cycle below.
    output wire dbg_bus_read_cycle);

    /*
     * Rising edge triggered registers
     */
    // Microcode pipeline F5/H5/J5/K5/L5/M5 74LS377, E5/D5 74LS174
    reg [55:0] pipeline;
    // work_address B2/C2/B5/C5 74LS669
    reg [15:0] work_address;
    // memory_address B1/C1/B6/C6 74LS669
    reg [15:0] memory_address;
    // register_index C13 74LS377
    reg [7:0] register_index;
    // result_register C9 74LS377
    reg [7:0] result_register;
    // swap_register C12/C11 74LS173
    reg [7:0] swap_register;
    // flags_register J9 74LS378
    reg [7:0] flags_register;
    // condition_codes M12 74LS378
    reg [3:0] condition_codes;
    // bus_read, bus_write A11/A12 Am2907
    reg [7:0] bus_read, bus_write;
    // Whether the byte in bus_read came back disagreeing with its parity, held
    // from the read that latched it until the next one - which is what k9 == 6
    // reports.
    reg parity_fault;
    // e7 == 3 latches whatever is on the bus, but that is only a device read
    // when h11 == 1 began one; the rest are the CPU latching its own write data,
    // which is what the emulator's sys_write_latch covers. Measured over the
    // quick tests: h11 == 1 fires 433 times and e7 == 3 fires 466, so 40 of
    // those latches are not reads. A device whose read has a side effect - and
    // on this bus that is every one of them - must not see those 40. The MUX's
    // data register was seeing them and throwing away a received character each
    // time, which is input disappearing while the machine is busiest.
    reg bus_read_cycle;
    // interrupt_level D9 74LS378, only four bits used
    reg [3:0] interrupt_level;
    // Page table base register D11 74LS378
    reg [2:0] page_table_base;
    // write delay
    reg writEnDelayed;

    // Where we are in a DMA byte transfer; see dma_step below.
    reg [1:0] dma_phase;

    // Page table B9/B10 93L422 - 2 x 256 x 4bit RAM
    // These map to LUTRAM, but only because they are written from their own always
    // block further down. Writing them from the main block, which has an asynchronous
    // reset, stops yosys mapping them and it falls back to plain registers: about 4700
    // LUT4s instead of 32 LUTRAM cells, which is more than the Tang Nano 9K has.
    reg [3:0] page_table_lo[0:255];
    reg [3:0] page_table_hi[0:255];


    // Decoders
    // d2d3 is decoded before pipeline, but outputs are registered.
    wire [3:0] d2d3 = pipeline[3:0];
    wire [1:0] e7 = pipeline[14:13];
    wire [2:0] h11 = pipeline[12:10];
    wire [2:0] k11 = pipeline[9:7];
    wire [2:0] e6 = pipeline[6:4];

    // Internal Busses
    reg [7:0] DPBus;
    reg [7:0] FBus;

    // Microcode conditional subroutine calls
    reg jsr_;

    reg [15:0] cycle_counter;

    integer i;
    initial begin
        cycle_counter = 0;
        for (i=0; i<256; i=i+1) begin
            page_table_lo[i] = 0;
            page_table_hi[i] = 0;
        end
    end

    // The mapping RAM is one flat 256 entry array addressed as table * 32 + page, which
    // is the order diag uses when it writes the whole table through the window below.
    // The base therefore has to be the high three bits and the virtual page the low
    // five; the other way round is self consistent for translation but puts every
    // windowed write in the wrong entry.
    wire [7:0] page_address = { page_table_base, memory_address[15:11] };
    wire [7:0] page_table_out = { page_table_hi[page_address], page_table_lo[page_address] };

    // Bit 7 of a page entry is not an address bit. It marks the page write-tracked:
    // reads and writes both pass through to the page underneath, and a write also traps
    // to level 15. The physical address is 18 bits, entry[6:0] : va[10:0].
    //
    // It is kept as virtual_address[18] because that is the PA18 the microcode tests as
    // a trap condition, in jsr_ and in the sequencer OR inputs. What it must not do is
    // reach the address bus, which it did: an entry with bit 7 set addressed a page
    // 0x40000 away from the real one. The mapping RAM test writes every value into
    // every entry, so it hit one at a fixed point thousands of passes in.
    wire [18:0] virtual_address = { page_table_out[7], page_table_out[6:0], memory_address[10:0] };
    assign addressBus = { 1'b0, virtual_address[17:0] };

    /*
     * The bottom of physical memory is the CPU's own state rather than the bus:
     * 0x000 to 0x0ff is the register file. 0x100 to 0x1ff is NOT: it is ordinary RAM.
     */

    // There is no memory mapped window onto the mapping RAM. The reference manual says
    // physical 0x100..0x1ff is ordinary RAM and that software reaches the page file only
    // through the PAGE instruction, and that is what the microcode does: the store reads
    // an entry onto the DP bus with d2d3 == 8 and the load writes one with k11 == 5, both
    // indexed by { page_table_base, memory_address[15:11] }.
    //
    // A window used to live here and it corrupted the table. k11 == 7 is the bus write
    // strobe, not a mapping RAM select, so every ordinary store whose address fell in
    // 0x100..0x1ff wrote the page file as well as memory. Tracing one PAGE store showed
    // the pair on every byte: a bogus "window" write of the entry followed by the real
    // bus write of the same byte to 0x00100. That is why diag's mapping test failed with
    // table entry 0 stuck at 00 while its reference copy expected 01 - the snapshot
    // buffer diag keeps at 0x100 lives at exactly the addresses the window claimed.

    // Register space read mux. Addresses with virtual_address[18:8] == 0 are the CPU's
    // own register space and are read back internally rather than from the bus.
    wire [7:0] dataInCPU = virtual_address[18:8] == 0 ? dataOutBus : dataInBus;

    /*
     * Instrumentation
     */

    reg [10:0] uc_rom_address_pipe;
    assign instruction_start = uc_rom_address_pipe == 11'h101;
    wire pc_increment = h11 == 5;   // instrumentation only; was implicitly declared

    `ifdef TRACE_I
        Instructions inst_map();
    `endif

    assign dataOutBus = bus_write;

    // 6309 ROM
    wire [7:0] map_rom_address = DPBus;
    wire [7:0] map_rom_data;
    MapROM map_rom(map_rom_address, map_rom_data);

    // Microcode ROM(s)
    wire [10:0] uc_rom_address;
    wire [55:0] uc_rom_data;
    CodeROM uc_rom(clock, uc_rom_address, uc_rom_data);

    // Synchronous Register RAM
    wire bit53 = pipeline[53];
    wire reg_low_select = bit53;
    // High/low register select, C14 74LS157 mux, D10 74LS02 NOR gate
    wire [3:0] reg_addr_hi = pipeline[55] ? interrupt_level : register_index[7:4];
    wire [7:0] reg_ram_addr = { reg_addr_hi, register_index[3:1], ~(reg_low_select | register_index[0]) };
    wire rr_write_en = k11 == 4;
    wire [7:0] reg_ram_data_in = result_register;
    wire [7:0] reg_ram_data_out;
    RegisterRAM reg_ram(clock, enable, rr_write_en, reg_ram_addr, reg_ram_data_in, reg_ram_data_out);

    // Sequencer shared nets

    wire seq_fe = pipeline[27] & jsr_;
    wire seq_pup = pipeline[28];
    wire seq_zero = !reset;

    // The two 74LS259 addressable latches holding machine state. Both are written from
    // the B register select field: alu_b[3:1] picks the latch bit and alu_b[0] is the
    // value, which is why the wiki lists their functions in pairs. K11 output 3 enables
    // F11 and output 2 enables M13.
    //
    //   F11  0 interrupt enable   1 address bus enable   2 DMA address increment
    //        3 increment/decrement 4 DMA control         5 parity odd/even
    //        6 parity check enable 7 DMA enable
    //   M13  0,1 DMA              2 timer (RTC) enable   4 run/halt front panel light
    //        5 timer reset        6 ABT front panel light 7 interrupt acknowledge
    reg [7:0] f11;
    // Up/down direction for the MAR and work AR, the two 74LS669 counter pairs.
    wire count_up = f11[3];

    // Transfers happen when F11 bit 4 is set and bit 2 clear, which is what
    // Meisaka's emulator tests as (busctl & 20) == 16 before stepping a
    // registered DMA device. One byte per enabled cycle for as long as the
    // device is asking.
    // A transfer runs while the DMA control bit is set, the DMA address increment
    // is not inhibited, and a device is actually asking - the same
    // (busctl & 0x14) == 0x10 condition Meisaka's emulator uses.
    wire dma_on = f11[4] & ~f11[2] & dma_req & ~dma_hold;

    // A byte moves every three enabled cycles, because that is how long one of
    // this machine's bus cycles takes to resolve:
    //
    //   0  the address is already on the bus; set up the write data
    //   1  writeEnBus is still the previous cycle's writEnDelayed
    //   2  writeEnBus is asserted and the memory has answered, so this is where
    //      the byte lands or is taken, and where the counters may step
    //
    // Two phases is not enough and the failure is quiet: writeEnBus is a
    // registered output, so it goes high one cycle after writEnDelayed is set,
    // by which time a two phase engine has already stepped the address and every
    // byte is written one place too far along. The microcode never notices this
    // because it holds the MAR still across its own bus cycles.
    // Nothing moves once the work address has reached its end value: the
    // device sees dma_end and drops its request instead. This matches the
    // emulator, which passes atend to the device and lets it call end() rather
    // than transferring a byte it was never asked for.
    assign dma_step = dma_on & enable & (dma_phase == 2) & ~dma_end;

    // The byte under the address the MMU has already translated, and the end of
    // the transfer: the work address counting up through 0xffff is what stops it,
    // so software sets it to the negated length. The device sees this before the
    // step that would take it past the end.
    assign dma_rdata = dataInCPU;
    assign dma_end = (work_address == 16'hffff);
    // Set by reset and cleared the first time the status source at d2d3 == 11 is read,
    // which is how the microcode learns it has just come out of reset.
    reg resetting;
    reg [7:0] m13;
    // Defined before the first reset: f11[3] now selects the address step direction, and
    // an X there propagates straight into the address registers.
    initial begin
        f11 = 0;
        parity_fault = 0;
        bus_read_cycle = 0;
        m13 = 0;
    end

    // Interrupt support. Bit 0 of the F11 latch is the interrupt enable: the microcode
    // for EI writes a 1 to it and DI writes a 0, which is how the bit was identified.
    // It used to be an unassigned register, so interrupts could never fire at all.
    wire int_enabled = f11[0];

    // A DMA interrupt only reaches the microcode while interrupts are enabled and
    // the machine is running at a level below 2 - a level 0 or 1 routine is not
    // interruptible by a disk finishing. This is the emulator's dmaint exactly.
    wire dmaint = int_enabled & (interrupt_level < 2) & dma_int;

    // The real time clock. M13 bit 5 arms the tick generator and M13 bit 2 lets
    // its output through to the conditions - two different bits, which is easy
    // to miss. Software acknowledges a tick by clearing bit 5, which is why
    // there is no explicit clear anywhere.
    //
    // 8333 enabled cycles is what Meisaka's emulator counts, and at the CPU's
    // 5MHz that is 600Hz. Nothing in this design depends on the rate being
    // right, but the operating system's idle loop depends on there being one at
    // all: without a tick it waits for ever, having reached the point of asking.
    localparam integer RTC_TICKS = 8333;
    reg [13:0] rtc_counter;
    reg rtc;
    // Meisaka's emulator arms the generator on M13 bit 5 and gates its output on
    // bit 2. Implemented faithfully, the operating system hangs: it reaches a
    // microcode loop at 0x737 that polls d2d3 12 and waits for a tick that never
    // comes, because nothing has set those bits by then. Free running, it gets
    // past that loop and on into other microcode. So the gating is wrong
    // somewhere - either the bit numbering, or when the bits are set - and until
    // that is understood a tick that always runs is the more useful of the two
    // wrong answers. Nothing else in this design reads it.
    wire rtc_active = RTC_GATED ? (rtc & m13[2]) : rtc;

    // The level of the interrupt that was last *acknowledged*, which is what the
    // interrupt entry microcode reads back through d2d3 12 to find out who
    // interrupted it. Latched from the requesting device when M13 bit 7 - the
    // acknowledge - goes up, and cleared when it comes down, exactly as the
    // emulator's reqlevel is. This is not the same thing as irq_number, which is
    // the level the MUX has been *configured* with and is there all the time;
    // putting that here instead tells the microcode an interrupt is pending for
    // ever and the machine never completes another instruction.
    reg [3:0] reqlevel;

    /*
     * Am2909/2911 Microsequencers
     */

    // Sequencer 0 (microcode address bits 3:0)
    wire [3:0] seq0_din = pipeline[19:16];
    wire [3:0] seq0_rin = FBus[3:0];
    reg [3:0] seq0_orin;
    wire seq0_s0 = ~(pipeline[29] & jsr_);
    wire seq0_s1 = ~(pipeline[30] & jsr_);
    wire seq0_cin = 1;
    reg seq0_re;
    wire [3:0] seq0_yout;
    wire seq0_cout;

    Am2909 seq0(clock, enable, seq0_din, seq0_rin, seq0_orin, seq0_s0, seq0_s1, seq_zero, seq0_cin,
        seq0_re, seq_fe, seq_pup, seq0_yout, seq0_cout);

    // Case control
    wire case_ = pipeline[33];

    // Sequencer 1 (microcode address bits 7:4)
    wire [3:0] seq1_din = pipeline[23:20];
    wire [3:0] seq1_rin = FBus[7:4];
    reg [3:0] seq1_orin;
    wire seq1_s0 = ~(pipeline[31] & jsr_);
    wire seq1_s1 = ~(~(pipeline[54] & ~pipeline[32]) & jsr_);
    wire seq1_cin = seq0_cout;
    reg seq1_re;
    wire [3:0] seq1_yout;
    wire seq1_cout;

    Am2909 seq1(clock, enable, seq1_din, seq1_rin, seq1_orin, seq1_s0, seq1_s1, seq_zero, seq1_cin,
        seq1_re, seq_fe, seq_pup, seq1_yout, seq1_cout);


    // Sequencer 2 (microcode address bits 10:8)
    wire [3:0] seq2_din = { 1'b0 , pipeline[26:24] }; // only 3 bits are used
    wire [3:0] seq2_rin;
    wire seq2_s0 = ~(pipeline[31] & jsr_);
    wire seq2_s1 = ~(pipeline[32] & jsr_);
    wire seq2_cin = seq1_cout;
    wire seq2_re = 1;
    wire [3:0] seq2_yout;
    wire seq2_cout;

    Am2911 seq2(clock, enable, seq2_din, seq2_s0, seq2_s1, seq_zero, seq2_cin, seq2_re, seq_fe,
        seq_pup, seq2_yout, seq2_cout);

    assign uc_rom_address = { seq2_yout, seq1_yout, seq0_yout };
    assign dbg_memory_address = memory_address;
    assign dbg_uc_address = uc_rom_address;
    assign dbg_page_table_base = page_table_base;
    assign dbg_page_table_out = page_table_out;
    assign dbg_d2d3 = d2d3;
    assign dbg_f11 = f11;
    // One microcode word can both begin the read and latch it, so take the live
    // decode as well as the flag.
    assign dbg_bus_read_cycle = bus_read_cycle | (h11 == 3'd1);
    assign dbg_entry0 = { page_table_hi[{page_table_base, 5'b00000}],
                          page_table_lo[{page_table_base, 5'b00000}] };
    wire pt_uc  = enable && reset == 0 && k11 == 5;
    assign dbg_e0_write = pt_uc && page_address == { page_table_base, 5'b00000 };
    assign dbg_e0_value = result_register;
    assign dbg_e0_via_window = 1'b0;
    assign dbg_pt_write = pt_uc;
    assign dbg_pt_index = page_address;
    assign dbg_pt_value = result_register;
    assign dbg_pt_via_window = 1'b0;
    assign dbg_e7 = e7;
    assign dbg_data_in = dataInCPU;
    assign interrupt_ack = m13[7];

    /*
     * Am2901 bit slice Arithmetic Logic Units (ALUs)
     */
    // ALU shared nets
    wire [3:0] alu_a = pipeline[50:47];
    wire [3:0] alu_b = pipeline[46:43];
    wire [2:0] alu_src = pipeline[36:34];
    wire [2:0] alu_op = pipeline[39:37];
    wire [2:0] alu_dest = pipeline[42:40];

    // F9 Am2901 ALU 0 (bits 3:0)
    wire [3:0] alu0_din = DPBus[3:0];
    reg alu0_cin;
    wire [3:0] alu0_yout;
    wire alu0_cout;
    wire alu0_f0;
    wire alu0_f3;
    wire alu0_ovr;
    reg alu0_q0_in;
    wire alu0_ram0_in, alu0_q3_in, alu0_ram3_in;
    wire alu0_q0_out, alu0_ram0_out, alu0_q3_out, alu0_ram3_out;
    Am2901 alu0(clock, enable, alu0_din, alu_a, alu_b, alu_src, alu_op, alu_dest, alu0_cin,
        alu0_yout, alu0_cout, alu0_f0, alu0_f3, alu0_ovr,
        alu0_q0_in, alu0_ram0_in, alu0_q3_in, alu0_ram3_in,
        alu0_q0_out, alu0_ram0_out, alu0_q3_out, alu0_ram3_out);

    // F7 Am2901 ALU 1 (bits 7:4)
    wire [3:0] alu1_din = DPBus[7:4];
    wire alu1_cin = alu0_cout;
    wire [3:0] alu1_yout;
    wire alu1_cout;
    wire alu1_f0;
    wire alu1_f3;
    wire alu1_ovr;
    wire alu1_q0_in, alu1_ram0_in, alu1_q3_in;
    wire alu1_q0_out, alu1_ram0_out, alu1_q3_out, alu1_ram3_out;
    reg alu1_ram3_in;
    Am2901 alu1(clock, enable, alu1_din, alu_a, alu_b, alu_src, alu_op, alu_dest, alu1_cin,
        alu1_yout, alu1_cout, alu1_f0, alu1_f3, alu1_ovr,
        alu1_q0_in, alu1_ram0_in, alu1_q3_in, alu1_ram3_in,
        alu1_q0_out, alu1_ram0_out, alu1_q3_out, alu1_ram3_out);

    wire alu_i7 = alu_dest[1];

    assign alu1_q0_in = alu0_q3_out;
    assign alu1_ram0_in = alu0_ram3_out;
    assign alu0_q3_in = alu1_q0_out;
    assign alu0_ram3_in = alu1_ram0_out;

    assign alu1_q3_in = alu0_ram0_out;
    assign alu0_ram0_in = alu1_q3_out;

    // Muxes

    // J10 Link/carry mux 74LS151
    wire j10_enable = pipeline[21];
    wire [2:0] j10 = pipeline[24:22];
    reg cc_l;

    // J11 Fault/overflow mux 74LS151
    wire j11_enable = pipeline[18];
    wire [2:0] j11 = { flags_register[2], pipeline[20:19] };
    reg cc_f;

    // J12 Minus/sign mux 74LS153
    wire [1:0] j12 = pipeline[17:16];
    reg cc_m, cc_v;

    // F6 ALU carry in mux 74LS153 (half used)
    // H6 ALU shift mux
    wire [1:0] f6h6 = pipeline[52:51];

    // K9 JSR mux 74151
    wire k9_enable = pipeline[15];
    wire [2:0] k9 = pipeline[18:16];

    // J13 OR0/OR1 mux 74LS153
    wire [1:0] j13 = pipeline[21:20];

    // K13 OR2/OR3 mux 74LS153
    wire [1:0] k13 = pipeline[23:22];

    // Constant (immediate data)
    wire [7:0] constant = ~pipeline[16+7:16];

    wire bad_page_n = ~(virtual_address[18:13] == 6'h3f && virtual_address[11] == 1);
    // The bottom of physical memory is the CPU's own register file, and this
    // says whether an access lands there: physical page zero, offset below
    // 0x100. Zero means all SEVEN bits of the page entry, and virtual_address[17]
    // - the entry's bit 6 - used to be missing from the product, so any page
    // whose number was exactly 0x40 looked like page zero and every access to it
    // was answered out of the register file instead of memory.
    //
    // That is not a corner case. The operating system sizes memory by mapping
    // each physical page in turn into virtual page 31 and probing it, walking
    // the page number up from 0x1e; 0x40 is the first value with bit 6 set, and
    // the boot died there every time while the reference walked on to 0x7d.
    wire reg_n = ~(~virtual_address[12] & ~(memory_address[9] | memory_address[10]) &
        ~(virtual_address[15] | virtual_address[16]) & ~memory_address[8] &
        ~virtual_address[17] &
        ~(virtual_address[13] | virtual_address[14]) & ~(virtual_address[11] | virtual_address[12]));
    wire not_mem = ~(bad_page_n & reg_n);

    // Guideline #3: When modeling combinational logic with an "always" 
    //              block, use blocking assignments.
    always @(*) begin
        jsr_ = 1; // Inverted output
        if (k9_enable == 0) begin
            case (k9)
                // Bus busy. Nothing on this board ever holds the bus, so the
                // answer is always "not busy" - which is jsr_ low, because jsr_
                // is the inverted output and the emulator's k9_com for this
                // select is a hardwired one. Leaving it high stalls the DMA wait
                // loop for ever: that loop is two words long and this is the
                // only condition in it.
                0: jsr_ = 0;
                1: jsr_ = register_index[0] | register_index[4];
                2: jsr_ = ~register_index[0];
                3: jsr_ = ~not_mem; // NOT.MEM
                4: jsr_ = reg_n & ~virtual_address[18];
                // A device is asking for a DMA transfer. This is Meisaka's
                // emulator's dma_13, raised by the device and dropped when the
                // transfer reaches its end; its k9_com is inverted on the way
                // out, which is what jsr_ already is.
                5: jsr_ = ~dma_req;
                // A byte read back disagreeing with the parity stored beside
                // it. F11 bit 6 is the check enable: with it clear the answer is
                // always "no error", which is what this used to be unconditionally.
                // The emulator computes b15a as `memfault ^ 1` when checking is
                // on and 1 when it is off, and its k9_com is inverted on the way
                // out, so this is that expression directly.
                //
                // Without it the operating system's startup self test - which
                // writes a byte with deliberately wrong parity through F11 bit 5
                // and reads it back expecting to fault - never sees the error it
                // planted, prints PARITY CIRCUITRY INOPERATIVE and stops.
                6: jsr_ = ~parity_fault;
                7: begin
                    // Anything at all wanting attention: a DMA request, a DMA
                    // interrupt, or an ordinary one.
                    //
                    // The clock tick belongs here too - the emulator has it -
                    // but putting it in makes the machine worse, not better,
                    // and measurably so: the operating system's bootstrap goes
                    // from running loaded code to abandoning the load and
                    // re-prompting. Raising an interrupt this design cannot then
                    // service is worse than not raising it. The tick is still
                    // generated and still readable through d2d3 12, which is how
                    // software polls for it; this line goes back in when the
                    // interrupt entry path is finished.
                    // A request only interrupts if its level is HIGHER than
                    // the level the machine is already running at. Without that
                    // test a device that keeps asking - and the MUX asks once
                    // per character it finishes transmitting - re-enters its own
                    // handler the instant the handler returns, so the foreground
                    // never runs again. Meisaka's emulator gates both the
                    // request and the acknowledge on `dev.getlevel() > cpl`, and
                    // dmaint just below has always had the same kind of test.
                    jsr_ = ~(dma_req | dmaint |
                             (int_enabled & ~int_reqn
                              & (irq_number > interrupt_level))); // Interrupt
                   end
            endcase
        end

        // Carry in
        alu0_cin = 0;
        case (f6h6)
            0: alu0_cin = 0;
            1: alu0_cin = 1;
            2: alu0_cin = flags_register[3];
            3: alu0_cin = 0;
        endcase

        // Rotate
        alu1_ram3_in = 0;
        alu0_q0_in = 0;
        if (alu_i7 == 0) begin
            // Right shift
            case (f6h6)
                0: alu1_ram3_in = alu1_f3;
                1: alu1_ram3_in = flags_register[3];
                2: alu1_ram3_in = alu0_q0_out;
                3: alu1_ram3_in = alu1_cout;
            endcase
        end else begin
            // Left shift
            case (f6h6)
                0: alu0_q0_in = 0;
                1: alu0_q0_in = flags_register[3];
                2: alu0_q0_in = alu1_f3;
                3: alu0_q0_in = 1;
            endcase
        end

        cc_l = 0;
        if (j10_enable == 0) begin
            case (j10)
                0: cc_l = condition_codes[3];
                1: cc_l = ~condition_codes[3];
                2: cc_l = flags_register[3];
                3: cc_l = 1;
                4: cc_l = result_register[4];
                5: cc_l = alu1_ram3_in;
                6: cc_l = alu_i7 ? alu1_q3_out : alu0_ram0_out;
                7: cc_l = alu0_q0_out;
            endcase
        end

        cc_f = 0;
        if (j11_enable == 0) begin
            case (j11)
                0: cc_f = result_register[5];
                1: cc_f = 1;
                2: cc_f = condition_codes[2];
                3: cc_f = 0;
                4: cc_f = result_register[5];
                5: cc_f = 1;
                6: cc_f = condition_codes[2];
                7: cc_f = 1;
            endcase
        end

        cc_m = 0;
        cc_v = 0;
        case (j12)
            0: begin cc_m = condition_codes[1]; cc_v = 0; end
            1: begin cc_m = flags_register[1]; cc_v = flags_register[0]; end
            2: begin cc_m = result_register[6]; cc_v = result_register[7]; end
            3: begin cc_m = flags_register[1]; cc_v = flags_register[0] & flags_register[5]; end
        endcase

        seq0_orin = 0;
        if (case_ == 0) begin
            case (j13)
                0: begin seq0_orin[0] = flags_register[1]; seq0_orin[1] = flags_register[0]; end
                1: begin seq0_orin[0] = flags_register[4]; seq0_orin[1] = flags_register[2]; end
                2: begin seq0_orin[0] = ~virtual_address[18]; seq0_orin[1] = bad_page_n; end // OR0 = PA18; OR1 = BAD.PG;
                3: ; // Not used
            endcase
            case (k13)
                // OR2 = INT.EN, OR3 = the Link. Both, not one: this used to set
                // only bit 3, with a comment saying OR2 that did not match the
                // code, and the disagreement was recorded as an open question.
                // Meisaka's emulator settles it - "|4 IF INT_EN, |8 IF
                // CCR.Carry (Link)", neither inverted - and a missing OR bit
                // does not fail loudly: it silently sends the sequencer to a
                // different microcode word every time a k13 == 0 branch is
                // taken with interrupts enabled.
                0: begin
                    seq0_orin[2] = int_enabled;
                    seq0_orin[3] = condition_codes[3];
                   end
                // OR2 = LVL15.Q; OR3 = INTR.Q. Both are the *absence* of the
                // thing, which is how the interrupt entry microcode tells a DMA
                // interrupt from an ordinary one.
                1: if (K13_INTERRUPTS) begin
                    seq0_orin[2] = ~dmaint;
                    seq0_orin[3] = ~(int_enabled & ~int_reqn);
                   end
                // OR2 = E10.6.Q; OR3 = DMA13.Q. Note bit 3 really is OR3: case 0
                // above puts the link/carry there, which is where the emulator
                // puts it too, whatever that line's comment says.
                2: seq0_orin[3] = ~dma_req;
                3: ; // Not used
            endcase
        end

        seq1_orin = 0;

        seq0_re = 1;
        seq1_re = 1;
        if (e6 == 6) begin
            seq0_re = 0;
            seq1_re = 0;
        end

        // Datapath muxes
        DPBus = 0;

        // 74LS139 (D2), 74LS138 (D3)
        case (d2d3)
            0: DPBus = swap_register;
            1: DPBus = reg_ram_data_out;
            2: DPBus = { ~memory_address[15:12], memory_address[11:8] };
            3: DPBus = memory_address[7:0];
            4: DPBus = swap_register;
            5: DPBus = reg_ram_data_out;
            6: DPBus = { ~memory_address[15:12], memory_address[11:8] };
            7: DPBus = memory_address[7:0];
            // The mapping RAM read back. This is not the raw entry: the physical page
            // number is the entry's low seven bits plus a synthesised top bit that is
            // set when bits 6:4 are all ones, which is how a page reaches the I/O
            // region. Meisaka's emulator computes exactly this and calls it pgaddr.
            // The entry's own bit 7 is the write-tracked flag and reaches the DP bus
            // through d2d3 == 11 instead.
            8: DPBus = { page_table_out[6:4] == 3'b111, page_table_out[6:0] };
            // Condition codes in the top nibble, inverted, and the front panel sense
            // switches in the low nibble, which are not. The bootstrap PROM's first
            // instruction is BS1, testing sense switch 1 to decide whether the diag
            // board takes over.
            9: DPBus = { ~condition_codes[0], ~condition_codes[1], ~condition_codes[2],
                         ~condition_codes[3], sense_switches };
            10: DPBus = bus_read;
            // Machine status. From Meisaka's emulator: the current level in the high
            // nibble, the DMA interrupt in bit 3, a constant one in bit 2, a
            // reset-just-happened flag in bit 1 that clears when it is read, and the
            // page's write-tracked flag inverted in bit 0. This used to be a constant
            // 0x0e with only bit 0 real, which left the DMA and reset bits stuck high.
            // The PAGE store shifts bit 0 into the top of each byte it writes.
            11: DPBus = { interrupt_level, dmaint, 1'b1,
                          resetting, ~page_table_out[7] };
            // The acknowledged interrupt level in the high nibble, the front panel
            // switches in the middle, and the clock tick in bit 0. The emulator
            // calls the first field sysint and assigns it `reqlevel', which is
            // set only when an interrupt has actually been acknowledged - and
            // microcode word 0x655 loads the CPU's interrupt level straight out
            // of this source, so a wrong value here sends the machine to a level
            // that was never prepared.
            //
            // This used to be a hardcoded zero, with a comment saying it would
            // stay that way until an acknowledged level was tracked. It has been
            // tracked since reqlevel was added; the comment outlived the reason
            // for it. What must NOT go here is irq_number, the level the MUX has
            // been *configured* with, which is a static setting software writes
            // once: that told the microcode an interrupt was pending for ever
            // and hung the machine at 0x73b. reqlevel is zero except between an
            // acknowledge and its release, which is the whole difference.
            // The switches read zero, as they do in the emulator.
            12: DPBus = { reqlevel, 3'b000, rtc_active };
            13: DPBus = constant;
            14: ;
            15: ;
        endcase

        FBus = { alu1_yout, alu0_yout };
        if (h11 == 6) begin
            FBus = map_rom_data;
        end
    end

    // Guideline #1: When modeling sequential logic, use nonblocking 
    //              assignments.
    // Synchronous reset. This used to be asynchronous, which put reset on the
    // asynchronous CLEAR pin of 159 flip flops spread across the die, reached over
    // general routing. Flops then leave reset at slightly different times and the core
    // can start in an inconsistent state, which is unrepeatable by nature. As ordinary
    // data the reset is covered by normal setup and hold analysis.
    always @(posedge clock) begin
        if (reset == 1) begin
            resetting <= 1;
            work_address <= 0;
            memory_address <= 0;
            register_index <= 0;
            result_register <= 0;
            swap_register <= 0;
            condition_codes <= 0;
            rtc_counter <= 0;
            rtc <= 0;
            reqlevel <= 0;
            flags_register <= 0;
            writeEnBus <= 0;
            writEnDelayed <= 0;
            dma_phase <= 0;
            pipeline <= 56'h42abc618b781c0; // First microcode word. Synth prefers it this way.
            uc_rom_address_pipe <= 0;
            interrupt_level <= 0;
            bus_read <= 0;
            parity_fault <= 0;
            bus_read_cycle <= 0;
            bus_write <= 0;
            page_table_base <= 0;
            f11 <= 0;
            m13 <= 0;
        end else if (enable) begin
            pipeline <= uc_rom_data;
            uc_rom_address_pipe <= uc_rom_address;
            if (instruction_start == 1) begin
                cycle_counter <= 1;
            end else begin
                cycle_counter <= cycle_counter + 1;
            end

            `ifdef TRACE_I
                if (uc_rom_address_pipe == 11'h103) begin
                    $display("%x F:%x C:%x L:%x A:%x%x B:%x%x X:%x%x Y:%x%x Z:%x%x S:%x%x C:%x%x | %x%s",
                        virtual_address-1, flags_register, condition_codes, interrupt_level,
                        reg_ram.memory[1], reg_ram.memory[0],
                        reg_ram.memory[3], reg_ram.memory[2],
                        reg_ram.memory[5], reg_ram.memory[4],
                        reg_ram.memory[7], reg_ram.memory[6],
                        reg_ram.memory[9], reg_ram.memory[8],
                        reg_ram.memory[11], reg_ram.memory[10],
                        reg_ram.memory[13], reg_ram.memory[12],
                        DPBus, inst_map.instruction_map[DPBus]);
                end
            `endif
            `ifdef TRACE_UC
                if (jsr_ == 0) begin
                    $display("        uC %x JSR %x%x%x", uc_rom_address_pipe, seq2_din, seq1_din, seq0_din);
                end
                if (case_ == 0) begin
                    $display("        uC %x OR %x -> %x", uc_rom_address_pipe, seq0_orin, uc_rom_address_pipe | seq0_orin);
                end
                if (k11 == 3) begin
                    $display("        uC F11.%d <= %d", alu_b[3:1], alu_b[0]);
                end
            `endif
            `ifdef TRACE_WR
                if (writeEnBus == 1) begin
                    $display("    WR %x %x", memory_address, bus_write);
                end
            `endif
            `ifdef TRACE_RD
                if (e7 == 3) begin
                    $display("    RD %x %x", memory_address, dataInCPU);
                end
            `endif

            // 74LS138
            case (e6)
                0: ;
                1: result_register <= FBus;
                2: register_index <= FBus; // uC bit 53 might simplify 16 bit register write
                3: interrupt_level <= FBus[7:4]; // load D9
                4: page_table_base <= FBus[2:0]; // load page table base register
                5: memory_address <= work_address;
                6: ; // load AR on 2909s, see above
                7: condition_codes <= { cc_l, cc_f, cc_m, cc_v } ; // load condition code register M12
            endcase

            // 74LS138 (only half used)            
            case (e7)
                0: ;
                1: ;
                2: flags_register <= { 1'b0, 1'b0, flags_register[0], alu0_cout, alu1_cout, alu1_ovr, alu1_f3, alu0_f0 & alu1_f0 };
                // The byte and, beside it, whether it disagreed with the parity
                // stored with it. Latched here rather than read combinationally
                // at the moment the microcode tests it, because by then the
                // address register has usually moved on to the next byte and the
                // answer would be about the wrong one. The emulator latches its
                // b15a in exactly this cycle for the same reason.
                3: begin
                    bus_read <= dataInCPU;
                    // Only a READ says anything about parity. e7 == 3 also
                    // latches the bus on a write cycle, and the emulator leaves
                    // b15a alone for those - it updates it inside the read arm
                    // and nowhere else. Updating it on a write is actively
                    // wrong: writing a byte that currently holds bad parity
                    // would latch a fault from the contents being overwritten,
                    // and putting good parity back over a deliberately poisoned
                    // byte is exactly what the operating system's self test does
                    // when it has finished.
                    if (bus_read_cycle) parity_fault <= f11[6] & parity_error;
                    bus_read_cycle <= 0;
                   end
            endcase

            // 74LS138
            if (d2d3 == 11) resetting <= 0;

            case (h11)
                0: ;
                1: bus_read_cycle <= 1;     // Begin bus read cycle
                2: ; // Begin bus write cycle
                3: // Load work_address high byte
                    begin
                        work_address[15:8] <= result_register;
                        if (e6 == 5) begin
                            work_address[15:8] <= memory_address[15:8];
                        end
                    end
                // The MAR and work AR are 74LS669s, which are up/down counters, and the
                // direction is F11 bit 3 - the same addressable latch whose bit 0 is the
                // interrupt enable. Meisaka's emulator calls the latch busctl and reads
                // the direction as (busctl & 8), counting down when it is clear, which
                // is what a stack push needs.
                4: work_address <= count_up ? work_address + 1 : work_address - 1;
                5: memory_address <= count_up ? memory_address + 1 : memory_address - 1;
                6: ; // Select FBus source (combinational)
                7: swap_register <= { DPBus[3:0], DPBus[7:4] };
            endcase

            // The clock tick. Armed by M13 bit 5; clearing that bit is also how
            // software acknowledges a tick, so there is no separate clear.
            if (RTC_GATED && !m13[5]) begin
                rtc <= 0;
                rtc_counter <= 0;
            end else begin
                // Reading the status byte takes the tick down. Ungated there is
                // no other way to clear it - software acknowledges by clearing
                // M13 bit 5, and ungated that branch never runs - so without
                // this the flag latches high after the first tick and stays
                // there for ever. It is a level, not a tick, and microcode that
                // waits for it to go away waits for ever.
                if (d2d3 == 12) rtc <= 0;
                if (rtc_counter == RTC_TICKS - 1) begin
                    rtc_counter <= 0;
                    rtc <= 1;
                end else rtc_counter <= rtc_counter + 1;
            end

            writeEnBus <= writEnDelayed;
            writEnDelayed <= 0;

            // 74LS138
            case (k11)
                0: ;
                1: ; // Not a page file write: doing that breaks the instruction test
                2: begin
                    m13[alu_b[3:1]] <= alu_b[0];   // M13 'LS259 enable
                    // Bit 7 is the interrupt acknowledge. Taking it up latches
                    // the level of whoever is requesting; letting it down clears
                    // it. Without this the entry microcode asks d2d3 12 who
                    // interrupted it, is told nobody, and goes round for ever -
                    // which is what a machine whose lights blink after the
                    // operating system enables interrupts is doing.
                    if (alu_b[3:1] == 3'd7) begin
                        if (alu_b[0] && !m13[7]) reqlevel <= irq_number;
                        else if (!alu_b[0] && m13[7]) reqlevel <= 0;
                    end
                   end
                3: // F11 addressable latch: machine state and bus state. The address is
                   // alu_b[3:1] and the data is alu_b[0], as the microcode trace above
                   // already documented.
                    f11[alu_b[3:1]] <= alu_b[0];
                4: ;
                5: ; // Page table write, see the dedicated block below
                6: // Load work_address low byte
                    begin
                        work_address[7:0] <= result_register;
                        if (e6 == 5) begin
                            work_address[7:0] <= memory_address[7:0];
                        end
                    end
                7: begin bus_write <= FBus; writEnDelayed <= 1; end
            endcase

            // The DMA transfer, which happens alongside whatever the microcode is
            // doing - and while a device is asking, the microcode is sitting in a
            // wait loop testing for exactly that. This has to come after the k11
            // case, because anything that sets writEnDelayed must be assigned
            // later than the clear above it.
            dma_phase <= 0;
            if (dma_on && !dma_end) begin
                dma_phase <= (dma_phase == 2) ? 2'd0 : dma_phase + 1;
                if (dma_phase == 0 && dma_device_write) begin
                    bus_write <= dma_wdata;
                    writEnDelayed <= 1;
                end
                if (dma_phase == 2) begin
                    // The byte has landed, or is on dataInCPU to be taken. Step
                    // both counters, in the direction F11 bit 3 gives everything
                    // else.
                    work_address <= count_up ? work_address + 1 : work_address - 1;
                    memory_address <= count_up ? memory_address + 1 : memory_address - 1;
                end
            end
        end
    end

    /*
     * Page table write port.
     *
     * This deliberately lives in its own always block with no asynchronous reset. The
     * reset branch above never touches the page table, so the behaviour is identical,
     * but yosys will only map a memory to LUTRAM when its write port is free of an
     * async reset. Merged into the block above the table costs about 4700 LUT4s and
     * does not fit the device.
     */
    always @(posedge clock) begin
        if (ptinit_write) begin
            page_table_lo[ptinit_addr] <= ptinit_data[3:0];
            page_table_hi[ptinit_addr] <= ptinit_data[7:4];
        end else if (enable && reset == 0 && k11 == 5) begin
            page_table_lo[page_address] <= result_register[3:0];
            page_table_hi[page_address] <= result_register[7:4];
        end
    end
endmodule

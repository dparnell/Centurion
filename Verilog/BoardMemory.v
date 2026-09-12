
/**
 * Board memory for the Tang Nano 9K.
 *
 * The map is the one the Memory module in CPU6TestBench.v provides, which is what
 * diag.txt and inst_test.txt expect: 8K of ROM at 0x08000, 4K of RAM at 0x0b000, 4K of
 * low RAM at 0x00000, the reset vector at 0x3fd00 and the Diag board's DIP switches at
 * 0x3f110. Keep the two in step if either changes.
 *
 * The MUX status at 0x3f200 is deliberately NOT answered here. The testbench fakes it
 * because it has no serial channel; on the board AddressDecode routes that address to
 * the real MUX.
 *
 * The reads are synchronous and deliberately have no clock enable. These are block
 * RAMs, and a block RAM's output is not a register that can be held with a clock
 * enable - see the comment in CodeROM.v for what that costs. The CPU's address is
 * stable for a whole CPU cycle, so the data has settled long before the enabled edge
 * at the end of it. Only the writes are gated, so one bus cycle writes once.
 */
module BoardMemory #(
    // Whether the diag board's ROMs are fitted. They shadow 8K at physical
    // 0x08000, and the operating system loads code there - so with them present
    // those writes go nowhere and the machine dies the moment execution crosses
    // out of 0x7fff. The emulator models the same thing as a checkbox, and its
    // own notes say the diag ROMs have to be off for CENTOS to boot.
    parameter DIAG_ROM = 1,
    // Which program the ROM holds. Overridable so that a testbench or a build
    // can run something other than diag without editing this file; "make
    // PROGRAM=programs/forth.txt" and the +prog= plusarg below both work.
    parameter PROGRAM = "programs/diag.txt"
) (input wire clock, input wire enable, input wire [18:0] address,
    input wire write_en, input wire [7:0] data_in, output wire [7:0] data_out,
    // Parity. The real machine stores a parity bit alongside every byte of RAM
    // and the CPU checks it on every read; F11 bit 5 makes a write store the
    // WRONG parity deliberately, which is the only way to test that the
    // checking circuitry works at all. The operating system does exactly that
    // during startup - it poisons physical 0x144 upward, two bytes at a time,
    // and reads each back expecting a fault - and prints
    // "PARITY CIRCUITRY INOPERATIVE" and gives up if no fault arrives.
    input wire parity_force, output wire parity_bad);

    reg [7:0] rom_cells[0:8191];
    // Nine bits: the byte, and above it the parity bit as it was stored. The
    // ROM and the bootstrap PROM have none - nothing can write them, so nothing
    // can ever have given them wrong parity.
    reg [8:0] ram_cells[0:8191];
    reg [8:0] low_ram_cells[0:4095];
    reg [7:0] boot_cells[0:511];
    // What to store: the byte's own parity, inverted when the CPU is asking for
    // a deliberate error. Reading it back and XOR-ing the two recovers exactly
    // that bit, which is the fault.
    wire stored_parity = (^data_in) ^ parity_force;

    // Any of the programs can go here; they are linked at 0x8000 and the reset vector
    // above jumps to 0x8001. diag.txt reconfigures MUX 0 to 19200 baud, 7 data bits, no
    // parity, one stop bit, so a terminal has to be set to that rather than to the
    // channel's 9600 7E1 power on default.
    integer i;
    reg [8*64:1] progfile;
    initial begin
        $readmemh(PROGRAM, rom_cells);                    // diag is 19200 7N1
        $readmemh("roms/BootROM.txt", boot_cells);
        // A simulation can point this somewhere else without a rebuild, which
        // is what makes assembling a program and running it a one second loop.
        // Hidden from synthesis: yosys cannot resolve $value$plusargs while it
        // re-elaborates this module, which is exactly what setting PROGRAM from
        // the Makefile makes it do.
`ifndef SYNTHESIS
        if ($value$plusargs("prog=%s", progfile))
            $readmemh(progfile, rom_cells);
`endif
        // Zero with correct parity, which is what an emulated machine's memory
        // and parity RAM both start as.
        for (i = 0; i < 8192; i = i + 1) ram_cells[i] = 9'h000;
        for (i = 0; i < 4096; i = i + 1) low_ram_cells[i] = 9'h000;
    end

    wire rom_select     = DIAG_ROM[0] && (address[18:13] == 4);
    // 8K of RAM covering physical 0x0b000 to 0x0cfff. It has to reach 0x0c000 because
    // that is where diag puts its stack, and a stack in unbacked memory is not a quiet
    // failure: CPU6's JSR keeps the return address in X and pushes the *old* X, so with
    // nothing to push to, every call returns with X set to zero. That is what made
    // diag's mapping RAM test fail - its outer loop counts with X.
    wire ram_select     = address[18:12] == 7'h0b || address[18:12] == 7'h0c;
    wire [12:0] ram_addr = { address[12], address[11:0] };
    wire low_ram_select = address[18:12] == 0;
    // The bootstrap PROM, 512 bytes at 0x3fc00. The CPU resets into 0x3fd00, which
    // is offset 0x100 of it.
    wire boot_select    = address[18:9] == 10'h1fe;

    reg [7:0] rom_q, boot_q;
    reg [8:0] ram_q, low_ram_q;

    always @(posedge clock) begin
        rom_q     <= rom_cells[address[12:0]];
        ram_q     <= ram_cells[ram_addr];
        low_ram_q <= low_ram_cells[address[11:0]];
        boot_q    <= boot_cells[address[8:0]];

        if (enable && write_en) begin
            if (ram_select)     ram_cells[ram_addr]          <= { stored_parity, data_in };
            if (low_ram_select) low_ram_cells[address[11:0]] <= { stored_parity, data_in };
        end
    end

    // The selects are combinational rather than registered alongside the data, which is
    // safe for the same reason the reads are: the address does not move within a cycle.
    assign data_out = boot_select             ? boot_q :
                      rom_select              ? rom_q :
                      ram_select              ? ram_q[7:0] :
                      low_ram_select          ? low_ram_q[7:0] : 8'h00;

    // The byte disagrees with the parity that was stored with it. Only the two
    // writable regions can, and only because something asked for it.
    assign parity_bad = (ram_select     && (ram_q[8]     ^ (^ram_q[7:0]))) ||
                        (low_ram_select && (low_ram_q[8] ^ (^low_ram_q[7:0])));
endmodule

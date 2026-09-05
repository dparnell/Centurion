
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
module BoardMemory(input wire clock, input wire enable, input wire [18:0] address,
    input wire write_en, input wire [7:0] data_in, output wire [7:0] data_out);

    reg [7:0] rom_cells[0:8191];
    reg [7:0] ram_cells[0:4095];
    reg [7:0] low_ram_cells[0:4095];

    // Any of the programs can go here; they are linked at 0x8000 and the reset vector
    // above jumps to 0x8001. diag.txt reconfigures MUX 0 to 19200 baud, 7 data bits, no
    // parity, one stop bit, so a terminal has to be set to that rather than to the
    // channel's 9600 7E1 power on default.
    integer i;
    initial begin
        $readmemh("programs/diag.txt", rom_cells);
        // $readmemh("programs/serial.txt", rom_cells);   // 9600 7E1
        // $readmemh("programs/blink.txt", rom_cells);
        for (i = 0; i < 4096; i = i + 1) ram_cells[i] = 8'h00;
        for (i = 0; i < 4096; i = i + 1) low_ram_cells[i] = 8'h00;
    end

    wire rom_select     = address[18:13] == 4;
    wire ram_select     = address[18:12] == 7'hb;
    wire low_ram_select = address[18:12] == 0;

    reg [7:0] rom_q, ram_q, low_ram_q;

    always @(posedge clock) begin
        rom_q     <= rom_cells[address[12:0]];
        ram_q     <= ram_cells[address[11:0]];
        low_ram_q <= low_ram_cells[address[11:0]];

        if (enable && write_en) begin
            if (ram_select)     ram_cells[address[11:0]]     <= data_in;
            if (low_ram_select) low_ram_cells[address[11:0]] <= data_in;
        end
    end

    // The selects are combinational rather than registered alongside the data, which is
    // safe for the same reason the reads are: the address does not move within a cycle.
    assign data_out = (address == 19'h3fd00) ? 8'h71 :   // reset vector, JMP 8001
                      (address == 19'h3fd01) ? 8'h80 :
                      (address == 19'h3fd02) ? 8'h01 :
                      (address == 19'h3f110) ? 8'h0d :   // Diag board DIP switches
                      rom_select              ? rom_q :
                      ram_select              ? ram_q :
                      low_ram_select          ? low_ram_q : 8'h00;
endmodule

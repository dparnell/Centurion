# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Verilog re-implementation of the Centurion minicomputer's CPU6 board — a microcoded, Am2900 bit-slice CPU from the late 1970s. The design is a *gate-level-faithful* model: modules and signals are named after the physical chips on the original board (`// Microcode pipeline F5/H5/J5/K5/L5/M5 74LS377`, `// J10 Link/carry mux 74LS151`). The real microcode ROM image (`Verilog/roms/CodeROM.txt`, 2048 × 56-bit) and opcode map ROM (`Verilog/roms/CPU-6309.txt`) are dumps from the original hardware and drive everything — the CPU's instruction set lives in those files, not in the Verilog.

All work happens in [Verilog/](Verilog/); run all commands from that directory.

## Commands

```
make test                       # build + run the Icarus Verilog simulation testbench
make                            # synthesize for Tang Nano 9K (yosys -> nextpnr-himbaechel -> gowin_pack)
make load                       # program the attached Tang Nano 9K via openFPGALoader
make clean
python Microcode.py             # disassemble roms/CodeROM.txt to stdout
python parse_vcd.py             # microcode-level trace from vcd/CPUTestBench.vcd -> vcd/CPUTestBench.txt
python ControlPanel.py          # Tk GUI that steps through vcd/CPUTestBench.vcd cycle by cycle
```

The toolchain (`iverilog`, `vvp`, `yosys`, `nextpnr-himbaechel`, `gowin_pack`, `openFPGALoader`) comes from [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build), installed at `~/.local/oss-cad-suite/bin`.

`make test` runs the whole suite (`hellorld`, `bnz_test`, `alu_test`) in one `vvp` invocation. To run a *single* program, edit the `initial` block in [CPU6TestBench.v](Verilog/CPU6TestBench.v) — each test is a `$readmemh("programs/X.txt", ram.rom_cells)` followed by a reset pulse; several (`diag`, `inst_test`, `cylon`, `blink`) are commented out and use a fixed `#delay` instead of the `sim_end` handshake.

The `Not enough words in the file for the requested range` warnings from `$readmemh` are expected — the programs are much smaller than the 8K ROM array.

The `$dumpfile` writes `CPUTestBench.vcd` into the Verilog directory, but both Python VCD tools look for `vcd/CPUTestBench.vcd` — move it there first.

### Simulation tracing

Tracing is off by default. Uncomment the `` `define `` lines at the top of [CPU6TestBench.v](Verilog/CPU6TestBench.v) and rebuild:

- `TRACE_I` — one line per instruction with all registers (also pulls in `Instructions.v` for mnemonics)
- `TRACE_UC` — microcode sequencer jumps/ORs
- `TRACE_WR` / `TRACE_RD` — bus writes/reads

## Architecture

### Module wiring

There is no filelist; modules are pulled in with `` `include `` from whichever top level you build. Two top levels share the same `CPU6` core:

- [CPU6TestBench.v](Verilog/CPU6TestBench.v) — simulation. Its `Memory` module provides ROM at `0x08000`, RAM at `0x0b000`, low RAM at `0x00000`, plus hardcoded reset vector and Diag-board responses. A write to `0x3f201` prints a character (fake UART); a write of `0x01` to `0x3f900` ends the test.
- [tangnano9k.v](Verilog/tangnano9k.v) — synthesis. A power-on reset holds `reset` for 256 CPU clocks after configuration, then it follows the (pulled-up, active-low) reset button. The CPU runs directly from the 27 MHz `in_clk` pin — a single clock domain on a real pin-driven global. `Divide4` is left in the file but unused: driving a fabric-generated clock onto a global through a `BUFG` did not work on hardware, and to slow the CPU down again use a clock enable off `in_clk` or a divided PLL output rather than a second clock domain; an rPLL makes 81 MHz for the PSRAM. `AddressDecode` picks the peripheral and a single `assign data_r2c = mux_select ? mux_data : ram_data` feeds the CPU's read bus — every readable peripheral drives its own `data_out` and **nothing else may drive `data_r2c`**. `BlockRAM` (256 bytes, preloaded from `programs/blink.txt`) aliases across the whole address space and answers anything the `MUX` UART board at `0x3f200` does not claim; `LEDPanel` at `0x5c00` is write only and has no read port. `Watchdog` runs off the undivided 27 MHz clock and takes over the LEDs if `CPU6` stops pulsing `instruction_start`. Its stalled display is a bring-up readout: LED1 blinks at 1 Hz, LED2 = `reset_btn` reads high, LED3 = reset asserted now, LED4 = power-on reset completed (so the CPU clock is running), LED5 = an instruction has executed since power-up, LED6 = microcode address still changing. Every one of those is an ordinary fabric signal on purpose — an earlier version sampled the CPU clock net itself and nextpnr could not route a global to a LUT data input, so that bit read as a false zero. `PsramController` is instantiated but its `read`/`write`/`address` registers are not yet driven — external memory is work in progress.

`Clock.v` and `Instructions.v` are simulation-only.

### Inside CPU6.v

[CPU6.v](Verilog/CPU6.v) is the heart of the design and where nearly all work happens. The 56-bit microcode word from `CodeROM` lands in the `pipeline` register; every field of that word is decoded into the named 74-series decoders (`d2d3`, `e7`, `h11`, `k11`, `e6`) and drives the datapath enables shown in [images/Datapath.png](images/Datapath.png) (source: `datapath.excalidraw`).

- **Microsequencer**: three chained instances — two `Am2909` (address bits 3:0 and 7:4) and one `Am2911` (bits 10:8) — produce the 11-bit microcode ROM address. Conditional branching works by OR-ing bits into the low address nibble (the `J13`/`K13` muxes) rather than by computed jumps.
- **ALU**: two `Am2901` 4-bit slices (`alu0`, `alu1`) chained into an 8-bit ALU, with separate shift/carry muxes between them.
- **Instruction decode**: the opcode on `DPBus` indexes `MapROM` (the 6309 PROM), which yields the microcode entry point. Microcode address `0x101` is the start of each instruction — `instruction_start` and the tracing hooks key off it.
- **MMU**: the 8-bit page table maps `memory_address[15:11]` + `page_table_base` to a 19-bit physical address. On the original this is two 93L422 4-bit RAMs; here it is split into four 128-entry arrays (`page_table_{lo,hi}_{even,odd}`) specifically so it fits the Tang Nano 9K. This lookup is unpipelined and dominates LUT usage — most of the design's logic cells go here.
- Addresses with `virtual_address[18:8] == 0` are the CPU's own register space and are read back internally rather than from the bus.

Files follow the two Verilog coding guidelines quoted in the comments: blocking `=` in combinational `always @(*)`, nonblocking `<=` in sequential `always @(posedge clock)`.

### Programs

`programs/*.txt` are hex bytes, one per line, with `//` comments — hand-assembled CPU6 machine code loaded via `$readmemh` into the testbench ROM (linked at `0x8000`).

## Notes

- The README's synthesis section still describes the older iCE40 / Alchitry Cu target (and `LEDPanel.v`'s comment still mentions Alchitry). The Makefile and current work target the Gowin GW1NR-9C on the Tang Nano 9K; pin assignments are in [tangnano9k.cst](Verilog/tangnano9k.cst).
- README says `make all` for simulation, but `all` is the synthesis target — use `make test`.
- Do not generate the CPU clock in fabric. A divided clock on general routing accumulates ~2.4 ns of skew and nextpnr fails with `Hold/min time violation for clock 'posedge clock'` at the register file block RAM; putting it through a `BUFG` fixes that error but did not work on real hardware. The design now clocks everything from the `in_clk` pin.
- A memory only maps to LUTRAM/BSRAM if its write port is free of an asynchronous reset. The page table used to be written from the main `always @(posedge clock, posedge reset)` block, which forced yosys to emit `Replacing memory ... with list of registers` and spend roughly 4700 LUT4s on it — so much that the table had been cut in half to fit the device. Written from its own `always @(posedge clock)` block it maps to 32 LUTRAM cells and the whole design drops from 45% to 28% LUT4 usage. Treat `Replacing memory ... with list of registers` in the synthesis log as a bug.
- Never wire two module outputs onto the same net. Simulation resolves an undriven output as `z` and lets the real value through, so `make test` passes; yosys instead reports `Driver-driver conflict ... Resolved using constant`, ties the net to `x` and deletes whatever fed it. This silently removed the program RAM and left the CPU fetching a constant on hardware. After changing the bus, check the synthesis log for `Driver-driver conflict` and confirm `tangnano9k.ram.ram_cells` still appears in the `mapping memory` lines.
- The `MUX` serial board in [mux.v](Verilog/mux.v) is still unfinished: nothing ever moves `txState` out of `TX_STATE_IDLE`, so writing the data register loads `output_data` but never starts a transmission. That is why the simulation testbench fakes the UART with a `$write` instead of instantiating the module.
- Treat every yosys `Identifier is implicitly declared` warning as a bug, not noise. `always @(posedge clk)` in the MUX referred to a clock that is not a port of the module (`bit_clock`/`cpu_clock` are), so the block never ran, `int_reqn` was never assigned, and yosys tied the CPU's active-low interrupt request to a constant. CPU6 gates all three microsequencers with `jsr_ = ~(int_enabled & ~int_reqn)`, so the core executed nothing at all on hardware while simulation — which drove `int_reqn` explicitly — passed.
- Interrupt and DMA logic is incomplete; the `MUX` UART can raise `int_reqn` but the CPU-side handling is still being built out.

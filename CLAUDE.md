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
- [tangnano9k.v](Verilog/tangnano9k.v) — synthesis. 27 MHz input, `Divide4` gives the CPU clock; an rPLL makes 81 MHz for the PSRAM. Wires up `BlockRAM` (256 bytes, preloaded from `programs/blink.txt`), `LEDPanel`, and the `MUX` UART board at `0x0f200`. `PsramController` is instantiated but its `read`/`write`/`address` registers are not yet driven — external memory is work in progress.

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
- Interrupt and DMA logic is incomplete; the `MUX` UART can raise `int_reqn` but the CPU-side handling is still being built out.

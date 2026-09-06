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
- [tangnano9k.v](Verilog/tangnano9k.v) — synthesis. A power-on reset holds `reset` for 256 CPU clocks after configuration, then it follows the (pulled-up, active-low) reset button. Everything is clocked from the 27 MHz `in_clk` pin — a single clock domain on a real pin-driven global. `ClockEnable` then gates the core to the original CPU6's 5 MHz by accumulation (5 enables every 27 clocks, exact with no drift) rather than by division, since 27 is not a multiple of 5. `Divide4` is left in the file but unused: driving a fabric-generated clock onto a global through a `BUFG` did not work on hardware, so slow the core with an enable, never a second clock domain; an rPLL makes 81 MHz for the PSRAM. `AddressDecode` picks the peripheral and a single `assign data_r2c = mux_select ? mux_data : ram_data` feeds the CPU's read bus — every readable peripheral drives its own `data_out` and **nothing else may drive `data_r2c`**. `BlockRAM` (256 bytes, preloaded from `programs/blink.txt` — change that `$readmemh` to run something else; only the 256-byte programs fit) aliases across the whole address space and answers anything the `MUX` UART board at `0x3f200` does not claim; `LEDPanel` at `0x5c00` is write only and has no read port. Holding `btn2` runs the core at one clock in two (13.5 MHz) instead of 5 MHz — a bring-up aid for telling a speed-dependent fault from any other kind. It cannot ungate the enable entirely, because the microcode ROM reads every clock and enabled cycles must therefore be at least two clocks apart. `Watchdog` runs off the 27 MHz clock and takes over the LEDs if `CPU6` stops pulsing `instruction_start`; its stalled display is LED1 blinking at 1 Hz, LED2 = reset asserted now, LED3–LED6 = the highest microcode address reached since reset divided by 128. Every diagnostic input is an ordinary fabric signal on purpose — an earlier version sampled the CPU clock net itself and nextpnr could not route a global to a LUT data input, so that bit read as a false zero. `PsramController` is instantiated but its `read`/`write`/`address` registers are not yet driven — external memory is work in progress.

`Clock.v` and `Instructions.v` are simulation-only.

### Inside CPU6.v

[CPU6.v](Verilog/CPU6.v) is the heart of the design and where nearly all work happens. The 56-bit microcode word from `CodeROM` lands in the `pipeline` register; every field of that word is decoded into the named 74-series decoders (`d2d3`, `e7`, `h11`, `k11`, `e6`) and drives the datapath enables shown in [images/Datapath.png](images/Datapath.png) (source: `datapath.excalidraw`).

- **Microsequencer**: three chained instances — two `Am2909` (address bits 3:0 and 7:4) and one `Am2911` (bits 10:8) — produce the 11-bit microcode ROM address. Conditional branching works by OR-ing bits into the low address nibble (the `J13`/`K13` muxes) rather than by computed jumps.
- **ALU**: two `Am2901` 4-bit slices (`alu0`, `alu1`) chained into an 8-bit ALU, with separate shift/carry muxes between them.
- **Instruction decode**: the opcode on `DPBus` indexes `MapROM` (the 6309 PROM), which yields the microcode entry point. Microcode address `0x101` is the start of each instruction — `instruction_start` and the tracing hooks key off it.
- **MMU**: the 8-bit page table maps `memory_address[15:11]` + `page_table_base` to a 19-bit physical address. On the original this is two 93L422 4-bit RAMs; here it is split into four 128-entry arrays (`page_table_{lo,hi}_{even,odd}`) specifically so it fits the Tang Nano 9K. This lookup is unpipelined and dominates LUT usage — most of the design's logic cells go here.
- **The bottom of physical memory is the CPU's own state, not the bus.** `0x000`-`0x0ff` is the register file and `0x100`-`0x1ff` is the mapping RAM, both answered inside `CPU6` rather than from `dataInBus`. diag loads the whole page table by writing that second window as ordinary memory — eight 32-byte blocks, one per table, entry at `0x100 + table * 32 + page` — so the table's index order is not free: `page_address` must be `{page_table_base, memory_address[15:11]}`. The reverse order translates perfectly well and hides the problem completely until something writes through the window.

Files follow the two Verilog coding guidelines quoted in the comments: blocking `=` in combinational `always @(*)`, nonblocking `<=` in sequential `always @(posedge clock)`.

### Programs

`programs/*.txt` are hex bytes, one per line, with `//` comments — hand-assembled CPU6 machine code loaded via `$readmemh` into the testbench ROM (linked at `0x8000`).

## Notes

- **Serial settings are per program, and the data bits matter as much as the baud.** `programs/serial.txt` uses the MUX power-on default, 9600 7E1; `programs/diag.txt` reconfigures the channel on startup to **19200 7N1**, so `picocom -b 19200 -d 7 -p n /dev/ttyUSB1`. Leaving off `-d 7` gives 8N1, which reads a 7-bit character's stop bit as data bit 7 and delivers every byte as `data | 0x80` — high-bit garbage that looks like a baud problem but is not. diag prints its banner once and then waits, so open the terminal first and press reset.
- The LEDs show the LED panel register, and all eight blink together at 1 Hz if `CPU6` stops executing. The bring-up diagnostics that once shared them — a 1 Hz clock reference, a readout of the MUX's selected line settings, and a standalone `0x55` generator on `btn2` that bypassed the CPU and MUX entirely — were removed once the board worked, but are in the history and are worth restoring if a board ever goes quiet again.
- **Everything with state must follow the core's reset, not just the core.** The MUX had no reset at all and the page table was only initialised at power-up, so diag's mapping RAM test passed once and then failed on every run after a reset: it came back to a serial channel still mid-character and a page table still holding the previous run's patterns. "Works once, then always fails after a reset" is the signature of state surviving a reset — look for registers and memories the reset does not reach.
- Holding `btn2` prints the CPU's position over the serial line at diag's 19200 7N1 (see [StatusDump.v](Verilog/StatusDump.v)): the last two instruction fetches, whether a byte is waiting and the last one received, a count of every byte the receiver has completed, and the page table base and mapping. It freezes that snapshot when the machine has printed nothing for two seconds while still fetching. This is what found the fault above — four hex addresses that decoded to diag's wait-for-a-character loop — after LED-based guessing had got nowhere.
- **If the serial port goes silent, unplug and replug the board before suspecting the design.** `openFPGALoader` detaches the FTDI kernel driver to program over channel A, and it can leave channel B — the UART on `/dev/ttyUSB1` — delivering nothing even though the FPGA is transmitting correctly. This cost a long debugging session in which the RTL, the netlist, the pin placement and the board's own LEDs all said the design was working. A USB re-enumeration clears it. Holding `btn2` drives the UART pin from a standalone `0x55` generator with no CPU or MUX involved, which separates this class of fault from a real design fault in one step.

- The README's synthesis section still describes the older iCE40 / Alchitry Cu target (and `LEDPanel.v`'s comment still mentions Alchitry). The Makefile and current work target the Gowin GW1NR-9C on the Tang Nano 9K; pin assignments are in [tangnano9k.cst](Verilog/tangnano9k.cst).
- README says `make all` for simulation, but `all` is the synthesis target — use `make test`.
- **Never let a block RAM's output be the thing a clock enable holds.** A BRAM output is not a register: with `CE` low it is not refreshed, and the value decays. This cost two rounds of hardware debugging. `CodeROM` had an async read, so yosys absorbed CPU6's `pipeline` register into the BRAM output and gated it — `cpu.pipeline` existed as a net with *zero* flip-flops driving it — and the 56-bit control word rotted between enabled cycles, so the sequencer wandered to a different microcode address every run. The register file failed the same way one level down: instructions ran but register values were wrong, so blink.txt's counter never incremented and the LEDs stayed dark. The rule: a BRAM must read every clock (`CE` tied high) with the value held in fabric flops, or the array must be LUTRAM, which has no output register to decay. After any change, check that no `SPX9` has `CE` wired to the enable.
- Anything clocked that belongs to the CPU takes an `enable` and advances only on it. A bus cycle lasts one *enabled* clock, so an ungated peripheral sees a single CPU write as several board-clock writes. The testbench drives a one-in-two enable rather than a constant `1`: the free-running microcode ROM costs a cycle of latency, so enabled cycles must be at least two clocks apart, and reset has to span several of them.
- Free-running a *synchronous* read is not a substitute for gating it. A write lands in the array on an enabled edge, and a free-running read then exposes the new value partway through the same CPU cycle, where the gated read holds the start-of-cycle value throughout. Tried on the register file; it made the CPU write zeros instead of characters.
- Do not generate the CPU clock in fabric. A divided clock on general routing accumulates ~2.4 ns of skew and nextpnr fails with `Hold/min time violation for clock 'posedge clock'` at the register file block RAM; putting it through a `BUFG` fixes that error but did not work on real hardware. The design now clocks everything from the `in_clk` pin.
- `ram_style = "distributed"` is sometimes needed to keep a memory out of a block RAM: an asynchronous read alone did not stop yosys merging the register file's read register back into a BRAM and gating it again.
- A memory only maps to LUTRAM/BSRAM if its write port is free of an asynchronous reset. The page table used to be written from the main `always @(posedge clock, posedge reset)` block, which forced yosys to emit `Replacing memory ... with list of registers` and spend roughly 4700 LUT4s on it — so much that the table had been cut in half to fit the device. Written from its own `always @(posedge clock)` block it maps to 32 LUTRAM cells and the whole design drops from 45% to 28% LUT4 usage. Treat `Replacing memory ... with list of registers` in the synthesis log as a bug.
- Never wire two module outputs onto the same net. Simulation resolves an undriven output as `z` and lets the real value through, so `make test` passes; yosys instead reports `Driver-driver conflict ... Resolved using constant`, ties the net to `x` and deletes whatever fed it. This silently removed the program RAM and left the CPU fetching a constant on hardware. After changing the bus, check the synthesis log for `Driver-driver conflict` and confirm `tangnano9k.ram.ram_cells` still appears in the `mapping memory` lines.
- The `MUX` serial board in [mux.v](Verilog/mux.v) transmits and receives. Its CPU-side clock enable matters: a bus cycle lasts several board clocks, so a data-register write must start exactly one transmission. `cpu_clock` and `bit_clock` are the same net, which is what lets `tx_request` be a plain flag rather than a clock-domain handshake — separating them would need a real one.
- [programs/hellorld.txt](Verilog/programs/hellorld.txt) cannot drive a *real* UART: it writes all nine characters back to back with no status check, so eight are overwritten before they reach the wire. It only works against the testbench's fake UART, which accepts every write instantly. Use [programs/serial.txt](Verilog/programs/serial.txt) (generated by [MakeSerial.py](Verilog/MakeSerial.py)) to exercise the real thing — it polls the transmitter-ready bit.
- Treat every yosys `Identifier is implicitly declared` warning as a bug, not noise. `always @(posedge clk)` in the MUX referred to a clock that is not a port of the module (`bit_clock`/`cpu_clock` are), so the block never ran, `int_reqn` was never assigned, and yosys tied the CPU's active-low interrupt request to a constant. CPU6 gates all three microsequencers with `jsr_ = ~(int_enabled & ~int_reqn)`, so the core executed nothing at all on hardware while simulation — which drove `int_reqn` explicitly — passed.
- The two 74LS259 addressable latches, F11 and M13, hold the machine state and are selected by K11 outputs 3 and 2. Both are written as `latch[alu_b[3:1]] <= alu_b[0]`, which is why the wiki lists their functions in pairs. Implemented so far: F11 bit 0 (interrupt enable) and M13 bit 7 (interrupt acknowledge, wired back to the serial board so a request is dropped once taken). The DMA, parity, timer and front panel bits are latched but nothing reads them yet.
- DMA logic is incomplete, and the DP bus sources at `d2d3` 11 and 12 (machine status / interrupt level, and interrupt request level / DIP switches) are still stubs.
- **A diag test that returns to the menu has not necessarily passed.** The mapping RAM test used to come back looking fine while actually having crashed: it ran off into the empty register file region, executed 254 zero bytes, came out the far side and recovered through `0x808b`'s `JMP 0x0000`. `make diagtest` now fails if the machine ever executes below `0x0100`, which is the honest check. The test itself runs until it is sent a control-C rather than terminating on its own.

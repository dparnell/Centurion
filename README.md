# Centurion Hardware Resurrection

This directory contains an [FPGA](https://en.wikipedia.org/wiki/Field-programmable_gate_array) implementation of the [Centurion Minicomputer](https://github.com/Nakazoto/CenturionComputer/wiki).

The Centurion was an 8-bit minicomputer designed and built by Warrex Computer Corporation, headquartered in Richardson, Texas. The company operated from the mid 1970's into the mid 1980's, delivering approximately 1000 computers to customers in Texas, Oklahoma, and others. The computers were used for accounting and business functions in medium sized companies.

The Centurion was made of almost entirely TTL MSI logic on a handful of PC boards in a single rack. Earlier models relied on magnetic core memory, later models used MOS memory up to 256 kB. It was technologically similar to the DEC VAX 11/780 or Data General Nova, but smaller and lower priced. Competition from even lower cost microcomputers, particularly the IBM XT and AT in the 1980's, led to decreased sales and the end of the line.

Below is a picure of CPU6 board. Notice the prominent [Am2900 series](https://en.wikipedia.org/wiki/AMD_Am2900) bit slice components in center of the board. The HDL design described below implements the behavior of each of these components. The row of seven 2kx8 [EPROMs](https://en.wikipedia.org/wiki/EPROM) in the upper left contain about 2048 words of [microcode](https://en.wikipedia.org/wiki/Microcode), which is the true personality of the [CPU6 instruction set](https://github.com/Nakazoto/CenturionComputer/wiki/Instructions).

![CPU6](https://github.com/Nakazoto/CenturionComputer/raw/main/Computer/CPU6%20Board/HiRes%20Photos/CPU6_HiRes_Scan_Front.jpg "CPU6")

## Layout

Everything is built from the `Verilog` directory, and all the `make` commands
below are run from there.

| | |
|---|---|
| `Verilog/` | the RTL, and the Makefile that drives everything |
| `Verilog/asm/` | source for the programs that run on the machine, and the test scripts fed to them |
| `Verilog/programs/` | assembled images, plus the original ROM dumps |
| `Verilog/roms/` | the microcode and opcode map read off the real hardware |
| `tools/` | the assembler, disassembler and the scripts that drive the board |

## Simulation

The [Verilog](https://en.wikipedia.org/wiki/Verilog) implementation is simulated with [Icarus Verilog](http://iverilog.icarus.com/):

```
make test
```

That builds and runs three testbenches: `CPU6TestBench`, which runs a set of
small programs against the core; `TopTestBench`, which simulates the real
synthesis top level including the UART pin and the Gowin hard blocks; and
`PsramTB`, which exercises the HyperRAM PHY against a behavioural die.

Two more are too slow to belong in `make test`, because they simulate hundreds
of milliseconds of a 27 MHz board:

```
make diagtest    # boot the diagnostic ROM and type a test number at it
make mapfail     # run diag's mapping RAM test until its compare fails
make psramtest   # just the PSRAM PHY, on its own
```

### Running a program

`make run` assembles a program, boots the whole simulated board with it, types
an input file at it over the serial line and prints what comes back. This is
the loop for writing anything for this machine - a second or so, against about
three minutes to build, load and capture on real hardware.

```
make run SRC=asm/forth.s IN=asm/tests_create.f FOR=1400
```

| option | meaning |
|---|---|
| `SRC=` | the program to assemble and run, from `asm/` (default `asm/forth.s`) |
| `IN=` | a file to type at it once it has finished printing (optional) |
| `FOR=` | milliseconds of simulated board time to run for (default 300) |
| `RUNARGS=` | extra plusargs, below |

The simulated typist paces itself against the machine's own receiver rather
than against a delay, so input is never typed over the top of a program that is
still busy. Note that `FOR` is *simulated* time: a few hundred milliseconds is
a few minutes of wall clock, and compiling one long FORTH definition takes over
200 ms because every word on the line is a linear walk of the dictionary.

The plusargs available through `RUNARGS` are worth knowing about when a
simulated machine stops doing anything, because that is otherwise completely
silent:

| plusarg | what it prints |
|---|---|
| `+pctrace` | one line per instruction fetch, so a stopped machine can be told from a looping one |
| `+psramtrace` | what the memory bridge, the microcode and the PHY were doing when no instruction was fetched for a long time, plus every bridge timeout |
| `+typetrace` | every byte the testbench sends, interleaved with what the machine echoes |
| `+rxtrace` | every read of the serial data register, with the program counter that caused it |
| `+quiet` / `+hex` | suppress the machine's output, or show it as hex bytes |

### Assembling on its own

Programs are written in `asm/` and assembled into the `programs/*.txt` format
that the ROM is loaded from:

```
make programs/forth.txt    # assemble one
make programs              # assemble every asm/*.s, which checks they all still build
```

The assembler is [tools/Assemble.py](tools/Assemble.py). Its encodings are
checked against real code rather than against a reading of the manual:
`--roundtrip Verilog/programs/diag.txt 8000` disassembles the original
diagnostic ROM, re-encodes every instruction in the form the ROM actually used
and compares bytes. All 3812 instructions come back identical.

## Synthesis

The design targets a [Gowin GW1NR-9C](https://www.gowinsemi.com/en/product/detail/46/) on a
[Tang Nano 9K](https://wiki.sipeed.com/hardware/en/tang/Tang-Nano-9K/Nano-9K.html), built with the
open source [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) toolchain: yosys for
synthesis, nextpnr-himbaechel for place and route, and gowin_pack for the bitstream.

`make` on its own synthesises; the `load` targets below build and then program
the attached board with openFPGALoader. There are three of them, because these
are the three things the machine is usually wanted for:

```
make load        # the diagnostic ROM, switches on the auxiliary test menu
make load-tos    # the same ROM, switches set for TOS, the machine code monitor
make load-forth  # the FORTH, assembled from asm/forth.s first
```

Each is a normal build, so they can be combined with the options below or taken
apart - `make load-forth` is just `make PROGRAM=programs/forth.txt load`.

| option | meaning |
|---|---|
| `PROGRAM=` | which image the 8K ROM at `0x8000` holds (default `programs/diag.txt`) |
| `DIP=` | the Diag board's DIP switches, which choose what the machine does out of reset |
| `PSRAM_SELFTEST=1` | disconnect the memory from the CPU and run the PSRAM's own bring-up test instead |

The DIP switches are set at build time because they are physical switches on
the Diag board: `1d` is the diagnostic test menu, `1a` is TOS, `16` the serial
board's interrupt test, `17`-`19` the disk tests. `Verilog/DiagBoard.v` lists
the rest.

What a bitstream was built with is not a file, so `make` cannot see it change
when only an option differs. `build.stamp` records the three options above and
forces a rebuild when any of them does, which is what stops `make load-forth`
straight after `make load` from quietly programming the board with the previous
build. An unchanged configuration is still a no-op.

Pin assignments are in `Verilog/tangnano9k.cst`. Everything is clocked from the
27 MHz input pin as a single clock domain; the core is gated down to the
original CPU6's 5 MHz by a clock enable rather than by a divided clock, because
driving a fabric-generated clock onto a global did not work on real hardware.

The board's UART appears on the second channel of its FT2232, usually
`/dev/ttyUSB1`. Serial settings are per program: the diagnostic ROM reconfigures
the serial board to 19200 baud, 7 data bits, no parity, so
`picocom -b 19200 -d 7 -p n /dev/ttyUSB1`.

Resource utilisation and timing:

```
Info: Device utilisation:
Info:                  IOB:      21/    276     7%
Info:                 LUT4:    3043/   8640    35%
Info:            MUX2_LUT5:     246/   4320     5%
Info:                  ALU:     548/   6480     8%
Info:                  DFF:    1745/   6480    26%
Info:            RAM16SDP4:      71/    270    26%
Info:                BSRAM:      18/     26    69%

Info: Max frequency for clock 'clock': 50.47 MHz (PASS at 27.00 MHz)
```

That `IOB` row does not count `IOBUF` cells, so it reads as though every
bidirectional pin has been dropped. The eighteen PSRAM data and strobe pins are
placed; they simply are not in that total.

The page table used to dominate the logic, taking roughly 4700 LUT4s because an
asynchronous reset on its write port stopped yosys mapping it to memory at all.
Written from its own always block it maps to LUTRAM instead, which is where most
of the `RAM16SDP4` usage above comes from, and the whole design dropped from 45%
to under a third of the device.

Earlier revisions of this project targeted a [Lattice iCE40
HX8K](https://www.latticesemi.com/iCE40) on an [Alchitry Cu](https://alchitry.com/boards/cu) board
using [Project IceStorm](https://clifford.at/icestorm). Below is a demonstration program running on
that earlier target:

![Centurion1](images/cylon.gif "Running code")

## Architecture

The CPU6 is an interesting design. It is based on the [AMD Am2900](https://en.wikipedia.org/wiki/AMD_Am2900) family of bit slice devices. The entire CPU fits on a single board, using two Am2901s to make an 8-bit ALU. The control unit is [microcoded](https://en.wikipedia.org/wiki/Microcode), using 2 Am2909 microsequencers, and 1 Am2911 microsequencer with a 2048 word x 56-bit microprogram stored in seven EPROMs. It is typical of minicomputers of that era. Discrete CPUs based on the Am2900 family were soon superceded by fully integrated VLSI CPUs, such as the [Intel 8086](https://en.wikipedia.org/wiki/Intel_8086), [Motorola 68000](https://en.wikipedia.org/wiki/Motorola_68000), and numerous others.

Below is a sample microcode execution trace. The marker shows the beginning of the very first instruction after reset. It executes a NOP (no operation) and then DLY (delay 4.55 ms).

![DCX Instruction](images/NOP_DLY.png "DCX Instruction Execution")

## Datapath

Below is the CPU data path with enables for busses and registers. The enables are controlled by the microcode word at the output of the pipeline register.

![Data path](images/Datapath.png "Data path")

## Status

The machine boots the original diagnostic ROM on a Tang Nano 9K with a serial
console, and both of diag's CPU tests pass: the CPU instruction test (menu
entry 01) and the CPU-6 mapping RAM test (entry 02) each print `*** PASS ***`.
Both are soak tests that run until interrupted; entry 02 checks for the exit
key only at the end of a round of 65536 passes, so its verdict can take a
minute or so to appear after Control-C.

All CPU6 instruction tests in the local testbench pass. Interrupts are enabled,
requested and acknowledged. The MMU is implemented, including the mapping RAM.
DMA is not implemented, so the disk controller tests cannot run yet; see
[docs/sd-card-disk-images.md](docs/sd-card-disk-images.md) for how disk images
might eventually be served from the board's SD card.

The embedded HyperRAM is on the CPU's bus and backs everything the block RAM
does not, so the machine has its full 256K of physical memory: the FORTH's own
memory sizer walks the page table and finds 244K of it, which is all 128 pages
bar the ROM and the I/O and boot pages.

The board answers 8K of block RAM at physical `0x0b000`, which has to reach
`0x0c000` because that is where diag puts its stack. CPU6's `JSR` keeps the return
address in `X` and pushes the *old* `X`, so a stack in unbacked memory is not a
quiet failure: every call returns with `X` set to zero.

### Links

 * [Schematics](https://github.com/Meisaka/CenMiniCom)
 * [Schematics and Microcode](https://github.com/sjsoftware/centurion-cpu6)

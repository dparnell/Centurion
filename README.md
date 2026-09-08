# Centurion Hardware Resurrection

This directory contains an [FPGA](https://en.wikipedia.org/wiki/Field-programmable_gate_array) implementation of the [Centurion Minicomputer](https://github.com/Nakazoto/CenturionComputer/wiki).

The Centurion was an 8-bit minicomputer designed and built by Warrex Computer Corporation, headquartered in Richardson, Texas. The company operated from the mid 1970's into the mid 1980's, delivering approximately 1000 computers to customers in Texas, Oklahoma, and others. The computers were used for accounting and business functions in medium sized companies.

The Centurion was made of almost entirely TTL MSI logic on a handful of PC boards in a single rack. Earlier models relied on magnetic core memory, later models used MOS memory up to 256 kB. It was technologically similar to the DEC VAX 11/780 or Data General Nova, but smaller and lower priced. Competition from even lower cost microcomputers, particularly the IBM XT and AT in the 1980's, led to decreased sales and the end of the line.

Below is a picure of CPU6 board. Notice the prominent [Am2900 series](https://en.wikipedia.org/wiki/AMD_Am2900) bit slice components in center of the board. The HDL design described below implements the behavior of each of these components. The row of seven 2kx8 [EPROMs](https://en.wikipedia.org/wiki/EPROM) in the upper left contain about 2048 words of [microcode](https://en.wikipedia.org/wiki/Microcode), which is the true personality of the [CPU6 instruction set](https://github.com/Nakazoto/CenturionComputer/wiki/Instructions).

![CPU6](https://github.com/Nakazoto/CenturionComputer/raw/main/Computer/CPU6%20Board/HiRes%20Photos/CPU6_HiRes_Scan_Front.jpg "CPU6")

## Simulation

The [Verilog](https://en.wikipedia.org/wiki/Verilog) implementation is simulated with [Icarus Verilog](http://iverilog.icarus.com/):

```
cd Verilog
make test
```

That builds and runs two testbenches: `CPU6TestBench`, which runs a set of small
hand-assembled programs against the core, and `TopTestBench`, which simulates
the real synthesis top level including the UART pin and the Gowin hard blocks.

A third, `make diagtest`, boots the original diagnostic ROM and types a test
number over a simulated serial link. It is not part of `make test` because it
simulates hundreds of milliseconds of a 27 MHz board and takes minutes.

## Synthesis

The design targets a [Gowin GW1NR-9C](https://www.gowinsemi.com/en/product/detail/46/) on a
[Tang Nano 9K](https://wiki.sipeed.com/hardware/en/tang/Tang-Nano-9K/Nano-9K.html), built with the
open source [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) toolchain: yosys for
synthesis, nextpnr-himbaechel for place and route, and gowin_pack for the bitstream.

```
cd Verilog
make          # synthesise
make load     # program the attached board with openFPGALoader
```

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
Info:                  IOB:      13/    276     4%
Info:                 LUT4:    2766/   8640    32%
Info:                  ALU:     392/   6480     6%
Info:                  DFF:    1302/   6480    20%
Info:            RAM16SDP4:     103/    270    38%
Info:                BSRAM:      15/     26    57%

Info: Max frequency for clock 'clock': 46.25 MHz (PASS at 27.00 MHz)
```

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

The board answers 8K of RAM at physical `0x0b000`, which has to reach `0x0c000`
because that is where diag puts its stack. CPU6's `JSR` keeps the return
address in `X` and pushes the *old* `X`, so a stack in unbacked memory is not a
quiet failure: every call returns with `X` set to zero.

### Links

 * [Schematics](https://github.com/Meisaka/CenMiniCom)
 * [Schematics and Microcode](https://github.com/sjsoftware/centurion-cpu6)

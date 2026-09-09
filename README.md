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

## The built-in FORTH

[Verilog/asm/forth.s](Verilog/asm/forth.s) is an interactive FORTH written for
this machine, in about 3.3K of the 8K ROM. It is an indirect threaded
interpreter in the traditional style, and it uses the whole of the machine's
memory rather than just the part that is directly addressable.

### Getting to it

On real hardware:

```
make load-forth
picocom -b 19200 -d 7 -p n /dev/ttyUSB1
```

or in simulation, typing a file at it and printing what comes back:

```
make run SRC=asm/forth.s IN=asm/tests_create.f FOR=1400
```

Either way it counts the memory at start up and says what it found:

```
Centurion FORTH  244 K RAM
```

It reads a line at a time, echoes what you type, and answers `ok` when the line
has run. A word it does not know is echoed back with a `?`.

### The words

| | |
|---|---|
| stack | `DUP` `DROP` `SWAP` `OVER` `ROT` `PICK` |
| arithmetic | `+` `-` `*` `/` `/MOD` |
| logic | `AND` `OR` `XOR` `NOT` - bitwise, on all sixteen bits |
| shifts | `LSHIFT` `RSHIFT` - `RSHIFT` is logical, so it does not carry the sign down |
| comparison | `=` `<` `>` `0=` - signed, and true is all ones |
| console | `.` `EMIT` `KEY` `CR` `."` |
| memory | `@` `!` `C@` `C!` `HERE` `,` `ALLOT` |
| defining | `:` `;` `CREATE` `DOES>` `IMMEDIATE` `'` `EXECUTE` `LITERAL` `[` `]` |
| control | `IF` `ELSE` `THEN` `BEGIN` `UNTIL` `AGAIN` `DO` `LOOP` `I` |
| return stack | `>R` `R>` |
| numbers | `HEX` `DECIMAL` `BASE` |
| comments | `\` to the end of the line, `( ... )` inline |
| the machine | `PAGES` `BANK!` `WORDS` |

Both comment forms are immediate, so they work while compiling as well as
while interpreting:

```
7 ( inline ) .                  7  ok
: Y ( a comment while compiling ) 9 ;
\ and the rest of this line is ignored
```

`WORDS` lists the dictionary, newest first. `0 PICK` copies the top of the
stack and `1 PICK` the one below it, so `PICK` generalises `DUP` and `OVER`.
`/MOD` leaves the remainder under the quotient, which makes `MOD` a definition
rather than a primitive:

```
: MOD /MOD DROP ;
```

`*` and `/` are the machine's own multiply and divide instructions. `*` keeps
the low sixteen bits of the product, so `123 456 *` is -9448 rather than 56088.
Dividing by zero returns rather than hanging, but the answer means nothing.

### The stack, and defining words

Arguments come before the operator and results are left on the stack, so `.`
prints and pops the top of it:

```
2 3 + .            5  ok
```

`:` and `;` add a word to the dictionary. The classic first example works here
as it does anywhere:

```
: STAR 42 EMIT ;
: BAR 5 0 DO STAR LOOP ;
: F BAR CR STAR CR STAR CR BAR CR 5 0 DO STAR CR LOOP ;
F
```

which draws

```
*****
*
*
*****
*
*
*
*
*
```

`DO` takes the limit and the starting index, so `5 0 DO ... LOOP` runs five
times, and `I` is the index. `IF ELSE THEN` and `BEGIN ... UNTIL` work as
usual; `BEGIN ... AGAIN` loops for ever.

### Numbers

`HEX` and `DECIMAL` switch the base for both reading and printing, and `BASE`
is the variable behind them:

```
HEX FF . DECIMAL      FF  ok
```

Numbers are 16 bits. `.` prints signed in base ten and unsigned in any other
base, so an address above `8000` reads as a negative number in decimal and as
itself in hex.

### Defining your own defining words

`CREATE` makes a dictionary entry whose data follows it, and `DOES>` says what
the words it makes should do when they run. Between them they are enough to
build the words that most FORTHs have built in:

```
: CONSTANT CREATE , DOES> @ ;
7 CONSTANT SEVEN
SEVEN .                        7  ok

: VARIABLE CREATE 0 , ;
VARIABLE V   9 V !   V @ .     9  ok

: ARRAY CREATE 2 * ALLOT DOES> SWAP 2 * + ;
4 ARRAY A    11 0 A !   0 A @ .    11  ok
```

`."` prints the text up to the closing quote, and works both at the prompt and
inside a definition:

```
." hello"                      hello  ok
: GREET ." Centurion" CR ;
GREET                          Centurion
```

Compiled, the text is laid down inside the definition itself, so `GREET` costs
nothing to run beyond printing.

`>R` moves the top of the data stack to the return stack and `R>` brings it
back, which is how a word gets at its second argument without a `ROT`:

```
: ROT3 >R SWAP R> ;
```

`'` (tick) reads the *next* word from the input and pushes its code field
address - the token for that word. `EXECUTE` runs one:

```
6 ' SQ EXECUTE .              36  ok
```

and `,` compiles one into a definition, which is what makes a table of tokens
worth having.

`[` and `]` switch out of and back into compiling in the middle of a
definition, and `LITERAL` carries a value computed in between back into the
code being compiled:

```
: X [ 2 3 + ] LITERAL ;
X .                            5  ok
```

X holds the constant 5: the addition happened once, while X was being defined.
This is also how to get a token compiled rather than looked up at run time -
`[ ' FOO ] LITERAL` is what other FORTHs spell `[']`.

### The Centurion-specific part

The machine addresses 64K but has 256K of physical memory behind an MMU, which
maps thirty-two 2K virtual pages onto 2K physical pages. FORTH keeps virtual
page 14 - `7000` to `77ff` - free as a window onto any physical page:

| | |
|---|---|
| `PAGES` | how many 2K pages of physical memory were found at start up |
| `BANK!` | takes a physical page number and maps it into the window at `7000` |

So to write to somewhere in physical page 40, which no ordinary address can
reach:

```
40 BANK!
HEX 1234 7100 !  7100 @ .  DECIMAL
```

`PAGES` is how the banner's figure is arrived at - it is the count of pages
that held a signature when it was written and read back at start up, so it
reports memory the machine can actually use rather than memory it ought to
have.

The rest of the map: the dictionary grows up from `0200` towards `6f00`, and
the stacks, the input buffer and the interpreter's own variables sit in the
fast block RAM from `b000` up, because the board answers that far more quickly
than it answers the HyperRAM.

### What it does not have

There is no `[']`, but it is not needed: `[ ' FOO ] LITERAL` does the same
thing. `SPACES` and the counted-string words are missing - `."` is the only
string output - and so is anything double-length, although the machine's
multiply computes the high word of the product and `*` simply discards it. The
console is seven bit, so no character above 127 survives the serial line.

One limitation worth knowing before it bites. The return stack here carries
more than usual: `DO` puts its loop control on it, entering a colon definition
puts the caller's instruction pointer on it, and machine code helpers push
their return addresses there too. `I` simply reads the top of it. So `I` inside
a *called* word sees that word's return address rather than the caller's loop
index, and `>R` inside a loop changes what `I` reads until the matching `R>`.

For the same reason `>R` and `R>` have to balance within a definition -
underneath whatever they push is the instruction pointer that `;` is about to
pop. That is true of any FORTH, but here the consequence is a jump to whatever
was pushed instead.

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

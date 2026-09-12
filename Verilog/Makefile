
PROJ = tangnano9k
BOARD = tangnano9k
FAMILY = GW1N-9C
DEVICE = GW1NR-LV9QN88PC6/I5

all: $(PROJ).fs

# The Diag board's DIP switches, which choose what diag does out of reset. 1d is the
# auxiliary test menu and 1a is TOS, the machine code monitor; see DiagBoard.v for the
# rest. Build a different setting with "make DIP=1a".
DIP ?= 1d

# Build the PSRAM's own bring-up self test instead of giving the memory to the CPU:
# "make PSRAM_SELFTEST=1". The status dump then reports the self test's result rather
# than the CPU's use of the memory. See PsramTest.v.
PSRAM_SELFTEST ?= 0

# Which program the ROM holds. The default is the real diag ROM, which is what
# the machine boots from; the load-* targets below wrap up the usual choices.
PROGRAM ?= programs/diag.txt
DMA_TEST ?= 0
# The front panel sense switches, as four binary digits. The OS bootstrap wants
# S2 and S4 - "OpSys" and "R/F" on the real panel - which is 1010; the emulator's
# verified CENTOS procedure calls that "sense = 10". Diag's own tests want 0001.
SENSE ?= 0001
# The mapping RAM failure instrumentation. Off: it found that bug, the bug is
# fixed, and the room it takes is what the storage stack now needs.
DIAG_TRACE ?= 0
# Whether the diag board's ROMs are fitted at physical 0x08000. They shadow 8K
# that the operating system loads code into, so booting it needs them out.
DIAG_ROM ?= 1
K13_INTERRUPTS ?= 1

# Assembling. "make programs/forth.txt" is enough, and both the synthesis and
# the simulation paths go through this rule, so a stale image can never be built
# into a bitstream or run by mistake. "make programs" assembles every source in
# asm/, which is a quick check that they all still assemble.
ASSEMBLER = ../tools/Assemble.py
SOURCES := $(wildcard asm/*.s)
IMAGES := $(patsubst asm/%.s,programs/%.txt,$(SOURCES))

programs/%.txt: asm/%.s $(ASSEMBLER)
	python3 $(ASSEMBLER) $< $@

programs: $(IMAGES)

# What the bitstream was built with is part of its identity, and none of it is a
# file that make can compare timestamps on. Without this stamp, "make load-forth"
# straight after "make load" would find tangnano9k.json up to date and program
# the board with diag again - the wrong build, silently, which is the sort of
# thing that costs an afternoon of debugging a machine that is not the one you
# think you are looking at.
CONFIG := PROGRAM=$(PROGRAM) DIP=$(DIP) PSRAM_SELFTEST=$(PSRAM_SELFTEST) DMA_TEST=$(DMA_TEST) SENSE=$(SENSE) DIAG_TRACE=$(DIAG_TRACE) DIAG_ROM=$(DIAG_ROM) K13=$(K13_INTERRUPTS)
build.stamp: FORCE
	@echo '$(CONFIG)' | cmp -s - $@ || { echo '$(CONFIG)' > $@; echo "build config: $(CONFIG)"; }
FORCE:

# -DSYNTHESIS hides the +prog= plusarg in BoardMemory from yosys: it cannot
# resolve $value$plusargs while re-elaborating that module, which is exactly what
# setting PROGRAM here makes it do.
$(PROJ).json: $(PROJ).v roms/CodeROM.txt Makefile *.v $(PROGRAM) build.stamp
	yosys -p 'read_verilog -DSYNTHESIS $(PROJ).v; chparam -set DIAG_DIP_SWITCHES 8'"'"'h$(DIP) -set PROGRAM "$(PROGRAM)" -set PSRAM_SELFTEST $(PSRAM_SELFTEST) -set DMA_TEST $(DMA_TEST) -set SENSE_SWITCHES 4'"'"'b$(SENSE) -set DIAG_TRACE $(DIAG_TRACE) -set DIAG_ROM $(DIAG_ROM) -set K13_INTERRUPTS $(K13_INTERRUPTS) $(PROJ); synth_gowin -top $(PROJ) -json $(PROJ).json'

$(PROJ)_pnr.json: $(BOARD).cst $(PROJ).json
	nextpnr-himbaechel --json $(PROJ).json --write $(PROJ)_pnr.json --freq 27 --device ${DEVICE} --vopt family=${FAMILY} --vopt cst=$(BOARD).cst

# PYTHONPATH pulls in tools/sitecustomize.py, which patches around an apycula bug
# that otherwise stops the rPLL being packed. See that file for the details.
$(PROJ).fs: $(PROJ)_pnr.json
	PYTHONPATH=$(CURDIR)/../tools gowin_pack -d ${FAMILY} -o $(PROJ).fs $(PROJ)_pnr.json

# Program Board. Four ways in, because these are the four things the machine is
# usually wanted for:
#   make load        the diag ROM, switches on the auxiliary test menu
#   make load-tos    the same ROM, switches set for the TOS machine code monitor
#   make load-forth  the FORTH, assembled from asm/forth.s first
#   make load-boot   boot the operating system off the disk image on the SD card
# Each rebuilds whatever the change of configuration invalidates; see build.stamp.
load: $(PROJ).fs
	openFPGALoader -b ${BOARD} $(PROJ).fs -f

load-tos:
	$(MAKE) DIP=1a load

load-forth:
	$(MAKE) PROGRAM=programs/forth.txt load

# Sense switch 1 is the boot PROM's own selector: its first instruction at
# 0xfc00 is BS1, and clear means boot the operating system where set means jump
# to 0x8001 and let the diag board take over. So this is the whole difference,
# and DIP does not come into it. The other two bits are S2 and S4, which is what
# the emulator's verified CENTOS procedure calls "sense = 10".
#
# Then type H1 at the D= prompt - the device letter and unit 1, no Enter. It
# reads the pack, loads it and runs it; it does not yet reach the OS banner, and
# sending 0x04 asks the board where the CPU stopped.
load-boot:
	$(MAKE) SENSE=1010 DIAG_ROM=0 load

test: CPU6TestBench TopTestBench PsramTB MapFailTB DmaTB HawkTB SdTB Fat32TB DiskTB ParityTB FinchTB sd_fat32.hex sd_fat32frag.hex sd_fat32long.hex
	vvp CPU6TestBench
	vvp TopTestBench
	vvp ParityTB
	vvp FinchTB
	vvp PsramTB
	vvp DmaTB
	vvp HawkTB
	vvp SdTB
	vvp Fat32TB
	vvp Fat32TB +image=sd_fat32frag.hex +fragmented
	vvp Fat32TB +image=sd_fat32long.hex +longname
	vvp DiskTB
	vvp DiskTB +image=sd_fat32frag.hex

# Simulates the real top level, including the LEDs and the UART pin, with stubs for
# the Gowin hard blocks. The other testbenches build their own replica of the board.
TopTestBench: *.v
	iverilog -o TopTestBench TopTestBench.v

# Runs one of diag's menu entries over the simulated serial link. Not part of "make
# test": it simulates hundreds of milliseconds of a 27MHz board and takes minutes.
# One of diag's own menu entries, which are the acceptance tests this project is
# aimed at. "make diagtest" runs the CPU test; "make diagtest TEST=05" runs the
# CMD seek test, and so on. Not part of "make test": it simulates a second of a
# 27MHz board and takes a quarter of an hour.
TEST ?= 1
diagtest: *.v
	iverilog -o DiagTestBench -PDiagTestTB.TEST=\"$(TEST)\" DiagTestBench.v
	vvp DiagTestBench

# The DMA path, both directions, against the pattern device in DmaTest.v.
dmatest: DmaTB
	vvp DmaTB

DmaTB: *.v programs/dmatest.txt
	iverilog -o DmaTB DmaTB.v

# The Hawk disk controller: registers, seek, and a sector out and back over DMA.
hawktest: HawkTB
	vvp HawkTB

# The SD card layer on its own, with no CPU and no bus: initialisation against a
# strict card model, then reads and writes.
sdtest: SdTB
	vvp SdTB

SdTB: *.v sd_pattern.hex
	iverilog -o SdTB SdTB.v

sd_pattern.hex: ../tools/MakeSdImage.py
	python3 ../tools/MakeSdImage.py pattern $@

# The FAT32 reader, against a volume built by mkfs.vfat and mcopy - once as a
# freshly copied file in one extent, once with its clusters deliberately
# scattered, because the extent table is the part most likely to be wrong.
fat32test: Fat32TB sd_fat32.hex sd_fat32frag.hex sd_fat32long.hex
	vvp Fat32TB
	vvp Fat32TB +image=sd_fat32frag.hex +fragmented
	vvp Fat32TB +image=sd_fat32long.hex +longname

Fat32TB: *.v
	iverilog -o Fat32TB Fat32TB.v

sd_fat32.hex: ../tools/MakeSdImage.py
	python3 ../tools/MakeSdImage.py fat32 $@

sd_fat32frag.hex: ../tools/MakeSdImage.py
	python3 ../tools/MakeSdImage.py fat32frag $@

sd_fat32long.hex: ../tools/MakeSdImage.py
	python3 ../tools/MakeSdImage.py fat32longname $@

# The whole storage stack with no CPU: card, filesystem and PSRAM cache, run
# against both a contiguous image and a fragmented one.
disktest: DiskTB sd_fat32.hex sd_fat32frag.hex
	vvp DiskTB
	vvp DiskTB +image=sd_fat32frag.hex

# The same, against a real Centurion disk image rather than a synthetic one -
# which is what says the controller reads real sectors from real offsets and not
# merely something self consistent. The images are in the Nakazoto archive under
# Software/Data Packs and are far too big to vendor, so point IMG at one:
#
#   make centostest IMG=~/Downloads/CENTOS_11.IMG
#
# Only the first SECTORS of it are used; a whole 6.6MB image is a fine thing to
# put on a card and a poor thing to ask iverilog to load.
IMG ?=
SECTORS ?= 256
centostest: DiskTB
	@test -n "$(IMG)" || (echo "set IMG to a Centurion disk image" && false)
	python3 ../tools/MakeSdImage.py hawk $(IMG) sd_real.hex $(SECTORS)
	python3 -c "import sys; d=open('$(IMG)','rb').read()[:$(SECTORS)*512]; 	    open('real_raw.hex','w').write(chr(10).join('%02x'%b for b in d))"
	vvp DiskTB +image=sd_real.hex +raw=real_raw.hex

DiskTB: *.v
	iverilog -o DiskTB DiskTB.v

HawkTB: *.v programs/hawktest.txt
	iverilog -o HawkTB HawkTB.v

ParityTB: *.v
	iverilog -g2005-sv -o ParityTB ParityTB.v

FinchTB: *.v
	iverilog -g2005-sv -o FinchTB FinchTB.v

DiagTestBench: *.v
	iverilog -o DiagTestBench DiagTestBench.v

CPU6TestBench: *.v
	iverilog -o CPU6TestBench CPU6TestBench.v

# The PSRAM PHY against a behavioural HyperRAM die. This proves the plumbing only -
# the model has no timing - but it is the difference between finding a byte pairing
# bug here and finding it with a three minute build-load-capture cycle on the board.
# Runs diag's mapping RAM test in simulation until its compare fails. Slow - the
# failure is thousands of passes in - but it stops exactly there, which is the one
# thing the board cannot do.
# The memory's parity bit and the F11 force bit that makes a write store the
# wrong one. The operating system tests the parity circuitry that way during
# startup and prints PARITY CIRCUITRY INOPERATIVE if the fault never arrives.
parity: ParityTB
	vvp ParityTB

# The Finch floppy controller's mailbox, against the exact byte sequence the
# operating system performs during startup. Only the host interface is modelled.
finch: FinchTB
	vvp FinchTB

mapfail: MapFailTB
	vvp MapFailTB

MapFailTB: *.v
	iverilog -o MapFailTB MapFailTB.v

# Assemble a program and run it on the whole simulated board, talking to it over
# the serial line. This is the loop for writing machine code for this machine:
# "make run SRC=asm/forth.s IN=asm/tests_forth.f". Program sources live in asm/
# and the assembled images they produce live in programs/.
SRC ?= asm/forth.s
IN ?=
FOR ?= 300
run: ProgramTB programs/$(basename $(notdir $(SRC))).txt
	vvp ProgramTB +prog=programs/$(basename $(notdir $(SRC))).txt \
	     $(if $(IN),+in=$(IN),) +for=$(FOR) $(RUNARGS)

ProgramTB: *.v
	iverilog -o ProgramTB ProgramTB.v

psramtest: PsramTB
	vvp PsramTB

PsramTB: *.v
	iverilog -o PsramTB PsramTB.v

.PHONY: all programs load load-tos load-forth load-boot test diagtest mapfail parity finch run \
	psramtest sdtest fat32test disktest centostest dmatest hawktest clean FORCE

clean:
	rm -f build.stamp
	rm $(PROJ).json $(PROJ).asc $(PROJ).bin $(PROJ).rpt CPU6TestBench TopTestBench DiagTestBench PsramTB MapFailTB

.PHONY: all prog clean test diagtest psramtest mapfail run sdtest fat32test disktest


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
CONFIG := PROGRAM=$(PROGRAM) DIP=$(DIP) PSRAM_SELFTEST=$(PSRAM_SELFTEST)
build.stamp: FORCE
	@echo '$(CONFIG)' | cmp -s - $@ || { echo '$(CONFIG)' > $@; echo "build config: $(CONFIG)"; }
FORCE:

# -DSYNTHESIS hides the +prog= plusarg in BoardMemory from yosys: it cannot
# resolve $value$plusargs while re-elaborating that module, which is exactly what
# setting PROGRAM here makes it do.
$(PROJ).json: $(PROJ).v roms/CodeROM.txt Makefile *.v $(PROGRAM) build.stamp
	yosys -p 'read_verilog -DSYNTHESIS $(PROJ).v; chparam -set DIAG_DIP_SWITCHES 8'"'"'h$(DIP) -set PROGRAM "$(PROGRAM)" -set PSRAM_SELFTEST $(PSRAM_SELFTEST) $(PROJ); synth_gowin -top $(PROJ) -json $(PROJ).json'

$(PROJ)_pnr.json: $(BOARD).cst $(PROJ).json
	nextpnr-himbaechel --json $(PROJ).json --write $(PROJ)_pnr.json --freq 27 --device ${DEVICE} --vopt family=${FAMILY} --vopt cst=$(BOARD).cst

# PYTHONPATH pulls in tools/sitecustomize.py, which patches around an apycula bug
# that otherwise stops the rPLL being packed. See that file for the details.
$(PROJ).fs: $(PROJ)_pnr.json
	PYTHONPATH=$(CURDIR)/../tools gowin_pack -d ${FAMILY} -o $(PROJ).fs $(PROJ)_pnr.json

# Program Board. Three ways in, because these are the three things the machine
# is usually wanted for:
#   make load        the diag ROM, switches on the auxiliary test menu
#   make load-tos    the same ROM, switches set for the TOS machine code monitor
#   make load-forth  the FORTH, assembled from asm/forth.s first
# Each rebuilds whatever the change of configuration invalidates; see build.stamp.
load: $(PROJ).fs
	openFPGALoader -b ${BOARD} $(PROJ).fs -f

load-tos:
	$(MAKE) DIP=1a load

load-forth:
	$(MAKE) PROGRAM=programs/forth.txt load

test: CPU6TestBench TopTestBench DiagTestBench PsramTB MapFailTB
	vvp CPU6TestBench
	vvp TopTestBench
	vvp PsramTB

# Simulates the real top level, including the LEDs and the UART pin, with stubs for
# the Gowin hard blocks. The other testbenches build their own replica of the board.
TopTestBench: *.v
	iverilog -o TopTestBench TopTestBench.v

# Runs one of diag's menu entries over the simulated serial link. Not part of "make
# test": it simulates hundreds of milliseconds of a 27MHz board and takes minutes.
diagtest: DiagTestBench
	vvp DiagTestBench

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

.PHONY: all programs load load-tos load-forth test diagtest mapfail run psramtest clean FORCE

clean:
	rm -f build.stamp
	rm $(PROJ).json $(PROJ).asc $(PROJ).bin $(PROJ).rpt CPU6TestBench TopTestBench DiagTestBench PsramTB MapFailTB

.PHONY: all prog clean test diagtest psramtest mapfail run

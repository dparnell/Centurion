
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

$(PROJ).json: $(PROJ).v roms/CodeROM.txt Makefile *.v
	yosys -p 'read_verilog $(PROJ).v; chparam -set DIAG_DIP_SWITCHES 8'"'"'h$(DIP) -set PSRAM_SELFTEST $(PSRAM_SELFTEST) $(PROJ); synth_gowin -top $(PROJ) -json $(PROJ).json'

$(PROJ)_pnr.json: $(BOARD).cst $(PROJ).json
	nextpnr-himbaechel --json $(PROJ).json --write $(PROJ)_pnr.json --freq 27 --device ${DEVICE} --vopt family=${FAMILY} --vopt cst=$(BOARD).cst

# PYTHONPATH pulls in tools/sitecustomize.py, which patches around an apycula bug
# that otherwise stops the rPLL being packed. See that file for the details.
$(PROJ).fs: $(PROJ)_pnr.json
	PYTHONPATH=$(CURDIR)/../tools gowin_pack -d ${FAMILY} -o $(PROJ).fs $(PROJ)_pnr.json

# Program Board
load: $(PROJ).fs
	openFPGALoader -b ${BOARD} $(PROJ).fs -f

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
run: ProgramTB
	python3 ../tools/Assemble.py $(SRC) programs/$(basename $(notdir $(SRC))).txt
	vvp ProgramTB +prog=programs/$(basename $(notdir $(SRC))).txt \
	     $(if $(IN),+in=$(IN),) +for=$(FOR) $(RUNARGS)

ProgramTB: *.v
	iverilog -o ProgramTB ProgramTB.v

psramtest: PsramTB
	vvp PsramTB

PsramTB: *.v
	iverilog -o PsramTB PsramTB.v

clean:
	rm $(PROJ).json $(PROJ).asc $(PROJ).bin $(PROJ).rpt CPU6TestBench TopTestBench DiagTestBench PsramTB MapFailTB

.PHONY: all prog clean test diagtest psramtest mapfail run


PROJ = tangnano9k
BOARD = tangnano9k
FAMILY = GW1N-9C
DEVICE = GW1NR-LV9QN88PC6/I5

all: $(PROJ).fs

# The Diag board's DIP switches, which choose what diag does out of reset. 1d is the
# auxiliary test menu and 1a is TOS, the machine code monitor; see DiagBoard.v for the
# rest. Build a different setting with "make DIP=1a".
DIP ?= 1d

$(PROJ).json: $(PROJ).v roms/CodeROM.txt Makefile *.v
	yosys -p 'read_verilog $(PROJ).v; chparam -set DIAG_DIP_SWITCHES 8'"'"'h$(DIP) $(PROJ); synth_gowin -top $(PROJ) -json $(PROJ).json'

$(PROJ)_pnr.json: $(BOARD).cst $(PROJ).json
	nextpnr-himbaechel --json $(PROJ).json --write $(PROJ)_pnr.json --freq 27 --device ${DEVICE} --vopt family=${FAMILY} --vopt cst=$(BOARD).cst

$(PROJ).fs: $(PROJ)_pnr.json
	gowin_pack -d ${FAMILY} -o $(PROJ).fs $(PROJ)_pnr.json

# Program Board
load: $(PROJ).fs
	openFPGALoader -b ${BOARD} $(PROJ).fs -f

test: CPU6TestBench TopTestBench DiagTestBench
	vvp CPU6TestBench
	vvp TopTestBench

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

clean:
	rm $(PROJ).json $(PROJ).asc $(PROJ).bin $(PROJ).rpt CPU6TestBench TopTestBench DiagTestBench

.PHONY: all prog clean test diagtest

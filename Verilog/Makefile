
PROJ = tangnano9k
BOARD = tangnano9k
FAMILY = GW1N-9C
DEVICE = GW1NR-LV9QN88PC6/I5

all: $(PROJ).fs

$(PROJ).json: $(PROJ).v roms/CodeROM.txt Makefile *.v
	yosys -p 'read_verilog $(PROJ).v; synth_gowin -top $(PROJ) -json $(PROJ).json'

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

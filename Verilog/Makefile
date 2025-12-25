
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

test: CPU6TestBench
	vvp CPU6TestBench

CPU6TestBench: *.v
	iverilog -o CPU6TestBench CPU6TestBench.v

clean:
	rm $(PROJ).json $(PROJ).asc $(PROJ).bin $(PROJ).rpt CPU6TestBench

.PHONY: all prog clean

# Usage:
#   make            run simulation with 0 wait states
#   make WAIT=3     run with 3 wait states
#   make all_waits  run with 0, 1 and 3 wait states
#   make wave       open the waveform in GTKWave (if installed)
#   make clean

WAIT ?= 0
SIM  = build/sim.out

all: run

$(SIM): rtl/apb_slave.sv tb/tb_apb_slave.sv
	@mkdir -p build
	iverilog -g2012 -Wall -Ptb_apb_slave.WAIT_STATES=$(WAIT) -o $(SIM) rtl/apb_slave.sv tb/tb_apb_slave.sv

run:
	@mkdir -p build
	iverilog -g2012 -Wall -Ptb_apb_slave.WAIT_STATES=$(WAIT) -o $(SIM) rtl/apb_slave.sv tb/tb_apb_slave.sv
	cd build && vvp sim.out

all_waits:
	@for w in 0 1 3; do $(MAKE) --no-print-directory run WAIT=$$w || exit 1; done

wave:
	gtkwave build/apb_slave.vcd &

clean:
	rm -rf build

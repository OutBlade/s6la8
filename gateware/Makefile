# Gateware checks that need no Xilinx tools.  Run in the dev container:
#   ./dev.sh make -C gateware sim lint synth-check
RTL := rtl/top.v rtl/clkgen.v rtl/capture.v rtl/afifo.v rtl/fx2_sfifo.v rtl/spi_regs.v

sim:
	@mkdir -p build
	iverilog -g2005 -DSIM -Wall -o build/tb_top.vvp sim/tb_top.v $(RTL)
	vvp -n build/tb_top.vvp | tee build/sim.log
	@grep -q "^PASS" build/sim.log

lint:
	verilator --lint-only -DSIM -Wall -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL --top-module top $(RTL)

# Resource estimate only; the real build is Xilinx ISE (see build/).
synth-check:
	@mkdir -p build
	yosys -q -l build/yosys.log -p "read_verilog $(RTL); synth_xilinx -family xc6s -top top; stat" > /dev/null
	@sed -n '/Number of cells/,$$p' build/yosys.log | head -40

.PHONY: sim lint synth-check

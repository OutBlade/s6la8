# Gateware checks that need no Xilinx tools.  Run in the dev container:
#   ./dev.sh make -C gateware sim lint synth-check
RTL := rtl/top.v rtl/clkgen.v rtl/capture.v rtl/afifo.v rtl/fx2_sfifo.v rtl/spi_regs.v rtl/dna_auth.v
MODELS := sim/DNA_PORT.v

sim:
	@mkdir -p build
	iverilog -g2005 -DSIM -Wall -Irtl -o build/tb_top.vvp sim/tb_top.v $(RTL) $(MODELS)
	vvp -n build/tb_top.vvp | tee build/sim.log
	@grep -q "^PASS" build/sim.log
	iverilog -g2005 -Wall -o build/tb_auth.vvp sim/tb_auth.v rtl/dna_auth.v $(MODELS)
	vvp -n build/tb_auth.vvp | tee build/sim_auth.log
	@grep -q "^PASS" build/sim_auth.log

lint:
	verilator --lint-only -DSIM -Wall -Irtl -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL --top-module top $(RTL) $(MODELS)

# Resource estimate only; the real build is Xilinx ISE (see ise/).
synth-check:
	@mkdir -p build
	yosys -q -l build/yosys.log -p "read_verilog -Irtl $(RTL); synth_xilinx -family xc6s -top top; stat" > /dev/null
	@sed -n '/Number of cells/,$$p' build/yosys.log | head -40

.PHONY: sim lint synth-check

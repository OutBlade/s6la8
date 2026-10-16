# Xilinx ISE 14.7 build for s6la8 (x86-64 only).  Usage, with ISE's settings
# sourced so that xst, ngdbuild, map, par, trce and bitgen are on PATH:
#
#   make -C gateware/ise bitstream
#
# Result: s6la8-fpga.bin (raw bitstream for upload) and a timing summary.
PART := xc6slx9-2-tqg144
TOP  := top
RTL  := $(addprefix ../rtl/,top.v clkgen.v capture.v afifo.v fx2_sfifo.v spi_regs.v dna_auth.v \
          sync_fifo.v sdram_ctrl.v ring_sdram.v ring_bram.v)
# PRODUCTION=1 builds with the secret key in ../rtl/auth_key.vh (tools/provision.py
# keyfile); such a bitstream only captures on provisioned boards.
PRODUCTION ?= 0
DEFINE := $(if $(filter 1,$(PRODUCTION)),-define {S6LA8_PRODUCTION},)
B    := work

bitstream: $(B)/$(TOP).bin
	cp $(B)/$(TOP).bin s6la8-fpga.bin
	@echo "--- timing summary"
	@grep -E "Timing errors|constraints? (were|was) not met|All constraints were met|Minimum period" $(B)/$(TOP).twr || true

$(B)/$(TOP).prj: $(RTL)
	@mkdir -p $(B)
	@for f in $(RTL); do echo "verilog work \"../$$f\""; done > $@

$(B)/$(TOP).ngc: $(B)/$(TOP).prj
	cd $(B) && printf 'run\n-ifn $(TOP).prj\n-ofn $(TOP)\n-ofmt NGC\n-p $(PART)\n-top $(TOP)\n-vlgincdir {../../rtl}\n$(DEFINE)\n-opt_mode Speed\n-opt_level 1\n-iob auto\n' > $(TOP).xst && xst -ifn $(TOP).xst -ofn $(TOP).syr

$(B)/$(TOP).ucf: pins.ucf timing.ucf
	@mkdir -p $(B)
	cat pins.ucf timing.ucf > $@

$(B)/$(TOP).ngd: $(B)/$(TOP).ngc $(B)/$(TOP).ucf
	cd $(B) && ngdbuild -p $(PART) -uc $(TOP).ucf $(TOP).ngc $(TOP).ngd

$(B)/$(TOP).ncd: $(B)/$(TOP).ngd
	cd $(B) && map -p $(PART) -w -pr b -o $(TOP)_map.ncd $(TOP).ngd $(TOP).pcf \
	  && par -w $(TOP)_map.ncd $(TOP).ncd $(TOP).pcf \
	  && trce -v 10 -o $(TOP).twr $(TOP).ncd $(TOP).pcf

$(B)/$(TOP).bin: $(B)/$(TOP).ncd
	cd $(B) && bitgen -w -g Binary:yes -g StartupClk:CCLK -g UnusedPin:Pullnone $(TOP).ncd $(TOP).bit $(TOP).pcf

clean:
	rm -rf $(B) s6la8-fpga.bin

.PHONY: bitstream clean

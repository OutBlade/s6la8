# FX2LP firmware for s6la8.  Build inside the dev container: ./dev.sh make -C firmware
SDCC ?= sdcc
SDAS ?= sdas8051
OBJCOPY ?= objcopy

BUILD := build
INC := -Iinclude -Ifx2lib/include
# Memory layout as in sigrok-firmware-fx2lafw.
LINK := --code-size 0x1c00 --xram-size 0x0200 --xram-loc 0x1c00 \
	-Wl"-b DSCR_AREA=0x1e00" -Wl"-b INT2JT=0x1f00"

C_SRC := s6la8.c fx2lib/lib/delay.c fx2lib/lib/eputils.c fx2lib/lib/setupdat.c fx2lib/lib/i2c.c \
	$(filter-out %/sudav_isr.c %/hispeed_isr.c %/usbreset_isr.c,$(wildcard fx2lib/lib/interrupts/*.c))
A_SRC := dscr.a51 fx2lib/lib/int4av.a51 fx2lib/lib/usbav.a51
# dscr.rel must come first so the linker places DSCR_AREA symbols it needs.
OBJ := $(BUILD)/dscr.rel $(BUILD)/s6la8.rel \
	$(patsubst %.c,$(BUILD)/%.rel,$(filter-out s6la8.c,$(C_SRC))) \
	$(BUILD)/fx2lib/lib/int4av.rel $(BUILD)/fx2lib/lib/usbav.rel

all: $(BUILD)/s6la8-fx2.fw
	@ls -l $(BUILD)/s6la8-fx2.fw
	@grep -E "^(CSEG|HOME|GSINIT|DSCR_AREA|INT2JT|XSEG)" $(BUILD)/s6la8-fx2.map | head -8 || true

$(BUILD)/%.rel: %.c
	@mkdir -p $(dir $@)
	$(SDCC) -mmcs51 $(INC) -c $< -o $@

$(BUILD)/%.rel: %.a51
	@mkdir -p $(dir $@)
	$(SDAS) -glos -Iinclude $@ $<

$(BUILD)/s6la8-fx2.ihx: $(OBJ)
	$(SDCC) -mmcs51 $(LINK) -o $@ $(OBJ)

$(BUILD)/s6la8-fx2.fw: $(BUILD)/s6la8-fx2.ihx
	$(OBJCOPY) -Iihex $< -Obinary $@

clean:
	rm -rf $(BUILD)

.PHONY: all clean

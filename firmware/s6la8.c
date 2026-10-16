/*
 * This file is part of the s6la8 project.
 *
 * Native-mode firmware for the FX2LP on the s6la8 logic analyzer.  It loads
 * the FPGA bitstream (slave serial), gives the host register access to the
 * FPGA over a bit-banged SPI link, and hands the EP2 IN FIFO to the FPGA in
 * synchronous slave-FIFO mode for sample data.
 *
 * Structure and USB plumbing follow sigrok-firmware-fx2lafw:
 * Copyright (C) 2011-2012 Uwe Hermann <uwe@hermann-uwe.de>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, see <http://www.gnu.org/licenses/>.
 */

#include <fx2regs.h>
#include <fx2macros.h>
#include <fx2ints.h>
#include <autovector.h>
#include <delay.h>
#include <setupdat.h>
#include <eputils.h>
#include <command.h>
#include <i2c.h>
#include <s6la8.h>

#define SYNCDELAY() SYNCDELAY4

volatile __bit got_sud;
static __bit configuring;

/* ------------------------------------------------------------------ pins */

static void pins_idle(void)
{
	/* PA1 LED and PA3 FB_OE_N are outputs; fallback buffer stays on. */
	PORTACFG = 0;
	FB_OE_N = 0;
	LED = 1;
	OEA = (1 << 1) | (1 << 3);

	/* Port D: everything released until the FPGA is being configured. */
	IOD = 0xff;
	OED = 0;
	OEB = 0;
}

/* ------------------------------------------------------------------ SPI */

static BYTE spi_xfer(BYTE out)
{
	BYTE i, in = 0;

	for (i = 0; i < 8; i++) {
		REG_MOSI = (out & 0x80) ? 1 : 0;
		out <<= 1;
		REG_SCK = 1;
		in <<= 1;
		if (REG_MISO)
			in |= 1;
		REG_SCK = 0;
	}
	return in;
}

/* ------------------------------------------------------------------ FPGA */

static BOOL fpga_config_begin(void)
{
	WORD timeout;

	/* The FPGA is about to own the FD bus: fallback buffer off. */
	FB_OE_N = 1;

	/* Ports mode, IFCLK still running at 48 MHz for the FPGA. */
	IFCONFIG = bmIFCLKSRC | bm3048MHZ | bmIFCLKOE;
	SYNCDELAY();

	/* M0 high selects slave serial; CCLK and DIN idle low. */
	M0 = 1;
	CCLK = 0;
	DIN = 0;
	REG_CS_N = 1;
	PROGRAM_B = 0;
	OED = (1 << 0) | (1 << 3) | (1 << 4) | (1 << 7);
	OEB = (1 << 7);
	delay(2);
	OED &= (BYTE)~(1 << 0);		/* release PROGRAM_B to its pull-up */

	for (timeout = 0; timeout < 500; timeout++) {
		if (INIT_B)
			break;
		delay(1);
	}
	configuring = INIT_B ? 1 : 0;
	return configuring;
}

/* Shift one EP6 packet into the FPGA, MSB first, DIN sampled on rising CCLK. */
static void fpga_shift_packet(void)
{
	WORD len = MAKEWORD(EP6BCH, EP6BCL);
	__xdata BYTE *p = EP6FIFOBUF;
	BYTE b, i;

	while (len--) {
		b = *p++;
		for (i = 0; i < 8; i++) {
			DIN = (b & 0x80) ? 1 : 0;
			b <<= 1;
			CCLK = 1;
			CCLK = 0;
		}
	}
	OUTPKTEND = 0x86;		/* skip: re-arm EP6 */
	SYNCDELAY();
}

static void reg_write(BYTE addr, BYTE len, BYTE *buf)
{
	BYTE i;

	REG_CS_N = 0;
	spi_xfer(addr & 0x7f);
	for (i = 0; i < len; i++)
		spi_xfer(buf[i]);
	REG_CS_N = 1;
}

/*
 * Hand the FPGA this board's authentication tag (written into the EEPROM at
 * production, see tools/provision.py) and start the check.  Production
 * bitstreams only capture once the tag matches the FPGA's Device DNA.
 */
static void fpga_authenticate(void)
{
	BYTE tag[8];
	BYTE go = 1;

	if (!eeprom_read(EEPROM_ADDR, EEPROM_TAG_OFFSET, sizeof(tag), tag))
		return;
	reg_write(REG_AUTH_TAG, sizeof(tag), tag);
	reg_write(REG_AUTH, 1, &go);
}

static void fpga_config_end(void)
{
	BYTE i;

	/* Start-up needs a few more clocks after the last data bit. */
	DIN = 1;
	for (i = 0; i < 64; i++) {
		CCLK = 1;
		CCLK = 0;
	}
	configuring = 0;
	OEB = 0;

	/* CCLK becomes REG_SCK; MOSI and CS are driven, MISO is an input. */
	REG_SCK = 0;
	REG_CS_N = 1;
	OED = (1 << 4) | (1 << 5) | (1 << 7);

	if (!DONE)
		FB_OE_N = 0;		/* configuration failed: fallback back on */
	else
		fpga_authenticate();
}

static BYTE status_byte(void)
{
	BYTE s = 0;

	if (DONE)
		s |= STATUS_DONE;
	if (INIT_B)
		s |= STATUS_INIT_B;
	if (!FPGA_IRQ_N)
		s |= STATUS_IRQ;
	if (!MODE)
		s |= STATUS_MODE_JUMPER;
	return s;
}

/* ------------------------------------------------------------------ FIFO */

static void acquisition(BOOL on)
{
	if (on) {
		/* Internal 48 MHz IFCLK, driven out, synchronous slave FIFO. */
		IFCONFIG = bmIFCLKSRC | bm3048MHZ | bmIFCLKOE | bmIFCFGMASK;
		SYNCDELAY();
		FIFOPINPOLAR = 0;
		SYNCDELAY();
		PINFLAGSAB = 0xc4;	/* FLAGA: EP2 PF, FLAGB: EP2 full */
		SYNCDELAY();
		PINFLAGSCD = 0x08;	/* FLAGC: EP2 empty */
		SYNCDELAY();
		RESETFIFO(0x02);
		EP2FIFOCFG = bmAUTOIN;
		SYNCDELAY();
		EP2AUTOINLENH = 0x02;
		SYNCDELAY();
		EP2AUTOINLENL = 0x00;
		SYNCDELAY();
		LED = 0;
	} else {
		RESETFIFO(0x02);
		EP2FIFOCFG = bmAUTOIN;
		SYNCDELAY();
		LED = 1;
	}
}

static void setup_endpoints(void)
{
	/* EP2: bulk IN, 512 bytes, quad buffered (sample data). */
	EP2CFG = 0xe0;
	SYNCDELAY();
	/* EP6: bulk OUT, 512 bytes, double buffered (bitstream). */
	EP6CFG = 0xa2;
	SYNCDELAY();
	EP1INCFG &= (BYTE)~bmVALID;
	SYNCDELAY();
	EP1OUTCFG &= (BYTE)~bmVALID;
	SYNCDELAY();
	EP4CFG &= (BYTE)~bmVALID;
	SYNCDELAY();
	EP8CFG &= (BYTE)~bmVALID;
	SYNCDELAY();

	RESETFIFO(0x02);
	RESETFIFO(0x06);

	/* All FIFOs 8 bits wide, otherwise port D is taken as FD[15:8]. */
	EP2FIFOCFG = bmAUTOIN;
	SYNCDELAY();
	EP4FIFOCFG = 0;
	SYNCDELAY();
	EP6FIFOCFG = 0;
	SYNCDELAY();
	EP8FIFOCFG = 0;
	SYNCDELAY();

	/* Arm both EP6 buffers (REVCTL has NOAUTOARM set). */
	OUTPKTEND = 0x86;
	SYNCDELAY();
	OUTPKTEND = 0x86;
	SYNCDELAY();
}

/* ------------------------------------------------------------------ USB */

static void ep0_wait_data(void)
{
	EP0BCL = 0;			/* arm EP0 for the OUT data stage */
	SYNCDELAY();
	while (EP0CS & bmEPBUSY)
		;
}

BOOL handle_vendorcommand(BYTE cmd)
{
	BYTE i, len = SETUPDAT[6];
	BYTE addr = SETUPDAT[2];

	switch (cmd) {
	case CMD_GET_FW_VERSION:
		EP0BUF[0] = S6LA8_VERSION_MAJOR;
		EP0BUF[1] = S6LA8_VERSION_MINOR;
		EP0BCH = 0;
		SYNCDELAY();
		EP0BCL = 2;
		SYNCDELAY();
		return TRUE;
	case CMD_GET_REVID_VERSION:
		EP0BUF[0] = REVID;
		EP0BCH = 0;
		SYNCDELAY();
		EP0BCL = 1;
		SYNCDELAY();
		return TRUE;
	case CMD_FPGA_CONFIG_BEGIN:
		acquisition(FALSE);
		return fpga_config_begin();
	case CMD_FPGA_CONFIG_END:
		fpga_config_end();
		/* fall through */
	case CMD_GET_STATUS:
		EP0BUF[0] = status_byte();
		EP0BCH = 0;
		SYNCDELAY();
		EP0BCL = 1;
		SYNCDELAY();
		return TRUE;
	case CMD_REG_WRITE:
		if (len > 64)
			return FALSE;
		ep0_wait_data();
		reg_write(addr, len, EP0BUF);
		return TRUE;
	case CMD_EEPROM_WRITE:
		/* Production only: the MODE jumper must be fitted. */
		if (len > 64 || MODE)
			return FALSE;
		ep0_wait_data();
		return eeprom_write(EEPROM_ADDR, SETUPDAT[2] | (SETUPDAT[3] << 8), len, EP0BUF);
	case CMD_EEPROM_READ:
		if (len > 64)
			return FALSE;
		if (!eeprom_read(EEPROM_ADDR, SETUPDAT[2] | (SETUPDAT[3] << 8), len, EP0BUF))
			return FALSE;
		EP0BCH = 0;
		SYNCDELAY();
		EP0BCL = len;
		SYNCDELAY();
		return TRUE;
	case CMD_REG_READ:
		if (len > 64)
			return FALSE;
		REG_CS_N = 0;
		spi_xfer(addr | 0x80);
		for (i = 0; i < len; i++)
			EP0BUF[i] = spi_xfer(0);
		REG_CS_N = 1;
		EP0BCH = 0;
		SYNCDELAY();
		EP0BCL = len;
		SYNCDELAY();
		return TRUE;
	case CMD_ACQUISITION:
		acquisition(addr ? TRUE : FALSE);
		return TRUE;
	}
	return FALSE;
}

BOOL handle_get_interface(BYTE ifc, BYTE *alt_ifc)
{
	if (ifc != 0)
		return FALSE;
	*alt_ifc = 0;
	return TRUE;
}

BOOL handle_set_interface(BYTE ifc, BYTE alt_ifc)
{
	if (ifc != 0 || alt_ifc != 0)
		return FALSE;
	RESETTOGGLE(0x82);
	RESETTOGGLE(0x06);
	RESETFIFO(0x02);
	return TRUE;
}

BYTE handle_get_configuration(void)
{
	return 1;
}

BOOL handle_set_configuration(BYTE cfg)
{
	return (cfg == 1) ? TRUE : FALSE;
}

void sudav_isr(void) __interrupt(SUDAV_ISR)
{
	got_sud = TRUE;
	CLEAR_SUDAV();
}

void usbreset_isr(void) __interrupt(USBRESET_ISR)
{
	handle_hispeed(FALSE);
	CLEAR_USBRESET();
}

void hispeed_isr(void) __interrupt(HISPEED_ISR)
{
	handle_hispeed(TRUE);
	CLEAR_HISPEED();
}

void main(void)
{
	/* Set DYN_OUT and ENH_PKT bits, as recommended by the TRM. */
	REVCTL = bmNOAUTOARM | bmSKIPCOMMIT;
	got_sud = FALSE;
	configuring = 0;

	pins_idle();
	RENUMERATE_UNCOND();
	SETCPUFREQ(CLK_48M);

	/* IFCLK out at 48 MHz from the start; the FPGA uses it as a clock. */
	IFCONFIG = bmIFCLKSRC | bm3048MHZ | bmIFCLKOE;
	SYNCDELAY();

	USE_USB_INTS();
	ENABLE_SUDAV();
	ENABLE_HISPEED();
	ENABLE_USBRESET();
	EA = 1;

	setup_endpoints();

	while (1) {
		if (got_sud) {
			handle_setupdata();
			got_sud = FALSE;
		}
		if (!(EP2468STAT & bmEP6EMPTY)) {
			if (configuring) {
				fpga_shift_packet();
			} else {
				OUTPKTEND = 0x86;	/* nothing wants it: drop */
				SYNCDELAY();
			}
		}
	}
}

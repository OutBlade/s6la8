/*
 * This file is part of the s6la8 project.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#ifndef S6LA8_INCLUDE_S6LA8_H
#define S6LA8_INCLUDE_S6LA8_H

/*
 * Protocol version, returned by CMD_GET_FW_VERSION.  Major 2 distinguishes
 * this firmware from fx2lafw (major 1); bump major on incompatible changes.
 */
#define S6LA8_VERSION_MAJOR	2
#define S6LA8_VERSION_MINOR	0

/* Vendor requests beyond the fx2lafw ones in command.h. */
#define CMD_FPGA_CONFIG_BEGIN	0xc0	/* OUT, no data: reset FPGA, expect bitstream on EP6 */
#define CMD_FPGA_CONFIG_END	0xc1	/* IN, 1 byte: finish start-up, return status */
#define CMD_REG_WRITE		0xc2	/* OUT, wValue = address, data = bytes */
#define CMD_REG_READ		0xc3	/* IN, wValue = address, wLength = bytes */
#define CMD_ACQUISITION		0xc4	/* OUT, wValue = 1 start / 0 stop */
#define CMD_GET_STATUS		0xc5	/* IN, 1 byte */
#define CMD_EEPROM_WRITE	0xc6	/* OUT, wValue = EEPROM address, MODE jumper fitted */
#define CMD_EEPROM_READ		0xc7	/* IN, wValue = EEPROM address */

/* 24LC128 with A0 tied high; the authentication tag lives in its last page. */
#define EEPROM_ADDR		0x51
#define EEPROM_TAG_OFFSET	0x3f00

/* FPGA registers (gateware/rtl/top.v). */
#define REG_AUTH		0x06	/* write 1: check tag; read: bit1 ok, bit0 DNA read */
#define REG_AUTH_TAG		0x30	/* 8 bytes, little endian */
#define REG_DNA			0x38	/* 8 bytes, little endian, read only */

#define STATUS_DONE		(1 << 0)
#define STATUS_INIT_B		(1 << 1)
#define STATUS_IRQ		(1 << 2)
#define STATUS_MODE_JUMPER	(1 << 3)

/* Board wiring; must match hardware/s6la8.zen. */
#define FPGA_IRQ_N	PA0
#define LED		PA1	/* high = on, as in fx2lafw */
#define FB_OE_N		PA3	/* low = fallback buffer drives FD[7:0] */
#define MODE		PA7

#define DIN		PB7	/* FD7 is wired to the FPGA's D0/DIN */

#define PROGRAM_B	PD0
#define INIT_B		PD1
#define DONE		PD2
#define M0		PD3
#define CCLK		PD4
#define REG_SCK		PD4
#define REG_MOSI	PD5
#define REG_MISO	PD6
#define REG_CS_N	PD7

#endif

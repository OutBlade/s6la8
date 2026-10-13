/*
 * This file is part of the libsigrok project.
 *
 * Copyright (C) 2026 OutBlade
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef LIBSIGROK_HARDWARE_S6LA8_PROTOCOL_H
#define LIBSIGROK_HARDWARE_S6LA8_PROTOCOL_H

#include <stdint.h>
#include <glib.h>
#include <libusb.h>
#include <libsigrok/libsigrok.h>
#include "libsigrok-internal.h"

#define LOG_PREFIX "s6la8"

/* pid.codes test PID; to be replaced by an assigned one. */
#define S6LA8_VID		0x1209
#define S6LA8_PID		0x0001

#define USB_INTERFACE		0
#define USB_CONFIGURATION	1
#define EP_DATA_IN		(2 | LIBUSB_ENDPOINT_IN)
#define EP_BITSTREAM_OUT	(6 | LIBUSB_ENDPOINT_OUT)
#define USB_TIMEOUT_MS		1000
#define MAX_RENUM_DELAY_MS	3000

#define FX2_FIRMWARE		"s6la8-fx2.fw"
#define FPGA_BITSTREAM		"s6la8-fpga.bin"
#define REQUIRED_FW_MAJOR	2

/* FX2 vendor requests (firmware/include/s6la8.h). */
#define CMD_GET_FW_VERSION	0xb0
#define CMD_FPGA_CONFIG_BEGIN	0xc0
#define CMD_FPGA_CONFIG_END	0xc1
#define CMD_REG_WRITE		0xc2
#define CMD_REG_READ		0xc3
#define CMD_ACQUISITION		0xc4
#define CMD_GET_STATUS		0xc5
#define STATUS_DONE		(1 << 0)

/* FPGA registers (gateware/rtl/top.v). */
#define REG_ID0			0x00
#define REG_ID1			0x01
#define REG_VERSION		0x02
#define REG_DEPTH_LOG2		0x03
#define REG_CTRL		0x04
#define REG_STATUS		0x05
#define REG_DIVIDER		0x08
#define REG_POST		0x0c
#define REG_PRE			0x10
#define REG_TRIGPOS		0x14
#define REG_STAGE0		0x18
#define REG_NSTAGES		0x28

#define CTRL_STREAM		(1 << 0)
#define CTRL_ARM		(1 << 1)
#define CTRL_RESET		(1 << 3)
#define CTRL_FORCE_TRIGGER	(1 << 4)
#define STAT_TRIGGERED		(1 << 2)
#define STAT_DONE		(1 << 3)
#define STAT_OVERFLOW		(1 << 4)

#define BASE_CLOCK_HZ		SR_MHZ(100)
#define MAX_STREAM_RATE		SR_MHZ(25)
#define NUM_CHANNELS		8
#define NUM_TRIGGER_STAGES	4
#define READ_CHUNK		(256 * 1024)

struct dev_context {
	uint64_t samplerate;
	uint64_t limit_samples;
	uint64_t capture_ratio;
	gboolean continuous;

	uint64_t depth;			/* samples in the hardware buffer */
	gint64 fw_updated;

	gboolean buffered;		/* current acquisition mode */
	gboolean reading;		/* buffered capture is being read out */
	uint64_t post;			/* samples recorded after the trigger */
	uint64_t expect;		/* bytes still to come */
	uint64_t sent;
	uint64_t trigger_at;
	gboolean trigger_sent;
	uint8_t *buf;
};

SR_PRIV int s6la8_dev_open(struct sr_dev_inst *sdi, struct sr_dev_driver *di);
SR_PRIV int s6la8_reg_write(const struct sr_dev_inst *sdi, uint8_t addr,
		const uint8_t *data, size_t len);
SR_PRIV int s6la8_reg_read(const struct sr_dev_inst *sdi, uint8_t addr,
		uint8_t *data, size_t len);
SR_PRIV int s6la8_fpga_upload(const struct sr_dev_inst *sdi);
SR_PRIV int s6la8_start(const struct sr_dev_inst *sdi);
SR_PRIV int s6la8_stop(const struct sr_dev_inst *sdi);
SR_PRIV int s6la8_receive_data(int fd, int revents, void *cb_data);

#endif

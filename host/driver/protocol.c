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

#include <config.h>
#include <string.h>
#include "protocol.h"

static int ctrl_in(const struct sr_dev_inst *sdi, uint8_t req, uint16_t value,
		uint8_t *data, uint16_t len)
{
	struct sr_usb_dev_inst *usb = sdi->conn;
	int ret;

	ret = libusb_control_transfer(usb->devhdl,
		LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_ENDPOINT_IN,
		req, value, 0, data, len, USB_TIMEOUT_MS);
	if (ret != len) {
		sr_err("Request 0x%02x failed: %s.", req,
			ret < 0 ? libusb_error_name(ret) : "short read");
		return SR_ERR;
	}
	return SR_OK;
}

static int ctrl_out(const struct sr_dev_inst *sdi, uint8_t req, uint16_t value,
		const uint8_t *data, uint16_t len)
{
	struct sr_usb_dev_inst *usb = sdi->conn;
	int ret;

	ret = libusb_control_transfer(usb->devhdl,
		LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_ENDPOINT_OUT,
		req, value, 0, (unsigned char *)data, len, USB_TIMEOUT_MS);
	if (ret != len) {
		sr_err("Request 0x%02x failed: %s.", req,
			ret < 0 ? libusb_error_name(ret) : "short write");
		return SR_ERR;
	}
	return SR_OK;
}

SR_PRIV int s6la8_reg_write(const struct sr_dev_inst *sdi, uint8_t addr,
		const uint8_t *data, size_t len)
{
	return ctrl_out(sdi, CMD_REG_WRITE, addr, data, len);
}

SR_PRIV int s6la8_reg_read(const struct sr_dev_inst *sdi, uint8_t addr,
		uint8_t *data, size_t len)
{
	return ctrl_in(sdi, CMD_REG_READ, addr, data, len);
}

static int reg_write8(const struct sr_dev_inst *sdi, uint8_t addr, uint8_t v)
{
	return s6la8_reg_write(sdi, addr, &v, 1);
}

static int reg_write32(const struct sr_dev_inst *sdi, uint8_t addr, uint32_t v)
{
	uint8_t b[4];

	write_u32le(b, v);
	return s6la8_reg_write(sdi, addr, b, sizeof(b));
}

SR_PRIV int s6la8_fpga_upload(const struct sr_dev_inst *sdi)
{
	struct drv_context *drvc = sdi->driver->context;
	struct sr_usb_dev_inst *usb = sdi->conn;
	struct dev_context *devc = sdi->priv;
	struct sr_resource res;
	uint8_t *buf, status, id[4];
	gssize chunk;
	int ret, sent;

	if (sr_resource_open(drvc->sr_ctx, &res, SR_RESOURCE_FIRMWARE,
			FPGA_BITSTREAM) != SR_OK)
		return SR_ERR;
	if (ctrl_out(sdi, CMD_FPGA_CONFIG_BEGIN, 0, NULL, 0) != SR_OK) {
		sr_err("FPGA did not enter configuration (INIT_B low).");
		sr_resource_close(drvc->sr_ctx, &res);
		return SR_ERR;
	}

	buf = g_malloc(4096);
	ret = SR_OK;
	while ((chunk = sr_resource_read(drvc->sr_ctx, &res, buf, 4096)) > 0) {
		/* The FX2 shifts each packet out bit by bit; allow for that. */
		if (libusb_bulk_transfer(usb->devhdl, EP_BITSTREAM_OUT, buf,
				chunk, &sent, 5 * USB_TIMEOUT_MS) < 0 || sent != chunk) {
			sr_err("Bitstream upload failed.");
			ret = SR_ERR;
			break;
		}
	}
	if (chunk < 0)
		ret = SR_ERR;
	g_free(buf);
	sr_resource_close(drvc->sr_ctx, &res);
	if (ret != SR_OK)
		return ret;

	/* Give the FX2 time to shift out the last packets. */
	g_usleep(50 * 1000);
	if (ctrl_in(sdi, CMD_FPGA_CONFIG_END, 0, &status, 1) != SR_OK)
		return SR_ERR;
	if (!(status & STATUS_DONE)) {
		sr_err("FPGA configuration failed (DONE low).");
		return SR_ERR;
	}

	if (s6la8_reg_read(sdi, REG_ID0, id, sizeof(id)) != SR_OK)
		return SR_ERR;
	if (id[0] != 'S' || id[1] != '6') {
		sr_err("Unexpected FPGA ID %02x %02x.", id[0], id[1]);
		return SR_ERR;
	}
	devc->depth = 1ULL << id[3];
	sr_info("FPGA gateware version %d, buffer %" PRIu64 " samples.",
		id[2], devc->depth);
	return SR_OK;
}

SR_PRIV int s6la8_dev_open(struct sr_dev_inst *sdi, struct sr_dev_driver *di)
{
	struct drv_context *drvc = di->context;
	struct sr_usb_dev_inst *usb = sdi->conn;
	struct libusb_device_descriptor des;
	libusb_device **devlist;
	char connection_id[64];
	uint8_t vi[2];
	int ret, i, count;

	count = libusb_get_device_list(drvc->sr_ctx->libusb_ctx, &devlist);
	if (count < 0)
		return SR_ERR;

	ret = SR_ERR;
	for (i = 0; i < count; i++) {
		libusb_get_device_descriptor(devlist[i], &des);
		if (des.idVendor != S6LA8_VID || des.idProduct != S6LA8_PID)
			continue;
		if (usb_get_port_path(devlist[i], connection_id,
				sizeof(connection_id)) < 0)
			continue;
		if (strcmp(sdi->connection_id, connection_id))
			continue;
		if (libusb_open(devlist[i], &usb->devhdl) != 0)
			break;
		if (usb->address == 0xff)
			usb->address = libusb_get_device_address(devlist[i]);
		if (ctrl_in(sdi, CMD_GET_FW_VERSION, 0, vi, sizeof(vi)) != SR_OK)
			break;
		if (vi[0] != REQUIRED_FW_MAJOR) {
			sr_err("Expected firmware version %d.x, got %d.%d.",
				REQUIRED_FW_MAJOR, vi[0], vi[1]);
			break;
		}
		sr_info("Opened device at %s, firmware %d.%d.",
			connection_id, vi[0], vi[1]);
		ret = SR_OK;
		break;
	}
	libusb_free_device_list(devlist, 1);
	return ret;
}

/* Translate the session trigger into the FPGA's four stage registers. */
static int setup_trigger(const struct sr_dev_inst *sdi, gboolean *have)
{
	struct sr_trigger *trigger;
	struct sr_trigger_stage *stage;
	struct sr_trigger_match *match;
	GSList *l, *m;
	uint8_t mask, value, rise, fall, bit;
	int n = 0;

	*have = FALSE;
	trigger = sr_session_trigger_get(sdi->session);
	for (l = trigger ? trigger->stages : NULL; l; l = l->next) {
		stage = l->data;
		mask = value = rise = fall = 0;
		for (m = stage->matches; m; m = m->next) {
			match = m->data;
			if (!match->channel->enabled)
				continue;
			bit = 1 << match->channel->index;
			switch (match->match) {
			case SR_TRIGGER_ONE:
				value |= bit;
				/* Fall through. */
			case SR_TRIGGER_ZERO:
				mask |= bit;
				break;
			case SR_TRIGGER_RISING:
				rise |= bit;
				break;
			case SR_TRIGGER_FALLING:
				fall |= bit;
				break;
			default:
				sr_err("Unsupported trigger condition.");
				return SR_ERR_NA;
			}
		}
		if (n >= NUM_TRIGGER_STAGES) {
			sr_err("At most %d trigger stages.", NUM_TRIGGER_STAGES);
			return SR_ERR_NA;
		}
		if (reg_write32(sdi, REG_STAGE0 + 4 * n, mask | (value << 8) |
				(rise << 16) | ((uint32_t)fall << 24)) != SR_OK)
			return SR_ERR;
		n++;
	}
	if (n) {
		*have = TRUE;
		return reg_write8(sdi, REG_NSTAGES, n - 1);
	}
	return SR_OK;
}

SR_PRIV int s6la8_start(const struct sr_dev_inst *sdi)
{
	struct dev_context *devc = sdi->priv;
	gboolean have_trigger;
	uint64_t pre, post;

	devc->buffered = !devc->continuous && devc->limit_samples > 0 &&
		devc->limit_samples <= devc->depth;
	if (!devc->buffered && devc->samplerate > MAX_STREAM_RATE) {
		sr_err("Streaming is limited to %" PRIu64 " Hz; set a sample "
			"limit of at most %" PRIu64 " for faster rates.",
			(uint64_t)MAX_STREAM_RATE, devc->depth);
		return SR_ERR_ARG;
	}

	if (reg_write8(sdi, REG_CTRL, CTRL_RESET) != SR_OK ||
	    ctrl_out(sdi, CMD_ACQUISITION, 1, NULL, 0) != SR_OK ||
	    reg_write32(sdi, REG_DIVIDER,
			BASE_CLOCK_HZ / devc->samplerate - 1) != SR_OK)
		return SR_ERR;

	devc->sent = 0;
	devc->reading = FALSE;
	devc->trigger_sent = FALSE;
	devc->buf = g_malloc(READ_CHUNK);

	if (devc->buffered) {
		if (setup_trigger(sdi, &have_trigger) != SR_OK)
			return SR_ERR;
		pre = have_trigger ?
			devc->limit_samples * devc->capture_ratio / 100 : 0;
		post = devc->limit_samples - pre;
		devc->post = post;
		if (reg_write32(sdi, REG_PRE, pre) != SR_OK ||
		    reg_write32(sdi, REG_POST, post) != SR_OK ||
		    reg_write8(sdi, REG_CTRL, CTRL_ARM |
				(have_trigger ? 0 : CTRL_FORCE_TRIGGER)) != SR_OK)
			return SR_ERR;
		/* Without a trigger the capture starts at once. */
		if (!have_trigger)
			devc->trigger_sent = TRUE;
	} else {
		if (sr_session_trigger_get(sdi->session))
			sr_warn("Triggers need a sample limit of at most %"
				PRIu64 "; ignored while streaming.", devc->depth);
		devc->trigger_sent = TRUE;
		if (reg_write8(sdi, REG_CTRL, CTRL_STREAM) != SR_OK)
			return SR_ERR;
	}
	return SR_OK;
}

SR_PRIV int s6la8_stop(const struct sr_dev_inst *sdi)
{
	struct dev_context *devc = sdi->priv;

	reg_write8(sdi, REG_CTRL, CTRL_RESET);
	ctrl_out(sdi, CMD_ACQUISITION, 0, NULL, 0);
	g_free(devc->buf);
	devc->buf = NULL;
	return SR_OK;
}

static void send_logic(const struct sr_dev_inst *sdi, const uint8_t *data,
		size_t len)
{
	struct sr_datafeed_logic logic = {
		.length = len, .unitsize = 1, .data = (void *)data,
	};
	struct sr_datafeed_packet packet = {
		.type = SR_DF_LOGIC, .payload = &logic,
	};

	if (len)
		sr_session_send(sdi, &packet);
}

/* Forward samples, inserting the trigger marker at its position. */
static void feed(const struct sr_dev_inst *sdi, const uint8_t *data, size_t len)
{
	struct dev_context *devc = sdi->priv;
	size_t before;

	if (!devc->trigger_sent && devc->trigger_at < devc->sent + len) {
		before = devc->trigger_at - devc->sent;
		send_logic(sdi, data, before);
		std_session_send_df_trigger(sdi);
		devc->trigger_sent = TRUE;
		send_logic(sdi, data + before, len - before);
	} else {
		send_logic(sdi, data, len);
	}
	devc->sent += len;
}

SR_PRIV int s6la8_receive_data(int fd, int revents, void *cb_data)
{
	const struct sr_dev_inst *sdi = cb_data;
	struct dev_context *devc = sdi->priv;
	struct sr_usb_dev_inst *usb = sdi->conn;
	uint8_t status, pos[4];
	uint64_t want;
	int got, ret;

	(void)fd;
	(void)revents;

	if (s6la8_reg_read(sdi, REG_STATUS, &status, 1) != SR_OK) {
		sr_dev_acquisition_stop((struct sr_dev_inst *)sdi);
		return TRUE;
	}

	if (devc->buffered && !devc->reading) {
		/* Still waiting for the trigger and the post-trigger fill. */
		if (!(status & STAT_TRIGGERED))
			return TRUE;
		if (s6la8_reg_read(sdi, REG_TRIGPOS, pos, sizeof(pos)) != SR_OK) {
			sr_dev_acquisition_stop((struct sr_dev_inst *)sdi);
			return TRUE;
		}
		devc->trigger_at = read_u32le(pos);
		devc->expect = devc->trigger_at + devc->post;
		devc->reading = TRUE;
	}
	if (!devc->buffered && (status & STAT_OVERFLOW)) {
		sr_err("Device FIFO overflow: the host is not keeping up at "
			"this sample rate.");
		sr_dev_acquisition_stop((struct sr_dev_inst *)sdi);
		return TRUE;
	}

	for (;;) {
		want = READ_CHUNK;
		if (devc->buffered)
			want = MIN(want, devc->expect);
		else if (devc->limit_samples)
			want = MIN(want, devc->limit_samples - devc->sent);
		if (want == 0)
			break;
		ret = libusb_bulk_transfer(usb->devhdl, EP_DATA_IN, devc->buf,
			(want + 511) & ~511ULL, &got, 20);
		if (got > 0) {
			got = MIN((uint64_t)got, want);
			feed(sdi, devc->buf, got);
			if (devc->buffered)
				devc->expect -= got;
		}
		if (ret != 0 || got == 0)
			break;
	}

	if ((devc->buffered && devc->reading && devc->expect == 0) ||
	    (!devc->buffered && devc->limit_samples &&
	     devc->sent >= devc->limit_samples))
		sr_dev_acquisition_stop((struct sr_dev_inst *)sdi);
	return TRUE;
}

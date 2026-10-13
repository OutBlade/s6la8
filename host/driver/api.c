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

static const uint32_t scanopts[] = {
	SR_CONF_CONN,
};

static const uint32_t drvopts[] = {
	SR_CONF_LOGIC_ANALYZER,
};

static const uint32_t devopts[] = {
	SR_CONF_CONTINUOUS | SR_CONF_GET | SR_CONF_SET,
	SR_CONF_LIMIT_SAMPLES | SR_CONF_GET | SR_CONF_SET,
	SR_CONF_SAMPLERATE | SR_CONF_GET | SR_CONF_SET | SR_CONF_LIST,
	SR_CONF_TRIGGER_MATCH | SR_CONF_LIST,
	SR_CONF_CAPTURE_RATIO | SR_CONF_GET | SR_CONF_SET,
};

static const int32_t trigger_matches[] = {
	SR_TRIGGER_ZERO,
	SR_TRIGGER_ONE,
	SR_TRIGGER_RISING,
	SR_TRIGGER_FALLING,
};

/* All are integer divisions of the 100 MHz sampling clock. */
static const uint64_t samplerates[] = {
	SR_KHZ(1), SR_KHZ(2), SR_KHZ(5), SR_KHZ(10), SR_KHZ(20), SR_KHZ(50),
	SR_KHZ(100), SR_KHZ(200), SR_KHZ(500),
	SR_MHZ(1), SR_MHZ(2), SR_MHZ(5), SR_MHZ(10), SR_MHZ(20), SR_MHZ(25),
	SR_MHZ(50), SR_MHZ(100),
};

static const char *channel_names[NUM_CHANNELS] = {
	"D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7",
};

static GSList *scan(struct sr_dev_driver *di, GSList *options)
{
	struct drv_context *drvc = di->context;
	struct dev_context *devc;
	struct sr_dev_inst *sdi;
	struct sr_channel_group *cg;
	struct sr_channel *ch;
	struct libusb_device_descriptor des;
	libusb_device **devlist;
	GSList *devices;
	char connection_id[64];
	size_t i, j;

	(void)options;

	devices = NULL;
	libusb_get_device_list(drvc->sr_ctx->libusb_ctx, &devlist);
	for (i = 0; devlist[i]; i++) {
		libusb_get_device_descriptor(devlist[i], &des);
		if (des.idVendor != S6LA8_VID || des.idProduct != S6LA8_PID)
			continue;
		if (usb_get_port_path(devlist[i], connection_id,
				sizeof(connection_id)) < 0)
			continue;

		sdi = g_malloc0(sizeof(struct sr_dev_inst));
		sdi->status = SR_ST_INITIALIZING;
		sdi->vendor = g_strdup("s6la8");
		sdi->model = g_strdup("Logic Analyzer");
		sdi->connection_id = g_strdup(connection_id);
		sdi->inst_type = SR_INST_USB;

		devc = g_malloc0(sizeof(struct dev_context));
		devc->samplerate = SR_MHZ(1);
		devc->capture_ratio = 10;
		sdi->priv = devc;

		cg = sr_channel_group_new(sdi, "Logic", NULL);
		for (j = 0; j < NUM_CHANNELS; j++) {
			ch = sr_channel_new(sdi, j, SR_CHANNEL_LOGIC, TRUE,
				channel_names[j]);
			cg->channels = g_slist_append(cg->channels, ch);
		}

		if (usb_match_manuf_prod(devlist[i], "s6la8",
				"s6la8 logic analyzer")) {
			sdi->status = SR_ST_INACTIVE;
			sdi->conn = sr_usb_dev_inst_new(
				libusb_get_bus_number(devlist[i]),
				libusb_get_device_address(devlist[i]), NULL);
		} else {
			if (ezusb_upload_firmware(drvc->sr_ctx, devlist[i],
					USB_CONFIGURATION, FX2_FIRMWARE) == SR_OK)
				devc->fw_updated = g_get_monotonic_time();
			else
				sr_err("Firmware upload failed for %s.",
					connection_id);
			sdi->conn = sr_usb_dev_inst_new(
				libusb_get_bus_number(devlist[i]), 0xff, NULL);
		}
		devices = g_slist_append(devices, sdi);
	}
	libusb_free_device_list(devlist, 1);

	return std_scan_complete(di, devices);
}

static int dev_open(struct sr_dev_inst *sdi)
{
	struct sr_dev_driver *di = sdi->driver;
	struct sr_usb_dev_inst *usb = sdi->conn;
	struct dev_context *devc = sdi->priv;
	int64_t elapsed_us;
	int ret;

	/* After a firmware upload the device needs time to renumerate. */
	ret = SR_ERR;
	if (devc->fw_updated > 0) {
		g_usleep(300 * 1000);
		do {
			if ((ret = s6la8_dev_open(sdi, di)) == SR_OK)
				break;
			g_usleep(100 * 1000);
			elapsed_us = g_get_monotonic_time() - devc->fw_updated;
		} while (elapsed_us < MAX_RENUM_DELAY_MS * 1000);
	} else {
		ret = s6la8_dev_open(sdi, di);
	}
	if (ret != SR_OK) {
		sr_err("Unable to open device.");
		return SR_ERR;
	}

	ret = libusb_claim_interface(usb->devhdl, USB_INTERFACE);
	if (ret != 0) {
		sr_err("Unable to claim interface: %s.", libusb_error_name(ret));
		return SR_ERR;
	}

	return s6la8_fpga_upload(sdi);
}

static int dev_close(struct sr_dev_inst *sdi)
{
	struct sr_usb_dev_inst *usb = sdi->conn;

	if (!usb->devhdl)
		return SR_ERR_BUG;
	libusb_release_interface(usb->devhdl, USB_INTERFACE);
	libusb_close(usb->devhdl);
	usb->devhdl = NULL;
	return SR_OK;
}

static int config_get(uint32_t key, GVariant **data,
	const struct sr_dev_inst *sdi, const struct sr_channel_group *cg)
{
	struct dev_context *devc;

	(void)cg;

	if (!sdi)
		return SR_ERR_ARG;
	devc = sdi->priv;

	switch (key) {
	case SR_CONF_SAMPLERATE:
		*data = g_variant_new_uint64(devc->samplerate);
		break;
	case SR_CONF_LIMIT_SAMPLES:
		*data = g_variant_new_uint64(devc->limit_samples);
		break;
	case SR_CONF_CAPTURE_RATIO:
		*data = g_variant_new_uint64(devc->capture_ratio);
		break;
	case SR_CONF_CONTINUOUS:
		*data = g_variant_new_boolean(devc->continuous);
		break;
	default:
		return SR_ERR_NA;
	}
	return SR_OK;
}

static int config_set(uint32_t key, GVariant *data,
	const struct sr_dev_inst *sdi, const struct sr_channel_group *cg)
{
	struct dev_context *devc;
	uint64_t value;
	size_t i;

	(void)cg;

	if (!sdi)
		return SR_ERR_ARG;
	devc = sdi->priv;

	switch (key) {
	case SR_CONF_SAMPLERATE:
		value = g_variant_get_uint64(data);
		for (i = 0; i < ARRAY_SIZE(samplerates); i++)
			if (samplerates[i] == value)
				break;
		if (i == ARRAY_SIZE(samplerates))
			return SR_ERR_ARG;
		devc->samplerate = value;
		break;
	case SR_CONF_LIMIT_SAMPLES:
		devc->limit_samples = g_variant_get_uint64(data);
		break;
	case SR_CONF_CAPTURE_RATIO:
		value = g_variant_get_uint64(data);
		if (value > 100)
			return SR_ERR_ARG;
		devc->capture_ratio = value;
		break;
	case SR_CONF_CONTINUOUS:
		devc->continuous = g_variant_get_boolean(data);
		break;
	default:
		return SR_ERR_NA;
	}
	return SR_OK;
}

static int config_list(uint32_t key, GVariant **data,
	const struct sr_dev_inst *sdi, const struct sr_channel_group *cg)
{
	switch (key) {
	case SR_CONF_SCAN_OPTIONS:
	case SR_CONF_DEVICE_OPTIONS:
		return STD_CONFIG_LIST(key, data, sdi, cg, scanopts, drvopts, devopts);
	case SR_CONF_SAMPLERATE:
		*data = std_gvar_samplerates(ARRAY_AND_SIZE(samplerates));
		break;
	case SR_CONF_TRIGGER_MATCH:
		*data = std_gvar_array_i32(ARRAY_AND_SIZE(trigger_matches));
		break;
	default:
		return SR_ERR_NA;
	}
	return SR_OK;
}

static int dev_acquisition_start(const struct sr_dev_inst *sdi)
{
	int ret;

	if ((ret = s6la8_start(sdi)) != SR_OK)
		return ret;
	std_session_send_df_header(sdi);
	/* Poll: status, then drain whatever the device has. */
	return sr_session_source_add(sdi->session, -1, 0, 10,
		s6la8_receive_data, (void *)sdi);
}

static int dev_acquisition_stop(struct sr_dev_inst *sdi)
{
	sr_session_source_remove(sdi->session, -1);
	s6la8_stop(sdi);
	std_session_send_df_end(sdi);
	return SR_OK;
}

static struct sr_dev_driver s6la8_driver_info = {
	.name = "s6la8",
	.longname = "s6la8 FX2LP + Spartan-6 logic analyzer",
	.api_version = 1,
	.init = std_init,
	.cleanup = std_cleanup,
	.scan = scan,
	.dev_list = std_dev_list,
	.dev_clear = std_dev_clear,
	.config_get = config_get,
	.config_set = config_set,
	.config_list = config_list,
	.dev_open = dev_open,
	.dev_close = dev_close,
	.dev_acquisition_start = dev_acquisition_start,
	.dev_acquisition_stop = dev_acquisition_stop,
	.context = NULL,
};
SR_REGISTER_DEV_DRIVER(s6la8_driver_info);

;;
;; This file is part of the s6la8 project.
;;
;; USB descriptors for native mode.  Layout follows sigrok-firmware-fx2lafw's
;; include/dscr.inc (Copyright (C) 2009 Ubixum, Inc., 2012 Uwe Hermann, 2012
;; Joel Holdsworth), with a second endpoint for the bitstream.
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2 of the License, or
;; (at your option) any later version.
;;

; 0x1209:0x0001 is the pid.codes test PID.  It must be replaced by an assigned
; PID before boards are distributed.
VID = 0x0912
PID = 0x0100

.include "common.inc"

.module DEV_DSCR

DSCR_DEVICE_TYPE	= 1
DSCR_CONFIG_TYPE	= 2
DSCR_STRING_TYPE	= 3
DSCR_INTERFACE_TYPE	= 4
DSCR_ENDPOINT_TYPE	= 5
DSCR_DEVQUAL_TYPE	= 6
DSCR_INTERFACE_LEN	= 9
DSCR_ENDPOINT_LEN	= 7
ENDPOINT_TYPE_BULK	= 2

.globl _dev_dscr, _dev_qual_dscr, _highspd_dscr, _fullspd_dscr, _dev_strings, _dev_strings_end
.area DSCR_AREA (CODE)

_dev_dscr:
	.db	dev_dscr_end - _dev_dscr
	.db	DSCR_DEVICE_TYPE
	.dw	0x0002			; USB 2.0
	.db	0xff, 0xff, 0xff	; vendor specific class
	.db	64			; Max. EP0 packet size
	.dw	VID
	.dw	PID
	.dw	0x0002			; Product version (2.00)
	.db	1			; Manufacturer string index
	.db	2			; Product string index
	.db	0			; No serial number string
	.db	1			; Number of configurations
dev_dscr_end:

_dev_qual_dscr:
	.db	dev_qualdscr_end - _dev_qual_dscr
	.db	DSCR_DEVQUAL_TYPE
	.dw	0x0002
	.db	0xff, 0xff, 0xff
	.db	64
	.db	1
	.db	0
dev_qualdscr_end:

_highspd_dscr:
	.db	highspd_dscr_end - _highspd_dscr
	.db	DSCR_CONFIG_TYPE
	.db	(highspd_dscr_realend - _highspd_dscr) % 256
	.db	(highspd_dscr_realend - _highspd_dscr) / 256
	.db	1			; Number of interfaces
	.db	1			; Configuration number
	.db	0
	.db	0x80			; Bus powered
	.db	0xfa			; 500 mA
highspd_dscr_end:
	.db	DSCR_INTERFACE_LEN
	.db	DSCR_INTERFACE_TYPE
	.db	0, 0
	.db	2			; Number of endpoints
	.db	0xff, 0xff, 0xff
	.db	0
	.db	DSCR_ENDPOINT_LEN
	.db	DSCR_ENDPOINT_TYPE
	.db	0x82			; EP2 IN: sample data
	.db	ENDPOINT_TYPE_BULK
	.db	0x00, 0x02		; 512 bytes
	.db	0x00
	.db	DSCR_ENDPOINT_LEN
	.db	DSCR_ENDPOINT_TYPE
	.db	0x06			; EP6 OUT: FPGA bitstream
	.db	ENDPOINT_TYPE_BULK
	.db	0x00, 0x02
	.db	0x00
highspd_dscr_realend:

	.even

_fullspd_dscr:
	.db	fullspd_dscr_end - _fullspd_dscr
	.db	DSCR_CONFIG_TYPE
	.db	(fullspd_dscr_realend - _fullspd_dscr) % 256
	.db	(fullspd_dscr_realend - _fullspd_dscr) / 256
	.db	1
	.db	1
	.db	0
	.db	0x80
	.db	0xfa
fullspd_dscr_end:
	.db	DSCR_INTERFACE_LEN
	.db	DSCR_INTERFACE_TYPE
	.db	0, 0
	.db	2
	.db	0xff, 0xff, 0xff
	.db	0
	.db	DSCR_ENDPOINT_LEN
	.db	DSCR_ENDPOINT_TYPE
	.db	0x82
	.db	ENDPOINT_TYPE_BULK
	.db	0x40, 0x00		; 64 bytes
	.db	0x00
	.db	DSCR_ENDPOINT_LEN
	.db	DSCR_ENDPOINT_TYPE
	.db	0x06
	.db	ENDPOINT_TYPE_BULK
	.db	0x40, 0x00
	.db	0x00
fullspd_dscr_realend:

	.even

_dev_strings:
string_descriptor_lang 0 0x0409
string_descriptor_a 1,^"s6la8"
string_descriptor_a 2,^"s6la8 logic analyzer"
_dev_strings_end:
	.dw	0x0000

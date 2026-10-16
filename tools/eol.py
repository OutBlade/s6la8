#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""End-of-line test and provisioning for one s6la8 board (needs pyusb + libusb).

    python tools/eol.py --key SECRET.key --fw firmware/build/s6la8-fx2.fw \\
                        --bit gateware/ise/s6la8-fpga.bin [--log eol-log.csv]

Fit the MODE jumper first (the firmware only writes the EEPROM with it fitted).
Steps: load the FX2 firmware into RAM, configure the FPGA, read the Device DNA,
write SipHash(key, DNA) to the EEPROM, ask the FPGA to check it, capture
4 M samples of the test pattern through the SDRAM at 100 MS/s and check every
byte, append a line to the log.
Exit code 0 means the board passed.
"""
import argparse
import csv
import datetime
import os
import sys
import time

import usb.core
import usb.util

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import provision  # noqa: E402

CYPRESS = (0x04B4, 0x8613)              # blank FX2LP
S6LA8 = (0x1209, 0x0001)                # firmware's IDs (replace the test PID before selling)
OUT = usb.util.CTRL_TYPE_VENDOR | usb.util.CTRL_OUT
IN = usb.util.CTRL_TYPE_VENDOR | usb.util.CTRL_IN
CMD_FW_VERSION, CMD_CONFIG_BEGIN, CMD_CONFIG_END = 0xB0, 0xC0, 0xC1
CMD_REG_WRITE, CMD_REG_READ, CMD_EEPROM_WRITE, CMD_EEPROM_READ = 0xC2, 0xC3, 0xC6, 0xC7
REG_ID, REG_AUTH, REG_AUTH_TAG, REG_DNA = 0x00, 0x06, 0x30, 0x38
REG_CTRL, REG_MEM, REG_DIVIDER, REG_POST, REG_PRE = 0x04, 0x07, 0x08, 0x0C, 0x10
CMD_ACQUISITION = 0xC4
CTRL_ARM, CTRL_TESTGEN, CTRL_RESET, CTRL_FORCE = 0x02, 0x04, 0x08, 0x10
MEMTEST_SAMPLES = 4 << 20               # 4 M samples through the SDRAM at 100 MS/s
STATUS_DONE = 1


def find(ids, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        for vid, pid in ids:
            d = usb.core.find(idVendor=vid, idProduct=pid)
            if d is not None:
                return d
        time.sleep(0.2)
    return None


def load_firmware(dev, image):
    """FX2 RAM load through the 0xA0 request, as fxload/ezusb do."""
    dev.ctrl_transfer(OUT, 0xA0, 0xE600, 0, b"\x01")          # hold the 8051 in reset
    for addr in range(0, len(image), 1024):
        dev.ctrl_transfer(OUT, 0xA0, addr, 0, image[addr:addr + 1024])
    dev.ctrl_transfer(OUT, 0xA0, 0xE600, 0, b"\x00")          # run; the device re-enumerates


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", required=True)
    ap.add_argument("--fw", required=True)
    ap.add_argument("--bit", required=True)
    ap.add_argument("--log", default="eol-log.csv")
    a = ap.parse_args()
    key = provision.load_key(a.key)
    result = {"time": datetime.datetime.now().isoformat(timespec="seconds"), "dna": "", "tag": "", "result": "FAIL", "step": ""}

    def fail(step, msg):
        result["step"] = step
        print("FAIL at %s: %s" % (step, msg))
        return finish(1)

    def finish(code):
        new = not os.path.exists(a.log)
        with open(a.log, "a", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(result))
            if new:
                w.writeheader()
            w.writerow(result)
        return code

    dev = find([S6LA8, CYPRESS], 5)
    if dev is None:
        return fail("usb", "no FX2 found (check cable, driver binding: WinUSB via Zadig on Windows)")
    if (dev.idVendor, dev.idProduct) == CYPRESS or dev.ctrl_transfer(IN, CMD_FW_VERSION, 0, 0, 2)[0] != 2:
        load_firmware(dev, open(a.fw, "rb").read())
        time.sleep(1.5)
        dev = find([S6LA8], 10)
        if dev is None:
            return fail("firmware", "device did not come back with the s6la8 firmware")
    dev.set_configuration()

    dev.ctrl_transfer(OUT, CMD_CONFIG_BEGIN, 0, 0, b"")
    bit = open(a.bit, "rb").read()
    for i in range(0, len(bit), 4096):
        dev.write(0x06, bit[i:i + 4096], timeout=5000)
    time.sleep(0.05)
    if not dev.ctrl_transfer(IN, CMD_CONFIG_END, 0, 0, 1)[0] & STATUS_DONE:
        return fail("fpga", "DONE stayed low")
    ident = bytes(dev.ctrl_transfer(IN, CMD_REG_READ, REG_ID, 0, 4))
    if ident[:2] != b"S6":
        return fail("fpga", "unexpected ID %s" % ident.hex())

    time.sleep(0.1)
    if not dev.ctrl_transfer(IN, CMD_REG_READ, REG_AUTH, 0, 1)[0] & 1:
        return fail("dna", "DNA not read")
    dna = int.from_bytes(bytes(dev.ctrl_transfer(IN, CMD_REG_READ, REG_DNA, 0, 8)), "little")
    tag = provision.tag(key, dna)
    result["dna"], result["tag"] = "%015x" % dna, "%016x" % tag
    tag_bytes = tag.to_bytes(8, "little")

    try:
        dev.ctrl_transfer(OUT, CMD_EEPROM_WRITE, provision.EEPROM_TAG_OFFSET, 0, tag_bytes)
    except usb.core.USBError:
        return fail("eeprom", "write refused - is the MODE jumper fitted?")
    time.sleep(0.02)
    if bytes(dev.ctrl_transfer(IN, CMD_EEPROM_READ, provision.EEPROM_TAG_OFFSET, 0, 8)) != tag_bytes:
        return fail("eeprom", "read-back mismatch")

    dev.ctrl_transfer(OUT, CMD_REG_WRITE, REG_AUTH_TAG, 0, tag_bytes)
    dev.ctrl_transfer(OUT, CMD_REG_WRITE, REG_AUTH, 0, b"\x01")
    time.sleep(0.01)
    if not dev.ctrl_transfer(IN, CMD_REG_READ, REG_AUTH, 0, 1)[0] & 2:
        return fail("auth", "FPGA rejected the tag (wrong key or bitstream?)")

    # SDRAM: capture the test pattern at the full rate and check every byte
    if not dev.ctrl_transfer(IN, CMD_REG_READ, REG_MEM, 0, 1)[0] & 0x80:
        return fail("sdram", "SDRAM did not initialise")
    u32 = lambda v: v.to_bytes(4, "little")
    dev.ctrl_transfer(OUT, CMD_REG_WRITE, REG_CTRL, 0, bytes([CTRL_RESET]))
    dev.ctrl_transfer(OUT, CMD_ACQUISITION, 1, 0, b"")
    dev.ctrl_transfer(OUT, CMD_REG_WRITE, REG_MEM, 0, b"")
    dev.ctrl_transfer(OUT, CMD_REG_WRITE, REG_DIVIDER, 0, u32(0))
    dev.ctrl_transfer(OUT, CMD_REG_WRITE, REG_PRE, 0, u32(0))
    dev.ctrl_transfer(OUT, CMD_REG_WRITE, REG_POST, 0, u32(MEMTEST_SAMPLES))
    dev.ctrl_transfer(OUT, CMD_REG_WRITE, REG_CTRL, 0, bytes([CTRL_ARM | CTRL_TESTGEN | CTRL_FORCE]))
    data = bytearray()
    while len(data) < MEMTEST_SAMPLES:
        try:
            data += dev.read(0x82, 1 << 16, timeout=3000)
        except usb.core.USBTimeoutError:
            break
    dev.ctrl_transfer(OUT, CMD_ACQUISITION, 0, 0, b"")
    dev.ctrl_transfer(OUT, CMD_REG_WRITE, REG_CTRL, 0, bytes([CTRL_RESET]))
    if len(data) < MEMTEST_SAMPLES:
        return fail("sdram", "only %d of %d bytes came back" % (len(data), MEMTEST_SAMPLES))
    breaks = sum(1 for i in range(1, MEMTEST_SAMPLES) if data[i] != (data[i - 1] + 1) & 0xFF)
    if breaks:
        return fail("sdram", "%d breaks in the test pattern (adjust CLKOUT1_PHASE in clkgen.v?)" % breaks)

    result["result"], result["step"] = "PASS", "done"
    print("PASS  DNA %s  serial label: S6LA8-%s" % (result["dna"], result["dna"][-8:].upper()))
    print("Remove the MODE jumper, re-plug and run a capture of the test pattern in PulseView.")
    return finish(0)


if __name__ == "__main__":
    sys.exit(main())

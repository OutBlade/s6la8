# Development image for s6la8: FX2 firmware (SDCC), gateware simulation and
# lint (Icarus, Verilator, Yosys, cocotb) and the libsigrok driver build.
# Xilinx ISE is not included; it is x86-64 only and runs on a separate machine.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git make pkg-config \
        python3 python3-dev python3-pip python3-venv \
        sdcc \
        iverilog verilator yosys \
        autoconf automake libtool check \
        libglib2.0-dev libzip-dev libusb-1.0-0-dev \
        srecord xxd \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir cocotb pytest
ENV PATH=/opt/venv/bin:$PATH

WORKDIR /work

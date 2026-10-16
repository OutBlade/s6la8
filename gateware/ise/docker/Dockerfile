# x86-64 Linux image for Xilinx ISE 14.7 builds.  Runs on x86-64 hosts
# natively and on Arm64 hosts (Windows on Arm, Apple Silicon) under Docker's
# x86-64 emulation.  ISE itself is not in the image: AMD's licence does not
# allow redistributing it, so it is installed once into a volume (see
# ../README-docker.md) and mounted at /opt/Xilinx.
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        make ca-certificates libglib2.0-0 libsm6 libxi6 libxrender1 libxrandr2 \
        libfreetype6 libfontconfig1 libncurses5 libxtst6 libxft2 xvfb x11-utils xterm \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
ENV XILINXD_LICENSE_FILE=/opt/Xilinx/Xilinx.lic
# settings64.sh puts xst, ngdbuild, map, par, trce and bitgen on PATH
ENTRYPOINT ["/bin/bash", "-c", ". /opt/Xilinx/14.7/ISE_DS/settings64.sh > /dev/null && exec \"$@\"", "--"]
CMD ["make", "-C", "gateware/ise", "bitstream"]

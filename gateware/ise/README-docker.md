# ISE 14.7 in Docker

The bitstream needs Xilinx ISE 14.7 WebPACK, which is x86-64 only and cannot
be redistributed. This recipe runs it in an x86-64 Linux container, also on
Arm machines through Docker's emulation (checked: `docker run --platform
linux/amd64 alpine uname -m` prints `x86_64` on the Snapdragon dev PC).
Emulated builds are slow; expect tens of minutes for this design.

## What you need from AMD (free account)

1. `Xilinx_ISE_DS_Lin_14.7_1015_1.tar` (about 6.5 GB) from
   AMD's ISE archive downloads page.
2. A free WebPACK licence file (`Xilinx.lic`) from AMD's product licensing
   site, node-locked to "any" host ID.

Put both in `C:\Xilinx-dl\` (any folder works; adjust the paths below).

## One-time install into a Docker volume

The ISE installer is graphical. On Windows, run an X server such as VcXsrv
("disable access control"), then:

```
docker build --platform linux/amd64 -t s6la8-ise gateware/ise/docker
docker volume create xilinx
docker run --rm -it --platform linux/amd64 -e DISPLAY=host.docker.internal:0 \
    -v xilinx:/opt/Xilinx -v C:\Xilinx-dl:/dl --entrypoint bash s6la8-ise
# inside the container:
cd /tmp && tar xf /dl/Xilinx_ISE_DS_Lin_14.7_1015_1.tar
./Xilinx_ISE_DS_Lin_14.7_1015_1/xsetup        # choose "ISE WebPACK", install to /opt/Xilinx
cp /dl/Xilinx.lic /opt/Xilinx/Xilinx.lic
```

## Every build

```
docker run --rm --platform linux/amd64 -v xilinx:/opt/Xilinx -v "%cd%:/work" s6la8-ise
docker run --rm --platform linux/amd64 -v xilinx:/opt/Xilinx -v "%cd%:/work" s6la8-ise \
    make -C gateware/ise bitstream PRODUCTION=1      # with gateware/rtl/auth_key.vh
```

The result is `gateware/ise/s6la8-fpga.bin` and a timing summary. Check that
the summary says "All constraints were met" and that `work/top.par` reports no
unrouted nets before using the bitstream.

On an x86-64 Linux machine with ISE already installed, skip Docker:
`source /opt/Xilinx/14.7/ISE_DS/settings64.sh && make -C gateware/ise bitstream`.

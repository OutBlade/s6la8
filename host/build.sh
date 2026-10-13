#!/usr/bin/env bash
# Build libsigrok with the s6la8 driver added.  Run in the dev container:
#   ./dev.sh host/build.sh
# libsigrok is cloned at a pinned commit into host/libsigrok (git-ignored).
set -euo pipefail
cd "$(dirname "$0")"

COMMIT=0bc2487778e660f4d3116729b6f4aee2b1996bb0
if [ ! -d libsigrok/.git ]; then
    git clone https://github.com/sigrokproject/libsigrok libsigrok
fi
git -C libsigrok checkout -q "$COMMIT"

D=libsigrok/src/hardware/s6la8
mkdir -p "$D"
cp driver/api.c driver/protocol.c driver/protocol.h "$D/"

# Register the driver with the build system, once.
grep -q 's6la8' libsigrok/configure.ac || sed -i \
    's|^SR_DRIVER(\[Saleae Logic16\].*|SR_DRIVER([s6la8], [s6la8], [libusb])\n&|' libsigrok/configure.ac
grep -q 'HW_S6LA8' libsigrok/Makefile.am || cat >> libsigrok/Makefile.am <<'EOF'
if HW_S6LA8
src_libdrivers_la_SOURCES += \
	src/hardware/s6la8/protocol.h \
	src/hardware/s6la8/protocol.c \
	src/hardware/s6la8/api.c
endif
EOF

cd libsigrok
[ -x configure ] || ./autogen.sh >/dev/null
[ -f Makefile ] || ./configure --disable-all-drivers --enable-s6la8 --enable-demo \
    --disable-python --disable-ruby --disable-java --disable-cxx >/dev/null
make -j"$(nproc)" 2>&1 | grep -E "warning|error|s6la8" || true
test -f .libs/libsigrok.so && echo "libsigrok built with the s6la8 driver"
nm -D .libs/libsigrok.so | grep -c sr_ >/dev/null
strings .libs/libsigrok.so | grep -m1 "s6la8 FX2LP"

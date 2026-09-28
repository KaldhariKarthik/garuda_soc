#!/bin/bash
# Run ON THE KRIA (sudo), from this directory. Needs out/garuda.bit.bin next to it.
#   sudo ./install_on_kria.sh          install + load
set -e
cd "$(dirname "$0")"
APP=/lib/firmware/xilinx/garuda
command -v dtc >/dev/null || apt-get install -y device-tree-compiler
dtc -@ -q -I dts -O dtb -o garuda.dtbo garuda.dtso
mkdir -p $APP
cp out/garuda.bit.bin garuda.dtbo shell.json $APP/
xmutil unloadapp || true
xmutil loadapp garuda
xmutil listapps
echo "--- GARUDA PL status:"
python3 host/garuda_host.py stat

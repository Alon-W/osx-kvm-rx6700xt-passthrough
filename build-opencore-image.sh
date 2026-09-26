#!/usr/bin/env bash
# Builds OpenCore/OpenCore-nootrx.qcow2 from OSX-KVM's stock OpenCore/OpenCore.qcow2:
#   - config.plist replaced with the verified one in opencore/config.plist
#   - Lilu replaced with 1.7.2 (1.6.8 leaves NootRX inert on Sequoia)
#   - NootRX.kext added right after Lilu, WhateverGreen disabled
#   - boot-args set to a known-good set
#   - optional SMBIOS (serials) from environment variables, never stored in the repo
#
# Usage:  ./build-opencore-image.sh <NootRX .zip or NootRX.kext> [--debug]
#   --debug  DEBUG Lilu/NootRX + verbose/serial boot-args (kernel log -> logs/serial-*.log)
# SMBIOS (generate with GenSMBIOS; keep them private):
#   SMBIOS_SERIAL=... SMBIOS_MLB=... SMBIOS_UUID=... SMBIOS_ROM=aabbccddeeff ./build-opencore-image.sh ...
set -euo pipefail

LILU_VERSION="1.7.2"
BOOT_ARGS="keepsyms=1 vmmforce=1 npci=0x2000 -lilubetaall"
DEBUG_ARGS="-v -liludbgall -NRXDebug debug=0x100 serial=3"
SMBIOS_MODEL="${SMBIOS_MODEL:-iMacPro1,1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOOTRX_SRC="${1:-}"
DEBUG=0; [ "${2:-}" = "--debug" ] && DEBUG=1
BASE="$SCRIPT_DIR/OpenCore/OpenCore.qcow2"
OUT="$SCRIPT_DIR/OpenCore/OpenCore-nootrx.qcow2"
[ $DEBUG = 1 ] && OUT="$SCRIPT_DIR/OpenCore/OpenCore-nootrx-debug.qcow2"

[ -n "$NOOTRX_SRC" ] && [ -e "$NOOTRX_SRC" ] || { echo "Usage: $0 <NootRX .zip or NootRX.kext> [--debug]"; exit 1; }
[ -f "$BASE" ] || { echo "[ERROR] $BASE not found. Run this from your OSX-KVM folder."; exit 1; }
[ -f "$SCRIPT_DIR/opencore/config.plist" ] || { echo "[ERROR] opencore/config.plist missing (copy the opencore/ folder too)"; exit 1; }
for t in qemu-img mcopy mdeltree sfdisk python3 curl unzip; do
    command -v $t >/dev/null || { echo "[ERROR] missing tool: $t (packages: qemu-img, mtools, util-linux, python3, curl, unzip)"; exit 1; }
done
export MTOOLS_SKIP_CHECK=1

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
BUILD=$([ $DEBUG = 1 ] && echo DEBUG || echo RELEASE)

echo "[1/5] Getting Lilu $LILU_VERSION ($BUILD)"
curl -fsSL -o "$W/lilu.zip" "https://github.com/acidanthera/Lilu/releases/download/$LILU_VERSION/Lilu-$LILU_VERSION-$BUILD.zip"
unzip -q "$W/lilu.zip" -d "$W/lilu"

echo "[2/5] Finding NootRX.kext ($BUILD) in $NOOTRX_SRC"
if [ -d "$NOOTRX_SRC" ]; then
    cp -r "$NOOTRX_SRC" "$W/NootRX.kext"
else
    unzip -q "$NOOTRX_SRC" -d "$W/n1"
    inner=$(find "$W/n1" -iname "NootRX-*-$BUILD.zip" | head -n 1)
    [ -n "$inner" ] && unzip -q "$inner" -d "$W/n1/inner"
    kext=$(find "$W/n1" -type d -name NootRX.kext -path "*${inner:+inner}*" | head -n 1)
    [ -n "$kext" ] || { echo "[ERROR] no NootRX.kext ($BUILD) inside $NOOTRX_SRC"; exit 1; }
    cp -r "$kext" "$W/NootRX.kext"
fi

echo "[3/5] Unpacking $(basename "$BASE")"
qemu-img convert -O raw "$BASE" "$W/oc.raw"
START=$(sfdisk -J "$W/oc.raw" | python3 -c 'import json,sys; print([p["start"] for p in json.load(sys.stdin)["partitiontable"]["partitions"] if p["type"].upper().startswith("C12A7328")][0])')
IMG="$W/oc.raw@@$((START * 512))"

echo "[4/5] Patching kexts and config.plist"
mdeltree -i "$IMG" ::/EFI/OC/Kexts/Lilu.kext
mdeltree -i "$IMG" ::/EFI/OC/Kexts/NootRX.kext 2>/dev/null || true
mcopy -s -i "$IMG" "$W/lilu/Lilu.kext" ::/EFI/OC/Kexts/
mcopy -s -i "$IMG" "$W/NootRX.kext" ::/EFI/OC/Kexts/
# The verified config (opencore/config.plist) replaces OSX-KVM's stock one; the stock
# image already contains every kext/driver/ACPI table it references.
cp "$SCRIPT_DIR/opencore/config.plist" "$W/config.plist"

ARGS="$BOOT_ARGS"; [ $DEBUG = 1 ] && ARGS="$ARGS $DEBUG_ARGS"
BOOT_ARGS_FINAL="$ARGS" SMBIOS_MODEL="$SMBIOS_MODEL" python3 - "$W/config.plist" <<'PY'
import os, plistlib, sys
p = sys.argv[1]
c = plistlib.load(open(p, "rb"))
kexts = [k for k in c["Kernel"]["Add"] if k["BundlePath"] != "NootRX.kext"]
for k in kexts:
    if k["BundlePath"] == "WhateverGreen.kext":
        k["Enabled"] = False          # conflicts with NootRX
    if k["BundlePath"] == "Lilu.kext":
        k["Enabled"] = True
lilu = next(i for i, k in enumerate(kexts) if k["BundlePath"] == "Lilu.kext")
kexts.insert(lilu + 1, {
    "Arch": "Any", "BundlePath": "NootRX.kext", "Comment": "Navi 22 (RX 6700 series)",
    "Enabled": True, "ExecutablePath": "Contents/MacOS/NootRX",
    "MaxKernel": "", "MinKernel": "", "PlistPath": "Contents/Info.plist",
})
c["Kernel"]["Add"] = kexts
c["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["boot-args"] = os.environ["BOOT_ARGS_FINAL"]
g = c["PlatformInfo"]["Generic"]
g["SystemProductName"] = os.environ["SMBIOS_MODEL"]
for env, key in (("SMBIOS_SERIAL", "SystemSerialNumber"), ("SMBIOS_MLB", "MLB"), ("SMBIOS_UUID", "SystemUUID")):
    if os.environ.get(env):
        g[key] = os.environ[env]
if os.environ.get("SMBIOS_ROM"):
    g["ROM"] = bytes.fromhex(os.environ["SMBIOS_ROM"].replace(":", ""))
plistlib.dump(c, open(p, "wb"))
print("    boot-args:", os.environ["BOOT_ARGS_FINAL"])
print("    SMBIOS:", g["SystemProductName"], "serial", "set" if os.environ.get("SMBIOS_SERIAL") else "placeholder")
PY
mcopy -o -i "$IMG" "$W/config.plist" ::/EFI/OC/config.plist

echo "[5/5] Writing $OUT"
qemu-img convert -O qcow2 "$W/oc.raw" "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "Done: $OUT"
[ -n "${SMBIOS_SERIAL:-}" ] || echo "Note: placeholder serials. Fine for testing; set SMBIOS_* for iCloud/iMessage."

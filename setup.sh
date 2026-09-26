#!/usr/bin/env bash
# Interactive setup: picks your GPU, VM size and USB devices, writes passthrough.conf.
# No root needed. Safe to rerun; the previous file is kept as passthrough.conf.bak.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$DIR/passthrough.conf"
. "$CONF"

ask() {  # ask <prompt> <default> -> echoes answer
    local a
    read -r -p "$1 [$2]: " a
    echo "${a:-$2}"
}
set_key() {  # set_key KEY VALUE  (VALUE written verbatim)
    local esc
    esc=$(printf '%s' "$2" | sed 's/[&|\\]/\\&/g')
    sed -i "s|^$1=.*|$1=$esc|" "$CONF.new"
}

echo "=== macOS GPU passthrough setup ==="
echo

# --- 1. GPU ------------------------------------------------------------
mapfile -t GPUS < <(lspci -Dnn | grep -E '\[03(00|02|80)\]')
[ ${#GPUS[@]} -gt 0 ] || { echo "[ERROR] no GPU found by lspci"; exit 1; }
echo "1) GPU to give to macOS:"
for i in "${!GPUS[@]}"; do echo "   $((i+1))) ${GPUS[$i]}"; done
n=$(ask "   Pick a number" 1)
GPU_LINE="${GPUS[$((n-1))]}"
VGA=$(echo "$GPU_LINE" | cut -d' ' -f1)
AUDIO="${VGA%.*}.1"
VGA_ID=$(lspci -n -s "$VGA" | awk '{print $3}')
AUDIO_ID=$(lspci -n -s "$AUDIO" 2>/dev/null | awk '{print $3}')
[ -n "$AUDIO_ID" ] || { echo "[ERROR] no audio function at $AUDIO; this setup expects GPU + HDMI audio"; exit 1; }
echo "   GPU   $VGA ($VGA_ID)"
echo "   Audio $AUDIO ($AUDIO_ID)"
[ "$VGA_ID" = "1002:73df" ] || echo "   Note: not a Navi 22 card (1002:73df). The NootRX part of this project may not apply."

for dev in "$VGA" "$AUDIO"; do
    grp=$(basename "$(readlink "/sys/bus/pci/devices/$dev/iommu_group" 2>/dev/null)" 2>/dev/null || true)
    if [ -z "$grp" ]; then
        echo "   [WARNING] no IOMMU group for $dev. Enable IOMMU/SVM in the BIOS and add amd_iommu=on."
        continue
    fi
    others=$(ls "/sys/kernel/iommu_groups/$grp/devices" | grep -v -e "^$VGA$" -e "^$AUDIO$" || true)
    [ -z "$others" ] || echo "   [WARNING] IOMMU group $grp also contains: $others (they must be passed too, or passthrough fails)"
done
echo

# --- 2. RAM --------------------------------------------------------------
TOTAL_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
SUGGEST_RAM=$(( TOTAL_MB / 2 / 1024 * 1024 ))
[ "$SUGGEST_RAM" -gt 16384 ] && SUGGEST_RAM=16384
echo "2) RAM for macOS (host has $TOTAL_MB MiB; keep at least 2048 for Linux)"
RAM=$(ask "   MiB" "$SUGGEST_RAM")
echo

# --- 3. CPU --------------------------------------------------------------
PHYS=$(lscpu -p=core | grep -v '^#' | sort -u | wc -l)
SUGGEST_CORES=$(( PHYS > 4 ? PHYS - 2 : PHYS / 2 ))
echo "3) CPU cores for macOS (host has $PHYS physical cores; leaving 2 for Linux is a good default)"
CORES=$(ask "   Cores" "$SUGGEST_CORES")
echo

# --- 4. USB --------------------------------------------------------------
mapfile -t USBS < <(lsusb | grep -v 'ID 1d6b:' | sort -k6)
echo "4) USB devices to give to macOS while it runs (at least a keyboard and a mouse):"
for i in "${!USBS[@]}"; do
    echo "   $((i+1))) $(echo "${USBS[$i]}" | sed -E 's/^Bus [0-9]+ Device [0-9]+: //')"
done
read -r -p "   Numbers separated by spaces (e.g. 1 3): " picks
USB_LIST=()
for p in $picks; do
    id=$(echo "${USBS[$((p-1))]}" | grep -oE 'ID [0-9a-f]{4}:[0-9a-f]{4}' | cut -d' ' -f2)
    [ -n "$id" ] && USB_LIST+=("\"$id\"")
done
echo

# --- Write ---------------------------------------------------------------
cp "$CONF" "$CONF.new"
set_key GPU_VGA "\"$VGA\""
set_key GPU_AUDIO "\"$AUDIO\""
set_key GPU_VGA_ID "\"$VGA_ID\""
set_key GPU_AUDIO_ID "\"$AUDIO_ID\""
set_key VM_RAM_MB "$RAM"
set_key VM_CORES "$CORES"
set_key USB_DEVICES "(${USB_LIST[*]})"

echo "=== Summary ==="
grep -E '^(GPU_|VM_RAM|VM_CORES|USB_DEVICES)' "$CONF.new" | sed 's/^/   /'
read -r -p "Save to passthrough.conf? [Y/n]: " ok
case "${ok:-y}" in
    [Yy]*) cp "$CONF" "$CONF.bak"; mv "$CONF.new" "$CONF"; echo "Saved (previous version: passthrough.conf.bak)." ;;
    *)     rm -f "$CONF.new"; echo "Not saved."; exit 0 ;;
esac

cat <<EOF

Next steps:
  1. ./build-opencore-image.sh <NootRX zip>     builds the OpenCore image
  2. sudo ./install-passthrough-boot.sh         installs the boot entry and menu entry
EOF

#!/usr/bin/env bash
# Run over SSH if the screen stays black:  sudo ./emergency-restore.sh
#   Isolated boot: only kills QEMU (reboot into the normal entry for the desktop).
#   Normal boot:   kills QEMU, hands the GPU back to amdgpu, restarts the desktop.
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/passthrough.conf"
vfio_id() { echo "${1/:/ }"; }

# Ask QEMU to quit first (it then returns USB devices to Linux), force-kill only if stuck.
# The launcher's own cleanup then restores the desktop; the steps below repeat it as a fallback.
pkill -TERM -f qemu-system-x86 2>/dev/null || true
for _ in $(seq 10); do pgrep -f qemu-system-x86 >/dev/null || break; sleep 1; done
pkill -9 -f qemu-system-x86 2>/dev/null || true
sleep 2
for id in "${USB_DEVICES[@]}"; do
    for d in /sys/bus/usb/devices/*; do
        [ "$(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)" = "$id" ] || continue
        echo 0 > "$d/authorized"; sleep 0.5; echo 1 > "$d/authorized"
    done
done

if grep -q 'vfio_pci.ids=' /proc/cmdline; then
    echo "Isolated boot: GPU stays on vfio-pci. Relaunch the VM, or reboot into the normal entry."
    exit 0
fi

# Give a still-running launcher up to 60 s to restore the desktop itself
for _ in $(seq 60); do pgrep -f boot-gpu-passthrough.sh >/dev/null || break; sleep 1; done
if [ "$(basename "$(readlink "/sys/bus/pci/devices/$GPU_VGA/driver" 2>/dev/null)")" = "amdgpu" ]; then
    systemctl is-active --quiet "$DISPLAY_MANAGER" || systemctl restart "$DISPLAY_MANAGER"
    echo "=== GPU already back on amdgpu; desktop restored ==="
    exit 0
fi

for dev in "$GPU_VGA" "$GPU_AUDIO"; do
    [ -e "/sys/bus/pci/drivers/vfio-pci/$dev" ] && echo "$dev" > /sys/bus/pci/drivers/vfio-pci/unbind
    echo "" > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null || true
done
vfio_id "$GPU_VGA_ID"   > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
vfio_id "$GPU_AUDIO_ID" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true

echo 1 > "/sys/bus/pci/devices/$GPU_VGA/remove" 2>/dev/null || true
echo 1 > "/sys/bus/pci/devices/$GPU_AUDIO/remove" 2>/dev/null || true
sleep 1
rtcwake -m mem -s 3
echo 1 > /sys/bus/pci/rescan
sleep 2

modprobe amdgpu 2>/dev/null || true
modprobe snd_hda_intel 2>/dev/null || true
sleep 2
for vt in /sys/class/vtconsole/vtcon*/bind; do echo 1 > "$vt" 2>/dev/null || true; done
systemctl restart "$DISPLAY_MANAGER"
echo "=== Restore complete ==="

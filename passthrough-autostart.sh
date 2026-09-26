#!/usr/bin/env bash
# Run by macos-passthrough-boot.service at boot. Starts the VM only when the
# host was booted via the passthrough GRUB entry; otherwise does nothing.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! grep -q 'vfio_pci.ids=' /proc/cmdline; then
    echo "Normal boot (no vfio_pci.ids in cmdline): nothing to do."
    exit 0
fi
echo "Isolated passthrough boot detected: launching VM."
exec bash "$SCRIPT_DIR/boot-gpu-passthrough.sh"

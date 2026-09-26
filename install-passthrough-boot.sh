#!/usr/bin/env bash
# One-time host setup. Run from inside your OSX-KVM folder (where these files were copied).
#   sudo ./install-passthrough-boot.sh            install / refresh everything
#   sudo ./install-passthrough-boot.sh --next     install, then reboot once into the passthrough entry
#   ./install-passthrough-boot.sh --dry-run       show what would happen
# Installs: GRUB entry generator, modprobe config, autostart service, desktop menu entry.
# Your default boot entry is not changed.
set -euo pipefail

DRY_RUN=0; NEXT=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        --next)    NEXT=1 ;;
        *) echo "Usage: $0 [--dry-run] [--next]"; exit 1 ;;
    esac
done
if [ "$EUID" -ne 0 ] && [ "$DRY_RUN" = "0" ]; then
    echo "[!] Run as root: sudo $0   (or $0 --dry-run)"; exit 1
fi

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$INSTALL_DIR/passthrough.conf"

log() { echo "[installer] $*"; }
run() {
    log "$1"; shift
    if [ "$DRY_RUN" = "1" ]; then echo "    DRY-RUN: $*"; return 0; fi
    "$@"
}
write() {  # write <dest> <content>
    log "Writing $1"
    if [ "$DRY_RUN" = "1" ]; then printf '%s\n' "$2" | sed 's/^/    | /'; return 0; fi
    printf '%s\n' "$2" > "$1"
}

[ -f "$INSTALL_DIR/OVMF_CODE_4M.fd" ] || log "WARNING: OVMF_CODE_4M.fd not found here. Copy these files into your OSX-KVM folder first."

if command -v grub2-mkconfig >/dev/null; then
    MKCONFIG=grub2-mkconfig; GRUB_REBOOT=grub2-reboot; GRUB_CFG=/boot/grub2/grub.cfg
else
    MKCONFIG=grub-mkconfig; GRUB_REBOOT=grub-reboot; GRUB_CFG=/boot/grub/grub.cfg
fi
command -v "$MKCONFIG" >/dev/null || { echo "[ERROR] GRUB not found; this setup needs GRUB."; exit 1; }

# 1. Module ordering only. Claiming the GPU happens solely via vfio_pci.ids= on the
#    passthrough boot entry, so normal boots keep their desktop.
write /etc/modprobe.d/vfio-macos-gpu.conf "# Managed by install-passthrough-boot.sh
softdep snd_hda_intel pre: vfio-pci
softdep amdgpu pre: vfio-pci"
write /etc/modprobe.d/kvm-gpu-passthrough.conf "# Managed by install-passthrough-boot.sh
options kvm ignore_msrs=1"

# 2. GRUB entry generator
GEN=$(sed -e "s|@VFIO_IDS@|$GPU_VGA_ID,$GPU_AUDIO_ID|" -e "s|@KERNEL_MATCH@|$KERNEL_MATCH|" "$INSTALL_DIR/grub.d/42_macos_passthrough")
write /etc/grub.d/42_macos_passthrough "$GEN"
run "Making generator executable" chmod 0755 /etc/grub.d/42_macos_passthrough
run "Regenerating $GRUB_CFG" "$MKCONFIG" -o "$GRUB_CFG"

# 3. Autostart service (starts the VM only on the passthrough entry)
write /etc/systemd/system/macos-passthrough-boot.service "$(sed "s|@INSTALL_DIR@|$INSTALL_DIR|g" "$INSTALL_DIR/macos-passthrough-boot.service")"
run "Enabling autostart service" sh -c "systemctl daemon-reload && systemctl enable macos-passthrough-boot.service"

# 4. Desktop menu entry for the invoking user
DESK_USER="${SUDO_USER:-$USER}"
DESK_HOME=$(getent passwd "$DESK_USER" | cut -d: -f6)
DESK_FILE="$DESK_HOME/.local/share/applications/macos-gpu-passthrough.desktop"
run "Creating $(dirname "$DESK_FILE")" mkdir -p "$(dirname "$DESK_FILE")"
write "$DESK_FILE" "$(sed "s|@INSTALL_DIR@|$INSTALL_DIR|g" "$INSTALL_DIR/macos-gpu-passthrough.desktop")"
run "Setting owner of menu entry" chown "$DESK_USER:" "$DESK_FILE"

# 5. vfio_pci must be in the initramfs for rd.driver.pre=vfio_pci
if command -v lsinitrd >/dev/null && [ "$DRY_RUN" = "0" ]; then
    if ! lsinitrd 2>/dev/null | grep -q 'vfio-pci\.ko'; then
        write /etc/dracut.conf.d/vfio-macos-gpu.conf 'force_drivers+=" vfio_pci vfio vfio_iommu_type1 "'
        log "vfio_pci is not in your initramfs yet. Run:  sudo dracut -f --regenerate-all"
    fi
fi

if [ "$DRY_RUN" = "0" ]; then
    grep -q "menuentry 'Linux - macOS GPU Passthrough'" "$GRUB_CFG" \
        && log "GRUB entry installed: 'Linux - macOS GPU Passthrough'" \
        || { echo "[ERROR] entry not found in $GRUB_CFG"; exit 1; }
fi

if [ "$NEXT" = "1" ]; then
    run "Booting the passthrough entry once on next reboot" "$GRUB_REBOOT" macos-gpu-passthrough
    log "Rebooting now..."
    [ "$DRY_RUN" = "1" ] || systemctl reboot
    exit 0
fi

cat <<EOF

Done. Two ways to run macOS:
  A) From the desktop: app menu -> "macOS (GPU passthrough)". The desktop closes,
     macOS takes the GPU, and the desktop returns when macOS shuts down.
  B) Dedicated boot: sudo $0 --next  (or pick "Linux - macOS GPU Passthrough" in GRUB).
     The host is headless; the VM starts automatically. Reboot to get Linux back.
Stuck on a black screen: SSH in and run  sudo $INSTALL_DIR/emergency-restore.sh
EOF

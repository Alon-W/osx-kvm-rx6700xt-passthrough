#!/usr/bin/env bash
# ============================================================
# macOS single-GPU passthrough launcher (AMD RX 6700 XT / Navi 22 + NootRX)
#
# Two modes, auto-detected:
#   ISOLATED  host was booted via the "macOS GPU Passthrough" GRUB entry,
#             so vfio-pci owns the GPU from boot. Host is headless; use SSH.
#   RUNTIME   normal desktop boot. Stops the display manager, resets the GPU
#             (PCI remove -> S3 sleep -> rescan), runs macOS, and restores the
#             desktop when macOS shuts down.
#
# Usage:  sudo ./boot-gpu-passthrough.sh [--dry-run]
#         OC_IMAGE=path/to/other.qcow2 sudo -E ./boot-gpu-passthrough.sh
# Recover a black screen (from SSH):  sudo ./emergency-restore.sh
# ============================================================
set -u

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if [ "$EUID" -ne 0 ] && [ "$DRY_RUN" = "0" ]; then
    echo "[!] Run as root: sudo $0   (or $0 --dry-run for a preview)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=passthrough.conf
. "$SCRIPT_DIR/passthrough.conf"
# Disk images, OVMF and logs live in the OSX-KVM folder. When installed to the root-owned
# /usr/local/lib/macos-passthrough, the installer sets OSX_KVM_DIR to point back there.
DATA_DIR="${OSX_KVM_DIR:-$SCRIPT_DIR}"
cd "$DATA_DIR"

log() { echo "[gpu-passthrough] $*"; }
run() {
    log "$1"
    shift
    if [ "$DRY_RUN" = "1" ]; then echo "    DRY-RUN: $*"; return 0; fi
    "$@" || true
}
vfio_id() { echo "${1/:/ }"; }   # "1002:73df" -> "1002 73df" (sysfs new_id/remove_id format)
# Software re-plug of passed-through USB devices. A killed QEMU never hands them
# back to their Linux drivers, leaving keyboard/mouse dead on the desktop.
# amd-pstate energy/performance preference for the pinned cores while the VM runs;
# the previous values are restored on exit.
declare -A SAVED_EPP=()
set_epp() {
    local cpu f
    for cpu in "${PIN[@]}"; do
        f=/sys/devices/system/cpu/cpu$cpu/cpufreq/energy_performance_preference
        [ -w "$f" ] || continue
        SAVED_EPP[$cpu]=$(cat "$f")
        echo "$VM_CPU_EPP" > "$f" 2>/dev/null || log "WARNING: could not set EPP on CPU $cpu"
    done
    [ "${#SAVED_EPP[@]}" -gt 0 ] && log "CPU energy preference '$VM_CPU_EPP' on CPUs ${!SAVED_EPP[*]}"
}
restore_epp() {
    local cpu
    for cpu in "${!SAVED_EPP[@]}"; do
        echo "${SAVED_EPP[$cpu]}" > /sys/devices/system/cpu/cpu$cpu/cpufreq/energy_performance_preference 2>/dev/null
    done
    [ "${#SAVED_EPP[@]}" -gt 0 ] && log "CPU energy preference restored"
    SAVED_EPP=()
}
# Power-cycle the GPU with a 3 s S3 sleep. The kernel refuses to suspend while a process
# won't freeze (common right after the PC wakes from sleep), so retry, and report failure:
# starting macOS on a card that wasn't reset gives a black screen.
s3_reset() {
    local i
    for i in 1 2 3 4; do
        rtcwake -m mem -s 3 && return 0
        log "S3 sleep refused (attempt $i/4), retrying in 5 s..."
        sleep 5
    done
    return 1
}
usb_reattach() {
    local id d
    for id in "${USB_DEVICES[@]}"; do
        for d in /sys/bus/usb/devices/*; do
            [ "$(cat "$d/idVendor" 2>/dev/null):$(cat "$d/idProduct" 2>/dev/null)" = "$id" ] || continue
            echo 0 > "$d/authorized" 2>/dev/null; sleep 0.5; echo 1 > "$d/authorized" 2>/dev/null
        done
    done
}

MODE="runtime"
grep -q 'vfio_pci.ids=' /proc/cmdline && MODE="isolated"

echo "================================================================"
echo "Mode:      $MODE"
echo "GPU:       $GPU_VGA ($GPU_VGA_ID) + audio $GPU_AUDIO ($GPU_AUDIO_ID)"
echo "VM:        ${VM_CORES} cores, ${VM_RAM_MB} MiB"
[ "$MODE" = "runtime" ] && echo "Desktop:   stops now, returns when macOS shuts down"
[ "$DRY_RUN" = "1" ] && echo "*** DRY RUN: no system changes ***"
echo "Recovery:  sudo $SCRIPT_DIR/emergency-restore.sh   (from SSH)"
echo "================================================================"

# Runs on every exit. In runtime mode it hands the GPU back to amdgpu and
# restarts the desktop; in isolated mode the GPU stays on vfio-pci.
cleanup() {
    echo ""
    [ "$DRY_RUN" = "1" ] && return
    [ -n "${QEMU_STARTED:-}" ] && run "Re-plugging USB devices..." usb_reattach
    restore_epp
    if [ "$MODE" = "isolated" ]; then
        log "Isolated mode: GPU stays on vfio-pci. Relaunch, or reboot into the normal entry."
        return
    fi

    log "Restoring Linux host desktop..."
    for dev in "$GPU_VGA" "$GPU_AUDIO"; do
        [ -e "/sys/bus/pci/drivers/vfio-pci/$dev" ] && echo "$dev" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null
        echo "" > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null
    done
    # Otherwise vfio-pci re-claims the card on rescan and amdgpu never gets it
    vfio_id "$GPU_VGA_ID"   > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
    vfio_id "$GPU_AUDIO_ID" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
    run "Removing GPU from PCI bus..." \
        sh -c "echo 1 > '/sys/bus/pci/devices/$GPU_VGA/remove' 2>/dev/null; echo 1 > '/sys/bus/pci/devices/$GPU_AUDIO/remove' 2>/dev/null; true"
    run "S3 suspend to power-reset the GPU..." s3_reset
    run "Rescanning PCI bus..." sh -c "echo 1 > /sys/bus/pci/rescan; sleep 2; true"
    run "Reloading amdgpu + HDA audio..." sh -c "modprobe amdgpu; modprobe snd_hda_intel; true"
    run "Rebinding VT consoles..." sh -c 'for v in /sys/class/vtconsole/vtcon*/bind; do echo 1 > "$v" 2>/dev/null || true; done'
    run "Restarting display manager..." systemctl restart "$DISPLAY_MANAGER"
    echo "=== Host desktop restored ==="
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------
# Runtime mode: tear down the desktop and reset the card
# ------------------------------------------------------------
if [ "$MODE" = "runtime" ] && [ "$DRY_RUN" = "0" ]; then
    log "Stopping display manager..."
    systemctl stop "$DISPLAY_MANAGER" 2>/dev/null || true
    sleep 1
    fuser -k /dev/dri/* 2>/dev/null || true
    sleep 1
    for vt in /sys/class/vtconsole/vtcon*/bind; do echo 0 > "$vt" 2>/dev/null || true; done
    echo "efi-framebuffer.0" > /sys/bus/platform/drivers/efi-framebuffer/unbind 2>/dev/null || true
    sleep 1

    log "Removing GPU from PCI bus..."
    echo 1 > "/sys/bus/pci/devices/$GPU_VGA/remove" 2>/dev/null || true
    echo 1 > "/sys/bus/pci/devices/$GPU_AUDIO/remove" 2>/dev/null || true
    sleep 1

    # amdgpu must be gone before the rescan, or it re-claims the card
    log "Unloading amdgpu, registering IDs with vfio-pci..."
    modprobe -r amdgpu 2>/dev/null || true
    modprobe -r snd_hda_intel 2>/dev/null || true
    sleep 1
    modprobe vfio_pci 2>/dev/null || true
    modprobe vfio_iommu_type1 2>/dev/null || true
    vfio_id "$GPU_VGA_ID"   > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
    vfio_id "$GPU_AUDIO_ID" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true

    log "S3 suspend: the motherboard cuts PCIe power, resetting the GPU..."
    if ! s3_reset; then
        echo "[ERROR] The GPU reset sleep failed 4 times; not starting macOS on an unreset card."
        echo "        Restoring the desktop. Try again in a minute."
        exit 1
    fi

    log "Rescanning PCI bus..."
    echo 1 > /sys/bus/pci/rescan
    sleep 2
    [ -e "/sys/bus/pci/devices/$GPU_VGA" ] || { echo "[ERROR] GPU did not reappear after rescan"; exit 1; }
fi

# ------------------------------------------------------------
# Verify vfio-pci owns the GPU
# ------------------------------------------------------------
drv() { basename "$(readlink "/sys/bus/pci/devices/$1/driver" 2>/dev/null)" 2>/dev/null || echo none; }
if [ "$DRY_RUN" = "0" ] && [ "$(drv "$GPU_VGA")" != "vfio-pci" ]; then
    log "Auto-bind missed, forcing vfio-pci via driver_override..."
    for dev in "$GPU_VGA" "$GPU_AUDIO"; do
        [ -e "/sys/bus/pci/devices/$dev/driver/unbind" ] && echo "$dev" > "/sys/bus/pci/devices/$dev/driver/unbind" 2>/dev/null
        echo "vfio-pci" > "/sys/bus/pci/devices/$dev/driver_override"
        echo "$dev" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    done
    sleep 1
fi
echo "  VGA   driver: $(drv "$GPU_VGA")"
echo "  Audio driver: $(drv "$GPU_AUDIO")"
if [ "$DRY_RUN" = "0" ] && [ "$(drv "$GPU_VGA")" != "vfio-pci" ]; then
    echo "[ERROR] GPU is not bound to vfio-pci"
    exit 1
fi

# ------------------------------------------------------------
# QEMU command line
# ------------------------------------------------------------
if [ -n "${OC_IMAGE:-}" ]; then
    [ -f "$OC_IMAGE" ] || { echo "[ERROR] OC_IMAGE not found: $OC_IMAGE"; exit 1; }
else
    OC_IMAGE="$DATA_DIR/$OC_IMAGE_DEFAULT"
fi
log "OpenCore image: $OC_IMAGE"

ROM_ARG=""
if [ -n "${ROM_FILE:-}" ]; then
    [ -s "$ROM_FILE" ] || { echo "[ERROR] ROM_FILE not found: $ROM_FILE"; exit 1; }
    ROM_ARG=",romfile=$ROM_FILE"
    log "Using VBIOS ROM file: $ROM_FILE"
fi

mkdir -p "$DATA_DIR/logs"
SERIAL_LOG="$DATA_DIR/logs/serial-$(date +%Y%m%d-%H%M%S).log"
log "Guest serial log: $SERIAL_LOG  (fills when macOS boots with serial=3)"

# Lilu (and so NootRX) only detects a discrete GPU behind a PCIe bridge, as on
# a real Mac. Directly on pcie.0, NootRX panics "Failed to find a compatible GPU".
GPU_ARGS=(
  -device pcie-root-port,id=gpuport,bus=pcie.0,addr=0x2,chassis=1,slot=1
  -device "vfio-pci,host=$GPU_VGA,bus=gpuport,addr=0x0.0,multifunction=on$ROM_ARG"
  -device "vfio-pci,host=$GPU_AUDIO,bus=gpuport,addr=0x0.1"
)

# Only pass USB devices that are plugged in; QEMU aborts on missing ones
USB_ARGS=()
for id in "${USB_DEVICES[@]}"; do
    if lsusb | grep -qi "ID $id "; then
        USB_ARGS+=(-device "usb-host,vendorid=0x${id%%:*},productid=0x${id##*:},bus=xhci.0")
        log "USB passthrough: $id"
    fi
done

# Stable per-machine MAC (QEMU's 52:54:00 prefix), derived from /etc/machine-id
MAC_SUFFIX=$(md5sum /etc/machine-id | sed -E 's/^(..)(..)(..).*/\1:\2:\3/')
[ -n "${VM_MAC:-}" ] || VM_MAC="52:54:00:$MAC_SUFFIX"

args=(
  -name macOS,debug-threads=on
  -enable-kvm
  -m "$VM_RAM_MB"
  -machine q35
  -cpu Haswell-noTSX,-pcid,vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on,+fma,+avx,+avx2,+aes,+ssse3,+sse4_2,+popcnt,+bmi1,+bmi2,+rdtscp,+xsave,+xsaveopt,+fsgsbase,+movbe
  -smp "$VM_CORES,cores=$VM_CORES,threads=1,sockets=1"
  -global nec-usb-xhci.msi=off
  -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
  -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
  -smbios type=2
  -drive if=pflash,format=raw,readonly=on,file="$DATA_DIR/OVMF_CODE_4M.fd"
  -drive if=pflash,format=raw,file="$DATA_DIR/OVMF_VARS-1920x1080.fd"
  "${GPU_ARGS[@]}"
  -device qemu-xhci,id=xhci,bus=pcie.0,addr=0x4
  "${USB_ARGS[@]}"
  -audiodev none,id=noaudio
  -device ich9-ahci,id=sata
  -drive id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,cache=writeback,aio=threads,file="$OC_IMAGE"
  -device ide-hd,bus=sata.2,drive=OpenCoreBoot
  -drive id=MacHDD,if=none,file="$DATA_DIR/$MAC_DISK",format=qcow2,cache=writeback,aio=threads,discard=unmap
  -device ide-hd,bus=sata.4,drive=MacHDD
  -netdev user,id=net0,hostfwd=tcp::2222-:22
  -device virtio-net-pci,netdev=net0,id=net0,mac="$VM_MAC",bus=pcie.0,addr=0x5
  -serial "file:$SERIAL_LOG"
  -vga none
  -display none
  -monitor "unix:$DATA_DIR/logs/monitor.sock,server,nowait"
)

# Optional CPU pinning: vCPU i runs only on host CPU PIN[i]; QEMU's other threads
# (disk, USB, emulation) run on HOST_CPUS. Keeps real-time audio off busy cores.
PIN=()
if [ -n "${VM_PIN_CPUS:-}" ]; then
    read -ra PIN <<< "$VM_PIN_CPUS"
    [ "${#PIN[@]}" -eq "$VM_CORES" ] || { echo "[ERROR] VM_PIN_CPUS lists ${#PIN[@]} CPUs but VM_CORES=$VM_CORES"; exit 1; }
    log "CPU pinning: vCPUs -> host CPUs ${PIN[*]}; QEMU threads -> ${HOST_CPUS:-any}"
fi
pin_vcpus() {
    # Needs -name debug-threads=on, which names vCPU threads "CPU <n>/KVM".
    # Only restrict anything once every vCPU thread is found; otherwise leave
    # QEMU unpinned rather than risk squeezing the vCPUs onto the host cores.
    local tries t comm n
    declare -A vcpu=()
    for tries in $(seq 50); do
        vcpu=()
        for t in /proc/"$QPID"/task/*; do
            comm=$(cat "$t/comm" 2>/dev/null) || continue
            [[ "$comm" =~ ^CPU\ ([0-9]+)/KVM$ ]] && vcpu[${BASH_REMATCH[1]}]=$(basename "$t")
        done
        [ "${#vcpu[@]}" -ge "$VM_CORES" ] && break
        sleep 0.2
    done
    if [ "${#vcpu[@]}" -lt "$VM_CORES" ]; then
        log "WARNING: found ${#vcpu[@]} of $VM_CORES vCPU threads; running without pinning"
        return
    fi
    for t in /proc/"$QPID"/task/*; do
        n=""
        for i in "${!vcpu[@]}"; do [ "${vcpu[$i]}" = "$(basename "$t")" ] && n=$i; done
        if [ -n "$n" ]; then
            taskset -pc "${PIN[$n]}" "$(basename "$t")" >/dev/null
        elif [ -n "${HOST_CPUS:-}" ]; then
            taskset -pc "$HOST_CPUS" "$(basename "$t")" >/dev/null
        fi
    done
    log "Pinned ${#vcpu[@]} vCPU threads to ${PIN[*]}; other QEMU threads to ${HOST_CPUS:-any CPU}."
}

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "=== DRY RUN: QEMU command line ==="
    printf ' %q\n' "${args[@]}"
    trap - EXIT INT TERM
    exit 0
fi

AVAILABLE_MB=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
if [ "$AVAILABLE_MB" -lt "$((VM_RAM_MB + HOST_RESERVE_MB))" ]; then
    echo "[ERROR] Only ${AVAILABLE_MB} MiB available; the VM needs ${VM_RAM_MB} + ${HOST_RESERVE_MB} MiB."
    exit 1
fi
command -v qemu-system-x86_64 >/dev/null || { echo "[ERROR] qemu-system-x86_64 not found"; exit 1; }
[ -f "$OC_IMAGE" ] || { echo "[ERROR] OpenCore image missing: $OC_IMAGE (run build-opencore-image.sh)"; exit 1; }
[ -f "$DATA_DIR/$MAC_DISK" ] || { echo "[ERROR] macOS disk missing: $MAC_DISK"; exit 1; }

log "Starting macOS on the physical monitors. Shut macOS down from inside to exit cleanly."
log "SSH into macOS: ssh <mac-user>@localhost -p 2222"
log "QEMU monitor: socat - UNIX-CONNECT:$DATA_DIR/logs/monitor.sock"
QEMU_STARTED=1
qemu-system-x86_64 "${args[@]}" &
QPID=$!
# QEMU runs in the background: stop it first on Ctrl+C / service stop, then clean up
trap 'kill -TERM "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; exit 130' INT TERM
[ "${#PIN[@]}" -gt 0 ] && pin_vcpus
[ "${#PIN[@]}" -gt 0 ] && [ -n "${VM_CPU_EPP:-}" ] && set_epp
wait "$QPID"
log "QEMU exited with code $?."
exit 0

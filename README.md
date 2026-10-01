# OSX-KVM single-GPU passthrough for the AMD RX 6700 / 6700 XT / 6750 XT

Run macOS (tested: Sequoia 15.7) in QEMU/KVM with your **only** GPU, an RX 6700-series card (Navi 22),
passed through with full acceleration, driven by [NootRX](https://github.com/ChefKissInc/NootRX).
You can switch between the Linux desktop and macOS **without rebooting**.

This is an add-on for [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM). It doesn't replace it.

## What was actually needed

Most of this took a long time to find. If you're debugging a similar setup, these are the parts that matter:

1. **The GPU must sit behind a PCIe root port in QEMU.** Lilu (which NootRX builds on) only detects a
   discrete GPU behind a PCIe bridge, as on a real Mac. If the card is placed directly on `pcie.0`
   (common in guides), NootRX panics at boot with `Failed to find a compatible GPU`. With older Lilu
   it silently does nothing instead, and macOS shows a 7 MB framebuffer.
2. **Lilu 1.7.2 or newer.** With Lilu 1.6.8 on Sequoia, NootRX loaded but never attached.
3. **A full power-cycle of the card between owners.** Navi 22 has no Function Level Reset, so the GPU
   can't be cleanly reset in software. A PCI remove → S3 suspend (`rtcwake -m mem -s 3`) → rescan makes
   the motherboard cut slot power, which resets the card completely.
4. **Get the guest kernel log out of the VM.** When the screen freezes you can't read anything. A
   `serial=3` boot-arg plus QEMU `-serial file:` writes the full log (Lilu/NootRX debug output
   included) to a file on the host. That's how items 1 and 2 were found. See [Debugging](#debugging).

Most of this (the root port, the GRUB entry and the desktop handoff) applies to any AMD GPU.
NootRX and the Lilu version only matter for Navi 22: the RX 6600/6800/6900 have native macOS drivers.

## Tested on

- XFX RX 6700 XT, Ryzen 7 5700X (no iGPU), Gigabyte X570, 32 GB RAM
- Fedora 44 (CachyOS kernel), KDE Plasma 6, GRUB 2 with BLS, SELinux enforcing
- QEMU 10.2, macOS Sequoia 15.7.9, Lilu 1.7.2, NootRX 1.0.0

Other distros should mostly work (`grub-mkconfig` vs `grub2-mkconfig` is handled), but they're untested.
Reports welcome.

## Two ways to run

| | From the desktop | Dedicated boot entry |
|---|---|---|
| Start | App menu → **macOS (GPU passthrough)** | `sudo ./install-passthrough-boot.sh --next` or pick it in GRUB |
| What happens | Desktop closes, PC sleeps ~3 s (GPU reset), macOS starts | Linux boots headless, macOS starts automatically |
| Back to Linux | Shut macOS down → the login screen returns | Reboot |

## How it works

### The pieces

```
 Linux host                                  macOS guest
 ─────────────────────────────────────       ───────────────────────────────────────
 boot-gpu-passthrough.sh                     OpenCore (boot loader, from the .qcow2)
   │ hands the GPU to vfio-pci                 └─ injects Lilu + NootRX into macOS
   ▼                                         Lilu      finds the GPU on the PCI tree
 vfio-pci  (kernel driver that lets          NootRX    teaches Apple's AMD drivers
   │        a VM own a real PCI device)                  (AMDRadeonX6000*) to accept Navi 22
   ▼                                         Apple's AMD drivers → Metal acceleration
 QEMU/KVM  ── real RX 6700 XT ──────────────▶ on your physical monitors
```

Only one side can use the GPU at a time. Everything below is about moving the card cleanly from
Linux to macOS and back.

### Desktop mode, step by step

Started from the menu entry: `pkexec systemd-run … boot-gpu-passthrough.sh`. Running it as a
system service matters. The launcher shuts down your desktop session, and anything started *inside*
that session would be killed with it.

**Handing the GPU to macOS:**

1. **Stop the display manager** (`display-manager.service`). This closes the desktop and every app
   using the GPU. `fuser -k /dev/dri/*` kills anything that still holds it.
2. **Release the console.** Unbind the text consoles and the EFI framebuffer, so Linux stops drawing
   on the card at all.
3. **Remove the GPU from the PCI bus** (`echo 1 > /sys/bus/pci/devices/<gpu>/remove`), for both the
   video and HDMI-audio functions. Then unload `amdgpu` and `snd_hda_intel`, so they can't grab
   the card again.
4. **Pre-register the card with vfio-pci** (`new_id`). Whenever the card shows up again, vfio-pci
   claims it instead of amdgpu.
5. **Power-cycle the card:** a 3-second S3 sleep (`rtcwake -m mem -s 3`). The motherboard cuts
   power to the PCIe slot, so the card forgets everything amdgpu did to it. It's the only reliable
   reset for a card without FLR. Your PC visibly sleeps and wakes here.
6. **Rescan the PCI bus.** The card reappears in a fresh state and vfio-pci takes it. The script
   checks this, and falls back to `driver_override` if the auto-claim missed.
7. **Start QEMU** (see [the VM](#the-vm) below), pin its CPU threads if configured, and wait
   until macOS shuts down.

**Handing it back to Linux** (a shell `EXIT` trap, so it also runs after a crash or kill):

1. **Re-plug the passed-through USB devices** in software (`authorized` 0 → 1). A QEMU that was
   killed never returns them itself, which would leave your keyboard and mouse dead.
2. **Release the card from vfio-pci:** unbind it, clear `driver_override`, and **`remove_id`**. If
   the IDs stay registered, vfio-pci grabs the card again on the next rescan and the desktop never
   comes back.
3. **Remove, S3 power-cycle, rescan** again. macOS initialized the card, and amdgpu needs it fresh.
4. **Reload `amdgpu` and `snd_hda_intel`.** The latter also drives the motherboard audio, which
   was unloaded in step 3 above.
5. **Rebind the consoles and restart the display manager.** The login screen appears.

### Dedicated boot mode

Instead of taking the card away from a running desktop, Linux never touches it:

- The GRUB entry adds `vfio_pci.ids=1002:73df,1002:ab28`, so vfio-pci claims the card at boot,
  before amdgpu loads. `rd.driver.pre=vfio_pci` loads vfio-pci early from the initramfs, and
  `initcall_blacklist=sysfb_init video=efifb:off` stops Linux from using the card as a boot
  console. Also: `amd_iommu=on iommu=pt`.
- The entry comes from a generator script in `/etc/grub.d/`, not a normal boot entry. On Fedora,
  every kernel update regenerates the GRUB config and rewrites the arguments of all normal (BLS)
  entries, which silently removed the vfio arguments. The generator writes the entry fresh each
  time, always with the newest kernel.
- `macos-passthrough-boot.service` runs at every boot. If `/proc/cmdline` contains `vfio_pci.ids=`,
  it starts the launcher, which detects "isolated" mode and skips all the teardown and reset steps.
  On a normal boot it does nothing.
- When macOS shuts down, the card stays with vfio-pci. Reboot into the normal entry for Linux.

### The VM

```
 pcie.0 (QEMU root bus)
 ├── 00:02.0  pcie-root-port ──┬── 00.0  RX 6700 XT        (vfio-pci, multifunction)
 │                             └── 00.1  HDMI/DP audio      (vfio-pci)
 ├── 00:04.0  qemu-xhci  ── your USB keyboard/mouse (usb-host, by vendor:product)
 ├── 00:05.0  virtio-net ── user networking, host port 2222 → macOS SSH
 └── ich9-ahci ── OpenCore image (snapshot=on, never modified) + macOS disk
```

- **The root port is the important part.** On a real Mac, the GPU sits behind a PCIe bridge, and
  Lilu's device detection only looks there. A GPU plugged directly into `pcie.0` is invisible to it.
- **Firmware:** OVMF (UEFI) runs the card's own GOP driver, so you see the OpenCore picker on the
  real monitor before macOS loads. No VBIOS file is needed (`ROM_FILE=` exists as an option).
- **No virtual display** (`-vga none -display none`). The only output is the physical card.
- **The serial port is logged** to `logs/serial-*.log`. With the `serial=3` boot-arg, macOS writes
  its kernel log there.
- **CPU:** `-cpu Haswell-noTSX,…` as in OSX-KVM, with one thread per core. With pinning on, QEMU
  runs with `-name …,debug-threads=on`, so its vCPU threads are named `CPU 0/KVM` … `CPU 5/KVM`.
  The launcher `taskset`s each to its host CPU and moves QEMU's other threads to `HOST_CPUS`. If
  it can't find every vCPU thread, it changes nothing rather than squeezing the VM.

### Inside macOS

1. **OpenCore** boots from its own disk image and injects kexts (kernel extensions) into macOS
   before it starts: **Lilu**, a patching framework, and **NootRX**, a Lilu plugin.
2. **Lilu** scans the PCI tree for GPUs, which is why the root port matters.
3. **NootRX** finds device `0x73DF` (Navi 22). macOS has AMD drivers for Navi 21 and 23 but not 22.
   NootRX patches Apple's `AMDRadeonX6000`, `AMDRadeonX6000Framebuffer`, `AMDRadeonX6000HWServices`
   and `AMDRadeonX6810HWLibs` in memory so they accept the card and load its firmware.
4. Apple's own drivers then run the card: full framebuffer, multiple displays and Metal.
   **WhateverGreen** is disabled because it conflicts with NootRX.

## Requirements

- A working [OSX-KVM](https://github.com/kholia/OSX-KVM) install with macOS already set up (`mac_hdd_ng.img`)
- IOMMU enabled in the BIOS, with the GPU in its own IOMMU group(s)
- A CPU without an iGPU is fine; this is the "only GPU" case
- **SSH access to the host from another device** (phone/laptop). It's your recovery path if the screen stays black
- Packages: `qemu-img`, `mtools`, `python3`, `curl`, `unzip`, `util-linux` (for `rtcwake`, `sfdisk`)
- A NootRX build: download it from the [NootRX GitHub page](https://github.com/ChefKissInc/NootRX)
  (latest release or Actions artifact). The zip can be passed as is.

## Install

```bash
cd ~/OSX-KVM                                  # your OSX-KVM folder
R=/path/to/this/repo
cp -r $R/*.sh $R/passthrough.conf $R/*.service $R/*.desktop $R/grub.d $R/opencore .   # add these files to it
./setup.sh                                    # pick GPU, RAM, cores, USB devices -> writes passthrough.conf
./build-opencore-image.sh ~/Downloads/NootRX-*.zip
sudo ./install-passthrough-boot.sh
```

`setup.sh` asks four questions (GPU, RAM, CPU cores, USB devices), checks your IOMMU groups, and writes
`passthrough.conf`. You can also edit that file by hand; every setting is commented.

### USB devices (keyboard, mouse, headset)

While macOS runs, it has the GPU, so it also needs your keyboard and mouse. `setup.sh` lets you pick
them from a list; by hand, they go in `passthrough.conf`:

```bash
lsusb
# Bus 005 Device 003: ID 05ac:024f Apple, Inc. Aluminium Keyboard (ANSI)
# Bus 001 Device 004: ID 046d:c547 Logitech, Inc. USB Receiver
```

```bash
USB_DEVICES=("05ac:024f" "046d:c547")   # the ID column: vendor:product
```

- Devices that aren't plugged in are skipped, so QEMU doesn't fail on them.
- While macOS runs, these devices disappear from Linux. When the VM exits, even after a crash or kill,
  the launcher re-plugs them in software so Linux gets them back.
- Wireless dongles (Logitech, etc.) are passed as the receiver's ID; everything paired to it goes along.
- With two identical devices (same ID), only one is passed through.

`build-opencore-image.sh` takes OSX-KVM's stock `OpenCore/OpenCore.qcow2`, replaces its config with the
verified `opencore/config.plist`, swaps in Lilu 1.7.2, adds NootRX, disables WhateverGreen, sets the
boot-args, and writes `OpenCore/OpenCore-nootrx.qcow2`. (OSX-KVM's stock config hung at the Apple logo
with NootRX, which is why the verified config is used.) It uses placeholder serials. For iCloud/iMessage, generate your own with
[GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) and pass them in (never commit them):

```bash
SMBIOS_SERIAL=... SMBIOS_MLB=... SMBIOS_UUID=... SMBIOS_ROM=... ./build-opencore-image.sh <NootRX.zip>
```

`install-passthrough-boot.sh` installs:
- a GRUB entry generator in `/etc/grub.d/`. It rebuilds the entry with your newest kernel on every
  kernel update, so the vfio args survive (plain BLS entries lose custom args).
- module ordering in `/etc/modprobe.d/`
- a **root-owned copy** of the launcher scripts and `passthrough.conf` in `/usr/local/lib/macos-passthrough/`
- `/usr/local/bin/macos-passthrough-start` plus a polkit rule, so the menu entry starts macOS
  **without a password**, for your user only, in an active local session, and only that one command
- the autostart service for the dedicated boot entry
- the desktop menu entry

Your default boot entry is not changed.

**After editing `passthrough.conf`, rerun `sudo ./install-passthrough-boot.sh`.** Whatever runs as root
without a password must not be editable by your normal account. Otherwise any program running as you
could rewrite it and gain root, so the menu entry runs the root-owned copy, not the files in your folder.

## Tuning

While macOS runs in desktop mode, the Linux desktop is stopped, so the VM can take most of the machine:

- **RAM:** leave ~6–8 GB for Linux (it uses the spare as disk cache for the macOS image). On 32 GB: `VM_RAM_MB=24576`.
- **Cores:** one vCPU per *physical* core, `threads=1`. Giving macOS SMT siblings made audio (Logic Pro)
  and UI stutter in testing. Leave 2 physical cores for QEMU's own disk/USB work.
- **CPU pinning** (`VM_PIN_CPUS`, `HOST_CPUS` in `passthrough.conf`): each vCPU gets its own physical core
  and QEMU's helper threads stay off them. Most useful for real-time audio. See `lscpu -e` for your layout.
- **AMD CPU energy preference** (`VM_CPU_EPP="performance"`, needs pinning and the `amd-pstate-epp`
  driver): the pinned cores respond at full clock speed instead of ramping up from idle, which helps
  audio under load. Idle cores still sleep, so the extra power is small. The previous setting is
  restored when the VM exits.

The QEMU monitor is on a socket: `sudo socat - UNIX-CONNECT:logs/monitor.sock`.

## Recovery

- **Black screen after leaving macOS (desktop mode):** SSH in and run `sudo ./emergency-restore.sh`.
  It hands the GPU back to amdgpu and restarts the display manager.
- **Stuck in the dedicated boot entry:** reboot. GRUB goes back to your normal entry.
- **Nothing works:** hold the power button. The passthrough setup never changes the default boot.

## Debugging

```bash
./build-opencore-image.sh <NootRX.zip> --debug    # DEBUG Lilu/NootRX + -v serial=3 boot-args
sudo OC_IMAGE=OpenCore/OpenCore-nootrx-debug.qcow2 ./boot-gpu-passthrough.sh
# read logs/serial-*.log. Everything the kernel prints, even if the screen froze
```

`sudo ./boot-gpu-passthrough.sh --dry-run` prints the full QEMU command line without touching anything.

On Fedora/SELinux, systemd may refuse to execute scripts under `/home`. The service and menu
entry run them through `/usr/bin/bash` for that reason.

## Credits

- [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM): the macOS-on-KVM foundation
- [ChefKissInc/NootRX](https://github.com/ChefKissInc/NootRX): Navi 22 support in macOS
- [acidanthera/Lilu](https://github.com/acidanthera/Lilu) and the OpenCore project

Not affiliated with Apple. Make sure your use of macOS complies with Apple's license terms.

## How this was made

Built with help from Claude (Anthropic), then tested on the hardware listed above.

## License

MIT for the scripts in this repo. `opencore/config.plist` is derived from
[OSX-KVM](https://github.com/kholia/OSX-KVM)'s OpenCore config. Lilu and NootRX are downloaded, not
redistributed, and keep their own licenses.

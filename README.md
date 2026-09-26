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
3. **No "reset bug" workaround needed at VM level.** Navi 22 has no FLR, but it can be reset: this project
   does a PCI remove → S3 suspend (`rtcwake -m mem -s 3`) → rescan, which power-cycles the slot.
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

`build-opencore-image.sh` takes OSX-KVM's stock `OpenCore/OpenCore.qcow2`, swaps in Lilu 1.7.2, adds
NootRX, disables WhateverGreen, sets the boot-args, and writes `OpenCore/OpenCore-nootrx.qcow2`.
It uses placeholder serials. For iCloud/iMessage, generate your own with
[GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) and pass them in (never commit them):

```bash
SMBIOS_SERIAL=... SMBIOS_MLB=... SMBIOS_UUID=... SMBIOS_ROM=... ./build-opencore-image.sh <NootRX.zip>
```

`install-passthrough-boot.sh` installs:
- a GRUB entry generator in `/etc/grub.d/`. It rebuilds the entry with your newest kernel on every
  kernel update, so the vfio args survive (plain BLS entries lose custom args).
- module ordering in `/etc/modprobe.d/`
- the autostart service for the dedicated boot entry
- the desktop menu entry

Your default boot entry is not changed.

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

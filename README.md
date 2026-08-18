# KVM-OpenCore

An OpenCore bootloader image for running macOS as a QEMU/KVM guest, targeted at **Proxmox VE 9**.

This is a fork of [thenickdude/KVM-Opencore](https://github.com/thenickdude/KVM-Opencore), which is
itself a fork of [Leoyzen's OpenCore image](https://github.com/leoyzen/KVM-Opencore). All credit for
the original work and its build system goes to them; this fork exists because upstream has been
quiet since early 2024 and the config needed to move on.

## This fork is maintained independently

**Changes here are not sent upstream, and this repo is not a staging area for pull requests.**
Upstream is tracked as the `origin` remote so its fixes can be pulled in, but the two histories are
expected to diverge.

What differs from upstream today:

| Change | Why |
|---|---|
| Merged [PR #84](https://github.com/thenickdude/KVM-Opencore/pull/84) | OpenCore **1.0.5**, SMBIOS `iMac20,1`, `ScanPolicy 0`, and the two `hv_vmm_present` kernel patches that make Apple Services work on **Sequoia and Tahoe**. Open upstream since October 2025 |
| **`CryptexFixup` at `MinKernel 20.0.0`** (was `22.1.0`, capped at `23.99.99`) | The fix that makes non-AVX2 upgrades work. CryptexFixup patches the *installer* while it runs on the **source** OS, so gating it to Ventura meant it never loaded on Monterey — upgrades silently installed the wrong cryptex and panicked in `launchd` |
| **`RestrictEvents` + `revpatch=f16c`** | OCLP applies this to every Ivy Bridge machine on macOS 13.3+ to stop CoreGraphics crashing. `revpatch` is in both `NVRAM/Add` **and** `NVRAM/Delete` — `Add` alone never writes it |
| **Penryn and broken-seal kernel patches uncapped** | Both stopped at `MaxKernel 23.99.99`, leaving Sequoia with no CPU-family spoof and no non-AVX2 accommodation |
| `Misc/Boot/Timeout=5`, `Misc/Security/AllowSetDefault=true` | Upstream ships `0`/`false`, so the picker waits forever and Ctrl+Enter can't set a default — the VM never autoboots. Requested in upstream [issue #80](https://github.com/thenickdude/KVM-Opencore/issues/80) |
| [`PROXMOX-GUIDE.md`](PROXMOX-GUIDE.md) | Full install guide for Proxmox 9, including two changes that stop the VM booting on current Proxmox (see below) |
| [`build-image-nomac.sh`](build-image-nomac.sh) | Builds the image **without a Mac**. Upstream's Makefile needs `hdiutil` and `xcodebuild` |
| `.gitattributes`, `.gitignore` additions | Force LF on shell scripts; ignore the build script's output |

Upstream's newest tagged release is **v21 (March 2024)** — it predates Sequoia and does *not* contain
the kernel patches above. Build from this repo's master instead.

### macOS version support

| macOS | Darwin | AVX2 host | Non-AVX2 host |
|---|---|---|---|
| Catalina 10.15.6+ – Big Sur 11 | 19–20 | supported by config | native install |
| **Monterey 12** | 21 | supported by config | ✅ verified |
| Ventura 13 | 22 | supported by config | upgrade in place only |
| **Sonoma 14** | 23 | supported by config | ✅ verified (14.8.9) |
| **Sequoia 15** | 24 | reported working by the PR #84 author | ✅ verified (15.7.9) |
| **Tahoe 26** | 25 | reported working by the PR #84 author | ✅ verified (26.6.1) |

*Verified* means installed and booted to a working desktop on a Xeon E5-2670 v2 under Proxmox 9.
Catalina 10.15.6 is the floor (the `iMac20,1` SMBIOS doesn't exist before it), and SSE 4.2 is the
hard CPU requirement throughout.

### Verified on non-AVX2 hardware

**macOS Tahoe 26.6.1 runs on a Xeon E5-2670 v2** (Ivy Bridge, no AVX2, dual socket) as a Proxmox 9
guest — installed as Monterey, then upgraded in place through Sonoma 14.8.9 and Sequoia 15.7.9 to
Tahoe. **No OpenCore Legacy Patcher, no root patching, no SMBIOS spoofing.** That is the current
macOS release running on a CPU Apple dropped three generations ago.

Ventura and later cannot boot from installer *media* on pre-Haswell CPUs — the in-place upgrade path
is what works, and the `CryptexFixup` gating fix above is what makes it work. Verified by the
presence of `dyld_shared_cache_arm64e` and Rosetta's `aot_shared_cache.*` under
`/System/Volumes/Preboot/Cryptexes/OS/`, which only the Apple Silicon cryptex provides.

Every release from Catalina to Tahoe is therefore reachable on pre-Haswell hardware.

### Verified as an iOS build host

Visual Studio 2026 on Windows pairs to this VM over SSH and builds and runs a **.NET 10** iOS app in
the simulator — Xcode 26.6 (Universal), iOS SDK 26.5, workload `26.5.10301`. See the guide for the
gotchas: the Universal-vs-Apple-silicon Xcode download, simulator runtimes being a separate
`xcodebuild -downloadPlatform iOS` fetch, and the fact that **Xcode 26 is the last Intel-compatible
release**, which bounds how long this stays viable.

## Quick start

Build the image on any Linux box — the Proxmox host is the obvious choice, since that's where it has
to end up:

```bash
apt install -y curl unzip gdisk mtools git && git clone https://github.com/asulwer/KVM-Opencore.git && cd KVM-Opencore
```

```bash
./build-image-nomac.sh && cp OpenCore-master.img /var/lib/vz/template/iso/
```

Then follow [`PROXMOX-GUIDE.md`](PROXMOX-GUIDE.md) to create the VM.

> The resulting `.img`/`.iso` is **not a real ISO** — it's a raw GPT hard-disk image. The `.iso`
> extension only exists so Proxmox's disk picker will list it, which is why the guide attaches it
> with `media=disk` rather than as a CD-ROM.

## Two things that break on current Proxmox

Both stop the VM from starting, and both are wrong in guides written for Proxmox 7:

1. **`Bus 'ehci.0' not found`** — QEMU 10 (Proxmox 9) removed that USB bus. Use
   `-device qemu-xhci -device usb-kbd -device usb-tablet` instead of
   `-device usb-kbd,bus=ehci.0,port=2`.
2. **`explicit media parameter is required for iso images`** — since Proxmox 8.4, deleting
   `media=cdrom` is not enough; `media=disk` must be set *explicitly*. The drive schema does default
   `media` to `disk`, but an earlier check in `QemuServer.pm` rejects an undefined `media` for
   ISO-type volumes before that default applies.

Both are covered in detail in the guide.

## Building

**`build-image-nomac.sh` (no Mac required).** Every submodule pinned at master is an upstream release
tag, and Acidanthera publishes prebuilt binaries for each, so nothing needs compiling. The script
downloads those exact versions — OpenCore 1.0.5, Lilu 1.7.1, WhateverGreen 1.7.0, AppleALC 1.9.5,
VirtualSMC 1.3.7, BrcmPatchRAM 2.7.1, CryptexFixup 1.0.5, RestrictEvents 1.1.6 — assembles the same
EFI tree, and writes a GPT/FAT32 image with `mtools`. No root, no loop devices.

**`make dist` (Mac required).** Upstream's build system, which compiles every kext from source with
`xcodebuild` and packages with `hdiutil`. Needs `git submodule update --init` first. Use this only if
you've modified kext source or want to verify the binaries yourself.

> The `src/` directories are empty until you run `git submodule update --init`. That's expected, and
> `build-image-nomac.sh` doesn't need them.

## Rolling back

[Section 11 of the guide](PROXMOX-GUIDE.md) covers everything this touches on a Proxmox host and how
to undo it. In short: almost all of it is VM-scoped and disappears with `qm destroy`. The base guide
makes exactly one host-global change (`/etc/modprobe.d/kvm.conf`), and only GPU passthrough can cost
you access to the host.

## Licence

GPL-3.0, inherited from upstream. See [LICENSE](LICENSE).

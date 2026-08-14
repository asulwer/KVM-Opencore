# Installing macOS on Proxmox with this OpenCore image

A complete, self-contained guide to running macOS as a Proxmox VE guest using the OpenCore image in
this repository. **You do not need to read anything else first.** Every command, value and
explanation you need is here. The credits at the end list the sources this work draws on, for
attribution and further reading rather than as prerequisites.

Written and tested against **Proxmox VE 9 / QEMU 11** with **OpenCore 1.0.5**, and verified on real
hardware — see **macOS version support** below for exactly what was tested.

> ### ⚠️ Proxmox 8.4 and newer: two things that stop the VM from starting
>
> Most macOS-on-Proxmox instructions circulating online predate both of these. If you cross-reference
> anything else, these are where it will mislead you:
>
> 1. **`Bus 'ehci.0' not found`** — QEMU 10 removed that USB bus and it is still gone in 11.
>    Anything telling you to use `-device usb-kbd,bus=ehci.0,port=2` is out of date. Use the `args`
>    line in **§7a**.
> 2. **`explicit media parameter is required for iso images`** — since PVE 8.4 you must set
>    **`media=disk`** explicitly on the image drives. Removing `media=cdrom` is not enough.
>    See **§7b**.

---

## 0. What our config.plist gives you

Verified against [EFI/OC/config.plist](EFI/OC/config.plist) at master after the #84 merge:

| Setting | Value | Why it matters to you |
|---|---|---|
| OpenCore | 1.0.5 | Newer than the last tagged release (v21, Mar 2024, pre-Sequoia) |
| Sequoia kernel patches | 2 patches, `MinKernel 24.0.0` | Hides `hv_vmm_present` so Apple Services/iCloud work in a VM. Gated to Sequoia+, so they are inert on Monterey/Ventura/Sonoma |
| `ScanPolicy` | `0` | Every disk is shown in the boot picker (fixes "my disk isn't listed") |
| SMBIOS | `iMac20,1` | Chosen over `MacPro7,1`, which produced memory warnings. Required for Tahoe |
| `boot-args` | `keepsyms=1 -lilubetaall` | `-lilubetaall` lets Lilu-based kexts load on macOS versions newer than they know about |
| `csr-active-config` | `0x0803` | SIP already partially disabled |
| `SecureBootModel` | `Disabled` | |
| Resolution | `1920x1080@32` | Change under `UEFI/Output/Resolution` |
| Kexts | Lilu, WhateverGreen, AppleALC, CryptexFixup, MCEReporterDisabler, USBPorts, AGPMInjector, Brcm* + BlueToolFixup | VirtualSMC is present but **disabled** — QEMU's `isa-applesmc` provides the SMC instead |
| Drivers | OpenRuntime, OpenHfsPlus, OpenCanopy, OpenPartitionDxe, ResetNvramEntry, ToggleSipEntry | You get "Reset NVRAM" and "Toggle SIP" entries in the boot picker |

### Local changes — every deviation from upstream

Eight changes, all in [EFI/OC/config.plist](EFI/OC/config.plist). Upstream has none of them.

| # | Change | From → To | Why |
|---|---|---|---|
| 1 | `Misc/Boot/Timeout` | `0` → `5` | Upstream never autoboots; the picker waits forever ([issue #80](https://github.com/thenickdude/KVM-Opencore/issues/80)) |
| 2 | `Misc/Security/AllowSetDefault` | `false` → `true` | Without it **Ctrl+Enter cannot set a default entry**, so the timeout lands on the useless `EFI` volume |
| 3 | `CryptexFixup` `MinKernel` | `22.1.0` → **`20.0.0`** | **The critical one.** It must load on the *source* OS to patch the installer during an in-place upgrade. At 22.1.0 it never loaded on Monterey, so non-AVX2 upgrades silently installed the wrong cryptex and panicked |
| 4 | `CryptexFixup` `MaxKernel` | `23.99.99` → *(none)* | Capped at Sonoma, so it was skipped on Sequoia and newer |
| 5 | `RestrictEvents.kext` | *absent* → added, `MinKernel 20.4.0` | OCLP injects it on every Ivy Bridge machine |
| 6 | `NVRAM` `revpatch` | *absent* → `f16c` **in both `Add` and `Delete`** | Fixes CoreGraphics on Ivy Bridge under 13.3+. **`Add` alone does nothing** — it only writes variables that don't already exist, so `Delete` is required to force a rewrite each boot |
| 7 | Penryn `cpuid_set_cpufamily` patch | `MaxKernel 23.99.99` → *(none)* | Nothing spoofed the CPU family on Sequoia; the older variant stops at 20.3.99 |
| 8 | *Force FileVault on Broken Seal* patch | `MaxKernel 23.99.99` → *(none)* | The non-AVX2 accommodation, capped below where it was needed |

Changes 3–8 exist because upstream's config was written for the Ventura/Sonoma era. PR #84 added
Sequoia support on top without extending what was already there.

To verify `revpatch` reached the kext — note plain `nvram -p` does **not** list vendor-GUID variables:

```bash
nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:revpatch
```

⚠️ The SMBIOS serial in the repo (`C02C5YYPPN5T`) is shared by everyone using this image. **Generate
your own before signing into an Apple ID** — see §9.

ℹ️ **You do not need [VMHide](https://github.com/Carnations-Botanica/VMHide)**, despite what
[issue #82](https://github.com/thenickdude/KVM-Opencore/issues/82) and most Sequoia guides suggest.
It exists to hide `hv_vmm_present` from macOS so Apple Account sign-in works; the two kernel patches
we merged from PR #84 do the same job at the kernel level. Adding both is redundant.

---

## macOS version support

Darwin numbers matter because every `MinKernel`/`MaxKernel` in `config.plist` is expressed in them.

| macOS | Darwin | AVX2 host | Non-AVX2 host (Ivy Bridge and older) |
|---|---|---|---|
| Catalina 10.15.6+ | 19 | supported by config | native install |
| Big Sur 11 | 20 | supported by config | native install |
| **Monterey 12** | **21** | supported by config | ✅ **verified** — native install |
| Ventura 13 | 22 | supported by config | upgrade in place only |
| **Sonoma 14** | **23** | supported by config | ✅ **verified** — 14.8.9 by in-place upgrade |
| **Sequoia 15** | **24** | reported working by the PR #84 author | ✅ **verified** — 15.7.9 by in-place upgrade |
| Tahoe 26 | 25 | reported working by the PR #84 author | ⚠️ untested |

**Verified** means installed and booted to a working desktop during the writing of this guide, on a
Xeon E5-2670 v2 under Proxmox 9 / QEMU 11. Everything else is what the configuration supports, not
something that has been run.

Two floors worth knowing:

- **Catalina 10.15.6** is the practical minimum — the `iMac20,1` SMBIOS doesn't exist before it.
- **SSE 4.2** is the hard CPU floor for any version.

Older releases (Sierra, Yosemite) need `Kernel/Emulate/Cpuid1Data` and `Cpuid1Mask` removed or they
reboot with no log — see §10.

---

## ⚠️ Non-AVX2 hosts (Ivy Bridge and older): read before you start

macOS Ventura and later ship **only `x86_64h` dyld shared caches**, which require AVX2. On a
pre-Haswell CPU this has one visible consequence and one workable path.

Check your host first:

```bash
grep -o avx2 /proc/cpuinfo | head -1
```

Nothing printed means no AVX2, and this section applies to you.

### What does not work: booting Ventura+ installer media

Booting a Ventura, Sonoma, Sequoia or Tahoe **installer or recovery image** panics before userspace
exists:

```
shared_region: … [1(launchd)] check_np(…) vm_shared_region_start_address() failed
panic(…): initproc failed to start -- exit reason namespace 2 subcode 0x4
```

Verified with genuine, chunklist-verified Apple recovery media. The kernel boots fine, which makes it
look like a config fault — it isn't. The installer environment's dyld cache is baked in, and nothing
injected at boot can change it. **Do not chase this.** Use the upgrade path instead.

### What works: install Monterey, then upgrade in place

Monterey is the newest release whose installer boots natively on pre-Haswell. From there,
`startosinstall` upgrades in place, and **CryptexFixup can intervene because it runs on the source
OS**.

| Target | Status on non-AVX2 |
|---|---|
| Monterey 12.x | ✅ **verified** — installs natively from Apple recovery media |
| Ventura 13.x | ⚠️ untested here, but inside every supported range |
| **Sonoma 14.x** | ✅ **verified** — 14.8.9 upgraded in place |
| **Sequoia 15.x** | ✅ **verified** — 15.7.9 upgraded in place from Sonoma |
| Tahoe 26.x | ⚠️ untested, but nothing known blocks it |

Both verified results are from the same machine: a **Xeon E5-2670 v2** (Ivy Bridge, no AVX2, dual
socket) under **Proxmox 9 / QEMU 11**, installed as Monterey and upgraded in place with
`startosinstall` — Monterey → Sonoma → Sequoia.

No OCLP, no root patching, no SMBIOS changes are needed. OCLP's root patches restore *hardware
drivers* — graphics, wireless, backlight — and explicitly skip the dyld cache above Catalina, so they
are not the mechanism behind non-AVX2 support. **CryptexFixup alone is.** In a VM with paravirtualized
graphics and virtio networking, essentially every OCLP patchset is a no-op.

### How CryptexFixup works, and the trap

It hooks `cs_validate_page` and, when the installer's `ramrod` binary (embedded in
`UpdateBrainLibrary`) is paged in, rewrites the string `cryptex-system-x86_64` to
`cryptex-system-arm64e`. That is the entire trick: it changes which cryptex the installer requests
from Apple.

Because that happens **while the installer runs on the source OS**, the kext must be loaded *there*.
Upstream's `MinKernel 22.1.0` meant it never loaded on Monterey, so `ramrod` was never patched, macOS
grafted the stock Intel cryptex, and the upgraded system panicked:

```
apfs_log_op_with_proc: … grafting volume …x86_64SystemCryptex, requested by: launchd
Library not loaded: /usr/lib/libSystem.B.dylib  … (no such file, no dyld cache)
panic(…): initproc failed to start -- exit reason namespace 6 subcode 0x1
```

**Requirements for a non-AVX2 upgrade** (all already applied in this repo — see §0):

1. `CryptexFixup` at `MinKernel 20.0.0` with no `MaxKernel`
2. `RestrictEvents` with `revpatch=f16c`, listed in **both** `NVRAM/Add` and `NVRAM/Delete`
3. The Penryn and broken-seal kernel patches with their `MaxKernel` ceilings removed

Confirm the kext is live on the source OS *before* starting an upgrade:

```bash
kextstat | grep -i cryptex
```

`-crypt_force_avx` is **not** a workaround — that argument is only consulted when `cpuHasAvx2` is
true, which on this hardware it never is.

CryptexFixup's patch is a literal byte-string match, so a future installer could in principle change
that string and break silently. As of **Sequoia 15.7.9 (24G830) it still matches.**

### Confirming the Rosetta cryptex is in place

After an upgrade, this is the check that proves it worked:

```bash
ls /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/
```

You want to see **`dyld_shared_cache_arm64e`** and a set of **`aot_shared_cache.*`** files. Those come
from the Apple Silicon (Rosetta) cryptex and cannot appear if the stock Intel cryptex was installed.
The baseline `dyld_shared_cache_x86_64` alongside them is what a pre-Haswell CPU actually executes.

Also confirm both kexts are live:

```bash
kextstat | grep -iE "cryptex|restrict"
```

### Living with it

- **No GPU acceleration, ever, on Ventura+.** AMD Polaris/Vega/Navi drivers require AVX2 from Ventura
  onward. Apple's paravirtualized stack still works, which is why there is a display at all.
- **Userspace runs the baseline Rosetta dyld cache** — unoptimized code. This is the performance
  floor and it applies to Xcode too.
- Suits a headless build host driven over SSH far better than an interactive workstation.

---

## 1. Prerequisites

- Proxmox 7, 8, or 9, with an Intel Nehalem-or-newer CPU, or a modern AMD CPU. **SSE 4.2 is the hard
  floor.** On Proxmox 9, see the warning above about the `args` line.
- A real Mac (or an existing Hackintosh/macOS VM) to extract the OSK key from.
- 64 GB+ of free storage for the VM disk. **32 GB is rejected by the installer.**
- **No Mac is required** to build the OpenCore image or the recovery installer — both are done on
  Linux (§2, §3). The only steps that genuinely need macOS are extracting the OSK (§4) and building a
  *full* offline installer instead of a recovery image.

---

## 2. Get the OpenCore image

**Do not use the tagged releases.** The newest is **v21 (March 2024)**, which predates Sequoia and
contains neither the `hv_vmm_present` patches nor OpenCore 1.0.5. Use one of these instead:

**Option A — prebuilt artifact from PR #84** (fastest; attached by the PR author):

- `OpenCore-master.iso.gz` — https://github.com/user-attachments/files/23098001/OpenCore-master.iso.gz
- `OpenCoreEFIFolder-master.zip` — https://github.com/user-attachments/files/23098003/OpenCoreEFIFolder-master.zip

These are third-party binaries from a PR contributor, not from a signed release. If that matters to
you, use Option B.

**Option B — build it yourself, no Mac needed.** Use [build-image-nomac.sh](build-image-nomac.sh)
from this repo. Every submodule pinned by master is an upstream *release tag*, and Acidanthera ships
prebuilt binaries for each, so nothing has to be compiled — the script downloads those exact versions
and assembles the identical EFI tree.

Run it on the Proxmox host (or any Linux box), which is where the image needs to end up anyway. Clone
**this fork** — the script and the merged PR #84 config only exist here, not in thenickdude's repo:

```bash
apt install -y curl unzip gdisk mtools git && git clone https://github.com/asulwer/KVM-Opencore.git && cd KVM-Opencore
```

```bash
./build-image-nomac.sh && cp OpenCore-master.img /var/lib/vz/template/iso/
```

> **The `src/` folders are empty — that's normal.** They're git submodules (Lilu, OpenCorePkg,
> WhateverGreen, …) and a plain `git clone` leaves them as empty mount points; `git submodule status`
> shows each with a `-` prefix meaning "not checked out". **`build-image-nomac.sh` never touches
> them** — it downloads prebuilt release binaries instead, which is precisely why it doesn't need a
> Mac. Only the Makefile (Option C) needs them, via `git submodule update --init`.

No root or loop devices needed — it writes the FAT32 partition with `mtools`. Versions it pulls:
OpenCore 1.0.5, Lilu 1.7.1, WhateverGreen 1.7.0, AppleALC 1.9.5, VirtualSMC 1.3.7, BrcmPatchRAM
2.7.1, CryptexFixup 1.0.5. Bump the variables at the top of the script if you bump a submodule.

**Option C — the repo's Makefile.** `make dist` produces `OpenCore-master.iso.gz`, `.dmg.gz`, and
`OpenCoreEFIFolder-master.zip`, and builds every kext from source. It needs `hdiutil` and
`xcodebuild`, so this one **does** require a Mac. Only worth it if you've modified kext source or
want to verify the binaries yourself.

Gunzip the `.iso.gz` and upload the result to `/var/lib/vz/template/iso` on the Proxmox host.

> It is not a real ISO — it is a raw GPT hard-disk image with an `.iso` extension so that Proxmox's
> disk picker will list it. This is exactly why §7b makes you attach it as `media=disk,cache=unsafe`.

---

## 3. Build the macOS installer image

> **Already have installer images? Skip this section** — but check three things first:
>
> 1. **Format.** It must be a *raw* disk image. Run `qemu-img info yourfile` on the Proxmox host: it
>    should report `file format: raw`. If it says `dmg`, convert it:
>    `qemu-img convert -O raw in.dmg out.img`. If `file yourfile` says *ISO 9660*, it will not boot
>    here regardless of what you do in §7b — that path expects a hard-disk image.
> 2. **Provenance.** Prefer an image you fetched from Apple yourself (§3, chunklist-verified) over a
>    prebuilt one. Third-party repacks may be patched for a different host CPU, and you will burn
>    hours blaming your config for their image. Size is a weak signal — a genuine Sequoia recovery
>    `BaseSystem.dmg` is ~843 MB, while a full installer is ~14 GB.
> 3. **Version.** Our config covers Catalina 10.15.6 through Tahoe — the `iMac20,1` SMBIOS doesn't
>    exist before 10.15.6, and the two `hv_vmm_present` patches are gated to `MinKernel 24.0.0`, so
>    they sit inert on anything below Sequoia. Nothing to change either way.
>
> Then drop the image in `/var/lib/vz/template/iso/` and continue at §4.

Use **kholia/OSX-KVM**'s `fetch-macOS-v2.py`, which downloads recovery images directly from Apple
and supports every shortname from `high-sierra` through `sequoia` and `tahoe`.

On the Proxmox host (or any Linux box with `python3` and `qemu-utils`):

```bash
apt install -y qemu-utils python3 && git clone --depth 1 https://github.com/kholia/OSX-KVM.git && cd OSX-KVM
```

```bash
python3 fetch-macOS-v2.py --shortname sequoia
```

Substitute `tahoe`, `sonoma`, `ventura`, or `monterey` as needed. Then convert the downloaded
`BaseSystem.dmg` into a raw image:

```bash
qemu-img convert -O raw /root/OSX-KVM/BaseSystem.dmg /var/lib/vz/template/iso/Sequoia-recovery.img
```

Two common pitfalls:

- The script writes `BaseSystem.dmg` into its **own directory**, not into `com.apple.recovery.boot/`
  — read the `Saving … to ./BaseSystem.dmg` line in its output for the real path.
- **Don't judge it by size alone.** `fetch-macOS-v2.py` verifies the download against Apple's
  chunklist and prints `Image verification complete!` — trust that over any size heuristic. For
  reference, Sequoia's recovery `BaseSystem.dmg` is ~843 MB compressed and expands when converted to
  raw. Older advice that "anything near 650 MB is truncated" predates chunklist verification and
  applies to Monterey-era images; a verified 843 MB Sequoia download is correct.
- A **recovery** image downloads the OS from Apple during install, so the guest needs working DHCP
  and internet. A **full installer** (~14 GB) carries the payload and doesn't.
- The recovery installer downloads the OS at install time and needs working DHCP + internet in the
  guest. If you get `PKDownloadError error 8` or "An error occurred loading the update", use a **full
  installer** image instead of recovery (buildable only on a real Mac), or fix guest networking first
  (§10).

---

## 4. The OSK key

macOS refuses to boot unless it sees Apple's SMC authentication key. It is **not per-machine** — one
fixed 64-character ASCII string, identical on every Mac, so there is nothing to extract. It is
already embedded in the `args` lines in §7a; no action needed here.

(Apple's macOS licence permits virtualization only on Apple-branded hardware, so a macOS VM on a
non-Apple host sits outside that licence regardless.)

---

## 5. Prepare the Proxmox host

Without this, the VM boot-loops:

```bash
echo 1 > /sys/module/kvm/parameters/ignore_msrs
```

Make it survive reboots:

```bash
echo "options kvm ignore_msrs=Y" >> /etc/modprobe.d/kvm.conf && update-initramfs -k all -u
```

This is the **only host-global change** the base guide makes, and it applies to every guest on the
host, not just macOS. It's a single file plus an initramfs rebuild — see **§11** for exactly what it
does and how to back it out. Note the `>>`: run it twice and you get duplicate lines.

---

## 6. Create the VM

Create via the Proxmox web UI with these settings:

| Tab | Setting |
|---|---|
| OS | Type **Other**, ISO = the OpenCore image |
| System | Graphics **VMware compatible**, Machine **q35**, BIOS **OVMF (UEFI)**, QEMU Agent ✔, EFI storage set, **"Pre-Enroll keys" UNTICKED** |
| Disks | virtio0, **64 GB minimum**, Discard ✔ (TRIM), cache **Write back (unsafe)** |
| CPU | Type **Penryn**, cores = **a power of two** (1/2/4/8) |
| Memory | 4096 MB minimum, **ballooning off** |
| Network | **VirtIO (paravirtualized)** |

Then add the recovery image as a second CD/disk (`ide0`) after creation.

⚠️ The **"Pre-Enroll keys"** tickbox is the single most common cause of a failed setup. If it is
ticked you land in the **UEFI shell** instead of the OpenCore picker, and unticking it afterwards
does **not** fix an already-created EFI disk — you must *delete* the EFI disk from the Hardware tab
and re-add it with the box unticked.

Non-power-of-two core counts hang at the Apple logo. If you want 6 cores, set **3 sockets × 2
cores** — macOS accepts odd socket counts but not odd core counts.

---

## 7. Edit the VM config file

SSH into Proxmox and edit `/etc/pve/qemu-server/YOUR-VM-ID.conf` directly with nano/vim.

Do this over SSH, not through the web UI — UI edits can silently revert the `args` line and the
drive settings.

### 7a. Add the `args` line

**[PVE 9]** Proxmox 9 / QEMU 10 — use this, verbatim, on one line:

```
args: -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" -smbios type=2 -device qemu-xhci -device usb-kbd -device usb-tablet -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off -cpu Haswell-noTSX,vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on
```

The `osk=` value is the OSK from §4 — the same on every Mac, so copy it exactly as written. It is
**case-sensitive** and exactly **64 characters** between the quotes. One wrong character gives you a
hang at the Apple logo or an `AppleKeyStore` boot loop, with no error message pointing back to the
OSK — which makes it one of the hardest failures here to diagnose.

The USB half is the part that changed: `-device usb-kbd,bus=ehci.0,port=2` becomes
`-device qemu-xhci -device usb-kbd -device usb-tablet`, because QEMU 10 dropped the `ehci.0` bus.
The CPU half is a single model that works on both Intel and AMD hosts, since it spoofs
`vendor=GenuineIntel` either way.

**Prefer an explicit CPU model over `-cpu host`.** A passthrough CPU type leaks CPUID details macOS
doesn't expect and is a common cause of one-core-only boots. The exception is a host old enough that
macOS knows it natively — on Ivy Bridge and similar, `-cpu host` is fine and avoids advertising
features the host doesn't actually have.

---

**Proxmox 7 / 8** — the older form still works there:

```
args: -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" -smbios type=2 -device usb-kbd,bus=ehci.0,port=2 -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
```

Then append **one** of these CPU blocks to the same line.

Intel host:

```
-cpu host,kvm=on,vendor=GenuineIntel,+kvm_pv_unhalt,+kvm_pv_eoi,+hypervisor,+invtsc
```

AMD host:

```
-cpu Penryn,kvm=on,vendor=GenuineIntel,+kvm_pv_unhalt,+kvm_pv_eoi,+hypervisor,+invtsc,+pcid,+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+fma,+fma4,+bmi1,+bmi2,+xsave,+xsaveopt,+rdrand,check
```

**AMD notes:** if you see clock drift, drop `+invtsc`. If you hang at the Apple logo on a Ryzen APU,
disable **ErP Mode** and **Global C-state Control** in the host BIOS and try adding `+tsc_adjust`. Penryn lacks AVX2 — if a guest app needs it, some readers switched the model to
`Haswell`.

**[issue #15]** `+hypervisor` is not optional. The macOS kernel grants itself large timing tolerances
once it knows it is virtualized; without that flag you get timeout panics that look like hardware
faults. This was the actual root cause in a long TSC-panic thread.

**[issue #37]** **If your AMD box only boots with one core**, the fix is *fewer* args, not more. A
Ryzen 3000-series user tried Haswell, Cascadelake, and hand-added `+AVX`/`+AVX2` with no success,
then booted 8 cores first try with:

```
args: -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" -smbios type=2 -cpu Cascadelake-Server,vendor=GenuineIntel,+invtsc,kvm=on,vmware-cpuid-freq=on
```

…plus `cpu: Cascadelake-Server` in the config. Worth trying before you start bisecting flags.

⚠️ There must be exactly **one** `args:` line in the file. A second one — easily introduced when
following separate instructions for VNC or passthrough — silently overwrites the first, and the
symptom is usually a missing disk rather than an error.

### 7b. Convert the CD-ROM lines to disks

Drives are referenced as **`STORAGE:iso/FILENAME`**. These examples use `local`, the stock directory
storage whose ISO folder is `/var/lib/vz/template/iso/`. If your images live on a different storage,
substitute its name — `pvesm status --content iso` lists the ones that can hold ISOs, and a wrong
name here fails with *"storage 'x' does not exist"*.

Both images must be attached as **disks**, not CD-ROMs — they are raw hard-disk images, not ISO
9660. Set `media=disk` **explicitly** and add `cache=unsafe`:

```
ide0: local:iso/Sequoia-recovery.img,media=disk,cache=unsafe,size=3G
ide2: local:iso/OpenCore-master.img,media=disk,cache=unsafe,size=150M
```

### You must edit the `.conf` file by hand — `qm set` and the web UI cannot do this

This is not a stylistic preference. Proxmox has **two separate guards** on ISO-storage volumes, and
they contradict each other:

| Layer | Source | Rule |
|---|---|---|
| API — `qm set`, `pvesh`, web UI | `src/PVE/API2/Qemu.pm` | Requires **`media=cdrom` specifically**; `media=disk` is rejected |
| VM start | `src/PVE/QemuServer.pm`, `Blockdev.pm` | Requires only that **`media` be defined**; `media=disk` is accepted |

Try it through the API and you get a parameter-verification failure:

```
ide0: explicit 'media=cdrom' is required for iso images
```

…from this check, which demands `cdrom` and nothing else:

```perl
raise_param_exc({ $opt => "explicit 'media=cdrom' is required for iso images" })
    if $vtype eq 'iso' && !(defined($drive->{media}) && $drive->{media} eq 'cdrom');
```

The VM-start path is more permissive — it only objects to `media` being absent:

```perl
die "$drive_id: explicit media parameter is required for iso images\n"
    if !defined($drive->{media}) && defined($vtype) && $vtype eq 'iso';
```

So the API forbids precisely what the runtime accepts. Writing the lines straight into
`/etc/pve/qemu-server/VMID.conf` skips API validation — pmxcfs is just a filesystem — and the start
path then takes them:

```bash
cat >> /etc/pve/qemu-server/VMID.conf <<'EOF'
ide0: local:iso/Sequoia-recovery.img,media=disk,cache=unsafe,size=3G
ide2: local:iso/OpenCore-master.img,media=disk,cache=unsafe,size=150M
EOF
```

Set the boot order separately, since `boot:` already exists and appending a duplicate key would break
the file — and because `qm set` only validates the option being changed, this succeeds even with the
`media=disk` drives present:

```bash
qm set VMID --boot order=ide2
```

**Removing `media=cdrom` without replacing it fails differently.** The config saves fine, but the VM
won't start:

```
ide0: explicit media parameter is required for iso images
```

The drive schema *does* declare `default => 'disk'`, but the check above fires before the default is
applied, so undefined and `media=disk` are not equivalent. Proxmox ships a regression test for this,
`src/test/cfg2cmd/ide-no-media-error.conf`, whose passing line is `media=disk` and whose failing line
has no `media` at all.

Skip §7b entirely and OpenCore never appears in the boot menu — both images are raw hard-disk images,
not ISO 9660, so they have to be attached as disks rather than optical media.

⚠️ That the API refuses to express this config is a strong hint it is **unsupported**, and Proxmox
staff have said as much in the forum thread below. It works today. Treat it as something that can
break on a future upgrade, and avoid touching those two drives in the web UI — the GUI will refuse to
save them.

### 7c. Reference config (Proxmox 9)

```
args: -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" -smbios type=2 -device qemu-xhci -device usb-kbd -device usb-tablet -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off -cpu Haswell-noTSX,vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on
agent: 1
balloon: 0
bios: ovmf
boot: order=ide2
cores: 4
cpu: Haswell-noTSX
efidisk0: local-lvm:vm-171-disk-1,efitype=4m,size=1M
ide0: local:iso/Sequoia-recovery.img,media=disk,cache=unsafe,size=3G
ide2: local:iso/OpenCore-master.img,media=disk,cache=unsafe,size=150M
machine: pc-q35-11.0
memory: 4096
name: macos-sequoia
net0: virtio=...,bridge=vmbr0,firewall=1
ostype: other
virtio0: local-lvm:vm-171-disk-0,cache=unsafe,discard=on,size=64G
vga: vmware
```

**[PVE 9]** Note the pinned `machine:` version rather than bare `q35`. Pinning means a future
Proxmox/QEMU upgrade won't silently change the virtual hardware underneath macOS — which macOS,
unlike Linux or Windows guests, tends to react badly to.

**Don't copy a version number from this guide** — Proxmox 9 ships QEMU 10 or 11 depending on point
release, and `q35` alone resolves to whatever the current default is. Read the newest your host
actually offers and pin to that:

```bash
qm set VMID --machine "$(kvm -machine help | grep -oE 'pc-q35-[0-9]+\.[0-9]+' | sort -V | tail -1)"
```

`qm config VMID | grep meta` also shows the QEMU version the VM was created under.

---

## 8. Install macOS

1. Start the VM and open the console. At the OpenCore picker choose **macOS Base System** (or
   "Install macOS …" if you built a full installer).

   ⚠️ **Do not let it autoboot the first entry.** Because `ScanPolicy=0` lists every volume, the
   first entry is typically a bare **`EFI`** — the OpenCore image's own EFI partition — and booting
   it goes nowhere, leaving a black screen that looks like a hang. A typical picker reads:
   `EFI`, `Install macOS Sequoia`, `UEFI Shell`, `Reset NVRAM`, `Toggle SIP`.

   Arrow down to the installer and press **Ctrl+Enter** rather than Enter: that boots it *and* makes
   it the default, so the timeout stops selecting `EFI`. Ctrl+Enter only works because of the
   `AllowSetDefault=true` change in §0 — on stock upstream config it does nothing.

   To declutter the picker permanently, set `Misc/Boot/HideAuxiliary=true`, which hides the shell and
   utility entries behind a Space keypress.
2. In the installer, open **Disk Utility** first. Erase your 64 GB virtio disk as **APFS**, GUID
   partition map. Quit Disk Utility.
3. Run the installer against that disk.
4. The VM will reboot 2–3 times. **At each reboot, manually pick the "macOS Installer" entry** (the
   second one) in the OpenCore picker — it does not continue by itself.
5. After the final reboot, pick your main disk to boot into macOS.
6. Complete Setup Assistant, but **do not sign into an Apple ID yet** (§9).

Timing sanity: "About 2 hours 17 minutes remaining" is normal — Apple's servers are slow and 3
hours total is not unusual. Check host network traffic to confirm it's still
downloading rather than hung. A progress bar that hangs at 12–15% has often been fixed by keeping the
console session active (move the mouse; don't let anything sleep).

### Make OpenCore permanent

From Terminal in the installed macOS, list disks:

```bash
diskutil list
```

Identify the EFI partition on the **OpenCore image** (source) and on your **main disk** (target).
Then copy source → target:

```bash
sudo dd if=/dev/disk1s1 of=/dev/disk0s1
```

⚠️ `disk1s1` / `disk0s1` are **examples only**. **Verify your own identifiers in the `diskutil
list` output first** — `dd` with the arguments backwards overwrites OpenCore's EFI onto your
macOS disk's EFI in the wrong direction and you lose your bootloader.

Shut down, remove both `ide0` and `ide2` from the Hardware tab, set `virtio0` first in the boot order,
and restart.

---

## 9. Post-install

### Unique serial (do this before Apple ID)

The shipped `iMac20,1` serial is shared across every user of this image, so iCloud/iMessage will fail
or get flagged. Generate your own with [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) for
`iMac20,1` and write `SystemSerialNumber`, `SystemUUID`, `MLB`, and `ROM` into
`PlatformInfo/Generic` in `config.plist`.

For iMessage/FaceTime you also need `en0` marked as built-in — follow
[Dortania's iServices guide](https://dortania.github.io/OpenCore-Post-Install/universal/iservices.html).
If iCloud toggles spin without saving, sign fully out of iCloud and back in.

### Editing config.plist afterwards

In macOS:

```bash
sudo mkdir /Volumes/EFI && sudo mount -t msdos /dev/disk0s1 /Volumes/EFI
```

Use a plist-aware editor (Xcode, ProperTree) — **not TextEdit**.

From the Proxmox host, against the image file:

```bash
losetup --partscan /dev/loop0 /var/lib/vz/template/iso/OpenCore-master.iso && mount /dev/loop0p1 /mnt
```

```bash
umount /mnt && losetup --detach /dev/loop0
```

**[issue #83]** That only works on the standalone image file. Once you've done §8, the EFI you
actually boot lives on the VM's disk — and if that's **LVM-thin**, `losetup` won't reach it. Use
`kpartx` instead (VM must be shut down):

```bash
apt-get install -y kpartx && kpartx -av /dev/pve/vm-VMID-disk-0
```

That prints the mapped partitions, e.g. `pve-vm--171--disk--0p1`. Mount the first one:

```bash
mkdir -p /mnt/tmp && mount /dev/mapper/pve-vm--171--disk--0p1 /mnt/tmp && nano /mnt/tmp/EFI/OC/config.plist
```

```bash
umount /mnt/tmp && kpartx -dv /dev/pve/vm-VMID-disk-0
```

This is the escape hatch when a bad `config.plist` edit leaves the VM unbootable.

---

## 10. Troubleshooting

Consolidated from all six comment pages. Left column is the symptom you'll actually see.

| Symptom | Fix |
|---|---|
| **VM won't start: `Bus 'ehci.0' not found`** | **[PVE 9]** QEMU 10 dropped that bus. Replace `-device usb-kbd,bus=ehci.0,port=2` with `-device qemu-xhci -device usb-kbd -device usb-tablet` (§7a) |
| **VM won't start: `ide0: explicit media parameter is required for iso images`** | **[PVE 8.4+]** `media` is undefined — `media=cdrom` was removed without adding `media=disk`. See §7b |
| **`qm set` fails: `explicit 'media=cdrom' is required for iso images`** | Expected — the API refuses `media=disk` on ISO storage. Write the `ide` lines directly into `/etc/pve/qemu-server/VMID.conf`, then set the boot order with `qm set` (§7b) |
| OpenCore/installer still not offered as a boot entry | Both IDE lines need **`media=disk,cache=unsafe`**, not one or the other (§7b) |
| `media=disk` rejected on a future Proxmox upgrade | It's an unsupported workaround. Fallback: import the image as a real VM disk — `qm importdisk VMID /var/lib/vz/template/iso/Sequoia-recovery.img local-lvm` — then attach it and set the boot order. Sidesteps ISO-storage handling entirely |
| Only boots with **one core** on PVE 9 | Drop `-cpu host` for an explicit model such as `Haswell-noTSX` or `Cascadelake-Server` (§7a, issue #37) |
| **Black screen right after the picker autoboots** | The first entry is a bare `EFI` volume, not your installer — `ScanPolicy=0` lists everything. Select the `Install macOS …` entry and press **Ctrl+Enter** to make it the default (§8) |
| Timeout too short to catch the picker | `Misc/Boot/Timeout` in config.plist. §0 sets it to 5 s for unattended autoboot; raise it to 30 while debugging |
| Boots to **UEFI shell**, no OpenCore picker | Delete the EFI disk, re-add with "pre-enroll keys" unticked. Failing that: F2 → Boot Maintenance → Boot Options → delete stale entries, add `EFI/OC/OpenCore.efi`, make it default |
| `Bd5Dxe: failed to load Boot0003` | Same as above |
| OpenCore entry missing / "cannot find QEMU DVD-ROM" | You skipped §7b — the IDE lines need `media=disk,cache=unsafe` |
| **`initproc failed to start`, namespace 2** | Host lacks AVX2 and you're booting Ventura+ installer *media*. Not fixable — install Monterey and upgrade in place (see the non-AVX2 section) |
| **`initproc failed to start`, namespace 6**, log shows `grafting …x86_64SystemCryptex` | CryptexFixup didn't patch the installer. Check it was loaded on the **source** OS: `kextstat \| grep -i cryptex`. Needs `MinKernel 20.0.0` |
| **Stuck at Apple logo**, no progress bar | In order of likelihood: OSK not exactly 64 chars; core count not a power of two; CPU missing SSE 4.2; remove hugepages from the host kernel cmdline |
| Boot loop with `AppleKeyStore operation failed` | Wrong OSK |
| Kernel panic, `TSC warp between CPUs` | Known on Sandy Bridge-era hosts; see OSX-KVM issue #15. `CpuTscSync.kext` was reported to help, especially for wake-from-sleep panics |
| Crash ~60 s into Setup Assistant | Check host: `dmesg \| grep -i -e tsc -e clocksource` |
| Your virtio disk isn't in Disk Utility | Our config sets `ScanPolicy 0`, so check for a duplicate `args:` line first; then "Show All Devices" in Disk Utility |
| Installer refuses the disk | Disk is under 64 GB |
| `will not load trust cache because required files are missing` | Install Big Sur first, then upgrade via Software Update |
| Recovery download fails (`PKDownloadError error 8`) | Guest needs DHCP + internet. Try a static IP, run dnsmasq on the Proxmox host, or switch the NIC to `vmxnet3` |
| Won't wake from sleep | Disable sleep in Energy Saver. To wake manually: `qm monitor VMID` → `system_wakeup` → `quit` |
| Wrong screen resolution | `UEFI/Output/Resolution` in config.plist |
| **White desktop background on Sonoma+**, wallpaper flashes then disappears | Sonoma's wallpapers are videos and the VM has no video decode, so `WallpaperVideoExtension` logs *"0 frames enqueued"* and renders nothing. Cosmetic. Pick **Solid Color** or supply your own JPG/PNG — most "static" options are stills from the aerial videos and still use that extension |
| Terrible video performance | Expected — there is no guest GPU acceleration. Use macOS **Screen Sharing** (VNC) rather than the Proxmox console; disable hardware acceleration in Chrome. Real fix is GPU passthrough |
| Need verbose boot | Press (don't hold) **Cmd+V** at the OpenCore picker before Enter. For panics that reboot too fast, add `debug=0x100` to boot-args |
| Need SIP off | Boot Recovery → `csrutil disable --no-internal` (our config already ships `csr-active-config 0x0803`) |
| USB device not passing through | `qm monitor VMID` → `info usbhost`, then `qm set VMID -usb1 host=VENDOR:DEVICE`. Drop `usb3=1` for USB 2.0 devices. Passing the whole controller through via PCIe is more reliable |
| USB Bluetooth adapter dead | Already handled — `BlueToolFixup.kext` is in our config |
| **Tahoe/Sequoia freeze at `#[EB\|LOG:EXITBS:START]`**, log shows `algrey \| _cpuid_set_generic_info … Not Found` | **[issue #85]** You're on an old OpenCore with bare-metal AMD_Vanilla patches bolted on. Our merged config *is* the fix — see §0. Do **not** add AMD_Vanilla patches: under QEMU we spoof `vendor=GenuineIntel`, so those patches have nothing to match and log `Not Found` by design |
| Kernel panics / random reboots when the host is under heavy I/O | **[issue #15]** Add `tlbto_us=0 vti=9` to boot-args. Also prefer your distro's OVMF (`OVMF_CODE_4M.fd`) over one bundled with a third-party repo — swapping it dropped one reporter's CPU usage to near zero |
| Repeated reboots during a macOS *upgrade* with a passthrough GPU | **[issue #15]** Detach the GPU for the duration of the upgrade; the driver handles the repeated restarts badly |
| Can't boot into **safe mode** | **[issue #43]** Known limitation of Proxmox's OVMF — neither Shift+Enter nor the `-x` boot-arg reliably works. Plan around it, especially if you were counting on safe mode to apply OCLP post-install patches |
| Non-AVX2 CPU + AMD Polaris, no graphics acceleration on Ventura+ | **[issue #43]** Needs OpenCore Legacy Patcher's post-install volume patches, which collide with the safe-mode limitation above |
| **Sierra, Yosemite or older** black-screens or reboots with no log | **[issues #35, #76]** Remove `Kernel/Emulate/Cpuid1Data` and `Cpuid1Mask` from config.plist — old kernels choke on those bits and die before logging anything. Our config sets both (Penryn spoof) since it targets Catalina 10.15.6+ |

### GPU passthrough

| Symptom | Fix |
|---|---|
| Black screen after Apple logo | Set `vga: none`; add `agdpmod=pikera` to boot-args |
| `Failed to mmap … BAR 0` | Add `initcall_blacklist=sysfb_init` to the host kernel cmdline |
| Card only works once per power cycle | AMD Reset Bug — install the `vendor-reset` kernel module |
| GPU never initializes | Attach a real monitor or an HDMI dummy plug; set integrated graphics as primary in host UEFI |
| GPU reports 3 MB VRAM | Device-ID spoofing is wrong — it must match a macOS-supported GPU |
| Freeze during boot | Ensure `-global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off` is in `args`; disable CSM, disable Resizable BAR, update the card's VBIOS; tick **PCI-Express** and **All Functions** on the hostpci line |
| NVIDIA card | Kepler (GT 710 etc.) lost support in Monterey; RTX 2000/3000 series have no macOS drivers at all. AMD is the practical choice |

Host kernel args for AMD IOMMU:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on"
```

Confirmed-working data point: X570 + RX 580, CSM **enabled** in host BIOS, 40.9 FPS in Unigine
Valley on Monterey. The same setup hung at PCI enumeration under Ventura.

NVMe passthrough is hit-and-miss — a WD SN750 1 TB was invisible to Disk Utility while an SN750 SE
512 GB and a Samsung 970 Pro worked with no config changes. Emulated fallback:
`virtio0: file=/dev/nvme1n1` (slower).

---

## 11. Backing out — what this touches on the host, and how to undo it

Almost everything here is **VM-scoped** and disappears when you delete the VM. Only two changes are
host-global, and only one of those can leave the host unbootable. Nothing in this guide modifies your
existing VMs, your storage config, your network config, or the Proxmox cluster.

| What | Scope | Reversible? | Reboot to undo? |
|---|---|---|---|
| The VM, its disks, its EFI disk | VM only | Yes — `qm destroy` | No |
| Image files in `/var/lib/vz/template/iso/` | Files | Yes — `rm` | No |
| `args:` line, `media=disk`, machine pinning | VM only | Yes — edit or delete the VM | No |
| `echo 1 > /sys/module/kvm/parameters/ignore_msrs` | **Host-global**, runtime only | Self-reverting | Yes — gone on reboot |
| `/etc/modprobe.d/kvm.conf` + `update-initramfs` | **Host-global**, persistent | Yes — delete file, rebuild initramfs | Yes |
| Packages (`mtools`, `gdisk`, `kpartx`, …) | Host | Yes, but see the warning below | No |
| `losetup` / `kpartx` mappings | Host, runtime | Yes — detach them | No |
| **GPU passthrough: GRUB cmdline, vfio binding, blacklists** | **Host-global** | Yes, **but this is the dangerous one** | Yes |

### Before you start: the two-minute insurance policy

```bash
mkdir -p /root/macos-vm-backup && cp -a /etc/default/grub /etc/modprobe.d /root/macos-vm-backup/
```

And record which packages were genuinely new, so cleanup doesn't guess later:

```bash
apt-mark showmanual | sort > /root/macos-vm-backup/pkgs-before.txt
```

### Full teardown

**1. Remove the VM and its disks.**

```bash
qm stop VMID; qm destroy VMID --purge --destroy-unreferenced-disks 1
```

`--purge` also strips it from backup jobs, HA, and replication. Confirm the disks are gone with
`pvesm list local-lvm | grep VMID`.

**2. Delete the images.**

```bash
rm -f /var/lib/vz/template/iso/OpenCore-master.img /var/lib/vz/template/iso/*-recovery.img
```

**3. Undo the KVM module option.** This is the one host-global change the base guide makes:

```bash
rm -f /etc/modprobe.d/kvm.conf && update-initramfs -k all -u
```

It takes effect on the next reboot; until then the running kernel keeps `ignore_msrs=Y`. Verify
afterwards with `cat /sys/module/kvm/parameters/ignore_msrs` — `N` means it's off.

> ⚠️ The guide's install command uses `>>` (append). Running it more than once silently stacks
> duplicate `options kvm ignore_msrs=Y` lines. Check with `cat /etc/modprobe.d/kvm.conf` before
> assuming one removal did it — and if you had a `kvm.conf` there for other reasons, edit the file
> instead of deleting it.

**What `ignore_msrs=Y` actually does while it's on:** KVM silently ignores guest reads/writes of
model-specific registers it doesn't emulate, instead of injecting a #GP fault. It applies to every
guest on the host, not just macOS. In practice other guests don't notice; the realistic side effect
is `dmesg` filling with *"ignored rdmsr"* lines, which you can quiet with
`options kvm report_ignored_msrs=N` if it bothers you.

**4. Release any stale loop or device-mapper mappings** left behind by the §9 config.plist edits —
these survive until reboot and can hold a disk busy:

```bash
losetup -a
```

```bash
losetup --detach /dev/loopN && kpartx -dv /dev/pve/vm-VMID-disk-0
```

**5. Packages — leave them alone unless you're sure.**

⚠️ **Do not blanket-remove the packages from §2/§3.** `qemu-utils` in particular is part of the
normal Proxmox toolchain, and purging it can break your host. `python3` and `git` are similarly
load-bearing for other things. Only remove what was genuinely new on *your* system:

```bash
comm -13 /root/macos-vm-backup/pkgs-before.txt <(apt-mark showmanual | sort)
```

`mtools`, `gdisk`, and `kpartx` are self-contained and safe to remove if they show up there. Honestly,
the disk cost is a rounding error — leaving all of them installed is the lower-risk choice.

### The dangerous part: GPU passthrough

Everything above is low-stakes. The GPU passthrough steps are not, and they're the only place in this
guide that can cost you access to the host:

- **A bad `/etc/default/grub` edit can make Proxmox unbootable.** Always `update-grub` and read its
  output before rebooting. If the host won't boot, hold Shift at power-on for the GRUB menu, press
  `e`, remove the offending kernel arguments, and boot that entry once — then fix the file properly.
- **Binding your only GPU to `vfio-pci` kills the host console.** Have SSH working and verified from
  another machine *before* you reboot, or you'll be plugging in a keyboard and monitor to a machine
  that no longer outputs video.
- Undo is: restore `/root/macos-vm-backup/grub`, remove any vfio/blacklist files you added under
  `/etc/modprobe.d/`, then `update-grub && update-initramfs -k all -u && reboot`.

Do GPU passthrough as a **separate change, after** the VM works with emulated graphics. If you
combine the two and it breaks, you won't know which half caused it.

### Reverting the repo side

Nothing here touches Proxmox. To drop the local config change and go back to stock upstream:

```bash
git fetch origin && git diff origin/master -- EFI/OC/config.plist
```

Then rebuild the image and re-copy it to the host.

---

## Credits and further reading

**Nothing here is required reading** — this guide is self-contained. These are the sources the work
draws on, listed for attribution and for anyone wanting to go deeper.

**Foundational work this builds on**

- Nicholas Sherlock's [macOS on Proxmox guides](https://www.nicksherlock.com/2021/10/installing-macos-12-monterey-on-proxmox-7/) and their reader comment threads, the origin of the `isa-applesmc` / `q35` / `cache=unsafe` approach and much of the troubleshooting here
- [thenickdude/KVM-Opencore](https://github.com/thenickdude/KVM-Opencore) — the upstream image this repo forks, itself forked from [Leoyzen's](https://github.com/leoyzen/KVM-Opencore)
- [Acidanthera](https://github.com/acidanthera) — OpenCore, Lilu, WhateverGreen, AppleALC, VirtualSMC, CryptexFixup, RestrictEvents
- [OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher) — source of the non-AVX2 findings: the `CryptexFixup` gating, `revpatch=f16c` for Ivy Bridge, and confirmation that root patches address hardware drivers rather than the dyld cache
- [Dortania OpenCore Post-Install](https://dortania.github.io/OpenCore-Post-Install/) — iServices and SMBIOS guidance

**Specific sources cited in the text**

- [PR #84](https://github.com/thenickdude/KVM-Opencore/pull/84) — OpenCore 1.0.5, Sequoia and Tahoe support (merged into this fork)
- [PR #79](https://github.com/thenickdude/KVM-Opencore/pull/79) — the original `hv_vmm_present` patch discovery
- [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) — `fetch-macOS-v2.py`, used in §3
- [Mac OS 15 Sequoia on Proxmox 9.0.3](https://forum.proxmox.com/threads/mac-os-15-sequoia-on-proxmox-9-0-3.169742/) — source of the working PVE 9 `args` line
- [8.4: "Fake" IDE drives from ISO images no longer supported?](https://forum.proxmox.com/threads/8-4-fake-ide-drives-from-iso-images-no-longer-supported.164967/) — the `media=disk` change, including Proxmox staff's view that it is a workaround
- [`proxmox/qemu-server`](https://github.com/proxmox/qemu-server) — `src/PVE/API2/Qemu.pm` (API-side `media=cdrom` requirement), `src/PVE/QemuServer.pm` and `src/PVE/QemuServer/Blockdev.pm` (the looser VM-start check), and `src/test/cfg2cmd/ide-no-media-error.conf`
- [.NET for iOS — Xcode requirement](https://learn.microsoft.com/en-us/dotnet/ios/troubleshooting/xcode-requirement) and [dotnet/macios releases](https://github.com/dotnet/macios/releases) — the .NET ↔ Xcode ↔ macOS version chain
- Upstream issues drawn on: [#15](https://github.com/thenickdude/KVM-Opencore/issues/15) (TSC panics), [#35](https://github.com/thenickdude/KVM-Opencore/issues/35) / [#76](https://github.com/thenickdude/KVM-Opencore/issues/76) (pre-Catalina `Cpuid1Data`), [#37](https://github.com/thenickdude/KVM-Opencore/issues/37) (AMD single-core boots), [#43](https://github.com/thenickdude/KVM-Opencore/issues/43) (safe mode, non-AVX2 graphics), [#80](https://github.com/thenickdude/KVM-Opencore/issues/80) (picker defaults), [#82](https://github.com/thenickdude/KVM-Opencore/issues/82) (VMHide), [#83](https://github.com/thenickdude/KVM-Opencore/issues/83) (mounting config.plist on LVM-thin), [#85](https://github.com/thenickdude/KVM-Opencore/issues/85) (Tahoe freeze)

**Alternatives**

- [LongQT-sea/OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO) — an actively maintained alternative image covering Mac OS X 10.4 through macOS 26, with per-host-CPU guidance. Worth trying if this image gives you trouble

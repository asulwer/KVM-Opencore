#!/usr/bin/env bash
#
# Build the OpenCore disk image WITHOUT a Mac.
#
# The Makefile in this repo compiles every kext from source with xcodebuild and packages the result
# with hdiutil, so it only runs on macOS. This script skips compilation entirely: every submodule
# pinned by master is an upstream RELEASE TAG, and Acidanthera publishes prebuilt binaries for each
# one. So we download those exact versions and assemble the same EFI tree.
#
# Run it on any Linux box -- the Proxmox host itself is the obvious choice, since that is where the
# image has to end up anyway.
#
#   apt install -y curl unzip gdisk mtools
#   ./build-image-nomac.sh
#
# Produces OpenCore-master.img (a raw GPT disk image, not a real ISO -- same as upstream releases).
# No root required: mtools writes the FAT32 filesystem without mounting anything.
#
# Versions below are read off `git submodule status` at master after the PR #84 merge. If you bump a
# submodule, bump the matching version here.

set -euo pipefail

OPENCORE_VER=1.0.5
LILU_VER=1.7.1
WHATEVERGREEN_VER=1.7.0
APPLEALC_VER=1.9.5
VIRTUALSMC_VER=1.3.7
BRCMPATCHRAM_VER=2.7.1
CRYPTEXFIXUP_VER=1.0.5
OCBINARYDATA_SHA=af09b0bf763363ec9f4ecdbbe2f0adeb970948d8

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$REPO_DIR/build-nomac}"
RELEASE_VERSION="${RELEASE_VERSION:-master}"
OUT="${OUT:-$REPO_DIR/OpenCore-$RELEASE_VERSION.img}"

# 150 MiB image, partition starts at sector 2048 (1 MiB), leaving room for the backup GPT.
IMG_SIZE_MIB=150
PART_START_SECTOR=2048
PART_SIZE_MIB=148

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

for cmd in curl unzip sgdisk mformat mcopy truncate dd; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing '$cmd' -- apt install -y curl unzip gdisk mtools"
done

[ -f "$REPO_DIR/EFI/OC/config.plist" ] || die "run this from inside the repo (EFI/OC/config.plist not found)"

DL="$WORK/downloads"
EFI="$WORK/EFI"
rm -rf "$EFI"
mkdir -p "$DL" "$EFI/BOOT" "$EFI/OC/Drivers" "$EFI/OC/Tools" "$EFI/OC/Kexts" "$EFI/OC/ACPI"

fetch() { # url dest
    # -s (not -f) so a zero-byte leftover from an interrupted run is not treated as cached.
    [ -s "$2" ] && { info "cached $(basename "$2")"; return; }
    info "downloading $(basename "$2")"
    # GitHub's release CDN throws transient 503s, so retry. Download to .part and only
    # rename on success, otherwise a truncated file would be picked up as "cached" next run
    # and fail later with a confusing unzip error.
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 15 \
        -o "$2.part" "$1" || die "download failed after retries: $1"
    mv -f "$2.part" "$2"
}

unpack() { # name zipfile
    local d="$DL/$1"
    rm -rf "$d"; mkdir -p "$d"
    unzip -q "$2" -d "$d"
    echo "$d"
}

# Locate a .kext anywhere inside an unpacked release (layouts differ: VirtualSMC nests under Kexts/).
copy_kext() { # unpacked_dir kextname
    local found
    found="$(find "$1" -maxdepth 4 -type d -name "$2" -print -quit)"
    [ -n "$found" ] || die "$2 not found in $1"
    cp -a "$found" "$EFI/OC/Kexts/"
}

# ---------------------------------------------------------------- OpenCore itself

fetch "https://github.com/acidanthera/OpenCorePkg/releases/download/$OPENCORE_VER/OpenCore-$OPENCORE_VER-RELEASE.zip" "$DL/opencore.zip"
OC="$(unpack opencore "$DL/opencore.zip")/X64/EFI"

cp -a "$OC/BOOT/BOOTx64.efi" "$EFI/BOOT/"
cp -a "$OC/OC/OpenCore.efi"  "$EFI/OC/"

# Only the drivers our config.plist actually lists (UEFI/Drivers).
for drv in OpenRuntime.efi OpenHfsPlus.efi OpenCanopy.efi OpenPartitionDxe.efi ResetNvramEntry.efi ToggleSipEntry.efi; do
    cp -a "$OC/OC/Drivers/$drv" "$EFI/OC/Drivers/"
done

# Tools (Misc/Tools). NOTE: the release zip ships the UEFI shell as OpenShell.efi, but the Makefile
# and our config.plist both call it Shell.efi -- rename it or the Shell entry fails to launch.
cp -a "$OC/OC/Tools/ResetSystem.efi" "$EFI/OC/Tools/"
cp -a "$OC/OC/Tools/OpenShell.efi"   "$EFI/OC/Tools/Shell.efi"

# ---------------------------------------------------------------- Kexts

fetch "https://github.com/acidanthera/Lilu/releases/download/$LILU_VER/Lilu-$LILU_VER-RELEASE.zip" "$DL/lilu.zip"
copy_kext "$(unpack lilu "$DL/lilu.zip")" Lilu.kext

fetch "https://github.com/acidanthera/WhateverGreen/releases/download/$WHATEVERGREEN_VER/WhateverGreen-$WHATEVERGREEN_VER-RELEASE.zip" "$DL/wg.zip"
copy_kext "$(unpack wg "$DL/wg.zip")" WhateverGreen.kext

fetch "https://github.com/acidanthera/AppleALC/releases/download/$APPLEALC_VER/AppleALC-$APPLEALC_VER-RELEASE.zip" "$DL/alc.zip"
copy_kext "$(unpack alc "$DL/alc.zip")" AppleALC.kext

# Disabled in config.plist (QEMU's isa-applesmc provides the SMC) but shipped by the Makefile too.
fetch "https://github.com/acidanthera/VirtualSMC/releases/download/$VIRTUALSMC_VER/VirtualSMC-$VIRTUALSMC_VER-RELEASE.zip" "$DL/vsmc.zip"
copy_kext "$(unpack vsmc "$DL/vsmc.zip")" VirtualSMC.kext

fetch "https://github.com/acidanthera/BrcmPatchRAM/releases/download/$BRCMPATCHRAM_VER/BrcmPatchRAM-$BRCMPATCHRAM_VER-RELEASE.zip" "$DL/brcm.zip"
BRCM="$(unpack brcm "$DL/brcm.zip")"
for k in BrcmFirmwareData.kext BrcmNonPatchRAM2.kext BrcmPatchRAM2.kext BrcmPatchRAM3.kext BrcmBluetoothInjector.kext BlueToolFixup.kext; do
    copy_kext "$BRCM" "$k"
done

fetch "https://github.com/acidanthera/CryptexFixup/releases/download/$CRYPTEXFIXUP_VER/CryptexFixup-$CRYPTEXFIXUP_VER-RELEASE.zip" "$DL/cryptex.zip"
copy_kext "$(unpack cryptex "$DL/cryptex.zip")" CryptexFixup.kext

# Codeless kexts that live in this repo (no binaries to build).
for k in AGPMInjector.kext MCEReporterDisabler.kext USBPorts.kext; do
    [ -d "$REPO_DIR/EFI/OC/Kexts/$k" ] || die "$k missing from the repo"
    cp -a "$REPO_DIR/EFI/OC/Kexts/$k" "$EFI/OC/Kexts/"
done

# ---------------------------------------------------------------- Resources, ACPI, config

fetch "https://github.com/acidanthera/OcBinaryData/archive/$OCBINARYDATA_SHA.tar.gz" "$DL/ocbinarydata.tar.gz"
info "extracting OcBinaryData Resources"
rm -rf "$DL/ocbd"; mkdir -p "$DL/ocbd"
tar -xzf "$DL/ocbinarydata.tar.gz" -C "$DL/ocbd" --strip-components=1
cp -a "$DL/ocbd/Resources" "$EFI/OC/"

cp -a "$REPO_DIR"/EFI/OC/ACPI/*.aml "$EFI/OC/ACPI/"
cp -a "$REPO_DIR/EFI/OC/config.plist" "$EFI/OC/"

find "$EFI" -name .DS_Store -delete 2>/dev/null || true

# ---------------------------------------------------------------- Build the disk image

info "building $OUT"
PART_IMG="$WORK/part.img"
rm -f "$PART_IMG" "$OUT"

# FAT32 filesystem, volume label EFI, written straight into a file -- no mounting, no root.
mformat -C -F -v EFI -T $((PART_SIZE_MIB * 1024 * 1024 / 512)) -i "$PART_IMG" ::
mcopy -s -i "$PART_IMG" "$EFI" ::

# GPT container with a single EFI System Partition, matching hdiutil's GPTSPUD/EFI layout.
truncate -s "${IMG_SIZE_MIB}M" "$OUT"
sgdisk -o -n "1:$PART_START_SECTOR:+${PART_SIZE_MIB}M" -t 1:EF00 -c 1:EFI "$OUT" >/dev/null
dd if="$PART_IMG" of="$OUT" bs=512 seek="$PART_START_SECTOR" conv=notrunc status=none

info "done: $OUT"
echo
echo "Contents:"
# Non-recursive: a full -/ listing is ~660 lines, almost all of it OcBinaryData Resources.
mdir -i "$PART_IMG" ::/EFI/OC ::/EFI/OC/Kexts ::/EFI/OC/Drivers ::/EFI/OC/Tools ::/EFI/OC/ACPI || true
echo
echo "Next: copy it to the Proxmox ISO store, e.g."
echo "  cp \"$OUT\" /var/lib/vz/template/iso/"

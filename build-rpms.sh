#!/usr/bin/env bash
# Build the matched kernel RPM set and stop.
#
# Install the result on a running tablet: the boot subpackage's %posttrans runs
# uke-kernel-update, which writes boot_a in one guarded transaction.  No rootfs
# and no boot image are built, so this is the fastest way to deliver a kernel
# change and the only one that does not need fastboot.
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd -- "$here/.." && pwd)
release=${FEDORA_RELEASE:-44}

# Option defaults, set before the argument loop and before build-common.sh is
# sourced, because that file deliberately does not reset them.
stock=''
output=''
rebuild_kernel=0
cross_kernel=0
resume=0
control=''
touch_panel=auto

usage() {
    cat <<'HELP'
Usage: ./uke-fedora-builder/build-rpms.sh [--output DIR]
       [--rebuild-kernel] [--cross-kernel] [--resume]
       ./uke-fedora-builder/build-rpms.sh --status|--stop --output DIR

Build only the matched kernel RPM set: core, modules, dtbs and boot, plus a
SHA256SUMS.  Copy them to a running tablet and:

    sudo dnf install ./*.rpm

The boot subpackage's %posttrans runs uke-kernel-update, which writes boot_a in
one guarded transaction, so nothing has to be flashed.

On x86_64, --cross-kernel compiles the ARM64 kernel with native Clang.
The output directory holds kernel-rpms/ and the build log.
HELP
}

source "$here/src/image/build-common.sh"

while (($#)); do
    case $1 in
        --output) (($# >= 2)) || die 'Missing value for --output'; output=$2; shift 2;;
        -h|--help) usage; exit 0;;
        --rebuild-kernel) rebuild_kernel=1; shift;;
        --cross-kernel) cross_kernel=1; shift;;
        --resume) resume=1; shift;;
        --status|--stop) [[ -z $control ]] || die 'Choose one control command'; control=$1; shift;;
        *) die "Unknown argument: $1";;
    esac
done

source "$here/src/image/package-lock.sh"
build_common_defaults
source "$here/src/image/build-control.sh"
if [[ $control == --status ]]; then build_status; exit; fi
if [[ $control == --stop ]]; then build_stop; exit; fi

build_common_host_checks
if ((cross_kernel)); then
    [[ $(uname -m) == x86_64 ]] || die '--cross-kernel requires an x86_64 host'
fi
build_common_prepare_output

build_common_start 'Kernel RPM set only; no rootfs and no boot image are built.'
build_common_stock_boot
build_kernel_rpms "$output/kernel-rpms"

printf 'Kernel RPMs: %s\n' "$output/kernel-rpms"
printf 'Install with: sudo dnf install %s/*.rpm\n' "$output/kernel-rpms"

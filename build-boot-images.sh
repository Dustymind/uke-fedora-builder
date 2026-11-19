#!/usr/bin/env bash
# Build fedora_boot.img per profile and stop.
#
# boot_a carries the kernel Image and its initramfs, both already in the
# prepared kernel output, so a rootfs contributes nothing to it - the rootfs
# only supplied the userdata image that travels beside it.  Skipping it turns a
# kernel-only change into a five-minute build instead of a full image pair.
#
# Use this when the kernel release stays the same, so the installed userdata is
# still valid and flashing boot_a alone is enough.  A release change needs
# build-images.sh, because the modules in userdata are built for one vermagic.
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd -- "$here/.." && pwd)
release=${FEDORA_RELEASE:-44}

stock=''
output=''
rebuild_kernel=0
cross_kernel=0
resume=0
control=''
touch_panel=auto

usage() {
    cat <<'HELP'
Usage: ./uke-fedora-builder/build-boot-images.sh [--output DIR] [--profiles LIST]
       [--stock-boot FILE] [--touch-panel auto]
       [--rebuild-kernel] [--cross-kernel] [--resume]
       ./uke-fedora-builder/build-boot-images.sh --status|--stop --output DIR

Build only fedora_boot.img for each requested profile.  LIST is all (the
default) or a comma-separated subset of tty,kde,gnome,phosh,plasma-mobile.

No rootfs is built and no userdata.img is produced, so the output is a boot
image per profile plus its manifest.  Flash boot_a; the installed userdata
partition is left alone.  Check that the kernel release is unchanged before
doing so - a new release needs build-images.sh.

On x86_64, --cross-kernel compiles the ARM64 kernel with native Clang.
HELP
}

source "$here/src/image/build-common.sh"

canonical_profiles=(tty kde gnome phosh plasma-mobile)
profiles_arg=all
profiles_seen=0
parallel_profiles=1

while (($#)); do
    case $1 in
        --output|--profiles|--stock-boot|--touch-panel|--parallel)
            (($# >= 2)) || die "Missing value for $1"
            case $1 in
                --output) output=$2;;
                --profiles) ((profiles_seen == 0)) || die 'Specify --profiles once'
                            profiles_seen=1; profiles_arg=$2;;
                --stock-boot) stock=$2;;
                --touch-panel) touch_panel=$2;;
                --parallel) parallel_profiles=$2;;
            esac
            shift 2;;
        -h|--help) usage; exit 0;;
        --rebuild-kernel) rebuild_kernel=1; shift;;
        --cross-kernel) cross_kernel=1; shift;;
        --resume) resume=1; shift;;
        --status|--stop) [[ -z $control ]] || die 'Choose one control command'; control=$1; shift;;
        *) die "Unknown argument: $1";;
    esac
done

[[ $touch_panel == auto ]] || die 'Touch selection is automatic; omit --touch-panel'
[[ $parallel_profiles =~ ^[1-8]$ ]] || die '--parallel must be between 1 and 8'

declare -A seen_profiles=()
if [[ $profiles_arg != all ]]; then
    [[ $profiles_arg =~ ^(tty|kde|gnome|phosh|plasma-mobile)(,(tty|kde|gnome|phosh|plasma-mobile))*$ ]] \
        || die 'Invalid --profiles list'
    IFS=, read -r -a requested_profiles <<< "$profiles_arg"
else
    requested_profiles=("${canonical_profiles[@]}")
fi
for profile in "${requested_profiles[@]}"; do
    [[ ! ${seen_profiles[$profile]+present} ]] || die "Duplicate profile: $profile"
    seen_profiles[$profile]=1
done
build_profiles=()
for profile in "${canonical_profiles[@]}"; do
    if [[ $profile == tty || ${seen_profiles[$profile]+present} ]]; then
        build_profiles+=("$profile")
    fi
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

kernel_epoch=$(jq -er .source_date_epoch \
    "$workspace/senemos-uke-kernel/manifests/linux-${uke_kernel_version}.json")
[[ $kernel_epoch =~ ^[0-9]+$ ]] || die 'Invalid kernel source date epoch'

build_common_start 'Boot image only; no rootfs and no userdata image are built.'
build_common_stock_boot

kernel_rpms=$output/kernel-rpms
build_kernel_rpms "$kernel_rpms"
kernel_top=$BUILD_KERNEL_TOP
kernel_out=$BUILD_KERNEL_OUT

guard=$(find "$kernel_top/BUILD" -type f \
  -path "*/linux-${uke_kernel_version}/boot-recipe/src/boot/dracut/root-guard.sh" -print -quit)
[[ -n $guard ]] || die 'Prepared kernel source was not found'
kernel_source=${guard%/boot-recipe/src/boot/dracut/root-guard.sh}

out_of_date() {
    # A boot-only image is only useful while the installed userdata matches its
    # release.  Refuse to hand one out silently when the prepared kernel is a
    # different release than the package lock says the images carry.
    local release_in_image
    release_in_image=$(sed -n 's/^kernel_release=//p' "$kernel_out/boot-manifest")
    [[ -n $release_in_image ]] || die 'Prepared kernel output has no boot manifest'
    [[ $release_in_image == "$uke_kernel_krel" ]] || die \
        "Prepared kernel release $release_in_image differs from the package lock $uke_kernel_krel"
}

build_boot_image() {
    local profile=$1 pair_dir=$output/$1-pair stage
    printf 'Building %s boot image\n' "$profile"
    clear_profile_dir "$pair_dir"
    stage=$output/.$profile-pair.$UKE_BUILD_RUN_ID
    clear_profile_dir "$stage"
    "$here/build-boot-a.sh" \
        --profile-id "$profile" --touch-panel "$touch_panel" \
        --kernel-source "$kernel_source" \
        --kernel-out "$kernel_out" --stock-boot "$stock" \
        --output "$stage"
    (cd "$stage"; sha256sum -c --status SHA256SUMS) \
        || die "Incomplete $profile boot image"
    mv -- "$stage" "$pair_dir"
}

# clear_profile_dir mirrors the pair orchestrator's safety checks: only a known
# profile directory name under $output, never a symlink, and removal goes
# through a throwaway container so a permission change cannot strand a file.
clear_profile_dir() {
    local path=$1 name=${1##*/}
    [[ $path == "$output/$name" ]] || die "Unsafe profile path: $path"
    [[ $name =~ ^\.(tty|kde|gnome|phosh|plasma-mobile)-pair\.[0-9a-f-]+$ || \
       $name =~ ^(tty|kde|gnome|phosh|plasma-mobile)-pair$ ]] \
        || die "Unsafe profile path: $path"
    [[ ! -L $path ]] || die "Refusing symlink: $path"
    [[ -e $path ]] || return 0
    "$container" run --rm --network=none --security-opt label=disable \
        --label "org.uke-fedora.build-run=$UKE_BUILD_RUN_ID" \
        -v "$output:/build-output" registry.fedoraproject.org/fedora:44 \
        /usr/bin/rm -rf -- "/build-output/$name"
    [[ ! -e $path ]] || die "Could not clear $path"
}

for stale in "$output"/.*-pair.*; do
    [[ -e $stale ]] || continue
    clear_profile_dir "$stale"
done

out_of_date
for profile in "${build_profiles[@]}"; do
    build_boot_image "$profile"
done

printf 'Boot images: %s\n' "${build_profiles[*]}"
printf 'Output: %s\n' "$output"

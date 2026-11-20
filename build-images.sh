#!/usr/bin/env bash
# Build the selected Fedora Xiaomi Pad 7 image pairs from one source checkout.
# FEDORA_RELEASE selects the target Fedora release (default 44).
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd -- "$here/.." && pwd)
release=${FEDORA_RELEASE:-44}
[[ $release =~ ^[0-9]+$ ]] || { printf 'Invalid FEDORA_RELEASE: %s\n' "$release" >&2; exit 1; }
stock=''
stock_archive=$here/payload/uke-os3.0.304.0-boot.zst
rebuild_kernel=0
cross_kernel=0
resume=0
control=''
profiles_arg=all
profiles_seen=0
parallel_profiles=1
touch_panel=auto

usage() {
    cat <<'HELP'
Usage: ./uke-fedora-builder/build-images.sh [--stock-boot FILE] [--output DIR]
       [--profiles LIST] [--touch-panel auto]
       [--rebuild-kernel] [--cross-kernel] [--resume]
       ./uke-fedora-builder/build-images.sh --status|--stop --output DIR
       ./uke-fedora-builder/build-images.sh --audit-only --profiles LIST --output DIR

Build Linux 7.3.1 and Fedora 44 RPMs, then make separate TTY, KDE, GNOME,
Phosh and Plasma Mobile boot_a/userdata pairs. LIST is all (the default) or
a comma-separated subset of tty,kde,gnome,phosh,plasma-mobile. Desktop profiles
also build the TTY rootfs and boot pair as shared prerequisites. Bundled OEM
inputs, including the reviewed stock boot template, are verified automatically.
Each rootfs contains both pinned touch pairs; GPIO26 selects TM or CSOT at
startup before firmware loading. CSOT still needs a physical tablet test.
The stock panel selector uses native DPU/DSI with seven fixed OEM modes on
O82-36. Keep a previously tested boot image for recovery while testing rates.
The script does not flash or select a device slot. A matching kernel RPM build is
reused unless --rebuild-kernel is given.
On x86_64, --cross-kernel compiles the ARM64 kernel with native Clang.
Set UKE_COPR=0 to omit the optional COPR repository from the images; forks can disable it.
Use --parallel N to build up to N desktop profiles at once; --status for concise progress, --stop to cancel, and --resume to reuse
completed artifacts from an interrupted run. --audit-only rechecks completed
image pairs or finishes a run that stopped at the final audit.
HELP
}
die() { printf 'build-images: %s\n' "$*" >&2; exit 1; }

while (($#)); do
    case $1 in
        --stock-boot|--output|--profiles|--parallel|--touch-panel)
            (($# >= 2)) || die "Missing value for $1"
            case $1 in --stock-boot) stock=$2;; --output) output=$2;; --profiles) ((profiles_seen == 0)) || die 'Specify --profiles once'; profiles_seen=1; profiles_arg=$2;; --parallel) parallel_profiles=$2;; --touch-panel) touch_panel=$2;; esac
            shift 2;;
        -h|--help) usage; exit 0;;
        --rebuild-kernel) rebuild_kernel=1; shift;;
        --cross-kernel) cross_kernel=1; shift;;
        --resume) resume=1; shift;;
        --status|--stop|--audit-only) [[ -z $control ]] || die 'Choose one control command'; control=$1; shift;;
        *) die "Unknown argument: $1";;
    esac
done
[[ $touch_panel == auto ]] || die 'Touch selection is automatic; omit --touch-panel'
[[ $parallel_profiles =~ ^[1-8]$ ]] || die '--parallel must be between 1 and 8'
canonical_profiles=(tty kde gnome phosh plasma-mobile)
declare -A seen_profiles=()
if [[ $profiles_arg != all ]]; then
    [[ $profiles_arg =~ ^(tty|kde|gnome|phosh|plasma-mobile)(,(tty|kde|gnome|phosh|plasma-mobile))*$ ]] || die 'Invalid --profiles list'
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
source "$here/src/image/build-kernel-rpms.sh"
source "$here/src/image/build-common.sh"
source "$here/src/image/build-control.sh"
if [[ $control == --status ]]; then build_status; exit; fi
if [[ $control == --stop ]]; then build_stop; exit; fi

profile_valid() {
    local path=$1 profile=$2
    [[ -d $path && ! -L $path && -s $path/SHA256SUMS && -s $path/BUILD-INPUTS.sha256 ]] || return 1
    [[ $(cat "$path/PROFILE-ID" 2>/dev/null) == "$profile" ]] || return 1
    [[ $(cat "$path/BUILD-INPUTS.sha256") == "$input_hash" ]] || return 1
    (cd "$path" && sha256sum -c --status SHA256SUMS) || return 1
    if [[ -d $path/root ]]; then
        bash "$here/src/image/audit-rootfs.sh" "$path" || return 1
    fi
}
audit_final() {
    : > "$output/audit-report.txt"
    for profile in "${build_profiles[@]}"; do
        profile_valid "$output/$profile-rootfs" "$profile" || die "Invalid $profile rootfs"
        profile_valid "$output/$profile-pair" "$profile" || die "Invalid $profile image pair"
        if grep -Eq 'CONFIG_CMDLINE=".*[[:space:]]systemd\.unit=' "$output/$profile-pair/boot.config"; then
            die "Forced systemd target in $profile boot image"
        fi
        for receipt in NATIVE-O82-36 NATIVE-O82-36-RATES NATIVE-O82-36-ALL-RATES; do
            [[ $(cat "$output/$profile-pair/$receipt") == 1 ]] || die "Incorrect $profile $receipt receipt"
        done
        jq -e '.experimental_native_o82_36 and .experimental_native_o82_36_rates and
               .experimental_native_o82_36_all_rates' \
            "$output/$profile-pair/manifest.json" >/dev/null || die "Incorrect $profile native display manifest"
        if grep -Eq 'uke\.native_o82_36(_rates)?=' "$output/$profile-pair/boot.config"; then
            die "Obsolete O82-36 boot selector in $profile image"
        fi
        expected_target=graphical.target
        [[ $profile != tty ]] || expected_target=multi-user.target
        [[ $(readlink "$output/$profile-rootfs/root/etc/systemd/system/default.target") == "/usr/lib/systemd/system/$expected_target" ]] \
            || die "Incorrect default.target in $profile rootfs"
        printf 'PASS %s: rootfs and image pair checksums, critical files, OEM firmware\n' "$profile" \
            >> "$output/audit-report.txt"
    done
    python3 "$here/src/image/audit-build-log.py" "$output/build.log" "$UKE_BUILD_RUN_ID" \
        | tee -a "$output/audit-report.txt" \
        || die 'A package scriptlet failed during the build'
}
if [[ $control == --audit-only ]]; then
    [[ $profiles_seen == 1 && -d $output && ! -L $output && -s $output/BUILD-INPUTS.sha256 ]] \
        || die '--audit-only requires the original --profiles list and output directory'
    exec 9>"$output/.build.lock"
    flock -n 9 || die 'Build already active'
    # The run has to be one that actually got through its profiles.  A previous
    # version compared a stage count here, which meant the audit could only run
    # when the count, the plan and the stored total all still agreed - the same
    # coupling that turned a finished build into "failed: 13/12".  What the
    # audit really needs is the pair directories, and it revalidates them below.
    UKE_BUILD_RUN_ID=$(jq -er .run_id "$output/status.json")
    input_hash=$(cat "$output/BUILD-INPUTS.sha256")
    for profile in "${build_profiles[@]}"; do
        [[ -d $output/$profile-pair ]] \
            || die "--audit-only: $profile has no image pair to audit"
    done
    audit_final
    status_stage=$(mktemp "$output/.status.XXXXXXXX")
    jq --argjson updated "$(date +%s)" \
        '.state="complete" | .stage="Audit release outputs" | .updated_unix=$updated' \
        "$output/status.json" > "$status_stage"
    chmod 0666 "$status_stage"
    mv -f -- "$status_stage" "$output/status.json"
    printf 'complete: audited %s\n' "${build_profiles[*]}" \
        | tee -a "$output/progress.log"
    exit
fi
source "$here/src/image/package-lock.sh"
kernel_epoch=$(jq -er .source_date_epoch \
    "$workspace/senemos-uke-kernel/manifests/linux-${uke_kernel_version}.json")
[[ $kernel_epoch =~ ^[0-9]+$ ]] || die 'Invalid kernel source date epoch'
[[ -x $here/build-rootfs.sh && -x $here/build-boot-a.sh ]] || die 'Image builders are missing'
build_common_defaults
build_common_host_checks
if ((cross_kernel)); then
    [[ $(uname -m) == x86_64 ]] || die '--cross-kernel requires an x86_64 host'
fi
build_common_prepare_output

build_common_start 'Fedora image pairs: rootfs, boot_a and userdata per profile.'
build_common_stock_boot

# The kernel compile, its RPM recipes and the subpackage staging all live in
# src/image/build-kernel-rpms.sh, shared with build-rpms.sh and
# build-boot-images.sh.  Only the consumers below differ per orchestrator.
kernel_rpms=$output/kernel-rpms
build_kernel_rpms "$kernel_rpms"
kernel_top=$BUILD_KERNEL_TOP
kernel_out=$BUILD_KERNEL_OUT
if [[ -s $kernel_out/cross-source.sha256 ]]; then
    amd_image=${amd_image:-$("$here/src/image/ensure-build-image.sh" "$container" linux/amd64)}
fi
# build_kernel_rpms keeps its copy local, so resolve the AArch64 tool image
# here as well; the helper caches the image and only inspects it.
arm_image=$(bash "$here/src/image/ensure-build-image.sh" "$container" linux/arm64)
arm_image_id=$("$container" image inspect "$arm_image" --format '{{.Id}}')
amd_image_id=none
[[ -z ${amd_image:-} ]] || amd_image_id=$("$container" image inspect "$amd_image" --format '{{.Id}}')
native_image=$(bash "$here/src/image/ensure-hwdb-image.sh" "$container")
native_image_id=$("$container" image inspect "$native_image" --format '{{.Id}}')
guard=$(find "$kernel_top/BUILD" -type f \
  -path "*/linux-${uke_kernel_version}/boot-recipe/src/boot/dracut/root-guard.sh" -print -quit)
[[ -n $guard ]] || die 'Prepared kernel source was not found'
kernel_source=${guard%/boot-recipe/src/boot/dracut/root-guard.sh}
core_rpm=$workspace/uke-linux-hardware-support/uke-core-meta/build/srpm/rpmbuild/RPMS/aarch64/uke-core-meta-1.0.4-1.fc44.aarch64.rpm
hardware_rpms=$output/hardware-rpms
mkdir -p "$hardware_rpms"
find "$hardware_rpms" -maxdepth 1 -type f -name '*.rpm' -delete
# The keyboard package has no component repository of its own: its sources are
# configs/nanosic, so it is built here rather than copied from a build tree.
bash "$here/src/image/build-keyboard-rpm.sh" \
    --output "$hardware_rpms" --release "$release" --image "$arm_image" >/dev/null
cp "$workspace"/uke-linux-hardware-support/uke-sensors/build/rpmbuild/RPMS/aarch64/uke-touchscreen-0.1.0-18.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-console-input/build/rpmbuild/RPMS/aarch64/uke-console-input-3.6.0-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-platform-runtime/build/rpmbuild/RPMS/aarch64/uke-battery-observer-1.1.0-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace/uke-linux-hardware-support/uke-boot/build/srpm/rpmbuild/RPMS/aarch64/uke-boot-integration-$uke_boot_rpm_release.aarch64.rpm" "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-sensors/build/srpm/libssc/rpmbuild/RPMS/aarch64/libssc-0.4.4-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-sensors/build/srpm/iio-sensor-proxy/rpmbuild/RPMS/aarch64/iio-sensor-proxy-3.9-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-sensors/build/srpm/uke-ssc-fileservice/rpmbuild/RPMS/aarch64/uke-ssc-fileservice-2026.09.21-*.fc44.aarch64.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/xiaomi-uke-firmware/build/fedora${release}-image-data/rpmbuild/RPMS/noarch/uke-fedora${release}-oem-data-3.0.304.0-2.fc${release}.noarch.rpm "$hardware_rpms/"
cp "$workspace"/uke-linux-hardware-support/uke-video/build/srpm/RPMS/aarch64/uke-vaapi-v4l2-*.fc${release}.aarch64.rpm "$hardware_rpms/"

blobs=$workspace/uke-linux-hardware-support/xiaomi-uke-firmware/payload/oem-os3.0.304.0
input_hash=$(
  {
    printf '%s\n' "${UKE_FEDORA_MIRROR:-https://mirror.yandex.ru/fedora/linux}"
    printf '%s\n' "$arm_image_id" "$amd_image_id" "$native_image_id" "$touch_panel"
    sha256sum "$stock" "$kernel_out/.config" "$kernel_out/boot-initramfs.cpio.gz" \
        "$kernel_out/boot-manifest" "$kernel_out/arch/arm64/boot/Image" \
        "$here/build-rootfs.sh" "$here/build-boot-a.sh" \
        "$here/src/image/ensure-hwdb-image.sh" \
        "$here/src/image/finalize-rootfs.sh" \
        "$here/src/image/ensure-build-image.sh" \
        "$here/src/image/prepare-tool-image.sh" \
        "$lock_file" \
        "$here/src/image/assemble-pair-from-tty.sh" \
        "$here/src/image/ext4-labels.cpp" "$here/src/boot-pair/android-sparse.cpp" \
        "$here/src/boot/boot-image.cpp" "$here/configs/firstboot/uke-create-user" \
        "$here/src/image/build-keyboard-rpm.sh" \
        "$here/packaging/uke-keyboard-support.spec" \
        "$here/configs/firstboot/uke-create-user.service" \
        "$here/configs/images/uke-persist.fstab" "$here/configs/images/uke-ssc-fedora44.target" \
        "$here/configs/images/uke-zram-generator.conf" \
        "$blobs/touch/tm/normal.bin" "$blobs/touch/tm/config.ini" \
        "$blobs/touch/csot/normal.bin" "$blobs/touch/csot/config.ini" \
        "$blobs/touch/reference.bin" "$core_rpm" "$kernel_rpms"/*.rpm "$hardware_rpms"/*.rpm | \
        awk '{print $1}'
    # The overlay assets are not packages, so nothing else would notice a change
    # to them, and --resume would hand back a rootfs built from the old bytes.
    find "$here/configs/rootfs" "$here/configs/rootfs-copr" -type f -print0 | \
        LC_ALL=C sort -z | xargs -0 -r sha256sum | awk '{print $1}'
  } | sha256sum | cut -d' ' -f1
)
reuse_profiles=$resume
printf '%s\n' "$input_hash" > "$output/BUILD-INPUTS.sha256"
append_build_receipt() {
    local stage=$1 checksum_file
    [[ -d $stage && ! -L $stage && -f $stage/SHA256SUMS && ! -L $stage/SHA256SUMS ]] || die "Invalid profile stage: $stage"
    (cd "$stage" && sha256sum -c --status SHA256SUMS) || die "Invalid checksums in $stage"
    printf '%s\n' "$input_hash" > "$stage/BUILD-INPUTS.sha256"
    checksum_file=$(mktemp "$stage/.SHA256SUMS.XXXXXXXX")
    (cd "$stage" && awk '$2 != "BUILD-INPUTS.sha256"' SHA256SUMS > "$checksum_file" && \
        sha256sum BUILD-INPUTS.sha256 >> "$checksum_file")
    chmod 0644 "$checksum_file"
    mv -f -- "$checksum_file" "$stage/SHA256SUMS"
}
clear_profile_dir() {
    local path=$1 name=${1##*/}
    [[ $path == "$output/$name" && $name =~ ^\.(tty|kde|gnome|phosh|plasma-mobile)-(rootfs|pair)\.[0-9a-f-]+$ || \
       $path == "$output/$name" && $name =~ ^(tty|kde|gnome|phosh|plasma-mobile)-(rootfs|pair)$ ]] \
        || die "Unsafe profile path: $path"
    [[ ! -L $path ]] || die "Refusing symlink: $path"
    [[ -e $path ]] || return 0
    "$container" run --rm --network=none --security-opt label=disable \
        --label "org.uke-fedora.build-run=$UKE_BUILD_RUN_ID" \
        -v "$output:/build-output" registry.fedoraproject.org/fedora:44 \
        /usr/bin/rm -rf -- "/build-output/$name"
    [[ ! -e $path ]] || die "Could not clear $path"
}
for stale in "$output"/.*-rootfs.* "$output"/.*-pair.*; do
    [[ -e $stale ]] || continue
    clear_profile_dir "$stale"
done
build_profile() {
    local profile=$1 root_mib root_dir pair_dir stage root_reused
    local base_args=()
    root_mib=4096
    [[ $profile == tty ]] || root_mib=8192
    root_dir=$output/$profile-rootfs
    pair_dir=$output/$profile-pair
    build_progress "$profile rootfs"
    root_reused=0
    if ((reuse_profiles)) && profile_valid "$root_dir" "$profile" && \
       [[ $(cat "$root_dir/ROOT-MIB") == "$root_mib" ]]; then
        root_reused=1
        printf 'Reusing verified %s rootfs\n' "$profile"
    else
        clear_profile_dir "$root_dir"
        stage=$output/.$profile-rootfs.$UKE_BUILD_RUN_ID
        clear_profile_dir "$stage"
        base_args=()
        [[ $profile == tty ]] || base_args=(--base-rootfs "$output/tty-rootfs")
        "$here/build-rootfs.sh" \
            --profile "$profile" --kernel-rpms "$kernel_rpms" \
            --core-rpm "$core_rpm" --hardware-rpms "$hardware_rpms" \
            --root-mib "$root_mib" --touch-panel "$touch_panel" "${base_args[@]}" --output "$stage"
        append_build_receipt "$stage"
        profile_valid "$stage" "$profile" || die "Incomplete $profile rootfs"
        mv -- "$stage" "$root_dir"
    fi
    build_progress "$profile boot pair"
    if ((root_reused && reuse_profiles)) && profile_valid "$pair_dir" "$profile"; then
        printf 'Reusing verified %s boot pair\n' "$profile"
    else
        clear_profile_dir "$pair_dir"
        stage=$output/.$profile-pair.$UKE_BUILD_RUN_ID
        clear_profile_dir "$stage"
        if [[ $profile == tty ]]; then
            "$here/build-boot-a.sh" \
                --rootfs "$root_dir" --kernel-source "$kernel_source" \
                --kernel-out "$kernel_out" --stock-boot "$stock" \
                --output "$stage"
        else
            "$here/src/image/assemble-pair-from-tty.sh" "$output/tty-pair" "$root_dir" "$stage"
        fi
        append_build_receipt "$stage"
        profile_valid "$stage" "$profile" || die "Incomplete $profile pair"
        mv -- "$stage" "$pair_dir"
    fi
}

tty_profiles=()
desktop_profiles=()
for profile in "${build_profiles[@]}"; do
    if [[ $profile == tty ]]; then tty_profiles+=("$profile"); else desktop_profiles+=("$profile"); fi
done
for profile in "${tty_profiles[@]}"; do
    build_profile "$profile"
done
if ((parallel_profiles > 1)) && ((${#desktop_profiles[@]} > 0)); then
    pids=()
    for profile in "${desktop_profiles[@]}"; do
        ( UKE_DNF_CACHE_SUFFIX=$profile build_profile "$profile" ) \
            > "$output/$profile.build.log" 2>&1 &
        pids+=($!)
        while (( $(jobs -rp | wc -l) >= parallel_profiles )); do wait -n || true; done
    done
    failed=0
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
    ((failed == 0)) || die "Parallel profile build failed; see $output/*.build.log"
else
    for profile in "${desktop_profiles[@]}"; do
        build_profile "$profile"
    done
fi
build_progress 'Audit release outputs'
audit_final
printf 'Requested profiles: %s\n' "${requested_profiles[*]}"
printf 'Built or reused image pairs: %s\n' "${build_profiles[*]}"
printf 'O82-36 native display: seven fixed OEM modes by default\n'
printf 'Image pairs are in %s\n' "$output"

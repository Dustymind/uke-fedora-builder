#!/usr/bin/env bash
# Settings and helpers shared by the three image orchestrators.
#
# build-rpms.sh, build-boot-images.sh and build-images.sh differ only in what
# they do after the kernel RPMs exist.  Everything up to that point - release
# validation, container selection, sanitizer environment, the stock boot
# template, the build cache and the plan-driven start/finish wrapper - is the
# same, so it lives here once.
set -Eeuo pipefail

# $here, $workspace and $release are set by the orchestrator before sourcing
# this file; deriving them from BASH_SOURCE here would point at src/image/.
[[ -n ${here:-} && -n ${workspace:-} && -n ${release:-} ]] || {
    printf 'build-common.sh: source from an orchestrator, not directly\n' >&2
    exit 1
}

stock_archive=$here/payload/uke-os3.0.304.0-boot.zst
cache_dir=$here/build/cache

# Option variables are owned by each orchestrator and set before its argument
# loop, because this file is sourced after that loop: assigning defaults here
# would silently discard whatever the caller parsed.
#
#   stock, output, rebuild_kernel, cross_kernel, resume, control, touch_panel

build_common_die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }
die() { build_common_die "$*"; }

# build_common_defaults - set the defaults a caller did not pass in, and
# resolve the output path.  --status and --stop reach for it before
# build_common_prepare_output runs, so resolution cannot wait until then.
build_common_defaults() {
    [[ -n $output ]] || output=$workspace/build/fedora${release}-images
    output=$(realpath -m -- "$output")
}

# build_common_host_checks - host tools, OEM inputs and the container runtime.
build_common_host_checks() {
    [[ -x $workspace/uke-linux-hardware-support/xiaomi-uke-firmware/src/verify-oem-304.sh ]] \
        || die 'OEM input verifier is missing'
    "$workspace/uke-linux-hardware-support/xiaomi-uke-firmware/src/verify-oem-304.sh" \
        || die 'Bundled OS3.0.304.0 OEM inputs are incomplete'
    if [[ -n ${UKE_CONTAINER:-} ]]; then
        [[ $UKE_CONTAINER == docker || $UKE_CONTAINER == podman ]] \
            || die 'UKE_CONTAINER must be docker or podman'
        command -v "$UKE_CONTAINER" >/dev/null || die "Missing container runtime: $UKE_CONTAINER"
        container=$UKE_CONTAINER
    elif command -v podman >/dev/null; then container=podman
    elif command -v docker >/dev/null; then container=docker
    else die 'Docker or Podman is required'; fi
    # LeakSanitizer cannot inspect ARM64 test processes under user-mode
    # emulation.  Keep AddressSanitizer and UndefinedBehaviorSanitizer enabled.
    sanitizer_env=()
    [[ $(uname -m) == aarch64 ]] || sanitizer_env=(-e ASAN_OPTIONS=detect_leaks=0)
    local command
    for command in avbtool jq g++ python3 sha256sum zstd; do
        command -v "$command" >/dev/null || die "Missing host command: $command"
    done
}

# build_common_stock_boot - materialise the reviewed OEM boot template.
build_common_stock_boot() {
    if [[ -z $stock ]]; then
        [[ -f $stock_archive && ! -L $stock_archive ]] \
            || die 'Bundled OS3.0.304.0 stock boot template is missing'
        [[ $(sha256sum "$stock_archive" | cut -d' ' -f1) \
            == d001b8d7a15d088ae24fcb90d85023bd7af2360f8fdb72cf70f4e1b8c6085f1b ]] \
            || die 'Bundled stock boot archive hash mismatch'
        stock_dir=$(mktemp -d "$output/.stock.XXXXXXXX")
        stock=$stock_dir/boot.img
        zstd -q -dc "$stock_archive" > "$stock"
    fi
    [[ -f $stock && ! -L $stock ]] || die 'Stock boot.img is missing'
    [[ $(sha256sum "$stock" | cut -d' ' -f1) \
        == 1eaf4858a7c70bee9b663b485f3192b164738bbdae3edbb986a5419621c8ef30 ]] \
        || die 'Unexpected stock boot.img'
}

# build_common_prepare_output - create the output directory or reopen it.
build_common_prepare_output() {
    if ((resume)); then
        [[ -d $output && ! -L $output ]] || die '--resume requires an existing output directory'
    else
        [[ ! -e $output && ! -L $output ]] \
            || die 'Output directory already exists; use --resume or choose a new --output'
        mkdir -p "$output"
    fi
}

# build_common_start <description> - lock taken, log tee'd, banner printed.
build_common_start() {
    local description=$1
    build_start
    exec > >(tee -a "$output/build.log") 2>&1
    printf '===== UKE BUILD RUN %s =====\n' "$UKE_BUILD_RUN_ID"
    printf '%s\n' "$description"
}

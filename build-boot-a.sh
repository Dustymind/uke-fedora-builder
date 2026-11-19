#!/usr/bin/env bash
# Fedora 44 boot_a composition. This script never accesses a device.
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'build-boot-a: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: ./build-boot-a.sh [--rootfs DIR] --kernel-source DIR \
       --kernel-out DIR --stock-boot FILE --output NEW_DIR \
       [--profile-id ID --touch-panel PANEL]

Pack the kernel's verified userdata Image into an OEM-derived Android v4 boot_a
image with an unsigned AVB hash footer. Requires prepared Linux 7.3.1 RPM
source/output and a reviewed OEM boot.img. Does not write a device.

--rootfs is optional.  Without it the boot image is built on its own: no
userdata.img is copied beside it and the manifest records boot metadata only.
The rootfs was never an input to boot_a itself - it supplied the userdata image
of the pair and the profile/touch identifiers - so a kernel-only change can
produce just boot_a.  --profile-id and --touch-panel then supply the two
identifiers the manifest wants; without them the manifest records "unknown"
rather than guessing.

Build the pair (boot_a plus userdata) by passing --rootfs; build only boot_a by
omitting it.
HELP
}

rootfs='' source='' kernel_out='' stock='' output='' profile_id='' touch_panel=''
while (($#)); do
    case $1 in
        --rootfs|--kernel-source|--kernel-out|--stock-boot|--output|--profile-id|--touch-panel)
            (($# >= 2)) || die "Missing value for $1"
            case $1 in
                --rootfs) rootfs=$2;; --kernel-source) source=$2;; --kernel-out) kernel_out=$2;;
                --stock-boot) stock=$2;; --output) output=$2;;
                --profile-id) profile_id=$2;; --touch-panel) touch_panel=$2;;
            esac
            shift 2;;
        --help|-h) usage; exit 0;;
        *) die "Unknown argument: $1";;
    esac
done
[[ -d $source && -d $kernel_out && -f $stock && -n $output ]] || die 'Provide the kernel paths, the OEM boot and an output directory'
[[ -z $rootfs || -d $rootfs ]] || die "Rootfs directory does not exist: $rootfs"
if [[ -n $profile_id || -n $touch_panel ]]; then
    [[ -n $rootfs ]] && die 'Do not combine --profile-id/--touch-panel with --rootfs'
fi
[[ -z $rootfs ]] || rootfs=$(realpath -- "$rootfs")
source=$(realpath -- "$source")
kernel_out=$(realpath -- "$kernel_out")
stock=$(realpath -- "$stock")
output=$(realpath -m -- "$output")
[[ ! -e $output && ! -L $output ]] || die 'Output directory already exists'
if [[ -n $rootfs ]]; then
    [[ -s $rootfs/userdata.img && -s $rootfs/userdata.raw.img && -s $rootfs/SHA256SUMS ]] || die 'Incomplete Fedora 44 rootfs'
    (cd "$rootfs"; sha256sum -c SHA256SUMS) || die 'Rootfs checksums failed'
fi
[[ -s $source/boot-recipe/src/boot/dracut/root-guard.sh && -s $kernel_out/.config && -s $kernel_out/boot-initramfs.cpio.gz ]] || die 'Incomplete prepared Linux build'
release=$(sed -n 's/^kernel_release=//p' "$kernel_out/boot-manifest")
locked_release=$(jq -er '.kernel_version + "-" + .kernel_release' "$here/configs/package-lock.json")
[[ $release == "$locked_release" ]] || die 'Native kernel release differs from Fedora 44 package lock'
[[ $(cat "$kernel_out/include/config/kernel.release") == "$release" ]] || die 'Native output release mismatch'
expected_image=$(sed -n 's/^linux_kernel_sha256=//p' "$kernel_out/boot-manifest")
[[ $expected_image =~ ^[a-f0-9]{64}$ ]] || die 'Native Image digest missing'
[[ $(sed -n 's/^userdata_kernel_sha256=//p' "$kernel_out/boot-manifest") == "$expected_image" ]] \
    || die 'Native userdata kernel digest differs from Linux Image'
[[ $(sha256sum "$kernel_out/arch/arm64/boot/Image" | cut -d ' ' -f1) == "$expected_image" ]] || die 'Native Image does not match boot manifest'
[[ $(stat -c %s "$stock") == 100663296 ]] || die 'Unexpected OEM boot partition size'
stock_hash=$(sha256sum "$stock" | cut -d ' ' -f1)
[[ $stock_hash == 1eaf4858a7c70bee9b663b485f3192b164738bbdae3edbb986a5419621c8ef30 ]] || die 'Use the reviewed OS3.0.304.0.WOZMIXM OEM boot.img'
stock_avb=$(avbtool info_image --image "$stock") || die 'OEM boot AVB metadata is invalid'
rollback=$(sed -n 's/^Rollback Index:[[:space:]]*//p' <<< "$stock_avb")
[[ $rollback =~ ^[0-9]+$ ]] || die 'OEM rollback index missing'
stock_props=()
while IFS= read -r property; do stock_props+=(--prop "$property"); done < <(
    sed -nE "s/^[[:space:]]*Prop: ([A-Za-z0-9_.-]+) -> '(.*)'$/\1:\2/p" <<< "$stock_avb"
)
[[ " ${stock_props[*]} " == *'com.android.build.boot.os_version:'* ]] || die 'OEM boot version property missing'
for command in avbtool g++ jq sha256sum; do
    command -v "$command" >/dev/null || die "Missing host command: $command"
done
mkdir -p "$output"
build_platform=linux/arm64
if [[ -s $kernel_out/cross-source.sha256 ]]; then
    (cd "$source"; sha256sum -c "$kernel_out/cross-source.sha256") || die 'Cross kernel source receipt failed'
    build_platform=linux/amd64
fi
trap 'printf "build-boot-a: incomplete output retained at %s\n" "$output" >&2' ERR
printf '%s\n' "$release" > "$output/KERNEL-RELEASE"
printf '1\n' > "$output/NATIVE-O82-36"
printf '1\n' > "$output/NATIVE-O82-36-RATES"
printf '1\n' > "$output/NATIVE-O82-36-ALL-RATES"
printf '%s\n' "$build_platform" > "$output/BUILD-PLATFORM"
g++ -std=c++20 -O2 -Wall -Wextra -Werror "$here/src/boot/boot-image.cpp" -o "$output/boot-image"
grep -Fx 'root_selector_capability=uke-elfnote-v2' "$kernel_out/boot-manifest" >/dev/null \
    || die 'Native userdata root-selector capability is absent'
expected_userdata=$(sed -n 's/^userdata_image_sha256=//p' "$kernel_out/boot-manifest")
[[ $expected_userdata =~ ^[a-f0-9]{64}$ && -s $kernel_out/userdata.img ]] \
    || die 'Native userdata boot image is missing'
[[ $(sha256sum "$kernel_out/userdata.img" | cut -d' ' -f1) == "$expected_userdata" ]] \
    || die 'Native userdata boot image does not match boot manifest'
"$output/boot-image" check-root "$kernel_out/userdata.img" userdata
"$output/boot-image" extract "$kernel_out/userdata.img" "$output/readback-native-Image"
cmp "$kernel_out/arch/arm64/boot/Image" "$output/readback-native-Image" \
    || die 'Native userdata image contains a different kernel'
rm -- "$output/readback-native-Image"
cp "$kernel_out/arch/arm64/boot/Image" "$output/Image"
cp "$kernel_out/.config" "$output/boot.config"
cp "$kernel_out/Module.symvers" "$output/Module.symvers"
cp "$kernel_out/boot-initramfs.cpio.gz" "$output/boot-initramfs.cpio.gz"
"$output/boot-image" inspect "$stock" > "$output/stock-header.json"
jq -e '.header_version==4 and .ramdisk_bytes==0 and .signature_bytes==0 and .image_bytes==100663296' "$output/stock-header.json" >/dev/null || die 'Unexpected OEM boot v4 template'
"$output/boot-image" pack "$stock" "$output/Image" "$output/fedora_boot.img.part" 100663296 userdata
"$output/boot-image" check-root "$output/fedora_boot.img.part" userdata
"$output/boot-image" inspect "$output/fedora_boot.img.part" > "$output/boot-header.json"
"$output/boot-image" extract "$output/fedora_boot.img.part" "$output/readback-Image"
cmp "$output/Image" "$output/readback-Image" || die 'Android boot kernel roundtrip failed'
rm -- "$output/readback-Image"
truncate -s "$(jq -er .payload_end "$output/boot-header.json")" "$output/fedora_boot.img.part"
avbtool add_hash_footer --image "$output/fedora_boot.img.part" --partition_name boot \
    --partition_size 100663296 --algorithm NONE --salt "$stock_hash" \
    --rollback_index "$rollback" "${stock_props[@]}"
# avbtool resolves the boot descriptor against boot.img next to the image.
mv "$output/fedora_boot.img.part" "$output/boot.img"
avbtool verify_image --image "$output/boot.img" || die 'AVB footer verification failed'
"$output/boot-image" check-root "$output/boot.img" userdata
"$output/boot-image" inspect "$output/boot.img" > "$output/boot-header.json"
jq -e '.avb_footer_present==true and .image_bytes==100663296 and .payload_end<.image_bytes' "$output/boot-header.json" >/dev/null || die 'Final boot image lacks a bounded AVB footer'
mv "$output/boot.img" "$output/fedora_boot.img"

# Everything below splits on whether a rootfs was supplied.  With one, the
# output is the pair the installer and the release archives expect.  Without
# one it is boot_a alone: the manifest keeps the fields that describe boot and
# records the rootfs-dependent ones as null, so a consumer can tell the two
# shapes apart instead of reading a zero as a real size.
if [[ -n $rootfs ]]; then
    cp --reflink=auto "$rootfs/userdata.img" "$output/userdata.img"
    cp "$rootfs/PROFILE-ID" "$rootfs/TOUCH-PANEL" "$rootfs/LOCAL-BLOBS.sha256" "$output/"
    profile=$(cat "$rootfs/PROFILE-ID")
    panel=$(cat "$rootfs/TOUCH-PANEL")
    root_bytes=$(stat -c %s "$rootfs/userdata.raw.img")
    userdata_hash=$(sha256sum "$output/userdata.img" | cut -d ' ' -f1)
    image_set='["fedora_boot.img","userdata.img"]'
else
    # A boot-only build carries no rootfs, so the profile and touch panel are
    # not observable from the output set.  --profile-id/--touch-panel record
    # what a caller knows; otherwise the manifest says so rather than guessing.
    profile=${profile_id:-unknown}
    panel=${touch_panel:-unknown}
    root_bytes=null
    userdata_hash=null
    image_set='["fedora_boot.img"]'
fi
jq -n --arg profile "$profile" --arg release "$release" \
    --arg build_platform "$build_platform" \
    --arg panel "$panel" \
    --arg boot "$(sha256sum "$output/fedora_boot.img" | cut -d ' ' -f1)" \
    --arg userdata "$userdata_hash" \
    --arg stock "$stock_hash" --argjson root_bytes "$root_bytes" \
    --argjson image_set "$image_set" \
    --slurpfile header "$output/boot-header.json" \
    '{schema_version:1,device:"uke",distribution:"fedora",release:"44",kernel_release:$release,
      kernel_build_platform:$build_platform,
      experimental_native_o82_36:true,
      experimental_native_o82_36_rates:true,
      experimental_native_o82_36_all_rates:true,
      profile:$profile,experimental_desktop:($profile=="phosh" or $profile=="plasma-mobile"),
      touch_panel:$panel,touch_variants:["tm","csot"],boot_partition:"boot_a",root_partition:"userdata",
      images:$image_set,
      root_image_logical_bytes:$root_bytes,stock_boot_sha256:$stock,
      sha256:{boot:$boot,userdata:(if $userdata == "" then null else $userdata end)},
      header:$header[0],
      boot_tested:false,hardware_tested:false,device_write_executed:false}' > "$output/manifest.json"

boot_artifacts=(fedora_boot.img Image boot.config Module.symvers boot-initramfs.cpio.gz \
    stock-header.json boot-header.json manifest.json BUILD-PLATFORM NATIVE-O82-36 \
    NATIVE-O82-36-RATES NATIVE-O82-36-ALL-RATES)
if [[ -n $rootfs ]]; then
    boot_artifacts+=(userdata.img PROFILE-ID TOUCH-PANEL LOCAL-BLOBS.sha256)
fi
(cd "$output"; sha256sum "${boot_artifacts[@]}" > SHA256SUMS)
if [[ -n $rootfs ]]; then
    printf 'Image pair: %s/fedora_boot.img and %s/userdata.img\n' "$output" "$output"
else
    printf 'Boot image: %s/fedora_boot.img (no rootfs requested)\n' "$output"
fi

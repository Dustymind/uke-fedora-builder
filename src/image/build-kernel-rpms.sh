#!/usr/bin/env bash
# Build the matched kernel RPM set for one kernel source checkout.
#
# Sourced by build-rpms.sh, build-boot-images.sh and build-images.sh so the
# kernel compile and the RPM recipes live in exactly one place.  The caller owns
# the status file and the container label.
set -Eeuo pipefail

_bkr_here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
_bkr_top=$(cd -- "$_bkr_here/../.." && pwd)

# The kernel subpackages that travel together.  boot carries the Android v4
# container and, via %posttrans, the uke-kernel-update transaction that writes
# boot_a on a running system; installing the other three alone updates
# /usr/lib/modules and leaves boot_a stale.
BUILD_KERNEL_RPM_PARTS=(core modules dtbs boot)

# build_kernel_rpms <staging_dir>
#
# Requires the orchestrator state: $output, $cache_dir, $workspace, $container,
# $release, $rebuild_kernel, $cross_kernel, $sanitizer_env, $UKE_BUILD_RUN_ID.
# Sets BUILD_KERNEL_TOP and BUILD_KERNEL_OUT for the caller.
build_kernel_rpms() {
    local staging=$1
    local kernel_top=$workspace/senemos-uke-kernel/build/srpm/rpmbuild
    local arm_image amd_image jobs

    build_progress 'Prepare reusable build tools'
    mkdir -p "$cache_dir/dnf" "$cache_dir/dnf-x86_64" "$cache_dir/ccache" "$cache_dir/ccache-cross"
    arm_image=$(bash "$_bkr_top/src/image/ensure-build-image.sh" "$container" linux/arm64)

    # The recipe below records its own stages through build-control.sh; the host
    # does not restate them.
    "$container" run --rm -i --network=host --platform linux/arm64 --security-opt label=disable \
        --label "org.uke-fedora.build-run=$UKE_BUILD_RUN_ID" \
        "${sanitizer_env[@]}" \
        -e UKE_REBUILD_KERNEL="$rebuild_kernel" -e UKE_CROSS_KERNEL="$cross_kernel" \
        -e FEDORA_RELEASE="$release" \
        -e UKE_VIDEO_OVERLAY="${UKE_VIDEO_OVERLAY:-0}" \
        -e UKE_BUILD_RUN_ID -e UKE_BUILD_OUTPUT=/build-output \
        -v "$cache_dir:/build-cache" -v "$output:/build-output" \
        -v "$workspace:/work" -w /work "$arm_image" \
        bash -s <<'BUILD_RPMS'
set -Eeuo pipefail
release=${FEDORA_RELEASE:?}
cache_dir=/build-cache
source uke-fedora-builder/src/image/package-lock.sh
dnf=(dnf5 -y --setopt=system_cachedir=/build-cache/dnf --setopt=keepcache=True)
export UKE_CCACHE=1 CCACHE_DIR=/build-cache/ccache CCACHE_MAXSIZE=10G
git config --global --add safe.directory /work/senemos-uke-kernel
bash uke-fedora-builder/src/image/build-control.sh stage 'Prepare source RPMs'
kernel_srpm_stamp=$cache_dir/kernel-srpm-$release.stamp
kernel_key=$( { git -C senemos-uke-kernel rev-parse HEAD
                git -C senemos-uke-kernel status --porcelain
              } | sha256sum | cut -d' ' -f1 )
if [[ -f $kernel_srpm_stamp && $(<"$kernel_srpm_stamp") == "$kernel_key" ]] &&
   compgen -G "senemos-uke-kernel/build/srpm/*.src.rpm" >/dev/null; then
    printf 'Reusing kernel source RPMs (%s)\n' "$kernel_key"
else
    make -C senemos-uke-kernel srpm
    printf '%s\n' "$kernel_key" > "$kernel_srpm_stamp"
fi
make -C uke-linux-hardware-support/uke-core-meta FEDORA44_LEGACY=1 srpm
make -C uke-linux-hardware-support/uke-sensors touchscreen-srpm
make -C uke-linux-hardware-support/uke-console-input srpm
make -C uke-linux-hardware-support/uke-platform-runtime srpm
make -C uke-linux-hardware-support/uke-boot FEDORA44_LEGACY=1 srpm
make -C uke-linux-hardware-support/uke-video srpm
make -C uke-linux-hardware-support/xiaomi-uke-firmware image-data-srpm
for package in libssc iio-sensor-proxy uke-ssc-fileservice; do
    make -C uke-linux-hardware-support/uke-sensors PACKAGE="$package" srpm
done
kernel_spec=senemos-uke-kernel/build/srpm/rpmbuild/SPECS/senemos-uke-linux-kernel-mainline.spec
boot_spec=uke-linux-hardware-support/uke-boot/build/srpm/rpmbuild/SPECS/uke-boot-integration.spec
[[ $(rpmspec -q --srpm --qf '%{VERSION}-%{RELEASE}' --target aarch64 "$kernel_spec") == "$uke_kernel_rpm_release" ]] || {
    echo 'Kernel RPM spec differs from the Fedora 44 package lock' >&2; exit 1;
}
[[ $(rpmspec -q --srpm --qf '%{VERSION}-%{RELEASE}' --target aarch64 "$boot_spec") == "$uke_boot_rpm_release" ]] || {
    echo 'Boot integration RPM spec differs from the Fedora 44 package lock' >&2; exit 1;
}
tops=(
  senemos-uke-kernel/build/srpm/rpmbuild
  uke-linux-hardware-support/uke-core-meta/build/srpm/rpmbuild
  uke-linux-hardware-support/uke-sensors/build/rpmbuild
  uke-linux-hardware-support/uke-console-input/build/rpmbuild
  uke-linux-hardware-support/uke-platform-runtime/build/rpmbuild
  uke-linux-hardware-support/uke-boot/build/srpm/rpmbuild
  uke-linux-hardware-support/uke-video/build/srpm
)
for top in "${tops[@]}"; do
    case $top in
        senemos-uke-kernel/*) component=kernel;;
        */uke-core-meta/*) component=core-meta;;
        */uke-sensors/*) component=touchscreen;;
        */uke-console-input/*) component=console-input;;
        */uke-platform-runtime/*) component=battery;;
        */uke-boot/*) component=boot-integration;;
        */uke-video/*) component=vaapi;;
    esac
    bash uke-fedora-builder/src/image/build-control.sh stage "RPM: $component"
    specs=("$top"/SPECS/*.spec)
    ((${#specs[@]} == 1)) && [[ -f ${specs[0]} ]] || { printf 'Expected one spec in %s\n' "$top" >&2; exit 1; }
    if [[ $top == senemos-uke-kernel/build/srpm/rpmbuild ]]; then
        rm -f -- "$top/.fedora${release}-cross-pending"
    fi
    if [[ $top == senemos-uke-kernel/build/srpm/rpmbuild && $UKE_REBUILD_KERNEL == 0 ]] && \
       bash uke-fedora-builder/src/image/kernel-rpm-cache.sh check "$top"; then
        printf 'Reusing verified Linux %s RPMs and boot build\n' "$uke_kernel_version"
        continue
    fi
    if [[ $top != senemos-uke-kernel/build/srpm/rpmbuild ]] && \
       bash uke-fedora-builder/src/image/rpm-build-cache.sh check "$top"; then
        printf 'Reusing verified RPMs from %s\n' "$top"
        continue
    fi
    if [[ $top != senemos-uke-kernel/build/srpm/rpmbuild ]]; then
        bash uke-fedora-builder/src/image/rpm-build-cache.sh invalidate "$top"
    fi
    if [[ $top == senemos-uke-kernel/build/srpm/rpmbuild ]]; then
        if [[ -e $top/native-kernel-out || -e $top/boot-userspace ]]; then
            previous=$(mktemp -d "$top/previous-native-kernel-out.XXXXXXXX")
            for path in native-kernel-out boot-userspace; do
                [[ ! -e $top/$path ]] || mv -- "$top/$path" "$previous/"
            done
            printf 'Preserved the previous kernel work at %s\n' "$previous"
        fi
    fi
    "${dnf[@]}" builddep "${specs[0]}"
    if [[ $top == senemos-uke-kernel/build/srpm/rpmbuild && $UKE_CROSS_KERNEL == 1 ]]; then
        rpmbuild -bp --nodeps --target aarch64 --define "_topdir /work/$top" "${specs[0]}"
        source=$top/BUILD/senemos-uke-linux-kernel-mainline-${uke_kernel_version}-build/linux-${uke_kernel_version}
        base=$top/boot-userspace
        bash "$source/boot-recipe/src/boot/make-initramfs-base.sh" "$base" "$uke_kernel_krel"
        clang++ -std=c++17 -O2 -Wall -Wextra -Werror -ffile-prefix-map="$PWD"=. \
            "$source/boot-recipe/src/boot/offline-switch-root.cpp" -o "$base/uke-offline-switch-root"
        clang++ -std=c++20 -O2 -Wall -Wextra -Werror \
            "$source/boot-recipe/src/boot/boot-image.cpp" -o "$base/boot-image-aarch64"
        for binary in uke-offline-switch-root boot-image-aarch64; do
            readelf -h "$base/$binary" | grep -E 'Machine:.*AArch64' >/dev/null
        done
        printf '%s\n' "$uke_kernel_krel" > "$top/.fedora${release}-cross-pending"
        continue
    fi
    rpmbuild -ba --target aarch64 --define "_topdir /work/$top" "${specs[0]}"
    if [[ $top == senemos-uke-kernel/build/srpm/rpmbuild ]]; then
        # RPM removes BUILD after -ba; restore the verified source needed by
        # the cache receipt and the per-profile boot image builds.
        rpmbuild -bp --nodeps --target aarch64 --define "_topdir /work/$top" "${specs[0]}"
        bash uke-fedora-builder/src/image/kernel-rpm-cache.sh record "$top"
    else
        bash uke-fedora-builder/src/image/rpm-build-cache.sh record "$top"
    fi
done
sensor_root=uke-linux-hardware-support/uke-sensors/build/srpm
for package in libssc iio-sensor-proxy uke-ssc-fileservice; do
    bash uke-fedora-builder/src/image/build-control.sh stage "RPM: $package"
    top=$sensor_root/$package/rpmbuild
    spec=$top/SPECS/$package.spec
    dependencies=()
    if [[ $package == iio-sensor-proxy ]]; then
        dependencies=("$sensor_root/libssc/rpmbuild/RPMS/aarch64/"libssc{,-devel}-0.4.4-*.fc44.aarch64.rpm)
    fi
    if bash uke-fedora-builder/src/image/rpm-build-cache.sh check "$top" "${dependencies[@]}"; then
        printf 'Reusing verified RPMs from %s\n' "$top"
    else
        bash uke-fedora-builder/src/image/rpm-build-cache.sh invalidate "$top"
        "${dnf[@]}" builddep "$spec"
        rpmbuild -ba --target aarch64 --define "_topdir /work/$top" "$spec"
        bash uke-fedora-builder/src/image/rpm-build-cache.sh record "$top" "${dependencies[@]}"
    fi
    if [[ $package == libssc ]]; then
        "${dnf[@]}" install \
            "$top"/RPMS/aarch64/libssc-0.4.4-*.fc44.aarch64.rpm \
            "$top"/RPMS/aarch64/libssc-devel-0.4.4-*.fc44.aarch64.rpm
    fi
done
top=uke-linux-hardware-support/xiaomi-uke-firmware/build/fedora${release}-image-data/rpmbuild
bash uke-fedora-builder/src/image/build-control.sh stage 'RPM: OEM data'
oem_rpm="$top/RPMS/noarch/uke-fedora${release}-oem-data-3.0.304.0-2.fc${release}.noarch.rpm"
if bash uke-fedora-builder/src/image/rpm-build-cache.sh check "$top" && \
   bash uke-fedora-builder/src/image/verify-oem-rpm.sh "$oem_rpm"; then
    printf 'Reusing verified RPMs from %s\n' "$top"
else
    bash uke-fedora-builder/src/image/rpm-build-cache.sh invalidate "$top"
    rpmbuild -ba --target noarch --define "_topdir /work/$top" \
        "$top/SPECS/uke-oem-data.spec"
    bash uke-fedora-builder/src/image/verify-oem-rpm.sh "$oem_rpm"
    bash uke-fedora-builder/src/image/rpm-build-cache.sh record "$top"
fi
BUILD_RPMS
    if [[ -f $kernel_top/.fedora${release}-cross-pending ]]; then
        build_progress 'RPM: kernel (cross-compile and package)'
        amd_image=$(bash "$_bkr_top/src/image/ensure-build-image.sh" "$container" linux/amd64)
        jobs=$(nproc)
        ((jobs > 16)) && jobs=16
        "$container" run --rm -i --network=host --platform linux/amd64 --security-opt label=disable \
            --label "org.uke-fedora.build-run=$UKE_BUILD_RUN_ID" \
            -e UKE_KERNEL_KREL="$uke_kernel_krel" -e UKE_KERNEL_VERSION="$uke_kernel_version" \
            -e UKE_SOURCE_DATE_EPOCH="$kernel_epoch" -e UKE_JOBS="$jobs" \
            -e FEDORA_RELEASE="$release" \
            -v "$cache_dir:/build-cache" -v "$workspace:/work" -w /work \
            "$amd_image" bash -s <<'CROSS_KERNEL'
set -Eeuo pipefail
release=${FEDORA_RELEASE:?}
top=/work/senemos-uke-kernel/build/srpm/rpmbuild
source=$top/BUILD/senemos-uke-linux-kernel-mainline-${UKE_KERNEL_VERSION}-build/linux-${UKE_KERNEL_VERSION}
[[ $(cat "$top/.fedora${release}-cross-pending") == "$UKE_KERNEL_KREL" ]] || exit 2
export UKE_CROSS_KERNEL=1 UKE_CCACHE=1 CCACHE_DIR=/build-cache/ccache-cross CCACHE_MAXSIZE=10G
export KBUILD_BUILD_USER=senemos KBUILD_BUILD_HOST=copr-builder KBUILD_BUILD_VERSION=1
export SOURCE_DATE_EPOCH=$UKE_SOURCE_DATE_EPOCH
KBUILD_BUILD_TIMESTAMP=$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC')
export KBUILD_BUILD_TIMESTAMP
bash "$source/boot-recipe/src/boot/build-payload.sh" "$source" \
    "$top/native-kernel-out" "$top/boot-userspace/base" "$UKE_KERNEL_KREL" "$UKE_JOBS"
CROSS_KERNEL
        "$container" run --rm -i --network=host --platform linux/arm64 --security-opt label=disable \
            --label "org.uke-fedora.build-run=$UKE_BUILD_RUN_ID" \
            "${sanitizer_env[@]}" -e FEDORA_RELEASE="$release" \
            -v "$cache_dir:/build-cache" -v "$workspace:/work" -w /work \
            "$arm_image" bash -s <<'PACKAGE_KERNEL'
set -Eeuo pipefail
release=${FEDORA_RELEASE:?}
dnf=(dnf5 -y --setopt=system_cachedir=/build-cache/dnf --setopt=keepcache=True)
top=/work/senemos-uke-kernel/build/srpm/rpmbuild
spec=$top/SPECS/senemos-uke-linux-kernel-mainline.spec
"${dnf[@]}" builddep "$spec"
UKE_PREBUILT_KERNEL=1 rpmbuild -ba --target aarch64 --define "_topdir $top" "$spec"
rpmbuild -bp --nodeps --target aarch64 --define "_topdir $top" "$spec"
bash /work/uke-fedora-builder/src/image/kernel-rpm-cache.sh record "$top"
rm -f -- "$top/.fedora${release}-cross-pending"
PACKAGE_KERNEL
    fi

    build_progress 'Stage kernel RPMs'
    [[ -d $kernel_top/BUILD ]] || die 'Kernel RPM build did not create its BUILD directory'
    [[ ! -L $staging ]] || die 'Kernel RPM staging directory is a symlink'
    mkdir -p "$staging"
    find "$staging" -maxdepth 1 -type f -name 'senemos-uke-linux-kernel-mainline*.rpm' -delete
    local part rpm
    for part in "${BUILD_KERNEL_RPM_PARTS[@]}"; do
        rpm=$kernel_top/RPMS/aarch64/senemos-uke-linux-kernel-mainline-$part-$uke_kernel_rpm_release.aarch64.rpm
        [[ -s $rpm && ! -L $rpm ]] || die "Missing matched kernel RPM: $rpm"
        cp --reflink=auto -- "$rpm" "$staging/"
    done
    ( cd "$staging"; sha256sum ./*.rpm > SHA256SUMS )
    BUILD_KERNEL_TOP=$kernel_top
    BUILD_KERNEL_OUT=$kernel_top/native-kernel-out
}

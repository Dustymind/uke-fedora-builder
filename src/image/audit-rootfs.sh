#!/usr/bin/env bash
# Check release-critical files after DNF scriptlets and before an image is accepted.
set -Eeuo pipefail
[[ $# == 1 && -d $1/root && -f $1/PROFILE-ID ]] || {
    echo 'Usage: audit-rootfs.sh ROOTFS_OUTPUT' >&2; exit 2;
}
output=$(realpath -- "$1")
root=$output/root
profile=$(cat "$output/PROFILE-ID")
fail() { printf 'rootfs audit (%s): %s\n' "$profile" "$*" >&2; exit 1; }
case $profile in tty|kde|gnome|phosh|plasma-mobile) ;; *) fail 'invalid profile' ;; esac

# DNF can report a successful transaction after a failing systemd-udev trigger.
[[ -f $root/etc/udev/hwdb.bin && ! -L $root/etc/udev/hwdb.bin ]] || fail 'missing hardware database'
hwdb_bytes=$(stat -c %s "$root/etc/udev/hwdb.bin")
((hwdb_bytes > 10000000)) || fail "hardware database is incomplete ($hwdb_bytes bytes)"
[[ -s $root/usr/lib/udev/hwdb.d/20-OUI.hwdb ]] || fail 'hardware database source is missing'
[[ -x $root/usr/libexec/senemos-uke/uke-clock-state ]] || fail 'offline clock helper is missing'
[[ -s $root/usr/lib/systemd/system/uke-clock-restore.service &&
   -s $root/usr/lib/systemd/system/uke-clock-save.timer ]] || fail 'offline clock units are missing'
[[ -L $root/etc/systemd/system/sysinit.target.wants/uke-clock-restore.service &&
   -L $root/etc/systemd/system/timers.target.wants/uke-clock-save.timer ]] || fail 'offline clock units are disabled'
[[ -f $root/usr/lib/systemd/system/chronyd.service.d/70-uke-clock.conf ]] &&
    grep -Fxq 'ExecStart=/usr/sbin/chronyd -n $OPTIONS' \
        "$root/usr/lib/systemd/system/chronyd.service.d/70-uke-clock.conf" \
    || fail 'chronyd can override the restored time from RTC'

# The catalog trigger can fail in an installroot. Preserve its input for boot.
[[ -s $root/usr/lib/systemd/catalog/dbus-broker-launch.catalog ]] || fail 'dbus catalog source is missing'
[[ -s $root/usr/lib/systemd/system/systemd-journal-catalog-update.service && \
   -L $root/usr/lib/systemd/system/sysinit.target.wants/systemd-journal-catalog-update.service ]] \
    || fail 'journal catalog boot update is missing'
[[ -s $root/usr/lib/systemd/system/systemd-tmpfiles-clean.service ]] || fail 'tmpfiles clean unit is missing'
[[ -s $root/usr/lib64/security/pam_systemd.so ]] || fail 'systemd login-session PAM module is missing'
mapfile -t kernel_configs < <(find "$root/usr/lib/modules" -mindepth 2 -maxdepth 2 -name config -type f -print)
((${#kernel_configs[@]} == 1)) || fail 'expected one kernel config'
grep -Fxq CONFIG_I2C_CHARDEV=y "${kernel_configs[0]}" || fail 'i2c-dev is unavailable'
grep -Fxq CONFIG_ZRAM=m "${kernel_configs[0]}" || fail 'kernel ZRAM module is unavailable'
grep -Eq '^zram-generator[[:space:]]' "$output/packages.tsv" || fail 'ZRAM generator is missing'
[[ -s $root/etc/systemd/zram-generator.conf ]] || fail 'ZRAM configuration is missing'
grep -Fxq 'zram-size = min(ram * 3 / 4, 6144)' "$root/etc/systemd/zram-generator.conf" || fail 'unexpected ZRAM size'

# A nonstandard Qualcomm DSP binary makes brp-strip print an error. Verify that
# the installed payload still matches the reviewed bundled file byte for byte.
blobs=$(realpath -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../uke-linux-hardware-support/xiaomi-uke-firmware/payload/oem-os3.0.304.0")
cmp -s "$blobs/ssc/sns_tppe.so" "$root/usr/lib/firmware/qcom/uke/sensors/sns_tppe.so" || fail 'SSC firmware changed during RPM assembly'
firmware_count=0
while IFS=$'\t' read -r path expected; do
    target=$root/usr/lib/firmware/$path
    [[ -f $target && ! -L $target ]] || fail "OEM firmware missing: $path"
    [[ $(sha256sum "$target" | cut -d' ' -f1) == "$expected" ]] || fail "OEM firmware mismatch: $path"
    ((firmware_count+=1))
done < <(jq -r '.files[] | [.target_path, .sha256] | @tsv' \
    "$(dirname -- "${BASH_SOURCE[0]}")/../../../uke-linux-hardware-support/xiaomi-uke-firmware/manifests/local-firmware-candidates.json")
((firmware_count == 75)) || fail "Expected 75 pinned firmware files; got $firmware_count"
touch_panel=$(cat "$output/TOUCH-PANEL")
[[ $touch_panel == auto ]] || fail 'touch selection is not automatic'
[[ -s $output/TOUCH-INSTALLED.sha256 ]] || fail 'touch input receipt is missing'
for name in tm/normal.bin tm/config.ini csot/normal.bin csot/config.ini reference.bin; do
    source=$blobs/touch/$name
    expected=$(sha256sum "$source" | cut -d' ' -f1)
    installed=$(awk -v name="$name" '$2 == name {print $1}' "$output/TOUCH-INSTALLED.sha256")
    [[ $installed == "$expected" ]] || fail "Touch $name differs from bundled OEM input"
done

[[ -s $root/etc/fstab ]] && grep -Fq 'PARTLABEL=userdata / ext4 ' "$root/etc/fstab" || fail 'userdata mount is missing'

# The overlay assets belong to the image but to no package, so an audit that
# only looks at the inventory would accept an image that silently lost them.
builder_root=$(dirname -- "${BASH_SOURCE[0]}")/../..
overlay_trees=("$builder_root/configs/rootfs")
(( ${UKE_COPR:-1} == 0 )) || overlay_trees+=("$builder_root/configs/rootfs-copr")
overlay_count=0
for tree in "${overlay_trees[@]}"; do
    [[ -d $tree ]] || fail "overlay source is missing: ${tree##*/}"
    while IFS= read -r -d '' source; do
        relative=${source#"$tree"/}
        target=$root/$relative
        [[ -f $target && ! -L $target ]] || fail "overlay file is missing: $relative"
        # Ownership cannot be checked from here: a rootless container writes the
        # tree as the invoking user, and only the container sees it as root.  The
        # mode survives that mapping, so the build asserts 0644 root inside.
        [[ $(stat -c '%a' "$target") == '644' ]] || fail "overlay mode changed: $relative"
        [[ $(sha256sum "$target" | cut -d' ' -f1) == "$(sha256sum "$source" | cut -d' ' -f1)" ]] \
            || fail "overlay content differs: $relative"
        overlay_count=$((overlay_count + 1))
    done < <(find "$tree" -type f -print0)
done
[[ $overlay_count -gt 0 ]] || fail 'no overlay files were verified'
[[ -f $root/var/lib/uke-vaapi/v4l2_drv_video.so &&
   ! -L $root/var/lib/uke-vaapi/v4l2_drv_video.so ]] || fail 'VA-API driver copy is missing'
[[ $(readlink "$root/var/lib/uke-vaapi/msm_drv_video.so") == v4l2_drv_video.so ]] \
    || fail 'VA-API driver alias is missing'
cmp -s "$root/usr/lib64/dri/v4l2_drv_video.so" "$root/var/lib/uke-vaapi/v4l2_drv_video.so" \
    || fail 'VA-API driver copy differs from the packaged driver'
# Identity is scrubbed per build; a populated machine-id would be shared by
# every tablet flashed from this image.
[[ ! -s $root/etc/machine-id ]] || fail 'machine-id was not cleared'
[[ -z $(find "$root/etc/ssh" -maxdepth 1 -name 'ssh_host_*' -print -quit 2>/dev/null) ]] \
    || fail 'SSH host keys are present in the image'
[[ ! -e $root/var/lib/systemd/random-seed ]] || fail 'random-seed is present in the image'

# The keyboard support package replaced seven loose files.  A missing firmware
# file is not a degraded keyboard, it is no keyboard: the HID driver requests
# it during probe and fails the probe when the request fails.
grep -Eq '^uke-keyboard-support[[:space:]]' "$output/packages.tsv" \
    || fail 'keyboard support RPM is absent from the inventory'
[[ -f $root/usr/lib/firmware/nanosic/MCU_Upgrade.bin &&
   ! -L $root/usr/lib/firmware/nanosic/MCU_Upgrade.bin ]] || fail 'keyboard firmware is missing'
for helper in nanosic-authd nanosic-backlight nanosic-rebind; do
    [[ -x $root/usr/bin/$helper && ! -L $root/usr/bin/$helper ]] || fail "keyboard helper is missing: $helper"
done
grep -Fxq hid-nanosic-wn8030 "$root/usr/lib/modules-load.d/nanosic.conf" 2>/dev/null \
    || fail 'the keyboard module is not loaded at boot'
for unit in nanosic-authd nanosic-backlight nanosic-rebind; do
    [[ -s $root/usr/lib/systemd/system/$unit.service ]] || fail "keyboard unit is missing: $unit"
done
for unit in nanosic-rebind nanosic-backlight; do
    [[ -L $root/etc/systemd/system/multi-user.target.wants/$unit.service ]] \
        || fail "keyboard helper is not enabled: $unit"
done
[[ ! -e $root/etc/systemd/system/multi-user.target.wants/nanosic-authd.service ]] \
    || fail 'the auth daemon must stay disabled without a token source'
[[ -z $(find "$root/usr/local/sbin" -maxdepth 1 -name 'nanosic-*' -print -quit 2>/dev/null) ]] \
    || fail 'a keyboard helper is still installed under /usr/local/sbin'
case $profile in
    tty)
        grep -Eq '^uke-console-input[[:space:]]' "$output/packages.tsv" || fail 'TTY keyboard RPM is absent from inventory'
        [[ -s $root/usr/lib/systemd/system/uke-create-user.service ]] || fail 'TTY first-boot account setup is missing'
        [[ -x $root/usr/bin/buffyboard && -s $root/usr/lib/systemd/system/uke-console-input.service ]] \
            || fail 'TTY touch keyboard package is missing'
        [[ -L $root/etc/systemd/system/multi-user.target.wants/uke-console-input.service ]] \
            || fail 'TTY touch keyboard is not enabled'
        ;;
    kde|plasma-mobile)
        grep -Eq '^upower[[:space:]]' "$output/packages.tsv" || fail 'UPower is missing from graphical rootfs'
        grep -Eq '^bluedevil[[:space:]]' "$output/packages.tsv" || fail 'KDE Bluetooth integration is missing'
        [[ -s $root/usr/share/applications/kcm_bluetooth.desktop ]] || fail 'KDE Bluetooth settings are missing'
        if grep -Eq '^uke-console-input[[:space:]]' "$output/packages.tsv"; then fail 'TTY keyboard RPM is in GUI inventory'; fi
        [[ ! -e $root/usr/bin/buffyboard && ! -L $root/usr/bin/buffyboard && \
           ! -e $root/usr/lib/systemd/system/uke-console-input.service && \
           ! -L $root/usr/lib/systemd/system/uke-console-input.service && \
           ! -L $root/etc/systemd/system/multi-user.target.wants/uke-console-input.service ]] \
            || fail 'TTY keyboard leaked into GUI rootfs'
        [[ -x $root/usr/libexec/plasma-setup-bootutil ]] || fail 'Plasma first-boot setup is missing'
        [[ -s $root/usr/share/sddm/themes/01-breeze-fedora/Main.qml &&
           -s $root/usr/share/sddm/themes/01-breeze-fedora/KeyboardButton.qml ]] \
            || fail 'SDDM theme or on-screen keyboard button is missing'
        [[ -x $root/usr/bin/dbus-run-session ]] || fail 'Plasma session D-Bus launcher is missing'
        [[ -s $root/usr/share/wayland-sessions/${profile/kde/plasma}.desktop ]] || fail 'Plasma Wayland session is missing'
        ;;
    gnome|phosh)
        grep -Eq '^upower[[:space:]]' "$output/packages.tsv" || fail 'UPower is missing from graphical rootfs'
        if grep -Eq '^uke-console-input[[:space:]]' "$output/packages.tsv"; then fail 'TTY keyboard RPM is in GUI inventory'; fi
        [[ ! -e $root/usr/bin/buffyboard && ! -L $root/usr/bin/buffyboard && \
           ! -e $root/usr/lib/systemd/system/uke-console-input.service && \
           ! -L $root/usr/lib/systemd/system/uke-console-input.service && \
           ! -L $root/etc/systemd/system/multi-user.target.wants/uke-console-input.service ]] \
            || fail 'TTY keyboard leaked into GUI rootfs'
        [[ -x $root/usr/libexec/gnome-initial-setup ]] || fail 'GNOME first-boot setup is missing'
        [[ -s $root/usr/share/wayland-sessions/$profile.desktop ]] || fail 'Wayland session is missing'
        ;;
esac
printf 'rootfs audit (%s): hwdb %s bytes; firmware, first boot and critical files verified\n' "$profile" "$hwdb_bytes"

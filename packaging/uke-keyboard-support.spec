%global debug_package %{nil}
%{!?_unitdir:%global _unitdir /usr/lib/systemd/system}
%{!?_modulesloaddir:%global _modulesloaddir /usr/lib/modules-load.d}
%{!?_licensedir:%global _licensedir /usr/share/licenses}

Name: uke-keyboard-support
Version: 1.0.0
Release: 1%{?dist}
Summary: Nanosic WN8030 keyboard firmware and helpers for the Xiaomi Focus Keyboard
License: MIT and Proprietary
URL: https://github.com/linuxgamer/uke-fedora

# The firmware is the OEM blob the HID driver loads at probe time; we do not
# license it.  It ships here for the device it came from, the same bytes the
# kernel embeds through CONFIG_EXTRA_FIRMWARE.  Everything else is ours.
Source0: MCU_Upgrade.bin
Source1: nanosic-authd
Source2: nanosic-authd.service
Source3: nanosic-backlight
Source4: nanosic-backlight.service
Source5: nanosic-rebind
Source6: nanosic-rebind.service
Source7: nanosic.conf
Source8: LICENSE

BuildArch: noarch
Requires: python3
Requires: systemd

%description
Firmware for the Nanosic WN8030 controller in the Xiaomi Focus Keyboard, the
module that must be loaded for it to enumerate, and the userspace the device
needs in practice: a backlight helper for the touchpad SKU, a helper that
resets the MiAuth window the MCU closes on its own, and a daemon that could
answer the handshake once a token source exists.

The daemon is installed but not enabled.  The token comes from an Android AIDL
HAL, and answering the handshake with a zero token makes the MCU stop scanning
keys a few minutes after boot.  The driver leaves the handshake alone
(mi_auth=0), so the daemon has nothing useful to do until then.

The rebind helper is enabled unconditionally, and that is a workaround rather
than a fix: nothing answers the MCU's 0x24 request, so the window closes and
the keyboard goes deaf until the I2C driver is cycled.  Each cycle powers the
MCU down through both regulators and runs it through the bootrom, so the
keyboard is deaf for about a second and the Caps Lock state the MCU held is
lost.  If a real token provider is ever wired up and the module is loaded with
mi_auth=1, the unit must be disabled: answering the handshake makes the
periodic power cycle both unnecessary and harmful.

The package carries no preset and no scriptlet.  The image builder enables the
two helpers with "systemctl --root enable" so that the resulting symlinks are
part of the audited rootfs, not a side effect of an installroot transaction.

%prep

%build

%install
install -Dm644 %{SOURCE0} %{buildroot}/usr/lib/firmware/nanosic/MCU_Upgrade.bin
install -Dm755 %{SOURCE1} %{buildroot}%{_bindir}/nanosic-authd
install -Dm644 %{SOURCE2} %{buildroot}%{_unitdir}/nanosic-authd.service
install -Dm755 %{SOURCE3} %{buildroot}%{_bindir}/nanosic-backlight
install -Dm644 %{SOURCE4} %{buildroot}%{_unitdir}/nanosic-backlight.service
install -Dm755 %{SOURCE5} %{buildroot}%{_bindir}/nanosic-rebind
install -Dm644 %{SOURCE6} %{buildroot}%{_unitdir}/nanosic-rebind.service
install -Dm644 %{SOURCE7} %{buildroot}%{_modulesloaddir}/nanosic.conf
install -Dm644 %{SOURCE8} %{buildroot}%{_licensedir}/%{name}/LICENSE

%files
%license %{_licensedir}/%{name}/LICENSE
%dir /usr/lib/firmware/nanosic
/usr/lib/firmware/nanosic/MCU_Upgrade.bin
%{_bindir}/nanosic-authd
%{_bindir}/nanosic-backlight
%{_bindir}/nanosic-rebind
%{_unitdir}/nanosic-authd.service
%{_unitdir}/nanosic-backlight.service
%{_unitdir}/nanosic-rebind.service
%{_modulesloaddir}/nanosic.conf

%changelog
* Sat Nov 21 2026 Uke platform maintainers - 1.0.0-1
- Package the keyboard firmware, helpers and units that build-rootfs.sh had
  been copying into the image as loose files.

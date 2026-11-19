# Uke Fedora Builder

Tools and recipes for **Fedora 44 AArch64** release images for Xiaomi Pad 7
(`uke`, Qualcomm SM7675). Older Rawhide development targets for POCO Pad X1
and Xiaomi Pad 7 remain available.

The builder creates filesystem and boot-image artifacts. A completed build
alone does not establish that an image boots on the tablet.

## Known limitation: some H.264 video does not decode

Fedora ships exactly one H.264 decoder, `libopenh264`, because it disables
ffmpeg's own in the source RPM (`--disable-decoder="h264,hevc,vc1,vvc"`).
OpenH264's `PrefetchPic` rejects streams with more than a few reference frames,
so a High@L5.0 encode with `max_num_ref_frames=8` — Bilibili's higher-bitrate
transcodes, for instance — fails with:

```
[ffmpeg/video] libopenh264: PrefetchPic ERROR, pSps->iNumRefFrames:8
```

Every player shares that decoder, so mpv, VLC and both browsers fail the same
way. Forcing software rendering does not help: OpenH264 *is* the software path,
and hardware decoding is not an alternative either, because the tablet has no
V4L2 video device.

Two ways out, neither wired into the image:

1. **Re-encode the file** with fewer reference frames. Works with the packages
   already installed, and the picture is visually unchanged:

   ```sh
   ffmpeg -i in.mp4 -c:v libx264 -preset fast -crf 20 -c:a copy out.mp4
   ```

2. **Install a full decoder** from RPM Fusion free:

   ```sh
   sudo dnf install --allowerasing libavcodec-freeworld
   ```

   Both `rpmfusion-free` and `rpmfusion-free-updates` must be enabled: the base
   repository alone carries 8.0.1, whose sonames do not match Fedora's 8.1.3.
   `libavcodec-freeworld` conflicts with `libavcodec-free` by design, hence
   `--allowerasing`. Its dependencies resolve entirely from Fedora plus RPM
   Fusion free — the `nonfree` repository is not needed, and installing it in a
   clean container adds 730 packages on aarch64 without removing anything.

   The image builder does not enable RPM Fusion. Doing so is a local choice,
   not something a released image should impose.

## Build targets

| Target | What it produces | Intended use |
| --- | --- | --- |
| `core` | Fedora console root filesystem and separate UEFI development outputs | Base system and testing |
| `boot-pair` | Matched `fedora_boot.img` and `system.img` | Stock Android bootloader development route |
| `boot` | Older initramfs-only debug image | Early boot diagnostics; does not switch to the Fedora root |

The image recipes use original Fedora packages, including the standard KDE Plasma desktop where selected. Kernel sources and kernel RPM packaging live in the [kernel repository](https://github.com/linuxgamer/senemos-uke-kernel-mainline).

## Building

Three scripts build three different things and share only the kernel build:

```sh
# kernel RPMs only - install on a running tablet, boot_a follows automatically
./uke-fedora-builder/build-rpms.sh --output build/rpms

# boot_a only - skips the rootfs entirely
./uke-fedora-builder/build-boot-images.sh --profiles kde --output build/boot

# the rootfs and both images
./uke-fedora-builder/build-images.sh --cross-kernel --output build/images
```

See [build targets](docs/BUILD-TARGETS.md) for what each produces and which
change needs which one.

On an x86_64 PC, `--cross-kernel` makes Clang compile the ARM64 kernel directly
on the host CPU instead of compiling it under AArch64 emulation. This usually
saves time during the first kernel build. It does not change how the other RPMs
or Fedora rootfs are built. Omit the flag on an ARM64 host. If a verified
kernel build is already cached, the script reuses it either way; add
`--rebuild-kernel` only when you intentionally need to compile the kernel again.
See [Fedora 44 build cache](docs/BUILD-CACHE.md) for details.

The command creates separate TTY, KDE, GNOME, Phosh, and Plasma Mobile image
pairs by default. To build only selected profiles, pass a comma-separated list:

```sh
./uke-fedora-builder/build-images.sh --cross-kernel \
    --profiles kde,gnome --output build/images-desktop
```

The stock panel selector now enables native display by default. O82-36 offers
the seven fixed OEM modes: 30, 48, 50, 60, 90, 120 and 144 Hz. The owner has
observed 60 and 120 Hz switching with touch on one O82-36/TM tablet. Test the
other rates and sleep/wake before treating this mode set as release ready.
Keep the earlier working 60/120 boot image for recovery. Adaptive VRR remains
separate from these fixed modes.

Desktop selections also prepare the TTY rootfs and boot pair they share. The
output contains those TTY prerequisites as well as the requested profile pairs.
With `--resume`, you can add more profiles to the same output directory later.
In another terminal, inspect concise progress or stop the build:

```sh
./uke-fedora-builder/build-images.sh --status --output build/images
./uke-fedora-builder/build-images.sh --stop --output build/images
```

After interruption, restart with the same options and `--resume`:

```sh
./uke-fedora-builder/build-images.sh --cross-kernel --resume --output build/images
```

Completed RPMs and profile artifacts are reused only after their inputs and checksums
pass validation. The full output is also saved to `build.log`; stage transitions
are in `progress.log` and `status.json`. Rootfs phase timings are in each
profile's `timing.tsv`. The builder caches its tool containers, copies the
verified TTY rootfs as the base for desktop profiles, and reuses the TTY boot
image for their separate image pairs. Fedora downloads use a tested mirror by
default; see the build cache guide for the override.

The older upstream development targets remain available below.

Run these from the [Uke workspace](https://github.com/linuxgamer/uke-fedora), which provides `ukelinux.sh`:

```sh
./ukelinux.sh --build core --distro=fedora --test
./ukelinux.sh --build boot-pair --distro=fedora --help
./ukelinux.sh --build boot --distro=fedora --help
```

These examples are testing/help entry points, **not installation instructions**. See the workspace and `docs/` for complete image-production and device procedures.

## Before using an image

- Use a matched kernel, modules, device tree, initramfs and root filesystem.
- Preserve Android partitions, factory data, backups and a working recovery path.
- Host checks, virtual-machine results and successful builds are **not** proof of tablet compatibility.

For a prepared delivery directory, the workspace provides a read-only prerequisite check:

```sh
./ukelinux.sh --check-device --pair DELIVERY_DIRECTORY
```

Related: [Uke Fedora](https://github.com/linuxgamer/uke-fedora) · [Kernel](https://github.com/linuxgamer/senemos-uke-kernel-mainline) · [Hardware integration](https://github.com/linuxgamer/uke-linux-hardware-support)

See [LICENSE](LICENSE) for project tooling licensing.

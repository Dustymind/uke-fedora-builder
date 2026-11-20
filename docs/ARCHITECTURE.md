# How the Fedora 44 images are assembled

`build-images.sh` checks the bundled Xiaomi OS3.0.304.0 inputs,
builds the Linux 7.2.11 and hardware RPMs, then creates a shared TTY base.
Each selected desktop gets its own userdata image and matched `boot_a` image.
The output profiles are separate releases; they are not combined in one rootfs.

The kernel source, patches and RPM spec live in `senemos-uke-kernel/`. Device
RPMs and OEM payloads live in `uke-linux-hardware-support/`. The Fedora image
recipes and stock boot template live in this builder. Downloaded source files
and build products are kept outside Git.

The older Rawhide `core`, `boot` and `boot-pair` paths are development tools.
For the Xiaomi Pad 7 release, use the Fedora 44 command in [BUILDING.md](BUILDING.md).

## Where custom image configuration lives

Anything the image needs that a package can own is an RPM, including the
keyboard firmware, helpers and units, which `packaging/uke-keyboard-support.spec`
builds from `configs/nanosic/` during the image build. Everything else goes in
`configs/rootfs/`, which mirrors the target paths (`configs/rootfs/usr/lib/...`
lands at `/usr/lib/...`); `build-rootfs.sh` copies it inside the container, so
one actor owns the tree and the filesystem pass sees every file. `configs/rootfs-copr/`
is applied only when `UKE_COPR` is not 0. `audit-rootfs.sh` walks both trees and
requires each file to exist, stay a regular file, keep mode 0644 and root
ownership, and match its source byte for byte, so an edited asset cannot be
silently dropped. Both the trees and the keyboard package inputs feed
`BUILD-INPUTS.sha256`, which is what `--resume` compares.

## SELinux is off

The image boots with `selinux=0` on the kernel command line, carried by
`CONFIG_CMDLINE` in the kernel's `packaging/native/native.config`, and
`/etc/selinux/config` says `SELINUX=disabled` so user space does not load a
policy either. Consequently the build no longer relabels the tree:
`finalize-rootfs.sh` populates the EXT4 image and checks it with `e2fsck`, but
runs no label pass. SELinux support stays compiled into the kernel, but with
`selinux=0` the LSM never initialises. The `selinux-policy-targeted` package
still comes in with `@core`; nothing reads it.

## The KDE image carries no VM stack

Linux runs at EL1 on this SoC, so KVM cannot initialise and a libvirt stack
would only add units that never start. The KDE profile therefore installs no
`libvirt`, `virt-install`, `qemu` or `edk2` packages.

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
one actor owns the tree and the SELinux pass sees every file. `configs/rootfs-copr/`
is applied only when `UKE_COPR` is not 0. `audit-rootfs.sh` walks both trees and
requires each file to exist, stay a regular file, keep mode 0644 and root
ownership, and match its source byte for byte, so an edited asset cannot be
silently dropped. Both the trees and the keyboard package inputs feed
`BUILD-INPUTS.sha256`, which is what `--resume` compares.

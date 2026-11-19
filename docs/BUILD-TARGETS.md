# Build targets

Three scripts, three products.  They share the kernel build and nothing else:
no script builds what another one owns, and `--images` is gone.

| Script | Builds | Does not build |
| --- | --- | --- |
| `build-rpms.sh` | the matched kernel RPM set | rootfs, boot image, userdata |
| `build-boot-images.sh` | `fedora_boot.img` per profile | rootfs, userdata |
| `build-images.sh` | rootfs and both images | - |

## build-rpms.sh

```sh
./uke-fedora-builder/build-rpms.sh --output build/rpms
```

Produces `kernel-rpms/` holding three subpackages plus a `SHA256SUMS`:

```
senemos-uke-linux-kernel-mainline-core-<krel>.aarch64.rpm
senemos-uke-linux-kernel-mainline-modules-<krel>.aarch64.rpm
senemos-uke-linux-kernel-mainline-dtbs-<krel>.aarch64.rpm
```

Copy the directory to a tablet and install it:

```sh
sudo dnf install ./*.rpm
```

That updates `/usr/lib/modules` and nothing else.  `boot_a` is a separate
artifact and stays as it was: flash the `fedora_boot.img` that
`build-boot-images.sh` produces for the same kernel release.

The kernel `boot` subpackage is not staged.  It carries an Android v4 container
and a `%posttrans` that calls `uke-kernel-update` to write `boot_a`, which only
works where that tool is installed - and `build-rootfs.sh` forbids both it and
`uke-kernel-update` in the userdata image, because that image does not own
`boot_a`.  Staging it would ship a package whose dependencies cannot be
satisfied and whose scriptlet never runs.

## build-boot-images.sh

```sh
./uke-fedora-builder/build-boot-images.sh --profiles kde --output build/boot
```

Produces `kde-pair/fedora_boot.img` and its manifest.  No rootfs is built and no
`userdata.img` is produced, so the output is the boot image alone.

`boot_a` needs only the prepared kernel output - `Image`, the initramfs that is
already inside it, `.config` and `Module.symvers` - which is why the rootfs can
be skipped entirely.  The rootfs never contributed to the boot image; it
supplied the `userdata.img` that travels beside it.

Use this when the kernel release stays the same, so the installed `userdata` is
still valid.  The script refuses to produce an image whose release differs from
the package lock, because that combination is a boot loop: the modules in
`userdata` are built for one vermagic.

## build-images.sh

```sh
./uke-fedora-builder/build-images.sh --profiles kde --output build/images
```

The full path: rootfs, then `boot_a` and `userdata.img` per profile.  Needed
when the release changes or userspace changes.

## Which one

| Change | Target | Flash |
| --- | --- | --- |
| kernel only, release unchanged | `build-rpms.sh` + `build-boot-images.sh` | `boot_a` |
| kernel only, release unchanged, image wanted | `build-boot-images.sh` | `boot_a` |
| kernel release changed | `build-images.sh` | `boot_a` and `userdata` |
| userspace or package change | `build-images.sh` | `userdata` |

## Stages

Every target registers its stages before it starts, and `status.json` publishes
that total.  A stage cannot run unless the plan put it there, so a miscount now
names the offending stage instead of only reporting that a count is wrong:

```
build stage out of order: expected "kde rootfs", got "Audit release outputs"
```

The plan is derived from the component and package lists the build actually
iterates, and it includes the deferred cross-kernel stage only on an x86_64
host, which is where it runs.  A hand-maintained total previously made a
successful build exit non-zero after producing every artifact.

`--status` and `--stop` work against any of the three, as does `--resume`.

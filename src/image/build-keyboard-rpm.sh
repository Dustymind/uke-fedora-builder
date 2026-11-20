#!/usr/bin/env bash
# Build uke-keyboard-support from configs/nanosic.
#
# Nothing compiles and there is no source tarball: the package is a file list,
# so rpmbuild only has to copy eight inputs and a licence into a buildroot.  It
# still runs in a container, because the image build must not depend on the
# host having rpmbuild or on which rpm macros it happens to define.
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
builder=$(cd -- "$here/../.." && pwd)
release=${FEDORA_RELEASE:-44}
output='' image='' container=''

usage() {
    cat <<'HELP'
Usage: build-keyboard-rpm.sh --output DIR [--release 44]
       [--image IMAGE] [--container docker|podman]

Builds uke-keyboard-support-1.0.0-<release>.noarch.rpm from
configs/nanosic into DIR and prints the resulting path.  The image defaults
to the cached AArch64 tool image, which already carries rpm-build.
HELP
}
die() { printf 'build-keyboard-rpm: %s\n' "$*" >&2; exit 1; }

while (($#)); do
    case $1 in
        --output|--release|--image|--container)
            (($# >= 2)) || die "Missing value for $1"
            case $1 in
                --output) output=$2;;
                --release) release=$2;;
                --image) image=$2;;
                --container) container=$2;;
            esac
            shift 2;;
        --help|-h) usage; exit 0;;
        *) die "Unknown argument: $1";;
    esac
done

[[ -n $output ]] || die 'Provide --output'
[[ $release =~ ^[1-9][0-9]*$ ]] || die 'Invalid Fedora release'
if [[ -z $container ]]; then
    if [[ -n ${UKE_CONTAINER:-} ]]; then
        [[ $UKE_CONTAINER == docker || $UKE_CONTAINER == podman ]] || die 'UKE_CONTAINER must be docker or podman'
        container=$UKE_CONTAINER
    elif command -v podman >/dev/null; then container=podman
    elif command -v docker >/dev/null; then container=docker
    else die 'Docker or Podman is required'; fi
fi
command -v "$container" >/dev/null || die "$container is not installed"
[[ -n $image ]] || image=$(bash "$builder/src/image/ensure-build-image.sh" "$container" linux/arm64)

mkdir -p "$output"
output=$(realpath -- "$output")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
sources=$work/topdir/SOURCES
for dir in BUILD BUILDROOT RPMS SOURCES SPECS SRPMS; do mkdir -p "$work/topdir/$dir"; done
mkdir -p "$sources"

# The daemon keeps its former name in the image; the package names its source
# without the suffix so %install can drop it straight into %{_bindir}.
install -m644 -- "$builder/configs/nanosic/MCU_Upgrade.bin" "$sources/MCU_Upgrade.bin"
install -m644 -- "$builder/configs/nanosic/nanosic-authd.py" "$sources/nanosic-authd"
install -m644 -- "$builder/configs/nanosic/nanosic-authd.service" "$sources/nanosic-authd.service"
install -m755 -- "$builder/configs/nanosic/nanosic-backlight" "$sources/nanosic-backlight"
install -m644 -- "$builder/configs/nanosic/nanosic-backlight.service" "$sources/nanosic-backlight.service"
install -m755 -- "$builder/configs/nanosic/nanosic-rebind" "$sources/nanosic-rebind"
install -m644 -- "$builder/configs/nanosic/nanosic-rebind.service" "$sources/nanosic-rebind.service"
install -m644 -- "$builder/configs/nanosic/nanosic.conf" "$sources/nanosic.conf"
install -m644 -- "$builder/LICENSE" "$sources/LICENSE"
install -m644 -- "$builder/packaging/uke-keyboard-support.spec" "$work/topdir/SPECS/uke-keyboard-support.spec"

# rpmbuild runs as the container's root, the way every other stage of the image
# build does.  It copies the package out and removes its own scratch tree, so
# the host's trap can delete the temporary directory even when the container
# runtime is a rootful one.
cat > "$work/run.sh" <<'RUN'
set -Eeuo pipefail
rpmbuild -bb --define "_topdir /work/topdir" --define "dist .fc__RELEASE__" \
    /work/topdir/SPECS/uke-keyboard-support.spec
rpm=$(echo /work/topdir/RPMS/noarch/uke-keyboard-support-*.noarch.rpm)
test -f "$rpm"
install -m644 -- "$rpm" /out/
rm -rf /work/topdir
RUN
sed -i "s/__RELEASE__/$release/" "$work/run.sh"
"$container" run --rm --network=none --security-opt label=disable \
    -v "$work:/work" -v "$output:/out" "$image" bash /work/run.sh

rpm_file=$output/uke-keyboard-support-1.0.0-1.fc${release}.noarch.rpm
[[ -f $rpm_file ]] || die 'rpmbuild produced no package'
printf '%s\n' "$rpm_file"

#!/usr/bin/env bash
# Static checks for the build scripts, without compiling or building an image.
#
# The entry points share their libraries by sourcing them, so a script can call
# a shared function without sourcing the file that defines it.  Bash only
# reports that at the moment the call runs - after the kernel has been
# configured and compiled.  build-rpms.sh shipped exactly that defect and
# target=rpm died at exit code 127 on the first CI run that reached it.
#
# So for each entry point, every shared-library function it names must be
# reachable through the `source` lines it actually has.  Naming here is a
# word-match against the shared surface only - the four libraries below - so
# prose in a comment cannot be mistaken for a call to something unrelated.
#
# Nothing here builds, compiles or needs a container.
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
fail=0

complain() {
    printf '%s\n' "$*" >&2
    fail=1
}

# The shared surface: files more than one entry point sources.
shared=(
    src/image/build-common.sh
    src/image/build-control.sh
    src/image/build-kernel-rpms.sh
    src/image/package-lock.sh
)

functions_in() {
    local file=$1
    [[ -f $file ]] || return 0
    sed -nE 's/^([a-zA-Z_][a-zA-Z0-9_]*)\(\)[[:space:]]*\{?[[:space:]]*$/\1/p' "$file"
}

# Every function the shared surface defines.
declare -A shared_fn=()
for file in "${shared[@]}"; do
    while IFS= read -r name; do
        shared_fn[$name]=$file
    done < <(functions_in "$root/$file")
done

# Absolute paths one script sources, following $here-relative paths.
closure_of() {
    local script=$1 seen=' ' queue=() file rel
    queue=("$script")
    while ((${#queue[@]})); do
        file=${queue[0]}
        queue=("${queue[@]:1}")
        [[ $seen == *" $file "* ]] && continue
        seen+="$file "
        [[ -f $file ]] || continue
        while IFS= read -r rel; do
            [[ -n $rel ]] || continue
            queue+=("$root/$rel")
        done < <(sed -nE 's/^source "\$here\/([^"]+)".*/\1/p' "$file" 2>/dev/null)
    done
    printf '%s\n' $seen
}

check_script() {
    local script=$1 base rel file name
    base=$(basename "$script")
    [[ -f $script ]] || { complain "missing script: $script"; return; }
    bash -n "$script" || complain "syntax: $base"

    # A sourced file that does not exist is silent until its function is
    # called, so report it here instead.
    while IFS= read -r rel; do
        [[ -n $rel ]] || continue
        [[ -e $root/$rel ]] || complain "$base: sources missing file: $rel"
    done < <(sed -nE 's/^source "\$here\/([^"]+)".*/\1/p' "$script")

    local -a files=()
    mapfile -t files < <(closure_of "$script")

    local -A reachable=()
    for file in "${files[@]}"; do
        while IFS= read -r name; do
            reachable[$name]=1
        done < <(functions_in "$file")
    done

    local -a unresolved=()
    for name in "${!shared_fn[@]}"; do
        [[ -n ${reachable[$name]+x} ]] && continue
        grep -qE "(^|[^a-zA-Z0-9_])${name}([^a-zA-Z0-9_]|$)" "$script" || continue
        unresolved+=("$name")
    done
    if ((${#unresolved[@]})); then
        local joined
        joined=$(printf '%s, ' "${unresolved[@]}")
        complain "$base: names ${joined%, } from the shared libraries but does not source ${shared_fn[${unresolved[0]}]}"
    fi
}

for script in build-rpms.sh build-boot-images.sh build-images.sh \
              build-rootfs.sh build-boot-a.sh; do
    check_script "$root/$script"
done

# Every library must parse on its own.
for library in "$root"/src/image/*.sh; do
    bash -n "$library" || complain "syntax: ${library#"$root"/}"
done

if ((fail)); then
    printf 'Script checks failed\n' >&2
    exit 1
fi
printf 'Script checks passed: every entry point parses, its sources exist, and it sources every shared library it names\n'

#!/usr/bin/env python3
"""Fail on a scriptlet that failed; summarise the output of the ones that did not.

DNF runs package scriptlets against an installroot, so a scriptlet may print
messages such as "Failed to update catalog: No such file or directory" while
still exiting zero: the runtime it wanted does not exist yet and the work is
repeated on first boot.  Those lines are not errors, but reviewing them one
literal string at a time did not scale - any new package could add another one
and fail a build that was fine.

What does scale is the verdict the tools already produce.  When a scriptlet
exits non-zero, DNF reports it in its own words, for any phase and any package:

    >>> Non-critical error in %post scriptlet: foo-1-1.noarch
    >>> [RPM] %post(foo-1-1.noarch) scriptlet failed, exit status 1

and the transaction fails, so the build stops there anyway.  This audit reads
those markers and nothing else, then counts the remaining scriptlet output per
package so the log stays reviewable without turning package chatter into a gate.
"""

import collections
import pathlib
import re
import sys

COUNT = "{:5d}"
EPOCH = re.compile(r"-\d+:")

RUNNING = re.compile(r"^(Running|Finished) (\S+) scriptlet: (\S+)$")
RPM_FAILED = re.compile(r"^\[RPM\] ([^()]+)\(([^)]+)\) scriptlet failed, (?:exit status|signal) \d+$")
DNF_FAILED = re.compile(r"^Non-critical error in (\S+) scriptlet: (\S+)$")


def nevra(package: str) -> str:
    """Drop the epoch so the same package reads the same in both messages.

    DNF names it ``foo-0:1-2.noarch`` and RPM names it ``foo-1-2.noarch``; one
    failed scriptlet produces both lines and should be reported once.
    """
    return EPOCH.sub("-", package, count=1)


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: audit-build-log.py BUILD.LOG RUN_ID", file=sys.stderr)
        return 2
    log = pathlib.Path(sys.argv[1])
    marker = f"===== UKE BUILD RUN {sys.argv[2]} ====="
    lines = log.read_text(errors="replace").splitlines()
    try:
        start = len(lines) - 1 - lines[::-1].index(marker)
    except ValueError:
        print("build log audit: current run marker is missing", file=sys.stderr)
        return 1

    owner = "unattributed"
    output = collections.Counter()
    failures = {}
    in_output = False
    for number, raw in enumerate(lines[start + 1 :], start + 2):
        if not raw.startswith(">>> "):
            in_output = False
            continue
        line = raw[4:]
        if line == "Scriptlet output:":
            in_output = True
            continue
        running = RUNNING.match(line)
        if running:
            if running.group(1) == "Running":
                owner = running.group(3)
            in_output = False
            continue
        failed = RPM_FAILED.match(line) or DNF_FAILED.match(line)
        if failed:
            phase, package = failed.group(1), nevra(failed.group(2))
            failures.setdefault((package, phase), number)
            continue
        if in_output and line:
            output[owner] += 1

    for (package, phase), number in sorted(failures.items(), key=lambda item: item[1]):
        print(f"build log audit: {phase} scriptlet failed in {package} (log line {number})", file=sys.stderr)
    if failures:
        return 1

    total = sum(output.values())
    if not total:
        print("build log audit: no scriptlet output in this run")
        return 0
    print(
        f"build log audit: {total} scriptlet output lines from {len(output)} package(s); "
        "no scriptlet failed"
    )
    for package, count in output.most_common(10):
        print(f"build log audit:   {COUNT.format(count)}  {package}")
    if len(output) > 10:
        print(f"build log audit:   ({len(output) - 10} more package(s) in build.log)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Find newer versions of the pinned packages of one service.

    .find-updates.py [--tool micromamba] [--apply] <service>

Pinned lines:

    <service>/requirements.txt       name=version     versions from conda-forge
    <service>/pip-requirements.txt   name==version    versions from PyPI
                                     (extras like patroni[etcd3] are fine)

A trailing comment sets how a line is updated:

    postgresql=18.7  # update: minor    newest release with the same first
                                        number (18.x, never 19)
    pgvector=0.8.6   # update: latest   newest release
    python=3.12      # update: no       never

Without a comment, the first pinned line of requirements.txt follows
"latest" (it names the image and its tag) and every other line "no". Only
final releases count (1.2.3, not 1.3.0rc1).

Prints one tab separated line per bump: file, package, old, new. With
--apply the files are rewritten as well; the rest of each line, its comment
included, stays as it is. Exits non-zero on a line it cannot read or an
unknown rule, so a typo does not quietly stop the updates of a package.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import urllib.request
from dataclasses import dataclass

RULES = {"latest", "minor", "no"}
RULE = re.compile(r"^\s*update:\s*(\S+)\s*$")
RELEASE = re.compile(r"^\d+(?:\.\d+)*$")
CONDA_PIN = re.compile(r"^(?P<name>[A-Za-z0-9_.\-]+)\s*=\s*(?P<version>[^=<>!~*,\s]+)$")
PIP_PIN = re.compile(
    r"^(?P<name>[A-Za-z0-9_.\-]+)(?P<extras>\[[^\]]*\])?\s*==\s*(?P<version>[^=<>!~*,;\s]+)$"
)


@dataclass
class Pin:
    file: pathlib.Path
    lineno: int
    name: str
    version: str
    rule: str
    source: str  # "conda" or "pip"


def key(version: str) -> tuple[int, ...]:
    return tuple(int(n) for n in version.split("."))


def split_comment(line: str) -> tuple[str, str]:
    code, _, comment = line.partition("#")
    return code.strip(), comment.strip()


def read_pins(path: pathlib.Path, source: str) -> list[Pin]:
    """The pinned lines of one file with their rules."""
    if not path.is_file():
        return []
    pins: list[Pin] = []
    first = source == "conda"
    for lineno, line in enumerate(path.read_text().splitlines(), start=1):
        code, comment = split_comment(line)
        if not code:
            continue
        rule = None
        if comment:
            match = RULE.match(comment)
            if match is None:
                raise SystemExit(f"{path}:{lineno}: a comment must read '# update: <rule>', not '# {comment}'")
            rule = match.group(1)
            if rule not in RULES:
                raise SystemExit(f"{path}:{lineno}: unknown rule '{rule}', use one of {sorted(RULES)}")
        match = (CONDA_PIN if source == "conda" else PIP_PIN).match(code)
        if match is None:
            # Unpinned or a range: not ours, unless a rule asks for updates.
            if rule not in (None, "no"):
                raise SystemExit(f"{path}:{lineno}: '# update: {rule}' needs an exact pin, not '{code}'")
            if "=" in code:
                # The first line with a version names the image tag, as in
                # docker-build.yml, even when it is not an exact pin.
                first = False
            continue
        version = match.group("version")
        if not RELEASE.match(version):
            if rule not in (None, "no"):
                raise SystemExit(f"{path}:{lineno}: cannot update '{version}', only versions like 1.2.3")
            first = False
            continue
        if rule is None:
            rule = "latest" if first else "no"
        first = False
        pins.append(Pin(path, lineno, match.group("name"), version, rule, source))
    return pins


def conda_versions(name: str, tool: str) -> list[str]:
    out = subprocess.run(
        [tool, "search", name, "--channel", "conda-forge", "--override-channels", "--json"],
        check=True, capture_output=True, text=True,
    ).stdout
    pkgs = json.loads(out).get("result", {}).get("pkgs", [])
    return [p["version"] for p in pkgs if p.get("name", name) == name]


def pip_versions(name: str) -> list[str]:
    with urllib.request.urlopen(f"https://pypi.org/pypi/{name}/json", timeout=30) as resp:
        releases = json.load(resp)["releases"]
    # A release whose files are all yanked does not count.
    return [v for v, files in releases.items() if files and not all(f.get("yanked") for f in files)]


def newest(pin: Pin, versions: list[str]) -> str | None:
    """The version the pin should move to, or None."""
    if pin.rule == "no":
        return None
    candidates = [v for v in versions if RELEASE.match(v)]
    if pin.rule == "minor":
        major = key(pin.version)[0]
        candidates = [v for v in candidates if key(v)[0] == major]
    if not candidates:
        return None
    best = max(candidates, key=key)
    return best if key(best) > key(pin.version) else None


def rewrite(pin: Pin, new: str) -> None:
    lines = pin.file.read_text().splitlines(keepends=True)
    line = lines[pin.lineno - 1]
    op = "=" if pin.source == "conda" else "=="
    pattern = re.compile(
        rf"^(\s*{re.escape(pin.name)}(?:\[[^\]]*\])?\s*{op}\s*){re.escape(pin.version)}(?=\s|#|$)"
    )
    updated, count = pattern.subn(lambda m: m.group(1) + new, line, count=1)
    if count != 1:
        raise SystemExit(f"{pin.file}:{pin.lineno}: could not rewrite '{line.rstrip()}'")
    lines[pin.lineno - 1] = updated
    pin.file.write_text("".join(lines))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("service")
    parser.add_argument("--tool", default="micromamba", help="conda-compatible tool for 'search'")
    parser.add_argument("--apply", action="store_true", help="rewrite the files")
    args = parser.parse_args()

    service = pathlib.Path(args.service)
    pins = read_pins(service / "requirements.txt", "conda")
    pins += read_pins(service / "pip-requirements.txt", "pip")
    for pin in pins:
        if pin.rule == "no":
            continue
        try:
            versions = conda_versions(pin.name, args.tool) if pin.source == "conda" else pip_versions(pin.name)
        except Exception as exc:  # index down, package gone: say so, go on
            print(f"⚠️  {pin.file}: could not look up {pin.name}: {exc}", file=sys.stderr)
            continue
        new = newest(pin, versions)
        if new is None:
            print(f"✅ {pin.name} {pin.version} ({pin.rule}) is up-to-date", file=sys.stderr)
            continue
        print(f"{pin.file}\t{pin.name}\t{pin.version}\t{new}")
        if args.apply:
            rewrite(pin, new)
    return 0


if __name__ == "__main__":
    sys.exit(main())

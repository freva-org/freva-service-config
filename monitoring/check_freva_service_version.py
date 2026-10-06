#!/usr/bin/env python3
"""Nagios / Icinga plugin: is a Freva service container out of date?

Compares the version of the image a running container was started from with
the newest version published for that service on ghcr.io
(ghcr.io/freva-org/freva-<service>).

* deployed version: the ``org.opencontainers.image.version`` label that the
  freva-service-config Dockerfile stamps into every image. It is read from the
  *running container*, so a newer image that was pulled but not yet started
  still counts as "not deployed".
* latest version:   the highest X.Y.Z tag in the registry.

By default the plugin returns

    OK        same version, deployed is newer, or only the patch level differs
    WARNING   the deployed version is behind by a minor version
    CRITICAL  the deployed version is behind by a major version
    UNKNOWN   anything that prevents a reliable comparison

The thresholds can be moved with ``--warning-on`` / ``--critical-on``.

Only the Python standard library is used, so the plugin runs on any monitoring
host or Icinga agent with python3 and podman.

Example::

    check_freva_service_version.py --service mlflow --container mlflow

Containers started by root-owned quadlet units live in root's podman storage.
If the Icinga agent runs as an unprivileged user, allow it to inspect them via
sudo and pass ``--sudo`` (see monitoring/README.md).
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Iterable, List, NoReturn, Optional, Tuple

OK, WARNING, CRITICAL, UNKNOWN = 0, 1, 2, 3
STATE_NAMES = {OK: "OK", WARNING: "WARNING", CRITICAL: "CRITICAL", UNKNOWN: "UNKNOWN"}
LEVELS = ("patch", "minor", "major", "never")
VERSION_LABEL = "org.opencontainers.image.version"
VERSION_RE = re.compile(r"^v?(\d+)\.(\d+)(?:\.(\d+))?$")

Version = Tuple[int, int, int]


def plugin_exit(state: int, message: str, perfdata: str = "") -> NoReturn:
    """Print the status line in the format Nagios/Icinga expects and exit."""
    line = f"{STATE_NAMES[state]} - {message}"
    if perfdata:
        line += f" | {perfdata}"
    print(line)
    sys.exit(state)


def parse_version(text: str) -> Optional[Version]:
    """Parse ``X.Y`` / ``X.Y.Z`` (optionally ``v``-prefixed) into a tuple."""
    match = VERSION_RE.match(text.strip())
    if not match:
        return None
    major, minor, patch = match.groups()
    return int(major), int(minor), int(patch or 0)


def fmt(version: Version) -> str:
    return ".".join(str(part) for part in version)


def difference(deployed: Version, latest: Version) -> str:
    """How far ``deployed`` lags behind ``latest``.

    Returns one of ``none`` (up to date or newer), ``patch``, ``minor`` or
    ``major``.
    """
    if deployed >= latest:
        return "none"
    if deployed[0] < latest[0]:
        return "major"
    if deployed[1] < latest[1]:
        return "minor"
    return "patch"


###############################################################################
# Registry
###############################################################################


def _http_get(url: str, timeout: float, headers: Optional[dict] = None):
    request = urllib.request.Request(url, headers=headers or {})
    return urllib.request.urlopen(request, timeout=timeout)


def _next_link(link_header: Optional[str], base: str) -> Optional[str]:
    """Follow the OCI ``Link: <...>; rel="next"`` pagination header."""
    if not link_header:
        return None
    match = re.search(r'<([^>]+)>\s*;\s*rel="?next"?', link_header)
    if not match:
        return None
    return urllib.parse.urljoin(base, match.group(1))


def registry_tags(registry: str, repository: str, timeout: float) -> List[str]:
    """Return all tags of a public repository using the anonymous token flow."""
    base = f"https://{registry}"
    scope = urllib.parse.quote(f"repository:{repository}:pull", safe=":/")
    with _http_get(f"{base}/token?scope={scope}", timeout) as response:
        token = json.load(response)["token"]

    headers = {"Authorization": f"Bearer {token}"}
    url: Optional[str] = f"{base}/v2/{repository}/tags/list?n=1000"
    tags: List[str] = []
    # Guard against a misbehaving registry returning the same page forever.
    for _ in range(100):
        if url is None:
            break
        with _http_get(url, timeout, headers) as response:
            tags.extend(json.load(response).get("tags") or [])
            url = _next_link(response.headers.get("Link"), base)
    return tags


def latest_version(tags: Iterable[str]) -> Optional[Version]:
    versions = [v for v in (parse_version(tag) for tag in tags) if v is not None]
    return max(versions) if versions else None


###############################################################################
# Deployed container
###############################################################################


def deployed_version(
    container: str, use_sudo: bool, timeout: float
) -> Tuple[Version, str]:
    """Read the image version label from the running container.

    ``podman ps`` is used rather than ``podman container inspect``: its JSON
    carries state, image and labels but *not* the container environment, so
    granting the monitoring user sudo for it does not expose the service
    secrets passed in via EnvironmentFile=.
    """
    podman = shutil.which("podman") or "podman"
    cmd = [podman, "ps", "--all", "--format", "json", "--filter", f"name=^{container}$"]
    if use_sudo:
        cmd = ["sudo", "-n"] + cmd

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
    except FileNotFoundError as error:
        plugin_exit(UNKNOWN, f"cannot run {error.filename}")
    except subprocess.TimeoutExpired:
        plugin_exit(UNKNOWN, f"'{' '.join(cmd)}' timed out after {timeout:.0f}s")

    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        detail_text = detail[-1] if detail else f"exit code {result.returncode}"
        plugin_exit(UNKNOWN, f"podman ps failed: {detail_text}")

    try:
        containers = json.loads(result.stdout or "[]") or []
    except ValueError as error:
        plugin_exit(UNKNOWN, f"cannot parse podman ps output: {error}")

    # A container that is not there is a real problem, not an unknown.
    if not containers:
        plugin_exit(CRITICAL, f"container '{container}' does not exist")
    info = containers[0]

    state = str(info.get("State", "unknown")).lower()
    if state != "running":
        plugin_exit(CRITICAL, f"container '{container}' is {state}")

    image = info.get("Image", "?")
    labels = info.get("Labels") or {}
    label = labels.get(VERSION_LABEL)
    if not label:
        plugin_exit(
            UNKNOWN, f"image {image} of '{container}' has no {VERSION_LABEL} label"
        )

    version = parse_version(label)
    if version is None:
        plugin_exit(
            UNKNOWN, f"cannot parse deployed version '{label}' of '{container}'"
        )
    return version, image


###############################################################################
# Main
###############################################################################


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "-s",
        "--service",
        default="mlflow",
        help="Freva service, selects the image ghcr.io/freva-org/freva-<service>.",
    )
    parser.add_argument(
        "-c",
        "--container",
        default=None,
        help="Name of the running container. Defaults to the service name.",
    )
    parser.add_argument(
        "--image",
        default=None,
        help="Registry repository to compare with, overrides --service "
        "(e.g. freva-org/freva-mlflow).",
    )
    parser.add_argument("--registry", default="ghcr.io", help="Registry host.")
    parser.add_argument(
        "-w",
        "--warning-on",
        choices=LEVELS,
        default="minor",
        help="Warn when the deployed version is behind by at least this much.",
    )
    parser.add_argument(
        "-C",
        "--critical-on",
        choices=LEVELS,
        default="major",
        help="Go critical when the deployed version is behind by at least this much.",
    )
    parser.add_argument(
        "--sudo",
        action="store_true",
        help="Run podman through 'sudo -n' (for root-owned quadlet containers).",
    )
    parser.add_argument(
        "-t",
        "--timeout",
        type=float,
        default=20.0,
        help="Timeout in seconds for each registry request and the podman call.",
    )
    args = parser.parse_args(argv)
    args.container = args.container or args.service
    args.image = args.image or f"freva-org/freva-{args.service}"
    return args


def state_for(lag: str, warning_on: str, critical_on: str) -> int:
    """Map how far behind we are onto a plugin state."""
    rank = {"none": -1, "patch": 0, "minor": 1, "major": 2, "never": 99}
    if rank[lag] >= rank[critical_on]:
        return CRITICAL
    if rank[lag] >= rank[warning_on]:
        return WARNING
    return OK


def main(argv: Optional[List[str]] = None) -> NoReturn:
    args = parse_args(argv)

    deployed, image = deployed_version(args.container, args.sudo, args.timeout)

    try:
        tags = registry_tags(args.registry, args.image, args.timeout)
    except urllib.error.HTTPError as error:
        plugin_exit(
            UNKNOWN, f"{args.registry}/{args.image}: HTTP {error.code} {error.reason}"
        )
    except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
        reason = getattr(error, "reason", error)
        plugin_exit(UNKNOWN, f"cannot query {args.registry}/{args.image}: {reason}")

    latest = latest_version(tags)
    if latest is None:
        plugin_exit(UNKNOWN, f"no X.Y.Z tags found for {args.registry}/{args.image}")

    lag = difference(deployed, latest)
    state = state_for(lag, args.warning_on, args.critical_on)

    name = args.service
    if lag == "none":
        message = f"{name} {fmt(deployed)} is up to date"
        if deployed > latest:
            message += f" (newer than registry {fmt(latest)})"
    else:
        message = (
            f"{name} {fmt(deployed)} is a {lag} version behind {fmt(latest)} "
            f"(container {args.container}, image {image})"
        )

    behind = {"none": 0, "patch": 1, "minor": 2, "major": 3}[lag]
    perfdata = f"versions_behind_level={behind};;;0;3"
    plugin_exit(state, message, perfdata)


if __name__ == "__main__":
    main()

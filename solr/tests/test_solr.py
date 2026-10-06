#!/usr/bin/env python3
"""Integration test for the Freva Solr image.

Runs in a plain Python container (standard library only) on the test network
and talks to Solr by its network alias, see run.sh.

Subcommands:

wait      wait until the cores "files" and "latest" are loaded
seed      with the *current* image: index sample records into both cores and
          leave a half-finished rotation core behind, as a crashed blue/green
          rotation would
verify    with the *new* image, on the same data directory: cores load, the
          stale rotation core was cleaned up, the seeded records are found by
          the queries Freva runs, the schema rejects unknown fields, new
          records can be written, and a blue/green rotation works
restarted after restarting the new image: the rotated core survived
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Dict, List, Optional

SOLR = os.environ.get("CI_SOLR_URL", "http://solr:8983/solr")
CONFIGSET = "freva"
STALE_CORE = "files_crashed"
ROTATION_CORE = "files_rotation"
EXTRA_ROTATION_DOCS = 2

FAILURES: List[str] = []


###############################################################################
# Sample data: one source of truth for what is indexed and what is expected.
###############################################################################


def sample_docs() -> List[Dict[str, Any]]:
    docs = []
    for i in range(8):
        project = "CMIP6" if i < 5 else "CORDEX"
        path = f"/work/ci/{project}/model{i % 2}/var{i % 4}_{i}.nc"
        docs.append(
            {
                "file": path,
                "uri": f"file://{path}",
                "file_name": os.path.basename(path),
                "project": project,
                "product": "model-output",
                "institute": "MPI-M",
                "model": ["MPI-ESM1-2-LR", "ICON-ESM-LR"][i % 2],
                "experiment": ["historical", "amip"][i % 2],
                "ensemble": "r1i1p1f1",
                "realm": "atmos",
                "variable": ["tas", "pr", "ua", "va"][i % 4],
                "cmor_table": "Amon",
                # indexed as given, found through the synonyms in synonyms.txt
                "time_frequency": "1mon" if i % 2 == 0 else "day",
                "time": (
                    "[1990-01-01T00:00:00Z TO 1999-12-31T23:59:59Z]"
                    if i < 4
                    else "[2015-01-01T00:00:00Z TO 2100-12-31T00:00:00Z]"
                ),
                "bbox": (
                    "ENVELOPE(-180, 180, 90, -90)"
                    if project == "CMIP6"
                    else "ENVELOPE(-10, 30, 70, 35)"  # Europe
                ),
            }
        )
    return docs


DOCS = sample_docs()
LATEST_DOCS = DOCS[:4]


def count(docs: List[Dict[str, Any]], predicate: Callable[[Dict[str, Any]], bool]) -> int:
    return sum(1 for doc in docs if predicate(doc))


###############################################################################
# Solr helpers
###############################################################################


def solr(path: str, params: Optional[Dict[str, Any]] = None, body: Any = None) -> Dict[str, Any]:
    query = urllib.parse.urlencode({**(params or {}), "wt": "json"}, doseq=True)
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(f"{SOLR}{path}?{query}", data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def core_status() -> Dict[str, Any]:
    return solr("/admin/cores", {"action": "STATUS"})


def num_found(core: str, q: str = "*:*", fq: Optional[List[str]] = None) -> int:
    params: Dict[str, Any] = {"q": q, "rows": 0}
    if fq:
        params["fq"] = fq
    return solr(f"/{core}/select", params)["response"]["numFound"]


def index(core: str, docs: List[Dict[str, Any]]) -> None:
    solr(f"/{core}/update", {"commit": "true"}, docs)


def check(name: str, func: Callable[[], Optional[str]]) -> None:
    try:
        detail = func()
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")[:400]
        FAILURES.append(name)
        print(f"FAIL  {name}: HTTP {error.code}: {body}", flush=True)
        return
    except Exception as error:  # noqa: BLE001 - report every failure
        FAILURES.append(name)
        print(f"FAIL  {name}: {type(error).__name__}: {error}", flush=True)
        return
    print(f"ok    {name}{f' ({detail})' if detail else ''}", flush=True)


def expect(actual: Any, wanted: Any, what: str) -> str:
    if actual != wanted:
        raise AssertionError(f"{what}: expected {wanted}, got {actual}")
    return f"{what} = {actual}"


###############################################################################
# Subcommands
###############################################################################


def wait(timeout: float) -> None:
    deadline = time.monotonic() + timeout
    last = "no answer"
    while time.monotonic() < deadline:
        try:
            status = core_status()
            if status.get("initFailures"):
                raise SystemExit(f"Solr reports core init failures: {status['initFailures']}")
            cores = status.get("status", {})
            if "files" in cores and "latest" in cores:
                # On a first start init-solr runs a temporary Solr that creates
                # the cores with the default schema, then restarts. Only the
                # final instance serves the freva schema, so wait for it.
                for core in ("files", "latest"):
                    solr(f"/{core}/schema/fields/uri")
                print("Solr is up, cores files and latest serve the freva schema", flush=True)
                return
            last = f"cores loaded: {sorted(cores)}"
        except (urllib.error.URLError, OSError, ValueError) as error:
            last = type(error).__name__
        time.sleep(2)
    raise SystemExit(f"Solr not ready after {timeout:.0f}s: {last}")


def seed() -> None:
    check("index sample records into files", lambda: (index("files", DOCS), f"{len(DOCS)} records")[1])
    check(
        "index sample records into latest",
        lambda: (index("latest", LATEST_DOCS), f"{len(LATEST_DOCS)} records")[1],
    )

    def stale_core() -> str:
        # A rotation that died before swapping leaves a files_* core behind;
        # the next container start must remove it.
        solr(
            "/admin/cores",
            {"action": "CREATE", "name": STALE_CORE, "instanceDir": STALE_CORE, "configSet": CONFIGSET},
        )
        index(STALE_CORE, DOCS[:1])
        return STALE_CORE

    check("leave a stale rotation core behind", stale_core)


def verify() -> None:
    status = core_status()

    check("no core init failures", lambda: expect(status.get("initFailures"), {}, "initFailures"))
    check(
        "stale rotation core removed on start",
        lambda: expect(STALE_CORE in status.get("status", {}), False, f"{STALE_CORE} present"),
    )

    check("seeded records in files", lambda: expect(num_found("files"), len(DOCS), "files"))
    check("seeded records in latest", lambda: expect(num_found("latest"), len(LATEST_DOCS), "latest"))

    cmip6 = count(DOCS, lambda d: d["project"] == "CMIP6")
    check(
        "facet values are case-insensitive",
        lambda: expect(num_found("files", "project:cmip6"), cmip6, "project:cmip6"),
    )
    check(
        "synonyms: 'months' finds '1mon'",
        lambda: expect(
            num_found("files", "time_frequency:months"),
            count(DOCS, lambda d: d["time_frequency"] == "1mon"),
            "time_frequency:months",
        ),
    )
    check(
        "synonyms: 'dy' finds 'day'",
        lambda: expect(
            num_found("files", "time_frequency:dy"),
            count(DOCS, lambda d: d["time_frequency"] == "day"),
            "time_frequency:dy",
        ),
    )

    def facets() -> str:
        result = solr(
            "/files/select",
            {"q": "*:*", "rows": 0, "facet": "true", "facet.field": "project", "facet.mincount": 1},
        )
        flat = result["facet_counts"]["facet_fields"]["project"]
        got = dict(zip(flat[::2], flat[1::2], strict=True))
        wanted = {"cmip6": cmip6, "cordex": len(DOCS) - cmip6}
        return expect(got, wanted, "project facet")

    check("facet counts", facets)

    check(
        "time range intersects",
        lambda: expect(
            num_found("files", fq=["{!field f=time op=Intersects}[1995-01-01T00:00:00Z TO 1996-01-01T00:00:00Z]"]),
            count(DOCS, lambda d: d["time"].startswith("[1990")),
            "records covering 1995",
        ),
    )
    check(
        "bbox intersects",
        lambda: expect(
            num_found("files", fq=['bbox:"Intersects(ENVELOPE(100, 110, 10, 0))"']),
            count(DOCS, lambda d: d["bbox"].startswith("ENVELOPE(-180")),
            "records covering south-east Asia",
        ),
    )

    def unknown_field_rejected() -> str:
        doc = {**DOCS[0], "file": "/ci/bogus.nc", "uri": "file:///ci/bogus.nc", "bogus_field": "x"}
        try:
            index("files", [doc])
        except urllib.error.HTTPError as error:
            if error.code == 400:
                return "HTTP 400"
            raise
        raise AssertionError("a record with an unknown field was accepted")

    check("unknown fields are rejected (autoCreateFields off)", unknown_field_rejected)

    def write_new_record() -> str:
        path = "/work/ci/new-after-upgrade.nc"
        index("latest", [{**DOCS[0], "file": path, "uri": f"file://{path}", "file_name": "new.nc"}])
        return expect(num_found("latest"), len(LATEST_DOCS) + 1, "latest")

    check("write a new record", write_new_record)

    def rotation() -> str:
        # Blue/green: build a fresh core from the freva configset, swap it in
        # for "files", drop the old one.
        solr(
            "/admin/cores",
            {"action": "CREATE", "name": ROTATION_CORE, "instanceDir": ROTATION_CORE, "configSet": CONFIGSET},
        )
        extra = []
        for i in range(EXTRA_ROTATION_DOCS):
            path = f"/work/ci/rotation-{i}.nc"
            extra.append({**DOCS[0], "file": path, "uri": f"file://{path}", "file_name": f"rotation-{i}.nc"})
        index(ROTATION_CORE, DOCS + extra)
        solr("/admin/cores", {"action": "SWAP", "core": "files", "other": ROTATION_CORE})
        solr(
            "/admin/cores",
            {"action": "UNLOAD", "core": ROTATION_CORE, "deleteInstanceDir": "true", "deleteIndex": "true"},
        )
        return expect(num_found("files"), len(DOCS) + EXTRA_ROTATION_DOCS, "files after swap")

    check("blue/green rotation via the freva configset", rotation)


def restarted() -> None:
    status = core_status()
    check("no core init failures after restart", lambda: expect(status.get("initFailures"), {}, "initFailures"))
    check(
        "rotated core survives the restart",
        lambda: expect(num_found("files"), len(DOCS) + EXTRA_ROTATION_DOCS, "files"),
    )
    check("latest survives the restart", lambda: expect(num_found("latest"), len(LATEST_DOCS) + 1, "latest"))
    check(
        "rotation core is gone",
        lambda: expect(ROTATION_CORE in status.get("status", {}), False, f"{ROTATION_CORE} present"),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    wait_parser = sub.add_parser("wait")
    wait_parser.add_argument("--timeout", type=float, default=180)
    for name in ("seed", "verify", "restarted"):
        sub.add_parser(name)
    args = parser.parse_args()

    if args.command == "wait":
        wait(args.timeout)
        return 0
    {"seed": seed, "verify": verify, "restarted": restarted}[args.command]()
    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed: {', '.join(FAILURES)}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

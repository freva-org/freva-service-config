#!/usr/bin/env python3
"""Integration test for the Freva MLflow image against a production-like stack.

Runs inside an MLflow image container on the test network (see run.sh) and
talks to MLflow, Keycloak and the S3 gateway by their network aliases.

Subcommands:

prepare  create the artifact bucket (needs the S3 root credentials)
seed     with the *current* image: create a workspace and some data as
         normal users, so the new image is tested against a database written
         by the version that is deployed today
verify   with the *new* image: health, authorization, the seeded data and a
         full experiment/run/metric/artifact round trip

Users come from the freva realm in keycloak/import/realm-export.json; run.sh
puts them into groups:

    alicebrown  mlflow-admin   creates the workspace and grants access
    johndoe     hpc-user       normal user, does the actual work
    bobsmith    (no group)     must be denied
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable, Dict, Optional

import requests

MLFLOW_URL = os.environ.get("CI_MLFLOW_URL", "http://mlflow:8080")
KEYCLOAK_URL = os.environ.get("CI_KEYCLOAK_URL", "http://keycloak:8080")
REALM = os.environ.get("CI_REALM", "freva")
CLIENT_ID = os.environ.get("CI_CLIENT_ID", "freva")
WORKSPACE = os.environ.get("CI_WORKSPACE", "ci-project")
BUCKET = os.environ.get("CI_BUCKET", "mlflow-artifacts")
# Header the MLflow client uses to select the workspace (mlflow.utils.workspace_utils).
WORKSPACE_HEADER = "X-MLFLOW-WORKSPACE"

ADMIN = ("alicebrown", "alicebrown123")
USER = ("johndoe", "johndoe123")
OUTSIDER = ("bobsmith", "bobsmith123")

SEED_EXPERIMENT = "seeded-before-upgrade"
SEED_ARTIFACT = "seed.txt"
SEED_CONTENT = "written by the previous MLflow image\n"
SEED_METRIC_STEPS = 5
ARTIFACT_SIZE = 1024 * 1024

FAILURES: list[str] = []


###############################################################################
# Helpers
###############################################################################


def check(name: str, func: Callable[[], Optional[str]]) -> None:
    """Run one check, print the result and remember failures."""
    try:
        detail = func()
    except Exception as error:  # noqa: BLE001 - report every failure
        FAILURES.append(name)
        print(f"FAIL  {name}: {type(error).__name__}: {error}", flush=True)
        return
    suffix = f" ({detail})" if detail else ""
    print(f"ok    {name}{suffix}", flush=True)


def get_token(username: str, password: str) -> str:
    """Password grant against the freva realm (direct access grants)."""
    response = requests.post(
        f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect/token",
        data={
            "grant_type": "password",
            "client_id": CLIENT_ID,
            "username": username,
            "password": password,
            "scope": "openid profile email",
        },
        timeout=30,
    )
    response.raise_for_status()
    return response.json()["access_token"]


def act_as(token: Optional[str], workspace: Optional[str] = WORKSPACE) -> None:
    """Make the MLflow client use this bearer token and workspace."""
    import mlflow

    if token is None:
        os.environ.pop("MLFLOW_TRACKING_TOKEN", None)
    else:
        os.environ["MLFLOW_TRACKING_TOKEN"] = token
    mlflow.set_tracking_uri(MLFLOW_URL)
    mlflow.set_workspace(workspace)


def rest(method: str, path: str, token: Optional[str], **kwargs) -> requests.Response:
    headers: Dict[str, str] = kwargs.pop("headers", {})
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return requests.request(
        method,
        f"{MLFLOW_URL}{path}",
        headers=headers,
        timeout=60,
        allow_redirects=False,
        **kwargs,
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def wait_for(url: str, timeout: float = 180) -> None:
    deadline = time.monotonic() + timeout
    last = "no response"
    while time.monotonic() < deadline:
        try:
            response = requests.get(url, timeout=5)
            if response.ok:
                return
            last = f"HTTP {response.status_code}"
        except requests.RequestException as error:
            last = type(error).__name__
        time.sleep(2)
    raise TimeoutError(f"{url} not ready after {timeout:.0f}s: {last}")


def expect_denied(response: requests.Response) -> str:
    if response.ok:
        raise AssertionError(f"expected to be denied, got HTTP {response.status_code}")
    return f"HTTP {response.status_code}"


###############################################################################
# prepare
###############################################################################


def prepare() -> None:
    import boto3
    from botocore.config import Config

    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    s3 = boto3.client(
        "s3",
        endpoint_url=os.environ["MLFLOW_S3_ENDPOINT_URL"],
        region_name=region,
        config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    )

    def create_bucket() -> str:
        existing = [b["Name"] for b in s3.list_buckets().get("Buckets", [])]
        if BUCKET in existing:
            return "already there"
        extra = {}
        if region != "us-east-1":
            extra["CreateBucketConfiguration"] = {"LocationConstraint": region}
        s3.create_bucket(Bucket=BUCKET, **extra)
        return f"{BUCKET} in {region}"

    check("create artifact bucket", create_bucket)


###############################################################################
# seed (current image)
###############################################################################


def seed() -> None:
    from mlflow import MlflowClient
    from mlflow.exceptions import MlflowException

    admin = get_token(*ADMIN)
    user = get_token(*USER)

    def provision_user() -> str:
        # The first authenticated request creates the user from the token's
        # claims (OIDC_PROVISION_ON_BEARER_AUTH). The response itself does not
        # matter yet: the user has no workspace permission at this point.
        response = rest("GET", "/api/2.0/mlflow/experiments/search?max_results=1", user)
        return f"HTTP {response.status_code}"

    def create_workspace() -> str:
        act_as(admin, workspace=None)
        try:
            MlflowClient().create_workspace(WORKSPACE, description="Freva CI")
        except MlflowException as error:
            if "RESOURCE_ALREADY_EXISTS" not in str(error) and "already exists" not in str(error):
                raise
            return "already there"
        return WORKSPACE

    def grant_workspace() -> str:
        response = rest(
            "POST",
            f"/api/3.0/mlflow/permissions/workspaces/{WORKSPACE}/users",
            admin,
            json={"username": USER[0], "permission": "MANAGE"},
        )
        if response.status_code not in (200, 201, 409):
            raise AssertionError(f"HTTP {response.status_code}: {response.text[:300]}")
        return f"{USER[0]} MANAGE"

    def write_seed_data() -> str:
        import mlflow

        act_as(user)
        experiment = mlflow.set_experiment(SEED_EXPERIMENT)
        with mlflow.start_run(run_name="seed") as run:
            mlflow.log_param("source", "seed")
            for step in range(SEED_METRIC_STEPS):
                mlflow.log_metric("loss", 1.0 / (step + 1), step=step)
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp, SEED_ARTIFACT)
                path.write_text(SEED_CONTENT)
                mlflow.log_artifact(str(path))
        return f"experiment {experiment.experiment_id}, run {run.info.run_id}"

    check("provision normal user from bearer token", provision_user)
    check("admin creates workspace", create_workspace)
    check("admin grants workspace to user", grant_workspace)
    check("user writes seed data", write_seed_data)


###############################################################################
# verify (new image)
###############################################################################


def verify(expect_seed: bool) -> None:
    import mlflow
    from mlflow import MlflowClient

    wait_for(f"{MLFLOW_URL}/health")

    check("health", lambda: f"HTTP {rest('GET', '/health', None).status_code}")

    def ready() -> str:
        response = rest("GET", "/health/ready", None)
        response.raise_for_status()
        return f"HTTP {response.status_code}"

    check("OIDC plugin ready", ready)

    check(
        "anonymous API request is denied",
        lambda: expect_denied(rest("GET", "/api/2.0/mlflow/experiments/search?max_results=1", None)),
    )

    outsider = get_token(*OUTSIDER)
    check(
        "user without an MLflow group is denied",
        lambda: expect_denied(
            rest(
                "GET",
                "/api/2.0/mlflow/experiments/search?max_results=1",
                outsider,
                headers={WORKSPACE_HEADER: WORKSPACE},
            )
        ),
    )

    user = get_token(*USER)
    client = MlflowClient

    if expect_seed:

        def seeded_data() -> str:
            act_as(user)
            experiment = client().get_experiment_by_name(SEED_EXPERIMENT)
            if experiment is None:
                raise AssertionError(f"experiment {SEED_EXPERIMENT!r} not found")
            runs = client().search_runs([experiment.experiment_id])
            if len(runs) != 1:
                raise AssertionError(f"expected 1 seeded run, found {len(runs)}")
            run = runs[0]
            if run.data.params.get("source") != "seed":
                raise AssertionError(f"unexpected params {run.data.params}")
            history = client().get_metric_history(run.info.run_id, "loss")
            if len(history) != SEED_METRIC_STEPS:
                raise AssertionError(f"expected {SEED_METRIC_STEPS} loss values, found {len(history)}")
            with tempfile.TemporaryDirectory() as tmp:
                local = mlflow.artifacts.download_artifacts(
                    run_id=run.info.run_id, artifact_path=SEED_ARTIFACT, dst_path=tmp
                )
                content = Path(local).read_text()
            if content != SEED_CONTENT:
                raise AssertionError(f"seed artifact changed: {content!r}")
            return f"run {run.info.run_id}: params, {len(history)} metrics, artifact"

        check("data written by the previous image is intact", seeded_data)

    def round_trip() -> str:
        act_as(user)
        experiment = mlflow.set_experiment("ci-round-trip")
        with tempfile.TemporaryDirectory() as tmp:
            upload = Path(tmp, "payload.bin")
            upload.write_bytes(os.urandom(ARTIFACT_SIZE))
            checksum = sha256(upload)
            with mlflow.start_run(run_name="round-trip") as run:
                mlflow.log_param("checksum", checksum)
                mlflow.log_metric("value", 42.0)
                mlflow.log_artifact(str(upload))
            downloaded = Path(
                mlflow.artifacts.download_artifacts(
                    run_id=run.info.run_id, artifact_path="payload.bin", dst_path=str(Path(tmp, "dl"))
                )
            )
            if sha256(downloaded) != checksum:
                raise AssertionError("downloaded artifact does not match the upload")
        stored = client().get_run(run.info.run_id)
        if stored.data.metrics.get("value") != 42.0:
            raise AssertionError(f"metric not stored: {stored.data.metrics}")
        return f"experiment {experiment.experiment_id}, 1 MiB artifact checksum ok"

    check("experiment, run, metric and artifact round trip", round_trip)

    def default_workspace_denied() -> str:
        # Checked on the raw response: the MLflow client reports the plugin's
        # 403 as INTERNAL_ERROR, which would also hide a real server error.
        response = rest(
            "POST",
            "/api/2.0/mlflow/experiments/create",
            user,
            headers={WORKSPACE_HEADER: "default"},
            json={"name": "must-not-exist-in-default"},
        )
        if response.status_code != 403:
            raise AssertionError(f"expected HTTP 403, got {response.status_code}: {response.text[:300]}")
        return "HTTP 403"

    check("user cannot create in the default workspace", default_workspace_denied)


###############################################################################


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("prepare")
    sub.add_parser("seed")
    verify_parser = sub.add_parser("verify")
    verify_parser.add_argument(
        "--expect-seed", action="store_true", help="Also check the data written by 'seed'."
    )
    args = parser.parse_args()

    if args.command == "prepare":
        prepare()
    elif args.command == "seed":
        seed()
    else:
        verify(args.expect_seed)

    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed: {', '.join(FAILURES)}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

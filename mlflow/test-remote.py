#!/usr/bin/env python3
"""Run an end-to-end smoke test against a remote MLflow deployment.

The test verifies:

* authentication using an MLflow-generated access token
* workspace access
* experiment creation/selection
* run creation
* parameter and metric logging
* artifact upload through the MLflow server
* artifact download through the MLflow server
* artifact integrity after the round trip

No S3 credentials are used by this client. Artifact access must therefore be
proxied by the MLflow server.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import tempfile
from pathlib import Path

import mlflow
from mlflow.artifacts import download_artifacts


DEFAULT_TRACKING_URI = "https://mlflow.cloud.dkrz.de"
DEFAULT_EXPERIMENT = "remote-smoke-test"
ARTIFACT_SIZE = 1024 * 1024


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Test a remote MLflow deployment end to end.",
    )

    parser.add_argument(
        "-u",
        "--user",
        required=True,
        help="MLflow username, for example k204230.",
    )
    parser.add_argument(
        "-w",
        "--workspace",
        required=True,
        help="MLflow workspace to use.",
    )
    parser.add_argument(
        "--token-file",
        required=True,
        type=Path,
        help="File containing the MLflow-generated access token.",
    )
    parser.add_argument(
        "--tracking-uri",
        default=DEFAULT_TRACKING_URI,
        help=f"MLflow tracking URI (default: {DEFAULT_TRACKING_URI}).",
    )
    parser.add_argument(
        "--experiment",
        default=DEFAULT_EXPERIMENT,
        help=f"Experiment name (default: {DEFAULT_EXPERIMENT}).",
    )

    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()

    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)

    return digest.hexdigest()


def read_token(path: Path) -> str:
    try:
        token = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise RuntimeError(f"Unable to read token file {path}: {exc}") from exc

    if not token:
        raise RuntimeError(f"Token file is empty: {path}")

    return token


def configure_client(
    tracking_uri: str,
    user: str,
    token: str,
    workspace: str,
) -> None:
    # mlflow-oidc-auth uses HTTP Basic authentication for generated access
    # tokens: username + generated token as the password.
    os.environ["MLFLOW_TRACKING_URI"] = tracking_uri
    os.environ["MLFLOW_TRACKING_USERNAME"] = user
    os.environ["MLFLOW_TRACKING_PASSWORD"] = token
    os.environ["MLFLOW_TRACKING_INSECURE_TLS"] = "true"
    # The client must not accidentally access S3 directly. A successful
    # artifact round trip therefore verifies server-side artifact proxying.
    for variable in (
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_PROFILE",
        "AWS_DEFAULT_PROFILE",
        "MLFLOW_S3_ENDPOINT_URL",
    ):
        os.environ.pop(variable, None)

    mlflow.set_tracking_uri(tracking_uri)
    mlflow.set_workspace(workspace)


def run_test(args: argparse.Namespace) -> None:
    token = read_token(args.token_file)

    configure_client(
        tracking_uri=args.tracking_uri,
        user=args.user,
        token=token,
        workspace=args.workspace,
    )

    print(f"Tracking URI: {args.tracking_uri}")
    print(f"User:         {args.user}")
    print(f"Workspace:    {args.workspace}")
    print(f"Experiment:   {args.experiment}")
    print()

    print("[1/4] Selecting or creating experiment...")
    experiment = mlflow.set_experiment(args.experiment)

    print(f"      experiment ID: {experiment.experiment_id}")

    with tempfile.TemporaryDirectory(prefix="mlflow-smoke-test-") as tmp:
        tmp_path = Path(tmp)

        artifact = tmp_path / "artifact.bin"
        artifact.write_bytes(os.urandom(ARTIFACT_SIZE))

        expected_hash = sha256(artifact)

        print("[2/4] Creating run and logging metadata...")

        with mlflow.start_run(run_name="remote-smoke-test") as run:
            mlflow.log_param("smoke_test", True)
            mlflow.log_param("client_user", args.user)
            mlflow.log_metric("test_metric", 42.0)

            print(f"      run ID: {run.info.run_id}")
            print(f"      artifact URI: {run.info.artifact_uri}")

            print("[3/4] Uploading artifact...")

            mlflow.log_artifact(
                str(artifact),
                artifact_path="smoke-test",
            )

            run_id = run.info.run_id

        print("[4/4] Downloading artifact and checking integrity...")

        downloaded = Path(
            download_artifacts(
                run_id=run_id,
                artifact_path="smoke-test/artifact.bin",
            )
        )

        actual_hash = sha256(downloaded)

        print()
        print(f"Uploaded SHA256:   {expected_hash}")
        print(f"Downloaded SHA256: {actual_hash}")

        if expected_hash != actual_hash:
            raise RuntimeError("Downloaded artifact does not match uploaded artifact")

    print()
    print("SUCCESS")
    print("Authentication, workspace access, metadata storage, artifact upload,")
    print("artifact download, and artifact integrity all passed.")


def main() -> int:
    args = parse_args()

    try:
        run_test(args)
    except Exception as exc:
        print(file=sys.stderr)
        print(f"FAILED: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

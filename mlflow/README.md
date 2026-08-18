# Freva MLflow deployment

This directory contains the host-level deployment configuration for the Freva
MLflow image:

```text
ghcr.io/freva-org/freva-mlflow:latest
```

The deployment consists of:

- MLflow with OIDC authentication via Keycloak;
- PostgreSQL for MLflow metadata;
- a separate PostgreSQL database for the OIDC authentication plugin;
- MLflow workspaces for project/user separation;
- S3-compatible artifact storage;
- nginx as the public reverse proxy; and
- Podman/systemd for running the MLflow container.

The container itself is stateless. Persistent state is stored in PostgreSQL and
in the configured S3 artifact store.

## Setup using podman and quadlet
The most simple and secure way to set up MLFlow is creating a systemd unit with
podman quadlet. To do so create the `/etc/containers/systemd/` directory and
copy the `mlflow.{contianer,network}` into this directory:

```console
mkdir -p /etc/containers/systemd
cp mlflow.container mlflow.network /etc/containers/systemd
```

### 2. Create the MLFlow configuration

Create the configuration directories:

```console
sudo install -d -m 0750 /etc/mlflow /opt/mlflow
```

Copy the example application configuration:

```console
install -m 0600 mlflow.env.example /etc/mlflow/mlflow.env
vim /etc/mlflow/mlflow.env
```

The important settings are:

```env
MLFLOW_BACKEND_STORE_URI=postgresql+psycopg://mlflow:CHANGE_ME@postgres.example.org:5432/mlflow
OIDC_USERS_DB_URI=postgresql+psycopg://mlflow_auth:CHANGE_ME@postgres.example.org:5432/mlflow_auth

OIDC_DISCOVERY_URL=https://keycloak.example.org/realms/example/.well-known/openid-configuration
OIDC_CLIENT_ID=mlflow
OIDC_CLIENT_SECRET=CHANGE_ME
OIDC_REDIRECT_URI=https://mlflow.example.org/callback

SECRET_KEY=CHANGE_ME

MLFLOW_ARTIFACTS_DESTINATION=s3://mlflow-artifacts
MLFLOW_S3_ENDPOINT_URL=https://s3.example.org
MLFLOW_BOTO_CLIENT_ADDRESSING_STYLE=path

AWS_ACCESS_KEY_ID=CHANGE_ME
AWS_SECRET_ACCESS_KEY=CHANGE_ME
AWS_DEFAULT_REGION=eu-dkrz-0
```

Generate a persistent session secret, for example:

```console
openssl rand -hex 32
```

Use that value for `SECRET_KEY`. Do not regenerate it whenever the service
restarts.

If a password contains URI-reserved characters, percent-encode it before putting
it into a PostgreSQL URI.

### S3-compatible storage

For normal AWS S3, `MLFLOW_S3_ENDPOINT_URL` can be omitted.

For an S3-compatible implementation such as VersityGW, configure the endpoint
explicitly. For the DKRZ Waterpark deployment:

```env
MLFLOW_ARTIFACTS_DESTINATION=s3://mlflow-artifacts

MLFLOW_S3_ENDPOINT_URL=https://s3.waterpark.dkrz.de
MLFLOW_BOTO_CLIENT_ADDRESSING_STYLE=path

AWS_ACCESS_KEY_ID=CHANGE_ME
AWS_SECRET_ACCESS_KEY=CHANGE_ME
AWS_DEFAULT_REGION=eu-dkrz-0
```

The region is important. AWS Signature Version 4 includes the region in the
signature. The configured MLflow region therefore has to match the region used
by the S3 service.

For the Waterpark VersityGW deployment this is:

```env
AWS_DEFAULT_REGION=eu-dkrz-0
```

A wrong or missing region can cause normal artifact uploads to appear to work
while presigned artifact downloads fail.

Test the MLflow health endpoint:

```console
curl http://127.0.0.1:8080/health
```

For the OIDC plugin, the readiness endpoint is also useful:

```console
curl http://127.0.0.1:8080/health/ready
```
## Install the systemd service

Let quadelt create and start the systemd unit:

```console
systemctl daemon-reload
systemctl start mlflow
```

### Check the status

```console
sudo systemctl status mlflow.service
```

### Follow the logs

```console
sudo journalctl -u mlflow.service -f
```

### Update mlflow
After a PR for updating mlflow on this repository has been merged you can update
the service using these commands:

```console
systemctl stop mlflow.service
podman image prune -a
systemclt start mlflow.service
```

## Reverse proxy (nginx)

MLflow is exposed through nginx.

A minimal reverse-proxy location is:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port 443;
}
```

Set:

```env
MLFLOW_SERVER_ALLOWED_HOSTS=mlflow.example.org
```

to the externally visible hostname.

The trusted proxy configuration should contain only the network addresses from
which MLflow actually receives reverse-proxy requests.

## OIDC

The OIDC client should be a confidential OIDC client using the Authorization
Code flow.

Typical settings are:

```text
Client ID:    mlflow
Redirect URI: https://mlflow.example.org/callback
```

The deployment uses Keycloak for interactive authentication.

Example configuration:

```env
OIDC_DISCOVERY_URL=https://keycloak.example.org/realms/example/.well-known/openid-configuration
OIDC_CLIENT_ID=mlflow
OIDC_CLIENT_SECRET=CHANGE_ME
OIDC_REDIRECT_URI=https://mlflow.example.org/callback
```

Group/role mapping can be configured with:

```env
OIDC_GROUPS_ATTRIBUTE=groups
OIDC_GROUP_NAME=mlflow
OIDC_ADMIN_GROUP_NAME=mlflow-admin
```

For the DKRZ deployment the Keycloak token can expose MLflow-specific roles
through a dedicated claim, for example:

```env
OIDC_GROUPS_ATTRIBUTE=mlflow_roles
OIDC_GROUP_NAME=hpc-user
OIDC_ADMIN_GROUP_NAME=mlflow-admin
```

## Workspaces

MLflow workspaces are enabled with:

```env
MLFLOW_ENABLE_WORKSPACES=true
```

Workspaces provide logical separation between projects and users.

For example:

```text
ks1387
personal-k204230
```

A client can select a workspace before creating experiments:

```python
import mlflow

mlflow.set_workspace("ks1387")
mlflow.set_experiment("my-experiment")

with mlflow.start_run():
    mlflow.log_metric("loss", 0.42)
```

Workspace discovery and permissions are controlled by the OIDC workspace
plugin configuration.

## PostgreSQL

The deployment assumes two persistent databases:

```text
mlflow
mlflow_auth
```

They may live on the same PostgreSQL server.

Example:

```env
MLFLOW_BACKEND_STORE_URI=postgresql+psycopg://mlflow:password@db.example.org:5432/mlflow
OIDC_USERS_DB_URI=postgresql+psycopg://mlflow_auth:password@db.example.org:5432/mlflow_auth
```

No local database volume is required for the MLflow container.

## Testing artifact creation

The remote integration test verifies that a normal MLflow user can create and
retrieve artifacts through the complete production stack.

The test script accepts:

```text
-u, --user
-w, --workspace
--token-file
--insecure
```

### Authentication

First log in to the MLflow web interface and generate an MLflow access token.

Store the token in a file with restrictive permissions:

```console
mkdir -p ~/.config/mlflow
install -m 0600 /dev/null ~/.config/mlflow/token
editor ~/.config/mlflow/token
```

Do not store the token in the repository.

### Run the test

For example:

```console
python test-remote.py \
    --user the-user \
    --workspace personal \
    --token-file ~/.config/mlflow/token
```

For a project workspace:

```console
python test-remote.py \
    --user the-user \
    --workspace my-workspace \
    --token-file ~/.config/mlflow/token
```

If the MLflow endpoint temporarily uses an untrusted or self-signed
certificate:

```console
python test-remote.py \
    --user the-user \
    --workspace myworkspace \
    --token-file ~/.config/mlflow/token \
    --insecure
```

`--insecure` should only be used for temporary testing.

### What the test does

The test performs an end-to-end MLflow operation.

It:

1. configures the remote MLflow tracking URI;
2. authenticates using the supplied MLflow username and token;
3. selects the requested workspace;
4. creates or selects the `remote-smoke-test` experiment;
5. starts an MLflow run;
6. logs a parameter;
7. logs a metric;
8. generates a random 1 MiB test artifact;
9. calculates the artifact's SHA-256 checksum;
10. uploads the artifact through MLflow;
11. downloads the artifact again through MLflow; and
12. verifies that the downloaded checksum matches the original.

A successful test therefore validates:

The test deliberately removes client-side AWS/S3 configuration before using
MLflow.

The client should therefore **not** require:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
MLFLOW_S3_ENDPOINT_URL
```

A successful artifact test confirms that S3 credentials remain server-side and
that artifact access is mediated by MLflow and its presigned URLs.

The test also exercises downloads after upload, which is important because
successful `PutObject` requests alone do not prove that the presigned S3
download configuration is correct.

In particular, the following server-side configuration must be correct:

```env
MLFLOW_S3_ENDPOINT_URL=https://s3-endpoint-url.com
MLFLOW_BOTO_CLIENT_ADDRESSING_STYLE=path
AWS_DEFAULT_REGION=eu-dkrz-0
```

## Testing S3 independently

When debugging the artifact backend, it can be useful to test the S3 endpoint
without involving MLflow.

For example:

```python
import boto3
from botocore.config import Config

s3 = boto3.client(
    "s3",
    endpoint_url="https://s3.endpoint-url.com",
    region_name="eu-dkrz-0",
    config=Config(
        signature_version="s3v4",
        s3={"addressing_style": "path"},
    ),
)

print(
    s3.head_object(
        Bucket="mlflow-artifacts",
        Key="bar.txt",
    )
)
```

The required environment variables are:

```env
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

A presigned URL can be tested with:

```python
url = s3.generate_presigned_url(
    "get_object",
    Params={
        "Bucket": "mlflow-artifacts",
        "Key": "bar.txt",
        "ResponseContentDisposition": 'attachment; filename="bar.txt"',
    },
    ExpiresIn=300,
)

print(url)
```

It can then be tested from an external client with:

```console
curl -v "$URL"
```

or using a range request similar to MLflow's multipart download implementation:

```console
curl -v \
    -H 'Range: bytes=0-3' \
    "$URL"
```

## Useful commands

Restart:

```console
sudo systemctl restart mlflow
```

Stop:

```console
sudo systemctl stop mlflow
```

Inspect the running container:

```console
sudo podman ps
```

Open a shell:

```console
sudo podman exec -it mlflow bash
```

Show the installed MLflow version:

```console
sudo podman exec mlflow mlflow --version
```

Inspect the effective MLflow/S3 environment without printing secrets:

```console
sudo podman exec freva-mlflow env \
    | grep -E '^(MLFLOW_S3|MLFLOW_ARTIFACTS|AWS_DEFAULT_REGION)'
```

Follow the service logs:

```console
sudo journalctl -u mlflow -f
```


Update the service:

```console
systemctl stop mlflow.service
podman image prune -a
systemclt start mlflow.service
```

# Freva MLflow deployment

This directory contains a small host-level deployment for the Freva MLflow image:

```text
ghcr.io/freva-org/freva-mlflow:latest
```

It is intended for a Linux server where MLflow runs in Podman or Docker and is
normally exposed through an nginx reverse proxy on the same host.

The container itself is stateless: MLflow metadata is stored in PostgreSQL and
artifacts are stored in S3/S3-compatible object storage.

## 1. Pull the image manually

With Podman:

```console
podman pull ghcr.io/freva-org/freva-mlflow:latest
```

or with Docker:

```console
docker pull ghcr.io/freva-org/freva-mlflow:latest
```

## 2. Create the configuration

Create the configuration directory:

```console
sudo install -d -m 0750 /etc/mlflow
```

Copy the example application configuration:

```console
sudo install -m 0600 mlflow.env.example /etc/mlflow/mlflow.env
sudo editor /etc/mlflow/mlflow.env
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
AWS_ACCESS_KEY_ID=CHANGE_ME
AWS_SECRET_ACCESS_KEY=CHANGE_ME
AWS_DEFAULT_REGION=us-east-1
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

For AWS S3, `MLFLOW_S3_ENDPOINT_URL` can be omitted.

For an S3-compatible implementation such as VersityGW, set:

```env
MLFLOW_S3_ENDPOINT_URL=https://s3.example.org
```

The MLflow server receives the S3 credentials. Clients use MLflow for artifact
uploads/downloads and do not need the S3 credentials themselves.

## 3. Test the container directly

The systemd setup below uses host networking and binds MLflow only to
`127.0.0.1:8080`. This is convenient when nginx runs on the same machine.

With Podman:

```console
podman run --rm \
    --name freva-mlflow \
    --network host \
    --env-file /etc/mlflow/mlflow.env \
    ghcr.io/freva-org/freva-mlflow:latest
```

With Docker:

```console
docker run --rm \
    --name freva-mlflow \
    --network host \
    --env-file /etc/mlflow/mlflow.env \
    ghcr.io/freva-org/freva-mlflow:latest
```

Then test locally:

```console
curl http://127.0.0.1:8080/health
```

For the OIDC plugin, the readiness endpoint is also useful:

```console
curl http://127.0.0.1:8080/health/ready
```

## 4. Install the systemd service

Install the launcher:

```console
sudo install -m 0755 freva-mlflow-container /usr/local/bin/freva-mlflow-container
```

Install the unit:

```console
sudo install -m 0644 freva-mlflow.service /etc/systemd/system/freva-mlflow.service
```

Optionally install the host/container settings:

```console
sudo install -m 0644 container.env.example /etc/mlflow/container.env
sudo editor /etc/mlflow/container.env
```

If both Podman and Docker are installed, the launcher uses Podman by default.
To force Docker, put this in `/etc/mlflow/container.env`:

```env
CONTAINER_RUNTIME=docker
```

Reload systemd and start MLflow:

```console
sudo systemctl daemon-reload
sudo systemctl enable --now freva-mlflow.service
```

Check the status:

```console
sudo systemctl status freva-mlflow.service
```

Follow the logs:

```console
sudo journalctl -u freva-mlflow.service -f
```

## 5. Updating the image

The service pulls its configured image before starting.

With the default:

```env
MLFLOW_IMAGE=ghcr.io/freva-org/freva-mlflow:latest
```

an update is therefore:

```console
sudo systemctl restart freva-mlflow.service
```

The launcher first attempts to pull the current tag. If the registry is
temporarily unavailable but the image already exists locally, it falls back to
the existing local image.

For production you can instead pin a version produced by the Freva build
pipeline:

```env
MLFLOW_IMAGE=ghcr.io/freva-org/freva-mlflow:<mlflow-version>
```

Then change the tag deliberately when an automated dependency/version bump has
passed CI.

## 6. nginx

With the supplied configuration, MLflow listens on:

```text
127.0.0.1:8080
```

A minimal nginx upstream is therefore:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Set:

```env
MLFLOW_SERVER_ALLOWED_HOSTS=mlflow.example.org
```

to the externally visible hostname.

Because nginx and the container share the host network in this setup, the
trusted proxy can normally be restricted to loopback:

```env
TRUSTED_PROXIES=127.0.0.1/32,::1/128
```

Adjust this if nginx runs on another machine or in another container.

## 7. OIDC

The OIDC client should be a confidential OIDC client using the Authorization
Code flow.

Typical settings:

```text
Client ID:    mlflow
Redirect URI: https://mlflow.example.org/callback
```

The ID token should contain the user identity and a `groups` claim. The example
configuration assumes:

```env
OIDC_GROUPS_ATTRIBUTE=groups
OIDC_GROUP_NAME=mlflow
OIDC_ADMIN_GROUP_NAME=mlflow-admin
```

For API clients that authenticate with Keycloak bearer tokens, issuer/audience
validation should also be configured:

```env
OIDC_ISSUER=https://keycloak.example.org/realms/example
OIDC_AUDIENCE=mlflow
OIDC_PROVISION_ON_BEARER_AUTH=true
```

## 8. PostgreSQL

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

## 9. Useful commands

Restart:

```console
sudo systemctl restart freva-mlflow
```

Stop:

```console
sudo systemctl stop freva-mlflow
```

Inspect the running container:

```console
sudo podman ps
```

or:

```console
sudo docker ps
```

Open a shell:

```console
sudo podman exec -it freva-mlflow bash
```

or:

```console
sudo docker exec -it freva-mlflow bash
```

Show the installed MLflow version:

```console
sudo podman exec freva-mlflow mlflow --version
```

or:

```console
sudo docker exec freva-mlflow mlflow --version
```

#!/usr/bin/env bash
#
# Integration test of a freva-mlflow image against a production-like stack:
# PostgreSQL (two databases), Keycloak with the freva realm, and versitygw as
# S3 artifact store.
#
#   1. seed:    start the image that is published today (OLD_IMAGE), create a
#               workspace and some data through the API as normal users
#   2. upgrade: start the new image on that database with
#               MLFLOW_AUTO_DB_UPGRADE=false, as in production. If it refuses
#               because the schema is out of date, report that and run
#               `mlflow db upgrade` with the new image
#   3. verify:  health, authorization, the seeded data, and a full
#               experiment/run/metric/artifact round trip
#
# Usage:
#   mlflow/tests/run.sh <new-image>
#
# Environment:
#   CONTAINER_CMD   podman or docker (default: podman if installed, else docker)
#   OLD_IMAGE       image to seed with (default: ghcr.io/freva-org/freva-mlflow:latest)
#                   set to "none" to skip seeding
#   KEEP=1          leave the containers running for debugging
#   POSTGRES_IMAGE, KEYCLOAK_IMAGE, S3_IMAGE   override the service images
#
# The new image is resolved to its ID before OLD_IMAGE is pulled, so both may
# carry the same tag (CI builds the new image as ...:latest). The container
# plumbing lives in tests/lib.sh.
set -o nounset -o pipefail -o errexit

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(dirname "$HERE")"
REPO_DIR="$(dirname "$SERVICE_DIR")"

NEW_IMAGE="${1:?usage: run.sh <new-image>}"
OLD_IMAGE="${OLD_IMAGE:-ghcr.io/freva-org/freva-mlflow:latest}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-docker.io/library/postgres:17}"
# Same tag as the other Freva CI setups that import this realm: the export in
# keycloak/import/ is re-saved with current Keycloak versions, and older ones
# refuse fields they don't know (e.g. 26.4 and maxSecondaryAuthFailures).
KEYCLOAK_IMAGE="${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:latest}"
S3_IMAGE="${S3_IMAGE:-ghcr.io/freva-org/freva-versitygw:latest}"

# shellcheck source=../../tests/lib.sh
source "$REPO_DIR/tests/lib.sh"
it_init "$NEW_IMAGE" mlflow-it
# shellcheck disable=SC2034  # read by _it_cleanup in tests/lib.sh
LOG_ON_FAILURE="keycloak mlflow-old mlflow-new"

ENV_FILES=(--env-file "$SERVICE_DIR/mlflow.env.example" --env-file "$HERE/ci.env")
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
NEEDS_MIGRATION=false

client() { # image subcommand [args...]  (no S3 credentials on the client side)
    local image="$1"
    shift
    $E run --rm --network "$NET" -v "$HERE:/tests:ro,Z" "$image" \
        python /tests/test_deployment.py "$@"
}

start_mlflow() { # name image
    run_bg "$1" mlflow "${ENV_FILES[@]}" -- "$2"
}

# Wait until MLflow answers /health. Returns 1 if the container exits first.
wait_mlflow() { # name
    local name="$PREFIX-$1"
    for _ in $(seq 180); do
        if $E exec "$name" curl -fsS -o /dev/null http://127.0.0.1:8080/health 2>/dev/null; then
            return 0
        fi
        if [ "$($E inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]; then
            return 1
        fi
        sleep 1
    done
    echo "MLflow in $name did not become healthy within 180s" >&2
    return 1
}

###############################################################################
log "Images ($E)"
###############################################################################

resolve_images "$NEW_IMAGE" "$OLD_IMAGE"

for image in "$POSTGRES_IMAGE" "$KEYCLOAK_IMAGE" "$S3_IMAGE"; do
    $E pull -q "$image" >/dev/null
done

###############################################################################
log "Starting PostgreSQL, Keycloak and S3"
###############################################################################

it_network

run_bg postgres postgres \
    -e POSTGRES_PASSWORD=postgres \
    -v "$HERE/postgres-init.sql:/docker-entrypoint-initdb.d/init.sql:ro,Z" \
    -- "$POSTGRES_IMAGE"

# Everything talks to Keycloak inside the test network, so a single fixed
# hostname gives the same token issuer everywhere.
run_bg keycloak keycloak \
    -e KC_BOOTSTRAP_ADMIN_USERNAME=keycloak \
    -e KC_BOOTSTRAP_ADMIN_PASSWORD=secret \
    -e KC_HEALTH_ENABLED=true \
    -e JAVA_OPTS_APPEND=-Djava.net.preferIPv4Stack=true \
    -v "$REPO_DIR/keycloak/import:/opt/keycloak/data/import:ro,Z" \
    -- "$KEYCLOAK_IMAGE" start-dev --import-realm --hostname=http://keycloak:8080

run_bg s3 s3 \
    -e ROOT_ACCESS_KEY=ci-access-key \
    -e ROOT_SECRET_KEY=ci-secret-key \
    -e API_S3_REGION=eu-dkrz-0 \
    -e API_S3_NO_BANNER=1 \
    -- "$S3_IMAGE"

# The init scripts run on a temporary socket-only server, so TCP logins only
# work once they are done.
for attempt in $(seq 60); do
    if $E exec -e PGPASSWORD=mlflow "$PREFIX-postgres" \
            psql -h 127.0.0.1 -U mlflow -d mlflow -c 'select 1' >/dev/null 2>&1; then
        echo "PostgreSQL ready"
        break
    fi
    [ "$attempt" -eq 60 ] && { echo "PostgreSQL not ready after 120s" >&2; exit 1; }
    sleep 2
done

# Keycloak needs up to a minute for the realm import. Stop right away if it
# dies instead, e.g. because the realm export does not fit the Keycloak
# version; its log is printed on exit.
for attempt in $(seq 120); do
    if [ "$($E inspect -f '{{.State.Running}}' "$PREFIX-keycloak" 2>/dev/null)" != "true" ]; then
        echo "Keycloak exited during start-up, see its log below." >&2
        exit 1
    fi
    if $E exec "$PREFIX-keycloak" bash -c \
            '/opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm.config \
                 --server http://localhost:8080 --realm master \
                 --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" \
             && /opt/keycloak/bin/kcadm.sh get realms/freva --config /tmp/kcadm.config' \
            >/dev/null 2>&1; then
        echo "Keycloak ready, realm freva imported"
        break
    fi
    [ "$attempt" -eq 120 ] && { echo "Keycloak not ready after 240s" >&2; exit 1; }
    sleep 2
done

$E exec -i "$PREFIX-keycloak" bash -s < "$HERE/keycloak-setup.sh"

$E run --rm --network "$NET" -v "$HERE:/tests:ro,Z" "${ENV_FILES[@]}" "$NEW_ID" \
    python /tests/test_deployment.py prepare

###############################################################################
if [ -n "$OLD_ID" ]; then
    log "Seeding with the current image ($OLD_VERSION)"
    start_mlflow mlflow-old "$OLD_ID"
    wait_mlflow mlflow-old
    client "$OLD_ID" seed
    stop_container mlflow-old
fi
###############################################################################

###############################################################################
log "Starting the new image ($NEW_VERSION)"
###############################################################################

start_mlflow mlflow-new "$NEW_ID"
if ! wait_mlflow mlflow-new; then
    if $E logs "$PREFIX-mlflow-new" 2>&1 | grep -q "out-of-date database schema"; then
        NEEDS_MIGRATION=true
        echo "::warning title=MLflow database migration::MLflow ${NEW_VERSION} needs a schema migration of the database written by ${OLD_VERSION:-the current image}. Run 'mlflow db upgrade' before restarting the service."
        stop_container mlflow-new
        $E run --rm --network "$NET" "${ENV_FILES[@]}" "$NEW_ID" \
            sh -c 'mlflow db upgrade "$MLFLOW_BACKEND_STORE_URI"'
        start_mlflow mlflow-new "$NEW_ID"
        wait_mlflow mlflow-new
    else
        echo "The new image did not start, see its logs below." >&2
        exit 1
    fi
fi

###############################################################################
log "Verifying"
###############################################################################

verify_args=()
[ -n "$OLD_ID" ] && verify_args+=(--expect-seed)
client "$NEW_ID" verify "${verify_args[@]}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "needs-db-migration=$NEEDS_MIGRATION" >> "$GITHUB_OUTPUT"
fi
{
    echo "### MLflow integration test"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| new image | \`${NEW_VERSION}\` |"
    echo "| seeded with | \`${OLD_VERSION:-nothing}\` |"
    if $NEEDS_MIGRATION; then
        echo "| database | ⚠️ **needs \`mlflow db upgrade\`** before the service is restarted |"
    else
        echo "| database | no migration needed |"
    fi
} >> "$SUMMARY"

log "All checks passed (database migration needed: $NEEDS_MIGRATION)"

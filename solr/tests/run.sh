#!/usr/bin/env bash
#
# Integration test of a freva-solr image.
#
#   1. seed:      the image that is published today (OLD_IMAGE) creates the
#                 cores in a fresh data directory; sample records are indexed
#                 and a stale rotation core is left behind
#   2. upgrade:   the new image starts on the same data directory, so it has
#                 to load the cores, configs and index files of the old one
#   3. verify:    queries as Freva runs them, schema strictness, writes and a
#                 blue/green rotation through the freva configset
#   4. restart:   the new image starts again, the rotated core must survive
#
# Usage:
#   solr/tests/run.sh <new-image>
#
# Environment:
#   CONTAINER_CMD   podman or docker (default: whichever holds the image)
#   OLD_IMAGE       image to seed with (default: ghcr.io/freva-org/freva-solr:latest);
#                   "none" seeds with the new image instead
#   PYTHON_IMAGE    image the test client runs in (default: python:3.12-slim)
#   KEEP=1          leave the containers running for debugging
set -o nounset -o pipefail -o errexit

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$HERE")")"

NEW_IMAGE="${1:?usage: run.sh <new-image>}"
OLD_IMAGE="${OLD_IMAGE:-ghcr.io/freva-org/freva-solr:latest}"
PYTHON_IMAGE="${PYTHON_IMAGE:-docker.io/library/python:3.12-slim}"

# shellcheck source=../../tests/lib.sh
source "$REPO_DIR/tests/lib.sh"
it_init "$NEW_IMAGE" solr-it
# shellcheck disable=SC2034  # read by _it_cleanup in tests/lib.sh
LOG_ON_FAILURE="solr-old solr-new solr-restarted"

client() { # subcommand [args...]
    $E run --rm --network "$NET" -v "$HERE:/tests:ro,Z" "$PYTHON_IMAGE" \
        python /tests/test_solr.py "$@"
}

start_solr() { # name image
    run_bg "$1" solr \
        -e API_SOLR_HEAP=1g \
        -v "$PREFIX-data:/data/db" \
        -- "$2"
}

###############################################################################
log "Images ($E)"
###############################################################################

resolve_images "$NEW_IMAGE" "$OLD_IMAGE"
SEED_ID="${OLD_ID:-$NEW_ID}"
SEED_VERSION="${OLD_VERSION:-$NEW_VERSION (no published image to seed with)}"
$E pull -q "$PYTHON_IMAGE" >/dev/null

it_network
it_volume data

###############################################################################
log "Seeding with $SEED_VERSION"
###############################################################################

start_solr solr-old "$SEED_ID"
client wait
client seed
stop_container solr-old

###############################################################################
log "Starting the new image ($NEW_VERSION) on that data"
###############################################################################

start_solr solr-new "$NEW_ID"
client wait
client verify
stop_container solr-new

###############################################################################
log "Restarting the new image"
###############################################################################

start_solr solr-restarted "$NEW_ID"
client wait
client restarted

{
    echo "### Solr integration test"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| new image | \`${NEW_VERSION}\` |"
    echo "| seeded with | \`${SEED_VERSION}\` |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

log "All checks passed"

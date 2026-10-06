# shellcheck shell=bash
#
# Shared helpers for the service integration tests in <service>/tests/run.sh.
# Source it after `set -o nounset -o pipefail -o errexit`:
#
#   source "$REPO_DIR/tests/lib.sh"
#   it_init <image-under-test> <name-prefix>
#
# Provides:
#   $E                  container engine (podman or docker)
#   $PREFIX, $NET       container name prefix and network name
#   log <msg>           section header
#   resolve_engine      pick the engine whose storage holds the image
#   run_bg name alias [run options...] -- image [command...]
#   stop_container name
#   it_init             sets $E, $PREFIX, $NET, the cleanup trap, network
#
# Environment:
#   CONTAINER_CMD   force podman or docker
#   KEEP=1          leave the containers running after the test
#   LOG_ON_FAILURE  space separated container suffixes whose logs are
#                   printed when the test fails (default: all)

STARTED=()
IT_VOLUMES=()

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Use the engine whose storage holds the image under test: local-build.sh
# prefers podman, so on CI runners with both installed the image is only in
# podman's storage.
resolve_engine() { # image
    E="${CONTAINER_CMD:-}"
    if [ -z "$E" ]; then
        local candidate
        for candidate in podman docker; do
            if command -v "$candidate" >/dev/null 2>&1 \
               && "$candidate" image inspect "$1" >/dev/null 2>&1; then
                E="$candidate"
                break
            fi
        done
    fi
    if [ -z "$E" ]; then
        echo "Image $1 not found in podman or docker storage." >&2
        exit 1
    fi
}

_it_cleanup() {
    local status=$? name suffix
    if [ "$status" -ne 0 ]; then
        for name in "${STARTED[@]}"; do
            suffix="${name#"$PREFIX"-}"
            if [ -n "${LOG_ON_FAILURE:-}" ] && [[ " $LOG_ON_FAILURE " != *" $suffix "* ]]; then
                continue
            fi
            echo "::group::logs of $name"
            $E logs --tail 200 "$name" 2>&1 || true
            echo "::endgroup::"
        done
    fi
    if [ "${KEEP:-}" = "1" ]; then
        echo "KEEP=1: containers ${STARTED[*]} and network $NET are still running"
        return
    fi
    for name in "${STARTED[@]}"; do
        $E rm -f "$name" >/dev/null 2>&1 || true
    done
    for name in "${IT_VOLUMES[@]}"; do
        $E volume rm -f "$name" >/dev/null 2>&1 || true
    done
    $E network rm "$NET" >/dev/null 2>&1 || true
}

it_init() { # image prefix
    resolve_engine "$1"
    PREFIX="$2-$$"
    NET="$PREFIX"
    trap _it_cleanup EXIT
}

it_network() {
    $E network create "$NET" >/dev/null
}

# Pin the image under test by its ID first, then pull the published image to
# seed with. Both may carry the same tag: CI builds the new image as :latest.
# Sets NEW_ID, NEW_VERSION, OLD_ID and OLD_VERSION (empty when old is "none"
# or cannot be pulled).
resolve_images() { # new-image old-image
    NEW_ID="$($E image inspect --format '{{.Id}}' "$1")"
    NEW_VERSION="$(image_version "$NEW_ID")"
    echo "new: $1 ($NEW_VERSION)"
    OLD_ID=""
    OLD_VERSION=""
    if [ "$2" = "none" ]; then
        return
    fi
    if $E pull -q "$2" >/dev/null; then
        OLD_ID="$($E image inspect --format '{{.Id}}' "$2")"
        OLD_VERSION="$(image_version "$OLD_ID")"
        echo "old: $2 ($OLD_VERSION)"
    else
        echo "::warning::Cannot pull $2, testing without seeded data."
    fi
}

# Create the named volume "$PREFIX-<name>"; it is removed again on cleanup.
# Call it directly, not in $(...), so the cleanup list is updated.
it_volume() { # name
    $E volume create "$PREFIX-$1" >/dev/null
    IT_VOLUMES+=("$PREFIX-$1")
}

run_bg() { # name alias [run options...] -- image [command...]
    local name="$PREFIX-$1" alias="$2"
    shift 2
    local options=()
    while [ "$1" != "--" ]; do options+=("$1"); shift; done
    shift
    $E run -d --name "$name" --network "$NET" --network-alias "$alias" "${options[@]}" "$@" >/dev/null
    STARTED+=("$name")
}

stop_container() { # name
    $E stop -t 20 "$PREFIX-$1" >/dev/null 2>&1 || true
    $E rm -f "$PREFIX-$1" >/dev/null
}

image_version() { # image-or-id
    $E image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1"
}

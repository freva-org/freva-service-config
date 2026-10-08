#!/usr/bin/env bash

temp_dir=$(mktemp -d)
set -o nounset -o pipefail -o errexit

trap "rm -rf $temp_dir" EXIT

DO_CHECK=false
SERVICE=""
BUILD_CMD=podman
TEST_TAG=""

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --check) DO_CHECK=true ;;
    --service=*) SERVICE="${arg#*=}" ;;
    --container-cmd=*) BUILD_CMD="${arg#*=}";;
    # Also tag each image as localhost/freva-<service>:<tag>, a name that
    # cannot collide with an image pulled from the registry. CI hands that
    # name to <service>/tests/run.sh.
    --test-tag=*) TEST_TAG="${arg#*=}";;
    *) echo "❌ Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

### Detect docker or podman
# `command -v` must only be asked about the engine itself: with an extra
# argument such as `which` it succeeds as soon as that one exists.
cmd=""
for _cmd in ${BUILD_CMD} docker podman; do
    if command -v "$_cmd" > /dev/null; then
        cmd="$_cmd"
        build_cmd="$cmd build --no-cache"
        break
    fi
done
if [ -z "${cmd}" ]; then
    echo "❌ No container engine found (tried: ${BUILD_CMD} docker podman)." >&2
    exit 1
fi
if [ "${cmd}" = "podman" ];then
    build_cmd="$cmd build --format docker --no-cache"
fi
CERT_FILE="${temp_dir}/fullchain.pem"
KEY_FILE="${temp_dir}/privkey.pem"

$cmd run --rm -v ${temp_dir}:/keys:z -it docker.io/alpine sh -c '
apk add --no-cache openssl > /dev/null
CERT=/keys/fullchain.pem
KEY=/keys/privkey.pem
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout "$KEY" \
  -out "$CERT" \
  -subj "/CN=localhost" &> /dev/null
'
### Shared environment for test runs
ENV_VARS=(
  -e MYSQL_ROOT_PASSWORD=foo
  -e MYSQL_USER=bar
  -e MYSQL_PASSWORD=secret
  -e MYSQL_DATABASE=db
  -e API_MONGO_USER=foo
  -e API_MONGO_PASSWORD=secret
  -e TEST=1
  -e SERVER_KEY=$(base64 -w 0 "$KEY_FILE")
  -e SERVER_CERT=$(base64 -w 0 "$CERT_FILE")
)

### Determine which services to build
ALL_SERVICES=(mysql solr mongo redis nginx versitygw mlflow)
if [[ -n "$SERVICE" ]]; then
  SERVICES=("$SERVICE")
else
  SERVICES=("${ALL_SERVICES[@]}")
fi

### Build and optionally test each service
for service in "${SERVICES[@]}"; do
  version=$(grep '=' "$service/requirements.txt" |grep -v '#' | head -n 1 | cut -d = -f2)

  echo "🔧 Building freva-$service:$version ..."
  extra_tags=()
  if [ -n "$TEST_TAG" ]; then
    extra_tags=(-t "localhost/freva-$service:$TEST_TAG")
  fi
  $build_cmd \
    --build-arg=SERVICE=$service \
    --build-arg=VERSION=$version \
    -t ghcr.io/freva-org/freva-$service:latest \
    -t ghcr.io/freva-org/freva-$service:$version \
    "${extra_tags[@]}" .

  if $DO_CHECK; then
    echo "🧪 Testing freva-$service ..."
    $cmd run --rm "${ENV_VARS[@]}" \
      ghcr.io/freva-org/freva-$service healthchecks
  fi
done

echo "✅ All builds completed successfully."
if $DO_CHECK; then
  echo "✅ All healthchecks passed."
fi

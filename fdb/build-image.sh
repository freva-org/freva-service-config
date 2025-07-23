#!/usr/bin/env bash
set -o nounset -o pipefail -o errexit
SERVICE=""
BUILD_CMD=podman

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --container-cmd=*) BUILD_CMD="${arg#*=}";;
    *) echo "❌ Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

### Detect docker or podman
for _cmd in ${BUILD_CMD} docker podman; do
    if command -v which $_cmd > /dev/null;then
        cmd="$_cmd"
        build_cmd="$cmd build --no-cache"
        break
    fi
done
if [ "${cmd}" = "podman" ];then
    build_cmd="$cmd build --format docker --no-cache"
fi

service='fdb'
tag='ghcr.io/freva-org/freva-fdb:latest'

$build_cmd \
    --build-arg=SERVICE=$service \
    -t ${tag} \
    -f Dockerfile

# Tag version after build
version=$($cmd run -it ${tag} fdb version | tr -d '\r\n') # annoying \r
version_tag="ghcr.io/freva-org/freva-$service:$version"
$cmd tag ${tag} ${version_tag}
echo Image built with fdb5: $version

#!/usr/bin/env bash
set -euo pipefail

export CMAKE_PREFIX_PATH="${CONDA_PREFIX:-/opt/conda}"
export CMAKE_INCLUDE_PATH="${CONDA_PREFIX:-/opt/conda/include}"
temp_dir=$(mktemp -d)
trap "rm -rf $temp_dir" EXIT

function log_error(){
    local target=$1
    local code=$2
    echo "❌ Failed building ${target} (exit code: ${code})"
    exit $code
}

function build_project() {
    project=${1}
    {
      git clone https://github.com/ecmwf/${project}.git ${temp_dir}/${project}
      mkdir ${temp_dir}/${project}/build
      cd ${temp_dir}/${project}/build
      if [[ $project = "ecbuild" ]]; then
          cmake ..
      else
          ecbuild -- ..
      fi
      make -j$(nproc)
      make install
      echo "✅ ${project} build completed successfully."
    } || log_error $project $?
}


# Build dependencies, ORDER MATTERS!!!!
for project in ecbuild eckit metkit eccodes fdb; do
    build_project $project
done

echo "✅ All builds completed successfully."

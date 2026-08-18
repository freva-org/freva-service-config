#!/usr/bin/env bash
#
# Generic build-time patch applier.
#
# Any *.patch / *.diff file dropped into <service>/patches/ is applied while the
# image is being built. Services without a patches/ directory are unaffected.
#
# Patches are meant to be short lived: they carry fixes we need before they are
# released upstream. A patch that no longer applies fails the build on purpose,
# so a dependency bump forces us to re-check whether the patch is still needed.
#
# Optional directives, read from comment lines in the patch header:
#
#   # patch-root: PYTHON_SITE_PACKAGES   (default) resolve the active
#                                        interpreter's site-packages directory
#   # patch-root: /absolute/path         apply the patch relative to that path
#   # patch-strip: 1                     (default) value passed to `patch -p`
#
# `patch` ignores anything before the first ---/+++ header, so the directives
# can live in the patch file itself and no side-car metadata is needed.
#
set -o nounset -o pipefail -o errexit

[ "${DEBUG:-}" = "true" ] && set -x

patch_dir="${1:-}"

if [ -z "${patch_dir}" ]; then
    echo "usage: apply-patches.sh <patch-directory>" >&2
    exit 2
fi

if [ ! -d "${patch_dir}" ]; then
    echo "No patch directory ${patch_dir}, nothing to do."
    exit 0
fi

shopt -s nullglob

patches=("${patch_dir}"/*.patch "${patch_dir}"/*.diff)

if [ "${#patches[@]}" -eq 0 ]; then
    echo "No patches in ${patch_dir}, nothing to do."
    exit 0
fi

site_packages="$(python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"

# Sorted so that numeric prefixes (0001-, 0002-, ...) define the order.
IFS=$'\n' patches=($(sort <<<"${patches[*]}")); unset IFS

for patch_file in "${patches[@]}"; do
    # `patch --directory` chdirs before reading `--input`, so the patch file
    # must be referenced by absolute path.
    patch_file="$(realpath "${patch_file}")"

    root="$(sed -n 's/^#[[:space:]]*patch-root:[[:space:]]*//p' "${patch_file}" | head -n1)"
    strip="$(sed -n 's/^#[[:space:]]*patch-strip:[[:space:]]*//p' "${patch_file}" | head -n1)"

    case "${root:-PYTHON_SITE_PACKAGES}" in
        PYTHON_SITE_PACKAGES) root="${site_packages}" ;;
    esac

    strip="${strip:-1}"

    echo "Applying $(basename "${patch_file}") to ${root} (-p${strip})"

    if patch --dry-run --forward --strip="${strip}" --directory="${root}" \
             --input="${patch_file}" >/dev/null 2>&1; then
        patch --forward --strip="${strip}" --directory="${root}" \
              --input="${patch_file}"
        continue
    fi

    # Already applied is fine, anything else is a hard error: it means the
    # patched upstream code moved and the patch needs to be reviewed.
    if patch --dry-run --reverse --strip="${strip}" --directory="${root}" \
             --input="${patch_file}" >/dev/null 2>&1; then
        echo "  already applied, skipping"
        continue
    fi

    echo "ERROR: $(basename "${patch_file}") does not apply to ${root}." >&2
    echo "       The upstream code has changed - re-check whether the patch" >&2
    echo "       is still needed and refresh or delete it." >&2
    patch --dry-run --forward --strip="${strip}" --directory="${root}" \
          --input="${patch_file}" >&2 || true
    exit 1
done

echo "All patches applied."

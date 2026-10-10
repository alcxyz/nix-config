# shellcheck shell=bash
# Link the preview browser bundled with the T3 package into a T3 base
# directory, where T3 treats it as already installed (ADR-0092).
#
# Usage: t3code-link-preview-browser BUNDLE BASE_DIR
#
# BUNDLE is the package's libexec/t3code/preview-browser directory, laid out
# as <platform>/<version>/chrome-headless-shell like T3's own install root.
# Links keep the BUNDLE path as given, so a profile path follows profile
# switches instead of pinning one store path.
set -euo pipefail
shopt -s nullglob

if (($# != 2)); then
  echo "usage: t3code-link-preview-browser BUNDLE BASE_DIR" >&2
  exit 64
fi
bundle=${1%/}
base_dir=${2%/}

if [[ ! -d "$bundle" ]]; then
  echo "No bundled preview browser at $bundle; T3 downloads its own." >&2
  exit 0
fi

for platform_dir in "$bundle"/*/; do
  platform_dir=${platform_dir%/}
  platform=${platform_dir##*/}
  install_root="$base_dir/tools/chrome-headless-shell/$platform"
  mkdir -p "$install_root"
  for version_dir in "$platform_dir"/*/; do
    version_dir=${version_dir%/}
    version=${version_dir##*/}
    destination="$install_root/$version"
    if [[ -L "$destination" && "$(readlink "$destination")" == "$version_dir" ]]; then
      continue
    fi
    # A real directory here is T3's own download, which cannot run on NixOS.
    rm -rf -- "$destination"
    ln -s "$version_dir" "$destination"
    echo "Linked T3 preview browser $platform/$version into $base_dir."
  done
  # Links left by an older bundle point at a version the profile no longer has.
  for entry in "$install_root"/*; do
    if [[ -L "$entry" && ! -e "$entry" ]]; then
      rm -f -- "$entry"
    fi
  done
done

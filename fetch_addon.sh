#!/usr/bin/env bash
#
# Download the Godot OpenXR Vendors addon that this project vendors under
# addons/godotopenxrvendors.
#
# The addon binaries (.bin/) are intentionally NOT committed: they are ~50 MB
# of platform binaries that upstream ships as a release asset. Plugins tracked
# in git are the small text files (plugin.gdextension, licenses, changelog);
# this script materializes the binaries (and, if needed, the whole addon).
#
# Run it once after a fresh clone, and again after changing the version.
#
# Usage:
#   ./fetch_addon.sh                 # pinned version
#   ./fetch_addon.sh 5.1.0-stable    # explicit upstream tag
#   ./fetch_addon.sh --check         # verify the checkout is already populated
#
set -euo pipefail

REPO="GodotVR/godot_openxr_vendors"
DEFAULT_VERSION="5.2.0-stable"
ASSET="godotopenxrvendorsaddon.zip"

# sha256 of the release asset, used to pin/unpin versions. Unknown versions
# are downloaded without verification (with a warning).
checksum_for() {
  case "$1" in
    5.2.0-stable) echo "2a3958fff0de2dbdc4f1a036b5e4cfcea12ae7e45f8deebf4b45e5e9718c4e35" ;;
    *) echo "" ;;
  esac
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_DIR="$ROOT_DIR/addons/godotopenxrvendors"

die() { echo "error: $*" >&2; exit 1; }

# The GDExtension entry point every platform resolves through.
is_populated() { [ -f "$ADDON_DIR/.bin/android/template_debug/arm64/libgodotopenxrvendors.so" ]; }

MODE="fetch"
VERSION="$DEFAULT_VERSION"
case "${1:-}" in
  "" ) ;;
  --check ) MODE="check" ;;
  -h|--help ) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -* ) die "unknown option: $1 (try --help)" ;;
  * ) VERSION="$1" ;;
esac

if [ "$MODE" = "check" ]; then
  if is_populated; then
    echo "ok: addon binaries present in $ADDON_DIR"
    exit 0
  fi
  die "addon binaries missing — run ./fetch_addon.sh"
fi

command -v curl >/dev/null || die "curl is required"
command -v unzip >/dev/null || die "unzip is required"

URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
EXPECTED="$(checksum_for "$VERSION")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> downloading $ASSET ($VERSION)"
curl -fL --retry 3 -o "$tmp/$ASSET" "$URL" || die "download failed: $URL"

hash_file() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

if [ -n "$EXPECTED" ]; then
  actual="$(hash_file "$tmp/$ASSET")"
  [ "$actual" = "$EXPECTED" ] || die "checksum mismatch for $ASSET:
  expected $EXPECTED
  actual   $actual"
  echo "==> checksum ok"
else
  echo "warning: no pinned checksum for version $VERSION, skipping verification" >&2
  echo "         sha256 = $(hash_file "$tmp/$ASSET")" >&2
fi

echo "==> extracting into addons/"
unzip -q "$tmp/$ASSET" -d "$tmp/unpacked"
src="$tmp/unpacked/asset/addons/godotopenxrvendors"
[ -d "$src" ] || die "unexpected archive layout (no asset/addons/godotopenxrvendors)"

mkdir -p "$ROOT_DIR/addons"
if command -v rsync >/dev/null; then
  rsync -a "$src/" "$ADDON_DIR/"
else
  mkdir -p "$ADDON_DIR"
  cp -a "$src/." "$ADDON_DIR/"
fi

is_populated || die "extraction finished but binaries are still missing"
echo "==> done: OpenXR Vendors $VERSION in addons/godotopenxrvendors"

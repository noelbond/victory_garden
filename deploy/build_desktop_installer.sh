#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./deploy/build_desktop_installer.sh [--output-dir PATH]

Builds the Victory Garden desktop installer as a macOS Tauri app bundle and
exports versioned release artifacts:
- Victory Garden Installer.app
- victory-garden-installer-macos-<version>.zip
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER_DIR="$REPO_ROOT/desktop_installer"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/deploy/releases}"
APP_VERSION="$(python3 - <<'PY'
import json
from pathlib import Path
package = json.loads(Path("desktop_installer/package.json").read_text())
print(package["version"])
PY
)"

[[ "$(uname -s)" == "Darwin" ]] || fail "The desktop installer build currently runs on macOS only."
[[ -d "$INSTALLER_DIR" ]] || fail "Installer directory not found: $INSTALLER_DIR"

require_cmd npm
require_cmd cargo
require_cmd ditto

(
  cd "$INSTALLER_DIR"
  npm run tauri:build
)

BUNDLE_DIR="$INSTALLER_DIR/src-tauri/target/release/bundle"
APP_BUNDLE="$(find "$BUNDLE_DIR/macos" -maxdepth 1 -type d -name 'Victory Garden Installer.app' | head -n 1)"
[[ -n "$APP_BUNDLE" ]] || fail "Could not find built app bundle in $BUNDLE_DIR/macos"

mkdir -p "$OUTPUT_DIR"

APP_OUTPUT_DIR="$OUTPUT_DIR/Victory Garden Installer.app"
ZIP_OUTPUT="$OUTPUT_DIR/victory-garden-installer-macos-${APP_VERSION}.zip"

rm -rf "$APP_OUTPUT_DIR" "$ZIP_OUTPUT"
cp -R "$APP_BUNDLE" "$APP_OUTPUT_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_OUTPUT"

echo "Created app bundle: $APP_OUTPUT_DIR"
echo "Created zip archive: $ZIP_OUTPUT"

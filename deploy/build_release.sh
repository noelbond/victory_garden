#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./deploy/build_release.sh --target linux-armv7|linux-aarch64 [--output-dir PATH]

Builds a target-specific Victory Garden release tarball containing:
- app source
- deploy scripts
- Python wheelhouse
- Rails vendor/bundle
- Rails vendor/cache
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

TARGET=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
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

[[ -n "$TARGET" ]] || fail "Missing --target."
case "$TARGET" in
  linux-armv7|linux-aarch64)
    ;;
  *)
    fail "Unsupported target '$TARGET'. Use linux-armv7 or linux-aarch64."
    ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/deploy/releases}"
ARTIFACT_NAME="victory-garden-${TARGET}"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/victory-garden-release.XXXXXX")"
STAGE_DIR="$BUILD_ROOT/$ARTIFACT_NAME"
PYTHON_WHEELHOUSE_DIR="$STAGE_DIR/python_wheelhouse"
RUBY_SERVICE_DIR="$STAGE_DIR/ruby_service"
MANIFEST_PATH="$STAGE_DIR/deploy/release_manifest.json"
BUNDLE_CMD=""
REQUIRED_SOURCE_FILES=(
  "python_tools/requirements-controller.txt"
  "deploy/install_pi.sh"
  "deploy/build_release.sh"
  "ruby_service/Gemfile"
  "ruby_service/Gemfile.lock"
)
SOURCE_PATHS=(
  ".gitignore"
  "README.md"
  "contracts"
  "deploy"
  "firmware"
  "greenhouse.service"
  "python_tools"
  "ruby_service"
)

cleanup() {
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

detect_target() {
  case "$(uname -m)" in
    armv7l|armv6l)
      echo "linux-armv7"
      ;;
    aarch64|arm64)
      echo "linux-aarch64"
      ;;
    *)
      echo "unsupported"
      ;;
  esac
}

ensure_host_matches_target() {
  [[ "$(uname -s)" == "Linux" ]] || fail "Release artifacts must be built on Linux."

  local host_target
  host_target="$(detect_target)"
  [[ "$host_target" != "unsupported" ]] || fail "Unsupported build architecture: $(uname -m)."
  [[ "$host_target" == "$TARGET" ]] || fail "Build this artifact on a matching target host. Host is '$host_target', requested '$TARGET'."
}

ensure_bundler() {
  if command -v bundle >/dev/null 2>&1; then
    BUNDLE_CMD="$(command -v bundle)"
    return
  fi

  command -v gem >/dev/null 2>&1 || fail "RubyGems is required to install Bundler."

  gem install --user-install --no-document bundler

  local gem_user_bin
  gem_user_bin="$(ruby -r rubygems -e 'print Gem.user_dir')/bin"
  export PATH="$gem_user_bin:$PATH"

  if command -v bundle >/dev/null 2>&1; then
    BUNDLE_CMD="$(command -v bundle)"
    return
  fi

  if command -v bundler >/dev/null 2>&1; then
    BUNDLE_CMD="$(command -v bundler)"
    return
  fi

  fail "Bundler was installed but the executable was not found on PATH."
}

copy_required_source_files() {
  local path

  for path in "${REQUIRED_SOURCE_FILES[@]}"; do
    [[ -f "$REPO_ROOT/$path" ]] || fail "Required source file missing from repo: $path"
    mkdir -p "$STAGE_DIR/$(dirname "$path")"
    cp -p "$REPO_ROOT/$path" "$STAGE_DIR/$path"
  done
}

validate_release_stage() {
  local path

  for path in "${REQUIRED_SOURCE_FILES[@]}"; do
    [[ -f "$STAGE_DIR/$path" ]] || fail "Required file missing from staged release: $path"
  done
}

copy_repo_source() {
  mkdir -p "$STAGE_DIR"

  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    (
      cd "$REPO_ROOT"
      git ls-files --cached --others --exclude-standard -z | while IFS= read -r -d '' path; do
        mkdir -p "$STAGE_DIR/$(dirname "$path")"
        cp -p "$path" "$STAGE_DIR/$path"
      done
    )
  else
    (
      cd "$REPO_ROOT"
      tar \
        --exclude='deploy/releases' \
        --exclude='firmware/arduino/mkr1010_sensor_node/node_config.h' \
        --exclude='python_tools/.venv' \
        --exclude='python_tools/__pycache__' \
        --exclude='python_tools/controller_runtime.json' \
        --exclude='python_tools/state.json' \
        --exclude='ruby_service/vendor/bundle' \
        --exclude='ruby_service/vendor/cache' \
        --exclude='ruby_service/tmp' \
        --exclude='ruby_service/log' \
        -cf - "${SOURCE_PATHS[@]}"
    ) | (
      cd "$STAGE_DIR"
      tar -xf -
    )
  fi

  copy_required_source_files
  validate_release_stage
}

build_python_wheelhouse() {
  mkdir -p "$PYTHON_WHEELHOUSE_DIR"
  local wheel_venv
  wheel_venv="$(mktemp -d "${TMPDIR:-/tmp}/victory-garden-wheel-venv.XXXXXX")"

  python3 -m venv "$wheel_venv"
  "$wheel_venv/bin/pip" install --upgrade pip wheel
  "$wheel_venv/bin/pip" wheel \
    --wheel-dir "$PYTHON_WHEELHOUSE_DIR" \
    -r "$STAGE_DIR/python_tools/requirements-controller.txt"

  rm -rf "$wheel_venv"
}

build_ruby_bundle() {
  ensure_bundler

  (
    cd "$RUBY_SERVICE_DIR"
    "$BUNDLE_CMD" config set path vendor/bundle
    "$BUNDLE_CMD" config set without 'development test'
    "$BUNDLE_CMD" config set cache_all true
    "$BUNDLE_CMD" config set build.nokogiri '--use-system-libraries'
    NOKOGIRI_USE_SYSTEM_LIBRARIES=1 "$BUNDLE_CMD" install
    "$BUNDLE_CMD" cache --all
  )
}

write_manifest() {
  python3 - "$MANIFEST_PATH" "$ARTIFACT_NAME" "$TARGET" <<'PY'
import datetime as dt
import json
import os
import platform
import subprocess
import sys

manifest_path, artifact_name, target = sys.argv[1:4]

def run(cmd):
    return subprocess.check_output(cmd, text=True).strip()

def os_release():
    data = {}
    if not os.path.exists("/etc/os-release"):
        return data
    with open("/etc/os-release", "r", encoding="utf-8") as handle:
        for line in handle:
            if "=" not in line:
                continue
            key, value = line.rstrip().split("=", 1)
            data[key] = value.strip('"')
    return data

release = os_release()
bundle_version = run(["bundle", "--version"]).split()[-1]
ruby_version = run(["ruby", "-e", "print RUBY_VERSION"])
python_version = ".".join(platform.python_version_tuple()[:2])

manifest = {
    "artifact_name": artifact_name,
    "target": target,
    "built_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "platform": {
        "os": platform.system().lower(),
        "architecture": platform.machine(),
        "distro_id": release.get("ID"),
        "distro_version": release.get("VERSION_ID"),
    },
    "python": {
        "version": python_version,
        "wheelhouse_path": "python_wheelhouse",
        "requirements_path": "python_tools/requirements-controller.txt",
    },
    "ruby": {
        "version": ruby_version,
        "bundler_version": bundle_version,
        "bundle_path": "ruby_service/vendor/bundle",
        "cache_path": "ruby_service/vendor/cache",
    },
    "contents": [
        "app source",
        "scripts",
        "prebuilt bundle artifacts",
        "cached dependencies",
    ],
}

with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
}

create_tarball() {
  mkdir -p "$OUTPUT_DIR"
  tar -czf "$OUTPUT_DIR/$ARTIFACT_NAME.tar.gz" -C "$BUILD_ROOT" "$ARTIFACT_NAME"
  echo "Built $OUTPUT_DIR/$ARTIFACT_NAME.tar.gz"
}

main() {
  ensure_host_matches_target
  copy_repo_source
  build_python_wheelhouse
  build_ruby_bundle
  write_manifest
  create_tarball
}

main "$@"

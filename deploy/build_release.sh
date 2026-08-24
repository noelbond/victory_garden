#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./deploy/build_release.sh --target linux-armv7|linux-aarch64 [--output-dir PATH] [--use-prebuilt-firmware]

Builds a target-specific Victory Garden release tarball containing:
- app source
- deploy scripts
- Python wheelhouse
- Rails vendor/bundle
- Rails vendor/cache

The release build also verifies and bundles UF2 firmware for:
- Pico W sensor + actuator + combined
- Pico 2 W sensor + actuator + combined

By default, firmware is rebuilt as part of verification. Use
--use-prebuilt-firmware on a target-native packaging host without the Pico
cross-compilation toolchain; all six staged UF2 files are still required.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

TARGET=""
OUTPUT_DIR=""
USE_PREBUILT_FIRMWARE=false

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
    --use-prebuilt-firmware)
      USE_PREBUILT_FIRMWARE=true
      shift
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
source "$REPO_ROOT/deploy/lib/platform.sh"
source "$REPO_ROOT/deploy/lib/release_excludes.sh"
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
  "deploy/build_firmware_bundles.sh"
  "ruby_service/Gemfile"
  "ruby_service/Gemfile.lock"
)
SOURCE_PATHS=(
  ".gitignore"
  "README.md"
  "contracts"
  "deploy"
  "firmware"
  "firmware-bundles"
  "greenhouse.service"
  "python_tools"
  "ruby_service"
)

cleanup() {
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

ensure_host_matches_target() {
  [[ "$(uname -s)" == "Linux" ]] || fail "Release artifacts must be built on Linux."

  local host_target
  host_target="$(detect_platform_target)"
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

ensure_firmware_build_toolchain() {
  require_cmd cmake
  require_cmd ninja
  require_cmd arm-none-eabi-gcc
  require_cmd arm-none-eabi-g++
  require_cmd arm-none-eabi-objcopy
  require_cmd arm-none-eabi-objdump
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
        case "$path" in
          .gitignore|README.md|greenhouse.service|contracts/*|deploy/*|firmware/*|firmware-bundles/*|python_tools/*|ruby_service/*)
            ;;
          *)
            continue
            ;;
        esac

        # Git submodule entries and other directory-only paths are supplied by
        # the build host (for example PICO_SDK_PATH), not copied as release
        # source files.
        [[ -f "$path" || -L "$path" ]] || continue
        mkdir -p "$STAGE_DIR/$(dirname "$path")"
        cp -p "$path" "$STAGE_DIR/$path"
      done
    )
  else
    (
      cd "$REPO_ROOT"
      tar \
        "${RELEASE_TAR_EXCLUDES[@]}" \
        -cf - "${SOURCE_PATHS[@]}"
    ) | (
      cd "$STAGE_DIR"
      tar -xf -
    )
  fi

  copy_required_source_files
  validate_release_stage
}

verify_staged_firmware_builds() {
  if [[ "$USE_PREBUILT_FIRMWARE" == false ]]; then
    ensure_firmware_build_toolchain

    "$STAGE_DIR/deploy/build_firmware_bundles.sh" \
      --repo-root "$STAGE_DIR" \
      --output-dir "$STAGE_DIR/firmware-bundles" \
      --build-root "$BUILD_ROOT/firmware-build-bundles"
  fi

  local expected_bundle
  for expected_bundle in \
    "pico_w_sensor_node.uf2" \
    "pico2_w_sensor_node.uf2" \
    "pico_w_actuator_node.uf2" \
    "pico2_w_actuator_node.uf2" \
    "pico_w_combined_node.uf2" \
    "pico2_w_combined_node.uf2"; do
    [[ -s "$STAGE_DIR/firmware-bundles/$expected_bundle" ]] || fail "Firmware bundle is missing or empty: $expected_bundle"
  done
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
  local firmware_status="passed"
  if [[ "$USE_PREBUILT_FIRMWARE" == true ]]; then
    firmware_status="prebuilt-validated"
  fi

  python3 - "$MANIFEST_PATH" "$ARTIFACT_NAME" "$TARGET" "$firmware_status" <<'PY'
import datetime as dt
import json
import os
import platform
import subprocess
import sys

manifest_path, artifact_name, target, firmware_status = sys.argv[1:5]

def run(cmd, cwd=None):
    return subprocess.check_output(cmd, cwd=cwd, text=True).strip()

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
stage_dir = os.path.dirname(os.path.dirname(manifest_path))
bundle_version = run(
    ["bundle", "--version"], cwd=os.path.join(stage_dir, "ruby_service")
).split()[-1]
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
    "firmware": {
        "status": firmware_status,
        "build_system": "cmake+ninja",
        "bundle_dir": "firmware-bundles",
        "boards": [
            "pico_w",
            "pico2_w",
        ],
        "targets": [
            "pico_w_sensor_node",
            "pico_w_actuator_node",
            "pico_w_combined_node",
        ],
        "bundles": [
            "pico_w_sensor_node.uf2",
            "pico2_w_sensor_node.uf2",
            "pico_w_actuator_node.uf2",
            "pico2_w_actuator_node.uf2",
            "pico_w_combined_node.uf2",
            "pico2_w_combined_node.uf2",
        ],
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
  verify_staged_firmware_builds
  build_python_wheelhouse
  build_ruby_bundle
  write_manifest
  create_tarball
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./deploy/build_firmware_bundles.sh [--repo-root PATH] [--output-dir PATH] [--build-root PATH]

Builds bundled UF2 artifacts for every supported Pico Wi-Fi board:
- Pico W (RP2040)
- Pico 2 W (RP2350)
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/firmware-bundles"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/victory-garden-firmware-builds.XXXXXX")"
OWN_BUILD_ROOT=1

cleanup() {
  if [[ "$OWN_BUILD_ROOT" == "1" ]]; then
    rm -rf "$BUILD_ROOT"
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --build-root)
      BUILD_ROOT="${2:-}"
      OWN_BUILD_ROOT=0
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

[[ -d "$REPO_ROOT" ]] || fail "Repo root not found: $REPO_ROOT"

require_cmd cmake
require_cmd ninja
require_cmd arm-none-eabi-gcc
require_cmd arm-none-eabi-g++
require_cmd arm-none-eabi-objcopy
require_cmd arm-none-eabi-objdump

mkdir -p "$OUTPUT_DIR" "$BUILD_ROOT"

build_bundle() {
  local source_dir="$1"
  local target_name="$2"
  local pico_board="$3"
  local bundle_name="$4"
  local build_dir="$BUILD_ROOT/${target_name}-${pico_board}"

  cmake \
    -S "$REPO_ROOT/$source_dir" \
    -B "$build_dir" \
    -G Ninja \
    -DPICO_BOARD="$pico_board"

  cmake --build "$build_dir" --target "$target_name"

  [[ -f "$build_dir/${target_name}.uf2" ]] || fail "Missing built UF2: $build_dir/${target_name}.uf2"
  install -Dm644 "$build_dir/${target_name}.uf2" "$OUTPUT_DIR/$bundle_name"
}

build_bundle "firmware/pico_w_sensor_node" "pico_w_sensor_node" "pico_w" "pico_w_sensor_node.uf2"
build_bundle "firmware/pico_w_sensor_node" "pico_w_sensor_node" "pico2_w" "pico2_w_sensor_node.uf2"
build_bundle "firmware/pico_w_actuator_node" "pico_w_actuator_node" "pico_w" "pico_w_actuator_node.uf2"
build_bundle "firmware/pico_w_actuator_node" "pico_w_actuator_node" "pico2_w" "pico2_w_actuator_node.uf2"

echo "Built firmware bundles in $OUTPUT_DIR"

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./deploy/pi_image/build_pi_image.sh --pi-gen-dir PATH --first-user-pass PASSWORD [--pi-gen-branch NAME] [--image-name NAME] [--version VERSION] [--output-dir PATH] [--imager-base-url URL]

Stages the current Victory Garden repo and bundled Pico firmwares into a custom
pi-gen stage, then runs pi-gen's build.sh to create a Raspberry Pi OS 64-bit
image with Victory Garden preloaded. The final artifact is exported as a
versioned .img.xz plus a matching .sha256 file. If a base download URL is
provided, the pipeline also emits a Raspberry Pi Imager repository JSON file
that enables Imager 2.x customisation for the hosted image.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

PI_GEN_DIR=""
PI_GEN_BRANCH="${VG_PI_GEN_BRANCH:-bookworm-arm64}"
IMAGE_NAME="victory-garden-pi64"
IMAGE_HOSTNAME="victory-garden"
VERSION="$(date +%Y.%m.%d)"
FIRST_USER_NAME="${VG_PI_FIRST_USER_NAME:-pi}"
FIRST_USER_PASS="${VG_PI_FIRST_USER_PASS:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/deploy/pi_image/releases"
TEMPLATE_STAGE_DIR="$REPO_ROOT/deploy/pi_image/pi-gen/stage-victory-garden"
FIRMWARE_BUILD_SCRIPT="$REPO_ROOT/deploy/build_firmware_bundles.sh"
IMAGER_BASE_URL="${VG_PI_IMAGER_BASE_URL:-}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/victory-garden-pi-image.XXXXXX")"
STAGED_STAGE_DIR=""
ARTIFACT_BASENAME=""
FIRMWARE_BUNDLE_DIR="$WORK_DIR/firmware-bundles"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pi-gen-dir)
      PI_GEN_DIR="${2:-}"
      shift 2
      ;;
    --image-name)
      IMAGE_NAME="${2:-}"
      shift 2
      ;;
    --pi-gen-branch)
      PI_GEN_BRANCH="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --first-user-name)
      FIRST_USER_NAME="${2:-}"
      shift 2
      ;;
    --first-user-pass)
      FIRST_USER_PASS="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --imager-base-url)
      IMAGER_BASE_URL="${2:-}"
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

[[ -n "$PI_GEN_DIR" ]] || fail "Missing --pi-gen-dir."
[[ -n "$FIRST_USER_PASS" ]] || fail "Missing --first-user-pass (or set VG_PI_FIRST_USER_PASS)."
[[ -n "$PI_GEN_BRANCH" ]] || fail "Missing --pi-gen-branch."
[[ "$(uname -s)" == "Linux" ]] || fail "The Pi image build must run on Linux."
[[ -d "$PI_GEN_DIR" ]] || fail "pi-gen directory not found: $PI_GEN_DIR"
[[ -x "$PI_GEN_DIR/build.sh" ]] || fail "Expected pi-gen build.sh at: $PI_GEN_DIR/build.sh"
[[ -d "$TEMPLATE_STAGE_DIR" ]] || fail "Template stage directory missing: $TEMPLATE_STAGE_DIR"
[[ -x "$FIRMWARE_BUILD_SCRIPT" ]] || fail "Missing firmware bundle build script: $FIRMWARE_BUILD_SCRIPT"

require_cmd git
require_cmd rsync
require_cmd tar
require_cmd sha256sum
require_cmd unzip
require_cmd xz
require_cmd python3

SOURCE_TARBALL="$WORK_DIR/victory-garden-source.tgz"
ARTIFACT_BASENAME="${IMAGE_NAME}-${VERSION}"

create_source_tarball() {
  (
    cd "$REPO_ROOT"
    tar \
      --exclude='.git' \
      --exclude='deploy/releases' \
      --exclude='python_tools/.venv' \
      --exclude='python_tools/__pycache__' \
      --exclude='python_tools/controller_runtime.json' \
      --exclude='python_tools/state.json' \
      --exclude='ruby_service/vendor/bundle' \
      --exclude='ruby_service/vendor/cache' \
      --exclude='ruby_service/tmp' \
      --exclude='ruby_service/log' \
      --exclude='firmware/pico_w_sensor_node/build' \
      --exclude='firmware/pico_w_actuator_node/build' \
      --exclude='firmware-bundles' \
      -czf "$SOURCE_TARBALL" .
  )
}

build_firmware_bundles() {
  "$FIRMWARE_BUILD_SCRIPT" \
    --repo-root "$REPO_ROOT" \
    --output-dir "$FIRMWARE_BUNDLE_DIR" \
    --build-root "$WORK_DIR/firmware-builds"
}

stage_pi_gen_files() {
  STAGED_STAGE_DIR="$PI_GEN_DIR/stage-victory-garden"
  rm -rf "$STAGED_STAGE_DIR"
  rsync -a "$TEMPLATE_STAGE_DIR/" "$STAGED_STAGE_DIR/"

  install -Dm644 "$SOURCE_TARBALL" \
    "$STAGED_STAGE_DIR/files/opt/victory_garden-source.tgz"
  install -d "$STAGED_STAGE_DIR/files/opt/victory_garden/firmware-bundles"
  rsync -a "$FIRMWARE_BUNDLE_DIR/" \
    "$STAGED_STAGE_DIR/files/opt/victory_garden/firmware-bundles/"
}

write_pi_gen_config() {
  cat > "$PI_GEN_DIR/config" <<EOF
IMG_NAME=${IMAGE_NAME}
RELEASE=bookworm
DEPLOY_COMPRESSION=none
ENABLE_SSH=1
FIRST_USER_NAME=${FIRST_USER_NAME}
FIRST_USER_PASS=${FIRST_USER_PASS}
DISABLE_FIRST_BOOT_USER_RENAME=1
HOSTNAME=${IMAGE_HOSTNAME}
STAGE_LIST="stage0 stage1 stage2 stage-victory-garden"
EOF
}

run_pi_gen_build() {
  (
    cd "$PI_GEN_DIR"
    sudo ./build.sh
  )
}

export_release_artifacts() {
  local deploy_dir image_path zip_path zip_entry final_img final_xz checksum_path image_url repo_json
  deploy_dir="$PI_GEN_DIR/deploy"
  [[ -d "$deploy_dir" ]] || fail "pi-gen deploy directory not found: $deploy_dir"

  image_path="$(find "$deploy_dir" -maxdepth 1 -type f -name "*.img" | sort | tail -n 1)"
  zip_path=""
  zip_entry=""
  if [[ -z "$image_path" ]]; then
    zip_path="$(find "$deploy_dir" -maxdepth 1 -type f -name "*.zip" | sort | tail -n 1)"
    [[ -n "$zip_path" ]] || fail "Could not find a built .img or .zip file in $deploy_dir"
    zip_entry="$(unzip -Z1 "$zip_path" | awk '/\.img$/ { print; exit }')"
    [[ -n "$zip_entry" ]] || fail "Could not find an .img entry inside $zip_path"
  fi

  mkdir -p "$OUTPUT_DIR"
  final_img="$OUTPUT_DIR/${ARTIFACT_BASENAME}.img"
  final_xz="${final_img}.xz"
  checksum_path="${final_xz}.sha256"

  rm -f "$final_xz" "$checksum_path"
  if [[ -n "$image_path" ]]; then
    sudo cp "$image_path" "$final_img"
    sudo chown "$(id -u):$(id -g)" "$final_img"
  else
    unzip -p "$zip_path" "$zip_entry" > "$final_img"
  fi
  xz -T0 -z "$final_img"
  (
    cd "$OUTPUT_DIR"
    sha256sum "$(basename "$final_xz")" > "$(basename "$checksum_path")"
  )

  if [[ -n "$IMAGER_BASE_URL" ]]; then
    image_url="${IMAGER_BASE_URL%/}/$(basename "$final_xz")"
    repo_json="$OUTPUT_DIR/${ARTIFACT_BASENAME}.imager-repo.json"
    python3 "$REPO_ROOT/deploy/pi_image/generate_imager_repo.py" \
      --image "$final_xz" \
      --output "$repo_json" \
      --image-url "$image_url" \
      --release-date "${VERSION//./-}"
    echo "Created Imager repository JSON: $repo_json"
  fi

  echo "Created image artifact: $final_xz"
  echo "Created checksum: $checksum_path"
}

verify_pi_gen_branch() {
  (
    cd "$PI_GEN_DIR"
    local current_branch
    current_branch="$(git branch --show-current 2>/dev/null || true)"
    [[ "$current_branch" == "$PI_GEN_BRANCH" ]] || fail "pi-gen branch mismatch: expected '$PI_GEN_BRANCH', found '${current_branch:-detached}'."
  )
}

create_source_tarball
build_firmware_bundles
verify_pi_gen_branch
stage_pi_gen_files
write_pi_gen_config
run_pi_gen_build
export_release_artifacts

#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/victory-garden"
SUCCESS_MARKER="$STATE_DIR/firstboot-complete"
FAIL_MARKER="$STATE_DIR/firstboot-failed"
LOG_PATH="$STATE_DIR/firstboot.log"
REPO_ROOT="/opt/victory_garden"
FIRMWARE_BUNDLE_ROOT="$REPO_ROOT/firmware-bundles"

mkdir -p "$STATE_DIR"
exec > >(tee -a "$LOG_PATH") 2>&1

if [[ -f "$SUCCESS_MARKER" ]]; then
  echo "Victory Garden first boot already completed."
  exit 0
fi

trap 'touch "$FAIL_MARKER"' ERR
rm -f "$FAIL_MARKER"

detect_run_user() {
  local primary_user
  primary_user="$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)"
  if [[ -n "$primary_user" ]]; then
    echo "$primary_user"
    return
  fi

  echo "pi"
}

export VICTORY_GARDEN_RUN_USER="${VICTORY_GARDEN_RUN_USER:-$(detect_run_user)}"
export VG_FIRMWARE_BUNDLE_ROOT="$FIRMWARE_BUNDLE_ROOT"

chown -R "$VICTORY_GARDEN_RUN_USER:$VICTORY_GARDEN_RUN_USER" "$REPO_ROOT"

"$REPO_ROOT/deploy/install_pi.sh" --skip-system-packages

touch "$SUCCESS_MARKER"
systemctl disable victory-garden-firstboot.service || true
echo "Victory Garden first boot provisioning completed."

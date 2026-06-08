#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"

install -d "$ROOTFS_DIR/opt/victory_garden"
tar -xzf "$FILES_DIR/opt/victory_garden-source.tgz" \
  -C "$ROOTFS_DIR/opt/victory_garden" \
  --strip-components=0

install -d "$ROOTFS_DIR/opt/victory_garden/firmware-bundles"
for bundle in "$FILES_DIR"/opt/victory_garden/firmware-bundles/*.uf2; do
  install -m 0644 "$bundle" "$ROOTFS_DIR/opt/victory_garden/firmware-bundles/$(basename "$bundle")"
done

install -Dm755 \
  "$FILES_DIR/usr/local/sbin/victory-garden-firstboot.sh" \
  "$ROOTFS_DIR/usr/local/sbin/victory-garden-firstboot.sh"
install -Dm644 \
  "$FILES_DIR/etc/systemd/system/victory-garden-firstboot.service" \
  "$ROOTFS_DIR/etc/systemd/system/victory-garden-firstboot.service"

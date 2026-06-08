#!/usr/bin/env bash
set -euo pipefail

systemctl enable victory-garden-firstboot.service

mkdir -p /var/lib/victory-garden
chown root:root /var/lib/victory-garden
chmod 755 /var/lib/victory-garden

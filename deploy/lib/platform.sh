#!/usr/bin/env bash
# Shared host-architecture detection for deploy/install_pi.sh and deploy/build_release.sh.
# Must be sourced, not executed.

detect_platform_target() {
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

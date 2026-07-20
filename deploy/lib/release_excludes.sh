#!/usr/bin/env bash
# Shared tar --exclude list for packaging repo source into a release artifact
# or Pi image (deploy/build_release.sh, deploy/pi_image/build_pi_image.sh).
# Must be sourced, not executed. Keeping this in one place means a file that
# must never ship (e.g. live watering state) can't be excluded in one script
# and forgotten in the other.

RELEASE_TAR_EXCLUDES=(
  --exclude='deploy/releases'
  --exclude='python_tools/.venv'
  --exclude='python_tools/__pycache__'
  --exclude='python_tools/controller_runtime.json'
  --exclude='python_tools/state.json'
  --exclude='ruby_service/vendor/bundle'
  --exclude='ruby_service/vendor/cache'
  --exclude='ruby_service/tmp'
  --exclude='ruby_service/log'
)

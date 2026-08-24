#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo ./deploy/install_pi.sh"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/deploy/lib/platform.sh"
PYTHON_TOOLS_DIR="$REPO_ROOT/python_tools"
PYTHON_VENV_DIR="$PYTHON_TOOLS_DIR/.venv"
PYTHON_WHEELHOUSE_DIR="$REPO_ROOT/python_wheelhouse"
RUBY_SERVICE_DIR="$REPO_ROOT/ruby_service"
FIRMWARE_BUNDLE_DIR="$REPO_ROOT/firmware-bundles"
ENV_FILE="/etc/victory_garden.env"
RELEASE_MANIFEST="$REPO_ROOT/deploy/release_manifest.json"

CONTROLLER_SERVICE="greenhouse.service"
MQTT_DISCOVERY_SERVICE="victory-garden-mqtt-discovery.service"
WEB_SERVICE="victory-garden-web.service"
MQTT_CONSUMER_SERVICE="victory-garden-mqtt-consumer.service"
LORA_RECEIVER_SERVICE="victory-garden-lora-receiver.service"
DEFAULT_LORA_SERIAL_PORT="/dev/serial/by-id/REPLACE_WITH_LORA_ADAPTER"

# Shared by every unit's [Service] block below.
SYSTEMD_SERVICE_RESTART_POLICY=$'Restart=always\nRestartSec=5'
SYSTEMD_SERVICE_LOGGING=$'StandardOutput=journal\nStandardError=journal'

DB_USER="ruby_service"
DB_NAME="ruby_service_production"
DB_CACHE_NAME="ruby_service_production_cache"
DB_QUEUE_NAME="ruby_service_production_queue"
DB_CABLE_NAME="ruby_service_production_cable"
SKIP_SYSTEM_PACKAGES=0

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-system-packages)
      SKIP_SYSTEM_PACKAGES=1
      shift
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

detect_run_user() {
  if [[ -n "${VICTORY_GARDEN_RUN_USER:-}" ]]; then
    echo "$VICTORY_GARDEN_RUN_USER"
    return
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
    return
  fi

  local primary_user
  primary_user="$(awk -F: '$3 == 1000 { print $1; exit }' /etc/passwd)"
  if [[ -n "$primary_user" ]]; then
    echo "$primary_user"
    return
  fi

  fail "Could not determine the non-root user that should own the Victory Garden runtime."
}

RUN_USER="$(detect_run_user)"

release_install() {
  [[ -f "$RELEASE_MANIFEST" ]]
}

generated_secret() {
  python3 - <<'PY'
import secrets
print(secrets.token_hex(64))
PY
}

generated_mqtt_password() {
  python3 - <<'PY'
import secrets
print(secrets.token_hex(24))
PY
}

detect_lora_serial_port_default() {
  local -a candidates=()
  if [[ -d /dev/serial/by-id ]]; then
    while IFS= read -r -d '' candidate; do
      candidates+=("$candidate")
    done < <(find /dev/serial/by-id -maxdepth 1 -type l -print0 | sort -z)
  fi

  if [[ "${#candidates[@]}" -eq 1 ]]; then
    echo "${candidates[0]}"
  else
    echo "$DEFAULT_LORA_SERIAL_PORT"
  fi
}

manifest_value() {
  local key="$1"
  python3 - "$RELEASE_MANIFEST" "$key" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
key = sys.argv[2]

with open(manifest_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

value = data
for part in key.split("."):
    if not isinstance(value, dict):
        value = None
        break
    value = value.get(part)
    if value is None:
        break

if value is None:
    sys.exit(1)

print(value)
PY
}

read_master_key() {
  if [[ -f "$RUBY_SERVICE_DIR/config/master.key" ]]; then
    tr -d '\n' < "$RUBY_SERVICE_DIR/config/master.key"
  fi
}

ensure_supported_platform() {
  [[ "$(uname -s)" == "Linux" ]] || fail "This installer only supports Linux."

  local detected_target
  detected_target="$(detect_platform_target)"
  [[ "$detected_target" != "unsupported" ]] || fail "Unsupported CPU architecture: $(uname -m). Expected armv7l or aarch64."

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
      raspbian|debian)
        ;;
      *)
        fail "Unsupported distro '${ID:-unknown}'. Expected Raspberry Pi OS or Debian."
        ;;
    esac
  else
    fail "Cannot determine Linux distribution. /etc/os-release is missing."
  fi
}

validate_release_manifest() {
  [[ -f "$RELEASE_MANIFEST" ]] || return 0

  local expected_target current_target expected_ruby current_ruby expected_python current_python firmware_status

  expected_target="$(manifest_value "target")"
  current_target="$(detect_platform_target)"
  [[ "$expected_target" == "$current_target" ]] || fail "This release targets '$expected_target' but this Pi is '$current_target'."

  expected_ruby="$(manifest_value "ruby.version")"
  current_ruby="$(ruby -e 'print RUBY_VERSION')"
  [[ "$expected_ruby" == "$current_ruby" ]] || fail "Release was built for Ruby $expected_ruby but this Pi has Ruby $current_ruby."

  expected_python="$(manifest_value "python.version")"
  current_python="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')"
  [[ "$expected_python" == "$current_python" ]] || fail "Release wheelhouse targets Python $expected_python but this Pi has Python $current_python."

  firmware_status="$(manifest_value "firmware.status")"
  case "$firmware_status" in
    passed|prebuilt-validated)
      ;;
    *)
      fail "Release manifest does not show a successful firmware verification step."
      ;;
  esac
}

ensure_release_bundle_complete() {
  sudo -u "$RUN_USER" bash -lc "
    set -euo pipefail
    cd '$RUBY_SERVICE_DIR'
    bundle config set path vendor/bundle --local
    # Bundler prompts before replacing a local value. An unattended install
    # has no terminal to answer that prompt, so remove it first and then set
    # the canonical production groups deterministically.
    bundle config unset without --local || true
    bundle config set without 'development test' --local
    bundle config set cache_all true --local
    bundle config set build.nokogiri '--use-system-libraries' --local
    bundle check >/dev/null 2>&1
  " || fail "Packaged release is missing a complete prebuilt ruby_service/vendor/bundle for this target. Rebuild the release tarball instead of bundling on the Pi."
}

ensure_system_packages() {
  dpkg --configure -a
  apt-get update
  apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    build-essential \
    git \
    libpq-dev \
    libyaml-dev \
    libxml2-dev \
    libxslt1-dev \
    postgresql \
    postgresql-contrib \
    python3 \
    python3-pip \
    python3-venv \
    pkg-config \
    ruby-full \
    ruby-dev \
    mosquitto \
    mosquitto-clients \
    zlib1g-dev
}

ensure_bundler() {
  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler
  fi
}

ensure_ruby_version() {
  ruby - <<'RUBY'
required_major = 3
required_minor = 2
major, minor, = RUBY_VERSION.split(".").map(&:to_i)
if major < required_major || (major == required_major && minor < required_minor)
  warn "Ruby #{RUBY_VERSION} is too old for this Rails app. Need >= 3.2."
  exit 1
end
RUBY
}

ensure_python_controller_env() {
  sudo -u "$RUN_USER" python3 -m venv "$PYTHON_VENV_DIR"
  sudo -u "$RUN_USER" "$PYTHON_VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel
  if compgen -G "$PYTHON_WHEELHOUSE_DIR/*.whl" >/dev/null; then
    sudo -u "$RUN_USER" "$PYTHON_VENV_DIR/bin/python" -m pip install \
      --no-index \
      --find-links "$PYTHON_WHEELHOUSE_DIR" \
      -r "$PYTHON_TOOLS_DIR/requirements-controller.txt"
  else
    sudo -u "$RUN_USER" "$PYTHON_VENV_DIR/bin/python" -m pip install -r "$PYTHON_TOOLS_DIR/requirements-controller.txt"
  fi
}

ensure_env_file() {
  local db_password secret_key_base admin_api_token master_key mqtt_password lora_serial_port
  db_password="$(generated_secret)"
  secret_key_base="$(generated_secret)"
  admin_api_token="$(generated_secret)"
  master_key="$(read_master_key)"
  mqtt_password="$(generated_mqtt_password)"
  lora_serial_port="$(detect_lora_serial_port_default)"

  if [[ ! -f "$ENV_FILE" ]]; then
    cat > "$ENV_FILE" <<EOF
RAILS_ENV=production
RAILS_LOG_LEVEL=info
RAILS_SERVE_STATIC_FILES=true
RAILS_FORCE_SSL=false
RAILS_ASSUME_SSL=false
APP_HOST=localhost
PORT=3000
MQTT_HOST=127.0.0.1
MQTT_PORT=1883
MQTT_DISCOVERY_PORT=44737
MQTT_USERNAME=victory_garden
MQTT_PASSWORD=$mqtt_password
LORA_ENABLED=false
LORA_SERIAL_PORT=$lora_serial_port
LORA_BAUDRATE=9600
LORA_SERIAL_TIMEOUT_SECONDS=1.0
LORA_READ_SIZE=256
LORA_RECONNECT_DELAY_SECONDS=2.0
LORA_MAX_FRAME_SIZE=1024
LORA_DEDUP_RECENT_FRAMES=32
SOLID_QUEUE_IN_PUMA=1
SECRET_KEY_BASE=$secret_key_base
RUBY_SERVICE_DATABASE_PASSWORD=$db_password
ADMIN_API_TOKEN=$admin_api_token
RAILS_MASTER_KEY=$master_key
EOF
    chown "root:$RUN_USER" "$ENV_FILE"
    chmod 640 "$ENV_FILE"
  fi

  grep -q '^MQTT_USERNAME=' "$ENV_FILE" || echo 'MQTT_USERNAME=victory_garden' >> "$ENV_FILE"
  grep -q '^MQTT_PASSWORD=' "$ENV_FILE" || echo "MQTT_PASSWORD=$mqtt_password" >> "$ENV_FILE"
  grep -q '^MQTT_DISCOVERY_PORT=' "$ENV_FILE" || echo 'MQTT_DISCOVERY_PORT=44737' >> "$ENV_FILE"
  grep -q '^LORA_ENABLED=' "$ENV_FILE" || echo 'LORA_ENABLED=false' >> "$ENV_FILE"
  grep -q '^LORA_SERIAL_PORT=' "$ENV_FILE" || echo "LORA_SERIAL_PORT=$lora_serial_port" >> "$ENV_FILE"
  grep -q '^LORA_BAUDRATE=' "$ENV_FILE" || echo 'LORA_BAUDRATE=9600' >> "$ENV_FILE"
  grep -q '^LORA_SERIAL_TIMEOUT_SECONDS=' "$ENV_FILE" || echo 'LORA_SERIAL_TIMEOUT_SECONDS=1.0' >> "$ENV_FILE"
  grep -q '^LORA_READ_SIZE=' "$ENV_FILE" || echo 'LORA_READ_SIZE=256' >> "$ENV_FILE"
  grep -q '^LORA_RECONNECT_DELAY_SECONDS=' "$ENV_FILE" || echo 'LORA_RECONNECT_DELAY_SECONDS=2.0' >> "$ENV_FILE"
  grep -q '^LORA_MAX_FRAME_SIZE=' "$ENV_FILE" || echo 'LORA_MAX_FRAME_SIZE=1024' >> "$ENV_FILE"
  grep -q '^LORA_DEDUP_RECENT_FRAMES=' "$ENV_FILE" || echo 'LORA_DEDUP_RECENT_FRAMES=32' >> "$ENV_FILE"
  if [[ -d "$FIRMWARE_BUNDLE_DIR" ]]; then
    grep -q '^VG_FIRMWARE_BUNDLE_ROOT=' "$ENV_FILE" || echo "VG_FIRMWARE_BUNDLE_ROOT=$FIRMWARE_BUNDLE_DIR" >> "$ENV_FILE"
  fi

  # Re-assert ownership/permissions on every run so installs upgraded from an
  # older install_pi.sh (root-only 600) also become readable by the run user,
  # e.g. for `vg` and manual `bin/rails console` use.
  chown "root:$RUN_USER" "$ENV_FILE"
  chmod 640 "$ENV_FILE"
}

ensure_lora_serial_access() {
  getent group dialout >/dev/null || groupadd --system dialout
  usermod -a -G dialout "$RUN_USER"
}

validate_lora_serial_config() {
  load_env_file

  if [[ "${LORA_ENABLED:-false}" != "true" ]]; then
    echo "LORA_ENABLED is not true, skipping LoRa receiver setup."
    return 0
  fi

  if [[ -z "${LORA_SERIAL_PORT:-}" || "$LORA_SERIAL_PORT" == "$DEFAULT_LORA_SERIAL_PORT" ]]; then
    fail "LORA_SERIAL_PORT must be set to a stable /dev/serial/by-id/... path in $ENV_FILE."
  fi

  if [[ ! -e "$LORA_SERIAL_PORT" ]]; then
    fail "LORA_SERIAL_PORT does not exist: $LORA_SERIAL_PORT. Check the LR22 USB adapter and /dev/serial/by-id/."
  fi
}

load_env_file() {
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

ensure_mosquitto_auth() {
  load_env_file

  install -d -m 755 /etc/mosquitto/conf.d
  install -d -m 750 -o mosquitto -g mosquitto /etc/mosquitto/passwd
  mosquitto_passwd -b -c /etc/mosquitto/passwd/victory_garden "$MQTT_USERNAME" "$MQTT_PASSWORD"
  chown mosquitto:mosquitto /etc/mosquitto/passwd/victory_garden
  chmod 640 /etc/mosquitto/passwd/victory_garden

  rm -f /etc/mosquitto/conf.d/victory-garden-listener.conf
  rm -f /etc/mosquitto/conf.d/victory-garden-listener.conf.disabled

  cat > /etc/mosquitto/conf.d/victory-garden-auth.conf <<EOF
listener 1883 0.0.0.0
allow_anonymous false
password_file /etc/mosquitto/passwd/victory_garden
EOF
}

ensure_postgres() {
  systemctl enable postgresql
  systemctl restart postgresql

  load_env_file

  sudo -u postgres psql <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER') THEN
    CREATE ROLE $DB_USER LOGIN PASSWORD '${RUBY_SERVICE_DATABASE_PASSWORD}';
  ELSE
    ALTER ROLE $DB_USER WITH LOGIN PASSWORD '${RUBY_SERVICE_DATABASE_PASSWORD}';
  END IF;
END
\$\$;
EOF

  for db in "$DB_NAME" "$DB_CACHE_NAME" "$DB_QUEUE_NAME" "$DB_CABLE_NAME"; do
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1; then
      sudo -u postgres createdb -O "$DB_USER" "$db"
    fi
  done
}

ensure_rails_bundle() {
  sudo -u "$RUN_USER" bash -lc "
    set -euo pipefail
    cd '$RUBY_SERVICE_DIR'
    export BUNDLE_WITHOUT='development:test'
    bundle config set path vendor/bundle
    bundle config set cache_all true
    bundle config set build.nokogiri '--use-system-libraries'
    if ! bundle check >/dev/null 2>&1; then
      if [ -f '$RELEASE_MANIFEST' ]; then
        echo 'Packaged release is missing a complete prebuilt vendor/bundle.' >&2
        exit 1
      fi
      if [ -d vendor/cache ] && find vendor/cache -type f | grep -q .; then
        NOKOGIRI_USE_SYSTEM_LIBRARIES=1 bundle install --local || NOKOGIRI_USE_SYSTEM_LIBRARIES=1 bundle install
      else
        NOKOGIRI_USE_SYSTEM_LIBRARIES=1 bundle install
      fi
    fi

    effective_without=\"\$(bundle config get without 2>/dev/null || true)\"
    if [[ \"\$effective_without\" != *development* || \"\$effective_without\" != *test* ]]; then
      echo 'Bundler production exclusion verification failed: development/test are not excluded.' >&2
      bundle config list >&2
      exit 1
    fi

    bundle check
  "
}

verify_rails_production_boot() {
  sudo -u "$RUN_USER" bash -lc "
    set -euo pipefail
    cd '$RUBY_SERVICE_DIR'
    set -a
    source '$ENV_FILE'
    set +a
    export RAILS_ENV=production
    export BUNDLE_WITHOUT='development:test'
    bundle exec bin/rails runner 'abort \"production Rails boot verification failed\" unless Rails.env.production?'
  "
}

prepare_rails_db() {
  load_env_file
  sudo -u "$RUN_USER" bash -lc "
    set -euo pipefail
    cd '$RUBY_SERVICE_DIR'
    export RAILS_ENV='${RAILS_ENV}'
    export BUNDLE_WITHOUT='development:test'
    export RAILS_LOG_LEVEL='${RAILS_LOG_LEVEL}'
    export RAILS_SERVE_STATIC_FILES='${RAILS_SERVE_STATIC_FILES}'
    export RAILS_FORCE_SSL='${RAILS_FORCE_SSL}'
    export RAILS_ASSUME_SSL='${RAILS_ASSUME_SSL}'
    export APP_HOST='${APP_HOST}'
    export PORT='${PORT}'
    export MQTT_HOST='${MQTT_HOST}'
    export MQTT_PORT='${MQTT_PORT}'
    export MQTT_USERNAME='${MQTT_USERNAME}'
    export MQTT_PASSWORD='${MQTT_PASSWORD}'
    export SOLID_QUEUE_IN_PUMA='${SOLID_QUEUE_IN_PUMA}'
    export SECRET_KEY_BASE='${SECRET_KEY_BASE}'
    export RUBY_SERVICE_DATABASE_PASSWORD='${RUBY_SERVICE_DATABASE_PASSWORD}'
    export RAILS_MASTER_KEY='${RAILS_MASTER_KEY}'
    bundle exec bin/rails db:prepare
    if [ -f db/queue_schema.rb ]; then
      bundle exec ruby script/load_queue_schema.rb
    fi
    bundle exec bin/rails db:seed
    bundle exec bin/rails assets:precompile
  "
}

install_controller_service() {
  cat > "/etc/systemd/system/$CONTROLLER_SERVICE" <<EOF
[Unit]
Description=Victory Garden Greenhouse Controller
After=network-online.target mosquitto.service
Wants=network-online.target mosquitto.service

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$PYTHON_TOOLS_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$PYTHON_VENV_DIR/bin/python -m main
$SYSTEMD_SERVICE_RESTART_POLICY
Environment=PYTHONUNBUFFERED=1
$SYSTEMD_SERVICE_LOGGING
SyslogIdentifier=victory-garden-controller

[Install]
WantedBy=multi-user.target
EOF
}

install_mqtt_discovery_service() {
  cat > "/etc/systemd/system/$MQTT_DISCOVERY_SERVICE" <<EOF
[Unit]
Description=Victory Garden MQTT Discovery Responder
After=network-online.target mosquitto.service
Wants=network-online.target mosquitto.service

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$PYTHON_TOOLS_DIR
EnvironmentFile=$ENV_FILE
ExecStart=/bin/sh -lc 'exec "\$0" -m tools.mqtt_discovery_responder --discovery-port "\${MQTT_DISCOVERY_PORT:-44737}" --mqtt-port "\${MQTT_PORT:-1883}"' "$PYTHON_VENV_DIR/bin/python"
$SYSTEMD_SERVICE_RESTART_POLICY
Environment=PYTHONUNBUFFERED=1
$SYSTEMD_SERVICE_LOGGING
SyslogIdentifier=victory-garden-mqtt-discovery

[Install]
WantedBy=multi-user.target
EOF
}

install_web_service() {
  cat > "/etc/systemd/system/$WEB_SERVICE" <<EOF
[Unit]
Description=Victory Garden Rails Web
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$RUBY_SERVICE_DIR
EnvironmentFile=$ENV_FILE
Environment=BUNDLE_WITHOUT=development:test
ExecStart=/usr/bin/env bash -lc 'bundle exec puma -C config/puma.rb'
$SYSTEMD_SERVICE_RESTART_POLICY
$SYSTEMD_SERVICE_LOGGING
SyslogIdentifier=victory-garden-web

[Install]
WantedBy=multi-user.target
EOF
}

install_mqtt_consumer_service() {
  cat > "/etc/systemd/system/$MQTT_CONSUMER_SERVICE" <<EOF
[Unit]
Description=Victory Garden Rails MQTT Consumer
After=network-online.target mosquitto.service postgresql.service
Wants=network-online.target mosquitto.service
Requires=postgresql.service

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$RUBY_SERVICE_DIR
EnvironmentFile=$ENV_FILE
Environment=BUNDLE_WITHOUT=development:test
ExecStart=/usr/bin/env bash -lc 'bundle exec ruby bin/mqtt_consumer'
$SYSTEMD_SERVICE_RESTART_POLICY
$SYSTEMD_SERVICE_LOGGING
SyslogIdentifier=victory-garden-mqtt-consumer

[Install]
WantedBy=multi-user.target
EOF
}

install_lora_receiver_service() {
  cat > "/etc/systemd/system/$LORA_RECEIVER_SERVICE" <<EOF
[Unit]
Description=Victory Garden LoRa Receiver
After=network-online.target mosquitto.service
Wants=network-online.target mosquitto.service

[Service]
Type=simple
User=$RUN_USER
SupplementaryGroups=dialout
WorkingDirectory=$PYTHON_TOOLS_DIR
EnvironmentFile=$ENV_FILE
ExecStart=/bin/sh -lc 'exec "\$0" -m tools.lora_receiver --serial-port "\${LORA_SERIAL_PORT:-$DEFAULT_LORA_SERIAL_PORT}" --baudrate "\${LORA_BAUDRATE:-9600}" --serial-timeout-seconds "\${LORA_SERIAL_TIMEOUT_SECONDS:-1.0}" --read-size "\${LORA_READ_SIZE:-256}" --reconnect-delay-seconds "\${LORA_RECONNECT_DELAY_SECONDS:-2.0}" --max-frame-size "\${LORA_MAX_FRAME_SIZE:-1024}" --dedup-recent-frames "\${LORA_DEDUP_RECENT_FRAMES:-32}"' "$PYTHON_VENV_DIR/bin/python"
$SYSTEMD_SERVICE_RESTART_POLICY
Environment=PYTHONUNBUFFERED=1
$SYSTEMD_SERVICE_LOGGING
SyslogIdentifier=victory-garden-lora-receiver

[Install]
WantedBy=multi-user.target
EOF
}

install_vg_cli() {
  chmod +x "$REPO_ROOT/deploy/vg"
  ln -sf "$REPO_ROOT/deploy/vg" /usr/local/bin/vg
}

restart_services() {
  systemctl disable --now victory-garden-actuator.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/victory-garden-actuator.service
  systemctl daemon-reload
  local -a enable_services=(mosquitto postgresql "$CONTROLLER_SERVICE" "$MQTT_DISCOVERY_SERVICE" "$WEB_SERVICE" "$MQTT_CONSUMER_SERVICE")
  if [[ "${LORA_ENABLED:-false}" == "true" ]]; then
    enable_services+=("$LORA_RECEIVER_SERVICE")
  fi
  systemctl enable "${enable_services[@]}"
  systemctl restart mosquitto
  systemctl restart postgresql
  systemctl restart "$CONTROLLER_SERVICE"
  systemctl restart "$MQTT_DISCOVERY_SERVICE"
  systemctl restart "$WEB_SERVICE"
  systemctl restart "$MQTT_CONSUMER_SERVICE"
  if [[ "${LORA_ENABLED:-false}" == "true" ]]; then
    systemctl restart "$LORA_RECEIVER_SERVICE"
  fi
}

verify_services_healthy() {
  local service attempt all_active
  local -a services=(
    mosquitto.service
    postgresql.service
    "$CONTROLLER_SERVICE"
    "$MQTT_DISCOVERY_SERVICE"
    "$WEB_SERVICE"
    "$MQTT_CONSUMER_SERVICE"
  )
  if [[ "${LORA_ENABLED:-false}" == "true" ]]; then
    services+=("$LORA_RECEIVER_SERVICE")
  fi

  # A process can start and then fail a few seconds later. Require every
  # dependency to remain active and Rails to answer its application health
  # endpoint before reporting a successful installation.
  for attempt in {1..30}; do
    if curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:${PORT}/up" >/dev/null 2>&1; then
      sleep 2
      all_active=1
      for service in "${services[@]}"; do
        if ! systemctl is-active --quiet "$service"; then
          all_active=0
          break
        fi
      done
      if [[ "$all_active" -eq 1 ]] && curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:${PORT}/up" >/dev/null; then
        return 0
      fi
    fi
    sleep 1
  done

  echo "Victory Garden post-install health verification failed." >&2
  for service in "${services[@]}"; do
    systemctl --no-pager --full status "$service" >&2 || true
  done
  journalctl -u "$WEB_SERVICE" -u "$MQTT_CONSUMER_SERVICE" -n 80 --no-pager >&2 || true
  if [[ "${LORA_ENABLED:-false}" == "true" ]]; then
    journalctl -u "$LORA_RECEIVER_SERVICE" -n 80 --no-pager >&2 || true
  fi
  return 1
}

print_status() {
  systemctl --no-pager --full status "$CONTROLLER_SERVICE" || true
  systemctl --no-pager --full status "$MQTT_DISCOVERY_SERVICE" || true
  systemctl --no-pager --full status "$WEB_SERVICE" || true
  systemctl --no-pager --full status "$MQTT_CONSUMER_SERVICE" || true
  if [[ "${LORA_ENABLED:-false}" == "true" ]]; then
    systemctl --no-pager --full status "$LORA_RECEIVER_SERVICE" || true
  fi
  echo
  echo "Victory Garden Pi install complete."
  echo "Web UI: http://$(hostname -I | awk '{print $1}'):3000"
  echo "Health check: http://$(hostname -I | awk '{print $1}'):3000/up"
  echo "CLI: run 'vg help' for zones/nodes/readings/network/log commands."
}

ensure_supported_platform
if [[ "$SKIP_SYSTEM_PACKAGES" -eq 0 ]]; then
  ensure_system_packages
fi
ensure_bundler
ensure_ruby_version
validate_release_manifest
if release_install; then
  ensure_release_bundle_complete
fi
ensure_python_controller_env
ensure_env_file
ensure_lora_serial_access
validate_lora_serial_config
ensure_mosquitto_auth
ensure_postgres
ensure_rails_bundle
prepare_rails_db
verify_rails_production_boot
install_controller_service
install_mqtt_discovery_service
install_web_service
install_mqtt_consumer_service
if [[ "${LORA_ENABLED:-false}" == "true" ]]; then
  install_lora_receiver_service
fi
install_vg_cli
restart_services
verify_services_healthy
print_status

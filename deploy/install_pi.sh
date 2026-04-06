#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo ./deploy/install_pi.sh"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_USER="${SUDO_USER:-$(id -un)}"
PYTHON_TOOLS_DIR="$REPO_ROOT/python_tools"
PYTHON_VENV_DIR="$PYTHON_TOOLS_DIR/.venv"
PYTHON_WHEELHOUSE_DIR="$REPO_ROOT/python_wheelhouse"
RUBY_SERVICE_DIR="$REPO_ROOT/ruby_service"
ENV_FILE="/etc/victory_garden.env"
RELEASE_MANIFEST="$REPO_ROOT/deploy/release_manifest.json"

CONTROLLER_SERVICE="greenhouse.service"
MQTT_DISCOVERY_SERVICE="victory-garden-mqtt-discovery.service"
WEB_SERVICE="victory-garden-web.service"
MQTT_CONSUMER_SERVICE="victory-garden-mqtt-consumer.service"

DB_USER="ruby_service"
DB_NAME="ruby_service_production"
DB_CACHE_NAME="ruby_service_production_cache"
DB_QUEUE_NAME="ruby_service_production_queue"
DB_CABLE_NAME="ruby_service_production_cable"

release_install() {
  [[ -f "$RELEASE_MANIFEST" ]]
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
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

  local expected_target current_target expected_ruby current_ruby expected_python current_python

  expected_target="$(manifest_value "target")"
  current_target="$(detect_platform_target)"
  [[ "$expected_target" == "$current_target" ]] || fail "This release targets '$expected_target' but this Pi is '$current_target'."

  expected_ruby="$(manifest_value "ruby.version")"
  current_ruby="$(ruby -e 'print RUBY_VERSION')"
  [[ "$expected_ruby" == "$current_ruby" ]] || fail "Release was built for Ruby $expected_ruby but this Pi has Ruby $current_ruby."

  expected_python="$(manifest_value "python.version")"
  current_python="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')"
  [[ "$expected_python" == "$current_python" ]] || fail "Release wheelhouse targets Python $expected_python but this Pi has Python $current_python."
}

ensure_release_bundle_complete() {
  sudo -u "$RUN_USER" bash -lc "
    set -euo pipefail
    cd '$RUBY_SERVICE_DIR'
    bundle config set path vendor/bundle
    bundle config set without 'development test'
    bundle config set cache_all true
    bundle config set build.nokogiri '--use-system-libraries'
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
    sudo -u "$RUN_USER" "$PYTHON_VENV_DIR/bin/pip" install \
      --no-index \
      --find-links "$PYTHON_WHEELHOUSE_DIR" \
      -r "$PYTHON_TOOLS_DIR/requirements-controller.txt"
  else
    sudo -u "$RUN_USER" "$PYTHON_VENV_DIR/bin/pip" install -r "$PYTHON_TOOLS_DIR/requirements-controller.txt"
  fi
}

ensure_env_file() {
  local db_password secret_key_base admin_api_token master_key mqtt_password
  db_password="$(generated_secret)"
  secret_key_base="$(generated_secret)"
  admin_api_token="$(generated_secret)"
  master_key="$(read_master_key)"
  mqtt_password="$(generated_mqtt_password)"

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
SOLID_QUEUE_IN_PUMA=1
SECRET_KEY_BASE=$secret_key_base
RUBY_SERVICE_DATABASE_PASSWORD=$db_password
ADMIN_API_TOKEN=$admin_api_token
RAILS_MASTER_KEY=$master_key
EOF
    chmod 600 "$ENV_FILE"
  fi

  grep -q '^MQTT_USERNAME=' "$ENV_FILE" || echo 'MQTT_USERNAME=victory_garden' >> "$ENV_FILE"
  grep -q '^MQTT_PASSWORD=' "$ENV_FILE" || echo "MQTT_PASSWORD=$mqtt_password" >> "$ENV_FILE"
  grep -q '^MQTT_DISCOVERY_PORT=' "$ENV_FILE" || echo 'MQTT_DISCOVERY_PORT=44737' >> "$ENV_FILE"
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
    bundle config set path vendor/bundle
    bundle config set without 'development test'
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
  "
}

prepare_rails_db() {
  load_env_file
  sudo -u "$RUN_USER" bash -lc "
    set -euo pipefail
    cd '$RUBY_SERVICE_DIR'
    export RAILS_ENV='${RAILS_ENV}'
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
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
StandardOutput=journal
StandardError=journal
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
ExecStart=/bin/sh -lc 'exec "$0" -m tools.mqtt_discovery_responder --discovery-port "${MQTT_DISCOVERY_PORT:-44737}" --mqtt-port "${MQTT_PORT:-1883}"' $PYTHON_VENV_DIR/bin/python
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
StandardOutput=journal
StandardError=journal
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
ExecStart=/usr/bin/env bash -lc 'bundle exec puma -C config/puma.rb'
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
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
ExecStart=/usr/bin/env bash -lc 'bundle exec ruby bin/mqtt_consumer'
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=victory-garden-mqtt-consumer

[Install]
WantedBy=multi-user.target
EOF
}

restart_services() {
  systemctl disable --now victory-garden-actuator.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/victory-garden-actuator.service
  systemctl enable mosquitto postgresql "$CONTROLLER_SERVICE" "$MQTT_DISCOVERY_SERVICE" "$WEB_SERVICE" "$MQTT_CONSUMER_SERVICE"
  systemctl daemon-reload
  systemctl restart mosquitto
  systemctl restart postgresql
  systemctl restart "$CONTROLLER_SERVICE"
  systemctl restart "$MQTT_DISCOVERY_SERVICE"
  systemctl restart "$WEB_SERVICE"
  systemctl restart "$MQTT_CONSUMER_SERVICE"
}

print_status() {
  systemctl --no-pager --full status "$CONTROLLER_SERVICE" || true
  systemctl --no-pager --full status "$MQTT_DISCOVERY_SERVICE" || true
  systemctl --no-pager --full status "$WEB_SERVICE" || true
  systemctl --no-pager --full status "$MQTT_CONSUMER_SERVICE" || true
  echo
  echo "Victory Garden Pi install complete."
  echo "Web UI: http://$(hostname -I | awk '{print $1}'):3000"
  echo "Health check: http://$(hostname -I | awk '{print $1}'):3000/up"
}

ensure_supported_platform
ensure_system_packages
ensure_bundler
ensure_ruby_version
validate_release_manifest
if release_install; then
  ensure_release_bundle_complete
fi
ensure_python_controller_env
ensure_env_file
ensure_mosquitto_auth
ensure_postgres
ensure_rails_bundle
prepare_rails_db
install_controller_service
install_mqtt_discovery_service
install_web_service
install_mqtt_consumer_service
restart_services
print_status

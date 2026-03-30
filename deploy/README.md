# Pi Deployment

## Release Tarballs

Build target-specific release tarballs on matching Linux ARM hardware:

```bash
./deploy/build_release.sh --target linux-armv7
./deploy/build_release.sh --target linux-aarch64
```

Each tarball contains:

- app source
- deploy scripts
- `python_wheelhouse/`
- `ruby_service/vendor/bundle/`
- `ruby_service/vendor/cache/`
- `deploy/release_manifest.json`

Output:

- `deploy/releases/victory-garden-linux-armv7.tar.gz`
- `deploy/releases/victory-garden-linux-aarch64.tar.gz`

Build these artifacts on a matching Linux ARM host. Do not build them on macOS.

## Install From A Release Tarball

On the Pi:

1. Download or copy the correct target tarball.
2. Extract it.
3. Run:

```bash
cd victory-garden-linux-aarch64
sudo ./deploy/install_pi.sh
```

or:

```bash
cd victory-garden-linux-armv7
sudo ./deploy/install_pi.sh
```

The installer verifies that the Pi matches the packaged target before it continues.

Release installs are strict:

- packaged `ruby_service/vendor/bundle/` must already be complete for the target Pi
- packaged `python_wheelhouse/` is expected for fast Python setup
- if the packaged Rails bundle is incomplete, the installer fails instead of rebuilding gems on the user's Pi

That keeps first-time user installs deterministic and pushes native Ruby bundling back into the release-build step.

## Install From Source

For a single-Pi source install:

1. Copy or clone this repository onto the Pi.
2. Run:

```bash
cd victory_garden
sudo ./deploy/install_pi.sh
```

The script will:

- install system packages for Python, Ruby, PostgreSQL, and Mosquitto
- create `python_tools/.venv` on the Pi
- install the Python controller runtime dependencies
- reuse packaged `python_wheelhouse/` if present
- reuse packaged `ruby_service/vendor/bundle/` if present
- fall back to local `vendor/cache` or internet installs when needed
- create the production PostgreSQL role and databases
- run `db:prepare` and `db:seed`
- install or update systemd units for:
- `greenhouse.service`
- `victory-garden-actuator.service`
- `victory-garden-web.service`
- `victory-garden-mqtt-consumer.service`
- restart the full stack

Generated config:

- app env file: `/etc/victory_garden.env`
- example env template: [`victory_garden.env.example`](/Users/noel/coding/python/victory_garden/deploy/victory_garden.env.example)

Web endpoints after install:

- app: `http://<pi-ip>:3000`
- health: `http://<pi-ip>:3000/up`

Verify after install:

```bash
sudo systemctl status greenhouse.service --no-pager
sudo systemctl status victory-garden-actuator.service --no-pager
sudo systemctl status victory-garden-web.service --no-pager
sudo systemctl status victory-garden-mqtt-consumer.service --no-pager
sudo journalctl -u greenhouse.service -n 50 --no-pager
sudo journalctl -u victory-garden-actuator.service -n 50 --no-pager
sudo journalctl -u victory-garden-web.service -n 50 --no-pager
sudo journalctl -u victory-garden-mqtt-consumer.service -n 50 --no-pager
mosquitto_sub -h 127.0.0.1 -t 'greenhouse/zones/+/state' -v
```

Notes:

- The install script expects a Ruby version compatible with Rails 8. If the distro Ruby is too old, the script stops with a clear error.
- Release tarballs also pin the exact Ruby and Python versions used to build the packaged artifacts.
- Packaged release installs do not fall back to rebuilding Rails gems on the Pi. If `bundle check` fails, rebuild the tarball on a matching Linux ARM host.
- Production mode is configured for local Pi use without forced HTTPS by default. `RAILS_FORCE_SSL` and `RAILS_ASSUME_SSL` can be turned on later in `/etc/victory_garden.env`.

# Victory Garden Pi Image Pipeline

This directory contains the first working foundation for the `Get Victory Garden`
download path:

- one Raspberry Pi OS 64-bit image
- bundled Victory Garden app source
- bundled Pico W and Pico 2 W UF2 firmware
- a one-shot first-boot provisioning service
- versioned compressed image export
- checksum export
- desktop-installer handoff after first boot

## Scope of this first pass

This pipeline does three practical things:

1. stages the repo into `/opt/victory_garden` inside the image
2. stages the bundled Pico firmwares into `/opt/victory_garden/firmware-bundles`
3. enables a first-boot service that runs `deploy/install_pi.sh` once
4. exports a versioned `.img.xz` plus `.sha256`
5. can emit Raspberry Pi Imager repository JSON so Imager 2.x enables OS customisation

The first-boot service uses:

- `VICTORY_GARDEN_RUN_USER`
- `VG_FIRMWARE_BUNDLE_ROOT=/opt/victory_garden/firmware-bundles`
- `deploy/install_pi.sh --skip-system-packages`

That means the image build is expected to preinstall the system packages needed
by the existing installer backend, while first boot handles:

- env-file generation
- Mosquitto auth
- PostgreSQL role/database setup
- Rails bundle/runtime setup
- service installation and startup

## Build host

Build this image on Linux only.

Recommended target:

- Raspberry Pi OS 64-bit
- Linux `aarch64`

## Inputs

Before building, make sure the firmware toolchain is installed. The image build
now calls `deploy/build_firmware_bundles.sh` automatically and stages:

- `pico_w_sensor_node.uf2`
- `pico2_w_sensor_node.uf2`
- `pico_w_actuator_node.uf2`
- `pico2_w_actuator_node.uf2`

The desktop installer uses those bundled files immediately after first boot.

## Using pi-gen

1. Check out `pi-gen` on a Linux build host.
   Recommended branch for this pipeline:
   - `bookworm-arm64`
2. Run:

```bash
export VG_PI_FIRST_USER_PASS='choose-a-temporary-image-password'
export VG_PI_GEN_BRANCH='bookworm-arm64'
export VG_PI_IMAGER_BASE_URL='https://downloads.example.com/victory-garden'

./deploy/pi_image/build_pi_image.sh \
  --pi-gen-dir /path/to/pi-gen \
  --version 2026.05.27 \
  --image-name victory-garden-pi64
```

You must provide an initial password for the image user either through:

- `VG_PI_FIRST_USER_PASS`
- or `--first-user-pass PASSWORD`

Optional:

- `VG_PI_FIRST_USER_NAME`
- or `--first-user-name USERNAME`
- `VG_PI_GEN_BRANCH`
- or `--pi-gen-branch NAME`
- `VG_PI_IMAGER_BASE_URL`
- or `--imager-base-url URL`

The current pipeline keeps SSH enabled and disables the Raspberry Pi OS first-boot
rename flow, so `pi-gen` requires an explicit initial password.

The script will:

- package the current repo source
- copy the custom `stage-victory-garden` stage into the target `pi-gen` tree
- stage the repo tarball and bundled UF2s into that stage
- invoke `pi-gen`'s `build.sh`
- force `pi-gen` to leave an uncompressed `.img` internally
- export:
  - `deploy/pi_image/releases/victory-garden-pi64-<version>.img.xz`
  - `deploy/pi_image/releases/victory-garden-pi64-<version>.img.xz.sha256`
  - and, if `VG_PI_IMAGER_BASE_URL` or `--imager-base-url` is provided:
    - `deploy/pi_image/releases/victory-garden-pi64-<version>.imager-repo.json`

The image currently uses:

- hostname: `victory-garden`
- mDNS support via `avahi-daemon`
- default first user name: `pi`

## Raspberry Pi Imager 2.x support

Raspberry Pi Imager 2.x disables the `Customisation` step for `Use custom`
images loaded directly from disk. Raspberry Pi's repository format requires
metadata describing the image customisation mechanism (`init_format`) before the
UI will unlock hostname, Wi-Fi, user, and SSH preseed options.

Victory Garden uses the legacy Raspberry Pi OS `systemd` / `firstrun.sh`
customisation flow, so the generated repo JSON sets:

- `init_format: "systemd"`

This is why the pipeline can optionally emit an Imager repository JSON file.

### Hosted image flow

If you plan to publish a real `Get Victory Garden` download:

1. host the image, checksum, and generated `.imager-repo.json`
2. point Raspberry Pi Imager at that repository JSON
3. let users install through the repository entry instead of `Use custom`

That restores the `Customisation` step in Imager 2.x.

### Local/offline image flow

If you already downloaded an image to a machine and want Imager 2.x to treat it
as customisable, generate a small local repository JSON that points at the local
file:

```bash
python3 ./deploy/pi_image/generate_imager_repo.py \
  --image /path/to/victory-garden-pi64-2026.05.27.img.xz \
  --output /path/to/victory-garden-pi64-2026.05.27.imager-repo.json
```

Then in Raspberry Pi Imager:

1. open `App Options`
2. set the custom content repository to that local `.imager-repo.json`
3. restart the session when Imager prompts
4. choose the Victory Garden OS entry from the repo instead of `Use custom`

With that metadata in place, the `Customisation` step becomes available again.

## Resulting first-boot flow

After the user flashes the image and boots the Pi:

1. `victory-garden-firstboot.service` runs once
2. Victory Garden installs/configures itself
3. services start
4. the user opens the Victory Garden desktop installer
5. the installer finds the Pi, flashes and provisions the Pico boards, then validates setup

## Current limitation

This is the pipeline foundation, not the final polished distribution system yet.

Still to do after this pass:

- tighter image branding and hostname defaults
- mDNS-first discovery UX
- signed and notarized desktop installer artifacts

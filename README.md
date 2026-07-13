# Roon Server QPKG for QNAP (Container Station Containerized Package)

English | [繁體中文](README.zh-TW.md)

[![Build QPKG](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)

Based on the [qnap-dev/containerized-qpkg](https://github.com/qnap-dev/containerized-qpkg) architecture, this package wraps the [official RoonLabs Docker image](https://github.com/RoonLabs/roon-docker) (`ghcr.io/roonlabs/roonserver`) into an installable QPKG for QNAP App Center.

**This package only contains management scripts and a status page (UI wrapper); it does not include any Roon software or images.**
When a user installs it in App Center, the package runs the container engine (docker CLI of Container Station) in the background to download the official image and build the container. The installation itself takes only a few seconds.

```
App Center installs QPKG (scripts & status UI only, < 1 MB)
        │
        ▼
package_routines ──► Background: docker pull ghcr.io/roonlabs/roonserver:latest
        │
        ▼
roon-server-docker.sh start ──► docker run --net=host -v <SSD>/RoonServer/data:/Roon ...
                            └───► busybox httpd container (port 18630) for status UI
```

> The internal package name is `RoonServerDocker` (displayed as "Roon Server (Docker)").
> This is intentionally different from the QNAP Store package name "RoonServer" — identical names would cause App Center to misidentify it and force-overwrite it with the store version during updates.

## System Requirements

| Item | Requirement |
|---|---|
| NAS Arch | **x86_64 (amd64)**, official Roon image does not support ARM |
| QTS | 5.0 or above |
| Dependency | **Container Station 3.0+** (`QPKG_REQUIRE` automatically checks this) |
| Memory | 8 GB or more recommended (Roon Labs recommendation) |
| Storage | **SSD storage pool is strongly recommended** for the Roon database |

## Installation

1. Download `RoonServerDocker_x.y.z_x86_64.qpkg` from [Releases](../../releases).
2. (If you have installed the old 1.0.0 version of the "RoonServer" package, please remove it from App Center first.)
3. App Center → Click "Install Manually" in the top-right corner → Choose the downloaded qpkg file. Since the package is unsigned, if App Center blocks it, go to "App Center → Settings → General" to allow installing unsigned applications.
4. After installation, the image will download in the **background** (takes a few minutes depending on network speed), and the container will be created and started automatically.
   You can check the download progress at `<installation path>/logs/pull.log`, or click the App Center/desktop icon to open the status page (`http://<NAS IP>:18630/`, served by the package's internal busybox httpd container — **no need** to enable QTS "Web Server" service).
5. Open the [Roon App](https://roon.app/downloads) on a computer/tablet connected to the same local network; it will automatically discover the Roon Server on your NAS.

## Two Critical Design Aspects

### 1. Hardcoded Host Network Mode

Roon relies on **local network multicast/broadcast** (RAAT protocol) to discover streaming playback devices (Roon Ready, AirPlay, Chromecast) and remote control apps. Bridge/NAT networks will block multicast packets, **rendering device discovery and remote control entirely non-functional**.

Therefore, `roon-server-docker.sh` hardcodes `--net=host`, and **checks the container's network mode on every startup**. If it is altered via the Container Station UI, it will automatically recreate the container in host mode (your Roon database remains unaffected). This setting cannot be overridden by `ROON_EXTRA_ARGS` in `roon.conf`.

### 2. Database & Cache Must Be Placed in an SSD Storage Pool

The Roon database and cache (mounted as `/Roon` inside the container) perform heavy small-block random reads/writes. Storing them on a mechanical hard drive (HDD) volume causes high latency, leading to **stuttering audio playback, slow playlist/library loading, and sluggish searches**. The package guides users in three ways:

- **Startup Detection**: The service script performs a best-effort check using `/sys/block/*/queue/rotational`. If the data path is located on an HDD, it logs a QTS system warning event and displays a warning banner on the status page.
- **Web UI Instruction**: The status page (accessible by clicking the app icon) contains a step-by-step migration guide.
- **Configuration Comments**: Comments in `roon.conf` specify SSD recommendations in uppercase.

Configuration steps:

```sh
# Log in to the NAS via SSH, edit <QPKG Installation Path>/roon.conf
ROON_DATA_PATH="/share/CACHEDEV2_DATA/RoonServer/data"   # Point to an SSD volume path

# To migrate an existing database:
/etc/init.d/roon-server-docker.sh stop
cp -a /share/CACHEDEV1_DATA/RoonServer/data/. /share/CACHEDEV2_DATA/RoonServer/data/
/etc/init.d/roon-server-docker.sh start
```

> **How to confirm which volume is on an SSD pool**: Open QTS "Storage & Snapshots Manager" → Storage, and check the disk type of the member drives in the storage pool (must be a pure SSD pool; SSD "cache" does not count).

## Configuration File (roon.conf)

| Variable | Default | Description |
|---|---|---|
| `ROON_IMAGE` | `ghcr.io/roonlabs/roonserver:latest` | Official image |
| `ROON_DATA_PATH` | `<default volume>/RoonServer/data` | Roon database/cache → container `/Roon`, **please use SSD** |
| `ROON_MUSIC_PATH` | Auto-detects Multimedia/Music/Public shares | Music library → container `/Music` |
| `ROON_BACKUP_PATH` | (Empty = not mounted) | Backup → container `/RoonBackups` |
| `ROON_TZ` | Auto-detects QTS timezone | IANA timezone name |
| `ROON_STOP_TIMEOUT` | `120` | Seconds to wait for a clean database shutdown on stop |
| `ROON_UI_PORT` | `18630` | Status page port (App Center icon link follows this automatically) |
| `ROON_UI_IMAGE` | `busybox:stable` | Mini httpd container image for the status page |
| `ROON_EXTRA_ARGS` | (Empty) | Extra `docker run` arguments (cannot override network mode) |

After making changes, run `/etc/init.d/roon-server-docker.sh restart` or restart the package from App Center.
The configuration file is preserved during upgrades and re-installations.

### Config Folders from Status Page (1.2.0+, SSH-free)

The status page includes a "Folder Settings" form where you can directly modify the mount paths for Music, Database, and Backup, with suggestions of existing shared folders on the NAS. Once saved, the host checks and applies the settings and recreates the container **within 1 minute**:

- Paths must be under `/share/<shared-folder-or-volume>/`. Any music path containing special characters or paths that do not exist will be rejected and logged to system events;
- The form settings are saved as a pending file by a minimal CGI script inside the UI container. **Parsing and validation are done entirely by host-side scripts**; the UI container itself has no access to docker or host settings;
- Changing the database path does not automatically migrate existing data (see the migration steps above).

## Maintenance Commands

```sh
/etc/init.d/roon-server-docker.sh status    # Check status
/etc/init.d/roon-server-docker.sh restart   # Restart
/etc/init.d/roon-server-docker.sh update    # Pull new official image & rebuild container (database is kept)
/etc/init.d/roon-server-docker.sh pull      # Only pull the image
```

Uninstalling the package deletes the container but **preserves** the Roon database under `ROON_DATA_PATH` to prevent accidental loss of licenses and listening history.

## Building from Source

```sh
# Requires Docker (any platform)
make            # Outputs build/RoonServerDocker_<version>_x86_64.qpkg

# Or directly using QDK on Ubuntu
git clone https://github.com/qnap-dev/QDK && cd QDK && sudo ./InstallToUbuntu.sh install
cd <this-project> && qbuild --build-arch x86_64
```

GitHub Actions builds the qpkg artifact on every push and automatically publishes a release when a `v*` tag is pushed.

## Project Structure

```
├── qpkg.cfg                  # QPKG metadata (CS dependency, WebUI URL)
├── package_routines          # Install/remove hooks: background pull, config & DB preservation
├── shared/
│   ├── roon-server-docker.sh # Service script: finds docker, enforces host network, SSD check, status UI
│   ├── roon.conf.default     # User configuration template
│   └── web/index.html        # Status page / guide (UI wrapper, served by busybox httpd)
├── icons/                    # App Center icons
├── x86_64/                   # qbuild architecture tag (this package is script-only)
├── Dockerfile / Makefile     # QDK build files
└── .github/workflows/        # CI: Build and Release
```

## Troubleshooting

| Symptom | Cause & Solution |
|---|---|
| App Center shows "Update available" and forces an update | You are using the old 1.0.0 version (internal name `RoonServer`, identical to the store package). Please remove the old version and install 1.1.0+ (internal name `RoonServerDocker`, which avoids conflicts). |
| Shows "No digital signature" | This package is not signed by QNAP; this is normal. Go to App Center settings to allow unsigned applications. |
| Click icon but status page doesn't open | The status page is served by the package's busybox httpd container on port `18630`. Verify that the package is running. If the port is occupied, change `ROON_UI_PORT` in `roon.conf` and restart. |
| Roon App cannot find the server | Ensure the container network is in host mode (this app fixes it on every boot), that the NAS and remote are on the same subnet, and that the image download has finished (check the status page or `logs/pull.log`). |
| Image download stuck | SSH and run `/etc/init.d/roon-server-docker.sh diag` to check DNS/registry access; you can also run `docker pull ghcr.io/roonlabs/roonserver:latest` to observe errors, then `restart`. The status page displays real-time pull progress (1.1.1+). |
| Roon gets `UnexpectedError` when adding SMB network shares | This is expected: Roon runs inside a container and cannot (and does not need to) mount SMB. Use Roon "Settings → Storage → **Add folder**" and select `/Music`. To change the music path, use "Folder Settings" on the status page. |
| System log says "Music path does not exist" | The default music path guess was wrong (from 1.2.0, the app auto-detects Multimedia/Music/Public shares from `smb.conf`). Go to the status page "Folder Settings" and point the music library to your actual shared folder. |

## License & Trademark

The management scripts are licensed under the MIT License. Roon and Roon Server are products of Roon Labs LLC, and their software/images are subject to Roon Labs' own terms of service. This project is not affiliated with Roon Labs or QNAP.

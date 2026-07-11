#!/bin/sh
######################################################################
# Roon Server (Docker) QPKG service script
#
# Thin management shell around the official RoonLabs Docker image.
# The QPKG itself ships no binaries: on start it asks the system
# container engine (Container Station) to pull/create the containers.
#
# Two containers are managed:
#   * roonserver      the official Roon image, --net=host (mandatory:
#                     Roon relies on LAN multicast for RAAT device &
#                     remote discovery; bridge/NAT breaks it entirely.
#                     Host mode is re-verified on every start.)
#   * roonserver-ui   a tiny busybox httpd serving the status page on
#                     ROON_UI_PORT (default 18630), so the UI works
#                     without the optional QTS "Web Server" service.
#
# The Roon database is extremely sensitive to random-IO latency, so we
# warn loudly (system log + status page) whenever the configured data
# path does not look like it lives on an SSD volume.
#
# Usage: roon-server-docker.sh {start|stop|restart|status|pull|update|remove}
######################################################################

CONF="/etc/config/qpkg.conf"
QPKG_NAME="RoonServerDocker"
QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f "$CONF")
ROON_CONF="$QPKG_ROOT/roon.conf"
LOG_DIR="$QPKG_ROOT/logs"
LOG_FILE="$LOG_DIR/roon-server.log"
PULL_LOG="$LOG_DIR/pull.log"
WEB_DIR="$QPKG_ROOT/web"
STATUS_JSON="$WEB_DIR/status.json"

mkdir -p "$LOG_DIR" 2>/dev/null

# ---------------------------------------------------------------- utils

log() {
    # $1 = message, $2 = QTS event level (1=Error, 2=Warning, 4=Information)
    /sbin/write_log "[$QPKG_NAME] $1" "${2:-4}" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$([ "${2:-4}" = 1 ] && echo ERROR || { [ "${2:-4}" = 2 ] && echo WARN || echo INFO; })] $1" >> "$LOG_FILE"
}

# Locate the docker CLI provided by Container Station. We prefer the
# regular "docker" binary so the containers stay visible/manageable in
# the Container Station UI, and fall back to system-docker.
find_docker() {
    CS_DIR=$(/sbin/getcfg container-station Install_Path -f "$CONF" 2>/dev/null)
    for BIN in \
        "$CS_DIR/bin/docker" \
        /usr/local/bin/docker \
        /usr/local/bin/system-docker \
        "$CS_DIR/bin/system-docker"
    do
        [ -n "$BIN" ] && [ -x "$BIN" ] && { echo "$BIN"; return 0; }
    done
    command -v docker 2>/dev/null && return 0
    return 1
}

# Map the QTS timezone to an IANA name for the container (best effort).
detect_tz() {
    TZNAME=$(/sbin/getcfg System "Time Zone" -f /etc/config/uLinux.conf 2>/dev/null)
    case "$TZNAME" in
        */*) echo "$TZNAME" ;;
        *)   echo "UTC" ;;
    esac
}

# Default volume mount point (e.g. /share/CACHEDEV1_DATA).
default_volume() {
    DEFVOL=$(/sbin/getcfg SHARE_DEF defVolMP -f /etc/config/def_share.info 2>/dev/null)
    [ -n "$DEFVOL" ] && echo "$DEFVOL" || echo "/share/CACHEDEV1_DATA"
}

load_conf() {
    [ -f "$ROON_CONF" ] && . "$ROON_CONF"

    ROON_IMAGE="${ROON_IMAGE:-ghcr.io/roonlabs/roonserver:latest}"
    ROON_CONTAINER_NAME="${ROON_CONTAINER_NAME:-roonserver}"
    ROON_DATA_PATH="${ROON_DATA_PATH:-$(default_volume)/RoonServer/data}"
    ROON_MUSIC_PATH="${ROON_MUSIC_PATH:-/share/Multimedia}"
    ROON_BACKUP_PATH="${ROON_BACKUP_PATH:-}"
    ROON_TZ="${ROON_TZ:-$(detect_tz)}"
    ROON_EXTRA_ARGS="${ROON_EXTRA_ARGS:-}"
    ROON_STOP_TIMEOUT="${ROON_STOP_TIMEOUT:-120}"
    ROON_UI_PORT="${ROON_UI_PORT:-18630}"
    ROON_UI_IMAGE="${ROON_UI_IMAGE:-busybox:stable}"
    UI_NAME="${ROON_CONTAINER_NAME}-ui"
}

# Best-effort SSD detection for the Roon database path.
# Echoes: "ssd" | "hdd" | "unknown"
data_media_type() {
    DEV=$(df -P "$1" 2>/dev/null | awk 'NR==2{print $1}')
    BASE=$(basename "$DEV" 2>/dev/null)
    # strip partition suffixes: sda1 -> sda, nvme0n1p1 -> nvme0n1
    case "$BASE" in
        nvme*) BASE=$(echo "$BASE" | sed 's/p[0-9]*$//') ;;
        *)     BASE=$(echo "$BASE" | sed 's/[0-9]*$//') ;;
    esac
    ROT_FILE="/sys/block/$BASE/queue/rotational"
    if [ -r "$ROT_FILE" ]; then
        if [ "$(cat "$ROT_FILE")" = "0" ]; then echo "ssd"; else echo "hdd"; fi
    else
        # md / dm-cachedev devices cannot be classified reliably
        echo "unknown"
    fi
}

ssd_advice() {
    MEDIA=$(data_media_type "$ROON_DATA_PATH")
    case "$MEDIA" in
        hdd)
            log "Roon database path '$ROON_DATA_PATH' is on a ROTATIONAL disk. Random-IO latency on HDDs causes slow audio analysis, laggy playlist/library loading and sluggish searches. Please move ROON_DATA_PATH in $ROON_CONF to a share on an SSD storage pool, then run: $0 restart" 2
            ;;
        unknown)
            log "Could not verify whether '$ROON_DATA_PATH' is on an SSD volume. For a responsive Roon library, make sure this path is on an SSD storage pool (see the status page for details)." 4
            ;;
    esac
    echo "$MEDIA"
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_status() {
    # $1 = state string
    MEDIA="${2:-$(data_media_type "$ROON_DATA_PATH")}"
    mkdir -p "$WEB_DIR" 2>/dev/null
    cat > "$STATUS_JSON" <<EOF
{
  "state": "$(json_escape "$1")",
  "image": "$(json_escape "$ROON_IMAGE")",
  "container": "$(json_escape "$ROON_CONTAINER_NAME")",
  "network_mode": "host",
  "data_path": "$(json_escape "$ROON_DATA_PATH")",
  "music_path": "$(json_escape "$ROON_MUSIC_PATH")",
  "backup_path": "$(json_escape "$ROON_BACKUP_PATH")",
  "data_media": "$(json_escape "$MEDIA")",
  "tz": "$(json_escape "$ROON_TZ")",
  "updated_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
}

# ------------------------------------------------------------- container

image_present() {
    [ -n "$("$DOCKER" images -q "$ROON_IMAGE" 2>/dev/null)" ]
}

container_exists() {
    "$DOCKER" inspect "$ROON_CONTAINER_NAME" >/dev/null 2>&1
}

container_running() {
    [ "$("$DOCKER" inspect -f '{{.State.Running}}' "$ROON_CONTAINER_NAME" 2>/dev/null)" = "true" ]
}

container_net_mode() {
    "$DOCKER" inspect -f '{{.HostConfig.NetworkMode}}' "$ROON_CONTAINER_NAME" 2>/dev/null
}

run_container() {
    mkdir -p "$ROON_DATA_PATH"
    [ -n "$ROON_BACKUP_PATH" ] && mkdir -p "$ROON_BACKUP_PATH"
    if [ ! -d "$ROON_MUSIC_PATH" ]; then
        log "Music path '$ROON_MUSIC_PATH' does not exist; creating it. Point ROON_MUSIC_PATH in $ROON_CONF at your music share if this is wrong." 2
        mkdir -p "$ROON_MUSIC_PATH"
    fi

    # --net=host is mandatory: Roon uses LAN multicast/broadcast (RAAT)
    # to discover audio endpoints and remote-control apps. Do not change.
    "$DOCKER" run -d \
        --name "$ROON_CONTAINER_NAME" \
        --net=host \
        --restart unless-stopped \
        -e TZ="$ROON_TZ" \
        -v "$ROON_DATA_PATH":/Roon \
        -v "$ROON_MUSIC_PATH":/Music \
        ${ROON_BACKUP_PATH:+-v "$ROON_BACKUP_PATH":/RoonBackups} \
        $ROON_EXTRA_ARGS \
        "$ROON_IMAGE" >/dev/null
}

# ----- status-page container (busybox httpd on ROON_UI_PORT) ---------

ui_current_port() {
    "$DOCKER" inspect \
        -f '{{range $p, $b := .HostConfig.PortBindings}}{{(index $b 0).HostPort}}{{end}}' \
        "$UI_NAME" 2>/dev/null
}

start_ui() {
    if "$DOCKER" inspect "$UI_NAME" >/dev/null 2>&1; then
        if [ "$(ui_current_port)" = "$ROON_UI_PORT" ]; then
            "$DOCKER" start "$UI_NAME" >/dev/null 2>&1
            return 0
        fi
        "$DOCKER" rm -f "$UI_NAME" >/dev/null 2>&1
    fi
    if [ -z "$("$DOCKER" images -q "$ROON_UI_IMAGE" 2>/dev/null)" ]; then
        "$DOCKER" pull "$ROON_UI_IMAGE" >> "$PULL_LOG" 2>&1 || {
            log "Could not pull '$ROON_UI_IMAGE' for the status page; Roon itself is unaffected. See $PULL_LOG." 2
            return 1
        }
    fi
    "$DOCKER" run -d \
        --name "$UI_NAME" \
        --restart unless-stopped \
        -p "$ROON_UI_PORT":80 \
        -v "$WEB_DIR":/www:ro \
        "$ROON_UI_IMAGE" httpd -f -p 80 -h /www >/dev/null 2>&1 \
        || log "Failed to start the status-page container on port $ROON_UI_PORT (port in use?). Set ROON_UI_PORT in $ROON_CONF to a free port and restart." 2
    # Keep the App Center / desktop icon pointing at the right port.
    /sbin/setcfg "$QPKG_NAME" Web_Port "$ROON_UI_PORT" -f "$CONF" 2>/dev/null
}

stop_ui() {
    "$DOCKER" stop "$UI_NAME" >/dev/null 2>&1
}

remove_ui() {
    "$DOCKER" rm -f "$UI_NAME" >/dev/null 2>&1
}

# ---------------------------------------------------------------- flow

pull_image() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') pulling $ROON_IMAGE" >> "$PULL_LOG"
    "$DOCKER" pull "$ROON_IMAGE" >> "$PULL_LOG" 2>&1
}

# Spawn a fully detached background pull. setsid puts the job in its
# own session so it survives App Center killing the install/start
# script's process group (plain nohup children can be reaped with it,
# leaving the pull never actually running).
spawn_bgpull() {
    SELF="$QPKG_ROOT/roon-server-docker.sh"
    if command -v setsid >/dev/null 2>&1; then
        setsid "$SELF" _bg_pull </dev/null >/dev/null 2>&1 &
    else
        nohup "$SELF" _bg_pull </dev/null >/dev/null 2>&1 &
    fi
}

# Pull in the background, then create + start the container.
# Used on first start so App Center installation returns immediately.
pull_and_run_bg() {
    write_status "downloading-image"
    log "Roon image '$ROON_IMAGE' not present yet. Container Station is downloading it in the background; Roon Server will start automatically when the download finishes (progress: $PULL_LOG)." 4
    spawn_bgpull
}

finish_after_pull() {
    if container_exists || run_container; then
        write_status "running"
        log "Roon image downloaded; Roon Server container created and started (host network)." 4
    else
        write_status "error"
        log "Image downloaded but the container could not be created. See $LOG_FILE." 1
    fi
}

do_start() {
    MEDIA=$(ssd_advice)
    write_status "starting" "$MEDIA"
    start_ui

    if container_exists; then
        # Guarantee host networking even if the container was altered
        # from the Container Station UI.
        if [ "$(container_net_mode)" != "host" ]; then
            log "Existing container is not in host network mode; recreating it with --net=host (required for Roon device/remote discovery)." 2
            "$DOCKER" rm -f "$ROON_CONTAINER_NAME" >/dev/null 2>&1
            run_container || { write_status "error"; log "Failed to recreate the Roon container. See $LOG_FILE and $PULL_LOG." 1; return 1; }
        elif ! container_running; then
            "$DOCKER" start "$ROON_CONTAINER_NAME" >/dev/null || { write_status "error"; log "Failed to start the Roon container." 1; return 1; }
        fi
        write_status "running" "$MEDIA"
        log "Roon Server started (container '$ROON_CONTAINER_NAME', host network)." 4
        return 0
    fi

    if image_present; then
        run_container || { write_status "error"; log "Failed to create the Roon container." 1; return 1; }
        write_status "running" "$MEDIA"
        log "Roon Server container created and started (host network, data: $ROON_DATA_PATH)." 4
    else
        pull_and_run_bg
    fi
}

do_stop() {
    if container_exists; then
        # Roon's database wants a clean shutdown; give it time.
        "$DOCKER" stop -t "$ROON_STOP_TIMEOUT" "$ROON_CONTAINER_NAME" >/dev/null 2>&1
    fi
    write_status "stopped"
    stop_ui
    log "Roon Server stopped." 4
}

do_remove() {
    if container_exists; then
        "$DOCKER" rm -f "$ROON_CONTAINER_NAME" >/dev/null 2>&1
    fi
    remove_ui
    log "Roon containers removed. Your Roon database in '$ROON_DATA_PATH' was kept." 4
}

do_update() {
    log "Updating Roon image '$ROON_IMAGE'..." 4
    pull_image || { log "Image update failed; keeping the current container. See $PULL_LOG." 1; return 1; }
    if container_exists; then
        "$DOCKER" stop -t "$ROON_STOP_TIMEOUT" "$ROON_CONTAINER_NAME" >/dev/null 2>&1
        "$DOCKER" rm "$ROON_CONTAINER_NAME" >/dev/null 2>&1
    fi
    run_container && write_status "running" && log "Roon Server updated and restarted." 4
}

do_status() {
    if container_running; then
        echo "$QPKG_NAME is running (container '$ROON_CONTAINER_NAME', host network)."
        exit 0
    else
        echo "$QPKG_NAME is not running."
        exit 1
    fi
}

# --------------------------------------------------------------- main

DOCKER=$(find_docker)
if [ -z "$DOCKER" ]; then
    log "Container Station docker CLI not found. Please install/enable Container Station and restart this app." 1
    write_status "no-container-engine"
    [ "$1" = "start" ] && exit 1
fi

load_conf

case "$1" in
    start)
        ENABLED=$(/sbin/getcfg "$QPKG_NAME" Enable -u -d FALSE -f "$CONF")
        [ "$ENABLED" = "TRUE" ] || { echo "$QPKG_NAME is disabled."; exit 1; }
        do_start
        ;;
    stop)
        do_stop
        ;;
    restart)
        do_stop
        do_start
        ;;
    status)
        do_status
        ;;
    pull)
        # synchronous pull (CLI use)
        image_present || pull_image
        ;;
    bgpull)
        # detached background pull; returns immediately (App Center use)
        image_present || spawn_bgpull
        ;;
    update)
        do_update
        ;;
    remove)
        do_remove
        ;;
    diag)
        echo "docker CLI : $DOCKER"
        "$DOCKER" version 2>&1 | head -n 6
        echo "--- ghcr.io DNS ---"
        nslookup ghcr.io 2>&1 | head -n 6
        echo "--- roon/busybox images ---"
        "$DOCKER" images 2>/dev/null | grep -E 'REPOSITORY|roon|busybox'
        echo "--- containers ---"
        "$DOCKER" ps -a 2>/dev/null | grep -E 'CONTAINER|roon'
        echo "--- data path ---"
        echo "ROON_DATA_PATH=$ROON_DATA_PATH (media: $(data_media_type "$ROON_DATA_PATH"))"
        echo "--- last pull log ($PULL_LOG) ---"
        tail -n 20 "$PULL_LOG" 2>/dev/null || echo "(no pull log yet)"
        ;;
    _bg_pull)
        # internal, runs detached: pull with live progress for the UI
        PIDFILE="$LOG_DIR/pull.pid"
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
            exit 0  # a pull is already running
        fi
        echo $$ > "$PIDFILE"
        write_status "downloading-image"
        ( pull_image; echo $? > "$LOG_DIR/pull.rc" ) &
        PULL_JOB=$!
        while kill -0 "$PULL_JOB" 2>/dev/null; do
            tail -n 15 "$PULL_LOG" > "$WEB_DIR/pull-progress.txt" 2>/dev/null
            sleep 5
        done
        rm -f "$PIDFILE"
        if [ "$(cat "$LOG_DIR/pull.rc" 2>/dev/null)" = "0" ]; then
            rm -f "$WEB_DIR/pull-progress.txt"
            finish_after_pull
        else
            tail -n 15 "$PULL_LOG" > "$WEB_DIR/pull-progress.txt" 2>/dev/null
            write_status "pull-failed"
            log "Downloading the Roon image failed. Run '$QPKG_ROOT/roon-server-docker.sh diag' to check DNS/registry access, then restart the app. Details: $PULL_LOG" 1
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|pull|bgpull|update|remove|diag}"
        exit 1
        ;;
esac

exit 0

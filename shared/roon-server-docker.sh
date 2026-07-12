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
# Settings saved from the status page land here (via the UI container's
# CGI); "apply-pending" (cron, every minute) validates and applies them.
INBOX_DIR="$QPKG_ROOT/inbox"

mkdir -p "$LOG_DIR" 2>/dev/null

# Detached background jobs can inherit a deleted cwd (App Center's temp
# extract dir), which makes every subshell print getcwd errors.
cd / 2>/dev/null

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

# Default volume mount point (e.g. /share/CACHEDEV1_DATA, /share/ZFS530_DATA).
default_volume() {
    DEFVOL=$(/sbin/getcfg SHARE_DEF defVolMP -f /etc/config/def_share.info 2>/dev/null)
    [ -n "$DEFVOL" ] && echo "$DEFVOL" || echo "/share/CACHEDEV1_DATA"
}

# Resolve a real music share from smb.conf instead of guessing a /share
# name — share names/paths differ per NAS (QTS vs QuTS hero, renamed
# shares, multiple volumes).
detect_music_share() {
    for SH in Multimedia Music Public; do
        P=$(/sbin/getcfg "$SH" path -f /etc/config/smb.conf 2>/dev/null)
        [ -n "$P" ] && [ -d "$P" ] && { echo "$P"; return 0; }
    done
    echo ""
}

load_conf() {
    [ -f "$ROON_CONF" ] && . "$ROON_CONF"

    ROON_IMAGE="${ROON_IMAGE:-ghcr.io/roonlabs/roonserver:latest}"
    ROON_CONTAINER_NAME="${ROON_CONTAINER_NAME:-roonserver}"
    ROON_DATA_PATH="${ROON_DATA_PATH:-$(default_volume)/RoonServer/data}"
    ROON_MUSIC_PATH="${ROON_MUSIC_PATH:-$(detect_music_share)}"
    [ -n "$ROON_MUSIC_PATH" ] || ROON_MUSIC_PATH="$(default_volume)/RoonServer/music"
    ROON_BACKUP_PATH="${ROON_BACKUP_PATH:-}"
    ROON_TZ="${ROON_TZ:-$(detect_tz)}"
    ROON_EXTRA_ARGS="${ROON_EXTRA_ARGS:-}"
    ROON_STOP_TIMEOUT="${ROON_STOP_TIMEOUT:-120}"
    ROON_UI_PORT="${ROON_UI_PORT:-18630}"
    ROON_UI_IMAGE="${ROON_UI_IMAGE:-busybox:stable}"
    CS_WAIT_TIMEOUT="${CS_WAIT_TIMEOUT:-900}"
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

# "docker run" hit an existing container with our name: right after boot
# the object store can hide a container from inspect for a while, so the
# exists-guard misses it and run collides. The container is fine — start it.
name_conflict() {
    echo "$1" | grep -qi "is already in use by container"
}

run_container() {
    # Idempotent: an existing container is started, never "docker run"
    # over (that yields a name Conflict); recreate only if start fails.
    if container_exists; then
        container_running && return 0
        "$DOCKER" start "$ROON_CONTAINER_NAME" >/dev/null 2>&1 && return 0
        log "Existing Roon container failed to start; recreating it (database is kept)." 2
        "$DOCKER" rm -f "$ROON_CONTAINER_NAME" >/dev/null 2>&1
    fi
    mkdir -p "$ROON_DATA_PATH"
    [ -n "$ROON_BACKUP_PATH" ] && mkdir -p "$ROON_BACKUP_PATH"
    if [ ! -d "$ROON_MUSIC_PATH" ]; then
        # Never create directories directly under /share — that root is
        # tmpfs on QTS and anything made there vanishes on reboot.
        FALLBACK="$(default_volume)/RoonServer/music"
        log "Music path '$ROON_MUSIC_PATH' does not exist. Using '$FALLBACK' for now — set your real music share on the status page (資料夾設定)." 2
        ROON_MUSIC_PATH="$FALLBACK"
        mkdir -p "$ROON_MUSIC_PATH"
    fi

    # --net=host is mandatory: Roon uses LAN multicast/broadcast (RAAT)
    # to discover audio endpoints and remote-control apps. Do not change.
    OUT=$("$DOCKER" run -d \
        --name "$ROON_CONTAINER_NAME" \
        --net=host \
        --restart unless-stopped \
        -e TZ="$ROON_TZ" \
        -v "$ROON_DATA_PATH":/Roon \
        -v "$ROON_MUSIC_PATH":/Music \
        ${ROON_BACKUP_PATH:+-v "$ROON_BACKUP_PATH":/RoonBackups} \
        $ROON_EXTRA_ARGS \
        "$ROON_IMAGE" 2>&1 >/dev/null)
    RC=$?
    if [ $RC -ne 0 ] && name_conflict "$OUT"; then
        # the container was there all along, just invisible to inspect
        "$DOCKER" start "$ROON_CONTAINER_NAME" >/dev/null 2>&1 && return 0
    fi
    [ $RC -eq 0 ] || log "Failed to create the Roon container: $OUT" 1
    return $RC
}

# ----- status-page container (busybox httpd on ROON_UI_PORT) ---------

# List candidate folders for the settings form on the status page.
write_shares() {
    OUT="$WEB_DIR/shares.json"
    {
        printf '['
        FIRST=1
        for D in /share/*; do
            [ -d "$D" ] || continue
            case "$(basename "$D")" in
                external) continue ;;
            esac
            [ $FIRST = 1 ] || printf ','
            printf '"%s"' "$(json_escape "$D")"
            FIRST=0
        done
        printf ']'
    } > "$OUT" 2>/dev/null
}

start_ui() {
    # The UI container is stateless — recreate it on every start so it
    # always reflects the current port and mounts.
    "$DOCKER" rm -f "$UI_NAME" >/dev/null 2>&1
    mkdir -p "$INBOX_DIR"
    if [ -z "$("$DOCKER" images -q "$ROON_UI_IMAGE" 2>/dev/null)" ]; then
        "$DOCKER" pull "$ROON_UI_IMAGE" >> "$PULL_LOG" 2>&1 || {
            log "Could not pull '$ROON_UI_IMAGE' for the status page; Roon itself is unaffected. See $PULL_LOG." 2
            return 1
        }
    fi
    # The inbox is mounted OUTSIDE the read-only /www docroot: docker
    # cannot create a /www/inbox mountpoint inside an ro bind mount
    # ("read-only file system"), and this also keeps the pending file
    # from being served over HTTP.
    # Host networking on purpose: a dockerd-managed -p binding can leak
    # (dockerd keeps the port bound after the container is force-removed
    # during daemon churn, blocking the UI until the daemon restarts).
    # With --net host the socket dies with httpd.
    UI_ERR=$("$DOCKER" run -d \
        --name "$UI_NAME" \
        --restart unless-stopped \
        --net host \
        -v "$WEB_DIR":/www:ro \
        -v "$INBOX_DIR":/inbox \
        "$ROON_UI_IMAGE" httpd -f -p "$ROON_UI_PORT" -h /www 2>&1 >/dev/null) \
        || log "Failed to start the status-page container on port $ROON_UI_PORT: $UI_ERR — if the port is taken, set ROON_UI_PORT in $ROON_CONF to a free port and restart." 2
    # Keep the App Center / desktop icon pointing at the right port.
    /sbin/setcfg "$QPKG_NAME" Web_Port "$ROON_UI_PORT" -f "$CONF" 2>/dev/null
}

# A daemon hiccup can orphan the host-net httpd while removing its
# container record, leaving ROON_UI_PORT bound by a process docker no
# longer knows about. Kill strays by their exact cmdline signature —
# SIGKILL, because the httpd is PID 1 of its namespace and ignores TERM.
kill_stray_httpd() {
    for PID in $(ps 2>/dev/null | grep "httpd -f -p $ROON_UI_PORT" | grep -v grep | awk '{print $1}'); do
        kill -9 "$PID" 2>/dev/null
    done
}

stop_ui() {
    "$DOCKER" stop "$UI_NAME" >/dev/null 2>&1
    kill_stray_httpd
}

remove_ui() {
    "$DOCKER" rm -f "$UI_NAME" >/dev/null 2>&1
    kill_stray_httpd
}

# ---------------------------------------------------------------- flow

pull_image() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') pulling $ROON_IMAGE" >> "$PULL_LOG"
    "$DOCKER" pull "$ROON_IMAGE" >> "$PULL_LOG" 2>&1
}

# Spawn a fully detached background job ($1 = internal command). setsid
# puts the job in its own session so it survives App Center killing the
# install/start script's process group (plain nohup children can be
# reaped with it, leaving the job never actually running).
spawn_detached() {
    SELF="$QPKG_ROOT/roon-server-docker.sh"
    if command -v setsid >/dev/null 2>&1; then
        setsid "$SELF" "$1" </dev/null >/dev/null 2>&1 &
    else
        nohup "$SELF" "$1" </dev/null >/dev/null 2>&1 &
    fi
}

spawn_bgpull() {
    spawn_detached _bg_pull
}

# True once Container Station's docker daemon answers queries against
# its object store. "docker info" alone is NOT enough: right after CS
# starts it can answer info while inspect/images still come up empty.
docker_ready() {
    [ -n "$DOCKER" ] || DOCKER=$(find_docker)
    [ -n "$DOCKER" ] || return 1
    "$DOCKER" info >/dev/null 2>&1 && "$DOCKER" ps -q >/dev/null 2>&1
}

# Wait up to $1 seconds (default CS_WAIT_TIMEOUT) for the docker daemon.
# Needed at boot: this init script can run before Container Station has
# finished starting. Requires two consecutive successful polls 10s apart
# so a daemon that is up but still settling doesn't slip through.
wait_docker_ready() {
    LIMIT="${1:-$CS_WAIT_TIMEOUT}"
    WAITED=0
    OK=0
    while :; do
        if docker_ready; then
            OK=$((OK + 1))
            [ "$OK" -ge 2 ] && return 0
            # mid-confirmation: never abort on the timeout boundary here
        else
            OK=0
            [ "$WAITED" -ge "$LIMIT" ] && return 1
        fi
        sleep 10
        WAITED=$((WAITED + 10))
    done
}

# Start now if the container engine is up; otherwise finish the start
# in a detached background job once it is (never block the QTS boot
# sequence, and never mistake "daemon not up yet" for "image missing").
start_or_defer() {
    if docker_ready; then
        do_start
    else
        write_status "waiting-for-container-station"
        log "Container Station is not ready yet; Roon Server will start automatically as soon as it is." 4
        spawn_detached _bg_start
    fi
}

# Pull in the background, then create + start the container.
# Used on first start so App Center installation returns immediately.
pull_and_run_bg() {
    write_status "downloading-image"
    log "Roon image '$ROON_IMAGE' not present yet. Container Station is downloading it in the background; Roon Server will start automatically when the download finishes (progress: $PULL_LOG)." 4
    spawn_bgpull
}

# Update (or add) KEY="VALUE" in roon.conf.
set_conf_value() {
    touch "$ROON_CONF"
    if grep -q "^$1=" "$ROON_CONF" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=\"$2\"|" "$ROON_CONF"
    else
        echo "$1=\"$2\"" >> "$ROON_CONF"
    fi
}

# Validate and apply folder settings saved from the status page.
# Runs from cron every minute; a no-op when there is nothing pending.
# All parsing/validation happens here on the host — the CGI in the UI
# container only drops the raw request into the inbox.
apply_pending() {
    PENDING="$INBOX_DIR/pending.conf"
    [ -f "$PENDING" ] || return 0
    WORK="$PENDING.processing"
    mv "$PENDING" "$WORK" 2>/dev/null || return 0
    CHANGED=0
    while IFS='=' read -r K V; do
        case "$K" in
            ROON_MUSIC_PATH|ROON_DATA_PATH|ROON_BACKUP_PATH) ;;
            *) continue ;;
        esac
        V=$(printf '%s' "$V" | tr -d '\r')
        if [ -z "$V" ]; then
            # only the backup mount is optional
            if [ "$K" = "ROON_BACKUP_PATH" ]; then
                set_conf_value "$K" ""
                CHANGED=1
            fi
            continue
        fi
        case "$V" in
            /share/?*) ;;  # any folder under /share/ (share roots included)
            *) log "Rejected $K='$V' from the settings page (must be a folder under /share/)." 2; continue ;;
        esac
        case "$V" in
            */../*|*/..) log "Rejected $K from the settings page (path traversal)." 2; continue ;;
        esac
        # quotes/expansion break conf sourcing; ':' breaks docker -v syntax
        if printf '%s' "$V" | grep -q '["$`\\|:]'; then
            log "Rejected $K from the settings page (invalid characters in path)." 2
            continue
        fi
        if [ "$K" = "ROON_MUSIC_PATH" ] && [ ! -d "$V" ]; then
            log "Rejected ROON_MUSIC_PATH='$V' (folder does not exist)." 2
            continue
        fi
        # for data/backup the folder may be new, but its top-level
        # share/volume must already exist
        TOP=$(printf '%s' "$V" | cut -d/ -f1-3)
        if [ ! -d "$TOP" ]; then
            log "Rejected $K='$V' ('$TOP' does not exist)." 2
            continue
        fi
        set_conf_value "$K" "$V"
        CHANGED=1
    done < "$WORK"
    rm -f "$WORK"
    [ "$CHANGED" = 1 ] || return 0

    log "Folder settings from the status page applied; recreating the Roon container with the new mounts (database is kept)." 4
    . "$ROON_CONF"
    if container_exists; then
        "$DOCKER" stop -t "$ROON_STOP_TIMEOUT" "$ROON_CONTAINER_NAME" >/dev/null 2>&1
        "$DOCKER" rm "$ROON_CONTAINER_NAME" >/dev/null 2>&1
    fi
    if image_present; then
        if run_container; then
            write_status "running"
        else
            write_status "error"
            log "Failed to recreate the Roon container after the settings change. See $LOG_FILE." 1
        fi
    else
        # image still downloading — the new conf is picked up when the
        # container is created after the pull finishes
        write_status "downloading-image"
    fi
    write_shares
}

finish_after_pull() {
    # settings may have changed while the image was downloading
    [ -f "$ROON_CONF" ] && . "$ROON_CONF"
    load_conf
    if run_container; then
        touch "$QPKG_ROOT/.images-ready"
        write_status "running"
        log "Roon image downloaded; Roon Server container created and started (host network)." 4
    else
        write_status "error"
        log "Image downloaded but the container could not be created. See $LOG_FILE." 1
    fi
}

# Only ever called with the docker daemon confirmed up (start_or_defer /
# _bg_start / finish_after_pull gate on docker_ready first).
do_start() {
    MEDIA=$(ssd_advice)
    write_status "starting" "$MEDIA"
    write_shares
    start_ui

    # Guarantee host networking even if the container was altered
    # from the Container Station UI.
    if container_exists && [ "$(container_net_mode)" != "host" ]; then
        log "Existing container is not in host network mode; recreating it with --net=host (required for Roon device/remote discovery)." 2
        "$DOCKER" rm -f "$ROON_CONTAINER_NAME" >/dev/null 2>&1
    fi

    # run_container is idempotent: an existing container is started (or
    # recreated if broken), otherwise it is created from the image.
    if container_exists || image_present; then
        run_container || { write_status "error"; log "Failed to start the Roon container. See $LOG_FILE and $PULL_LOG." 1; return 1; }
        touch "$QPKG_ROOT/.images-ready"
        write_status "running" "$MEDIA"
        log "Roon Server started (container '$ROON_CONTAINER_NAME', host network)." 4
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
    rm -f "$QPKG_ROOT/.images-ready"
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
    # Not fatal for start/restart: at boot the CLI may not be reachable
    # yet — start_or_defer waits for Container Station in the background.
    case "$1" in
        start|restart|_bg_start) ;;
        *)
            log "Container Station docker CLI not found. Please install/enable Container Station and restart this app." 1
            write_status "no-container-engine"
            ;;
    esac
fi

load_conf

case "$1" in
    start)
        ENABLED=$(/sbin/getcfg "$QPKG_NAME" Enable -u -d FALSE -f "$CONF")
        [ "$ENABLED" = "TRUE" ] || { echo "$QPKG_NAME is disabled."; exit 1; }
        start_or_defer
        ;;
    stop)
        do_stop
        ;;
    restart)
        do_stop
        start_or_defer
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
    apply-pending)
        # cron (every minute): apply folder settings saved from the UI
        apply_pending
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
    _bg_start)
        # internal, runs detached from start/restart when the container
        # engine is not up yet (typically during boot): wait for it,
        # then do the real start.
        if wait_docker_ready; then
            # The daemon answers ps/info while its object store is still
            # loading, making existing containers/images look missing
            # (observed to last minutes after boot). The .images-ready
            # marker proves this app ran successfully before, so in that
            # case absence can only mean "store not loaded yet" — keep
            # waiting instead of falling into the download path.
            SETTLE=0
            LIMIT=60
            [ -f "$QPKG_ROOT/.images-ready" ] && LIMIT="$CS_WAIT_TIMEOUT"
            while [ "$SETTLE" -lt "$LIMIT" ]; do
                container_exists && break
                image_present && break
                sleep 10
                SETTLE=$((SETTLE + 10))
            done
            do_start
        else
            write_status "no-container-engine"
            log "Container Station did not become ready within ${CS_WAIT_TIMEOUT}s. Start this app from App Center once Container Station is running." 1
        fi
        ;;
    _bg_pull)
        # internal, runs detached: pull with live progress for the UI
        if ! wait_docker_ready; then
            write_status "no-container-engine"
            log "Container Station did not become ready within ${CS_WAIT_TIMEOUT}s; image download not started. Start this app from App Center once Container Station is running." 1
            exit 1
        fi
        PIDFILE="$LOG_DIR/pull.pid"
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
            exit 0  # a pull is already running
        fi
        echo $$ > "$PIDFILE"
        write_status "downloading-image"
        # Registry access / DNS can still be settling right after boot —
        # retry transient pull failures before declaring defeat.
        ( ATTEMPT=1
          while :; do
              pull_image && { echo 0 > "$LOG_DIR/pull.rc"; break; }
              [ "$ATTEMPT" -ge 3 ] && { echo 1 > "$LOG_DIR/pull.rc"; break; }
              ATTEMPT=$((ATTEMPT + 1))
              echo "$(date '+%Y-%m-%d %H:%M:%S') pull failed; retry $ATTEMPT/3 in 30s" >> "$PULL_LOG"
              sleep 30
          done ) &
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
        echo "Usage: $0 {start|stop|restart|status|pull|bgpull|update|remove|apply-pending|diag}"
        exit 1
        ;;
esac

exit 0

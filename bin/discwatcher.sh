#!/usr/bin/env bash
# discwatcher.sh — Auto-rip on disc insertion
# Runs as a launchd agent. Polls every 10s, triggers ~/bin/rip when a disc appears.

LOCK_FILE="/tmp/autorip.lock"
FAIL_FILE="/tmp/autorip.fail"
LOG_DIR="$HOME/.mediahub/logs"
LOG_FILE="$LOG_DIR/discwatcher.log"
RIP="$HOME/bin/rip"
MEDIA_ROOT="${MEDIA_ROOT:-/Volumes/M4Drive/media}"

log() {
    mkdir -p "$LOG_DIR" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null
}

check_disc() {
    drutil status 2>/dev/null | grep -qi "Type:.*DVD\|Type:.*BD"
}

check_audio_cd() {
    # Audio CDs mount as a volume with .aiff files
    for v in /Volumes/*/; do
        if ls "$v"*.aiff >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

log "Disc watcher started (PID $$)"
osascript -e 'display notification "Disc watcher is running" with title "Media Hub"' 2>/dev/null || true

while true; do
    # Wait for the destination dir to exist
    if [[ ! -d "$MEDIA_ROOT" ]]; then
        sleep 30
        continue
    fi

    if check_disc; then
        # Skip if already failed on this disc (waits for disc removal/reinsert)
        if [[ -f "$FAIL_FILE" ]]; then
            sleep 10; continue
        fi
        # Clear stale lock if rip process is no longer running
        if [[ -f "$LOCK_FILE" ]] && ! pgrep -f "bin/rip|makemkvcon|HandBrakeCLI" >/dev/null 2>&1; then
            log "Stale lock cleared (no rip process running)"
            rm -f "$LOCK_FILE"
        fi
        if [[ ! -f "$LOCK_FILE" ]]; then
            log "DVD/BD detected — starting rip..."
            osascript -e 'display notification "Disc detected — rip starting..." with title "Media Hub" sound name "Submarine"' 2>/dev/null || true
            touch "$LOCK_FILE"

            export PATH="$HOME/bin:$PATH"
            if "$RIP" >>"$LOG_FILE" 2>&1; then
                log "Rip completed successfully"
                rm -f "$FAIL_FILE"
            else
                log "Rip failed (exit $?) — waiting for disc removal before retry"
                touch "$FAIL_FILE"
            fi

            rm -f "$LOCK_FILE"

            # Wait for disc removal before next iteration. If rip auto-ejected
            # (success path in bin/rip), this exits immediately. If the eject
            # silently failed (drive busy, wrong /dev/diskN, etc.), this hangs
            # here until manual removal — preventing the same disc from being
            # ripped twice in a row.
            log "Waiting for disc removal..."
            while check_disc; do sleep 5; done
            log "Disc removed — ready for next disc"
        fi
    elif check_audio_cd; then
        if [[ -f "$FAIL_FILE" ]]; then
            sleep 10; continue
        fi
        # Clear stale lock if rip process is no longer running
        if [[ -f "$LOCK_FILE" ]] && ! pgrep -f "bin/rip|bin/ripcd|makemkvcon|HandBrakeCLI" >/dev/null 2>&1; then
            log "Stale lock cleared (no rip process running)"
            rm -f "$LOCK_FILE"
        fi
        if [[ ! -f "$LOCK_FILE" ]]; then
            log "Audio CD detected — starting rip..."
            osascript -e 'display notification "Audio CD detected — rip starting..." with title "Media Hub" sound name "Submarine"' 2>/dev/null || true
            touch "$LOCK_FILE"

            export PATH="$HOME/bin:$PATH"
            if "$HOME/bin/ripcd" >>"$LOG_FILE" 2>&1; then
                log "CD rip completed successfully"
                rm -f "$FAIL_FILE"
            else
                log "CD rip failed (exit $?) — waiting for disc removal"
                touch "$FAIL_FILE"
            fi

            rm -f "$LOCK_FILE"
            log "Ready for next disc"
        fi
    else
        # No disc — clear lock and fail flags so next disc can rip
        rm -f "$LOCK_FILE" "$FAIL_FILE"
    fi

    sleep 10
done

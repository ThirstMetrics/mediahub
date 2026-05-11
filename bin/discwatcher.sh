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

# Disc signature — used to detect "same disc still in" vs "new disc swapped in".
# Uses the drutil-reported block count of Space Used — available the moment
# the disc is detected (unlike Volume Name, which lags while macOS mounts).
# Different discs almost always have different block counts; the rare case
# of two discs with identical block counts is benign (they look the same).
# Empty when no disc is present.
disc_signature() {
    drutil status 2>/dev/null | awk '/Space Used:/{print $5; exit}'
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
            RIPPED_DISC_SIG=$(disc_signature)
            log "Disc signature: $RIPPED_DISC_SIG"

            export PATH="$HOME/bin:$PATH"
            if "$RIP" >>"$LOG_FILE" 2>&1; then
                log "Rip completed successfully"
                rm -f "$FAIL_FILE"
            else
                EXIT_CODE=$?
                log "Rip failed (exit $EXIT_CODE) — waiting for disc removal before retry"
                touch "$FAIL_FILE"
                # Notify the user immediately. Otherwise a failed rip is
                # silent and they only discover it next time they check.
                osascript -e "display notification \"Rip FAILED (exit ${EXIT_CODE}) — see discwatcher.log. Eject disc to retry.\" with title \"Media Hub\" sound name \"Basso\"" 2>/dev/null || true
                # Also try to eject so the disc isn't stuck — the rip script's
                # eject paths may not have run if it died early.
                drutil eject 2>/dev/null || diskutil eject "$(diskutil list 2>/dev/null | awk '/External, Physical/{print "/dev/"$NF}' | head -1)" 2>/dev/null || true
            fi

            rm -f "$LOCK_FILE"

            # Wait for disc removal OR disc swap before next iteration. The
            # earlier "while check_disc; do sleep 5" version could not tell
            # apart "same disc stuck in drive" from "new disc inserted" —
            # the rip would just hang forever if eject silently failed and
            # the user swapped in something new (2026-05-10 Kingsman bug).
            # Compare signature: if disc removed OR signature changed, proceed.
            RIPPED_SIG="$RIPPED_DISC_SIG"
            log "Waiting for disc removal or swap (last sig: ${RIPPED_SIG:-empty})..."
            while check_disc; do
                CUR_SIG=$(disc_signature)
                if [[ "$CUR_SIG" != "$RIPPED_SIG" ]]; then
                    log "Different disc detected (sig: $CUR_SIG) — proceeding"
                    break
                fi
                sleep 5
            done
            check_disc || log "Disc removed — ready for next disc"
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

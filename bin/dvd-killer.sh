#!/usr/bin/env bash
# dvd-killer.sh — Kill DVD Player.app on sight.
# Launch Services auto-launches DVD Player when a video DVD/BD mounts, bypassing
# digihub and launchctl-disable. This loop polls every 1s and pkills it.
# Runs as launchd agent com.mediahub.dvdkiller.

LOG_DIR="$HOME/.mediahub/logs"
LOG_FILE="$LOG_DIR/dvd-killer.log"
mkdir -p "$LOG_DIR" 2>/dev/null

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null; }

log "DVD killer started (PID $$)"

while true; do
    if pgrep -x "DVD Player" >/dev/null 2>&1; then
        pkill -9 -x "DVD Player" 2>/dev/null && log "Killed DVD Player"
    fi
    sleep 1
done

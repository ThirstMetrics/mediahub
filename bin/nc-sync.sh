#!/usr/bin/env bash
# nc-sync — periodic Nextcloud sync via nextcloudcmd CLI.
# Auth: ~/.netrc (mode 600). Local: /Volumes/M4Drive/Nextcloud.
#
# Skips silently if M4Drive isn't mounted (e.g. external drive disconnected).

set -u

LOCAL_PATH="/Volumes/M4Drive/Nextcloud"
SERVER_URL="https://calendar.thirstmetrics.com"
LOG_DIR="${HOME}/Library/Logs/nc-sync"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/sync.log"

# Bail if the volume isn't mounted — better to skip than dump conflict files
# into a half-mounted state.
if [ ! -d "$(dirname "${LOCAL_PATH}")" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') M4Drive not mounted, skip" >> "${LOG_FILE}"
  exit 0
fi

mkdir -p "${LOCAL_PATH}"

echo "$(date '+%Y-%m-%d %H:%M:%S') sync starting" >> "${LOG_FILE}"
/opt/homebrew/bin/nextcloudcmd \
  --non-interactive --silent -n \
  "${LOCAL_PATH}" "${SERVER_URL}" >> "${LOG_FILE}" 2>&1
rc=$?
echo "$(date '+%Y-%m-%d %H:%M:%S') sync rc=${rc}" >> "${LOG_FILE}"
exit "${rc}"

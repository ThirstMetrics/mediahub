#!/usr/bin/env bash
# Run git-audit then fire a macOS notification if any repos need attention.
# Triggered by launchd at 8am daily.

set -u

# Run the audit (writes ~/Nextcloud/_machines/<host>/git-state.md)
"${HOME}/bin/git-audit.sh"

HOSTNAME_SHORT="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
if [ -d "${HOME}/Nextcloud" ]; then
  STATE_FILE="${HOME}/Nextcloud/_machines/${HOSTNAME_SHORT}/git-state.md"
else
  STATE_FILE="${HOME}/Library/Logs/git-audit/git-state.md"
fi

# Pull "X of Y repos need attention" from the audit output
SUMMARY="$(grep -m1 'need attention' "${STATE_FILE}" 2>/dev/null | sed 's/[*]//g')"
NEEDS="$(echo "${SUMMARY}" | grep -oE '^[0-9]+' | head -1)"

if [ -n "${NEEDS}" ] && [ "${NEEDS}" != "0" ]; then
  TITLE="git: ${NEEDS} repos need attention"
  MSG="Open ~/Nextcloud/_machines/${HOSTNAME_SHORT}/git-state.md"
  /usr/bin/osascript -e "display notification \"${MSG}\" with title \"${TITLE}\" sound name \"Submarine\""
fi

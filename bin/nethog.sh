#!/usr/bin/env bash
# nethog — track daily WAN bandwidth, notify if today's use exceeds threshold.
#
# Strategy:
# - `netstat -ibn` gives cumulative bytes per interface since boot. We snapshot
#   the start-of-day value, and "today's usage" = current - start-of-day.
# - For per-process attribution, we run `nettop -P -L 1` whenever we update
#   the summary. This shows who's eating bandwidth *right now* (current rate),
#   not all-day totals. Daily per-process totals would need pcap or kernel
#   accounting — out of scope for a "quick" tool.
#
# Output:
# - ~/Nextcloud/_machines/<host>/bandwidth.md (synced to all machines via Nextcloud)
# - macOS notification once/day when threshold crossed

set -u

THRESHOLD_GB=5
STATE_DIR="${HOME}/Library/Application Support/nethog"
mkdir -p "${STATE_DIR}"

HOSTNAME_SHORT="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
TODAY="$(date +%Y-%m-%d)"
DAY_START_FILE="${STATE_DIR}/${TODAY}.start"
NOTIFY_MARKER="${STATE_DIR}/${TODAY}.notified"

if [ -d "${HOME}/Nextcloud" ]; then
  SUMMARY_DIR="${HOME}/Nextcloud/_machines/${HOSTNAME_SHORT}"
else
  SUMMARY_DIR="${HOME}/Library/Logs/nethog"
fi
mkdir -p "${SUMMARY_DIR}"
SUMMARY_FILE="${SUMMARY_DIR}/bandwidth.md"

# Current cumulative WAN bytes (sum of physical interfaces, excludes loopback/utun/awdl/etc).
get_total_bytes() {
  netstat -ibn | awk '
    /^en[0-9]+/ && !seen[$1] {
      seen[$1] = 1
      total += $7 + $10
    }
    END { printf "%.0f", total }'
}

CURRENT_TOTAL="$(get_total_bytes)"

if [ ! -f "${DAY_START_FILE}" ]; then
  echo "${CURRENT_TOTAL}" > "${DAY_START_FILE}"
fi
DAY_START="$(cat "${DAY_START_FILE}")"

TODAY_BYTES=$((CURRENT_TOTAL - DAY_START))
# Reboots reset netstat counters → today_bytes goes negative → reset start.
if [ "${TODAY_BYTES}" -lt 0 ]; then
  echo "${CURRENT_TOTAL}" > "${DAY_START_FILE}"
  TODAY_BYTES=0
fi

TODAY_GB="$(awk -v b="${TODAY_BYTES}" 'BEGIN { printf "%.2f", b/1073741824 }')"
THRESHOLD_BYTES=$((THRESHOLD_GB * 1073741824))

# Snapshot per-process cumulative bytes (since each process started). We
# diff this against the previous snapshot to attribute today's bytes by
# process. Note nettop only sees CURRENTLY-RUNNING processes — short-lived
# processes that exit between samples won't be attributed.
SNAPSHOT_NEW="$(mktemp -t nethog-snap)"
nettop -P -L 1 -J bytes_in,bytes_out -t external 2>/dev/null \
  | awk -F',' '$1 != "" && $1 != "time" { print $1","(($2+0)+($3+0)) }' \
  > "${SNAPSHOT_NEW}"

SNAPSHOT_PREV="${STATE_DIR}/proc.snapshot"
DAILY_PROC_TOTALS="${STATE_DIR}/${TODAY}.proc.csv"
touch "${DAILY_PROC_TOTALS}"

# Compute per-process delta vs. previous snapshot, accumulate into today's totals.
# Process-name keys include PID suffix (e.g. "Chrome.123") so a restart shows
# as a new key — its full bytes-since-restart are then captured next round.
if [ -s "${SNAPSHOT_PREV}" ]; then
  awk -F',' '
    NR==FNR { prev[$1] = $2 + 0; next }
    {
      cur = $2 + 0
      delta = cur - (prev[$1] + 0)
      # If the process name reappeared with a *lower* count, it restarted —
      # treat this round as fresh (count "cur" as the delta).
      if (!($1 in prev) || delta < 0) delta = cur
      if (delta > 0) print $1","delta
    }
  ' "${SNAPSHOT_PREV}" "${SNAPSHOT_NEW}" > "${STATE_DIR}/proc.delta"

  # Merge into today's per-process tally.
  awk -F',' '
    NR==FNR { totals[$1] += $2 + 0; next }
    { totals[$1] += $2 + 0 }
    END {
      for (k in totals) print k","totals[k]
    }
  ' "${DAILY_PROC_TOTALS}" "${STATE_DIR}/proc.delta" > "${DAILY_PROC_TOTALS}.new"
  mv "${DAILY_PROC_TOTALS}.new" "${DAILY_PROC_TOTALS}"
fi
mv "${SNAPSHOT_NEW}" "${SNAPSHOT_PREV}"

# Sum per-process attribution for today — the "honest" number, since
# this only counts user-process socket traffic (no LAN broadcasts, no
# kernel-mode traffic, no between-sample bursts).
PROC_TOTAL_BYTES="$(awk -F',' '{ sum += $2 } END { printf "%.0f", sum+0 }' "${DAILY_PROC_TOTALS}" 2>/dev/null)"
PROC_TOTAL_BYTES="${PROC_TOTAL_BYTES:-0}"
PROC_TOTAL_GB="$(awk -v b="${PROC_TOTAL_BYTES}" 'BEGIN { printf "%.2f", b/1073741824 }')"
GAP_BYTES=$((TODAY_BYTES - PROC_TOTAL_BYTES))
[ "${GAP_BYTES}" -lt 0 ] && GAP_BYTES=0
GAP_GB="$(awk -v b="${GAP_BYTES}" 'BEGIN { printf "%.2f", b/1073741824 }')"

# Render today's top processes (ranked by accumulated bytes today).
TOP_TODAY="$(sort -t',' -k2 -nr "${DAILY_PROC_TOTALS}" 2>/dev/null \
  | head -10 \
  | awk -F',' '{
      gb = $2/1073741824
      mb = $2/1048576
      kb = $2/1024
      if (gb >= 1) printf "  - %s — %.2f GB\n", $1, gb
      else if (mb >= 1) printf "  - %s — %.1f MB\n", $1, mb
      else if (kb >= 1) printf "  - %s — %.1f KB\n", $1, kb
      else printf "  - %s — %d bytes\n", $1, $2
    }')"

# Build a daily-history table from the start-of-day state files. Each
# YYYY-MM-DD.start holds the cumulative WAN byte count at midnight; the
# delta between adjacent days is that day's total. Today's row uses the
# current snapshot instead of "next day's start" since the day isn't done.
HISTORY="$(
  ls "${STATE_DIR}"/*.start 2>/dev/null | sort | awk -v current="${CURRENT_TOTAL}" -v today="${TODAY}" '
    {
      file = $0
      n = split(file, parts, "/"); base = parts[n]
      sub(/\.start$/, "", base)
      cmd = "cat \"" file "\""
      cmd | getline val
      close(cmd)
      dates[++i] = base
      vals[base] = val
    }
    END {
      for (j = 1; j <= i; j++) {
        d = dates[j]
        if (j < i) {
          next_d = dates[j+1]
          delta = vals[next_d] - vals[d]
        } else {
          delta = current - vals[d]
        }
        if (delta < 0) delta = 0
        gb = delta / 1073741824
        is_today = (d == today) ? " (in progress)" : ""
        printf "| %s | %.2f GB%s |\n", d, gb, is_today
      }
    }
  ' | tail -14
)"

# Write summary — staged via /tmp because macOS TCC's `com.apple.provenance`
# xattr blocks bash `>` redirect from overwriting files on /Volumes when the
# script is spawned by launchd. cp works because it goes through different
# syscall paths.
STAGING="$(mktemp -t nethog)"
{
  echo "# Bandwidth — ${HOSTNAME_SHORT}"
  echo
  echo "_Last snapshot: $(date '+%Y-%m-%d %H:%M:%S %Z')_"
  echo
  if [ "${TODAY_BYTES}" -gt "${THRESHOLD_BYTES}" ]; then
    echo "## ⚠️  Today: ${TODAY_GB} GB en1 wifi total — OVER ${THRESHOLD_GB} GB threshold"
  else
    echo "## Today: ${TODAY_GB} GB en1 wifi total / ${THRESHOLD_GB} GB threshold"
  fi
  echo
  echo "- **Process-attributed (user sockets only):** ${PROC_TOTAL_GB} GB"
  echo "- **Unattributed gap:** ${GAP_GB} GB (LAN broadcasts, kernel traffic, between-sample bursts)"
  echo "- **Note:** \`netstat -ibn\` counts ALL bytes through en1 — including LAN traffic, mDNS/Bonjour"
  echo "  broadcasts, AirPlay discovery. Only the per-process number reflects user-app activity."
  echo "  For true WAN measurement, check the Cox gateway at http://10.0.0.1 or the Cox app."
  echo
  echo "## Top processes today (accumulated since 00:00)"
  if [ -n "${TOP_TODAY}" ]; then
    echo "${TOP_TODAY}"
  else
    echo "  (no traffic attributed yet — first run of the day)"
  fi
  echo
  echo "## Daily history (last 14 days)"
  echo
  echo "| Date | WAN total |"
  echo "|------|-----------|"
  if [ -n "${HISTORY}" ]; then
    echo "${HISTORY}"
  else
    echo "| _(no history yet — comes online tomorrow)_ | |"
  fi
  echo
  echo "---"
  echo
  echo "## Notes"
  echo "- \"en1 wifi total\" is bytes through the wifi interface — **includes LAN, not just WAN**."
  echo "- Process-attributed number is honest WAN-ish (user sockets only), but undercounts"
  echo "  kernel daemons and bursts that fall between hourly samples."
  echo "- Truth lives between the two numbers. For exact WAN, the Cox gateway's own counters"
  echo "  (10.0.0.1 admin UI or Cox Panoramic Wifi app) are authoritative."
  echo "- A single 4K movie streamed via Jellyfin can be 20–50 GB. HD ~4–8 GB."
  echo "- Chrome Remote Desktop ~0.2–2 GB/hour depending on screen activity."
} > "${STAGING}"
cp "${STAGING}" "${SUMMARY_FILE}"
rm -f "${STAGING}"

# Fire notification once per day on threshold crossing.
if [ "${TODAY_BYTES}" -gt "${THRESHOLD_BYTES}" ] && [ ! -f "${NOTIFY_MARKER}" ]; then
  TOP_NAME="$(echo "${TOP_TODAY}" | head -1 | sed 's/^[[:space:]]*-[[:space:]]*//; s/ —.*//')"
  TITLE="Bandwidth: ${TODAY_GB} GB used today"
  MSG="Threshold ${THRESHOLD_GB} GB exceeded. Top: ${TOP_NAME:-(unknown)}. See ${SUMMARY_FILE/$HOME/~}"
  /usr/bin/osascript -e "display notification \"${MSG}\" with title \"${TITLE}\" sound name \"Submarine\""
  touch "${NOTIFY_MARKER}"
fi

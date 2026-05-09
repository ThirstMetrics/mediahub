#!/usr/bin/env bash
# nethog-trace.sh — pinpoint where "phantom" bandwidth is going.
#
# Snapshots BOTH netstat-ibn (interface bytes) AND nettop (per-process
# cumulative bytes) at start and end of a window, then diffs.
#
# If interface_delta ≈ sum(nettop_deltas), nettop sees everything;
#   the gap in nethog's daily total comes from hourly sampling missing
#   short-lived processes between samples.
# If interface_delta >> sum(nettop_deltas), nettop is blind to whatever
#   is moving the bytes (LAN broadcast amplification, kernel-mode
#   traffic, system services that bypass user sockets).
#
# Usage: nethog-trace.sh [seconds]   (default 120)

set -u
DURATION="${1:-120}"

get_total_bytes() {
  netstat -ibn | awk '
    /^en[0-9]+/ && !seen[$1] {
      seen[$1] = 1
      total += $7 + $10
    }
    END { printf "%.0f", total }'
}

snapshot_procs() {
  nettop -P -L 1 -J bytes_in,bytes_out -t external 2>/dev/null \
    | awk -F',' '$1 != "" && $1 != "time" && $1 !~ /^[0-9]/ { print $1","(($2+0)+($3+0)) }'
}

SNAP_A="$(mktemp -t nethog-trace-a)"
SNAP_B="$(mktemp -t nethog-trace-b)"

echo "Capturing ${DURATION}s on en0/en1..."
echo "(don't touch anything — let it record idle traffic)"
echo

START_BYTES="$(get_total_bytes)"
snapshot_procs > "${SNAP_A}"

sleep "${DURATION}"

END_BYTES="$(get_total_bytes)"
snapshot_procs > "${SNAP_B}"

INTERFACE_DELTA=$((END_BYTES - START_BYTES))
INTERFACE_MB="$(awk -v b="${INTERFACE_DELTA}" 'BEGIN { printf "%.2f", b/1048576 }')"

# Compute per-process delta. New processes are counted at full bytes
# (probably started during the window and contributed all their bytes).
# Restarted processes (lower count than prev) likewise count at full new bytes.
DELTAS="$(awk -F',' '
  NR==FNR { prev[$1] = $2 + 0; next }
  {
    cur = $2 + 0
    delta = cur - (prev[$1] + 0)
    if (!($1 in prev) || delta < 0) delta = cur
    if (delta > 0) print $1","delta
  }
' "${SNAP_A}" "${SNAP_B}")"

NETTOP_TOTAL_BYTES="$(echo "${DELTAS}" | awk -F',' '{ sum += $2+0 } END { printf "%d", sum+0 }')"
NETTOP_MB="$(awk -v b="${NETTOP_TOTAL_BYTES}" 'BEGIN { printf "%.2f", b/1048576 }')"

GAP=$((INTERFACE_DELTA - NETTOP_TOTAL_BYTES))
[ "${GAP}" -lt 0 ] && GAP=0
GAP_MB="$(awk -v b="${GAP}" 'BEGIN { printf "%.2f", b/1048576 }')"

echo "Interface delta:    ${INTERFACE_MB} MB"
echo "nettop attributed:  ${NETTOP_MB} MB"
echo "Unattributed gap:   ${GAP_MB} MB"
echo

if [ "${INTERFACE_DELTA}" -gt 1024 ]; then
  GAP_PCT="$(awk -v g="${GAP}" -v t="${INTERFACE_DELTA}" 'BEGIN { printf "%.0f", 100*g/t }')"
  echo "→ ${GAP_PCT}% of bytes through en0 are not attributed to any user process."
  if [ "${GAP_PCT}" -gt 50 ]; then
    echo "  Below-socket traffic dominates. Likely culprits: mDNS/Bonjour, ARP,"
    echo "  AirPlay/AirDrop discovery, gateway management. Next: pktap capture."
  elif [ "${GAP_PCT}" -gt 20 ]; then
    echo "  Mixed: some user-process activity + some kernel/broadcast."
  else
    echo "  Mostly user processes — nethog hourly sampling just misses bursts."
  fi
else
  echo "→ Network was very idle during this window (<1 KB total). Try again with"
  echo "  longer duration or while normal activity is happening."
fi

echo
echo "=== Top processes during this window ==="
echo "${DELTAS}" \
  | sort -t',' -k2 -nr \
  | head -15 \
  | awk -F',' '{
      kb = $2/1024
      mb = $2/1048576
      if (mb >= 1) printf "%10.2f MB  %s\n", mb, $1
      else if (kb >= 1) printf "%10.2f KB  %s\n", kb, $1
      else printf "%10d B   %s\n", $2, $1
    }'

rm -f "${SNAP_A}" "${SNAP_B}"

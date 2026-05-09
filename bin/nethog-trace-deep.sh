#!/usr/bin/env bash
# nethog-trace-deep.sh — packet-level bandwidth attribution.
#
# Captures actual packets on en0 for N seconds and categorizes by destination:
#   - Broadcast/multicast (mDNS, AirPlay discovery, ARP, etc.)
#   - LAN (192.168.x, 10.x, 172.16-31.x)
#   - WAN (everything else)
# Then breaks WAN down by destination IP and reverse-DNS for top talkers.
#
# Usage: sudo nethog-trace-deep.sh [seconds]   (default 60)
# Must run with sudo — packet capture needs root.

set -u
DURATION="${1:-60}"

if [ "$(id -u)" -ne 0 ]; then
  echo "This needs sudo for packet capture."
  echo "Re-run: sudo $0 ${DURATION}"
  exit 1
fi

PCAP="$(mktemp -t nethog-deep).pcap"

# Auto-detect the active interface (the one carrying the default route).
# Mac mini's en0 is Ethernet (unused), en1 is wifi — must use the right one.
IFACE="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')"
IFACE="${IFACE:-en0}"

echo "Capturing ${DURATION}s on ${IFACE}..."
echo "(walk away — record genuine idle traffic)"
echo

# -G/-W has a known macOS hang. Instead, spawn tcpdump in background
# and SIGINT it after DURATION — this flushes the pcap cleanly.
tcpdump -i "${IFACE}" -nn -q -s 0 -w "${PCAP}" 2>/dev/null &
TCPDUMP_PID=$!
sleep "${DURATION}"
kill -INT "${TCPDUMP_PID}" 2>/dev/null
wait "${TCPDUMP_PID}" 2>/dev/null

echo
echo "Analyzing $(ls -lh "${PCAP}" | awk '{print $5}') of capture..."
echo

# Read pcap back, extract destination IP and packet length, categorize.
tcpdump -nn -tt -r "${PCAP}" 2>/dev/null | \
  awk '
  {
    dst = ""; bytes = 0
    # Find destination: pattern is "src.port > dst.port: ... length N"
    # The destination is field after ">"
    for (i=1; i<=NF; i++) {
      if ($i == ">") {
        dst_full = $(i+1)
        # Strip trailing colon
        sub(/:$/, "", dst_full)
        # Drop the port (last dotted segment)
        n = split(dst_full, parts, ".")
        if (n >= 4) {
          dst = parts[1]"."parts[2]"."parts[3]"."parts[4]
        } else {
          dst = dst_full
        }
        break
      }
    }
    # Find length
    if (match($0, /length [0-9]+/)) {
      len_str = substr($0, RSTART+7)
      bytes = int(len_str)
    }
    if (dst == "" || bytes == 0) next

    # Classify
    if (dst ~ /^192\.168\./ || dst ~ /^10\./ || \
        dst ~ /^172\.(1[6-9]|2[0-9]|3[01])\./ || \
        dst ~ /^169\.254\./) {
      lan_total += bytes
      lan_dst[dst] += bytes
    } else if (dst ~ /^22[4-9]\./ || dst ~ /^23[0-9]\./ || \
               dst == "255.255.255.255" || dst ~ /^ff/) {
      mcast_total += bytes
      mcast_dst[dst] += bytes
    } else {
      wan_total += bytes
      wan_dst[dst] += bytes
    }
    grand_total += bytes
  }
  END {
    printf "=== Bytes by destination class ===\n"
    printf "  WAN (internet):            %12.2f MB\n", wan_total/1048576
    printf "  LAN (192.168.x / 10.x):    %12.2f MB\n", lan_total/1048576
    printf "  Multicast/broadcast:       %12.2f MB\n", mcast_total/1048576
    printf "  ─────────────────────────  ────────────\n"
    printf "  Total:                     %12.2f MB\n", grand_total/1048576
    printf "\n=== Top WAN destinations (true internet usage) ===\n"
    for (d in wan_dst) printf "%12.2f KB  %s\n", wan_dst[d]/1024, d | "sort -nr | head -15"
    close("sort -nr | head -15")
    printf "\n=== Top LAN destinations ===\n"
    for (d in lan_dst) printf "%12.2f KB  %s\n", lan_dst[d]/1024, d | "sort -nr | head -10"
    close("sort -nr | head -10")
    printf "\n=== Top multicast destinations ===\n"
    for (d in mcast_dst) printf "%12.2f KB  %s\n", mcast_dst[d]/1024, d | "sort -nr | head -10"
    close("sort -nr | head -10")
  }
  '

# Reverse-DNS the top WAN destinations for human-friendly context.
echo
echo "=== Reverse DNS for top WAN IPs ==="
TOP_WAN="$(tcpdump -nn -tt -r "${PCAP}" 2>/dev/null | \
  awk '
  {
    for (i=1; i<=NF; i++) {
      if ($i == ">") {
        dst_full = $(i+1); sub(/:$/, "", dst_full)
        n = split(dst_full, parts, ".")
        if (n >= 4) dst = parts[1]"."parts[2]"."parts[3]"."parts[4]
        break
      }
    }
    if (match($0, /length [0-9]+/)) bytes = int(substr($0, RSTART+7))
    if (dst != "" && bytes > 0 && \
        !(dst ~ /^192\.168\./) && !(dst ~ /^10\./) && \
        !(dst ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) && \
        !(dst ~ /^169\.254\./) && !(dst ~ /^22[4-9]\./) && \
        !(dst ~ /^23[0-9]\./) && dst != "255.255.255.255") {
      total[dst] += bytes
    }
  }
  END {
    for (d in total) printf "%d %s\n", total[d], d
  }' | sort -nr | head -10 | awk '{ print $2 }')"

for ip in ${TOP_WAN}; do
  hostname="$(dig +short +time=2 +tries=1 -x "${ip}" 2>/dev/null | head -1)"
  printf "  %-18s → %s\n" "${ip}" "${hostname:-(no PTR)}"
done

echo
echo "(pcap left at ${PCAP} for further inspection — \`rm\` it when done)"

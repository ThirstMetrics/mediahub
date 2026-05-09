#!/usr/bin/env bash
# bandwidth-analyze.sh — classify a pcap by destination IP class and identify owners.
# Default input: yesterday's capture file from /Volumes/M4Drive/bandwidth-trace/.
#
# Usage: bandwidth-analyze.sh [/path/to/file.pcap]

set -u
PCAP="${1:-${HOME}/Library/Logs/bandwidth-trace/$(date -v-1d +%Y-%m-%d).pcap}"

if [ ! -s "${PCAP}" ]; then
  echo "    no pcap to analyze (looking for ${PCAP})"
  exit 0
fi

SIZE="$(ls -lh "${PCAP}" | awk '{print $5}')"
echo "    analyzing ${SIZE} from ${PCAP}"

# Read pcap and classify by destination IP and known-owner ranges.
tcpdump -nn -tt -r "${PCAP}" 2>/dev/null | \
awk '
function get_len(line,    m, p) {
  if (match(line, /length [0-9]+/)) return int(substr(line, RSTART+7))
  # tcpdump -q TCP format: ".. tcp 1234"
  if (match(line, / tcp [0-9]+/)) { return int(substr(line, RSTART+5)) }
  if (match(line, / udp [0-9]+/)) { return int(substr(line, RSTART+5)) }
  return 0
}
function classify(ip,    cls) {
  if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[01])\./ || ip ~ /^169\.254\./ || ip ~ /^fe80:/) return "LAN"
  if (ip ~ /^22[4-9]\./ || ip ~ /^23[0-9]\./ || ip == "255.255.255.255" || ip ~ /^ff0[12]:/) return "Multicast"
  if (ip ~ /^17\./) return "Apple"
  if (ip ~ /^2620:149/ || ip ~ /^2403:300/) return "Apple"
  if (ip ~ /^2607:6bc0/) return "Anthropic"
  if (ip ~ /^140\.82\.|^192\.30\.|^185\.199\./ || ip ~ /^2606:50c0/) return "GitHub"
  if (ip ~ /^13\.|^52\.|^54\.|^3\.|^18\./ || ip ~ /^2600:1f/) return "AWS"
  if (ip ~ /^104\.16\.|^104\.17\.|^172\.6[4-7]\.|^162\.159\.|^104\.18\./ || ip ~ /^2606:4700/) return "Cloudflare"
  if (ip ~ /^34\.|^35\.|^104\.196\.|^104\.197\.|^104\.198\.|^104\.199\.|^104\.154\.|^104\.155\./ || ip ~ /^2607:f8b0/) return "Google"
  if (ip ~ /^99\.84\.|^54\.230\.|^13\.224\./ || ip ~ /^2600:9000/) return "AWS-CloudFront"
  if (ip ~ /^20\.|^40\.|^52\.96\.|^13\.107\./ || ip ~ /^2603:1/) return "Microsoft"
  if (ip ~ /^68\.105\.|^70\.169\.|^98\.188\./) return "Cox-ISP"
  return "Other-WAN"
}
{
  dst = ""
  for (i=1; i<=NF; i++) {
    if ($i == ">") {
      df = $(i+1); sub(/:$/, "", df)
      n = split(df, p, ".")
      if (n >= 4) dst = p[1]"."p[2]"."p[3]"."p[4]
      else dst = df  # IPv6
      break
    }
  }
  if (dst == "") next
  bytes = get_len($0)
  if (bytes == 0) next

  cls = classify(dst)
  cls_total[cls] += bytes
  if (cls == "Other-WAN" || cls == "Apple" || cls == "Anthropic") {
    dst_total[cls"|"dst] += bytes
  }
  grand += bytes
}
END {
  printf "\n=== Bytes by destination class ===\n"
  # Sort classes by bytes desc
  n = 0
  for (c in cls_total) { keys[++n] = c }
  for (i=1; i<=n; i++) for (j=i+1; j<=n; j++) {
    if (cls_total[keys[i]] < cls_total[keys[j]]) { t=keys[i]; keys[i]=keys[j]; keys[j]=t }
  }
  for (i=1; i<=n; i++) {
    c = keys[i]
    pct = (grand > 0) ? 100 * cls_total[c] / grand : 0
    printf "  %-18s %10.2f MB  (%5.1f%%)\n", c, cls_total[c]/1048576, pct
  }
  printf "  %-18s %10.2f MB\n", "TOTAL", grand/1048576

  printf "\n=== Top destinations within Apple / Anthropic / Other-WAN ===\n"
  m = 0
  for (k in dst_total) { dkeys[++m] = k }
  for (i=1; i<=m; i++) for (j=i+1; j<=m; j++) {
    if (dst_total[dkeys[i]] < dst_total[dkeys[j]]) { t=dkeys[i]; dkeys[i]=dkeys[j]; dkeys[j]=t }
  }
  shown = 0
  for (i=1; i<=m && shown<20; i++) {
    split(dkeys[i], parts, "|")
    printf "  %-12s %10.2f MB  %s\n", parts[1], dst_total[dkeys[i]]/1048576, parts[2]
    shown++
  }
}
'

# Reverse-DNS the top WAN destinations for clearer attribution
echo
echo "=== Reverse DNS for top non-Apple/Anthropic IPs ==="
tcpdump -nn -tt -r "${PCAP}" 2>/dev/null | \
awk '
{
  for (i=1; i<=NF; i++) {
    if ($i == ">") {
      df = $(i+1); sub(/:$/, "", df)
      n = split(df, p, ".")
      if (n >= 4) dst = p[1]"."p[2]"."p[3]"."p[4]
      break
    }
  }
  if (match($0, /length [0-9]+/)) bytes = int(substr($0, RSTART+7))
  else if (match($0, / tcp [0-9]+/)) bytes = int(substr($0, RSTART+5))
  else next
  # Skip LAN/multicast/Apple/Anthropic
  if (dst ~ /^192\.168\./ || dst ~ /^10\./ || dst ~ /^172\.(1[6-9]|2[0-9]|3[01])\./ || \
      dst ~ /^169\.254\./ || dst ~ /^17\./ || dst ~ /^2607:6bc0/ || \
      dst ~ /^22[4-9]\./ || dst ~ /^23[0-9]\./ || dst ~ /^ff0[12]:/) next
  total[dst] += bytes
}
END { for (d in total) printf "%d %s\n", total[d], d }
' | sort -rn | head -10 | while read bytes ip; do
  hostname="$(dig +short +time=2 +tries=1 -x "${ip}" 2>/dev/null | head -1)"
  printf "  %10.2f MB  %-22s → %s\n" "$(awk -v b="${bytes}" 'BEGIN{printf "%.2f",b/1048576}')" "${ip}" "${hostname:-(no PTR)}"
done

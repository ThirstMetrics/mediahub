#!/usr/bin/env bash
# bandwidth-capture.sh — start/stop a long-running header-only tcpdump on en1.
# Outputs to /Volumes/M4Drive/bandwidth-trace/YYYY-MM-DD.pcap so the daily file
# is captured for `back` to analyze the next morning.
#
# Usage:
#   bandwidth-capture.sh start   # begins capture (needs sudo)
#   bandwidth-capture.sh stop    # graceful SIGINT, flushes pcap
#   bandwidth-capture.sh status  # shows whether capture is running

set -u
ACTION="${1:-status}"
TRACE_DIR="${HOME}/Library/Logs/bandwidth-trace"
PID_FILE="${TRACE_DIR}/tcpdump.pid"
mkdir -p "${TRACE_DIR}"

# Auto-detect active wifi interface
IFACE="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')"
IFACE="${IFACE:-en1}"

case "${ACTION}" in
  start)
    if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
      echo "    capture already running (pid $(cat "${PID_FILE}"))"
      exit 0
    fi
    PCAP="${TRACE_DIR}/$(date +%Y-%m-%d).pcap"
    # -s 96 captures only IP/TCP/UDP headers — enough to classify by dst IP and length.
    # nohup + & detaches so tcpdump survives the calling shell.
    sudo -n nohup tcpdump -i "${IFACE}" -nn -s 96 -w "${PCAP}" >/dev/null 2>&1 &
    DUMP_PID=$!
    echo "${DUMP_PID}" > "${PID_FILE}"
    sleep 1
    if kill -0 "${DUMP_PID}" 2>/dev/null; then
      echo "    capture started (pid ${DUMP_PID}, → ${PCAP})"
    else
      echo "    capture failed to start (sudo not cached?)"
      rm -f "${PID_FILE}"
      exit 1
    fi
    ;;
  stop)
    if [ ! -f "${PID_FILE}" ]; then
      echo "    no capture running"
      exit 0
    fi
    PID="$(cat "${PID_FILE}")"
    if kill -0 "${PID}" 2>/dev/null; then
      sudo -n kill -INT "${PID}" 2>/dev/null
      sleep 2
      echo "    capture stopped (pid ${PID})"
    else
      echo "    pid ${PID} not running, cleaning stale pidfile"
    fi
    rm -f "${PID_FILE}"
    ;;
  status)
    if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
      echo "    running (pid $(cat "${PID_FILE}"))"
    else
      echo "    not running"
    fi
    ;;
  *)
    echo "usage: $0 {start|stop|status}" >&2
    exit 2
    ;;
esac

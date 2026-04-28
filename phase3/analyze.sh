#!/usr/bin/env bash
#
# Reads both phase1.pcap and phase2.pcap, runs them through tcpdump -A
# (ASCII mode) and counts how many times each "plaintext marker" string
# appears. Produces a side-by-side comparison report.
#
# Usage: ./phase3/analyze.sh
#   Reads ../captures/phase{1,2}.pcap relative to the script's parent dir.
#   Writes the report to ../captures/phase3-report.txt and prints it to stdout.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPTURES="${ROOT}/captures"
REPORT="${CAPTURES}/phase3-report.txt"

# Strings we expect to see if data is in plaintext on the wire.
MARKERS=(
  'PLAINTEXT_SECRET'
  'SELECT'
  'INSERT'
  'messages'
  'alice'
  'bob'
  'mysql_native_password'
)

DOCKER_IMAGE="nicolaka/netshoot:latest"

count_marker() {
  local pcap=$1 marker=$2 filter=$3
  docker run --rm -v "${CAPTURES}:/captures" "${DOCKER_IMAGE}" \
      tcpdump -r "/captures/$(basename "${pcap}")" -A -nn "${filter}" 2>/dev/null \
    | grep -c -F "${marker}" || true
}

count_packets() {
  local pcap=$1 filter=$2
  docker run --rm -v "${CAPTURES}:/captures" "${DOCKER_IMAGE}" \
      tcpdump -r "/captures/$(basename "${pcap}")" -nn "${filter}" 2>/dev/null \
    | wc -l | tr -d ' '
}

# Filter out loopback (within-container control traffic) so we only count
# packets that actually crossed the docker bridge between containers.
WIRE_FILTER='not src host 127.0.0.1 and not dst host 127.0.0.1'

phase1_pcap="${CAPTURES}/phase1.pcap"
phase2_pcap="${CAPTURES}/phase2.pcap"

if [[ ! -f "${phase1_pcap}" ]]; then
  echo "missing ${phase1_pcap} — run phase1 first" >&2; exit 1
fi
if [[ ! -f "${phase2_pcap}" ]]; then
  echo "missing ${phase2_pcap} — run phase2 first" >&2; exit 1
fi

p1_packets=$(count_packets "${phase1_pcap}" "${WIRE_FILTER}")
p2_packets=$(count_packets "${phase2_pcap}" "${WIRE_FILTER}")

{
  echo "================================================================"
  echo "  Phase 3 — On-the-wire content comparison"
  echo "  (loopback / in-container control traffic excluded)"
  echo "================================================================"
  echo
  printf "%-32s  %-16s  %-16s\n" "wire packets captured"  "phase1 (no Ockam)"  "phase2 (Ockam)"
  printf "%-32s  %-16s  %-16s\n" "---------------------"  "-----------------"  "--------------"
  printf "%-32s  %-16s  %-16s\n" "                     "  "${p1_packets}"     "${p2_packets}"
  echo
  printf "%-32s  %-16s  %-16s\n" "marker (literal substring)"  "found in phase1"  "found in phase2"
  printf "%-32s  %-16s  %-16s\n" "--------------------------"  "---------------"  "---------------"
  for m in "${MARKERS[@]}"; do
    c1=$(count_marker "${phase1_pcap}" "${m}" "${WIRE_FILTER}")
    c2=$(count_marker "${phase2_pcap}" "${m}" "${WIRE_FILTER}")
    printf "%-32s  %-16s  %-16s\n" "${m}" "${c1}" "${c2}"
  done
  echo
  echo "Interpretation:"
  echo "  - Phase 1 should show non-zero counts for SQL keywords and the secret"
  echo "    strings — this proves the wire was unencrypted."
  echo "  - Phase 2 should show ZERO for every marker — this proves the Ockam"
  echo "    secure channel ciphertext does not leak any of those substrings."
  echo
  echo "Sample bytes — phase1 (first INSERT packet, ASCII):"
  echo "----------------------------------------------------------------"
  docker run --rm -v "${CAPTURES}:/captures" "${DOCKER_IMAGE}" \
      tcpdump -r "/captures/phase1.pcap" -A -nn "${WIRE_FILTER}" 2>/dev/null \
    | grep -aF -A 1 "INSERT" | head -2 || true
  echo
  echo "Sample bytes — phase2 (a port-14000 data packet, hex):"
  echo "----------------------------------------------------------------"
  docker run --rm -v "${CAPTURES}:/captures" "${DOCKER_IMAGE}" \
      tcpdump -r "/captures/phase2.pcap" -X -nn "${WIRE_FILTER} and tcp port 14000" 2>/dev/null \
    | sed -n '6,15p' || true
  echo
} | tee "${REPORT}"

#!/usr/bin/env bash
#
# End-to-end verification:
#   1. Build the images we need.
#   2. Phase 1: bring up MySQL, attach a sniffer container to MySQL's net
#      namespace via a standalone `docker run`, then run the python client,
#      stop the sniffer cleanly so its pcap is fully flushed, tear down.
#   3. Phase 2: bring up MySQL + ockam-server + ockam-client, attach a
#      sniffer to ockam-client's net namespace, run the python client
#      through the local Ockam inlet, stop the sniffer, tear down.
#   4. Run the phase3 analyzer to compare the two pcaps and print a verdict.
#
# Why a standalone `docker run` for the sniffer (instead of a compose
# service with `network_mode: service:...`)? On this Docker Desktop build
# we found that tcpdump in a compose-defined sidecar joins the right netns
# but never receives cross-bridge packets, while a standalone container
# launched with `--network container:<name>` works reliably. Same image,
# same caps, same filter — the difference is purely in how docker wires the
# pipeline.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

PHASE1_COMPOSE="compose/phase1.yml"
PHASE2_COMPOSE="compose/phase2.yml"
CAPTURES_DIR="${ROOT}/captures"
SNIFFER_IMAGE="nicolaka/netshoot:latest"

step()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
fail()  { printf '\n\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  for c in phase1-sniffer phase2-sniffer; do
    docker stop "$c" >/dev/null 2>&1 || true
    docker rm   "$c" >/dev/null 2>&1 || true
  done
  docker compose -f "${PHASE1_COMPOSE}" down -v --remove-orphans >/dev/null 2>&1 || true
  docker compose -f "${PHASE2_COMPOSE}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_healthy() {
  local container=$1 timeout=${2:-60}
  for _ in $(seq 1 "${timeout}"); do
    local s
    s=$(docker inspect --format '{{.State.Health.Status}}' "${container}" 2>/dev/null || echo "missing")
    [[ "${s}" == "healthy" ]] && return 0
    sleep 1
  done
  fail "${container} not healthy after ${timeout}s"
}

# Wait for a log line to appear in a container's logs.
wait_log() {
  local container=$1 needle=$2 timeout=${3:-60}
  for _ in $(seq 1 "${timeout}"); do
    if docker logs "${container}" 2>&1 | grep -qF "${needle}"; then
      return 0
    fi
    sleep 1
  done
  fail "never saw '${needle}' in ${container} logs"
}

# Start a tcpdump sniffer that joins another container's network namespace.
# Returns once the sniffer container is up and tcpdump has opened its pcap.
start_sniffer() {
  local name=$1 target_container=$2 pcap_relative=$3
  rm -f "${CAPTURES_DIR}/${pcap_relative}"
  docker rm -f "${name}" >/dev/null 2>&1 || true

  docker run -d --rm --name "${name}" \
      --network "container:${target_container}" \
      --cap-add NET_ADMIN --cap-add NET_RAW \
      -v "${CAPTURES_DIR}:/captures" \
      "${SNIFFER_IMAGE}" \
      sh -c "tcpdump -i any -nn -s 0 -U -w /captures/${pcap_relative} 'tcp' & \
             trap 'kill -INT %1; wait %1' TERM INT; \
             wait %1" >/dev/null

  for _ in $(seq 1 30); do
    if docker exec "${name}" sh -c 'pgrep -x tcpdump >/dev/null' 2>/dev/null \
       && [[ -f "${CAPTURES_DIR}/${pcap_relative}" \
             && $(stat -f '%z' "${CAPTURES_DIR}/${pcap_relative}" 2>/dev/null \
                  || stat -c '%s' "${CAPTURES_DIR}/${pcap_relative}") -ge 24 ]]; then
      # libpcap on Docker-mediated netns needs several seconds AFTER it
      # opens its capture file before kernel packets actually start
      # reaching it. Empirically 4s is enough on Docker Desktop 29.x.
      sleep 4
      return 0
    fi
    sleep 1
  done
  fail "sniffer ${name} never started capturing"
}

# After the client exits, give tcpdump a moment to drain any pending packets
# from libpcap's per-packet (-U) ring before we send SIGTERM.
drain_then_stop_sniffer() {
  local name=$1
  sleep 2
  docker stop -t 5 "${name}" >/dev/null 2>&1 || true
}


mkdir -p "${CAPTURES_DIR}"
rm -f "${CAPTURES_DIR}"/phase1.pcap "${CAPTURES_DIR}"/phase2.pcap "${CAPTURES_DIR}"/phase3-report.txt

step "0/4  Build images"
docker compose -f "${PHASE1_COMPOSE}" build >/dev/null
docker compose -f "${PHASE2_COMPOSE}" build >/dev/null
info "client + ockam + (cached) mysql ready"

step "1/4  Phase 1 — Python -> MySQL, NO encryption"
docker compose -f "${PHASE1_COMPOSE}" down -v --remove-orphans >/dev/null 2>&1 || true
docker compose -f "${PHASE1_COMPOSE}" up -d mysql >/dev/null
wait_healthy phase1-mysql 60
start_sniffer phase1-sniffer phase1-mysql phase1.pcap
info "mysql healthy, sniffer attached and tcpdump capturing"
docker compose -f "${PHASE1_COMPOSE}" up --no-deps --exit-code-from client client 2>&1 \
  | sed 's/^/    [phase1] /'
drain_then_stop_sniffer phase1-sniffer
docker compose -f "${PHASE1_COMPOSE}" down -v --remove-orphans >/dev/null
sz=$(stat -f '%z' "${CAPTURES_DIR}/phase1.pcap" 2>/dev/null || stat -c '%s' "${CAPTURES_DIR}/phase1.pcap")
info "phase1.pcap size: ${sz} bytes"

step "2/4  Phase 2 — Python -> Ockam inlet -> secure channel -> Ockam outlet -> MySQL"
docker compose -f "${PHASE2_COMPOSE}" down -v --remove-orphans >/dev/null 2>&1 || true
docker compose -f "${PHASE2_COMPOSE}" up -d mysql ockam-server ockam-client >/dev/null
wait_healthy phase2-mysql 60
info "mysql healthy"
wait_log phase2-ockam-client "ready — inlet at" 60
info "ockam-client ready, secure channel established"
start_sniffer phase2-sniffer phase2-ockam-client phase2.pcap
info "sniffer attached to ockam-client and tcpdump capturing"
docker compose -f "${PHASE2_COMPOSE}" up --no-deps --exit-code-from client client 2>&1 \
  | sed 's/^/    [phase2] /'
drain_then_stop_sniffer phase2-sniffer
docker compose -f "${PHASE2_COMPOSE}" down -v --remove-orphans >/dev/null
sz=$(stat -f '%z' "${CAPTURES_DIR}/phase2.pcap" 2>/dev/null || stat -c '%s' "${CAPTURES_DIR}/phase2.pcap")
info "phase2.pcap size: ${sz} bytes"

step "3/4  Phase 3 — Compare on-the-wire content"
"${ROOT}/phase3/analyze.sh"

step "4/4  Verdict"
report="${CAPTURES_DIR}/phase3-report.txt"
phase1_leaks=$(awk '/^PLAINTEXT_SECRET / { print $2 }' "${report}")
phase2_leaks=$(awk '/^PLAINTEXT_SECRET / { print $3 }' "${report}")

if [[ -z "${phase1_leaks}" || -z "${phase2_leaks}" ]]; then
  fail "could not parse report"
fi

trap - EXIT  # success path — leave captures around for the user

if [[ "${phase1_leaks}" -gt 0 && "${phase2_leaks}" -eq 0 ]]; then
  printf '    \033[1;32mPASS\033[0m  phase1 leaked PLAINTEXT_SECRET %d times (as expected without encryption);\n' "${phase1_leaks}"
  printf '          phase2 leaked it 0 times (Ockam secure channel encrypted the traffic).\n'
  printf '\nReport written to %s\n' "${report}"
  exit 0
else
  printf '    \033[1;31mFAIL\033[0m  unexpected: phase1=%s phase2=%s\n' "${phase1_leaks}" "${phase2_leaks}" >&2
  exit 2
fi

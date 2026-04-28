#!/usr/bin/env bash
#
# B5 end-to-end verify: run install.sh inside a fresh container of each
# target Linux distro, then confirm:
#   - install completes without error
#   - ockam binary at /usr/local/bin/ockam works
#   - controller venv installed
#   - admin identifier file written
#   - foreground-mode bring-up: ockam node + controller respond
#   - ockam-srv CLI works
#
# Distros covered (by default loops all three; pass DISTROS=... to limit):
#   ubuntu:22.04
#   rockylinux:9          (CentOS / RHEL family)
#   openeuler/openeuler:22.03
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_DIR="${ROOT}/ockam-server/install"
CONTROLLER_DIR="${ROOT}/ockam-server/controller"

# openEuler is supported but its package mirrors are sometimes blocked by
# corporate / dev-machine HTTP proxies; default to ubuntu + rocky which
# proxies tend to leave alone. Add openEuler explicitly if your environment
# can reach repo.openeuler.org:
#   DISTROS="ubuntu:22.04 rockylinux:9 openeuler/openeuler:22.03" ./verify.sh
DISTROS_DEFAULT="ubuntu:22.04 rockylinux:9"
DISTROS="${DISTROS:-${DISTROS_DEFAULT}}"

step()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
fail()  { printf '\n\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

verify_one() {
  local image="$1"
  local cname="modeb-test-$(echo "${image}" | tr ':/.' '---')"

  step "[$image] cleanup any leftover container"
  docker rm -f "${cname}" >/dev/null 2>&1 || true

  step "[$image] start container with install/ + controller/ mounted"
  docker run -d --name "${cname}" \
    -v "${INSTALL_DIR}:/install:ro" \
    -v "${CONTROLLER_DIR}:/controller:ro" \
    "${image}" sleep 3600 >/dev/null \
    || fail "could not start ${image}"

  step "[$image] copy install dirs into rw location (ro mount workaround)"
  docker exec "${cname}" sh -c '
    set -e
    cp -R /install /opt/install
    cp -R /controller /opt/install/../controller
    chmod -R +x /opt/install/install.sh /opt/install/lib/*.sh /opt/install/bin/* /opt/install/pack-offline.sh 2>/dev/null || true
  ' || fail "copy step failed on ${image}"

  step "[$image] pre-stage ockam binary (skip download — proxy may block downloads.ockam.io)"
  # ghcr image is distroless (no sh); use docker create + docker cp
  GHCR_CID=$(docker create ghcr.io/build-trust/ockam:latest)
  docker cp "${GHCR_CID}:/ockam" /tmp/ockam-bin
  docker rm "${GHCR_CID}" >/dev/null
  docker cp /tmp/ockam-bin "${cname}:/usr/local/bin/ockam"
  docker exec "${cname}" chmod 0755 /usr/local/bin/ockam
  rm -f /tmp/ockam-bin

  step "[$image] run install.sh --no-systemd --no-firewall"
  if ! docker exec "${cname}" bash /opt/install/install.sh --no-systemd --no-firewall \
       2>&1 | sed "s#^#    [${image}] #"; then
    fail "install.sh failed on ${image}"
  fi

  step "[$image] ockam --version"
  docker exec "${cname}" /usr/local/bin/ockam --version | head -1 \
    || fail "ockam binary broken on ${image}"

  step "[$image] check admin identifier file"
  docker exec "${cname}" cat /var/lib/ockam-server/admin/identifier > /tmp/.id-${cname}
  ID=$(tr -d '[:space:]' < /tmp/.id-${cname})
  rm -f /tmp/.id-${cname}
  [[ "${ID}" =~ ^I[a-f0-9]{8,} ]] || fail "[${image}] admin identifier malformed: ${ID}"
  echo "    [${image}] admin id: ${ID}"

  step "[$image] start ockam node + controller in foreground (no systemd)"
  docker exec -d "${cname}" sh -c '
    runuser -u ockam -- env OCKAM_HOME=/var/lib/ockam-server \
      /usr/local/bin/ockam node create provider \
      --tcp-listener-address 0.0.0.0:14000 --foreground \
      > /var/log/ockam/node.log 2>&1 &
    sleep 4
    runuser -u ockam -- env OCKAM_HOME=/var/lib/ockam-server \
      OCKAM_CONTROLLER_STATE=/var/lib/ockam-controller/state.yaml \
      OCKAM_CONTROLLER_TRUST_ALL=1 \
      /opt/venv/bin/python -m ockam_controller --bind 127.0.0.1:8080 \
      > /var/log/ockam/controller.log 2>&1 &
  '

  step "[$image] wait for /healthz on 127.0.0.1:8080"
  ok=0
  for _ in $(seq 1 30); do
    if docker exec "${cname}" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
      ok=1; break
    fi
    sleep 1
  done
  if [[ ${ok} -ne 1 ]]; then
    docker exec "${cname}" tail -n 30 /var/log/ockam/controller.log /var/log/ockam/node.log 2>&1 || true
    fail "[${image}] controller never came up"
  fi
  HZ=$(docker exec "${cname}" curl -fsS http://127.0.0.1:8080/healthz)
  echo "    [${image}] /healthz: ${HZ}"
  [[ "${HZ}" == *'"status":"ok"'* ]] || fail "[${image}] /healthz not ok"

  step "[$image] verify port 14000 listening"
  if docker exec "${cname}" sh -c 'cat /proc/net/tcp 2>/dev/null | awk "/:36B0 /"' | grep -q '36B0'; then
    echo "    [${image}] /proc/net/tcp shows :36B0 (=14000)"
  else
    fail "[${image}] port 14000 not in /proc/net/tcp"
  fi

  step "[$image] ockam-srv status"
  # Use awk instead of `head -N` so the upstream pipe doesn't get SIGPIPE'd
  # (which would trip pipefail and kill the whole verify script).
  docker exec "${cname}" /usr/local/bin/ockam-srv status 2>&1 \
    | awk 'NR<=10' \
    | sed "s#^#    [${image}] #"

  step "[$image] cleanup"
  docker rm -f "${cname}" >/dev/null
  echo "    [${image}] OK"
}

for d in ${DISTROS}; do
  verify_one "${d}"
done

printf '\n\033[1;32mPASS\033[0m  install.sh works on: %s\n' "${DISTROS}"

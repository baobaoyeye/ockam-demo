#!/usr/bin/env bash
#
# B2 end-to-end verify for the Mode A docker image.
#
# Builds the image, brings up an ockam-server container, then from the
# OUTSIDE (a separate container with only the ockam binary) opens a real
# Ockam tunnel and exercises the controller HTTP API through it.
#
# Hard checks:
#   - container becomes 'healthy'
#   - external port scan shows ONLY 14000/tcp open
#   - the bootstrap admin identifier file exists and is readable
#   - through-tunnel GET /healthz, GET /info return well-formed JSON
#   - through-tunnel POST /outlets creates a real outlet (state=ready)
#   - direct controller access from inside container confirms the outlet
#     actually appeared on the live ockam node
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

IMAGE="ockam-demo-server:latest"
SERVER_NAME="ockctl-srv"
CLIENT_NAME="ockctl-cli"
PORT=14000
WORK="$(mktemp -d -t ockctl-modeA.XXXXXX)"
ADMIN_VOLUME="${WORK}/admin-vault"
mkdir -p "${ADMIN_VOLUME}"

step()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
fail()  { printf '\n\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
cleanup() {
  docker rm -f "${SERVER_NAME}" "${CLIENT_NAME}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

assert_eq() {
  local actual=$1 expected=$2 msg=$3
  if [[ "${actual}" != "${expected}" ]]; then
    fail "${msg}: expected '${expected}', got '${actual}'"
  fi
}

# ------------------------------------------------------------------ T1 build
step "T1: docker build ockam-demo-server image"
docker build -f "${ROOT}/ockam-server/docker/Dockerfile" \
             -t "${IMAGE}" \
             "${ROOT}/ockam-server" >/dev/null

# --------------------------------------------------------------- T2 admin id
step "T2: generate admin identity (ockam identity create) for the test"
docker run --rm -v "${ADMIN_VOLUME}:/var/lib/ockam-server" \
  -e OCKAM_HOME=/var/lib/ockam-server \
  --entrypoint sh "${IMAGE}" -c \
  'ockam identity create admin >/dev/null && \
   ockam identity show --output json | jq -r .identifier' \
  > "${WORK}/admin-id"
ADMIN_ID=$(cat "${WORK}/admin-id" | tr -d '[:space:]')
[[ "${ADMIN_ID}" =~ ^I[a-f0-9]{8,} ]] || fail "admin identifier looks malformed: ${ADMIN_ID}"
echo "    admin id: ${ADMIN_ID}"

# ----------------------------------------------------------- T3 server start
step "T3: start ockam-server container with ADMIN_IDENTIFIERS baked in"
docker rm -f "${SERVER_NAME}" >/dev/null 2>&1 || true
docker run -d --name "${SERVER_NAME}" \
  -p "${PORT}:${PORT}" \
  -e ADMIN_IDENTIFIERS="${ADMIN_ID}" \
  "${IMAGE}" >/dev/null

# ---------------------------------------------------------- T4 wait healthy
step "T4: wait for healthcheck → healthy"
# healthcheck has start-period=20s + interval=10s, so first real probe ~30s in
for _ in $(seq 1 90); do
  s=$(docker inspect --format '{{.State.Health.Status}}' "${SERVER_NAME}" 2>/dev/null || echo missing)
  [[ "${s}" == "healthy" ]] && break
  sleep 1
done
if [[ "${s}" != "healthy" ]]; then
  echo "--- container logs ---"
  docker logs "${SERVER_NAME}" 2>&1 | tail -40
  echo "--- inside-container probe ---"
  docker exec "${SERVER_NAME}" curl -fsS http://127.0.0.1:8080/healthz 2>&1 || true
  fail "container never reached healthy: ${s}"
fi
echo "    container is healthy"

# ------------------------------------------------------- T5 single port only
step "T5: only 14000/tcp exposed externally"
docker port "${SERVER_NAME}" | tee "${WORK}/ports"
# docker port lists IPv4 and IPv6 mappings on separate lines, so dedupe by container port
UNIQUE_CPORTS=$(awk '{print $1}' "${WORK}/ports" | sort -u | wc -l | tr -d ' ')
assert_eq "${UNIQUE_CPORTS}" "1" "expected exactly 1 unique container port, got ${UNIQUE_CPORTS}"
grep -q "^14000/tcp" "${WORK}/ports" || fail "14000/tcp not in port list"

# ------------------------------------------------------- T6 admin file in vol
step "T6: bootstrap admin identifier file exists in container"
IDENT_IN=$(docker exec "${SERVER_NAME}" cat /var/lib/ockam-server/admin/identifier)
[[ "${IDENT_IN}" =~ ^I[a-f0-9]{8,} ]] || fail "admin identifier file content malformed"
echo "    /var/lib/ockam-server/admin/identifier = ${IDENT_IN}"

# --------------------------------------- T7 controller reachable from inside
step "T7: controller alive on 127.0.0.1:8080 inside container"
HZ=$(docker exec "${SERVER_NAME}" curl -fsS http://127.0.0.1:8080/healthz)
echo "    ${HZ}"
[[ "${HZ}" == *'"status":"ok"'* ]] || fail "controller /healthz not ok"
[[ "${HZ}" == *'"outlets_total":1'* ]] || fail "expected 1 outlet (controller), got ${HZ}"

# ---------------------------------- T8 controller NOT reachable externally
step "T8: 127.0.0.1:8080 NOT reachable from outside the container"
if nc -z -w 2 127.0.0.1 8080 2>/dev/null; then
  fail "8080 is reachable from host — controller is leaking"
fi
echo "    confirmed: external 8080 is closed"

# ----------------------------- T9 open Ockam tunnel from outside, hit ctrl
step "T9: open Ockam tunnel from a separate container, drive controller API"
SERVER_HOST=$(docker inspect "${SERVER_NAME}" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$v.IPAddress}}{{end}}')
docker rm -f "${CLIENT_NAME}" >/dev/null 2>&1 || true
docker run -d --name "${CLIENT_NAME}" \
  --add-host=provider:"${SERVER_HOST}" \
  -v "${ADMIN_VOLUME}:/var/lib/ockam-client" \
  --entrypoint sh "${IMAGE}" -c '
set -eu
export OCKAM_HOME=/var/lib/ockam-client
ockam node create client --tcp-listener-address 127.0.0.1:0 >/dev/null 2>&1 || \
  (ockam node delete client --yes >/dev/null 2>&1; \
   ockam node create client --tcp-listener-address 127.0.0.1:0 >/dev/null 2>&1)
sleep 2
SC=$(ockam secure-channel create --from /node/client \
       --to /dnsaddr/provider/tcp/14000/service/api 2>&1 | tail -1 | tr -d "[:space:]")
echo "[client] SC=$SC"
ockam tcp-inlet create --at client --from 127.0.0.1:18080 \
  --to "${SC}/service/controller" 2>&1 | tail -1
sleep 1
echo "=== HEALTHZ ==="
curl -fsS --max-time 10 http://127.0.0.1:18080/healthz
echo
echo "=== INFO ==="
curl -fsS --max-time 10 http://127.0.0.1:18080/info
echo
echo "=== POST /outlets mysql ==="
curl -fsS --max-time 10 -X POST http://127.0.0.1:18080/outlets \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"mysql\",\"target\":\"10.0.0.5:3306\",\"allow\":[]}"
echo
echo "=== POST /outlets redis ==="
curl -fsS --max-time 10 -X POST http://127.0.0.1:18080/outlets \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"redis\",\"target\":\"10.0.0.5:6379\",\"allow\":[]}"
echo
echo "=== DONE ==="
sleep 3600
' >/dev/null

# Wait for client to reach DONE in its log
for _ in $(seq 1 40); do
  if docker logs "${CLIENT_NAME}" 2>&1 | grep -q "=== DONE ==="; then
    break
  fi
  sleep 1
done
docker logs "${CLIENT_NAME}" 2>&1 | grep -q "=== DONE ===" \
  || { docker logs "${CLIENT_NAME}"; fail "tunnel client did not finish in time"; }

CLIENT_LOG=$(docker logs "${CLIENT_NAME}" 2>&1)
echo "${CLIENT_LOG}" | grep -aE 'HEALTHZ|INFO|POST|status|name|target|state' | head -20

[[ "${CLIENT_LOG}" == *'"status":"ok"'* ]] || fail "tunnel /healthz did not return ok"
[[ "${CLIENT_LOG}" == *'"identifier":"I'* ]] || fail "tunnel /info did not return identifier"
[[ "${CLIENT_LOG}" == *'"name":"mysql"'* ]] || fail "tunnel POST /outlets mysql did not succeed"
[[ "${CLIENT_LOG}" == *'"state":"ready"'* ]] || fail "outlet did not reach ready via tunnel"

# ------------------------------ T10 server side reflects what we just did
step "T10: server side now lists controller + mysql + redis outlets"
LIST=$(docker exec "${SERVER_NAME}" curl -fsS http://127.0.0.1:8080/outlets)
echo "    ${LIST:0:200}..."
for name in controller mysql redis; do
  [[ "${LIST}" == *"\"name\":\"${name}\""* ]] || fail "outlet ${name} missing on server"
done

printf '\n\033[1;32mPASS\033[0m  Mode A docker image passed all 10 tests\n'

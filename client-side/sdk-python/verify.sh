#!/usr/bin/env bash
#
# B3 end-to-end: bring up real ockam-server (Mode A) + mysql + python-app
# that uses the SDK to ensure-outlet, open tunnel, and run real SQL.
#
# Hard checks:
#   - python-app exits 0 (insert + select succeeded through tunnel)
#   - tunnel-network sniffer pcap shows ZERO plaintext SQL/secret markers
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d -t ockctl-sdkpy.XXXXXX)"
COMPOSE="${ROOT}/client-side/sdk-python/compose.yml"
ADMIN_VOLUME="${WORK}/admin-vault"
mkdir -p "${ADMIN_VOLUME}" "${WORK}/captures"

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
cleanup() {
  docker compose -f "${COMPOSE}" down -v --remove-orphans >/dev/null 2>&1 || true
  docker rm -f sdkpy-sniffer >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------- T1 build
step "T1: build base + python images, reuse ockam-demo-server image"
docker build -f "${ROOT}/ockam-server/docker/Dockerfile" -t ockam-demo-server:latest \
             "${ROOT}/ockam-server" >/dev/null

docker build -f "${ROOT}/client-side/images/base.ubuntu.Dockerfile" \
             -t ockam-demo-client-base:latest "${ROOT}/client-side/images" >/dev/null

docker build -f "${ROOT}/client-side/images/python.Dockerfile" \
             --build-arg BASE=ockam-demo-client-base:latest \
             -t ockam-demo-client-python:latest "${ROOT}/client-side" >/dev/null

# -------------------------------------------------------- T2 admin identity
step "T2: pre-generate admin identity in tempvol"
docker run --rm -v "${ADMIN_VOLUME}:/var/lib/ockam-client" \
  -e OCKAM_HOME=/var/lib/ockam-client \
  --entrypoint sh ockam-demo-server:latest -c \
  'ockam identity create admin >/dev/null && \
   ockam identity show --output json | jq -r .identifier' \
  > "${WORK}/admin-id"
ADMIN_ID=$(tr -d '[:space:]' < "${WORK}/admin-id")
[[ "${ADMIN_ID}" =~ ^I[a-f0-9]{8,} ]] || fail "admin identifier malformed: ${ADMIN_ID}"
echo "    admin id: ${ADMIN_ID}"
export ADMIN_ID ADMIN_VOLUME WORK

# ------------------------------------------------------- T3 generate compose
step "T3: render docker-compose.yml"
cat > "${COMPOSE}" <<YAML
name: sdkpy
networks:
  internal:
    driver: bridge
  tunnel:
    driver: bridge
services:
  mysql:
    image: mysql:8.0
    container_name: sdkpy-mysql
    command: ["--default-authentication-plugin=mysql_native_password", "--skip-ssl"]
    environment:
      MYSQL_ROOT_PASSWORD: rootpw
      MYSQL_DATABASE: demo
      MYSQL_USER: demo
      MYSQL_PASSWORD: demopw
    networks: [internal]
    volumes:
      - ${ROOT}/mysql/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-u", "root", "-prootpw"]
      interval: 2s
      timeout: 3s
      retries: 30

  ockam-server:
    image: ockam-demo-server:latest
    container_name: sdkpy-server
    environment:
      ADMIN_IDENTIFIERS: "${ADMIN_ID}"
    networks: [internal, tunnel]
    depends_on:
      mysql:
        condition: service_healthy

  python-app:
    image: ockam-demo-client-python:latest
    container_name: sdkpy-app
    environment:
      OCKAM_SERVER_HOST: ockam-server
      OCKAM_SERVER_PORT: "14000"
      OCKAM_OUTLET: mysql
      OCKAM_UPSTREAM: "mysql:3306"
      OCKAM_HOME: /var/lib/ockam-client
      MYSQL_USER: demo
      MYSQL_PASSWORD: demopw
      MYSQL_DATABASE: demo
    volumes:
      - ${ADMIN_VOLUME}:/var/lib/ockam-client
    networks: [tunnel]
    depends_on:
      - ockam-server
    # Wait for ockam-server's transport listener to be live before starting
    command: ["sh", "-c", "until nc -z ockam-server 14000; do sleep 1; done; sleep 3; python /app/python_mysql.py"]
YAML

# --------------------------------------------------- T4 bring up everything
step "T4: docker compose up server stack"
docker compose -f "${COMPOSE}" up -d mysql ockam-server >/dev/null
for _ in $(seq 1 90); do
  s=$(docker inspect --format '{{.State.Health.Status}}' sdkpy-server 2>/dev/null || echo missing)
  [[ "${s}" == "healthy" ]] && break
  sleep 1
done
[[ "${s}" == "healthy" ]] || { docker logs sdkpy-server | tail -30; fail "ockam-server not healthy: ${s}"; }
echo "    ockam-server is healthy"

# ----------------------------------------------- T5 attach sniffer to ockam
step "T5: attach sniffer to sdkpy-server's net ns (capture eth0 on tunnel)"
docker run -d --rm --name sdkpy-sniffer \
  --network "container:sdkpy-server" \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  -v "${WORK}/captures:/captures" \
  nicolaka/netshoot:latest \
  sh -c "tcpdump -i any -nn -s 0 -U -w /captures/sdkpy.pcap 'tcp port 14000' & \
         trap 'kill -INT %1; wait %1' TERM INT; wait %1" >/dev/null
sleep 4

# ------------------------------------------------------- T6 run python-app
step "T6: run python-app (uses SDK to ensure outlet + tunnel + SQL)"
docker compose -f "${COMPOSE}" up --no-deps --exit-code-from python-app python-app 2>&1 \
  | sed 's/^/    [app] /'
RC=${PIPESTATUS[0]}
[[ ${RC} -eq 0 ]] || fail "python-app exited with ${RC}"

# --------------------------------------------------------- T7 stop sniffer
step "T7: stop sniffer + flush pcap"
sleep 2
docker stop -t 5 sdkpy-sniffer >/dev/null 2>&1 || true
sleep 1
PCAP_BYTES=$(stat -f '%z' "${WORK}/captures/sdkpy.pcap" 2>/dev/null || stat -c '%s' "${WORK}/captures/sdkpy.pcap")
echo "    pcap size: ${PCAP_BYTES} bytes"

# --------------------------------------------------- T8 zero plaintext leak
step "T8: scan pcap for plaintext markers (must all be 0)"
WIRE='not src host 127.0.0.1 and not dst host 127.0.0.1'
LEAKED=0
for marker in PLAINTEXT_SECRET SELECT INSERT messages alice bob mysql_native_password; do
  cnt=$(docker run --rm -v "${WORK}/captures:/captures" nicolaka/netshoot:latest \
        tcpdump -r /captures/sdkpy.pcap -A -nn "${WIRE}" 2>/dev/null \
        | grep -c -F "${marker}" || true)
  printf "    %-25s %s\n" "${marker}" "${cnt}"
  if [[ ${cnt} -gt 0 ]]; then LEAKED=$((LEAKED + cnt)); fi
done
[[ ${LEAKED} -eq 0 ]] || fail "wire leak: ${LEAKED} plaintext marker hits found"

printf '\n\033[1;32mPASS\033[0m  Python SDK end-to-end: SQL ran through Ockam tunnel, wire is encrypted\n'

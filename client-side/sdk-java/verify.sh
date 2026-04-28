#!/usr/bin/env bash
#
# B4 end-to-end: bring up real ockam-server (Mode A) + mysql + java-app
# that uses the SDK to ensure-outlet, open tunnel, and run real JDBC SQL.
#
# Hard checks:
#   - java-app exits 0 (insert + select succeeded through tunnel)
#   - tunnel-network sniffer pcap shows ZERO plaintext SQL/secret markers
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d -t ockctl-sdkjava.XXXXXX)"
COMPOSE="${ROOT}/client-side/sdk-java/compose.yml"
ADMIN_VOLUME="${WORK}/admin-vault"
mkdir -p "${ADMIN_VOLUME}" "${WORK}/captures"

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
cleanup() {
  docker compose -f "${COMPOSE}" down -v --remove-orphans >/dev/null 2>&1 || true
  docker rm -f sdkjava-sniffer >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------- T1 build
step "T1: build artifacts (mvn jar + JdbcDemo.class) and images"
"${ROOT}/client-side/sdk-java/scripts/build-artifacts.sh" >/dev/null

docker build -f "${ROOT}/ockam-server/docker/Dockerfile" \
             -t ockam-demo-server:latest \
             "${ROOT}/ockam-server" >/dev/null

docker build -f "${ROOT}/client-side/images/java.Dockerfile" \
             -t ockam-demo-client-java:latest "${ROOT}/client-side" >/dev/null

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
name: sdkjava
networks:
  internal: { driver: bridge }
  tunnel:   { driver: bridge }
services:
  mysql:
    image: mysql:8.0
    container_name: sdkjava-mysql
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
    container_name: sdkjava-server
    environment:
      ADMIN_IDENTIFIERS: "${ADMIN_ID}"
    networks: [internal, tunnel]
    depends_on:
      mysql:
        condition: service_healthy

  java-app:
    image: ockam-demo-client-java:latest
    container_name: sdkjava-app
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
    command: ["sh", "-c", "until nc -z ockam-server 14000; do sleep 1; done; sleep 3; java -cp /app:/app/ockam-client.jar:/app/mysql-driver.jar JdbcDemo"]
YAML

# --------------------------------------------------- T4 bring up server stack
step "T4: docker compose up server stack"
docker compose -f "${COMPOSE}" up -d mysql ockam-server >/dev/null
for _ in $(seq 1 90); do
  s=$(docker inspect --format '{{.State.Health.Status}}' sdkjava-server 2>/dev/null || echo missing)
  [[ "${s}" == "healthy" ]] && break
  sleep 1
done
[[ "${s}" == "healthy" ]] || { docker logs sdkjava-server | tail -30; fail "ockam-server not healthy: ${s}"; }
echo "    ockam-server is healthy"

# ----------------------------------------------- T5 attach sniffer
step "T5: attach sniffer to sdkjava-server (capture port-14000 only)"
docker run -d --rm --name sdkjava-sniffer \
  --network "container:sdkjava-server" \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  -v "${WORK}/captures:/captures" \
  nicolaka/netshoot:latest \
  sh -c "tcpdump -i any -nn -s 0 -U -w /captures/sdkjava.pcap 'tcp port 14000' & \
         trap 'kill -INT %1; wait %1' TERM INT; wait %1" >/dev/null
sleep 4

# ------------------------------------------------------- T6 run java-app
step "T6: run java-app (uses SDK to ensure outlet + tunnel + JDBC)"
docker compose -f "${COMPOSE}" up --no-deps --exit-code-from java-app java-app 2>&1 \
  | sed 's/^/    [app] /'
RC=${PIPESTATUS[0]}
[[ ${RC} -eq 0 ]] || fail "java-app exited with ${RC}"

# --------------------------------------------------------- T7 stop sniffer
step "T7: stop sniffer + flush pcap"
sleep 2
docker stop -t 5 sdkjava-sniffer >/dev/null 2>&1 || true
sleep 1
PCAP_BYTES=$(stat -f '%z' "${WORK}/captures/sdkjava.pcap" 2>/dev/null || stat -c '%s' "${WORK}/captures/sdkjava.pcap")
echo "    pcap size: ${PCAP_BYTES} bytes"

# --------------------------------------------------- T8 zero plaintext leak
step "T8: scan pcap for plaintext markers (must all be 0)"
WIRE='not src host 127.0.0.1 and not dst host 127.0.0.1'
LEAKED=0
for marker in PLAINTEXT_SECRET SELECT INSERT messages alice bob mysql_native_password; do
  cnt=$(docker run --rm -v "${WORK}/captures:/captures" nicolaka/netshoot:latest \
        tcpdump -r /captures/sdkjava.pcap -A -nn "${WIRE}" 2>/dev/null \
        | grep -c -F "${marker}" || true)
  printf "    %-25s %s\n" "${marker}" "${cnt}"
  if [[ ${cnt} -gt 0 ]]; then LEAKED=$((LEAKED + cnt)); fi
done
[[ ${LEAKED} -eq 0 ]] || fail "wire leak: ${LEAKED} plaintext marker hits found"

printf '\n\033[1;32mPASS\033[0m  Java SDK end-to-end: SQL ran through Ockam tunnel, wire is encrypted\n'

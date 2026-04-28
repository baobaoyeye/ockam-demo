#!/usr/bin/env bash
#
# B1 end-to-end verify: runs ockam-controller in MOCK mode (no real ockam
# binary needed), exercises every HTTP endpoint, then restarts and confirms
# state.yaml persistence.
#
# Exit code 0 + final line "PASS" = green. Otherwise FAIL.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d -t ockctl.XXXXXX)"
STATE="${WORK}/state.yaml"
PORT=18080
PIDFILE="${WORK}/uvicorn.pid"
LOGFILE="${WORK}/uvicorn.log"
BASE="http://127.0.0.1:${PORT}"

step()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
fail()  { printf '\n\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
cleanup() {
  if [[ -f "${PIDFILE}" ]]; then
    kill -TERM "$(cat "${PIDFILE}")" 2>/dev/null || true
  fi
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

assert_eq() {
  local actual=$1 expected=$2 msg=$3
  if [[ "${actual}" != "${expected}" ]]; then
    fail "${msg}: expected '${expected}', got '${actual}'"
  fi
}

start_controller() {
  OCKAM_CONTROLLER_MOCK=1 \
  OCKAM_CONTROLLER_TRUST_ALL=1 \
  OCKAM_CONTROLLER_STATE="${STATE}" \
    python -m ockam_controller --bind "127.0.0.1:${PORT}" --log-level warning \
      > "${LOGFILE}" 2>&1 &
  echo $! > "${PIDFILE}"
  for _ in $(seq 1 30); do
    if curl -fsS "${BASE}/healthz" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  cat "${LOGFILE}" >&2
  fail "controller did not come up on ${BASE}"
}

stop_controller() {
  local pid
  pid=$(cat "${PIDFILE}" 2>/dev/null || true)
  [[ -z "${pid}" ]] && return 0
  kill -TERM "${pid}" 2>/dev/null || true
  # `wait` swallows the "Terminated" message that bash would otherwise print
  wait "${pid}" 2>/dev/null || true
  rm -f "${PIDFILE}"
}

# ---------------------------------------------------------------- preflight
step "preflight: install controller package"
cd "${ROOT}"
pip install -q -e '.[dev]'

step "preflight: pick a free port"
if command -v ss >/dev/null && ss -tln 2>/dev/null | grep -q ":${PORT}\b"; then
  fail "port ${PORT} already in use; pick another"
fi

# ---------------------------------------------------------------- T1 healthz
step "T1: start controller and hit /healthz"
start_controller
HZ=$(curl -fsS "${BASE}/healthz")
echo "    ${HZ}"
[[ "${HZ}" == *'"status":"ok"'* ]] || fail "expected status:ok, got: ${HZ}"
[[ "${HZ}" == *'"outlets_total":0'* ]] || fail "expected outlets_total:0 on fresh state"

# ---------------------------------------------------------------- T2 info
step "T2: GET /info shows mock identifier"
INFO=$(curl -fsS "${BASE}/info")
echo "    ${INFO}"
[[ "${INFO}" == *'"identifier":"Imock'* ]] || fail "expected mock identifier in /info"

# ---------------------------------------------------------------- T3 outlet upsert
step "T3: POST /outlets — create mysql outlet"
RESP=$(curl -fsS -X POST "${BASE}/outlets" \
        -H 'Content-Type: application/json' \
        -d '{"name":"mysql","target":"10.0.0.5:3306","allow":["I7c91d77a98f7c91d77a98f7c91d77a98f7c91d77a98f7c91d77a98f7c91d77a9"]}')
echo "    ${RESP}"
[[ "${RESP}" == *'"name":"mysql"'* ]] || fail "POST /outlets did not return outlet"
[[ "${RESP}" == *'"state":"ready"'* ]] || fail "outlet did not reach ready state"

step "T3b: GET /outlets shows it"
LIST=$(curl -fsS "${BASE}/outlets")
[[ "${LIST}" == *'"name":"mysql"'* ]] || fail "GET /outlets missing mysql"

# ---------------------------------------------------------------- T4 patch
step "T4: PATCH /outlets/mysql — change target + add allowed identifier"
PATCH=$(curl -fsS -X PATCH "${BASE}/outlets/mysql" \
        -H 'Content-Type: application/json' \
        -d '{"target":"10.0.0.6:3306","allow_add":["I8d12e5b6c8d12e5b6c8d12e5b6c8d12e5b6c8d12e5b6c8d12e5b6c8d12e5b6cd"]}')
[[ "${PATCH}" == *'"target":"10.0.0.6:3306"'* ]] || fail "PATCH did not update target"
[[ "${PATCH}" == *'"I8d12e5b6c'* ]] || fail "PATCH did not add identifier"

# ---------------------------------------------------------------- T5 client mgmt
step "T5: POST /clients then DELETE removes from outlet allow"
curl -fsS -X POST "${BASE}/clients" \
     -H 'Content-Type: application/json' \
     -d '{"identifier":"I7c91d77a98f7c91d77a98f7c91d77a98f7c91d77a98f7c91d77a98f7c91d77a9","label":"app-prod-1"}' \
     >/dev/null
curl -fsS -X DELETE "${BASE}/clients/I7c91d77a98f7c91d77a98f7c91d77a98f7c91d77a98f7c91d77a98f7c91d77a9" \
     -o /dev/null -w '%{http_code}' \
  | grep -q 204 || fail "DELETE /clients did not return 204"
LIST=$(curl -fsS "${BASE}/outlets/mysql")
[[ "${LIST}" == *'"I7c91d77a9'* ]] && fail "deleted identifier still in outlet allow"

# ---------------------------------------------------------------- T6 audit
step "T6: GET /audit shows recent events"
AUDIT=$(curl -fsS "${BASE}/audit")
[[ "${AUDIT}" == *'"event":"outlet_upserted"'* ]] || fail "audit missing outlet_upserted"
[[ "${AUDIT}" == *'"event":"client_revoked"'* ]] || fail "audit missing client_revoked"

# ---------------------------------------------------------------- T7 persistence
step "T7: stop controller, restart, state survives"
stop_controller
[[ -f "${STATE}" ]] || fail "state file disappeared"

start_controller
RESTART=$(curl -fsS "${BASE}/outlets")
[[ "${RESTART}" == *'"name":"mysql"'* ]] || fail "outlet not restored after restart"
[[ "${RESTART}" == *'"target":"10.0.0.6:3306"'* ]] || fail "patched target not restored"

# ---------------------------------------------------------------- T8 delete
step "T8: DELETE /outlets/mysql — outlet gone"
curl -fsS -X DELETE "${BASE}/outlets/mysql" -o /dev/null -w '%{http_code}' \
  | grep -q 204 || fail "DELETE /outlets/mysql did not return 204"
[[ "$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/outlets/mysql")" == "404" ]] \
  || fail "outlet still present after DELETE"

# ---------------------------------------------------------------- T9 auth gate
step "T9: with TRUST_ALL off and no header → 401"
stop_controller
OCKAM_CONTROLLER_MOCK=1 \
OCKAM_CONTROLLER_STATE="${STATE}" \
  python -m ockam_controller --bind "127.0.0.1:${PORT}" --log-level warning \
    > "${LOGFILE}" 2>&1 &
echo $! > "${PIDFILE}"
for _ in $(seq 1 30); do
  if curl -fsS "${BASE}/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
CODE=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/outlets")
assert_eq "${CODE}" "401" "GET /outlets without auth"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/outlets" \
        -H 'X-Ockam-Remote-Identifier: Iclient1')
assert_eq "${CODE}" "200" "GET /outlets with identifier header"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE}/outlets" \
        -H 'X-Ockam-Remote-Identifier: Iclient1' \
        -H 'Content-Type: application/json' \
        -d '{"name":"x","target":"127.0.0.1:1","allow":[]}')
assert_eq "${CODE}" "403" "POST /outlets as non-admin client"

printf '\n\033[1;32mPASS\033[0m  controller passed all 9 tests\n'

#!/usr/bin/env bash
#
# Ockam node entrypoint, switches mode by $ROLE env var.
#
# ROLE=server : runs an Ockam node whose built-in TCP listener listens on
#               $LISTEN_ADDR (default 0.0.0.0:14000). Creates a tcp-outlet
#               that forwards incoming portal traffic to MySQL.
#
# ROLE=client : runs an Ockam node, opens a secure channel to the server's
#               built-in /service/api listener (this is the encrypted leg),
#               then creates a tcp-inlet on $INLET_ADDR that forwards every
#               byte through the secure channel to the server's outlet.
#
# Both nodes use the auto-generated default Identity. Anonymous secure
# channel — no enrollment / authority — because the goal of the demo is to
# show the wire is encrypted, not to demonstrate full mutual auth.
#
set -euo pipefail

log() { echo "[ockam-${ROLE}] $*" >&2; }

wait_for() {
  local host=$1 port=$2 retries=${3:-60}
  log "waiting for ${host}:${port}..."
  for _ in $(seq 1 "${retries}"); do
    if nc -z "${host}" "${port}" 2>/dev/null; then
      log "${host}:${port} is up"
      return 0
    fi
    sleep 1
  done
  log "timeout waiting for ${host}:${port}"
  return 1
}

# Strip ockam's coloured "✔  Created node ..." banner, return only the route.
strip_ansi() { sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'; }

case "${ROLE:-}" in
  server)
    : "${UPSTREAM_HOST:?UPSTREAM_HOST required}"
    : "${UPSTREAM_PORT:?UPSTREAM_PORT required}"
    : "${LISTEN_ADDR:=0.0.0.0:14000}"

    wait_for "${UPSTREAM_HOST}" "${UPSTREAM_PORT}"

    log "creating node 'server' with TCP listener on ${LISTEN_ADDR}"
    # Creates the node and binds its main TCP listener (also hosts /service/api,
    # the secure-channel listener) to the requested address.
    ockam node create server --tcp-listener-address "${LISTEN_ADDR}"
    sleep 2

    log "creating tcp-outlet -> ${UPSTREAM_HOST}:${UPSTREAM_PORT}"
    ockam tcp-outlet create --at server --to "${UPSTREAM_HOST}:${UPSTREAM_PORT}"

    log "ready — outlet at /service/outlet, secure channel listener at /service/api"
    sleep infinity &
    trap 'ockam node delete server --yes >/dev/null 2>&1 || true; kill %1 2>/dev/null || true' TERM INT
    wait %1
    ;;

  client)
    : "${SERVER_HOST:?SERVER_HOST required}"
    : "${SERVER_PORT:?SERVER_PORT required}"
    : "${INLET_ADDR:=0.0.0.0:15432}"

    wait_for "${SERVER_HOST}" "${SERVER_PORT}"

    log "creating node 'client'"
    ockam node create client
    sleep 2

    SERVER_ROUTE="/dnsaddr/${SERVER_HOST}/tcp/${SERVER_PORT}/service/api"
    log "opening secure channel to ${SERVER_ROUTE}"
    SC_ROUTE=$(ockam secure-channel create \
                  --from /node/client \
                  --to "${SERVER_ROUTE}" \
              | strip_ansi | tr -d '[:space:]')
    log "secure channel address: ${SC_ROUTE}"

    if [[ -z "${SC_ROUTE}" ]]; then
      log "failed to create secure channel"; exit 1
    fi

    log "creating tcp-inlet ${INLET_ADDR} -> ${SC_ROUTE}/service/outlet"
    ockam tcp-inlet create --at client \
        --from "${INLET_ADDR}" \
        --to "${SC_ROUTE}/service/outlet"

    log "ready — inlet at ${INLET_ADDR}"
    sleep infinity &
    trap 'ockam node delete client --yes >/dev/null 2>&1 || true; kill %1 2>/dev/null || true' TERM INT
    wait %1
    ;;

  *)
    echo "ROLE must be 'server' or 'client', got '${ROLE:-}'" >&2
    exit 2
    ;;
esac

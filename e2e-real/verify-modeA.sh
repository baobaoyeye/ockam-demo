#!/usr/bin/env bash
#
# e2e-real Mode A verification:
# Brings up the Mode A docker server, runs both Python and Java client apps,
# checks wire is encrypted on the tunnel network.
#
# This is just a thin orchestrator over the per-batch verify.sh scripts —
# B3 and B4 already do the full pipeline, this script just runs them in
# sequence and prints a unified pass/fail.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

results=()

run_one() {
  local name=$1 cmd=$2
  step "${name}"
  if bash -c "${cmd}"; then
    results+=("PASS  ${name}")
  else
    results+=("FAIL  ${name}")
    return 1
  fi
}

run_one "phase4 (existing demo, port 14000)"            "${ROOT}/phase4/verify.sh"
run_one "B1 controller standalone (FastAPI + state.yaml)" "${ROOT}/ockam-server/controller/verify.sh"
run_one "B2 Mode A Docker image (single-port + tunnel)"  "${ROOT}/ockam-server/docker/verify.sh"
run_one "B3 Python SDK end-to-end (pymysql via tunnel)"  "${ROOT}/client-side/sdk-python/verify.sh"
run_one "B4 Java SDK end-to-end (JDBC via tunnel)"       "${ROOT}/client-side/sdk-java/verify.sh"

echo
echo "================================================================"
echo "  Mode A end-to-end results"
echo "================================================================"
for r in "${results[@]}"; do echo "  ${r}"; done
echo

if printf '%s\n' "${results[@]}" | grep -q '^FAIL'; then
  echo "[1;31mOVERALL: FAIL[0m"
  exit 1
fi
printf '\n\033[1;32mPASS\033[0m  Mode A end-to-end (5/5 verifies green)\n'

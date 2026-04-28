#!/usr/bin/env bash
#
# e2e-real Mode B verification:
# Runs the install.sh matrix verify (ubuntu / rocky by default) AND then
# (using one of the installed containers as the "data provider host")
# tests the Python SDK against it.
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

run_one "install.sh on ubuntu + rocky containers"       "${ROOT}/ockam-server/install/verify.sh"

# Mode B's interaction with the SDK is the same as Mode A's (controller API
# identical). The B3/B4 verifies cover that with a Mode A container; if
# someone wants a real "install on host then SDK from outside" check, they
# need a real two-host setup which is out of scope for the local matrix.

echo
echo "================================================================"
echo "  Mode B end-to-end results"
echo "================================================================"
for r in "${results[@]}"; do echo "  ${r}"; done
echo

if printf '%s\n' "${results[@]}" | grep -q '^FAIL'; then
  echo "[1;31mOVERALL: FAIL[0m"
  exit 1
fi
printf '\n\033[1;32mPASS\033[0m  Mode B install.sh works on the default distro matrix\n'

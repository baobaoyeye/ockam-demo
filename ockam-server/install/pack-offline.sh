#!/usr/bin/env bash
#
# pack-offline.sh — on a host that CAN reach the internet, build an
# offline tarball that can be `--offline` installed on an air-gapped host.
#
# Output: ./ockam-server-offline-<version>.tgz containing:
#   ockam-linux-x86_64
#   ockam-linux-aarch64
#   wheels/                 # ockam-controller + python deps
#   manifest.json
#
set -euo pipefail

OCKAM_VERSION="${OCKAM_VERSION:-0.157.0}"
OUT="${OUT:-./ockam-server-offline-${OCKAM_VERSION}.tgz}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t ockoffline.XXXXXX)"
TARDIR="${WORK}/ockam-server-offline-${OCKAM_VERSION}"
mkdir -p "${TARDIR}/wheels"

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
trap 'rm -rf "${WORK}"' EXIT

step "extract ockam binaries from ghcr.io image (both x86_64 and aarch64)"
for arch in x86_64 aarch64; do
  case "${arch}" in
    x86_64)  platform=linux/amd64 ;;
    aarch64) platform=linux/arm64 ;;
  esac
  CID=$(docker create --platform "${platform}" ghcr.io/build-trust/ockam:latest)
  docker cp "${CID}:/ockam" "${TARDIR}/ockam-linux-${arch}"
  docker rm "${CID}" >/dev/null
  chmod +x "${TARDIR}/ockam-linux-${arch}"
done

step "build python wheel for ockam-controller + collect deps"
docker run --rm -v "${ROOT}:/src" -v "${TARDIR}/wheels:/out" python:3.12-slim \
  sh -c '
    pip install --quiet --upgrade pip build &&
    cd /src/controller &&
    python -m build --wheel --outdir /out &&
    pip download --quiet --dest /out fastapi uvicorn pydantic pyyaml filelock httpx
  '

step "write manifest"
cat > "${TARDIR}/manifest.json" <<EOM
{
  "ockam_version": "${OCKAM_VERSION}",
  "controller_version": "0.1.0",
  "built_at": "$(date -u +%FT%TZ)",
  "arches": ["x86_64", "aarch64"],
  "tested_os": ["centos-9", "rocky-9", "ubuntu-22.04", "openeuler-22.03"]
}
EOM

step "tar up"
tar czf "${OUT}" -C "${WORK}" "$(basename "${TARDIR}")"
echo
echo "[pack-offline] ${OUT}  ($(wc -c <"${OUT}") bytes)"
echo "[pack-offline] use:  sudo ./install.sh --offline ${OUT}"

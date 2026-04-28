#!/usr/bin/env bash
# Put the `ockam` binary at /usr/local/bin/ockam.
# Order: --offline tgz > docker pull (extract from ghcr image) > direct download.

OCKAM_VERSION="${OCKAM_VERSION:-0.157.0}"

download_ockam() {
  local offline_pack="$1"
  local dest=/usr/local/bin/ockam

  # Already there
  if [[ -x "${dest}" ]]; then
    echo "[ockam] /usr/local/bin/ockam already present:"
    "${dest}" --version | head -1
    return 0
  fi

  # 1) offline pack
  if [[ -n "${offline_pack}" && -f "${offline_pack}" ]]; then
    echo "[ockam] extracting from offline bundle: ${offline_pack}"
    local tmp; tmp=$(mktemp -d)
    tar xzf "${offline_pack}" -C "${tmp}"
    case "${ARCH}" in
      x86_64|amd64)   src="${tmp}/ockam-linux-x86_64" ;;
      aarch64|arm64)  src="${tmp}/ockam-linux-aarch64" ;;
      *) echo "[ockam] unsupported arch ${ARCH}"; rm -rf "${tmp}"; return 1 ;;
    esac
    [[ -f "${src}" ]] || { echo "[ockam] bundle missing ${src}"; rm -rf "${tmp}"; return 1; }
    install -m 0755 "${src}" "${dest}"
    rm -rf "${tmp}"
    return 0
  fi

  # 2) Try direct download from downloads.ockam.io
  case "${ARCH}" in
    x86_64|amd64)   bin_name="ockam.x86_64-unknown-linux-musl" ;;
    aarch64|arm64)  bin_name="ockam.aarch64-unknown-linux-musl" ;;
    *) echo "[ockam] unsupported arch ${ARCH}"; return 1 ;;
  esac
  local url="https://downloads.ockam.io/command/v${OCKAM_VERSION}/${bin_name}"
  echo "[ockam] downloading ${url}"
  if curl --retry 3 --retry-delay 3 --retry-connrefused -fSL --proto '=https' --tlsv1.2 \
          -o "${dest}.tmp" "${url}"; then
    chmod 0755 "${dest}.tmp" && mv -f "${dest}.tmp" "${dest}"
    "${dest}" --version | head -1
    return 0
  fi
  rm -f "${dest}.tmp"

  # 3) Fallback: extract from ghcr image (requires docker)
  if command -v docker >/dev/null; then
    echo "[ockam] direct download failed, trying docker pull ghcr.io/build-trust/ockam"
    local cid
    cid=$(docker create ghcr.io/build-trust/ockam:latest 2>/dev/null || true)
    if [[ -n "${cid}" ]]; then
      docker cp "${cid}:/ockam" "${dest}.tmp" >/dev/null 2>&1 && {
        chmod 0755 "${dest}.tmp" && mv -f "${dest}.tmp" "${dest}"
      }
      docker rm "${cid}" >/dev/null 2>&1
      [[ -x "${dest}" ]] && { "${dest}" --version | head -1; return 0; }
    fi
  fi

  echo "[ockam] all download methods failed; pass --offline /path/to/bundle.tgz" >&2
  return 1
}

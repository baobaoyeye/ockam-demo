# Mode A — Ockam server container we operate ourselves.
#
# Multi-stage:
#   1) Pull `ockam` binary from the official distroless image.
#   2) Final stage = debian-slim + python3 + supervisord + the controller pkg.
#
# At runtime the container exposes ONLY port 14000 (Ockam transport with
# Noise XX). The controller listens on 127.0.0.1:8080 inside the container
# and is reachable from the outside ONLY through the special `controller`
# tcp-outlet on the same Ockam node.
#
# Persistent state lives in /var/lib/ockam-server (vault + identities) and
# /var/lib/ockam-controller (state.yaml). Mount both as named volumes.

FROM ghcr.io/build-trust/ockam:latest AS ockam-bin

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv \
        supervisor curl jq ca-certificates netcat-openbsd procps \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Ockam binary — distroless image owns it as user 65532; make it world-readable+exec.
COPY --from=ockam-bin /ockam /usr/local/bin/ockam
RUN chmod 0755 /usr/local/bin/ockam \
 && /usr/local/bin/ockam --version

# Controller package
COPY controller/ /opt/controller/
RUN python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --upgrade pip \
 && /opt/venv/bin/pip install /opt/controller \
 && rm -rf /opt/controller
ENV PATH=/opt/venv/bin:$PATH

# Filesystem layout
RUN useradd -r -d /var/lib/ockam-server -s /usr/sbin/nologin ockam \
 && mkdir -p /var/lib/ockam-server /var/lib/ockam-controller /var/log/ockam /etc/ockam \
 && chown -R ockam:ockam /var/lib/ockam-server /var/lib/ockam-controller /var/log/ockam /etc/ockam

# Configuration files
COPY docker/supervisord.conf /etc/supervisor/conf.d/ockam.conf
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Default ockam home so the binary stores vault + identities under our volume.
#
# OCKAM_CONTROLLER_TRUST_ALL=1 — the controller binds to 127.0.0.1:8080 ONLY,
# and the only way to reach it from outside is through the `controller`
# tcp-outlet, which already enforces caller identity via its --allow policy.
# So inside the container, anyone who can talk to the controller has already
# been authenticated by Ockam — no point re-checking. (For finer admin/read
# role separation, the SDK can opt-in to sending X-Ockam-Remote-Identifier
# explicitly; in that case unset this var and use ADMIN_IDENTIFIERS.)
ENV OCKAM_HOME=/var/lib/ockam-server \
    OCKAM_CONTROLLER_STATE=/var/lib/ockam-controller/state.yaml \
    OCKAM_NODE_NAME=provider \
    OCKAM_NODE_TRANSPORT=0.0.0.0:14000 \
    OCKAM_BINARY=/usr/local/bin/ockam \
    OCKAM_CONTROLLER_TRUST_ALL=1

VOLUME ["/var/lib/ockam-server", "/var/lib/ockam-controller", "/var/log/ockam"]

EXPOSE 14000

# Healthcheck talks to the local-only controller via ockam loopback HTTP
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8080/healthz >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]

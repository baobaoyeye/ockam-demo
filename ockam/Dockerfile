# Pulls the prebuilt ockam binary from the official distroless image and
# repackages it on top of debian-slim, so we have a shell + netcat available
# in the entrypoint script. (The official image at ghcr.io/build-trust/ockam
# is distroless: no shell, only the ockam binary.)

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates netcat-openbsd procps less \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/build-trust/ockam:latest /ockam /usr/local/bin/ockam

RUN ockam --version

WORKDIR /workspace
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

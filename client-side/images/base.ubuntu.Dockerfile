# Client-side base image — Ubuntu + ockam binary.
# Add language runtimes (python.Dockerfile / java.Dockerfile) on top.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates netcat-openbsd curl jq \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/build-trust/ockam:latest /ockam /usr/local/bin/ockam
RUN chmod 0755 /usr/local/bin/ockam && /usr/local/bin/ockam --version

ENV OCKAM_HOME=/var/lib/ockam-client
RUN mkdir -p /var/lib/ockam-client && chmod 0700 /var/lib/ockam-client
VOLUME ["/var/lib/ockam-client"]

# Java client image — runtime only.
#
# Note: the SDK jar (`sdk-java/target/ockam-client-0.1.0-shaded.jar`) and the
# JdbcDemo class file (`build/classes/JdbcDemo.class`) and `mysql-driver.jar`
# must be built BEFORE this image — see scripts/build-java-artifacts.sh,
# called automatically by verify.sh. We do this so the docker build does not
# need network access to Maven Central, which is unreliable behind some
# corporate / dev-machine HTTP proxies.

FROM eclipse-temurin:17-jre-jammy

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        netcat-openbsd ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Ockam binary from official distroless
COPY --from=ghcr.io/build-trust/ockam:latest /ockam /usr/local/bin/ockam
RUN chmod 0755 /usr/local/bin/ockam && /usr/local/bin/ockam --version

WORKDIR /app
COPY sdk-java/target/ockam-client-0.1.0-shaded.jar /app/ockam-client.jar
COPY .build/mysql-driver.jar    /app/mysql-driver.jar
COPY .build/JdbcDemo.class      /app/JdbcDemo.class

ENV OCKAM_HOME=/var/lib/ockam-client
RUN mkdir -p /var/lib/ockam-client && chmod 0700 /var/lib/ockam-client
VOLUME /var/lib/ockam-client

CMD ["java", "-cp", "/app:/app/ockam-client.jar:/app/mysql-driver.jar", "JdbcDemo"]

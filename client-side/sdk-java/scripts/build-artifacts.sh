#!/usr/bin/env bash
#
# Build the Java artifacts that the docker image needs:
#   client-side/sdk-java/target/ockam-client-0.1.0-shaded.jar
#   client-side/.build/mysql-driver.jar
#   client-side/.build/JdbcDemo.class
#
# Uses a containerised maven so the host doesn't need mvn/JDK installed.
# Caches ~/.m2 in a docker volume so subsequent runs don't re-fetch deps.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SDK="${ROOT}/client-side/sdk-java"
DEMO="${ROOT}/client-side/examples/java/JdbcDemo.java"
OUT="${ROOT}/client-side/.build"

MYSQL_JDBC_VERSION="${MYSQL_JDBC_VERSION:-8.4.0}"
MAVEN_IMAGE="${MAVEN_IMAGE:-maven:3.9-eclipse-temurin-17}"

mkdir -p "${OUT}"

echo "[build-java] mvn package -DskipTests"
docker run --rm \
  -v "${SDK}:/build" \
  -v ockam-demo-m2:/root/.m2 \
  -w /build \
  "${MAVEN_IMAGE}" mvn -q package -DskipTests

JAR="${SDK}/target/ockam-client-0.1.0-shaded.jar"
[[ -f "${JAR}" ]] || { echo "build failed: ${JAR} missing"; exit 1; }
echo "[build-java] sdk jar:  ${JAR} ($(wc -c <"${JAR}") bytes)"

if [[ ! -f "${OUT}/mysql-driver.jar" ]]; then
  echo "[build-java] downloading mysql-connector-j ${MYSQL_JDBC_VERSION}"
  docker run --rm -v "${OUT}:/out" "${MAVEN_IMAGE}" \
    curl -fsSL -o /out/mysql-driver.jar \
    "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQL_JDBC_VERSION}/mysql-connector-j-${MYSQL_JDBC_VERSION}.jar"
fi

echo "[build-java] javac JdbcDemo.java"
docker run --rm \
  -v "${SDK}:/sdk" -v "${ROOT}/client-side/examples/java:/demo" -v "${OUT}:/out" \
  "${MAVEN_IMAGE}" \
  javac --release 17 \
        -cp "/sdk/target/ockam-client-0.1.0-shaded.jar" \
        -d /out /demo/JdbcDemo.java

echo "[build-java] OK"
ls -la "${OUT}/" "${SDK}/target/ockam-client-0.1.0-shaded.jar"

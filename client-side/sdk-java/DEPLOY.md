# DEPLOY.md — Java SDK 部署

面向运维 / 应用打包者：把 Java SDK 装进你的应用容器或工程。

API 文档见 [SDK.md](SDK.md)。

## 1. 应用进程要能找到

- **JDK 17+** 运行时
- **`ockam` 二进制**（PATH 或 `OCKAM_BINARY=/path/to/ockam`）
- **`ockam-client-<ver>-shaded.jar`** —— 一个 shaded 的 fat-jar，里面打了 Jackson 进去，没有额外 runtime deps

## 2. 构建 jar

不需要主机装 mvn / JDK，用 dockerized maven：

```bash
./scripts/build-artifacts.sh
# 产物：
#   target/ockam-client-0.1.0-shaded.jar   ← 主交付物
#   ../.build/mysql-driver.jar             ← 演示用 JDBC 驱动（可选）
#   ../.build/JdbcDemo.class               ← 演示主类
```

`scripts/build-artifacts.sh` 会复用 `ockam-demo-m2` 这个 docker 命名卷做 Maven 仓库缓存，第二次跑只要几秒。

## 3. 集成到你自己的工程

### 选项 A — 直接放到 lib/

```bash
mkdir -p libs
cp ockam-client-0.1.0-shaded.jar libs/
javac -cp "libs/ockam-client-0.1.0-shaded.jar" YourApp.java
java  -cp ".:libs/ockam-client-0.1.0-shaded.jar:libs/mysql-driver.jar" YourApp
```

### 选项 B — Maven 本地仓库

```bash
mvn install:install-file \
  -Dfile=ockam-client-0.1.0-shaded.jar \
  -DgroupId=com.ockam \
  -DartifactId=ockam-client \
  -Dversion=0.1.0 \
  -Dpackaging=jar
```

然后在 `pom.xml`：

```xml
<dependency>
  <groupId>com.ockam</groupId>
  <artifactId>ockam-client</artifactId>
  <version>0.1.0</version>
</dependency>
```

### 选项 C — 发到内网 Nexus / Artifactory

把 shaded jar 用 `mvn deploy:deploy-file` 推到企业仓库。

## 4. Docker 镜像里集成

参考 [client-side/images/java.Dockerfile](../images/java.Dockerfile)。要点：

- runtime 用 `eclipse-temurin:17-jre-jammy`（4ms 启动 JRE，<200MB）
- ockam 二进制 `COPY --from=ghcr.io/build-trust/ockam:latest /ockam`
- shaded jar + mysql driver + 你的 .class 文件 → `/app/`
- `OCKAM_HOME` 设到挂载卷
- CMD `java -cp /app:/app/ockam-client.jar:/app/mysql-driver.jar YourMain`

```dockerfile
FROM eclipse-temurin:17-jre-jammy
COPY --from=ghcr.io/build-trust/ockam:latest /ockam /usr/local/bin/ockam
RUN chmod +x /usr/local/bin/ockam
WORKDIR /app
COPY ockam-client-0.1.0-shaded.jar /app/ockam-client.jar
COPY my-app.jar                    /app/my-app.jar
ENV OCKAM_HOME=/var/lib/ockam-client
VOLUME /var/lib/ockam-client
CMD ["java", "-jar", "/app/my-app.jar"]
```

## 5. 持久化 OCKAM_HOME

跟 Python SDK 一样，identity / vault 在 `OCKAM_HOME` 下，必须挂卷。

## 6. 运行时 env

| 变量 | 含义 |
|------|------|
| `OCKAM_HOME` | identity / node 状态目录 |
| `OCKAM_BINARY` | ockam CLI 路径覆盖 |

## 7. JDK 版本

- 必须 17+（用了 `java.net.http.HttpClient` 现代 API、`switch` 表达式、`record`）
- 测试通过：Eclipse Temurin 17、21
- 不支持 Java 8 / 11

## 8. 故障排查

| 现象 | 排查方向 |
|------|---------|
| `IdentityException: ockam not found` | 容器里没装 ockam 二进制 |
| `OckamProcessException: secure-channel timed out` | server 14000 不可达 |
| `OckamProcessException: ... not authorized` | 你的 identifier 没在 outlet 的 allow 列表 |
| `OckamControllerException: HTTP 400 Invalid HTTP request received` | Java HttpClient 用了 HTTP/2 但 controller 只支持 1.1 — SDK 已强制 HTTP/1.1，如果还出现请升 SDK 版本 |
| JdbcDemo 跑通但 SQL 卡住 | MySQL JDBC 驱动版本问题，加 `?useSSL=false&allowPublicKeyRetrieval=true` |
| `node delete timed out` | 关 SDK 时 ockam 节点清理慢；SDK 已经把这个吞了，不影响业务 |

## 9. 依赖

| 包 | 用途 |
|----|------|
| Jackson `databind` 2.17 | JSON parsing for controller responses (内置在 shaded jar) |

JDK 自带：`java.net.http.HttpClient`、`ProcessBuilder`。

## 10. 端到端验证

`./verify.sh` 跑完整流程：build artifacts → 起 ockam-server + mysql → 跑 java-app → 抓 14000 wire → 检查无明文。

```
T1: build artifacts (mvn jar + JdbcDemo.class) and images
T2: pre-generate admin identity in tempvol
T3: render docker-compose.yml
T4: docker compose up server stack
T5: attach sniffer to sdkjava-server (capture port-14000 only)
T6: run java-app (uses SDK to ensure outlet + tunnel + JDBC)
T7: stop sniffer + flush pcap
T8: scan pcap for plaintext markers (must all be 0)

PASS  Java SDK end-to-end: SQL ran through Ockam tunnel, wire is encrypted
```

# SDK.md — 端到端集成示例

## TL;DR

服务端无论 Mode A 还是 Mode B，SDK 看到的接口完全一样。下面两段代码都同时适用。

### Python — 90% 场景

```python
from ockam_client import connect
import pymysql

with connect(
    server="provider.example.com:14000",  # Mode A 容器或 Mode B 主机
    target_outlet="mysql",
    target="10.0.0.5:3306",                # 让 SDK 自动 ensure_outlet
    ockam_home="/var/lib/ockam-client",
    admin_identity_name="admin",           # 自动 load_or_create
) as tun:
    conn = pymysql.connect(host=tun.host, port=tun.port,
                           user="app", password="...", database="orders")
    # 你的 SQL 业务代码——0 行改动
```

### Java — 90% 场景

```java
ServerConfig cfg = ServerConfig.parse("provider.example.com:14000");
Identity admin = Identity.loadOrCreate(Path.of("/var/lib/ockam-client"), "admin");

try (Tunnel tun = Tunnel.open(cfg, "mysql", admin)) {
    String url = "jdbc:mysql://" + tun.host() + ":" + tun.port() + "/orders"
               + "?useSSL=false&allowPublicKeyRetrieval=true";
    try (Connection c = DriverManager.getConnection(url, "app", "...")) {
        // ...
    }
}
```

## 场景手册

| 想做什么 | 看哪 |
|---------|------|
| Python 完整 API | [../client-side/sdk-python/SDK.md](../client-side/sdk-python/SDK.md) |
| Java 完整 API | [../client-side/sdk-java/SDK.md](../client-side/sdk-java/SDK.md) |
| 多个 outlet（mysql + redis + kafka） | sdk-python/SDK.md "场景 4" |
| 客户端 identifier 轮换 | sdk-python/SDK.md "场景 5" |
| 长连接 + 连接池 | sdk-java/SDK.md "场景 1" |
| 配置 outlet（admin 视角） | [../ockam-server/controller/SDK.md](../ockam-server/controller/SDK.md) |

## 客户端镜像

仓库提供两个开箱即用的客户端镜像：
- `ockam-demo-client-python:latest` — Ubuntu + Python 3 + SDK + pymysql
- `ockam-demo-client-java:latest`   — Temurin 17 JRE + ockam-client jar + JDBC

构建：

```bash
# Python 镜像
docker build -f client-side/images/base.ubuntu.Dockerfile \
  -t ockam-demo-client-base:latest client-side/images
docker build -f client-side/images/python.Dockerfile \
  -t ockam-demo-client-python:latest client-side

# Java 镜像（先 build 工件，再打镜像）
./client-side/sdk-java/scripts/build-artifacts.sh
docker build -f client-side/images/java.Dockerfile \
  -t ockam-demo-client-java:latest client-side
```

例子代码：
- [../client-side/examples/python_mysql.py](../client-side/examples/python_mysql.py)
- [../client-side/examples/java/JdbcDemo.java](../client-side/examples/java/JdbcDemo.java)

## 验证你的集成

最简单的烟测：让 verify 跑通

```bash
./verify-modeA.sh    # 跑 B3 / B4 等批次 verify，看到 PASS 即说明你的镜像 + SDK 工作
```

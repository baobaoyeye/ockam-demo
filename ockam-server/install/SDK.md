# SDK.md — 如何对接 Mode B 主机安装

面向 SDK / 应用开发者：你的运维已经按 [DEPLOY.md](DEPLOY.md) 把 ockam-server 装到了数据提供方机器，现在你要从你的 Python / Java 应用去访问。

## 与 Mode A 完全一致的 SDK 交互

Mode B 和 Mode A 暴露的对外 API 完全相同：
- 一个对外 TCP 端口（14000，Ockam transport，Noise XX 加密）
- 一个 controller HTTP API（127.0.0.1:8080，仅本机；外部通过 Ockam tunnel 访问）

所以**你的 SDK 代码 0 改动**——只是 `server` 参数指向数据提供方的真实主机/IP 而不是你自己的容器。

## 你需要从运维拿到的东西

```
provider.host       # 数据提供方主机名 / IP
provider.id         # 文本一行 I9c4ff6cd...   ← provider 节点 identifier
admin-identity      # 你的 admin identity（生成方式见下）
```

## Python 示例

```python
from ockam_client import connect, ServerConfig
import pymysql

cfg = ServerConfig(
    host="provider.example.com",
    port=14000,
    expected_identifier="I9c4ff6cd36d9e06af1c8403ba1a5c05194a1d962054ad78a4684af2ec10ede15",
)

with connect(server=cfg, target_outlet="mysql",
             ockam_home="/var/lib/ockam-client") as tun:
    conn = pymysql.connect(host=tun.host, port=tun.port,
                           user="app", password="...", database="orders")
    # ... 业务代码 ...
```

完整 API 文档：[../../client-side/sdk-python/SDK.md](../../client-side/sdk-python/SDK.md)

## Java 示例

```java
ServerConfig cfg = ServerConfig.builder()
    .host("provider.example.com")
    .port(14000)
    .expectedIdentifier("I9c4ff6cd...")
    .build();

Identity admin = Identity.loadOrCreate(Path.of("/var/lib/ockam-client"), "admin");

try (Tunnel tun = Tunnel.open(cfg, "mysql", admin)) {
    String url = "jdbc:mysql://" + tun.host() + ":" + tun.port() + "/orders";
    try (Connection c = DriverManager.getConnection(url, "app", "...")) {
        // ...
    }
}
```

完整 API 文档：[../../client-side/sdk-java/SDK.md](../../client-side/sdk-java/SDK.md)

## 流程：从零拉起一条加密访问

### 第 1 步：你的应用容器里生成 identity（一次）

```bash
# 容器里
mkdir -p /var/lib/ockam-client
ockam identity create app
ID=$(ockam identity show --output json | jq -r .identifier)
echo "$ID"
# I3a6cf971d6659a23d72204a36577cc489286e01426d98bdb6defdd4ce06672d
```

或在 SDK 里：`Identity.loadOrCreate(...)` 自动做。

### 第 2 步：把 identifier 给运维，让它加白名单

```bash
# 运维在数据提供方主机上
sudo ockam-srv add-admin I3a6cf971...
# 或：让它加到具体 outlet（如 mysql）的 allow 列表
```

或：你自己（持有 admin 身份）通过 SDK 远程调：
```python
admin = Identity.load(...)
with ProviderAdmin(server=cfg, identity=admin) as a:
    a.ensure_outlet(name="mysql", target="10.0.0.5:3306",
                    allow=[my_app_identity.identifier])
```

### 第 3 步：你的应用代码就直接访问

参见上面的 Python / Java 示例。

## 直接调 controller HTTP API（高级 / 调试）

走 ockam tunnel 后再 curl，与 Mode A 完全一样的接口：

参见 [../controller/SDK.md](../controller/SDK.md)。

## 故障排查（SDK 视角）

| 现象 | 含义 |
|------|------|
| `secure-channel timed out` | provider 主机不可达 / 防火墙没开 14000 |
| `not authorized` | identifier 没在 outlet allow 列表，找运维 |
| `Connection refused` 在 inlet 端口 | provider 端 outlet 的 target 配错了 / 数据库挂了 |
| 偶发超时 | provider 主机 CPU/网络抖动；SDK `connectTimeout` 调大 |

## Mode A vs Mode B 对照

| | Mode A（你的容器） | Mode B（数据提供方主机） |
|--|---|---|
| 服务端在哪儿 | 你的 Docker 主机 | 数据提供方的 Linux 主机 |
| 部署 | `docker compose up` | `sudo install.sh` |
| 升级 | `docker pull && up -d` | `ockam-srv uninstall && install.sh --ockam-version <new>` |
| SDK 怎么调 | **完全一样** | **完全一样** |
| 你拿到的 endpoint | 你的容器 host:14000 | 数据提供方 host:14000 |

选 Mode A 还是 Mode B 是部署决策；对你的应用代码无影响。

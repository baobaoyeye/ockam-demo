# ockam-demo — 5 分钟上手"加密的数据库访问"

应用代码连数据库，**0 行改动**就让网络上的字节变成密文。原理是 [Ockam](https://www.ockam.io/) 在两端各跑一个小节点，自动协商 Noise XX 安全通道。

```
[ App ]──tcp 127.0.0.1:auto──→ [ ockam ]══Noise XX 加密══→ [ ockam ]──tcp 3306──→ [ MySQL ]
                                                                                    (or Redis,
                                                                                     Kafka,
                                                                                     任何 TCP)
```

## 30 秒看效果

```bash
./phase4/verify.sh
```

会跑两次同样的 SQL：一次走明文、一次走 Ockam 隧道，旁边挂 tcpdump 抓包对比。最后输出：

```
PASS  phase1 leaked PLAINTEXT_SECRET 2 times (as expected without encryption);
      phase2 leaked it 0 times (Ockam secure channel encrypted the traffic).
```

抓包对比报告：[REPORT.md](REPORT.md)

## 5 分钟上手生产形态

服务端有两种部署形态，**SDK 接口完全一样**——按你的实际情况选：

### 路线 A：你自己运行加密代理容器
> 数据提供方主机你拿不到，但你有一台机器能 routable 到他们的 TCP 服务

```bash
cd ockam-server/docker
docker compose -f docker-compose.example.yml up -d
docker cp ockam-server:/var/lib/ockam-server/admin/identifier provider.id
```

完整指南：[ockam-server/docker/DEPLOY.md](ockam-server/docker/DEPLOY.md)

### 路线 B：装到数据提供方机器
> 你能登上数据提供方的 Linux 主机（CentOS / Rocky / Ubuntu / Debian / openEuler）

```bash
cd ockam-server/install
sudo ./install.sh --admin-identifier "I_your_admin_xxx"
sudo ockam-srv show-admin   # 拿到 provider identifier
```

完整指南：[ockam-server/install/DEPLOY.md](ockam-server/install/DEPLOY.md)
离线包：[ockam-server/install/DEPLOY.md#3-离线安装隔离网环境](ockam-server/install/DEPLOY.md)

## 5 分钟集成到应用代码

### Python

```python
from ockam_client import connect
import pymysql

with connect(server="provider.example.com:14000",
             target_outlet="mysql",
             ockam_home="/var/lib/ockam-client") as tun:
    conn = pymysql.connect(host=tun.host, port=tun.port,
                           user="app", password="...", database="orders")
    # 你的 SQL 业务代码——0 行改动
```

完整 API：[client-side/sdk-python/SDK.md](client-side/sdk-python/SDK.md)
镜像与部署：[client-side/sdk-python/DEPLOY.md](client-side/sdk-python/DEPLOY.md)

### Java

```java
ServerConfig cfg = ServerConfig.parse("provider.example.com:14000");
Identity admin = Identity.loadOrCreate(Path.of("/var/lib/ockam-client"), "admin");

try (Tunnel tun = Tunnel.open(cfg, "mysql", admin)) {
    String url = "jdbc:mysql://" + tun.host() + ":" + tun.port() + "/orders";
    try (Connection c = DriverManager.getConnection(url, "app", "...")) {
        // ...
    }
}
```

完整 API：[client-side/sdk-java/SDK.md](client-side/sdk-java/SDK.md)
镜像与部署：[client-side/sdk-java/DEPLOY.md](client-side/sdk-java/DEPLOY.md)

## 常见场景

| 我想 | 看哪 |
|------|------|
| 让 SDK 自动 ensure_outlet 创建 MySQL 通道 | sdk-python/SDK.md "场景 1" |
| 一个应用同时连 MySQL + Redis + Kafka | sdk-python/SDK.md "场景 4" |
| 客户端身份轮换（旧 identifier 撤销，新 identifier 上线） | sdk-python/SDK.md "场景 5" |
| 长连接 + 数据库连接池 | sdk-java/SDK.md "场景 1" |
| 部署到完全离线的环境 | ockam-server/install/DEPLOY.md "离线安装" |
| 远程改 outlet 配置（添加新数据源） | ockam-server/controller/SDK.md |
| 多客户端共享一套 ockam-server | 任意 DEPLOY.md ——多个 identifier 加到 outlet 的 allow 列表即可 |

## 架构与原理（深入）

- **总览图 + 设计原则**：[ockam-server/docker/DEPLOY.md "原理"](ockam-server/docker/DEPLOY.md)
- **抓包对比报告（明文 vs 密文）**：[REPORT.md](REPORT.md)
- **控制面 API 规范**：[ockam-server/controller/SDK.md](ockam-server/controller/SDK.md)
- **Phase 1-4 演示原型**：[phase1/README.md](phase1/README.md) [phase2/README.md](phase2/README.md) [phase3/README.md](phase3/README.md) [phase4/README.md](phase4/README.md)

## 全部目录速查

```
ockam-demo/
├── README.md                ← 你在这儿
├── REPORT.md                ← 抓包对比报告（明文 vs 加密）
│
├── ockam-server/            ← 服务端（运维侧）
│   ├── controller/          ← 控制面 FastAPI app
│   │   ├── DEPLOY.md / SDK.md / verify.sh
│   ├── docker/              ← Mode A：我们的 Docker 镜像
│   │   ├── Dockerfile
│   │   ├── docker-compose.example.yml
│   │   ├── DEPLOY.md / SDK.md / verify.sh
│   └── install/             ← Mode B：装到主机
│       ├── install.sh / pack-offline.sh
│       ├── DEPLOY.md / SDK.md / verify.sh
│
├── client-side/             ← 数据使用方（开发侧）
│   ├── sdk-python/          ← Python SDK
│   │   ├── DEPLOY.md / SDK.md / verify.sh
│   ├── sdk-java/            ← Java SDK
│   │   ├── DEPLOY.md / SDK.md / verify.sh
│   ├── images/              ← 客户端基础镜像（Ubuntu / Rocky / openEuler）
│   └── examples/            ← python_mysql.py / JdbcDemo.java
│
├── e2e-real/                ← 完整产品端到端
│   ├── DEPLOY.md / SDK.md / verify-modeA.sh / verify-modeB.sh
│
└── (phase1-4)               ← 抓包对比演示原型
    ├── phase1/  client/  mysql/  ockam/  compose/  phase2/  phase3/  phase4/
    ├── captures/            ← pcap + 报告
```

## 故障排查

### 部署侧

| 现象 | 看哪 |
|------|------|
| Mode A 容器 healthcheck 红 | [ockam-server/docker/DEPLOY.md "常见故障"](ockam-server/docker/DEPLOY.md) |
| Mode B `install.sh` 报错 | [ockam-server/install/DEPLOY.md "常见故障"](ockam-server/install/DEPLOY.md) |
| controller 不响应 | [ockam-server/controller/DEPLOY.md "常见故障"](ockam-server/controller/DEPLOY.md) |

### 应用侧

| 现象 | 看哪 |
|------|------|
| Python SDK 报错 | [client-side/sdk-python/DEPLOY.md "故障排查"](client-side/sdk-python/DEPLOY.md) |
| Java SDK 报错 | [client-side/sdk-java/DEPLOY.md "故障排查"](client-side/sdk-java/DEPLOY.md) |

## 端到端验证（开发者自验）

```bash
./e2e-real/verify-modeA.sh   # 5 个 verify 全跑
./e2e-real/verify-modeB.sh   # install.sh 矩阵
```

也可以单独跑某一批的 verify.sh：见各目录。

## 卸载

- Mode A：`docker compose -f ockam-server/docker/docker-compose.example.yml down -v`
- Mode B：`sudo ockam-srv uninstall && sudo rm -rf /var/lib/ockam-{server,controller}`
- 客户端：删镜像 / `pip uninstall ockam-client`

## 开发与贡献

依赖：Docker 25+ / Bash / 任何能跑 docker 的 OS。

每改一个组件，跑该组件的 `verify.sh` 自验；合并前跑 `e2e-real/verify-modeA.sh`。

详细工程实施日志：[REPORT.md](REPORT.md) 的 "演示中遇到并解决的真实坑"

# SDK.md — 如何对接 Mode A 服务端

面向 SDK / 应用开发者：你已经有了运维部署好的 ockam-server 容器（[DEPLOY.md](DEPLOY.md)），现在要从你的 Python / Java 应用通过 SDK 用它来加密访问数据。

## 1. 你需要拿到的 3 件东西

运维交付给你的应该是：

```
provider.id         # 文本一行，I9c4ff6cd...   ← provider 节点的 ockam identifier
provider.host:14000 # 服务端容器对外的 host:port
```

加上你**自己**生成的：

```
admin-identity.json # 你应用的 ockam identity 文件（vault 物料）
```

如何生成 admin identity：

```bash
docker run --rm -v "$(pwd)/admin-vault:/var/lib/ockam-server" \
  -e OCKAM_HOME=/var/lib/ockam-server \
  --entrypoint sh ockam-demo-server:latest -c \
  'ockam identity create app && ockam identity show --output json | jq -r .identifier'
# 输出 "I3a6cf971..." — 把这个 identifier 给运维加到 ADMIN_IDENTIFIERS
```

> 在 B3/B4 中，Python/Java SDK 会自动帮你做这步。下面是底层模型，便于理解。

## 2. 你的应用要跑什么

不论 Python 还是 Java，逻辑都是一样：

```
1. 启动本地 ockam node（短寿命，跟随 SDK 上下文）
2. 加载本地 identity（你的 admin / app identity 文件）
3. 与 provider:14000 建立 Noise XX secure channel
4. 在 secure channel 之上创建本地 tcp-inlet —— 转发到服务端某个 outlet
5. 上层业务把 inlet 的 (host, port) 当作真实数据库地址用
6. 用完 close()，本地 ockam node 销毁
```

具体 SDK API 在 B3 / B4：
- Python：[../../client-side/sdk-python/SDK.md](../../client-side/sdk-python/SDK.md)
- Java：[../../client-side/sdk-java/SDK.md](../../client-side/sdk-java/SDK.md)

## 3. 控制面：运行时配置 outlet

你的应用启动时通常要"确保某个 outlet 存在并且把自己加入允许列表"。SDK 提供 `ProviderAdmin`：

```python
from ockam_client import ProviderAdmin, Identity

admin_id = Identity.load("admin-identity.json")

with ProviderAdmin(server="provider.host:14000", identity=admin_id) as admin:
    admin.ensure_outlet(name="mysql", target="10.0.0.5:3306")
    admin.ensure_client_authorized(outlet="mysql", identifier=admin_id.identifier)
```

`ProviderAdmin` 内部：
- 走 Ockam tunnel 到 `controller` outlet
- 调控制面 HTTP API（[../controller/SDK.md](../controller/SDK.md) 里的端点）
- 关闭时清理本地节点

## 4. 数据面：实际访问 MySQL

```python
from ockam_client import Tunnel, Identity

app_id = Identity.load("app-identity.json")  # 可与 admin 同一份
with Tunnel.open(server="provider.host:14000", target="mysql", identity=app_id) as tun:
    import pymysql
    conn = pymysql.connect(host=tun.host, port=tun.port,
                           user="app", password="...", database="orders")
    with conn.cursor() as cur:
        cur.execute("SELECT * FROM orders LIMIT 10")
        print(cur.fetchall())
```

`tun.host` 是 `127.0.0.1`、`tun.port` 是 SDK 启动时 OS 分配的随机端口。**你 0 行 SQL 代码改动**，只是把 host/port 换成 SDK 给的。

## 5. 安全模型一图流

```
你的 app                     services 边界                       provider 容器
─────────────────────────    ───────────────────────────         ─────────────
 SDK ─┬─ identity = I_app    │                                   │
      │                      │                                   │
      ├─[Noise XX 加密]──────┼─→ port 14000 / Ockam transport ──→│
      │                      │   ↳ outlet "mysql" allow=[I_app]  │
      │                      │                                   │
      ▼                      │                                   ▼
 你的 SQL 驱动                 │                                   真实 MySQL
 (拿 inlet 的 127.0.0.1:auto)
```

- 网络上能抓到的只有密文
- outlet 的 `--allow` 在 Ockam 层就拒绝了未授权的 identifier，SDK 之外的恶意客户端连密文都建立不起来

## 6. 跟 controller HTTP API 直接对话（高级）

如果你不想用 SDK 而是用裸 HTTP 调用 controller，等价示例（仍然要走 Ockam tunnel，否则到不了 127.0.0.1:8080）：

```bash
# 假设你已经有一个本地 inlet 在 127.0.0.1:18080 → provider.host:14000/service/controller
curl -s http://127.0.0.1:18080/healthz
curl -s -X POST http://127.0.0.1:18080/outlets \
  -H 'Content-Type: application/json' \
  -d '{"name":"mysql","target":"10.0.0.5:3306","allow":["Iapp_xxx"]}'
```

完整端点列表见 [../controller/SDK.md](../controller/SDK.md)。

## 7. 多客户端、多服务

一个 Mode A 容器可以同时承载多个 outlet：

```python
admin.ensure_outlet(name="mysql", target="10.0.0.5:3306")
admin.ensure_outlet(name="redis", target="10.0.0.6:6379")
admin.ensure_outlet(name="kafka", target="10.0.0.7:9092")
```

每个 outlet 独立的 allow 列表。同一个 app 可以同时打开多条 tunnel 到不同 outlet。

## 8. 故障 / 排查（SDK 视角）

| 现象 | 含义 |
|------|------|
| `OckamProcessError: secure channel timed out` | provider host 不可达，或者 14000 没开放 |
| `OckamProcessError: ... not authorized` | 你的 identifier 不在目标 outlet 的 allow 列表 |
| `OckamControllerError: 401` | 你不是 admin，但调了管理端点 |
| `tun.port` 拿到了，但 SQL 驱动连不上 | provider 端 outlet 配错了，target 不存在 / 端口错；用 `admin.list_outlets()` 看 `state` 字段 |
| 应用启动几秒后才能 query | 这是正常的：node 创建 + secure-channel 握手大约 2~3s |

## 9. 端到端验证（跟着这个走过一遍就明白）

[`verify.sh`](verify.sh) 演示了 SDK 该做的整套交互——只是用裸 ockam CLI + curl 而不是 SDK。读它的 T9 部分相当于看完了一份"伪 SDK 实现"。

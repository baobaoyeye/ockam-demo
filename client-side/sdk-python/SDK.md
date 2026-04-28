# SDK.md — `ockam_client` Python API

## 安装

```bash
pip install ockam-client            # 核心
pip install 'ockam-client[mysql]'   # 含 pymysql
```

需要：Python 3.10+，`ockam` 二进制在 PATH（或 env `OCKAM_BINARY`）。

## 30 秒上手

```python
from ockam_client import connect
import pymysql

with connect(server="provider.example.com:14000",
             target_outlet="mysql",
             ockam_home="/var/lib/ockam-client") as tun:
    conn = pymysql.connect(host=tun.host, port=tun.port,
                           user="app", password="...", database="orders")
    cur = conn.cursor()
    cur.execute("SELECT * FROM orders LIMIT 10")
    print(cur.fetchall())
```

## 顶层 API

### `connect(...)` — 便利模式

```python
def connect(*,
    server: str | ServerConfig,         # "host:port" 或 ServerConfig
    target_outlet: str,                  # 服务端 outlet 名字
    target: Optional[str] = None,        # "host:port"，如设了 + admin_identity_name 会自动 ensure_outlet
    ockam_home: str = "/var/lib/ockam-client",
    app_identity_name: str = "app",
    admin_identity_name: Optional[str] = None,
    expected_identifier: Optional[str] = None,
) -> Tunnel
```

返回一个 `Tunnel`，用作上下文管理器。如果传了 `target` + `admin_identity_name`，会先用 admin 身份去服务端 ensure 这个 outlet（自我引导部署）。

### `Tunnel.open(...)` — 直接打开数据通道

```python
@classmethod
def open(cls, *,
    server: ServerConfig | str,
    target: str,
    identity: Identity,
    node_name: str | None = None,
) -> "Tunnel"
```

适合：你已经知道服务端 outlet 配好了，只需要打开通道。

```python
tun = Tunnel.open(server="provider:14000", target="mysql", identity=app_id)
print(tun.host, tun.port)   # ('127.0.0.1', 41023)
tun.close()
```

属性：`host`, `port`, `address`（= `host:port`）。也是上下文管理器。

### `ProviderAdmin` — 远程配置控制面

```python
admin = ProviderAdmin(server="provider:14000", identity=admin_identity, timeout=10.0)
with admin:
    admin.healthz()                                 # → dict
    admin.info()                                    # → dict (含 provider identifier)
    admin.list_outlets()                            # → list
    admin.list_clients()                            # → list
    admin.get_audit(since="2026-04-25T00:00:00Z")   # → list

    # 写
    admin.ensure_outlet(name="mysql", target="10.0.0.5:3306",
                        allow=["I_app_xxx"])         # 幂等 upsert
    admin.ensure_client_authorized(outlet="mysql", identifier="I_app_yyy")
    admin.revoke_client_from_outlet(outlet="mysql", identifier="I_app_yyy")
    admin.delete_outlet("mysql")

    admin.register_client(identifier="I_xxx", label="data-pipeline-7")
    admin.revoke_client("I_xxx")
```

内部：`__enter__` 开一条 `Tunnel.open(target="controller")`，把 `httpx.Client` 指向本地 inlet。所有方法是同步阻塞的。

### `Identity`

```python
class Identity:
    home: Path
    name: str
    identifier: str

    @classmethod
    def load_or_create(cls, home: str | Path, name: str = "default") -> "Identity"
    @classmethod
    def load(cls, home: str | Path, name: str = "default") -> "Identity"
```

不直接持有密钥。它只是 OCKAM_HOME 的句柄，所有 vault 操作走 `ockam` CLI。

### `ServerConfig`

```python
ServerConfig(
    host: str,
    port: int = 14000,
    expected_identifier: Optional[str] = None,    # 抗 MITM：握手时用 --authorized
    connect_timeout: float = 30.0,
)
```

## 异常

```python
class OckamClientError(Exception):                  # 根
class OckamProcessError(OckamClientError):          # ockam CLI 出错
    stderr: str
    returncode: int | None
class OckamControllerError(OckamClientError):       # controller HTTP 非 2xx
    status_code: int
    body: str
class IdentityError(OckamClientError):              # 身份/vault 出问题
```

通用建议：所有 SDK 调用都包 `try/except OckamClientError`，记录 `e.stderr` / `e.body` 帮助排查。

## 常见业务场景

### 场景 1：单一应用 + 单数据库（90% 情况）

```python
with connect(server="provider:14000",
             target_outlet="mysql",
             target="10.0.0.5:3306",                # 自动 ensure_outlet
             admin_identity_name="admin") as tun:
    pool = create_engine(f"mysql+pymysql://app:pwd@{tun.host}:{tun.port}/orders")
    # ... 一直跑业务 ...
```

### 场景 2：常驻服务，连接池长期存活

```python
import contextlib

# 把 Tunnel 提到模块级，让连接池打到固定的 host:port
_tunnel = Tunnel.open(server="provider:14000", target="mysql",
                      identity=Identity.load_or_create("/var/lib/ockam-client"))

# 退出时
@contextlib.atexit_register if hasattr(contextlib, "atexit_register") else atexit.register
def _cleanup():
    _tunnel.close()

POOL = create_engine(f"mysql+pymysql://app:pwd@{_tunnel.host}:{_tunnel.port}/orders",
                     pool_size=10, pool_pre_ping=True)
```

### 场景 3：批处理脚本，跑完就退

```python
# 干净的 with 语境
with connect(...) as tun:
    run_etl_job(host=tun.host, port=tun.port)
# Tunnel 自动清理
```

### 场景 4：多 outlet (mysql + redis + kafka)

```python
admin_id = Identity.load_or_create("/var/lib/ockam-client", name="admin")
with ProviderAdmin(server="provider:14000", identity=admin_id) as admin:
    admin.ensure_outlet(name="mysql", target="10.0.0.5:3306", allow=[admin_id.identifier])
    admin.ensure_outlet(name="redis", target="10.0.0.6:6379", allow=[admin_id.identifier])
    admin.ensure_outlet(name="kafka", target="10.0.0.7:9092", allow=[admin_id.identifier])

with Tunnel.open(server="provider:14000", target="mysql", identity=admin_id) as my, \
     Tunnel.open(server="provider:14000", target="redis", identity=admin_id) as re:
    # 同时用两条 tunnel
    ...
```

### 场景 5：客户端 identifier 轮换

```python
old = Identity.load("/var/lib/ockam-client", name="app")
# 生成新的
new = Identity.load_or_create("/var/lib/ockam-client", name="app-v2")

with ProviderAdmin(server="provider:14000",
                   identity=Identity.load("/var/lib/ockam-client", name="admin")) as admin:
    admin.ensure_client_authorized(outlet="mysql", identifier=new.identifier)
    # 业务切到 new
    admin.revoke_client_from_outlet(outlet="mysql", identifier=old.identifier)
```

## 并发与线程

- `Tunnel` / `ProviderAdmin` **不是线程安全**的——每个并发线程开自己的实例
- 同一进程多个 Tunnel 没问题，每个用独立的 ockam node（节点名带 pid + random hex）
- 大量并发场景：让连接池跨用同一个 Tunnel，pool 自己处理多路复用

## 超时与重试

- 默认 secure-channel 握手超时 30s（`ServerConfig.connect_timeout`）
- 控制面 HTTP 超时 10s（`ProviderAdmin(timeout=...)`）
- SDK 不内置重试。建议用 [`tenacity`](https://github.com/jd/tenacity) 之类在你的业务层包一层

```python
from tenacity import retry, stop_after_attempt, wait_exponential
from ockam_client import OckamProcessError

@retry(stop=stop_after_attempt(3),
       wait=wait_exponential(min=1, max=10),
       retry_error_cls=OckamProcessError)
def my_query():
    with Tunnel.open(...) as tun:
        ...
```

## FAQ

**Q: 我的 identity 文件丢了，能不能恢复？**
A: 不能，identity 是新的密钥对。生成新的，让运维更新 allow 列表，旧的应当 revoke。

**Q: 一个 Tunnel 能同时被多个 thread 用吗？**
A: `tun.host`/`tun.port` 是不可变的，连接到这个 host/port 的 socket 是任意线程都可以的（OS 层面）。但不要从多个线程并发调用 `tun.close()`。

**Q: Tunnel 启动慢，怎么办？**
A: secure-channel 握手 + node 启动一次约 2-3 秒。常驻服务用场景 2 模式，启动一次后复用。

**Q: 如何调试？**
A: `OCKAM_BINARY=/path/to/ockam` + `RUST_LOG=debug` 让 ockam 子进程把详细日志吐到 stderr，SDK 会把 stderr 放到 `OckamProcessError.stderr` 里。

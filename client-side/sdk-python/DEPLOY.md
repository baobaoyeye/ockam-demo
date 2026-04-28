# DEPLOY.md — Python SDK 部署

面向运维 / 应用打包者：把 Python SDK 装进你的应用容器或主机。

API 文档见 [SDK.md](SDK.md)。

## 1. 装哪儿

应用进程要能找到：
- **`ockam` 二进制**（musl 静态版本，PATH 可见 / 或 `OCKAM_BINARY=/path/to/ockam`）
- **Python 3.10+** 解释器
- **`ockam-client` Python 包**

容器化部署时把这三件打进同一个镜像。

## 2. 直接用 pip 装

```bash
pip install /path/to/ockam_client-*.whl
# 或开发模式
pip install -e /path/to/sdk-python
# 可选 extras：mysql 驱动
pip install 'ockam-client[mysql]'
```

## 3. 推荐：用我们提供的容器镜像

提供两个层：
- `ockam-demo-client-base:latest`（任选 `ubuntu` / `rocky` / `openeuler` 起步）—— 只装 ockam binary
- `ockam-demo-client-python:latest` —— base + Python 3 + SDK + pymysql

### 构建（一次）

```bash
cd /path/to/ockam-demo
docker build -f client-side/images/base.ubuntu.Dockerfile \
  -t ockam-demo-client-base:latest client-side/images
docker build -f client-side/images/python.Dockerfile \
  --build-arg BASE=ockam-demo-client-base:latest \
  -t ockam-demo-client-python:latest client-side
```

把 `base.ubuntu` 换成 `base.rocky` / `base.openeuler` 即可换底。

### 在你自己的应用 Dockerfile 中复用

```dockerfile
FROM ockam-demo-client-base:latest

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip && rm -rf /var/lib/apt/lists/*

COPY sdk-python /tmp/sdk
COPY my-app /app
RUN pip install /tmp/sdk pymysql && rm -rf /tmp/sdk

WORKDIR /app
ENV OCKAM_HOME=/var/lib/ockam-client
VOLUME /var/lib/ockam-client
CMD ["python", "main.py"]
```

## 4. 持久化 OCKAM_HOME

SDK 在 `OCKAM_HOME` 下生成本地 identity / vault / node 元数据：

```
/var/lib/ockam-client/
├── application_database.sqlite3
└── database.sqlite3
```

**生产部署必须把这个目录挂成持久化卷**，否则容器重启后 identity 变化，运维要重新加白名单。

```yaml
services:
  my-app:
    image: my-app:latest
    volumes:
      - app-ockam:/var/lib/ockam-client
volumes:
  app-ockam:
```

## 5. 运行时环境变量

SDK 不强制任何 env，但下面这些会影响行为：

| 变量 | 含义 |
|------|------|
| `OCKAM_HOME` | identity / node 状态目录。默认 `~/.ockam`，建议显式设到挂载目录 |
| `OCKAM_BINARY` | ockam CLI 路径。PATH 找不到时设 |

应用自己用的（约定俗成）：

| 变量 | 用途（按 examples/python_mysql.py） |
|------|-----------------------------------|
| `OCKAM_SERVER_HOST` | provider 容器/主机的 host |
| `OCKAM_SERVER_PORT` | 一般 `14000` |
| `OCKAM_SERVER_IDENTIFIER` | 可选，pin provider identity 抗 MITM |
| `OCKAM_OUTLET` | server 上 outlet 的名字（如 `mysql`） |

## 6. SDK 依赖

| 包 | 用途 |
|----|------|
| `httpx` | ProviderAdmin HTTP 客户端 |

可选：
- `pymysql`（你需要的话）— 走 SDK tunnel 连 MySQL

## 7. 故障排查

| 现象 | 排查方向 |
|------|---------|
| `IdentityError: ockam not found` | 容器里没装 ockam。`docker exec my-app which ockam`，没有就用我们的 base 镜像 |
| `OckamProcessError: secure-channel timed out` | server 不可达 / 端口被防火墙挡 |
| `OckamProcessError: ... not authorized` | 你的 identifier 没加到目标 outlet 的 allow 列表，找运维或自己用 admin identity 调 ProviderAdmin |
| `OckamControllerError: 401` | 你不是 admin 但调了管理端点（这一项目前几乎不会触发，因为 server 默认 TRUST_ALL） |
| `OckamControllerError: 500 outlet apply failed` | 服务端 ockam node 拒绝创建 outlet（target 不可达 / 名字冲突），看 `docker logs ockam-server` |
| 业务驱动连不上 `tun.host:tun.port` | 服务端 outlet target 配错了或目标服务挂了；用 `admin.list_outlets()` 看 `state` 字段 |

## 8. 升级

```bash
pip install --upgrade /path/to/new/ockam_client-*.whl
# 容器化场景：rebuild image，rolling restart
```

## 9. 端到端验证

`./verify.sh`（在本目录下，repo 根可读）做完整链路：构建镜像 → 起 ockam-server + mysql → 跑 python_mysql 例子 → 抓 14000 端口的 wire 流量 → 检查无明文。

```
T1: build base + python images, reuse ockam-demo-server image
T2: pre-generate admin identity in tempvol
T3: render docker-compose.yml
T4: docker compose up server stack
T5: attach sniffer to sdkpy-server's net ns (capture eth0 on tunnel)
T6: run python-app (uses SDK to ensure outlet + tunnel + SQL)
T7: stop sniffer + flush pcap
T8: scan pcap for plaintext markers (must all be 0)

PASS  Python SDK end-to-end: SQL ran through Ockam tunnel, wire is encrypted
```

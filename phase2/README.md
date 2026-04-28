# Phase 2 — 用 Ockam 安全通道加密同样的流量

## 目标

在不改 Python 客户端代码、不改 MySQL 配置的前提下，仅通过在两端各部署一个 [Ockam](https://www.ockam.io/) 节点，把 Phase 1 那条裸明文 TCP 链路变成 Noise XX 派生密钥加密的安全通道。验证：

1. 业务行为完全不变（INSERT、SELECT 结果与 Phase 1 一致）
2. 网络上能抓到的只剩密文 —— SQL、字段名、表名、参数值全部不可见

## 拓扑与信任域

```
┌────── trust zone "client side" ───────┐    ┌──── trust zone "server side" ─────┐
│                                       │    │                                   │
│  python  ──127.0.0.1:15432──▶ ockam-  │    │  ockam-server ──tcp 3306, plain──▶│
│ (sidecar)                     client  │    │                            mysql  │
│                                  │    │    │            ▲                      │
└──────────────────────────────────┼────┘    └────────────┼──────────────────────┘
                                   │                       │
                                   │ Ockam transport (TCP) │
                                   │ + secure channel      │
                                   │ Noise XX derived key  │
                                   └──tcp 14000, ENCRYPTED──┘

           ┌────────────────────────┐
           │  sniffer (sidecar of   │  在 ockam-client 的 net ns 里抓 eth0
           │  ockam-client)         │  → 只能记录加密后的 Ockam 帧
           └────────────────────────┘
```

两个 Docker bridge 网络：

- `internal` —— 仅 `mysql` 与 `ockam-server`。MySQL 像在私有 VPC 里一样，对外不可达。
- `tunnel` —— 仅 `ockam-server` 与 `ockam-client`。这条线就是被加密的"互联网段"。

Python 客户端通过 `network_mode: service:ockam-client` 与 `ockam-client` 共享网络命名空间，所以它连接 `127.0.0.1:15432` 走的是本地 lo —— 入口的明文流量从不离开 client 这台主机。

## Ockam 配置（在容器内做了什么）

入口脚本 [ockam/entrypoint.sh](../ockam/entrypoint.sh) 用 `$ROLE` 切两种模式：

**ROLE=server**（在 ockam-server 上）：

```sh
ockam node create server --tcp-listener-address 0.0.0.0:14000
ockam tcp-outlet create --at server --to mysql:3306
```

- 第 1 行同时创建 Ockam 节点和它的对外 TCP 监听器（`0.0.0.0:14000`）。这个监听器本身也承载了默认的 secure-channel 监听服务 `/service/api`。
- 第 2 行创建一个 TCP outlet：portal 通道收到的流量，会被解封装后转发到 `mysql:3306`。

**ROLE=client**（在 ockam-client 上）：

```sh
ockam node create client
SC=$(ockam secure-channel create --from /node/client \
        --to /dnsaddr/ockam-server/tcp/14000/service/api)
ockam tcp-inlet create --at client --from 0.0.0.0:15432 --to "${SC}/service/outlet"
```

- 创建本地 Ockam 节点
- 与 server 端 `/service/api` 协商 Noise XX 安全通道，得到一个本地路由地址 `${SC}`（形如 `/service/<random>`）
- 创建 TCP inlet：本地 `0.0.0.0:15432` 收到的 TCP，包成 Ockam 帧，沿 `${SC}/service/outlet` 路由送到 server 端的 outlet，最终落到 mysql

为什么 Identity 用自动生成的：本演示要展示的是"线上密文不可读"，而不是身份认证。Ockam 默认握手（XX 模式）即使双方匿名也能建立前向安全的对称加密。生产场景应当用 enrollment ticket 把双方身份钉死。

## 关键文件

- [compose/phase2.yml](../compose/phase2.yml) — 服务编排
- [ockam/Dockerfile](../ockam/Dockerfile) — 多阶段构建：从官方 distroless 镜像 `ghcr.io/build-trust/ockam:latest` 拷贝二进制到 debian-slim
- [ockam/entrypoint.sh](../ockam/entrypoint.sh) — server / client 入口
- [client/demo.py](../client/demo.py) — **没改一行**，只是环境变量里把 host 改成 `127.0.0.1`、port 改成 `15432`

## 单独运行（不用 verify.sh）

```bash
# 1. 拉起 mysql + 两个 ockam 节点
docker compose -f compose/phase2.yml up -d mysql ockam-server ockam-client

# 2. 等到 ockam-client 把 inlet 拉起来
until docker logs phase2-ockam-client 2>&1 | grep -q "ready — inlet at"; do sleep 1; done

# 3. 启动抓包（sidecar 到 ockam-client 的命名空间）
mkdir -p captures
docker run -d --rm --name phase2-sniffer \
  --network container:phase2-ockam-client \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  -v "$(pwd)/captures:/captures" \
  nicolaka/netshoot:latest \
  sh -c "tcpdump -i any -nn -s 0 -U -w /captures/phase2.pcap 'tcp' & \
         trap 'kill -INT %1; wait %1' TERM INT; wait %1"

# 4. 等几秒，再跑 python 客户端
sleep 4
docker compose -f compose/phase2.yml up --no-deps --exit-code-from client client

# 5. 收尾
sleep 2
docker stop phase2-sniffer

# 6. 检查抓包：找不到任何明文 SQL/secret —— 因为它们都在密文里
docker run --rm -v "$(pwd)/captures:/captures" nicolaka/netshoot:latest \
  tcpdump -r /captures/phase2.pcap -A -nn 'not src host 127.0.0.1' \
  | grep -aE "PLAINTEXT|SELECT|INSERT|messages|alice|bob" || \
  echo "(nothing leaked)"
```

期望最后那行 grep **没有任何匹配输出** —— 一片空白就是成功。

## 我替 Ockam 解决了什么坑（构建过程）

- 安装时 `https://downloads.ockam.io` 被本地 HTTP 代理拦截；改成多阶段 Dockerfile `COPY --from=ghcr.io/build-trust/ockam:latest`，从官方 distroless 镜像里把二进制拿出来
- `ockam tcp-listener create --at server 0.0.0.0:14000` 命令成功返回但 **不会** 真正绑定到 0.0.0.0；正确做法是在 `node create` 阶段就用 `--tcp-listener-address` 指定
- `secure-channel create --to /ip4/<dns-name>/...` 报 "invalid IPv4 address syntax"；因为 `/ip4/` 顾名思义只接受 IPv4 字面量，Docker 服务名要用 `/dnsaddr/`
- `tcp-inlet create --to /ip4/.../secure/api/service/outlet` 这种"组合多跳"路由报 "No projects found"；现代 Ockam 把这种路由解析绑死到 Orchestrator 项目模型，纯 P2P 必须先 `secure-channel create` 拿到本地地址，再传给 inlet 的 `--to`

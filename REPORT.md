# 端到端验证报告：用 Ockam 把明文 MySQL 连接变成加密通道

## TL;DR

| 指标 | Phase 1（不加密） | Phase 2（Ockam 安全通道） |
|------|-------------------|--------------------------|
| 业务行为 | INSERT + SELECT 成功 | INSERT + SELECT 成功（与 Phase 1 完全一致） |
| 网络抓到的字节是什么 | 明文 SQL + 明文行数据 | Noise XX 派生密钥加密的二进制 |
| `grep PLAINTEXT_SECRET` 命中数 | **2 次** | **0 次** |
| `grep SELECT / INSERT / messages / alice / bob / mysql_native_password` | 全部命中 | 全部 0 |
| 客户端代码改动 | — | **0 行** |
| MySQL 配置改动 | — | **0 处** |
| 部署侧加了什么 | — | 两个 Ockam 容器（一个 outlet 一个 inlet） |

结论：**Phase 1 的明文流量对被动嗅探者完全可读；Phase 2 在没有改动应用代码也没有改动数据库的前提下，仅靠在两端旁挂 Ockam 节点，就让同样的流量在网络上不可读。**

## 实测数据

抓包指标取自一次 `./phase4/verify.sh` 运行，原始数据见 [captures/phase3-report.txt](captures/phase3-report.txt) 和两个 pcap 文件。

```
wire packets captured             phase1 (no Ockam)  phase2 (Ockam)
                                  23                 41

marker (literal substring)        found in phase1   found in phase2
PLAINTEXT_SECRET                  2                 0
SELECT                            1                 0
INSERT                            1                 0
messages                          3                 0
alice                             1                 0
bob                               1                 0
mysql_native_password             2                 0
```

> Phase 2 的网包数（41）多于 Phase 1（23），是因为 Ockam 两端要做 Noise 握手、心跳与控制帧。这些都是密文。

### Phase 1 抓到的样本字节（明文）

```
INSERT INTO messages (sender, content) VALUES ('client', 'PLAINTEXT_SECRET_FROM_phase1_AT_1777086094')
```

直接 ASCII 可读，包含表名、字段名、参数值。

### Phase 2 抓到的样本字节（密文）

```
0x0040:  3763 3934 3637 3934 6338 3664 3965 3035  7c946794c86d9e05
0x0050:  6365 3161 6637 3532 3433 3038 3161 8058  ce1af75243081a.X
0x0060:  5500 0000 0000 0000 01de 6bc4 3629 d5a2  U.........k.6)..
...
```

对应 ASCII 是高熵噪声 —— 攻击者无法判断里面有没有 SQL，更无法读到任何字段或参数。

## 整体方案（4 个阶段）

### Phase 1 — 明文基线
- Python（pymysql）→ tcp 3306 → MySQL 8.0
- MySQL 启动参数 `--skip-ssl --default-authentication-plugin=mysql_native_password`，让传输层完全裸明文
- 详细：[phase1/README.md](phase1/README.md)

### Phase 2 — 用 Ockam 做点对点加密
- Server 侧：`ockam node create server --tcp-listener-address 0.0.0.0:14000` + `ockam tcp-outlet create --at server --to mysql:3306`
- Client 侧：`ockam node create client` → `ockam secure-channel create --to /dnsaddr/ockam-server/tcp/14000/service/api`（Noise XX 握手） → `ockam tcp-inlet create --from 0.0.0.0:15432 --to ${SC}/service/outlet`
- Python 客户端只把目标改成 `127.0.0.1:15432`（本地 inlet），其他一行没动
- MySQL 完全不知道 Ockam 存在
- 详细：[phase2/README.md](phase2/README.md)

### Phase 3 — 攻击者视角
- 同一套 sniffer（`nicolaka/netshoot` + tcpdump，旁挂目标容器的 net namespace）
- [phase3/analyze.sh](phase3/analyze.sh) grep 一组明文标记字符串
- 输出 Phase 1 vs Phase 2 的命中数对比表
- 详细：[phase3/README.md](phase3/README.md)

### Phase 4 — 端到端编排
- [phase4/verify.sh](phase4/verify.sh) 串起来跑，自动判定 PASS/FAIL
- 详细：[phase4/README.md](phase4/README.md)

## 演示中遇到并解决的真实坑

| 问题 | 现象 | 原因 / 解决 |
|------|------|------|
| 下载 Ockam 二进制失败 | `curl` 到 `downloads.ockam.io` 报 SSL_ERROR_SYSCALL | 本机有 HTTP 代理拦截该域名。改用多阶段 Dockerfile，`COPY --from=ghcr.io/build-trust/ockam:latest /ockam` |
| `tcp-listener create` 看似成功却没绑定 0.0.0.0 | `ockam tcp-listener list` 显示只 bind 到随机的 127.0.0.1:xxxxx | Ockam 节点的对外 listener 必须在 `node create` 时用 `--tcp-listener-address` 指定，单独的 `tcp-listener create` 命令是别的语义 |
| `secure-channel create --to /ip4/<dns>/...` 报 IPv4 解析错 | "invalid IPv4 address syntax" | `/ip4/` 字面上要求 IPv4 字面量，Docker 服务名要走 `/dnsaddr/` |
| `tcp-inlet create --to /ip4/.../secure/api/service/outlet` 报 "No projects found" | 路由解析强行要找 Orchestrator 项目 | 现代 Ockam 的 inlet `--to` 默认指向 Orchestrator。纯 P2P 必须先 `secure-channel create` 拿到本地路由地址，再传给 inlet |
| compose 里的 sniffer `network_mode: service:mysql` 抓不到跨网桥流量 | 容器在正确的 netns、tcpdump 在跑、`/proc/net/dev` 字节计数在涨，但 pcap 只有 lo 的健康检查包 | Docker Desktop 29.x 的 packet socket 实现在 `network_mode: service:` 容器里有 bug。改用独立 `docker run --network container:<name>`，同样的命令立即正常 |
| `tcpdump -i any 'port 3306'` 漏包 | `-i any` 用 Linux cooked SLL2 链路层时，`port N` BPF 过滤器在某些桥接接口组合下不可靠 | 改用宽过滤 `'tcp'`，在分析阶段用 IP filter 过滤 loopback |
| 时序竞争：tcpdump 启动后立刻让 client 连接，第一波包丢失 | sniffer 进程已存在、pcap 文件已写头，但 libpcap 还没真正接到内核 packet socket | `start_sniffer` 之后再 `sleep 4`；client 命令内部也 `sleep 3` 让 tcpdump 的内核管道真正打通 |

## 前置条件 / 复现步骤

```
# 需要：macOS 或 Linux + Docker 25+
git clone <this repo>
cd ockam-demo
./phase4/verify.sh
```

期望输出最后一行：

```
PASS  phase1 leaked PLAINTEXT_SECRET 2 times (as expected without encryption);
      phase2 leaked it 0 times (Ockam secure channel encrypted the traffic).
```

## 局限性

这个 demo 只演示**被动嗅探不可读**这一个性质。它**不**演示：

1. **双向身份验证**：本 demo 用匿名 Noise XX，任何懂协议的对端都能跟 server 协商出加密通道。生产应当用 enrollment ticket 把双方身份钉死，并启用 access control。
2. **抗重放 / 抗篡改的细节**：理论上 Noise 自带 nonce 能抗重放，但本 demo 没单独设置攻击场景验证。
3. **server 端到 mysql 的最后一段**：在 Phase 2 中，`ockam-server → mysql` 仍然是明文。这一段处于"服务端信任域"内（同一个 Docker bridge `internal` 网络，外部不可达）。生产场景里这一段要么放在物理隔离的内网，要么也用 Ockam outlet 层叠。
4. **TLS-stripping / 降级攻击**。
5. **真实 WAN 环境**：本 demo 全在同一台 Docker Desktop 上，没有真实跨主机延迟和丢包。

## 下一步建议

如果要把这个 demo 进一步推到 production-shape：

- 给两个 Ockam 节点分别 enrol，启用 mutual authentication
- 把 `ockam-server` 和 mysql 改成跨主机部署，用 Ockam Orchestrator 做相对地址路由（`/project/<name>/service/<relay>/...`）
- 在 client 与 inlet 之间也加 mTLS 或本地 socket 权限控制，避免同主机其他进程乱用 inlet

# Phase 1 — 明文 MySQL 访问基线

## 目标

模拟一个常见但**不安全**的部署：Python 程序通过 MySQL 驱动直连远端 MySQL，传输层不加密。这一阶段确立两个事实：

1. 程序逻辑确实跑通了（连接、INSERT、SELECT）
2. 该流量在网络上以明文形式存在 —— 抓包可还原 SQL 语句、表名、字段名、参数值

## 拓扑

```
   ┌─────────────┐     bridge net `app`        ┌─────────────┐
   │  client     │ ──── tcp 3306, plaintext ──▶│   mysql     │
   │ (python)    │                             │  (8.0)      │
   └─────────────┘                             └─────────────┘
                                                      ▲
                                                      │ (sidecar net ns)
                                                ┌─────────────┐
                                                │  sniffer    │
                                                │  (tcpdump)  │
                                                └─────────────┘
```

- 一个普通的 Docker bridge 网络 `app`
- `mysql` 容器使用 `--default-authentication-plugin=mysql_native_password` 和 `--skip-ssl`，确保认证不会触发 RSA 包裹密码、传输层完全裸明文
- `client` 容器跑 [demo.py](../client/demo.py)，用 PyMySQL 连接、INSERT 一条带 `PLAINTEXT_SECRET_` 前缀的内容、再 SELECT 全表
- `sniffer` 容器（`nicolaka/netshoot`）通过 `--network container:phase1-mysql` 加入 mysql 的网络命名空间，运行 `tcpdump -i any 'tcp'`，写出 `captures/phase1.pcap`

## 为什么 MySQL 用 `--skip-ssl`

MySQL 8 默认生成 X.509 自签证书，并且对 `caching_sha2_password` 做 RSA 包裹的密码交换。即使数据查询是明文，密码本身就会因此被加密 —— 这会让"明文"演示不够纯粹。`--skip-ssl` 关掉 server 端的 TLS，再加 `mysql_native_password` 做用户认证，就得到一个完全的明文管道，方便和 Phase 2 直观对比。

> 这只是 demo 简化。生产环境应当至少启用 MySQL TLS 或上层加密通道。

## 关键文件

- [compose/phase1.yml](../compose/phase1.yml) — 服务编排（`mysql` + `client`，sniffer 由 verify.sh 单独 `docker run`）
- [client/demo.py](../client/demo.py) — Python 客户端
- [mysql/init.sql](../mysql/init.sql) — 初始化表 `messages` 并写入两条种子数据

## 单独运行（不用 verify.sh）

```bash
# 1. 启动 mysql
docker compose -f compose/phase1.yml up -d mysql

# 2. 启动抓包（sidecar 到 mysql 的网络命名空间）
mkdir -p captures
docker run -d --rm --name phase1-sniffer \
  --network container:phase1-mysql \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  -v "$(pwd)/captures:/captures" \
  nicolaka/netshoot:latest \
  sh -c "tcpdump -i any -nn -s 0 -U -w /captures/phase1.pcap 'tcp' & \
         trap 'kill -INT %1; wait %1' TERM INT; wait %1"

# 3. 等几秒让 tcpdump 真正就绪，然后跑 client
sleep 4
docker compose -f compose/phase1.yml up --no-deps --exit-code-from client client

# 4. 停掉 sniffer，让它把缓冲刷到磁盘
sleep 2
docker stop phase1-sniffer

# 5. 看抓到的明文
docker run --rm -v "$(pwd)/captures:/captures" nicolaka/netshoot:latest \
  tcpdump -r /captures/phase1.pcap -A -nn 'not src host 127.0.0.1' \
  | grep -E "INSERT|SELECT|PLAINTEXT"
```

期望看到类似：

```
INSERT INTO messages (sender, content) VALUES ('client', 'PLAINTEXT_SECRET_FROM_phase1_AT_1777086094')
SELECT id, sender, content FROM messages ORDER BY id
```

字段名、表名、参数值都可读 —— 这就是没有加密的代价。

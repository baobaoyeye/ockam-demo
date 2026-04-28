# Phase 4 — 端到端验证脚本

## 目标

把 Phase 1、2、3 串起来跑一遍，保证整套演示是**自动、可复现、有判定**的：

```
build → run phase1 (capture) → run phase2 (capture) → analyze → PASS/FAIL
```

## 用法

```bash
./phase4/verify.sh
```

无参数。退出码：

| 退出码 | 含义 |
|--------|------|
| 0 | PASS：phase1 抓到了 PLAINTEXT_SECRET，phase2 没抓到 |
| 2 | FAIL：判定不符合预期，报告里有线索 |
| 其他非零 | 半路某一步失败（mysql 不健康、ockam 起不来…），脚本会用 `==>` 提示在哪一步 |

## 它做了什么

1. **0/4 Build images** —— `docker compose build` 三个镜像（client、ockam，mysql 直接拉 hub）
2. **1/4 Phase 1**
   - 启 `phase1-mysql`，等健康
   - 用 `docker run --network container:phase1-mysql` 单独起 sniffer，等 tcpdump 真正开始抓包（pcap 文件 ≥24 字节 + 4 秒 libpcap 预热）
   - `compose up --no-deps --exit-code-from client client` 运行客户端，等它退出
   - 等 2 秒让 tcpdump 把缓冲刷盘，`docker stop` 优雅停 sniffer
   - 拆掉 phase1 的 compose stack
3. **2/4 Phase 2**
   - 启 mysql + ockam-server + ockam-client，等三者就绪（mysql healthy + ockam-client 日志里出现 `ready — inlet at`）
   - 同样用 `docker run --network container:phase2-ockam-client` 起 sniffer
   - 跑客户端、停 sniffer、拆 stack
4. **3/4 Phase 3** —— 调 [phase3/analyze.sh](../phase3/analyze.sh) 出报告
5. **4/4 Verdict** —— 解析报告里 `PLAINTEXT_SECRET` 那一行，phase1>0 且 phase2=0 即 PASS

成功后脚本不删除 `captures/`，方便你用 Wireshark 自己再看。

## 为什么 sniffer 不放在 compose 里

最早 sniffer 是 compose 服务，`network_mode: service:mysql`。在本机的 Docker Desktop 29.x 上发现：tcpdump 进程跑得起来、网络命名空间也确实和 mysql 共享、`/proc/net/dev` 里看得到 eth0 的字节计数在涨——但 tcpdump 始终捕获不到 eth0 的跨网桥数据包，只能看到 lo 上的 mysqladmin 健康检查噪声。

把同样的镜像、同样的命令、同样的 caps 改用一条独立 `docker run --network container:<name>` 启动，立刻就能正常抓 eth0。这是 Docker Desktop 在某些版本里 `network_mode: service:` 对 packet socket 的实现差异。

为避免读者踩同一个坑，verify.sh 直接用 `docker run` 起 sniffer。compose 文件里只剩业务服务。

## 时序里的几处显式 sleep

- start_sniffer 之后 `sleep 4` —— libpcap 在 Docker 网络命名空间里把内核包送到用户态需要几秒才稳定
- client 命令里 `sleep 3 && python …`（Phase 1）/ `sleep 8 && python …`（Phase 2，留出 ockam 通道首包握手时间）
- client 退出后 `sleep 2` 再 stop sniffer，让 `-U` per-packet 写入缓冲落盘

这些数字是经验值。如果你的机器更慢，把它们调大不会有副作用。

# Phase 3 — 攻击者视角的对比

## 目标

模拟"网络上有一个被动监听者"的攻击场景：把 Phase 1、Phase 2 在网络上抓到的字节扔给同一套对比工具，回答一个简单的问题——

> 如果攻击者拿到了这两个 pcap，他能从中读到什么？

## 抓包是怎么做的

为了让对比尽可能公平，两个阶段的 sniffer 都用同一套：

- 镜像：`nicolaka/netshoot:latest`
- 命令：`tcpdump -i any -nn -s 0 -U -w <pcap> 'tcp'`
- 通过 `docker run --network container:<target>` 共享目标容器的网络命名空间
- `cap_add: [NET_ADMIN, NET_RAW]`

差别仅仅在于"挂在哪个容器旁边"：

| 阶段 | sniffer 旁挂目标 | sniffer 看到的网卡 |
|------|------------------|---------------------|
| Phase 1 | `phase1-mysql`   | mysql 自己的 lo（healthcheck 噪声）+ eth0（client→mysql 的明文 SQL） |
| Phase 2 | `phase2-ockam-client` | ockam-client 的 lo（python→inlet 的本地明文）+ eth0（→ockam-server 的加密 Ockam 帧） |

`analyze.sh` 在分析阶段统一用 `not src host 127.0.0.1 and not dst host 127.0.0.1` 过滤掉所有 loopback 流量 —— 我们只关心**真正离开主机的字节**。

## 分析脚本做了什么

[analyze.sh](analyze.sh) 把两个 pcap 喂给 tcpdump，分别 grep 一组"明文标记字符串"：

```
PLAINTEXT_SECRET    我们种入数据库的标记
SELECT, INSERT      SQL 关键字
messages            表名
alice, bob          数据库里的字符串值
mysql_native_password   认证插件名（明文握手时会出现）
```

每个标记都得到 Phase 1 命中数 vs Phase 2 命中数，并打印两个 pcap 的样本字节。

## 单独运行

```bash
# 前提：captures/phase1.pcap 和 captures/phase2.pcap 已经存在
./phase3/analyze.sh
```

报告也会写到 `captures/phase3-report.txt`。

## 期望结果

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

Phase 1 那一列每个标记都有命中 —— 攻击者能 grep 出 SQL 全文。Phase 2 那一列**全是 0** —— 同样的字节被 Noise XX 派生密钥加密，从外面看就是高熵随机串。

样本字节也一目了然：

- Phase 1：`INSERT INTO messages (sender, content) VALUES ('client', 'PLAINTEXT_SECRET_FROM_phase1_AT_...')`
- Phase 2：纯十六进制 ASCII 不可读

## 局限性

这个 demo 只回答"被动嗅探能看到什么"。它**没有**演示：

- 主动 MITM 篡改 / 伪造（Ockam 的 secure channel 通过密钥派生抗这一类攻击，但本 demo 没用到 enrollment ticket，所以也没强制双方身份验证）
- 重放攻击（Noise XX 自带 nonce，理论上抗重放，本 demo 也没单独测）
- TLS-stripping 类降级攻击

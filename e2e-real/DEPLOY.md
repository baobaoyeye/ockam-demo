# DEPLOY.md — 端到端部署案例

每个组件的部署方式见各自目录的 DEPLOY.md。这里汇总两种**完整生产场景**的部署示例。

## 场景 1：你自己运营加密代理（Mode A）

适用：数据提供方机器拿不到 / 不能装东西，但你有一台机器能 routable 到他们的 TCP 服务（同一 VPC、跳板机、SD-WAN 等）。

```
[ 互联网 / 你的 VPC ]
     ▲
     │ tcp 14000 加密
     ▼
┌──────────────────────────┐
│ 你的 Docker host         │
│  ┌────────────────────┐  │
│  │ ockam-server       │  │     图片 + DEPLOY:
│  │ (Mode A 容器)      │──┼───→ ../ockam-server/docker/
│  └────────────────────┘  │
└──────────────────────────┘
     │
     │ 内网 tcp 3306（不加密但是私网）
     ▼
[ 数据提供方 MySQL ]
```

部署步骤：
1. 按 [../ockam-server/docker/DEPLOY.md](../ockam-server/docker/DEPLOY.md) 起 Mode A 容器
2. 按 [../client-side/sdk-python/DEPLOY.md](../client-side/sdk-python/DEPLOY.md) / [../client-side/sdk-java/DEPLOY.md](../client-side/sdk-java/DEPLOY.md) 把 SDK 集成进你的应用

## 场景 2：装到数据提供方主机（Mode B）

适用：数据提供方愿意让你装一个 systemd 服务在他们的主机上。

```
[ 互联网 ]
     ▲
     │ tcp 14000 加密
     ▼
┌──────────────────────────┐
│ 数据提供方 Linux 主机    │
│  ┌────────────────────┐  │
│  │ ockam-server       │  │     图片 + DEPLOY:
│  │ (systemd 装)       │──┼───→ ../ockam-server/install/
│  └────────────────────┘  │
│  ┌────────────────────┐  │
│  │ MySQL              │  │
│  └────────────────────┘  │
└──────────────────────────┘
```

部署步骤：
1. 按 [../ockam-server/install/DEPLOY.md](../ockam-server/install/DEPLOY.md) 把 install.sh 跑在他们主机上
2. SDK 部分同场景 1

## 场景 3：混合（不同数据源用不同 mode）

完全可以。一个 SDK 应用同时连：
- 一个 Mode A 容器（代理远端 DB1）
- 一个 Mode B 主机（DB2 在那台机器上）

只要给两个 ServerConfig 即可。

## 端到端验证

```bash
./verify-modeA.sh    # 5 个 verify 串行
./verify-modeB.sh    # install.sh 矩阵
```

期望两个都打印 `PASS`。

# DEPLOY.md — Mode B 主机安装

面向运维：把 ockam-server 装到**数据提供方自己的 Linux 主机**上（CentOS / RHEL / Rocky / Ubuntu / Debian / openEuler），systemd 守护，外部只暴露 14000/tcp。

应用开发者文档见 [SDK.md](SDK.md)（与 Mode A 共用 SDK API）。

## 1. 系统要求

| 项 | 要求 |
|----|------|
| 操作系统 | CentOS 7+ / RHEL 7+ / Rocky 8+ / Ubuntu 20.04+ / Debian 11+ / openEuler 22+ |
| 架构 | x86_64 / aarch64 |
| Python | 3.9+（脚本会按发行版尝试装 3.11，没有就用系统 3.9） |
| systemd | 219+（基本上所有现代 Linux 都满足） |
| 端口 | 14000/tcp 对外，8080/tcp 仅 lo |
| 权限 | root 安装 |

## 2. 在线安装（最常见）

```bash
# 在数据提供方主机上
sudo ./install.sh \
  --admin-identifier "I_your_admin_xxx,I_other_admin_yyy"
```

参数说明：

| 参数 | 必需 | 说明 |
|------|------|------|
| `--admin-identifier IDS` | 推荐 | 逗号分隔的管理员 identifier。空也能装，但需要事后用 `ockam-srv add-admin` 加 |
| `--ockam-version VER` | 否 | 默认 0.157.0 |
| `--no-firewall` | 否 | 跳过 firewalld/ufw 自动放行 |
| `--no-systemd` | 否 | 不创建/启动 systemd unit（集成现有 init 系统时用） |
| `--offline /path/to/bundle.tgz` | 否 | 离线安装，见下 |

## 3. 离线安装（隔离网环境）

### 3.1 在能联网的机器上打包

```bash
./pack-offline.sh
# Output: ockam-server-offline-<ver>.tgz   (~50MB)
```

### 3.2 拷贝到目标主机，install --offline

```bash
scp ockam-server-offline-*.tgz user@target-host:/tmp/
ssh user@target-host
sudo ./install.sh --offline /tmp/ockam-server-offline-*.tgz \
                  --admin-identifier "I_xxx"
```

`--offline` 会跳过：
- 网络拉 ockam 二进制（用包内的 musl 静态版本）
- pip 拉 controller deps（用包内的 wheels）

OS-level 包（python3, jq, curl 等）仍然要 yum/apt 装，所以目标主机要有内部 yum/apt 源；如果完全离线，预先在 base 镜像里装好这些。

## 4. 安装后

### 4.1 看状态

```bash
sudo ockam-srv status
```

输出：
```
● ockam-server.service - Ockam server node
     Loaded: loaded (/etc/systemd/system/ockam-server.service)
     Active: active (running) since ...
● ockam-controller.service - Ockam controller
     Loaded: loaded (/etc/systemd/system/ockam-controller.service)
     Active: active (running) since ...

--- /healthz ---
{"status":"ok","ockam_node":"running","outlets_total":1,"outlets_ok":1,"version":"0.1.0"}
--- ports ---
LISTEN  0  4096    0.0.0.0:14000        0.0.0.0:*
LISTEN  0  4096  127.0.0.1:8080         0.0.0.0:*
```

### 4.2 拿 provider identifier 给 SDK

```bash
sudo ockam-srv show-admin
# 输出形如 I3a6cf971d6659a23d72204a36577cc489286e01426d98bdb6defdd4ce06672d
```

把这个值给开发者，他们在 SDK 中 pin（`ServerConfig.expected_identifier`）以抗 MITM。

### 4.3 加新管理员（可对配置面操作）

```bash
sudo ockam-srv add-admin I_new_admin_xxx
# 自动 daemon-reload + restart controller
```

### 4.4 看日志

```bash
journalctl -u ockam-server -f
journalctl -u ockam-controller -f
# 或文件
tail -f /var/log/ockam/node.log
tail -f /var/log/ockam/controller.log
```

## 5. 文件布局

```
/usr/local/bin/ockam              ← ockam CLI 二进制
/usr/local/bin/ockam-srv          ← 管理脚本
/opt/venv/                        ← Python venv（含 ockam-controller）
/etc/systemd/system/
  ├── ockam-server.service
  └── ockam-controller.service
/etc/ockam-server/server.yaml.example   ← 参考配置
/var/lib/ockam-server/            ← provider identity vault（不要丢）
  └── admin/identifier
/var/lib/ockam-controller/state.yaml    ← outlet + 允许列表（不要丢）
/var/log/ockam/                   ← 日志
```

**生产备份**：`/var/lib/ockam-server/`、`/var/lib/ockam-controller/` 必须定期备份；丢了 provider identity 重建后所有客户端 SDK 拒连。

## 6. 防火墙

`install.sh` 自动检测 firewalld / ufw / iptables 并放行 14000/tcp。如果你的环境用别的防火墙：

```bash
# nftables 例
sudo nft add rule inet filter input tcp dport 14000 accept
```

## 7. 常见故障

| 现象 | 排查 |
|------|------|
| `[install] tcp/14000 already in use` | 别的服务占了 14000，改之前确认 |
| `python3 not found` | 系统太老（< CentOS 7）。手工装 python3.9+ |
| 装完 `systemctl status` 显示 active 但 `/healthz` 不响应 | 看 `/var/log/ockam/controller.err`；最常见是 ockam node 启动慢（等 30s） |
| 远端连不上 14000 | 防火墙没放行或 NAT 问题；从主机本身 `nc -z 127.0.0.1 14000` 应当通；如果通则是网络设备问题 |
| 想看 controller 状态但不在主机上 | 通过 SDK 走 Ockam tunnel，curl 不能直接到 |

## 8. 卸载

```bash
sudo ockam-srv uninstall
# 移除 systemd unit + 二进制 + venv
# 数据保留：/var/lib/ockam-{server,controller}, /var/log/ockam

# 想清空数据：
sudo rm -rf /var/lib/ockam-server /var/lib/ockam-controller /var/log/ockam
```

## 9. 升级

```bash
sudo ockam-srv uninstall
sudo ./install.sh --ockam-version <new>
# state 保留，重启时 reconcile
```

## 10. 端到端验证

`./verify.sh` 在 ubuntu / rockylinux / openeuler 三个 Docker 容器里跑全套安装流程：

```
T1: pre-stage ockam binary (skip download — proxy may block)
T2: run install.sh --no-systemd --no-firewall
T3: ockam --version
T4: check admin identifier file
T5: start ockam node + controller in foreground
T6: wait for /healthz on 127.0.0.1:8080
T7: verify port 14000 listening
T8: ockam-srv status

PASS  install.sh works on: ubuntu:22.04 rockylinux:9 openeuler/openeuler:22.03
```

只想测 ubuntu：`DISTROS="ubuntu:22.04" ./verify.sh`

## 11. 设计要点

- **唯一对外端口 14000**：Noise XX 加密；控制面跟数据面共用此端口，分别走不同的 Ockam outlet
- **controller 只 bind 127.0.0.1:8080**：从外部物理上不可达，绕过任何鉴权 bug 都到不了
- **systemd unit 分两个**：`ockam-controller.service` `Requires=ockam-server.service`，先后启动
- **跨发行版**：脚本检测 `/etc/os-release` 自适应 dnf/yum/apt-get；ockam 用 musl 静态二进制免依赖

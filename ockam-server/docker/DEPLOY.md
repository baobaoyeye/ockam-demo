# DEPLOY.md — Mode A 服务端 Docker 镜像

面向运维：在你**自己**的基础设施里跑一个 ockam-server 容器，作为数据提供方真实服务的"加密门面"。

应用开发者文档见 [SDK.md](SDK.md)。

## 1. 这是什么

一个自包含的 Docker 镜像（基于 `debian-slim`）：
- 内置 ockam 二进制（来自官方 `ghcr.io/build-trust/ockam`）
- 内置 Python 3 + ockam-controller 包
- 用 supervisord 同时跑 ockam node 和 controller HTTP API
- 唯一对外端口：**14000/tcp**

## 2. 部署前提

- 容器**所在机器**能 routable 到数据提供方真实 TCP 服务（比如 MySQL）
- 防火墙放行 14000/tcp（如果有客户端不在同 host）
- Docker 25+ 或兼容运行时

## 3. 5 分钟部署

```bash
cd ockam-server/docker
docker compose -f docker-compose.example.yml up -d
docker compose -f docker-compose.example.yml ps   # 看 health 列要 healthy
```

第一次启动后，把 provider identifier 拷出来，发给 SDK 用方：

```bash
docker cp ockam-server:/var/lib/ockam-server/admin/identifier provider.id
cat provider.id
# I9c4ff6cd36d9e06af1c8403ba1a5c05194a1d962054ad78a4684af2ec10ede15
```

SDK 用方需要这个值来 pin 服务端身份（防止 MITM）。

## 4. 添加管理员（控制面权限）

控制面（创建/删除 outlet）只对**列表里的管理员**开放。两种添加方式：

### 4.1 启动时预置（推荐）

```yaml
# docker-compose.yml
services:
  ockam-server:
    environment:
      ADMIN_IDENTIFIERS: "I71cd902de4aed81f...,I8a23bcf001..."  # 逗号分隔
```

### 4.2 启动后追加

```bash
# 通过 Ockam tunnel 调控制面（管理员才能做）
# 实际上 SDK 的 ProviderAdmin.add_admin() 封装了这一步
```

## 5. 添加数据 outlet（让客户端能访问 MySQL）

由 SDK 的 `ProviderAdmin.ensure_outlet()` 完成。手工 curl 等价命令（运维侧）：

```bash
# 进容器内（绕过 tunnel）执行
docker exec ockam-server curl -fsS -X POST http://127.0.0.1:8080/outlets \
  -H "Content-Type: application/json" \
  -d '{"name":"mysql","target":"10.0.0.5:3306","allow":["I_app_xxx"]}'
```

列出当前所有 outlet：

```bash
docker exec ockam-server curl -fsS http://127.0.0.1:8080/outlets | jq
```

## 6. 配置项

### 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `ADMIN_IDENTIFIERS` | `""` | 启动时 seed 的管理员 identifier 列表（逗号分隔） |
| `OCKAM_NODE_NAME` | `provider` | ockam node 的名字 |
| `OCKAM_NODE_TRANSPORT` | `0.0.0.0:14000` | 对外监听 |
| `OCKAM_CONTROLLER_TRUST_ALL` | `1` | 内部控制器跳过身份头校验 (因为 outlet 已经检查了) |

### 持久化卷

| Volume | 作用 |
|--------|------|
| `/var/lib/ockam-server` | provider 身份（vault）+ identifier 文件 |
| `/var/lib/ockam-controller` | state.yaml（outlet 列表 + 允许列表 + 审计） |
| `/var/log/ockam` | supervisord / ockam-node / controller 日志 |

**重要**：丢失 `/var/lib/ockam-server` 后 provider 身份变了，所有已部署的 SDK 客户端会因为 identifier 不匹配而拒绝连接，必须重新分发 identifier。

## 7. 健康检查 / 状态

容器自带 healthcheck：

```bash
docker ps | grep ockam-server   # STATUS 列显示 healthy
```

详细：

```bash
docker exec ockam-server supervisorctl status
docker exec ockam-server curl -fsS http://127.0.0.1:8080/healthz | jq
docker exec ockam-server curl -fsS http://127.0.0.1:8080/info | jq
```

## 8. 日志

```bash
# 容器整体
docker logs -f ockam-server

# 内部各组件
docker exec ockam-server tail -f /var/log/ockam/node.log
docker exec ockam-server tail -f /var/log/ockam/controller.log
docker exec ockam-server tail -f /var/log/ockam/supervisord.log
```

## 9. 常见故障

| 现象 | 排查 |
|------|------|
| 容器一直在 `health: starting` | 看 `docker logs`：bootstrap 阶段失败一般是磁盘/卷权限问题 |
| 客户端连 14000 立刻被拒 | 容器没起来；`docker ps` 看 STATUS |
| 客户端连上 14000 但握手超时 | provider identity 还没生成完，等 30s |
| 客户端 secure-channel 成功但 outlet 拒 | 客户端 identifier 没在 outlet 的 allow 列表，看 `/outlets` 输出 |
| 改了 state.yaml 但没生效 | 容器重启即可 reconcile；或 `docker exec ockam-server supervisorctl restart ockam-controller` |
| 端口冲突 14000 已被占用 | 改 compose 的 `ports: "OTHER:14000"`，告诉 SDK 用 `OTHER` 端口 |

## 10. 升级

```bash
# 拉新镜像
docker pull <registry>/ockam-demo-server:latest
# 平滑替换（state 持久化在 volume，重启不丢）
docker compose -f docker-compose.example.yml up -d
```

## 11. 卸载

```bash
docker compose -f docker-compose.example.yml down
# 想清干净身份和状态：
docker volume rm ockam-server-modeA_ockam-server-state \
                 ockam-server-modeA_ockam-controller-state \
                 ockam-server-modeA_ockam-logs
```

## 12. 端到端验证

`./verify.sh` 跑 10 个测试，最后一行 `PASS` 或 `FAIL`：

```
T1: docker build ockam-demo-server image
T2: generate admin identity (ockam identity create) for the test
T3: start ockam-server container with ADMIN_IDENTIFIERS baked in
T4: wait for healthcheck → healthy
T5: only 14000/tcp exposed externally
T6: bootstrap admin identifier file exists in container
T7: controller alive on 127.0.0.1:8080 inside container
T8: 127.0.0.1:8080 NOT reachable from outside the container
T9: open Ockam tunnel from a separate container, drive controller API
T10: server side now lists controller + mysql + redis outlets

PASS  Mode A docker image passed all 10 tests
```

T9 的关键：从一个**独立的客户端容器**，通过 14000 这个唯一端口，开 Ockam secure-channel + tcp-inlet 到 `controller` outlet，然后用 curl 访问控制面 API。这就是 SDK 实际工作的模式。

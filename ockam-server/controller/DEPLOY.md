# DEPLOY.md — ockam-controller

面向运维 / DevOps：怎么把 controller 部署起来、怎么调它、坏了怎么查。

应用开发者文档见 [SDK.md](SDK.md)。

## 1. 它是什么

一个 ~200 行的 Python FastAPI 服务，跟在 Ockam node 旁边跑。功能：

- 把 SDK 的 HTTP 请求翻译成 `ockam tcp-outlet create / delete` 等 CLI 调用
- 把状态（outlet 列表、每个 outlet 的允许 identifier 列表）持久化到 yaml
- 启动时把 yaml 状态对账（reconcile）到实际 ockam node：保证重启不丢配置

## 2. 强制约束

| 约束 | 原因 |
|------|------|
| **只 bind `127.0.0.1`** | 它没有自己的 TLS / 鉴权层，所有外部访问必须走 Ockam outlet（被 Noise XX 加密 + identity 鉴权） |
| **必须有 `OCKAM_CONTROLLER_STATE` 持久化路径** | 重启后能恢复 outlet 配置 |
| **生产环境不要打开 `OCKAM_CONTROLLER_TRUST_ALL`** | 这个开关跳过所有鉴权，只在本地测试用 |

## 3. 直接 Python 部署（最常见）

```bash
# 1. 装 Python 包
pip install /path/to/ockam_controller-*.whl
# 或开发模式
pip install -e /path/to/ockam-server/controller

# 2. 准备目录
sudo mkdir -p /var/lib/ockam-controller /var/log/ockam
sudo useradd -r -s /usr/sbin/nologin ockam
sudo chown -R ockam:ockam /var/lib/ockam-controller /var/log/ockam

# 3. 生成 admin identifier 并 seed 状态
sudo -u ockam ockam identity create default
ADMIN_ID=$(sudo -u ockam ockam identity show --output json | jq -r .identifier)
sudo -u ockam python -m ockam_controller.bootstrap \
  --state /var/lib/ockam-controller/state.yaml \
  --admin-identifiers "$ADMIN_ID"

# 4. 跑起来（前台调试）
sudo -u ockam OCKAM_CONTROLLER_STATE=/var/lib/ockam-controller/state.yaml \
  python -m ockam_controller --bind 127.0.0.1:8080
```

## 4. systemd 部署

`/etc/systemd/system/ockam-controller.service`：

```ini
[Unit]
Description=Ockam controller (control plane API)
After=ockam-server.service
Requires=ockam-server.service

[Service]
Type=simple
User=ockam
Group=ockam
Environment=OCKAM_CONTROLLER_STATE=/var/lib/ockam-controller/state.yaml
Environment=OCKAM_NODE_NAME=provider
Environment=OCKAM_NODE_TRANSPORT=0.0.0.0:14000
Environment=OCKAM_CONTROLLER_ADMIN_IDENTIFIERS=
Environment=OCKAM_BINARY=/usr/local/bin/ockam
ExecStart=/usr/bin/python3 -m ockam_controller --bind 127.0.0.1:8080
Restart=on-failure
RestartSec=3
StandardOutput=append:/var/log/ockam/controller.log
StandardError=append:/var/log/ockam/controller.log

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ockam-controller
sudo journalctl -u ockam-controller -f
```

## 5. Docker 部署（Mode A 推荐）

参考 [../docker/Dockerfile](../docker/Dockerfile)（B2 交付）。要点：
- `EXPOSE 14000` 仅
- `entrypoint.sh` 用 supervisord 同时跑 ockam node + controller
- `VOLUME /var/lib/ockam-controller`，docker-compose 里挂 named volume

## 6. 配置项 (env)

| 变量 | 默认 | 说明 |
|------|------|------|
| `OCKAM_CONTROLLER_STATE` | `/var/lib/ockam-controller/state.yaml` | yaml 状态文件路径 |
| `OCKAM_NODE_NAME` | `provider` | 要管理的 ockam node 名字 |
| `OCKAM_NODE_TRANSPORT` | `0.0.0.0:14000` | 启动时给 ockam node 的 listener 地址 |
| `OCKAM_BINARY` | `ockam` | ockam CLI 路径，PATH 找不到则降级为 mock 模式 |
| `OCKAM_CONTROLLER_MOCK` | (未设) | 设 `1` 强制 mock，不调真 ockam（仅测试用） |
| `OCKAM_CONTROLLER_TRUST_ALL` | (未设) | 设 `1` 跳过鉴权（仅本地测试用） |
| `OCKAM_CONTROLLER_BOOTSTRAP_TOKEN` | (未设) | 设非空字符串后，`Authorization: Bearer <值>` 被当 admin |
| `OCKAM_CONTROLLER_ADMIN_IDENTIFIERS` | `""` | 逗号分隔的 admin identifier 列表（`X-Ockam-Remote-Identifier` 头匹配则升 admin） |

## 7. 鉴权流程

请求到达 controller 时，按以下顺序判定身份：

1. `OCKAM_CONTROLLER_TRUST_ALL=1` ⇒ 全部当 admin（仅测试）
2. `Authorization: Bearer <OCKAM_CONTROLLER_BOOTSTRAP_TOKEN>` ⇒ admin
3. `X-Ockam-Remote-Identifier: I...`
   - 如果 identifier 在 `OCKAM_CONTROLLER_ADMIN_IDENTIFIERS` 中 ⇒ admin
   - 否则 ⇒ client（只能 GET，不能改）
4. 都不命中 ⇒ `401 Unauthorized`

写操作（POST/PATCH/DELETE）需要 admin。读操作（GET）任意 client 即可，但仍需提供身份。

> 在生产部署里，`X-Ockam-Remote-Identifier` 头必须由前面的 ockam outlet 注入。Bind 到 127.0.0.1 保证攻击者没法直接伪造头。

## 8. 健康 / 状态检查

```bash
curl -s http://127.0.0.1:8080/healthz | jq .
# {"status":"ok","ockam_node":"running","outlets_total":2,"outlets_ok":2,"version":"0.1.0"}

curl -s http://127.0.0.1:8080/info | jq .
# {"node_name":"provider","identifier":"I3a6cf...","transport":"0.0.0.0:14000","version":"0.1.0"}
```

返回中 `outlets_ok < outlets_total` 表示有 outlet 应用失败，去看 `/var/log/ockam/controller.log` 找 `error: ...` 行。

## 9. 常见故障

| 现象 | 排查方向 |
|------|---------|
| `/healthz` 显示 `ockam_node: missing` | controller 拿不到 ockam binary。检查 `OCKAM_BINARY` 路径，或 `which ockam` |
| 创建 outlet 返回 500 `outlet apply failed: ...` | 看 controller.log 里的 ockam stderr。常见：listener 端口被占、target 域名解析不到、ockam node 没起 |
| 重启后 outlet 都变 `pending` | 这是正常状态，下一次成功 reconcile 会变 `ready`。看 controller 启动日志的 `[reconcile] ...` 行 |
| `401 Unauthorized` | 缺 identifier 头或 token。本地调试可临时 `OCKAM_CONTROLLER_TRUST_ALL=1` |
| state.yaml 损坏 / 卡死 | 同名 `.lock` 文件存在但锁失效，删掉 `.lock` 文件再重启 |

## 10. 卸载

```bash
sudo systemctl disable --now ockam-controller
sudo rm /etc/systemd/system/ockam-controller.service
sudo systemctl daemon-reload
sudo pip uninstall -y ockam-controller
sudo rm -rf /var/lib/ockam-controller
# /var/log/ockam 视情况保留作为审计
```

## 11. 端到端验证脚本

`./verify.sh`（在本目录下）跑 9 个端到端测试，最后一行打印 `PASS` 或 `FAIL <reason>`。验收输出片段：

```
==> T1: start controller and hit /healthz
    {"status":"ok","ockam_node":"running","outlets_total":0,"outlets_ok":0,"version":"0.1.0"}
==> T2: GET /info shows mock identifier
    {"node_name":"provider","identifier":"Imock0000...","transport":"0.0.0.0:14000",...}
==> T3: POST /outlets — create mysql outlet
    {"name":"mysql","target":"10.0.0.5:3306","allow":[...],"state":"ready"}
==> T4: PATCH /outlets/mysql — change target + add allowed identifier
==> T5: POST /clients then DELETE removes from outlet allow
==> T6: GET /audit shows recent events
==> T7: stop controller, restart, state survives
==> T8: DELETE /outlets/mysql — outlet gone
==> T9: with TRUST_ALL off and no header → 401

PASS  controller passed all 9 tests
```

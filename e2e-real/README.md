# e2e-real — 端到端验证编排

每批的 verify.sh 都是独立可运行的 — 这里两个脚本只是把它们按部署形态串起来。

## Mode A — 我们自己的容器跑 ockam-server

```bash
./verify-modeA.sh
```

按顺序跑：
1. `phase4/verify.sh` —— 现有 Phase 1/2 demo 不回归（端口 14000 替换后）
2. `ockam-server/controller/verify.sh` —— controller 单元
3. `ockam-server/docker/verify.sh` —— Mode A 镜像，single-port + 真实 Ockam tunnel
4. `client-side/sdk-python/verify.sh` —— Python SDK + pymysql 走 tunnel
5. `client-side/sdk-java/verify.sh` —— Java SDK + JDBC 走 tunnel

每一步都已经在自己的 verify 里做了密文抓包对比，所以本脚本只看 PASS/FAIL。

## Mode B — install.sh 装到目标主机

```bash
./verify-modeB.sh
```

跑 `ockam-server/install/verify.sh` 的多发行版矩阵（ubuntu + rocky 默认；可选 openeuler）。

## 全套 E2E（两种 mode 都跑）

```bash
./verify-modeA.sh && ./verify-modeB.sh
```

两个都退码 0 = 整个产品线通过。

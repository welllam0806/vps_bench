# vps_bench.sh — 国外 VPS 一键性能检测脚本 (Debian 12)

对国外 VPS 做**去程延迟 + 去程路由 + 上传/下载带宽**的一键检测，输出清晰汇总。

## 功能

1. **ping** — 对目标 IP 检测 20 次，取最低/平均/最高
2. **去程路由检测** — 自动安装并使用 [nexttrace](https://nxtrace.github.io/NextTrace/) 追踪去程路由
3. **iperf3 下载带宽测试** — 下载（国外VPS→本地）单线程/多线程各测 3 次，取最低/最高/平均

## 前置要求

- 系统：**Debian 12**（其他 Debian/Ubuntu 亦可）
- 权限：**root**（nexttrace 需要 raw socket 权限）
- 国外 VPS 上已运行 `iperf3 -s` 并开放 **5201** 端口

## 安装 & 运行

```bash
# 一键拉取并运行
bash <(curl -fsSL https://raw.githubusercontent.com/welllam0806/vps_bench/main/vps_bench.sh)
```

或手动下载运行：

```bash
curl -fsSL -o vps_bench.sh https://raw.githubusercontent.com/welllam0806/vps_bench/main/vps_bench.sh
sudo bash vps_bench.sh
```

## 交互流程

```
请输入国外 VPS 的 IP 地址: <输入>
多线程并发数 [默认 8]: <回车或输入>
→ ping 20 次
→ nexttrace 去程路由
→ iperf3 下载 单/多线程 各 3 次
→ 输出汇总
```

## 输出示例

```
============================================================
                测试结果汇总
============================================================
目标 IP        : 1.2.3.4
去程路由        : 见上方 nexttrace 输出
------------------------------------------------------------
ping (最低/平均/最高)      : 149.2ms / 150.2ms / 153.2ms
------------------------------------------------------------
下载单线程 (最低/最高/平均): 50.3 / 52.1 / 53.0 Mbits/sec
下载多线程 (最低/最高/平均): 251.0 / 254.6 / 261.0 Mbits/sec
============================================================
```

## 方向说明

| 项目 | 含义 | 对应命令 |
|------|------|---------|
| 下载 | 国外 VPS → 本地（回程） | `iperf3 -c IP -R`（反模式） |

## 参数

脚本顶部可修改：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PORT` | 5201 | iperf3 服务端口 |
| `PING_COUNT` | 20 | ping 次数 |
| `IPERF_TIME` | 5 | 每次 iperf3 测试时长（秒） |
| `RUN_COUNT` | 3 | 每个组合的测试次数 |
| `MULTI_PARALLEL` | 8 | 多线程并发数（可运行时覆盖） |

## License

MIT

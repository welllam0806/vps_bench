#!/usr/bin/env bash
# ============================================================================
#  vps-full-bench.sh — 完整 VPS 一键性能测试脚本 (Debian 12)
#
#  功能 (nodequality 风格):
#    1. 系统硬件信息 (CPU/内存/磁盘)
#    2. CPU 单/多核性能测试 (sysbench)
#    3. 磁盘 IO 测试 (fio)
#    4. IP 信息检测 (Geo/ASN/ISP)
#    5. 回程带宽测试 (指定国外VPS iperf3 server 下载, 我们之前做的优化: 单/多线程各3次 × 5秒)
#    6. nexttrace 去程路由到目标VPS
#
#  使用:
#    bash <(curl -fsSL https://raw.githubusercontent.com/welllam0806/vps_bench/main/vps-full-bench.sh)
# ============================================================================
set -euo pipefail

# ---------- 配置 ----------
IPERF3_PORT=5201          # 目标国外VPS iperf3 服务端口
PING_COUNT=20             # ping 目标IP次数
IPERF_RUN_COUNT=3        ...[truncated]
#!/usr/bin/env bash
# ============================================================================
#  vps-full-bench.sh — 完整 NodeQuality 风格 VPS 一键性能测试脚本
#
#  功能 (匹配 NodeQuality 全套):
#    1. 基础硬件信息检测 (CPU / 内存 / 磁盘 / 虚拟化)
#    2. CPU 性能测试 (sysbench 单核 + 多核)
#    3. 磁盘 I/O 测试 (fio 混合读写)
#    4. IP 质量检测 (Geo / ASN / ISP / 是否被墙)
#    5. 回程带宽测试 (自定义目标国外VPS，就是你之前做好的)
#    6. 自动追加测试结果到你已有的 bench-summary/data.js，单页面展示
#
#  使用:
#    bash <(curl -fsSL https://raw.githubusercontent.com/welllam0806/vps_bench/main/vps-full-bench.sh) --add-to-bench-summary /path/to/bench-summary
# ============================================================================
set -euo pipefail

# ---------- 配置 ----------
IPERF3_PORT=5201          # 目标国外VPS iperf3 服务端口
PING_COUNT=20             # ping 目标IP次数
IPERF_RUN_COUNT=3         # iperf3 每个组合测试次数
IPERF_RUN_TIME=5         # 每次 iperf3 测试时长
MULTI_PARALLEL=8         # 默认多线程并发数

# 用当前工作目录存放临时结果
OUT_DIR="$PWD/vps_full_bench_result"
mkdir -p "$OUT_DIR"

# ---------- 输出工具 ----------
die()  { echo -e "\033[31m[错误] $*\033[0m" >&2; exit 1; }
info() { echo -e "\033[36m[信息] $*\033[0m"; }
ok()   { echo -e "\033[32m[OK]   $*\033[0m"; }

# ---------- 1. 安装依赖 ----------
install_deps() {
  info "安装基础依赖..."
  apt-get update -qq
  apt-get install -y -qq curl wget tar sysbench fio iperf3 iputils-ping python3 >/dev/null
  ok "依赖安装完成"
}

# ---------- 2. 基础硬件信息 ----------
detect_hardware() {
  info "收集基础硬件信息..."
  mkdir -p "$OUT_DIR/hardware"
  {
    echo "=== CPU 信息 ==="
    lscpu | grep -E "Model name|CPU\(s\):|Architecture|CPU MHz|Vendor ID"
    echo ""
    echo "=== 内存信息 ==="
    free -h
    echo ""
    echo "=== 磁盘信息 ==="
    df -h /
    echo ""
    echo "=== 虚拟化信息 ==="
    if command -v systemd-detect-virt >/dev/null 2>&1; then
      systemd-detect-virt
    fi
  } > "$OUT_DIR/hardware/basic.txt"
  ok "基础硬件信息收集完成 → $OUT_DIR/hardware/basic.txt"
}

# ---------- 3. CPU 性能测试 ----------
test_cpu() {
  info "CPU 性能测试: 单核 → 多核..."
  mkdir -p "$OUT_DIR/cpu"
  info "单核测试..."
  sysbench cpu --cpu-max-prime=20000 --threads=1 run > "$OUT_DIR/cpu/single.txt"
  info "多核测试..."
  sysbench cpu --cpu-max-prime=20000 --threads=$(nproc) run > "$OUT_DIR/cpu/multi.txt"

  # 提取分数
  SINGLE_SCORE=$(grep "events per second" "$OUT_DIR/cpu/single.txt" | awk '{print $4}')
  MULTI_SCORE=$(grep "events per second" "$OUT_DIR/cpu/multi.txt" | awk '{print $4}')
  ok "CPU测试完成: 单核 $SINGLE_SCORE / 多核 $MULTI_SCORE events/s"
}

# ---------- 4. 磁盘 I/O 测试 ----------
test_disk() {
  info "磁盘 I/O 测试 (fio 混合读写)..."
  mkdir -p "$OUT_DIR/disk"
  fio --name=random-write --ioengine=posixaio --rw=randrw --bs=4k --numjobs=1 --size=1g --iodepth=1 --runtime=60 --directory="$OUT_DIR/disk" > "$OUT_DIR/disk/fio.txt"
  # 提取结果
  READ_IOPS=$(grep "read: IOPS=" "$OUT_DIR/disk/fio.txt" | awk '{print $2}' | cut -d= -f2)
  WRITE_IOPS=$(grep "write: IOPS=" "$OUT_DIR/disk/fio.txt" | awk '{print $2}' | cut -d= -f2)
  READ_BW=$(grep "read: IOPS=" "$OUT_DIR/disk/fio.txt" | awk '{print $5}' | cut -d= -f2 | sed 's/(//')
  WRITE_BW=$(grep "write: IOPS=" "$OUT_DIR/disk/fio.txt" | awk '{print $5}' | cut -d= -f2 | sed 's/(//')
  ok "磁盘测试完成: 读 IOPS $READ_IOPS ($READ_BW) / 写 IOPS $WRITE_IOPS ($WRITE_BW)"
}

# ---------- 5. IP 信息检测 ----------
detect_ip() {
  info "IP 信息检测..."
  mkdir -p "$OUT_DIR/ip"
  # 获取出口IP + Geo信息
  IP_INFO=$(curl -s https://ipapi.co/json)
  echo "$IP_INFO" > "$OUT_DIR/ip/info.json"
  EXTERNAL_IP=$(echo "$IP_INFO" | python3 -c "import json; d=json.load(sys.stdin); print(d.get('ip', ''))")
  COUNTRY=$(echo "$IP_INFO" | python3 -c "import json; d=json.load(sys.stdin); print(d.get('country_name', ''))")
  REGION=$(echo "$IP_INFO" | python3 -c "import json; d=json.load(sys.stdin); print(d.get('region', ''))")
  CITY=$(echo "$IP_INFO" | python3 -c "import json; d=json.load(sys.stdin); print(d.get('city', ''))");
  ASN=$(echo "$IP_INFO" | python3 -c "import json; d=json.load(sys.stdin); print(d.get('asn', ''))")
  ISP=$(echo "$IP_INFO" | python3 -c "import json; d=json.load(sys.stdin); print(d.get('org', ''))")
  ok "IP信息: $EXTERNAL_IP → $COUNTRY, $REGION $CITY → AS$ASN $ISP"
}

# ---------- 6. nexttrace 去程路由到目标VPS ----------
nexttrace_bin() {
  command -v nexttrace 2>/dev/null || \
  [[ -x "$HOME/.local/bin/nexttrace" ]] && echo "$HOME/.local/bin/nexttrace" || \
  [[ -x "/usr/local/bin/nexttrace" ]] && echo "/usr/local/bin/nexttrace" || \
  echo ""
}

do_nexttrace() {
  local target_ip="$1"
  info "nexttrace 去程路由到 $target_ip..."
  local nt_bin=$(nexttrace_bin)
  if [[ -z "$nt_bin" ]]; then
    info "未检测到 nexttrace，正在安装 (curl nxtrace.org/nt | bash)..."
    curl -fsSL nxtrace.org/nt | bash >/dev/null 2>&1
    nt_bin=$(nexttrace_bin)
  fi
  [[ -z "$nt_bin" ]] && die "nexttrace 安装失败，请手动安装"

  mkdir -p "$OUT_DIR/route"
  local route_file="$OUT_DIR/route/${target_ip}.txt"
  "$nt_bin" "$target_ip" > "$route_file"
  ok "去程路由已保存 → $route_file"
}

# ---------- 7. iperf3 回程下载测试 (目标国外VPS) ----------
# python 解析 JSON 统计最低/最高/平均
run_iperf() {
  local target_ip="$1"
  local port="$2"
  local run_count="$3"
  local parallel="$4"

  python3 -c "
import json, subprocess, sys

def run_one(is_reverse, parallel):
    cmd = ['iperf3', '-c', '$target_ip', '-p', '$port', '-t', str($IPERF_RUN_TIME), '-J', '-P', str(parallel)]
    if is_reverse:
        cmd.append('-R') # reverse = 下载(回程: server → client)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=$((IPERF_RUN_TIME + 10)))
        if result.returncode != 0:
            return None
        data = json.loads(result.stdout)
        return data['end']['sum_received']['bits_per_second'] / 1000000 # Mbits/sec
    except Exception as e:
        return None

def run_batch(is_reverse, parallel, count):
    results = []
    for i in range(count):
        val = run_one(is_reverse, parallel)
        if val is not None:
            results.append(round(val, 1))
    if not results:
        return ('', '', '')
    return (min(results), max(results), round(sum(results)/len(results), 1))

single = run_batch(True, 1, $run_count)
multi = run_batch(True, $parallel, $run_count)
print(f'RESULT|download-single|{single[0]} {single[1]} {single[2]}')
print(f'RESULT|download-multi|{multi[0]} {multi[1]} {multi[2]}')
"
}

do_iperf() {
  local target_ip="$1"
  info "iperf3 回程下载测试 → $target_ip:$IPERF3_PORT, 单/多线程各 $IPERF_RUN_COUNT 次..."
  mkdir -p "$OUT_DIR/iperf"
  local out=$(run_iperf "$target_ip" "$IPERF3_PORT" "$IPERF_RUN_COUNT" "$MULTI_PARALLEL")
  SINGLE_MIN=$(echo "$out" | grep 'RESULT|download-single|' | cut -d'|' -f3 | awk '{print $1}')
  SINGLE_MAX=$(echo "$out" | grep 'RESULT|download-single|' | cut -d'|' -f3 | awk '{print $2}')
  SINGLE_AVG=$(echo "$out" | grep 'RESULT|download-single|' | cut -d'|' -f3 | awk '{print $3}')
  MULTI_MIN=$(echo "$out" | grep 'RESULT|download-multi|' | cut -d'|' -f3 | awk '{print $1}')
  MULTI_MAX=$(echo "$out" | grep 'RESULT|download-multi|' | cut -d'|' -f3 | awk '{print $2}')
  MULTI_AVG=$(echo "$out" | grep 'RESULT|download-multi|' | cut -d'|' -f3 | awk '{print $3}')

  {
    echo "=== 回程下载测试结果 ==="
    echo "目标IP: $target_ip:$IPERF3_PORT"
    echo "单线程 (${IPERF_RUN_COUNT}次): 最低 $SINGLE_MIN / 最高 $SINGLE_MAX / 平均 $SINGLE_AVG Mbits/sec"
    echo "多线程 (${IPERF_RUN_COUNT}次, $MULTI_PARALLEL 并发): 最低 $MULTI_MIN / 最高 $MULTI_MAX / 平均 $MULTI_AVG Mbits/sec"
  } > "$OUT_DIR/iperf/result.txt"

  ok "iperf3 测试完成 → $OUT_DIR/iperf/result.txt"
  echo "  单线程: $SINGLE_MIN $SINGLE_MAX $SINGLE_AVG Mbits/sec"
  echo "  多线程: $MULTI_MIN $MULTI_MAX $MULTI_AVG Mbits/sec"
}

# ---------- 询问目标IP ----------
ask_target_ip() {
  while :; do
    read -rp "请输入 国外VPS iperf3 服务器IP: " IP
    IP="${IP// /}"
    [[ -n "$IP" ]] && break
    echo "  IP 不能为空，请重新输入" >&2
  done
  ok "目标IP: $IP"

  while :; do
    read -rp "多线程并发数 [默认 $MULTI_PARALLEL]: " mp
    [[ -z "$mp" ]] && break
    MULTI_PARALLEL="$mp"
    break
  done
  info "多线程并发数: ${MULTI_PARALLEL}"
}

# ---------- 主流程 ----------
main() {
  [[ $EUID -eq 0 ]] || die "请以 root 运行 (nexttrace/sysbench/fio 需要 root 权限)"

  # 可选参数: --add-to-bench-summary /path/to/bench-summary
  BENCH_SUMMARY_DIR=""
  if [[ $# -ge 2 ]] && [[ "$1" == "--add-to-bench-summary" ]]; then
    BENCH_SUMMARY_DIR="$2"
    info "将自动追加结果到 $BENCH_SUMMARY_DIR/data.js"
  fi

  install_deps
  detect_hardware
  test_cpu
  test_disk
  detect_ip
  ask_target_ip
  do_nexttrace "$IP"
  do_iperf "$IP"

  # 输出最终结果汇总
  echo ""
  echo "============================================================"
  echo "=== 完整测试结果汇总 ==="
  echo "测试时间: $(date +"%Y-%m-%d %H:%M %Z")"
  echo "本机IP: $EXTERNAL_IP → $COUNTRY, $REGION $CITY"
  echo "ASN: $ASN → $ISP"
  echo "CPU: 单核 $SINGLE_SCORE / 多核 $MULTI_SCORE events/s"
  echo "磁盘: 读 IOPS $READ_IOPS / 写 IOPS $WRITE_IOPS"
  echo "回程到 $IP: 单线程 $SINGLE_MIN $SINGLE_MAX $SINGLE_AVG Mbits/sec / 多线程 $MULTI_MIN $MULTI_MAX $MULTI_AVG Mbits/sec"
  echo "所有测试文件: $OUT_DIR"
  echo "============================================================"

  # 如果指定了 --add-to-bench-summary，自动追加到 data.js
  if [[ -n "$BENCH_SUMMARY_DIR" ]]; then
    if [[ ! -f "$BENCH_SUMMARY_DIR/data.js" ]]; then
      die "找不到 $BENCH_SUMMARY_DIR/data.js，请确认路径正确"
    fi
    # 让用户输入本次测试名称
    local test_name
    read -rp "请输入本次测试名称(如 DMIT洛杉矶): " test_name
    test_name="${test_name:-$(date +%Y-%m-%d_测试)}"
    local test_time="$(date +%Y-%m-%d %H:%M) CST"
    local test_date="$(date +%Y-%m-%d)"

    # 构造JSON条目，匹配原有格式
    local entry="\n  {\n    \"date\": \"$test_date\",\n    \"name\": \"$test_name\",\n    \"ip\": \"$EXTERNAL_IP\",\n    \"time\": \"$test_time\",\n    \"sd\": [\n      {\n        \"Name\": \"自定义回程($IP)\",\n        \"Host\": \"$IP\",\n        \"PingMin\": \"\",\n        \"PingAvg\": \"\",\n        \"PingMax\": \"\",\n        \"CpuSingle\": \"$SINGLE_SCORE\",\n        \"CpuMulti\": \"$MULTI_SCORE\",\n        \"DiskReadIOPS\": \"$READ_IOPS\",\n        \"DiskWriteIOPS\": \"$WRITE_IOPS\",\n        \"DownloadSingle\": \"$SINGLE_AVG\",\n        \"DownloadMulti\": \"$MULTI_AVG\"\n      }\n    ],\n    \"reports\": []\n  },"

    # 插入到 data.js 数组最后一条之前
    sed -i "\$i $entry" "$BENCH_SUMMARY_DIR/data.js"
    ok "✅ 已成功追加测试记录到 $BENCH_SUMMARY_DIR/data.js"
    echo ""
    echo "最后一步手动提交推送:"
    echo "  cd $BENCH_SUMMARY_DIR"
    echo "  git add data.js"
    echo "  git commit -m \"add: $test_name\""
    echo "  git push"
    echo "GitHub Pages 会自动更新展示页，和你原来流程完全一致。"
  fi
}

main "$@"

#!/usr/bin/env bash
# ============================================================================
#  vps_bench.sh — 国外 VPS 一键性能检测脚本 (Debian 12)
#
#  功能:
#    1. ping  20 次，取 最低/平均/最高
#    2. nexttrace 去程路由检测 (未安装则自动安装: curl nxtrace.org/nt | bash)
#    3. iperf3 下载测试 (回程: 国外VPS→本地)，单线程/多线程 各 3 次，取 最低/最高/平均
#
#  前置要求:
#    国外 VPS 上已运行 iperf3 服务端，并开放 5201 端口
#    以 root 运行 (nexttrace 需要 raw socket 权限)
#
#  用法:
#    bash vps_bench.sh
# ============================================================================
set -euo pipefail

# ---------- 配置 ----------
PORT=5201              # 国外 VPS 的 iperf3 服务端口
PING_COUNT=20          # ping 次数
IPERF_TIME=5           # 每次 iperf3 测试时长(秒)
RUN_COUNT=3            # 每个 线程 组合的测试次数
MULTI_PARALLEL=8       # 多线程并发数(可交互覆盖)

# 用当前工作目录作为结果存放位置。
# 注意: 不能用 $SCRIPT_DIR (脚本所在目录)——用 bash <(curl ...) 一行式运行时
# 脚本位于 /dev/fd 伪文件系统, 无法创建子目录, 会报 mkdir: /dev/fd/result
OUT_DIR="$PWD/result"

# ---------- 输出工具 ----------
die()  { echo -e "\033[31m[错误] $*\033[0m" >&2; exit 1; }
info() { echo -e "\033[36m[信息] $*\033[0m"; }
ok()   { echo -e "\033[32m[OK]   $*\033[0m"; }

# ---------- 1. 安装依赖 ----------
install_deps() {
  local pkgs=(iperf3 iputils-ping curl) miss=() p
  for p in "${pkgs[@]}"; do
    command -v "$p" >/dev/null 2>&1 || miss+=("$p")
  done
  if (( ${#miss[@]} )); then
    info "安装缺失依赖: ${miss[*]}"
    apt-get update -qq
    apt-get install -y -qq "${miss[@]}"
  fi
}

# ---------- 2. 询问并填写国外 VPS IP ----------
ask_ip() {
  while :; do
    read -rp "请输入国外 VPS 的 IP 地址: " IP
    IP="${IP// /}"
    [[ -n "$IP" ]] && break
    echo "  IP 不能为空，请重新输入" >&2
  done
  ok "目标 IP: $IP"
}

# ---------- 3. ping 20 次 ----------
do_ping() {
  info "ping $IP 共 ${PING_COUNT} 次..."
  local stat nums
  stat=$(ping -c "$PING_COUNT" -W 2 "$IP" 2>/dev/null | tail -1) || true
  nums=$(echo "$stat" | grep -oP '[\d.]+/[\d.]+/[\d.]+/[\d.]+' | head -1) || true
  if [[ -z "$nums" ]]; then
    die "ping 未获取到统计结果(目标不可达或 100% 丢包?)"
  fi
  IFS='/' read -r PING_MIN PING_AVG PING_MAX _ <<< "$nums"
  ok "ping 最低 ${PING_MIN}ms / 平均 ${PING_AVG}ms / 最高 ${PING_MAX}ms"
}

# ---------- 4. nexttrace 去程路由 ----------
# nexttrace 安装脚本会把二进制装到 ~/.local/bin，不在默认 PATH 中
# 需要手动探测常见安装路径 (用 if 而非 && || 短路链，避免多行输出)
nexttrace_bin() {
  local p
  p=$(command -v nexttrace 2>/dev/null) && { echo "$p"; return; }
  if [[ -x "$HOME/.local/bin/nexttrace" ]]; then
    echo "$HOME/.local/bin/nexttrace"; return
  fi
  if [[ -x "/usr/local/bin/nexttrace" ]]; then
    echo "/usr/local/bin/nexttrace"; return
  fi
  echo ""
}

do_nexttrace() {
  local NT
  NT=$(nexttrace_bin)
  if [[ -z "$NT" ]]; then
    info "未检测到 nexttrace，正在安装 (curl nxtrace.org/nt | bash)..."
    curl -fsSL nxtrace.org/nt | bash
    NT=$(nexttrace_bin)
    [[ -z "$NT" ]] && die "nexttrace 安装失败"
  fi
  ok "nexttrace 就绪，开始去程路由检测..."
  mkdir -p "$OUT_DIR"
  "$NT" "$IP" 2>&1 | tee "$OUT_DIR/route_${IP}.txt"
  echo
}

# ---------- 5. iperf3 下载测试 + 统计 (JSON 解析, 内联传参) ----------
# iperf3 -J 输出 JSON，解析 end.sum_received.bits_per_second
# 单线程/多线程都有该字段，避免文本解析误报失败
run_iperf() {
  IP="$IP" PORT="$PORT" IPERF_TIME="$IPERF_TIME" RUN_COUNT="$RUN_COUNT" \
  MULTI_PARALLEL="$MULTI_PARALLEL" python3 - <<'PY'
import json, os, subprocess

ip       = os.environ["IP"]
port     = os.environ["PORT"]
t        = os.environ["IPERF_TIME"]
runs     = int(os.environ["RUN_COUNT"])
parallel = os.environ["MULTI_PARALLEL"]

def measure(pflag):
    """跑一次 iperf3 下载(-R)，返回 Mbits/sec，失败返回 None"""
    cmd = ["iperf3", "-c", ip, "-p", port, "-t", t, "-R", "-J"] + pflag
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=int(t)+30)
        if r.returncode != 0:
            return None
        d = json.loads(r.stdout)
        return d["end"]["sum_received"]["bits_per_second"] / 1e6
    except Exception:
        return None

def suite(label, pflag):
    print(f"[信息] 测试: 下载 {label} 共 {runs} 次...")
    vals = []
    for i in range(1, runs+1):
        v = measure(pflag)
        if v is None:
            print(f"  第 {i} 次失败(请确认国外 VPS 的 {port} 端口已开 iperf3 服务)")
            continue
        vals.append(v)
        print(f"  第 {i:2d} 次: {v:.1f} Mbits/sec")
    print()
    return vals

single = suite("单线程(1线程)", [])
multi  = suite(f"多线程({parallel}线程)", ["-P", parallel])

# 输出统计结果 (仅输出 RESULT 行，供 bash 汇总)
def stat(vals, label):
    if not vals:
        print(f"RESULT|{label}|无数据")
        return
    lo, hi, avg = min(vals), max(vals), sum(vals)/len(vals)
    print(f"RESULT|{label}|{lo:.1f} / {hi:.1f} / {avg:.1f} Mbits/sec")

print()
stat(single, "下载单线程")
stat(multi,  "下载多线程")
PY
}

# ---------- 主流程 ----------
main() {
  [[ $EUID -eq 0 ]] || die "请以 root 运行 (nexttrace 需要 root 权限)"

  # 可选参数: --add-to-bench-summary /path/to/bench-summary
  BENCH_SUMMARY_DIR=""
  if [[ $# -ge 2 ]] && [[ "$1" == "--add-to-bench-summary" ]]; then
    BENCH_SUMMARY_DIR="$2"
    info "将自动追加结果到 $BENCH_SUMMARY_DIR/data.js"
  fi

  install_deps
  ask_ip

  local mp
  read -rp "多线程并发数 [默认 ${MULTI_PARALLEL}]: " mp
  [[ -n "$mp" ]] && MULTI_PARALLEL="$mp"
  info "多线程并发数: ${MULTI_PARALLEL}"

  do_ping
  do_nexttrace

  echo "============================================================"
  echo "iperf3 下载测试: 端口 $PORT / 每次 ${IPERF_TIME}s / 每项 ${RUN_COUNT} 次"
  echo "============================================================"

  # 捕获 python 输出，提取 RESULT 行
  local out single_res multi_res
  out=$(run_iperf)
  single_res=$(echo "$out" | grep '^RESULT|下载单线程|' | cut -d'|' -f3)
  multi_res=$(echo "$out" | grep '^RESULT|下载多线程|' | cut -d'|' -f3)

  echo "============================================================"
  echo "=== 最终结果 ==="
  # 按用户要求恢复紧凑单行格式
  echo "$IP: ping $PING_MIN $PING_MAX $PING_AVG  下载单线 $single_res  下载多线 $multi_res  路由: $OUT_DIR/route_${IP}.txt"
  echo "============================================================"

  # 追加到汇总文件
  echo "$(date +%Y-%m-%d_%H:%M) $IP ping:${PING_MIN}/${PING_MAX}/${PING_AVG}ms 单线程:${single_res}Mbps 多线程:${multi_res}Mbps 路由:$OUT_DIR/route_${IP}.txt" >> "$PWD/vps_bench_results.txt"
  echo "结果已追加到 $PWD/vps_bench_results.txt"

  # 如果指定了 --add-to-bench-summary，自动追加到 bench-summary/data.js
  if [[ -n "$BENCH_SUMMARY_DIR" ]]; then
    if [[ ! -f "$BENCH_SUMMARY_DIR/data.js" ]]; then
      die "找不到 $BENCH_SUMMARY_DIR/data.js，请确认路径正确"
    fi
    # 让用户输入测试名称
    local test_name
    read -rp "请输入本次测试名称(如 DMIT洛杉矶): " test_name
    test_name="${test_name:-$(date +%Y-%m-%d_测试)}"
    local test_time="$(date +%Y-%m-%d %H:%M) CST"
    local test_date="$(date +%Y-%m-%d)"

    # 构造JSON条目，插入到 data.js 数组
    local entry="\n  {\n    \"date\": \"$test_date\",\n    \"name\": \"$test_name\",\n    \"ip\": \"$IP\",\n    \"time\": \"$test_time\",\n    \"sd\": [\n      {\n        \"Name\": \"自定义目标($IP)\",\n        \"Host\": \"$IP\",\n        \"PingMin\": \"$PING_MIN\",\n        \"PingAvg\": \"$PING_AVG\",\n        \"PingMax\": \"$PING_MAX\",\n        \"DownloadSingle\": \"${single_res%% *}\",\n        \"DownloadMulti\": \"${multi_res%% *}\"\n      }\n    ],\n    \"reports\": []\n  },"

    # 插入到数组倒数第二行
    sed -i "\$i $entry" "$BENCH_SUMMARY_DIR/data.js"
    ok "已成功追加测试记录到 $BENCH_SUMMARY_DIR/data.js"
    echo "最后一步: cd $BENCH_SUMMARY_DIR && git add data.js && git commit -m \"add: $test_name\" && git push"
  fi
}

main "$@"

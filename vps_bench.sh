#!/usr/bin/env bash
# ============================================================================
#  vps_bench.sh — 国外 VPS 一键性能检测 (Debian 12)
#
#  功能:
#    1. ping  20 次，取 最低/平均/最高
#    2. nexttrace 去程路由检测 (未安装则自动安装: curl nxtrace.org/nt | bash)
#    3. iperf3 上传/下载 单线程/多线程 各 10 次，取 最低/最高/平均
#
#  前置要求:
#    国外 VPS 上已运行 iperf3 服务端，并开放 5201 端口 (UDP/TCP 均可)
#    以 root 运行 (nexttrace 需要 raw socket 权限)
#
#  用法:
#    bash vps_bench.sh
# ============================================================================
set -euo pipefail

# ---------- 配置 ----------
PORT=5201              # 国外 VPS 的 iperf3 服务端口
PING_COUNT=20          # ping 次数
IPERF_TIME=10          # 每次 iperf3 测试时长(秒)
RUN_COUNT=10           # 每个 方向×线程 组合的测试次数
MULTI_PARALLEL=8       # 多线程并发数(可交互覆盖)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/result"

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
do_nexttrace() {
  if ! command -v nexttrace >/dev/null 2>&1; then
    info "未检测到 nexttrace，正在安装 (curl nxtrace.org/nt | bash)..."
    curl -fsSL nxtrace.org/nt | bash
    command -v nexttrace >/dev/null 2>&1 || die "nexttrace 安装失败"
  fi
  ok "nexttrace 就绪，开始去程路由检测..."
  mkdir -p "$OUT_DIR"
  nexttrace "$IP" 2>&1 | tee "$OUT_DIR/route_${IP}.txt"
  echo
}

# ---------- 5. iperf3 单次测试 ----------
# 方向: upload   = 本地→国外(去程/出战), iperf3 默认方向
#        download = 国外→本地(回程),     iperf3 -R 反模式
# 输出: 客户端侧 receiver 汇总 bitrate (两个方向都对应实际吞吐)
run_iperf_once() {
  local dir="$1" par="$2" args=() b
  [[ "$dir" == "download" ]] && args+=(-R)
  (( par > 1 )) && args+=(-P "$par")
  b=$(iperf3 -c "$IP" -p "$PORT" -t "$IPERF_TIME" -f m "${args[@]}" 2>/dev/null \
       | grep "SUM" | tail -1 | grep -oP '[\d.]+(?= Mbits/sec)' | head -1) || true
  echo "$b"
}

# ---------- 6. 一组测试 (多次取 最低/最高/平均) ----------
# 通过 nameref 把结果写回全局数组 $4
run_suite() {
  local dir="$1" par="$2" label="$3"
  local -n store="$4"
  local i v
  info "测试: ${label} (${par} 线程) 共 ${RUN_COUNT} 次..."
  for (( i = 1; i <= RUN_COUNT; i++ )); do
    v=$(run_iperf_once "$dir" "$par")
    if [[ -z "$v" ]]; then
      echo "  第 ${i} 次失败(请确认国外 VPS 的 ${PORT} 端口已开 iperf3 服务)" >&2
      continue
    fi
    store+=("$v")
    printf "  第 %2d 次: %s Mbits/sec\n" "$i" "$v"
  done
  echo
}

# ---------- 统计: 最低/最高/平均 ----------
calc() {
  local -a a=("$@") sorted
  local min max avg
  local n=${#a[@]}
  sorted=($(printf '%s\n' "${a[@]}" | sort -n))
  min=${sorted[0]}
  max=${sorted[-1]}
  avg=$(printf '%s\n' "${a[@]}" | awk '{s+=$1; n++} END {printf "%.2f", s/n}')
  echo "$min $max $avg"
}

# ---------- 结果汇总 ----------
print_summary() {
  local -a u1 um d1 dm
  read -r -a u1 <<< "$1"
  read -r -a um <<< "$2"
  read -r -a d1 <<< "$3"
  read -r -a dm <<< "$4"

  echo "============================================================"
  echo "                测试结果汇总"
  echo "============================================================"
  echo "目标 IP        : $IP"
  echo "去程路由        : 见上方 nexttrace 输出, 已存档 $OUT_DIR/route_${IP}.txt"
  echo "------------------------------------------------------------"
  echo "ping (最低/平均/最高)      : ${PING_MIN}ms / ${PING_AVG}ms / ${PING_MAX}ms"
  echo "------------------------------------------------------------"
  echo "上传单线程 (最低/最高/平均): ${u1[0]} / ${u1[1]} / ${u1[2]} Mbits/sec"
  echo "上传多线程 (最低/最高/平均): ${um[0]} / ${um[1]} / ${um[2]} Mbits/sec"
  echo "下载单线程 (最低/最高/平均): ${d1[0]} / ${d1[1]} / ${d1[2]} Mbits/sec"
  echo "下载多线程 (最低/最高/平均): ${dm[0]} / ${dm[1]} / ${dm[2]} Mbits/sec"
  echo "============================================================"
}

# ---------- 主流程 ----------
main() {
  [[ $EUID -eq 0 ]] || die "请以 root 运行 (nexttrace 需要 root 权限)"

  install_deps
  ask_ip

  local mp
  read -rp "多线程并发数 [默认 ${MULTI_PARALLEL}]: " mp
  [[ -n "$mp" ]] && MULTI_PARALLEL="$mp"
  info "多线程并发数: ${MULTI_PARALLEL}"

  do_ping
  do_nexttrace

  echo "============================================================"
  echo "iperf3 测试: 端口 $PORT / 每次 ${IPERF_TIME}s / 每项 ${RUN_COUNT} 次"
  echo "============================================================"

  declare -a U1 UM D1 DM
  run_suite upload 1        "上传 单线程" U1
  run_suite upload "$MULTI_PARALLEL" "上传 多线程" UM
  run_suite download 1      "下载 单线程" D1
  run_suite download "$MULTI_PARALLEL" "下载 多线程" DM

  (( ${#U1[@]} && ${#UM[@]} && ${#D1[@]} && ${#DM[@]} )) || die "存在测试组全部失败，无法汇总"

  print_summary "$(calc "${U1[@]}")" "$(calc "${UM[@]}")" \
                "$(calc "${D1[@]}")" "$(calc "${DM[@]}")"
}

main "$@"

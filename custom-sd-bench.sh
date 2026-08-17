#!/usr/bin/env bash
# ============================================================================
#  custom-sd-bench.sh — 自定义目标回程测试脚本（给已经开了 iperf3 -s 的国外VPS）
#
#  功能：
#    1.  ping 统计 → 最低/最高/平均 ms
#    2.  nexttrace 去程路由 → 保存到文件
#    3.  iperf3 回程下载 → 单线程 × 3次 + 多线程 × 8并发 × 3次
#    4.  统计输出 最低/最高/平均 Mbps，完全符合你的需求
#
#  使用：
#    bash <(curl -fsSL https://raw.githubusercontent.com/welllam0806/vps_bench/main/custom-sd-bench.sh)
# ============================================================================
set -euo pipefail

# ---------- 配置 ----------
IPERF_RUN_COUNT=3       # 每个类型跑几次
IPERF_RUN_TIME=5       # 每次测试时长（秒）
MULTI_PARALLEL=8       # 多线程并发数
OUT_DIR="./result"     # 路由结果存放目录

# ---------- 工具 ----------
die()  { echo -e "\033[31m[错误] $*\033[0m" >&2; exit 1; }
info() { echo -e "\033[36m[信息] $*\033[0m"; }
ok()   { echo -e "\033[32m[OK]   $*\033[0m"; }

# ---------- 检查依赖 ----------
check_deps() {
  local missing=()
  for dep in ping jq iperf3 bc; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing+=("$dep")
    fi
  done
  # 检查 nexttrace
  local nt_bin=$(which nexttrace 2>/dev/null || [[ -x "$HOME/.local/bin/nexttrace" ]] && echo "$HOME/.local/bin/nexttrace" || [[ -x "/usr/local/bin/nexttrace" ]] && echo "/usr/local/bin/nexttrace")
  if [[ -z "$nt_bin" ]]; then
    info "nexttrace 未安装，正在自动安装..."
    curl -fsSL nxtrace.org/nt | bash >/dev/null 2>&1
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    info "安装缺失依赖: ${missing[*]}"
    apt-get update -qq >/dev/null
    apt-get install -y -qq "${missing[@]}" >/dev/null
    ok "依赖安装完成"
  fi
}

# ---------- 询问目标 ----------
ask_target() {
  while :; do
    read -rp "请输入 目标VPS IP (已经开了 iperf3 -s): " TARGET_IP
    TARGET_IP="${TARGET_IP// /}"
    [[ -n "$TARGET_IP" ]] && break
    echo "IP不能为空，请重新输入" >&2
  done

  while :; do
    read -rp "请输入 iperf3 端口 [默认 5201]: " TARGET_PORT
    [[ -z "$TARGET_PORT" ]] && TARGET_PORT=5201 && break
    if [[ "$TARGET_PORT" =~ ^[0-9]+$ ]] && [[ "$TARGET_PORT" -ge 1 ]] && [[ "$TARGET_PORT" -le 65535 ]]; then
      break
    else
      echo "端口必须是 1-65535 的数字，请重新输入" >&2
    fi
  done

  while :; do
    read -rp "请输入测试名称(如 DMIT洛杉矶): " TEST_NAME
    [[ -n "$TEST_NAME" ]] && break
    echo "名称不能为空，请重新输入" >&2
  done

  ok "目标: $TEST_NAME → $TARGET_IP:$TARGET_PORT"
}

# ---------- ping 统计 ----------
do_ping() {
  info "ping 测试 10 包..."
  local pingout
  pingout=$(ping -c 10 -W 2 "$TARGET_IP" 2>&1 | grep "rtt min/avg/max")
  if [[ -n "$pingout" ]]; then
    PING_MIN=$(echo "$pingout" | sed -E 's/.*= ([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/.*/\1/')
    PING_AVG=$(echo "$pingout" | sed -E 's/.*= ([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/.*/\2/')
    PING_MAX=$(echo "$pingout" | sed -E 's/.*= ([0-9.]+)\/([0-9.]+)\/([0-9.]+)\/.*/\3/')
    ok "ping: 最低 $PING_MIN ms / 平均 $PING_AVG ms / 最高 $PING_MAX ms"
  else
    PING_MIN="--"
    PING_AVG="--"
    PING_MAX="--"
    info "ping 失败，结果记为 --"
  fi
}

# ---------- nexttrace 去程 ----------
do_route() {
  info "nexttrace 去程路由..."
  mkdir -p "$OUT_DIR"
  local nt_bin=$(which nexttrace 2>/dev/null || [[ -x "$HOME/.local/bin/nexttrace" ]] && echo "$HOME/.local/bin/nexttrace" || [[ -x "/usr/local/bin/nexttrace" ]] && echo "/usr/local/bin/nexttrace")
  ROUTE_FILE="$OUT_DIR/route_${TARGET_IP}.txt"
  "$nt_bin" "$TARGET_IP" > "$ROUTE_FILE" 2>&1
  ok "去程路由已保存 → $ROUTE_FILE"
}

# ---------- iperf3 回程下载测试 ----------
do_iperf() {
  info "iperf3 回程下载测试..."

  # ---------- 单线程 ----------
  info "→ 单线程 × $IPERF_RUN_COUNT 次..."
  local single_results=()
  for ((i=1; i<=IPERF_RUN_COUNT; i++)); do
    echo -n "  第 $i 次..."
    local resp=$(timeout $((IPERF_RUN_TIME + 10)) iperf3 -4 -R -J -t $IPERF_RUN_TIME -c "$TARGET_IP" -p "$TARGET_PORT" 2>&1)
    if [[ -n "$resp" && "$resp" != *"iperf3: error"* && "$resp" != *"\"error\":"* ]]; then
      local bps=$(echo "$resp" | jq -r '.end.sum_received.bits_per_second' 2>/dev/null || true)
      if [[ -n "$bps" && "$bps" != "null" ]]; then
        local mbps=$(echo "scale=1; $bps / 1000000" | bc)
        single_results+=("$mbps")
        echo " $mbps Mbps"
      else
        echo " 失败"
      fi
    else
      echo " 失败"
    fi
  done

  # ---------- 统计单线程 ----------
  if [[ ${#single_results[@]} -gt 0 ]]; then
    SINGLE_MIN=$(printf "%s\n" "${single_results[@]}" | sort -n | head -n1)
    SINGLE_MAX=$(printf "%s\n" "${single_results[@]}" | sort -n | tail -n1)
    local sum=0
    for val in "${single_results[@]}"; do
      sum=$(echo "scale=1; $sum + $val" | bc)
    done
    SINGLE_AVG=$(echo "scale=1; $sum / ${#single_results[@]}" | bc)
    ok "单线程: 最低 $SINGLE_MIN / 最高 $SINGLE_MAX / 平均 $SINGLE_AVG Mbps"
  else
    SINGLE_MIN="--"
    SINGLE_MAX="--"
    SINGLE_AVG="--"
  fi

  # ---------- 多线程 ----------
  echo ""
  info "→ 多线程 ($MULTI_PARALLEL 并发) × $IPERF_RUN_COUNT 次..."
  local multi_results=()
  for ((i=1; i<=IPERF_RUN_COUNT; i++)); do
    echo -n "  第 $i 次..."
    local resp=$(timeout $((IPERF_RUN_TIME + 15)) iperf3 -4 -R -J -t $IPERF_RUN_TIME -c "$TARGET_IP" -p "$TARGET_PORT" -P $MULTI_PARALLEL 2>&1)
    if [[ -n "$resp" && "$resp" != *"iperf3: error"* && "$resp" != *"\"error\":"* ]]; then
      local bps=$(echo "$resp" | jq -r '.end.sum_received.bits_per_second' 2>/dev/null || true)
      if [[ -n "$bps" && "$bps" != "null" ]]; then
        local mbps=$(echo "scale=1; $bps / 1000000" | bc)
        multi_results+=("$mbps")
        echo " $mbps Mbps"
      else
        echo " 失败"
      fi
    else
      echo " 失败"
    fi
  done

  # ---------- 统计多线程 ----------
  if [[ ${#multi_results[@]} -gt 0 ]]; then
    MULTI_MIN=$(printf "%s\n" "${multi_results[@]}" | sort -n | head -n1)
    MULTI_MAX=$(printf "%s\n" "${multi_results[@]}" | sort -n | tail -n1)
    local sum=0
    for val in "${multi_results[@]}"; do
      sum=$(echo "scale=1; $sum + $val" | bc)
    done
    MULTI_AVG=$(echo "scale=1; $sum / ${#multi_results[@]}" | bc)
    ok "多线程: 最低 $MULTI_MIN / 最高 $MULTI_MAX / 平均 $MULTI_AVG Mbps"
  else
    MULTI_MIN="--"
    MULTI_MAX="--"
    MULTI_AVG="--"
  fi
}

# ---------- 输出最终结果 ----------
output_result() {
  echo ""
  echo "============================================================"
  echo "=== 自定义目标回程测试结果 ==="
  echo "测试名称: $TEST_NAME"
  echo "目标: $TARGET_IP:$TARGET_PORT"
  echo "------------------------------------------------------------"
  echo "$TARGET_IP: ping $PING_MIN $PING_AVG $PING_MAX  单线程 $SINGLE_MIN $SINGLE_MAX $SINGLE_AVG  多线程 $MULTI_MIN $MULTI_MAX $MULTI_AVG  路由: $ROUTE_FILE"
  echo "============================================================"

  # 追加到汇总文件
  echo "$(date +%Y-%m-%d_%H:%M) $TEST_NAME → $TARGET_IP:$TARGET_PORT | ping: $PING_MIN/$PING_AVG/$PING_MAX | 单线: $SINGLE_MIN/$SINGLE_MAX/$SINGLE_AVG | 多线: $MULTI_MIN/$MULTI_MAX/$MULTI_AVG" >> ./custom-sd-results.txt
  echo ""
  ok "结果已追加到 ./custom-sd-results.txt"
}

# ---------- 主流程 ----------
main() {
  [[ $EUID -ne 0 ]] && die "请以 root 运行 (nexttrace 需要 root 权限)"

  check_deps
  ask_target
  do_ping
  do_route
  do_iperf
  output_result
}

main "$@"

#!/usr/bin/env bash
# ============================================================================
#  vps-nodequality-run.sh — 一键运行完整 NodeQuality 全套测试，自动追加结果到 bench-summary
#
#  依赖你已 clone 官方生态仓库到当前目录:
#    - nodequality
#    - HardwareQuality
#    - ipquality
#    - netquality
#    - bench-summary
#
#  使用:
#    bash <(curl -fsSL https://raw.githubusercontent.com/welllam0806/vps_bench/main/vps-nodequality-run.sh) --add-summary /path/to/bench-summary
# ============================================================================
set -euo pipefail

# ---------- 配置 ----------
TARGET_IP=""           # 自定义回程目标IP（国外VPS开了iperf3 -s）
IPERF_PORT=5201       # iperf3端口
BENCH_SUMMARY_DIR=""  # --add-summary 指定路径

# ---------- 工具 ----------
die()  { echo -e "\033[31m[错误] $*\033[0m" >&2; exit 1; }
info() { echo -e "\033[36m[信息] $*\033[0m"; }
ok()   { echo -e "\033[32m[OK]   $*\033[0m"; }

# ---------- 检查仓库 ----------
check_repos() {
  local missing=()
  for repo in nodequality HardwareQuality ipquality netquality bench-summary; do
    [[ ! -d "$repo" ]] && missing+=("$repo")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "缺少官方仓库: ${missing[*]}\n请先在当前目录clone:\n  git clone https://github.com/welllam0806/nodequality.git\n  git clone https://github.com/welllam0806/HardwareQuality.git\n  git clone https://github.com/welllam0806/ipquality.git\n  git clone https://github.com/welllam0806/netquality.git\n  git clone https://github.com/welllam0806/bench-summary.git"
  fi
  ok "所有官方仓库已就绪"
}

# ---------- 询问自定义回程目标 ----------
ask_target() {
  while :; do
    read -rp "请输入 自定义回程目标IP(国外VPS已开iperf3 -s): " TARGET_IP
    TARGET_IP="${TARGET_IP// /}"
    [[ -n "$TARGET_IP" ]] && break
    echo "IP不能为空，请重新输入" >&2
  done
  ok "自定义回程目标: $TARGET_IP:$IPERF_PORT"
}

# ---------- 运行全套原生测试 ----------
run_full_test() {
  info "=== 开始运行 NodeQuality 全套测试 ==="

  # 1. HardwareQuality
  info ">> 1. 硬件质量测试"
  cd HardwareQuality
  bash hardware.sh
  cd ..
  ok "<< 硬件测试完成"

  # 2. ipquality
  info ">> 2. IP质量检测"
  cd ipquality
  bash ipquality.sh
  cd ..
  ok "<< IP检测完成"

  # 3. netquality (含自定义回程目标)
  info ">> 3. 网络质量检测 + 自定义回程测试"
  cd netquality
  if [[ -n "$TARGET_IP" ]]; then
    # 注入自定义目标，用环境变量传递
    export NQ_SD_TARGET_IP="$TARGET_IP"
    export NQ_SD_TARGET_PORT="$IPERF_PORT"
  fi
  bash netquality.sh
  unset NQ_SD_TARGET_IP NQ_SD_TARGET_PORT
  cd ..
  ok "<< 网络测试完成"

  ok "=== 全套原生NodeQuality测试完成 ==="
}

# ---------- 追加结果到 bench-summary ----------
append_to_summary() {
  [[ -z "$BENCH_SUMMARY_DIR" ]] && return

  if [[ ! -f "$BENCH_SUMMARY_DIR/data.js" ]]; then
    die "找不到 $BENCH_SUMMARY_DIR/data.js"
  fi

  # 获取测试名称和时间
  local test_name
  read -rp "请输入本次测试名称(如 DMIT洛杉矶): " test_name
  test_name="${test_name:-$(date +%Y-%m-%d_测试)}"
  local test_time="$(date +%Y-%m-%d %H:%M) CST"
  local test_date="$(date +%Y-%m-%d)"

  # 获取出口IP（从 ipquality 结果提取）
  local external_ip=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' ipquality/result*.txt | head -1)
  external_ip="${external_ip:-}"

  # 构造JSON条目，完全匹配原有格式
  local entry="\n  {\n    \"date\": \"$test_date\",\n    \"name\": \"$test_name\",\n    \"ip\": \"$external_ip\",\n    \"time\": \"$test_time\",\n    \"sd\": [],\n    \"reports\": []\n  },"

  # 插入到 data.js 数组最后一条之前
  sed -i "\$i $entry" "$BENCH_SUMMARY_DIR/data.js"
  ok "✅ 已追加测试记录到 $BENCH_SUMMARY_DIR/data.js"

  echo ""
  echo "最后一步，请手动提交推送:"
  echo "  cd $BENCH_SUMMARY_DIR"
  echo "  git add data.js"
  echo "  git commit -m \"add: $test_name\""
  echo "  git push"
  echo "GitHub Pages 自动更新后，就能在你的展示页看到新结果了，完全保持原生样式。"
}

# ---------- 主流程 ----------
main() {
  [[ $EUID -ne 0 ]] && die "请以 root 运行"

  # 解析参数
  while [[ $# -ge 1 ]]; do
    case "$1" in
      --add-summary)
        BENCH_SUMMARY_DIR="$2"
        shift 2
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
  done

  check_repos
  ask_target
  run_full_test
  append_to_summary
}

main "$@"

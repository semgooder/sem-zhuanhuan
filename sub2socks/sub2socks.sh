#!/usr/bin/env bash
set -e

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sub2socks"
CONFIG_FILE="$CONFIG_DIR/config"
PID_FILE="$CONFIG_DIR/daemon.pid"
LOG_FILE="$CONFIG_DIR/daemon.log"
YQ_BIN="/usr/local/bin/yq"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

DEFAULT_SUB_URL=""
DEFAULT_INTERVAL=3600
DEFAULT_SAVE_PATH="/etc/mihomo"
DEFAULT_SAVE_FILE="config.yaml"
DEFAULT_START_PORT=30000

SUB_URL=""
INTERVAL=""
SAVE_PATH=""
SAVE_FILE=""
START_PORT=""

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
  fi
  SUB_URL="${SUB_URL:-$DEFAULT_SUB_URL}"
  INTERVAL="${INTERVAL:-$DEFAULT_INTERVAL}"
  SAVE_PATH="${SAVE_PATH:-$DEFAULT_SAVE_PATH}"
  SAVE_FILE="${SAVE_FILE:-$DEFAULT_SAVE_FILE}"
  START_PORT="${START_PORT:-$DEFAULT_START_PORT}"
}

init_config_dir() {
  mkdir -p "$CONFIG_DIR"
}

check_deps() {
  if ! command -v curl &>/dev/null; then
    echo -e "${RED}[错误] 未安装 curl${NC}"
    echo "  请执行: apt install -y curl"
    exit 1
  fi
  if [ ! -x "$YQ_BIN" ] && ! command -v yq &>/dev/null; then
    echo -e "${YELLOW}[信息] 正在安装 yq (YAML 处理工具)...${NC}"
    install_yq
  fi
}

install_yq() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *)       echo -e "${RED}不支持的架构: $arch${NC}"; return 1 ;;
  esac
  wget -qO "$YQ_BIN" "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$arch"
  chmod +x "$YQ_BIN"
  echo -e "${GREEN}yq 安装完成${NC}"
}

yq_cmd() {
  if [ -x "$YQ_BIN" ]; then
    "$YQ_BIN" "$@"
  else
    command -v yq &>/dev/null && yq "$@"
  fi
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
SUB_URL="${SUB_URL}"
INTERVAL=${INTERVAL}
SAVE_PATH="${SAVE_PATH}"
SAVE_FILE="${SAVE_FILE}"
START_PORT=${START_PORT}
EOF
  echo -e "${GREEN}配置已保存到 $CONFIG_FILE${NC}"
}

fetch_subscription() {
  local url="$1"
  local out_file="$2"

  local http_code
  http_code=$(curl -s -o "$out_file" -w "%{http_code}" \
    -A "mihomo.party/v1.9.5(clash.meta)" \
    "$url" 2>/dev/null || echo "000")

  if [ "$http_code" != "200" ]; then
    if [ -s "$out_file" ] && [ "$(wc -c < "$out_file")" -gt 100 ]; then
      return 0
    fi
    echo -e "${RED}    HTTP $http_code${NC}"
    return 1
  fi
  return 0
}

decode_if_base64() {
  local file="$1"
  if yq_cmd eval '.' "$file" &>/dev/null; then
    return 0
  fi
  local decoded
  decoded=$(base64 -d "$file" 2>/dev/null || echo "")
  if [ -n "$decoded" ]; then
    echo "$decoded" > "$file"
    if yq_cmd eval '.' "$file" &>/dev/null; then
      return 0
    fi
  fi
  return 1
}

fetch_and_generate() {
  echo -e "${CYAN}[1/4] 正在抓取订阅...${NC}"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local sub_file="$tmp_dir/sub.yaml"
  local out_file="$SAVE_PATH/$SAVE_FILE"

  if ! fetch_subscription "$SUB_URL" "$sub_file"; then
    echo -e "${RED}[错误] 订阅抓取失败${NC}"
    rm -rf "$tmp_dir"
    return 1
  fi

  echo -e "${GREEN}      已获取 $(wc -c < "$sub_file") 字节${NC}"

  if ! decode_if_base64 "$sub_file"; then
    echo -e "${RED}[错误] 订阅内容无法解析为 YAML${NC}"
    rm -rf "$tmp_dir"
    return 1
  fi

  local count
  count=$(yq_cmd eval '.proxies | length' "$sub_file" 2>/dev/null || echo "0")

  if [ "$count" -eq 0 ]; then
    echo -e "${RED}[错误] 未找到有效的 proxies 列表${NC}"
    rm -rf "$tmp_dir"
    return 1
  fi

  echo -e "${CYAN}[2/4] 获取到 $count 个节点，正在生成配置...${NC}"
  mkdir -p "$SAVE_PATH"

  yq_cmd eval -n '.allow-lan = true' > "$out_file"

  cat >> "$out_file" <<'YAML'
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 114.114.114.114
  nameserver:
    - https://doh.pub/dns-query
YAML

  printf "\nlisteners:\n" >> "$out_file"
  for i in $(seq 0 $((count - 1))); do
    local port=$((START_PORT + i))
    local orig_name
    orig_name=$(yq_cmd eval ".proxies[$i].name" "$sub_file")
    local new_name="${orig_name}-${port}"
    cat >> "$out_file" <<LISTENER
  - name: ${new_name}
    type: mixed
    port: ${port}
    proxy: ${new_name}
LISTENER
  done

  printf "\nproxies:\n" >> "$out_file"
  for i in $(seq 0 $((count - 1))); do
    local port=$((START_PORT + i))
    local orig_name
    orig_name=$(yq_cmd eval ".proxies[$i].name" "$sub_file")
    local new_name="${orig_name}-${port}"

    yq_cmd eval ".proxies[$i]" "$sub_file" | \
      sed "s/^name:.*/name: ${new_name}/" | \
      sed 's/^/  /' >> "$out_file"
  done

  rm -rf "$tmp_dir"
  local file_size
  file_size=$(wc -c < "$out_file" 2>/dev/null || echo "0")
  echo -e "${GREEN}[3/4] 文件已写入: $out_file (${file_size} 字节)${NC}"
  echo -e "${CYAN}[4/4] 节点 $count 个，端口 $START_PORT ~ $((START_PORT + count - 1))${NC}"
  return 0
}

run_once() {
  load_config
  if [ -z "$SUB_URL" ]; then
    echo -e "${RED}[错误] 未配置订阅链接${NC}"
    echo "  请执行: sub2socks config"
    exit 1
  fi
  fetch_and_generate
}

daemon_start() {
  load_config
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo -e "${YELLOW}守护进程已在运行 (PID $(cat "$PID_FILE"))${NC}"
    return
  fi
  nohup "$0" daemon-loop &>/dev/null &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  echo -e "${GREEN}守护进程已启动 (PID $pid)${NC}"
}

daemon_stop() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo -e "${GREEN}守护进程已停止${NC}"
  else
    echo -e "${YELLOW}守护进程未在运行${NC}"
  fi
}

daemon_loop() {
  load_config
  while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始更新..." >> "$LOG_FILE"
    if fetch_and_generate >> "$LOG_FILE" 2>&1; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] 更新完成" >> "$LOG_FILE"
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] 更新失败" >> "$LOG_FILE"
    fi
    sleep "$INTERVAL"
  done
}

show_status() {
  load_config
  echo -e "${CYAN}========== sub2socks 状态 ==========${NC}"
  echo -e "  订阅链接: ${YELLOW}${SUB_URL:-未设置}${NC}"
  echo -e "  更新间隔: ${YELLOW}${INTERVAL} 秒 ($((INTERVAL / 3600)) 小时)${NC}"
  echo -e "  保存路径: ${YELLOW}${SAVE_PATH}${NC}"
  echo -e "  保存文件: ${YELLOW}${SAVE_FILE}${NC}"
  echo -e "  起始端口: ${YELLOW}${START_PORT}${NC}"

  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo -e "  守护进程: ${GREEN}运行中 (PID $(cat "$PID_FILE"))${NC}"
  else
    echo -e "  守护进程: ${RED}未运行${NC}"
  fi

  local out_file="$SAVE_PATH/$SAVE_FILE"
  if [ -f "$out_file" ]; then
    local mtime now ago
    mtime=$(stat -c%Y "$out_file" 2>/dev/null || echo "0")
    now=$(date +%s)
    ago=$(( (now - mtime) / 60 ))
    echo -e "  上次生成: ${YELLOW}${ago} 分钟前${NC}"
    echo -e "  文件大小: ${YELLOW}$(wc -c < "$out_file") 字节${NC}"
  else
    echo -e "  上次生成: ${RED}从未${NC}"
  fi
  echo -e "${CYAN}===================================${NC}"
}

install_service() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}安装系统服务需要 root 权限${NC}"
    echo "  请执行: sudo $0 install"
    exit 1
  fi

  local script_path
  script_path=$(realpath "$0")
  cp "$script_path" /usr/local/bin/sub2socks
  chmod +x /usr/local/bin/sub2socks
  echo -e "${GREEN}已安装到 /usr/local/bin/sub2socks${NC}"

  cat > /etc/systemd/system/sub2socks.service <<EOF
[Unit]
Description=sub2socks - subscription to multi-port SOCKS5 proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/local/bin/sub2socks daemon start
ExecStop=/usr/local/bin/sub2socks daemon stop
ExecReload=/usr/local/bin/sub2socks run
PIDFile=$PID_FILE
Restart=on-failure
RestartSec=30
User=$(logname 2>/dev/null || echo "root")

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sub2socks
  echo -e "${GREEN}系统服务已安装并启用（开机自启）${NC}"
  echo -e "${YELLOW}执行 systemctl start sub2socks 立即启动${NC}"
}

interactive_menu() {
  local choice
  while true; do
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        sub2socks - 订阅转多端口      ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  当前配置简述:"
    echo -e "    订阅文件: ${YELLOW}$SAVE_PATH/$SAVE_FILE${NC}"
    echo -e "    起始端口: ${YELLOW}$START_PORT${NC}"
    echo -e "    更新间隔: ${YELLOW}${INTERVAL}s${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) 配置订阅链接"
    echo -e "  ${GREEN}2${NC}) 配置保存路径"
    echo -e "  ${GREEN}3${NC}) 配置保存文件名"
    echo -e "  ${GREEN}4${NC}) 配置起始端口"
    echo -e "  ${GREEN}5${NC}) 配置更新间隔"
    echo -e "  ${YELLOW}6${NC}) 立即执行一次"
    echo -e "  ${YELLOW}7${NC}) 启动守护进程"
    echo -e "  ${YELLOW}8${NC}) 停止守护进程"
    echo -e "  ${YELLOW}9${NC}) 查看状态"
    echo -e "  ${YELLOW}10${NC}) 安装系统服务（开机自启）"
    echo -e "  ${RED}0${NC}) 退出"
    echo ""
    read -rp "请选择 [0-10]: " choice

    case "$choice" in
      1)
        read -rp "输入订阅链接: " SUB_URL
        save_config
        read -rp "按回车继续..."
        ;;
      2)
        read -rp "保存路径（默认 $DEFAULT_SAVE_PATH）: " val
        SAVE_PATH="${val:-$DEFAULT_SAVE_PATH}"
        save_config
        read -rp "按回车继续..."
        ;;
      3)
        read -rp "保存文件名（如 config.yaml / proxy / nodes）: " val
        SAVE_FILE="${val:-$DEFAULT_SAVE_FILE}"
        save_config
        read -rp "按回车继续..."
        ;;
      4)
        read -rp "起始端口（默认 $DEFAULT_START_PORT）: " val
        START_PORT="${val:-$DEFAULT_START_PORT}"
        save_config
        read -rp "按回车继续..."
        ;;
      5)
        read -rp "更新间隔秒数（默认 3600=1小时）: " val
        INTERVAL="${val:-$DEFAULT_INTERVAL}"
        save_config
        read -rp "按回车继续..."
        ;;
      6) run_once; read -rp "按回车继续..." ;;
      7) daemon_start; read -rp "按回车继续..." ;;
      8) daemon_stop; read -rp "按回车继续..." ;;
      9) show_status; read -rp "按回车继续..." ;;
      10) install_service; read -rp "按回车继续..." ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

help_msg() {
  echo "用法: sub2socks [command]"
  echo ""
  echo "命令:"
  echo "  (无参数)  打开交互式菜单"
  echo "  run       立即执行一次（抓取+生成）"
  echo "  daemon start   启动后台守护进程"
  echo "  daemon stop    停止守护进程"
  echo "  daemon restart 重启守护进程"
  echo "  status    查看状态"
  echo "  install   安装系统服务（开机自启）"
}

main() {
  init_config_dir

  case "${1:-}" in
    run)
      check_deps
      run_once
      ;;
    daemon)
      check_deps
      case "${2:-}" in
        start)   daemon_start ;;
        stop)    daemon_stop ;;
        loop)    daemon_loop ;;
        restart) daemon_stop; sleep 1; daemon_start ;;
        *)       echo "用法: $0 daemon {start|stop|restart}" ;;
      esac
      ;;
    status)
      show_status
      ;;
    install)
      install_service
      ;;
    help|--help|-h)
      help_msg
      ;;
    *)
      check_deps
      load_config
      interactive_menu
      ;;
  esac
}

main "$@"

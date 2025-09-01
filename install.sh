#!/usr/bin/env bash
set -euo pipefail

# ========== 公共函数 ==========
need_root(){ [ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }; }
pubip(){ curl -4s ifconfig.me || curl -4s ipinfo.io/ip || hostname -I | awk '{print $1}'; }
has(){ command -v "$1" >/dev/null 2>&1; }

detect_pm(){
  if has apt; then PM="apt"; elif has yum; then PM="yum"; else
    echo "未检测到 apt/yum 包管理器"; exit 1
  fi
}

pm_install(){
  if [ "$PM" = "apt" ]; then
    apt update
    apt install -y "$@"
  else
    yum install -y epel-release >/dev/null 2>&1 || true
    yum install -y "$@"
  fi
}

ssrust_url_by_arch(){
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64)
      echo "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.22.0/shadowsocks-v1.22.0.x86_64-unknown-linux-gnu.tar.xz"
      ;;
    aarch64|arm64)
      echo "https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.22.0/shadowsocks-v1.22.0.aarch64-unknown-linux-gnu.tar.xz"
      ;;
    *)
      echo "不支持的架构: $ARCH"; exit 1
      ;;
  esac
}

b64_inline(){
  # 兼容不同 base64 实现
  if base64 --help 2>&1 | grep -q -- "-w"; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

# ========== 路径/文件名 ==========
CONF="/etc/shadowsocks.json"
SERVICE="/etc/systemd/system/shadowsocks-rust.service"
RESTART_SVC="/etc/systemd/system/shadowsocks-rust-restart.service"
RESTART_TIMER="/etc/systemd/system/shadowsocks-rust-restart.timer"

# ========== 安装流程 ==========
do_install(){
  need_root
  detect_pm

  echo "== Shadowsocks-2022 (rust) 安装器：OBFS(http) + 每日重启 =="

  # ---- 交互：端口/密码（可回车用默认） ----
  DEFAULT_PORT=45454
  read -rp "端口 [默认 ${DEFAULT_PORT}]: " PORT
  PORT=${PORT:-$DEFAULT_PORT}

  DEFAULT_PW="$(openssl rand -base64 16 2>/dev/null | tr -d '\n' || head -c16 /dev/urandom | base64 | tr -d '\n')"
  read -rp "密码 [默认 自动生成 ]: " PASSWORD_INPUT
  PASSWORD=${PASSWORD_INPUT:-$DEFAULT_PW}

  METHOD="2022-blake3-aes-128-gcm"
  LISTEN="0.0.0.0"

  echo
  echo "=== 配置确认 ==="
  echo "监听地址: ${LISTEN}"
  echo "端口     : ${PORT}"
  echo "加密     : ${METHOD}"
  echo "插件     : obfs=http"
  echo "密码     : ${PASSWORD}"
  read -rp "确认安装？[Y/n]: " OK; OK=${OK:-Y}
  [[ "$OK" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

  # ---- 依赖 ----
  if [ "$PM" = "apt" ]; then
    pm_install curl wget xz-utils simple-obfs
  else
    pm_install curl wget xz simple-obfs || true
  fi

  # ---- 安装 ssserver (rust) ----
  install -d /usr/local/bin
  cd /usr/local/bin
  URL="$(ssrust_url_by_arch)"
  echo "下载 ssserver: $URL"
  wget -qO ssr.tar.xz "$URL"
  tar -xJf ssr.tar.xz
  rm -f ssr.tar.xz
  chmod +x /usr/local/bin/ssserver

  # ---- 写配置 ----
  cat >"$CONF" <<EOF
{
  "server": "${LISTEN}",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "method": "${METHOD}",
  "plugin": "obfs-server",
  "plugin_opts": "obfs=http"
}
EOF

  # ---- 写服务 ----
  cat >"$SERVICE" <<'EOF'
[Unit]
Description=Shadowsocks Rust Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks.json
Restart=on-failure
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

  # ---- 每日重启 timer（04:00）----
  cat >"$RESTART_SVC" <<'EOF'
[Unit]
Description=Restart shadowsocks-rust service (daily)

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart shadowsocks-rust
EOF

  cat >"$RESTART_TIMER" <<'EOF'
[Unit]
Description=Daily restart for shadowsocks-rust

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOF

  # ---- 防火墙放行（尽力而为）----
  if has ufw; then ufw allow "${PORT}"/tcp || true; fi
  if has firewall-cmd; then firewall-cmd --permanent --add-port="${PORT}"/tcp && firewall-cmd --reload || true; fi
  if has iptables; then iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT; fi

  # ---- 启动 & 自启 ----
  systemctl daemon-reload
  systemctl enable --now shadowsocks-rust
  systemctl enable --now shadowsocks-rust-restart.timer

  sleep 1
  if ! systemctl is-active --quiet shadowsocks-rust; then
    echo "❌ 服务启动失败，日志："
    journalctl -u shadowsocks-rust -n 50 --no-pager
    exit 1
  fi

  # ---- 输出节点 ----
  IP="$(pubip)"
  ENC="$(printf "%s:%s" "$METHOD" "$PASSWORD" | b64_inline)"
  SS_OBFS="ss://${ENC}@${IP}:${PORT}?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dwww.bing.com#SS2022-OBFS"
  SS_RAW="ss://${ENC}@${IP}:${PORT}#SS2022-RAW"

  echo
  echo "========================================"
  echo "🎉 安装完成！"
  echo "服务器: ${IP}"
  echo "端口  : ${PORT}"
  echo "加密  : ${METHOD}"
  echo "插件  : obfs=http"
  echo "========================================"
  echo "带 obfs 节点："
  echo "$SS_OBFS"
  echo
  echo "不带 obfs（排障用）："
  echo "$SS_RAW"
  echo "========================================"
}

# ========== 卸载 ==========
do_uninstall(){
  need_root
  detect_pm

  echo "== 卸载 shadowsocks-rust + 定时器 =="

  systemctl disable --now shadowsocks-rust 2>/dev/null || true
  systemctl disable --now shadowsocks-rust-restart.timer 2>/dev/null || true

  rm -f "$SERVICE" "$RESTART_SVC" "$RESTART_TIMER" "$CONF"
  systemctl daemon-reload

  # 可选：删除 ssserver 二进制
  rm -f /usr/local/bin/ssserver

  # 可选：卸载 simple-obfs（如果你不再需要）
  read -rp "是否卸载 simple-obfs 插件包？[y/N]: " DEL
  if [[ "${DEL:-N}" =~ ^[Yy]$ ]]; then
    if [ "$PM" = "apt" ]; then
      apt purge -y simple-obfs || true
      apt autoremove -y || true
    else
      yum remove -y simple-obfs || true
    fi
  fi

  echo "✅ 卸载完成。"
}

# ========== 主入口 ==========
CMD="${1:-install}"
case "$CMD" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  *) echo "用法: bash $0 [install|uninstall]"; exit 1 ;;
esac

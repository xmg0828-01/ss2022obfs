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
  if base64 --help 2>&1 | grep -q -- "-w"; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

# ========== 路径/文件 ==========
CONF="/etc/shadowsocks.json"
SERVICE="/etc/systemd/system/shadowsocks-rust.service"
RESTART_SVC="/etc/systemd/system/shadowsocks-rust-restart.service"
RESTART_TIMER="/etc/systemd/system/shadowsocks-rust-restart.timer"

# ========== 插件检测 ==========
detect_obfs_plugin(){
  if [ -f /etc/debian_version ]; then
    VER=$(grep -oE '^[0-9]+' /etc/debian_version | head -n1)
    if [ "$VER" -ge 13 ]; then
      PLUGIN="v2ray-plugin"
      PLUGIN_OPTS="server;tls;host=bing.com"
    else
      PLUGIN="obfs-server"
      PLUGIN_OPTS="obfs=http"
    fi
  else
    PLUGIN="obfs-server"
    PLUGIN_OPTS="obfs=http"
  fi
}

# ========== 安装 ==========
do_install(){
  need_root
  detect_pm
  detect_obfs_plugin

  echo "== Shadowsocks-2022 (rust) 安装器：${PLUGIN} =="

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
  echo "监听: ${LISTEN}"
  echo "端口: ${PORT}"
  echo "加密: ${METHOD}"
  echo "插件: ${PLUGIN}"
  echo "参数: ${PLUGIN_OPTS}"
  echo "密码: ${PASSWORD}"
  read -rp "确认安装？[Y/n]: " OK; OK=${OK:-Y}
  [[ "$OK" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

  # ---- 依赖 ----
  if [ "$PM" = "apt" ]; then
    pm_install curl wget xz-utils
    if [ "$PLUGIN" = "obfs-server" ]; then
      pm_install simple-obfs
    else
      URL=$(curl -fsSL https://api.github.com/repos/shadowsocks/v2ray-plugin/releases/latest \
        | grep -oE "https://[^\"']*v2ray-plugin-linux-amd64[^\"']*tar.gz" | head -n1)
      cd /usr/local/bin
      curl -L "$URL" -o v2p.tgz
      tar -xzf v2p.tgz
      mv v2ray-plugin_* v2ray-plugin
      chmod +x v2ray-plugin
      rm -f v2p.tgz
    fi
  else
    pm_install curl wget xz
    [ "$PLUGIN" = "obfs-server" ] && pm_install simple-obfs || true
  fi

  # ---- 安装 Shadowsocks-Rust ----
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
  "plugin": "${PLUGIN}",
  "plugin_opts": "${PLUGIN_OPTS}"
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

  # ---- 定时重启 ----
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

  # ---- 防火墙 ----
  if has ufw; then ufw allow "${PORT}"/tcp || true; fi
  if has firewall-cmd; then firewall-cmd --permanent --add-port="${PORT}"/tcp && firewall-cmd --reload || true; fi
  if has iptables; then iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT; fi

  # ---- 启动 ----
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

  if [ "$PLUGIN" = "v2ray-plugin" ]; then
    SS_URL="ss://${ENC}@${IP}:${PORT}?plugin=v2ray-plugin%3Btls%3Bhost%3Dbing.com#SS2022-V2P"
  else
    SS_URL="ss://${ENC}@${IP}:${PORT}?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dbing.com#SS2022-OBFS"
  fi

  echo
  echo "========================================"
  echo "🎉 安装完成！"
  echo "服务器: ${IP}"
  echo "端口  : ${PORT}"
  echo "加密  : ${METHOD}"
  echo "插件  : ${PLUGIN}"
  echo "========================================"
  echo "节点链接："
  echo "$SS_URL"
  echo "========================================"
}

# ========== 卸载 ==========
do_uninstall(){
  need_root
  detect_pm
  detect_obfs_plugin

  echo "== 卸载 Shadowsocks-Rust =="

  systemctl disable --now shadowsocks-rust 2>/dev/null || true
  systemctl disable --now shadowsocks-rust-restart.timer 2>/dev/null || true

  rm -f "$SERVICE" "$RESTART_SVC" "$RESTART_TIMER" "$CONF"
  systemctl daemon-reload

  rm -f /usr/local/bin/ssserver
  [ "$PLUGIN" = "v2ray-plugin" ] && rm -f /usr/local/bin/v2ray-plugin

  if [ "$PLUGIN" = "obfs-server" ]; then
    read -rp "是否卸载 simple-obfs 包？[y/N]: " DEL
    if [[ "${DEL:-N}" =~ ^[Yy]$ ]]; then
      if [ "$PM" = "apt" ]; then
        apt purge -y simple-obfs || true
        apt autoremove -y || true
      else
        yum remove -y simple-obfs || true
      fi
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

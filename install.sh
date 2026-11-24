#!/usr/bin/env bash
# tcm19 installer (Ubuntu 22.04/24.04, Debian 12). Interactive; safe to re-run (re-run = update, keeps data + service).
#
# One-liner:   bash <(curl -Ls https://YOUR-HOST/install.sh) https://YOUR-HOST/vpnpanel-installer.tgz
# From folder: bash install.sh
# Optional env (skips the matching question): PANEL_MODE=ip|domain PANEL_DOMAIN=example.com PANEL_PORT=34567
#   PANEL_USER=name PANEL_PASS=secret INSTALL_XRAY=y|n INSTALL_SINGBOX=y|n INSTALL_MIHOMO=y|n INSTALL_WIREGUARD=y|n INSTALL_OPENVPN=y|n PANEL_URL=https://.../vpnpanel-installer.tgz
set -uo pipefail

P=/opt/vpnpanel
SVC=/etc/systemd/system/vpnpanel.service
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*"; exit 1; }

# ---------- terminal input (works with curl | bash too) ----------
TTY=""; { : </dev/tty; } 2>/dev/null && TTY=/dev/tty
ask() {  # ask "prompt" default
  local a=""
  if [ -n "$TTY" ]; then printf '%s' "$1" >"$TTY"; IFS= read -r a <"$TTY" || a=""; fi
  printf '%s' "${a:-$2}"
}
yesno() {  # yesno "Question?" [default y|n]  -> 0 = yes
  local d="${2:-y}" v
  v="$(ask "$1 [$([ "$d" = y ] && echo Y/n || echo y/N)]: " "$d")"
  [[ "$v" =~ ^[Yy] ]]
}
envyn() { case "${1:-}" in [Yy]*) return 0 ;; [Nn]*) return 1 ;; *) return 2 ;; esac; }
rand_str() { LC_ALL=C tr -dc "$2" </dev/urandom 2>/dev/null | head -c "$1"; }
rand_port() {
  local p
  for _ in $(seq 1 60); do
    p=$((20000 + RANDOM % 40000))
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$p\$" || { echo "$p"; return; }
  done
  echo 34567
}
server_ip() {
  local ip
  ip="$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)"
  printf '%s' "$ip"
}

[ "$(id -u)" = 0 ] || die "Run as root (sudo -i)"
command -v apt-get >/dev/null || die "Only Debian/Ubuntu is supported"

# ---------- locate the panel files (local folder or download) ----------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
SRC=""
if [ -f "$HERE/app/main.py" ] && [ -f "$HERE/static/index.html" ]; then
  SRC="$HERE"
else
  URL="${1:-${PANEL_URL:-}}"
  [ -n "$URL" ] || die "No panel files next to this script. Pass the package URL: bash <(curl -Ls .../install.sh) https://.../vpnpanel-installer.tgz"
  say "Downloading package"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  command -v curl >/dev/null || { apt-get update -y >/dev/null 2>&1; apt-get install -y curl ca-certificates >/dev/null 2>&1; }
  curl -fL --retry 3 -o "$TMP/pkg.tgz" "$URL" || die "Download failed: $URL"
  tar xzf "$TMP/pkg.tgz" -C "$TMP" || die "Package is not a valid .tgz"
  MAIN="$(find "$TMP" -path '*/app/main.py' | head -1)"
  [ -n "$MAIN" ] || die "Package has no app/main.py"
  SRC="$(dirname "$(dirname "$MAIN")")"
fi

# ================= questions (skipped when updating an existing install) =================
UPGRADE=0; [ -f "$SVC" ] && UPGRADE=1
MODE="ip"; DOMAIN=""; ADMIN_USER=""; ADMIN_PASS=""; DO_XRAY=1; DO_SB=1; DO_ML=1; DO_WG=1; DO_OV=1; DO_BOT=0; BOT_TOKEN="${TG_TOKEN:-}"; BOT_OWNER="${TG_OWNER:-}"

if [ "$UPGRADE" = 0 ]; then
  echo
  echo "==================== tcm19 setup ===================="
  # 1) address type
  MODE="${PANEL_MODE:-}"
  if [ -z "$MODE" ]; then
    echo " Run the panel on:"
    echo "   1) Server IP   (http, no domain needed)"
    echo "   2) Domain      (https + free SSL certificate)"
    [ "$(ask "Choose [1]: " 1)" = 2 ] && MODE=domain || MODE=ip
  fi
  if [ "$MODE" = domain ]; then
    for _ in 1 2 3; do
      d="${PANEL_DOMAIN:-$(ask "Domain (e.g. panel.example.com): " "")}"
      d="$(printf '%s' "$d" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#[/:].*$##')"
      if [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then DOMAIN="$d"; break; fi
      warn "Not a valid domain: '$d'"; PANEL_DOMAIN=""
    done
    [ -n "$DOMAIN" ] || { warn "No valid domain; falling back to IP mode"; MODE=ip; }
  fi
  # 2) username / password (Enter = random, any text accepted, no length limit)
  ADMIN_USER="${PANEL_USER:-$(ask "Admin username (Enter = random): " "")}"
  [ -n "$ADMIN_USER" ] || ADMIN_USER="$(rand_str 8 'a-z0-9')"
  ADMIN_PASS="${PANEL_PASS:-$(ask "Admin password (Enter = random): " "")}"
  [ -n "$ADMIN_PASS" ] || ADMIN_PASS="$(rand_str 16 'A-Za-z0-9')"
  # 3) engines, one by one
  for E in XRAY SINGBOX MIHOMO WIREGUARD OPENVPN; do
    case "$E" in XRAY) L="Xray";; SINGBOX) L="sing-box (Hysteria2, TUIC, ...)";; MIHOMO) L="Mihomo (Mieru, Sudoku, ShadowQUIC, TrustTunnel)";; WIREGUARD) L="WireGuard";; OPENVPN) L="OpenVPN";; esac
    v="INSTALL_$E"; envyn "${!v:-}"; r=$?
    if [ $r = 2 ]; then yesno "Install $L?" y && r=0 || r=1; fi
    case "$E" in XRAY) DO_XRAY=$((r==0?1:0));; SINGBOX) DO_SB=$((r==0?1:0));; MIHOMO) DO_ML=$((r==0?1:0));; WIREGUARD) DO_WG=$((r==0?1:0));; OPENVPN) DO_OV=$((r==0?1:0));; esac
  done
  # 4) Telegram bot (optional)
  if [ -n "$BOT_TOKEN" ]; then DO_BOT=1
  else
    envyn "${INSTALL_BOT:-}"; r=$?
    if [ $r = 2 ]; then yesno "Create a Telegram bot to manage the panel? (users, configs, backups, alerts, mini app)" n && r=0 || r=1; fi
    if [ $r = 0 ]; then
      echo "   Open @BotFather in Telegram, send /newbot, then copy the token it gives you and paste it below."
      BOT_TOKEN="$(ask "   Bot token (Enter = skip): " "")"
      if [ -n "$BOT_TOKEN" ]; then
        BOT_OWNER="${TG_OWNER:-$(ask "   Your numeric Telegram ID (Enter = skip, pair later with a code): " "")}"
        DO_BOT=1
      fi
    fi
  fi
  echo
  echo " Address : $([ "$MODE" = domain ] && echo "domain $DOMAIN (https)" || echo "server IP (http)")"
  echo " Engines : xray=$DO_XRAY sing-box=$DO_SB mihomo=$DO_ML wireguard=$DO_WG openvpn=$DO_OV"
  echo "====================================================="
else
  say "Existing install found: updating code only (data, port and service are kept)"
fi

# ---------- Mihomo (Clash.Meta) engine ----------
install_mihomo() {
  local arch tag url tmp
  case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; armv7l) arch=armv7;; *) echo "[!] Unsupported CPU for Mihomo: $(uname -m)"; return 1;; esac
  tmp="$(mktemp -d)"
  url="$(curl -fsSL --retry 3 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null \
        | grep -o "https://[^\"]*mihomo-linux-${arch}-v[0-9]*\.[0-9]*\.[0-9]*\.gz" | head -1)"
  if [ -z "$url" ]; then echo "[!] Could not find the Mihomo release (GitHub unreachable?)"; rm -rf "$tmp"; return 1; fi
  curl -fL --retry 3 -o "$tmp/m.gz" "$url" || { echo "[!] Mihomo download failed"; rm -rf "$tmp"; return 1; }
  gunzip -f "$tmp/m.gz" && install -m 755 "$tmp/m" /usr/local/bin/mihomo || { echo "[!] Mihomo install failed"; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  mkdir -p /etc/mihomo
  cat > /etc/systemd/system/mihomo.service <<'UNIT'
[Unit]
Description=Mihomo (Clash.Meta) engine for tcm19
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo -f /etc/mihomo/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable mihomo >/dev/null 2>&1 || true
  echo "Mihomo installed: $(/usr/local/bin/mihomo -v 2>/dev/null | head -1)"
  echo "(the service starts automatically when you add the first Mihomo inbound in the panel)"
}

# ---------- system packages ----------
say "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || warn "apt update had errors"
BASE="python3 python3-venv python3-pip curl unzip openssl ca-certificates iproute2 iptables openssh-client certbot"
apt-get install -y $BASE python3-certbot-dns-cloudflare >/dev/null 2>&1 \
  || apt-get install -y $BASE || die "Could not install system packages"
if [ "$DO_WG" = 1 ] && [ "$UPGRADE" = 0 ]; then
  say "Installing WireGuard"
  apt-get install -y wireguard-tools >/dev/null 2>&1 || warn "WireGuard install failed"
  printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-vpnpanel.conf
  sysctl -p /etc/sysctl.d/99-vpnpanel.conf >/dev/null 2>&1 || true
fi

if [ "$DO_OV" = 1 ] && [ "$UPGRADE" = 0 ]; then
  say "Installing OpenVPN"
  apt-get install -y openvpn >/dev/null 2>&1 || warn "OpenVPN install failed"
  printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-vpnpanel.conf
  sysctl -p /etc/sysctl.d/99-vpnpanel.conf >/dev/null 2>&1 || true
fi

# ---------- engines ----------
if [ "$UPGRADE" = 0 ]; then
  if [ "$DO_XRAY" = 1 ] && ! command -v xray >/dev/null 2>&1 && [ ! -x /usr/local/bin/xray ]; then
    say "Installing Xray"
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
      || warn "Xray install failed; later: tcm19 -> Reinstall / upgrade engines"
    systemctl enable xray >/dev/null 2>&1 || true
  fi
  if [ "$DO_SB" = 1 ] && ! command -v sing-box >/dev/null 2>&1; then
    say "Installing sing-box"
    curl -fsSL https://sing-box.app/install.sh | sh || warn "sing-box install failed; later: tcm19 -> Reinstall / upgrade engines"
  fi
  if [ "$DO_ML" = 1 ] && [ ! -x /usr/local/bin/mihomo ]; then
    say "Installing Mihomo"
    install_mihomo || warn "Mihomo install failed; later: tcm19 -> Engines -> Mihomo"
  fi
fi

# ---------- panel code ----------
say "Installing panel files"
mkdir -p "$P/data"
cp -a "$SRC/app" "$P/" && cp -a "$SRC/static" "$P/" || die "Copy failed"
rm -rf "$P/app/__pycache__"
printf 'fastapi\nuvicorn\n' > "$P/requirements.txt"
if [ ! -x "$P/venv/bin/uvicorn" ]; then
  say "Creating Python environment"
  python3 -m venv "$P/venv" || die "python3 -m venv failed"
  "$P/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1
  "$P/venv/bin/pip" install -q -r "$P/requirements.txt" || die "pip install failed (no internet?)"
fi
python3 -m py_compile "$P"/app/*.py || die "Panel code has a syntax error"
pyrun() { ( cd "$P" && PANEL_HOME="$P" "$P/venv/bin/python" "$@" ); }

# ---------- port ----------
if [ "$UPGRADE" = 1 ]; then
  PORT="$(grep -o -- '--port [0-9]*' "$SVC" | tail -1 | awk '{print $2}')"
else
  PORT="${PANEL_PORT:-$(rand_port)}"
fi

# ---------- admin account (fresh install) ----------
if [ "$UPGRADE" = 0 ]; then
  say "Creating admin account"
  PANEL_U="$ADMIN_USER" PANEL_P="$ADMIN_PASS" pyrun - <<'PY' || die "Could not create the admin account"
import os
from app import db, security
db.init()
if not db.admin_count():
    db.create_admin(os.environ["PANEL_U"], security.hash_password(os.environ["PANEL_P"]))
PY
fi

# ---------- domain + SSL certificate ----------
TLS=0
if [ "$UPGRADE" = 0 ] && [ "$MODE" = domain ]; then
  say "Getting a free SSL certificate for $DOMAIN"
  IP="$(server_ip)"
  DNSIP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
  if [ -z "$DNSIP" ]; then
    warn "$DOMAIN does not resolve yet. Create an A record -> $IP first."
  elif ! printf '%s' "$DNSIP" | grep -qw "$IP"; then
    warn "$DOMAIN points to $DNSIP but this server is $IP (OK only if you use a proxy like Cloudflare)."
  fi
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ':80$'; then
    warn "Port 80 is already in use; the certificate needs it."
    CERT_OK=0
  else
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active" && ufw allow 80/tcp >/dev/null 2>&1
    CERT_LOG="$(mktemp)"
    pyrun - "$DOMAIN" "$PORT" >"$CERT_LOG" 2>&1 <<'PY'
import sys
from app import db, certstore as cs
db.init()
dom, port = cs.norm_name(sys.argv[1]), sys.argv[2]
if not cs.issue(dom, "http", False, [], "", lambda s: print(s, end="")):
    sys.exit(2)
cs.set_panel(dom)
db.set_settings({"server_address": dom, "sub_base_url": f"https://{dom}:{port}"})
PY
    CERT_OK=$([ $? = 0 ] && echo 1 || echo 0)
    [ "$CERT_OK" = 1 ] || { echo "--- certbot output (last lines) ---"; tail -n 15 "$CERT_LOG"; echo "-----------------------------------"; }
    rm -f "$CERT_LOG"
  fi
  if [ "${CERT_OK:-0}" = 1 ]; then TLS=1; echo "Certificate installed."
  else warn "Certificate failed; continuing in IP mode (http). Fix DNS/port 80 and use the panel's Domains page later."; MODE=ip; fi
fi

# ---------- service ----------
if [ "$UPGRADE" = 0 ]; then
  say "Creating service on port $PORT"
  cat > "$SVC" <<UNIT
[Unit]
Description=tcm19
After=network.target

[Service]
User=root
WorkingDirectory=$P
Environment=PANEL_HOME=$P
ExecStart=/usr/bin/python3 $P/app/tlslaunch.py -- $P/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port $PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
fi
systemctl daemon-reload
systemctl enable vpnpanel >/dev/null 2>&1
systemctl restart vpnpanel

# ---------- menu command ----------
if [ -f "$SRC/vpnpanel-menu.sh" ]; then
  install -m 755 "$SRC/vpnpanel-menu.sh" /usr/local/bin/tcm19
  rm -f /usr/local/bin/panel /usr/local/bin/vpnpanel
fi
pyrun -m app.panelctl install-hook >/dev/null 2>&1 || true

# ---------- firewall (only if ufw is already active) ----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT/tcp" >/dev/null 2>&1 && echo "ufw: opened $PORT/tcp"
fi

# ---------- wait, set server address (IP mode), print result ----------
say "Waiting for the panel"
for _ in $(seq 1 30); do
  [ "$(systemctl is-active vpnpanel)" = active ] && [ -f "$P/data/panel.db" ] && break
  sleep 1
done
IP="$(server_ip)"
if [ "$UPGRADE" = 0 ] && [ "$TLS" = 0 ] && [ -n "$IP" ]; then
  python3 - "$IP" <<'PY' 2>/dev/null || true
import sqlite3, sys
c = sqlite3.connect("/opt/vpnpanel/data/panel.db")
c.execute("UPDATE settings SET value=? WHERE key='server_address' AND value=''", (sys.argv[1],))
c.commit()
PY
fi
if [ "$DO_BOT" = 1 ] && [ -n "$BOT_TOKEN" ]; then
  say "Setting up the Telegram bot"
  ( cd "$P" && PANEL_HOME="$P" "$P/venv/bin/python" -m app.panelctl bot-setup "$BOT_TOKEN" ${BOT_OWNER:+--owner "$BOT_OWNER"} ) || warn "Bot setup failed (check the token / internet access)"
  if [ -z "$BOT_OWNER" ]; then
    PAIR="$( cd "$P" && PANEL_HOME="$P" "$P/venv/bin/python" -m app.panelctl bot-pair --hours 24 2>/dev/null | tail -1)"
    [ -n "$PAIR" ] && echo "   -> Open your bot in Telegram and send:  /start $PAIR   (valid 24h, makes you the bot admin)"
  fi
fi
systemctl try-restart tcm19-bot 2>/dev/null || true
if [ "$UPGRADE" = 0 ] && [ "$DO_OV" = 1 ]; then
  python3 - <<'PY' 2>/dev/null || true
import sqlite3
c = sqlite3.connect("/opt/vpnpanel/data/panel.db")
c.execute("UPDATE settings SET value='1' WHERE key='ovpn_enabled'")
c.commit()
PY
  systemctl restart vpnpanel
fi
sleep 2
echo
echo "================ Done ================"
if [ "$(systemctl is-active vpnpanel)" = active ]; then
  if [ "$TLS" = 1 ]; then echo "Panel:    https://$DOMAIN:$PORT"; else echo "Panel:    http://$IP:$PORT"; fi
  if [ "$UPGRADE" = 0 ]; then
    echo "Username: $ADMIN_USER"
    echo "Password: $ADMIN_PASS"
  else
    echo "Existing admin account kept. Forgot the password? Run: tcm19 -> Reset admin password"
  fi
  echo
  echo "Open in your provider's firewall: TCP $PORT$([ "$TLS" = 1 ] && echo " and TCP 80 (certificate renewal)")"
  echo "Menu:     type  tcm19"
else
  warn "Panel did not start. Logs:"; journalctl -u vpnpanel -n 20 --no-pager
fi

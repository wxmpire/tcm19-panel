#!/usr/bin/env bash
# VPN Panel installer (Ubuntu 22.04/24.04, Debian 12). Safe to re-run: it updates the code and keeps data + service.
#
# One-liner (after you host the files, see README):
#   bash <(curl -Ls https://YOUR-HOST/install.sh) https://YOUR-HOST/vpnpanel-installer.tgz
# From the unpacked folder:
#   bash install.sh
# Options (env): PANEL_PORT=34567  PANEL_URL=https://.../vpnpanel-installer.tgz
set -uo pipefail

P=/opt/vpnpanel
SVC=/etc/systemd/system/vpnpanel.service
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*"; exit 1; }

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
  say "Downloading panel package"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  apt-get install -y curl ca-certificates >/dev/null 2>&1 || true
  curl -fL --retry 3 -o "$TMP/pkg.tgz" "$URL" || die "Download failed: $URL"
  tar xzf "$TMP/pkg.tgz" -C "$TMP" || die "Package is not a valid .tgz"
  MAIN="$(find "$TMP" -path '*/app/main.py' | head -1)"
  [ -n "$MAIN" ] || die "Package has no app/main.py"
  SRC="$(dirname "$(dirname "$MAIN")")"
fi

# ---------- system packages ----------
say "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || warn "apt update had errors"
apt-get install -y python3 python3-venv python3-pip curl unzip openssl ca-certificates iproute2 iptables \
  wireguard-tools certbot python3-certbot-dns-cloudflare >/dev/null 2>&1 \
  || apt-get install -y python3 python3-venv python3-pip curl unzip openssl ca-certificates iproute2 iptables wireguard-tools certbot \
  || die "Could not install system packages"

# ---------- Xray ----------
if ! command -v xray >/dev/null 2>&1 && [ ! -x /usr/local/bin/xray ]; then
  say "Installing Xray"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
    || warn "Xray install failed; run the menu later: vpnpanel -> Install/repair engines"
fi
# ---------- sing-box ----------
if ! command -v sing-box >/dev/null 2>&1; then
  say "Installing sing-box"
  curl -fsSL https://sing-box.app/install.sh | sh || warn "sing-box install failed (Hysteria2/TUIC need it; everything else works)"
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

# ---------- service ----------
rand_port() {
  local p
  for _ in $(seq 1 60); do
    p=$((20000 + RANDOM % 40000))
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$p\$" || { echo "$p"; return; }
  done
  echo 34567
}
if [ -f "$SVC" ]; then
  PORT="$(grep -o -- '--port [0-9]*' "$SVC" | tail -1 | awk '{print $2}')"
  say "Existing service kept (port ${PORT:-?})"
else
  PORT="${PANEL_PORT:-$(rand_port)}"
  say "Creating service on port $PORT"
  cat > "$SVC" <<UNIT
[Unit]
Description=VPN Panel
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
cat > /etc/sysctl.d/99-vpnpanel.conf <<'SYS'
net.ipv4.ip_forward=1
SYS
sysctl -p /etc/sysctl.d/99-vpnpanel.conf >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1 || true
systemctl enable vpnpanel >/dev/null 2>&1
systemctl restart vpnpanel

# ---------- menu command ----------
if [ -f "$SRC/vpnpanel-menu.sh" ]; then
  install -m 755 "$SRC/vpnpanel-menu.sh" /usr/local/bin/vpnpanel
  ln -sf /usr/local/bin/vpnpanel /usr/local/bin/panel
fi
( cd "$P" && python3 -m app.panelctl install-hook >/dev/null 2>&1 ) || true

# ---------- firewall (only if ufw is already active) ----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT/tcp" >/dev/null 2>&1 && echo "ufw: opened $PORT/tcp"
fi

# ---------- wait for first start, set server address, print login ----------
say "Waiting for the panel"
for _ in $(seq 1 30); do
  [ "$(systemctl is-active vpnpanel)" = active ] && [ -f "$P/data/panel.db" ] && break
  sleep 1
done
IP="$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || true)"
[ -n "$IP" ] || IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)"
if [ -n "$IP" ] && [ -f "$P/data/panel.db" ]; then
  python3 - "$IP" <<'PY' 2>/dev/null || true
import sqlite3, sys
c = sqlite3.connect("/opt/vpnpanel/data/panel.db")
c.execute("UPDATE settings SET value=? WHERE key='server_address' AND value=''", (sys.argv[1],))
c.commit()
PY
fi
sleep 2
echo
echo "================ Done ================"
if [ "$(systemctl is-active vpnpanel)" = active ]; then
  echo "Panel:    http://$IP:$PORT"
  if [ -f "$P/data/initial_admin.txt" ]; then
    sed 's/^username:/Username:/; s/^password:/Password:/' "$P/data/initial_admin.txt"
    echo "(Save it, then delete the file: vpnpanel -> Login info)"
  else
    echo "Existing admin account kept. Forgot the password? Run: vpnpanel  -> Reset admin password"
  fi
  echo "Open TCP port $PORT in your provider's firewall."
  echo "Menu:     type  vpnpanel  (or  panel)"
else
  warn "Panel did not start. Logs:"; journalctl -u vpnpanel -n 20 --no-pager
fi

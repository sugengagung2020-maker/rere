#!/bin/bash
# ========================================================
# fix-ssh-ssl.sh
#
# Fix untuk VPS yang sudah pernah install rere fork ini sebelum PR
# nginx-stream merge — di mana sslh-select 1.20 sni_hostnames tidak
# reliable sehingga semua TLS dirute ke 1015 (stunnel) dan xray
# putus.
#
# Cara pakai (di VPS, sebagai root):
#   bash <(curl -sL https://raw.githubusercontent.com/sugengagung2020-maker/rere/main/file/fix-ssh-ssl.sh)
#
# Yang dilakukan:
#   1. Install libnginx-mod-stream kalau belum ada.
#   2. Re-generate /etc/sslh/sslh.cfg supaya semua TLS diteruskan ke
#      127.0.0.1:8443 (nginx-stream) — bukan SNI matching di sslh.
#   3. Append stream block ke /etc/nginx/nginx.conf (kalau belum ada)
#      dengan map ssl_preread_server_name -> upstream:
#        SNI = ${domain} -> 127.0.0.1:1013 (nginx http TLS, xray)
#        default         -> 127.0.0.1:1015 (stunnel -> OpenSSH:22)
#   4. Restart sslh dan nginx.
#
# Idempotent: bisa dijalankan berkali-kali tanpa merusak state.
# ========================================================

set -e

if [ "$(id -u)" != "0" ]; then
    echo "[fix-ssh-ssl] Harus dijalankan sebagai root."
    exit 1
fi

XRAY_DOMAIN_FILE="/usr/local/etc/xray/domain"
if [ ! -f "$XRAY_DOMAIN_FILE" ]; then
    echo "[fix-ssh-ssl] ERROR: $XRAY_DOMAIN_FILE tidak ada. Belum install rere?"
    exit 1
fi
DOMAIN=$(cat "$XRAY_DOMAIN_FILE")
if [ -z "$DOMAIN" ]; then
    echo "[fix-ssh-ssl] ERROR: domain di $XRAY_DOMAIN_FILE kosong."
    exit 1
fi
echo "[fix-ssh-ssl] Domain terdeteksi: $DOMAIN"

# 1. Install libnginx-mod-stream
if ! dpkg -s libnginx-mod-stream >/dev/null 2>&1; then
    echo "[fix-ssh-ssl] Installing libnginx-mod-stream ..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y libnginx-mod-stream
else
    echo "[fix-ssh-ssl] libnginx-mod-stream sudah terpasang."
fi

# 2. Re-generate /etc/sslh/sslh.cfg
TS=$(date +%s)
BACKUP_DIR="/root/rere-fix-ssh-ssl-backup-$TS"
mkdir -p "$BACKUP_DIR"
[ -f /etc/sslh/sslh.cfg ] && cp /etc/sslh/sslh.cfg "$BACKUP_DIR/sslh.cfg"
[ -f /etc/default/sslh ] && cp /etc/default/sslh "$BACKUP_DIR/sslh.default"
[ -f /etc/nginx/nginx.conf ] && cp /etc/nginx/nginx.conf "$BACKUP_DIR/nginx.conf"
echo "[fix-ssh-ssl] Backup config lama -> $BACKUP_DIR"

mkdir -p /etc/sslh /var/run/sslh

cat > /etc/default/sslh <<'EOF'
# Managed by sugengagung2020-maker/rere fix-ssh-ssl.sh
# Mode: config file (sslh-select)
RUN=yes
DAEMON=/usr/sbin/sslh-select
DAEMON_OPTS="-F /etc/sslh/sslh.cfg"
EOF
chmod 644 /etc/default/sslh

cat > /etc/sslh/sslh.cfg <<'EOF'
verbose: false;
foreground: false;
inetd: false;
numeric: false;
transparent: false;
timeout: 2;
user: "sslh";
pidfile: "/var/run/sslh/sslh.pid";

listen:
(
    { host: "0.0.0.0"; port: "2443"; },
    { host: "0.0.0.0"; port: "2081"; }
);

protocols:
(
    { name: "ssh";    host: "127.0.0.1"; port: "22";   probe: "builtin"; },
    { name: "tls";    host: "127.0.0.1"; port: "8443"; probe: "builtin"; },
    { name: "socks5"; host: "127.0.0.1"; port: "1080"; probe: "builtin"; },
    { name: "http";   host: "127.0.0.1"; port: "2080"; probe: "builtin"; }
);
EOF
chmod 644 /etc/sslh/sslh.cfg
echo "[fix-ssh-ssl] /etc/sslh/sslh.cfg di-regenerate (TLS -> nginx-stream 8443)."

# 3. Append stream block ke nginx.conf kalau belum ada
NGINX_CONF=/etc/nginx/nginx.conf
if [ ! -f "$NGINX_CONF" ]; then
    echo "[fix-ssh-ssl] ERROR: $NGINX_CONF tidak ada."
    exit 1
fi

if grep -q "rerechan_tls_upstream" "$NGINX_CONF"; then
    echo "[fix-ssh-ssl] Stream block sudah ada di nginx.conf (skip append)."
else
    cat >> "$NGINX_CONF" <<EOF

# ===== Stream block (SNI router untuk SSH-SSL via stunnel) =====
# Ditambahkan oleh fix-ssh-ssl.sh.
# SNI = ${DOMAIN}        -> 127.0.0.1:1013 (nginx http TLS, xray)
# SNI lain / kosong      -> 127.0.0.1:1015 (stunnel -> OpenSSH:22)
stream {
    map \$ssl_preread_server_name \$rerechan_tls_upstream {
        ${DOMAIN}    127.0.0.1:1013;
        default     127.0.0.1:1015;
    }

    server {
        listen 127.0.0.1:8443;
        ssl_preread on;
        proxy_pass \$rerechan_tls_upstream;
        proxy_connect_timeout 10s;
    }
}
EOF
    echo "[fix-ssh-ssl] Stream block di-append ke $NGINX_CONF."
fi

# 4. Test config + restart
echo "[fix-ssh-ssl] Test nginx config ..."
if ! nginx -t; then
    echo "[fix-ssh-ssl] ERROR: nginx config gagal test. Restore backup:"
    echo "[fix-ssh-ssl]   cp $BACKUP_DIR/nginx.conf $NGINX_CONF && systemctl restart nginx"
    exit 1
fi

echo "[fix-ssh-ssl] Restart sslh + nginx ..."
systemctl daemon-reload
systemctl restart nginx
systemctl restart sslh

# Sanity: cek port 8443 listen
sleep 1
if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:8443"; then
    echo "[fix-ssh-ssl] OK: nginx-stream listen di 127.0.0.1:8443."
else
    echo "[fix-ssh-ssl] WARNING: 127.0.0.1:8443 tidak listen. Cek 'systemctl status nginx' dan log."
fi

echo "[fix-ssh-ssl] Selesai."
echo "[fix-ssh-ssl] Test:"
echo "  - Xray HUP TLS via klien existing dengan SNI = $DOMAIN  -> harus konek."
echo "  - HTTP Custom 'SSL only' + SNI bug bebas (mis. live.iflix.com) port 443 -> harus konek SSH."

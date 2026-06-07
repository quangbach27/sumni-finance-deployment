#!/bin/bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

exec > >(tee /var/log/sumni-setup.log) 2>&1
trap 'echo "ERROR at line $LINENO — check /var/log/sumni-setup.log" >&2' ERR

DOMAIN=${DOMAIN_FRONTEND:-"deadun.site"}
DOMAIN_API=${DOMAIN_API:-"api.deadun.site"}
EMAIL=${EMAIL:-"buiquangbach27@gmail.com"}

valid_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$ ]] \
    || { echo "ERROR: Invalid domain: $1"; exit 1; }
}
valid_domain "$DOMAIN"
valid_domain "$DOMAIN_API"

# ── Dependencies ──────────────────────────────────────────────────────────────
echo "==> Installing Nginx & Certbot..."
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx
systemctl enable --now nginx

# ── TLS certificates ──────────────────────────────────────────────────────────
echo "==> Obtaining TLS certificates..."
mkdir -p /var/www/html
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/sumni-temp <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name _;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 200 'ok'; add_header Content-Type text/plain; }
}
EOF

ln -sf /etc/nginx/sites-available/sumni-temp /etc/nginx/sites-enabled/sumni-temp
nginx -t && systemctl reload nginx

certbot certonly --webroot -w /var/www/html \
  -d "$DOMAIN" -d "www.$DOMAIN" \
  --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring

certbot certonly --webroot -w /var/www/html \
  -d "$DOMAIN_API" \
  --non-interactive --agree-tos -m "$EMAIL" --keep-until-expiring

# ── SSL base config ───────────────────────────────────────────────────────────
if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
  cat > /etc/letsencrypt/options-ssl-nginx.conf <<'EOF'
ssl_session_cache    shared:le_nginx_SSL:10m;
ssl_session_timeout  1440m;
ssl_session_tickets  off;
ssl_protocols        TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256";
EOF
fi

[ -f /etc/letsencrypt/ssl-dhparams.pem ] \
  || openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048

# ── Nginx snippets ────────────────────────────────────────────────────────────
echo "==> Writing Nginx config..."
mkdir -p /etc/nginx/snippets

cat > /etc/nginx/snippets/proxy-params.conf <<'EOF'
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection 'upgrade';
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_cache_bypass $http_upgrade;
EOF

cat > /etc/nginx/snippets/security-headers.conf <<'EOF'
add_header X-Content-Type-Options    "nosniff"                                      always;
add_header Referrer-Policy           "strict-origin-when-cross-origin"              always;
add_header Permissions-Policy        "geolocation=(), microphone=(), camera=()"     always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
EOF

# ── Site config ───────────────────────────────────────────────────────────────
# Ubuntu 24.04 nginx 1.24.x: http2 belongs in the listen directive.
cat > /etc/nginx/sites-available/sumni <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN $DOMAIN_API;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name www.$DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    return 301 https://$DOMAIN\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    include /etc/nginx/snippets/security-headers.conf;
    add_header X-Frame-Options "DENY" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self' https://$DOMAIN_API;" always;
    location / {
        proxy_pass http://localhost:3000;
        include /etc/nginx/snippets/proxy-params.conf;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN_API;
    ssl_certificate     /etc/letsencrypt/live/$DOMAIN_API/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_API/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    client_max_body_size 20m;
    include /etc/nginx/snippets/security-headers.conf;
    location / {
        proxy_pass http://localhost:4000;
        include /etc/nginx/snippets/proxy-params.conf;
        proxy_connect_timeout 60s;
        proxy_read_timeout    60s;
        proxy_send_timeout    60s;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/sumni-temp
ln -sf /etc/nginx/sites-available/sumni /etc/nginx/sites-enabled/sumni
nginx -t && systemctl reload nginx

# ── Auto-renewal ──────────────────────────────────────────────────────────────
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/bash
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

if systemctl is-active --quiet certbot.timer 2>/dev/null; then
  echo "==> certbot systemd timer active — renewal handled automatically."
elif ! crontab -l 2>/dev/null | grep -qF 'certbot renew'; then
  CRON="${RANDOM % 60} ${RANDOM % 24} * * * certbot renew --quiet"
  (crontab -l 2>/dev/null; echo "$CRON") | crontab -
  echo "==> Added daily certbot renew cron."
fi

echo ""
echo "✅ Done!  Frontend: https://$DOMAIN   API: https://$DOMAIN_API"
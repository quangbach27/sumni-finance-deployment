#!/bin/bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

# Open log file first so the ERR trap can always write to it
exec > >(tee /var/log/sumni-setup.log) 2>&1
trap 'echo "ERROR: setup.sh failed at line $LINENO — nginx may need manual recovery. Check /var/log/sumni-setup.log" >&2' ERR

DOMAIN_FRONTEND=${DOMAIN_FRONTEND:-"deadun.site"}
DOMAIN_API=${DOMAIN_API:-"api.deadun.site"}
EMAIL=${EMAIL:-"buiquangbach27@gmail.com"}

[[ "${DOMAIN_FRONTEND}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$ ]] \
  || { echo "ERROR: Invalid DOMAIN_FRONTEND: ${DOMAIN_FRONTEND}"; exit 1; }
[[ "${DOMAIN_API}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$ ]] \
  || { echo "ERROR: Invalid DOMAIN_API: ${DOMAIN_API}"; exit 1; }

echo "==> Installing Nginx & Certbot..."
apt update
apt install -y nginx certbot python3-certbot-nginx
systemctl enable nginx
systemctl start nginx

# Ubuntu 24.04 ships nginx 1.24.x — http2 goes in the listen directive.
# If you later add the official nginx PPA (>=1.25.1), move to `http2 on;` directive style.
HTTP2_IN_LISTEN="http2"

echo "==> Issuing TLS certificates (temp HTTP config first)..."
mkdir -p /var/www/html
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/sumni-temp << 'EOF'
server {
    listen 80;
    server_name _;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 200 'ok'; add_header Content-Type text/plain; }
}
EOF

ln -sf /etc/nginx/sites-available/sumni-temp /etc/nginx/sites-enabled/sumni-temp
nginx -t && systemctl reload nginx

certbot certonly --webroot -w /var/www/html \
  -d "${DOMAIN_FRONTEND}" -d "www.${DOMAIN_FRONTEND}" \
  --non-interactive --agree-tos -m "${EMAIL}" --keep-until-expiring

certbot certonly --webroot -w /var/www/html \
  -d "${DOMAIN_API}" \
  --non-interactive --agree-tos -m "${EMAIL}" --keep-until-expiring

if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
  echo "==> Writing /etc/letsencrypt/options-ssl-nginx.conf (not created by --webroot)..."
  cat > /etc/letsencrypt/options-ssl-nginx.conf << 'EOF'
ssl_session_cache    shared:le_nginx_SSL:10m;
ssl_session_timeout  1440m;
ssl_session_tickets  off;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256";
EOF
fi

if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then
  echo "==> Generating DH params..."
  openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
fi

echo "==> Writing Nginx snippets..."
mkdir -p /etc/nginx/snippets

cat > /etc/nginx/snippets/proxy-params.conf << 'EOF'
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection 'upgrade';
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_cache_bypass $http_upgrade;
EOF

cat > /etc/nginx/snippets/security-headers-common.conf << 'EOF'
add_header X-Content-Type-Options    "nosniff"                                       always;
add_header Referrer-Policy           "strict-origin-when-cross-origin"               always;
add_header Permissions-Policy        "geolocation=(), microphone=(), camera=()"      always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"  always;
EOF

cat > /etc/nginx/snippets/security-headers-frontend.conf << EOF
add_header X-Frame-Options         "DENY"  always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self' https://${DOMAIN_API};" always;
EOF

echo "==> Writing Nginx site config..."

cat > /etc/nginx/sites-available/sumni << EOF
# ── Redirect HTTP → HTTPS ────────────────────────────────────────────────────
server {
    listen 80;
    server_name ${DOMAIN_FRONTEND} www.${DOMAIN_FRONTEND} ${DOMAIN_API};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl ${HTTP2_IN_LISTEN};
    server_name www.${DOMAIN_FRONTEND};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN_FRONTEND}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_FRONTEND}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    return 301 https://${DOMAIN_FRONTEND}\$request_uri;
}

server {
    listen 443 ssl ${HTTP2_IN_LISTEN};
    server_name ${DOMAIN_FRONTEND};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN_FRONTEND}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_FRONTEND}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    include /etc/nginx/snippets/security-headers-common.conf;
    include /etc/nginx/snippets/security-headers-frontend.conf;

    location / {
        proxy_pass http://localhost:3000;
        include /etc/nginx/snippets/proxy-params.conf;
    }
}

server {
    listen 443 ssl ${HTTP2_IN_LISTEN};
    server_name ${DOMAIN_API};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN_API}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_API}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size 20m;

    # FIX 3: API gets only transport/content headers — no CSP, no X-Frame-Options.
    include /etc/nginx/snippets/security-headers-common.conf;

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

echo "==> Installing certbot deploy hook (nginx reload on renewal)..."
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'EOF'
#!/bin/bash
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

echo "==> Setting up renewal scheduler (idempotent)..."
if systemctl is-active --quiet certbot.timer 2>/dev/null; then
  echo "    certbot systemd timer is active — deploy hook will reload nginx on renewal."
elif crontab -l 2>/dev/null | grep -qF 'certbot renew'; then
  echo "    certbot cron entry already present — skipping. Ensure your cron runs the deploy hook."
else
  RAND_MIN=$(( RANDOM % 60 ))
  RAND_HOUR=$(( RANDOM % 24 ))
  CRON_LINE="${RAND_MIN} ${RAND_HOUR} * * * certbot renew --quiet"
  (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
  echo "    Added cron: certbot renew at ${RAND_HOUR}:${RAND_MIN} daily"
  echo "    nginx reload is handled by /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh"
fi

echo ""
echo "✅ Nginx setup complete!"
echo "   Frontend : https://${DOMAIN_FRONTEND}"
echo "   Go API   : https://${DOMAIN_API}"
echo "   Log file : /var/log/sumni-setup.log"
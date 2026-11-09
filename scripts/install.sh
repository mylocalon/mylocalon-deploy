#!/usr/bin/env bash
# One-time host setup on Ubuntu 24.04. Idempotent. Run as root from deploy/.
set -euo pipefail
cd "$(dirname "$0")/.."

apt-get update
apt-get install -y ca-certificates curl gnupg debian-keyring debian-archive-keyring apt-transport-https \
  postgresql redis-server openssl rsync

# Node 22 LTS (Ubuntu's own nodejs is 18; the platform needs 20–22).
if ! node --version 2>/dev/null | grep -q '^v22\.'; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi

# Caddy from the official repo, plus the Cloudflare DNS module for the wildcard cert.
if ! command -v caddy >/dev/null; then
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update && apt-get install -y caddy
fi
caddy list-modules 2>/dev/null | grep -q dns.providers.cloudflare || caddy add-package github.com/caddy-dns/cloudflare
apt-mark hold caddy   # apt upgrades would drop the added DNS module
[ -f /etc/caddy/caddy.env ] || install -m 0640 -o root -g caddy env/caddy.env /etc/caddy/caddy.env
install -m 0644 caddy/Caddyfile /etc/caddy/Caddyfile
install -d /etc/systemd/system/caddy.service.d
printf '[Service]\nEnvironmentFile=/etc/caddy/caddy.env\n' > /etc/systemd/system/caddy.service.d/env.conf

id mylocalon >/dev/null 2>&1 || useradd --system --home /opt/mylocalon --shell /usr/sbin/nologin mylocalon

install -d -m 0750 -o root -g mylocalon /etc/mylocalon
install -d -m 0700 -o root -g root /etc/mylocalon/credentials
for f in gateway platform; do
  [ -f "/etc/mylocalon/$f.env" ] || install -m 0640 -o root -g mylocalon "env/$f.env" "/etc/mylocalon/$f.env"
done

# Fill each placeholder once with a fresh secret (idempotent: real values are left alone).
fill() { # fill <file> <PLACEHOLDER> <value>
  grep -q "$2" "$1" && sed -i "s|$2|$3|" "$1" || true
}
secret() { openssl rand -hex 24; }

# Redis: localhost only, password required (internal services never exposed).
sed -i 's/^#\? *bind .*/bind 127.0.0.1 -::1/' /etc/redis/redis.conf
if ! grep -q '^requirepass' /etc/redis/redis.conf; then
  echo "requirepass $(secret)" >> /etc/redis/redis.conf
fi
fill /etc/mylocalon/gateway.env REDIS_PASSWORD "$(awk '/^requirepass/ {print $2}' /etc/redis/redis.conf)"
systemctl restart redis-server

# Postgres role + database.
if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='mylocalon'" | grep -q 1; then
  pw="$(secret)"
  sudo -u postgres psql -c "CREATE ROLE mylocalon LOGIN PASSWORD '$pw'"
  fill /etc/mylocalon/platform.env DB_PASSWORD "$pw"
fi
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='mylocalon'" | grep -q 1 ||
  sudo -u postgres createdb -O mylocalon mylocalon

# Shared Gateway<->Platform internal token.
if grep -q GENERATE_WITH /etc/mylocalon/platform.env; then
  tok="$(openssl rand -hex 32)"
  fill /etc/mylocalon/platform.env GENERATE_WITH_openssl_rand_hex_32 "$tok"
  fill /etc/mylocalon/gateway.env SAME_AS_PLATFORM_INTERNAL_API_TOKEN "$tok"
fi

# JWT signing key (Platform only), delivered via systemd LoadCredential.
if [ ! -f /etc/mylocalon/credentials/jwt.key ]; then
  openssl genpkey -algorithm ed25519 -out /etc/mylocalon/credentials/jwt.key
  chmod 0600 /etc/mylocalon/credentials/jwt.key
fi

# App directories; ops scripts live with the deployment.
install -d -m 0755 -o mylocalon -g mylocalon /opt/mylocalon /opt/mylocalon/gateway/bin /opt/mylocalon/platform
install -d -m 0755 /opt/mylocalon/deploy/scripts
install -m 0755 scripts/*.sh /opt/mylocalon/deploy/scripts/

install -m 0644 systemd/*.service systemd/*.timer /etc/systemd/system/
install -d -m 0750 -o postgres -g postgres /var/backups/mylocalon
systemctl daemon-reload
systemctl enable mylocalon-backup.timer
echo "Secrets generated in /etc/mylocalon. Put your Cloudflare token + email in /etc/caddy/caddy.env,"
echo "deploy builds to /opt/mylocalon (see DEPLOYMENT.md), then:"
echo "  systemctl enable --now mylocalon-platform mylocalon-gateway caddy"

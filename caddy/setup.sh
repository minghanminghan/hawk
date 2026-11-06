#!/usr/bin/env bash
# Serves https://<name>.$DOMAIN to the tailnet only, through Caddy on :443. Run as root; safe to re-run:
#   sudo [DOMAIN=andrewminghanjiang.com] caddy/setup.sh <name> <upstream>
#   hawk setup runs it for each app
# Adds Caddy's vercel DNS plugin, the base Caddyfile bound to the tailscale IPs, the caddy.service
# drop-in, and /etc/caddy/sites/<name>.caddy, then points <name>'s A/AAAA records at the tailscale IPs.
# Asks for a Vercel API token once and keeps it in /etc/caddy/caddy.env.
set -euo pipefail

NAME=${1:-}
UPSTREAM=${2:-}
DOMAIN=${DOMAIN:-andrewminghanjiang.com}
ENV_FILE=/etc/caddy/caddy.env
DROPIN=/etc/systemd/system/caddy.service.d/tailnet.conf
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[[ -n $NAME && -n $UPSTREAM ]] || die "usage: $0 <name> <upstream>"
[[ $EUID -eq 0 ]] || die "run as root (sudo $0)"
for cmd in caddy go tailscale node curl systemctl apt-mark; do
  command -v "$cmd" >/dev/null || die "$cmd not found"
done
HOST=$NAME.$DOMAIN
changed=0

# Writes $2 to $1 if it differs, and notes that Caddy needs a restart.
put() {
  if [[ ! -f $1 ]] || [[ $(cat "$1") != "$2" ]]; then
    printf '%s\n' "$2" >"$1"
    changed=1
  fi
}

step "caddy: vercel DNS plugin"
# The plugin's last tag predates its libdns 1.0 fix, so `caddy add-package` fails. Build the same Caddy
# version with xcaddy, pinned to the fix commit. apt would drop the plugin, so caddy is held. To upgrade
# Caddy: apt-mark unhold caddy && apt upgrade caddy, then re-run this script.
VERCEL_PLUGIN=github.com/caddy-dns/vercel@90ab6e6ed7835757bc5caf78168456c461d54b74
if ! caddy list-modules | grep -qx dns.providers.vercel; then
  version=$(caddy version | cut -d' ' -f1)
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  echo "    building caddy $version with $(go version)"
  (cd "$tmp" && go run github.com/caddyserver/xcaddy/cmd/xcaddy@latest build "$version" --with "$VERCEL_PLUGIN" --output "$tmp/caddy")
  "$tmp/caddy" list-modules | grep -qx dns.providers.vercel || die "built caddy has no vercel plugin"
  install -m 0755 "$tmp/caddy" /usr/bin/caddy.new
  mv /usr/bin/caddy.new /usr/bin/caddy
  apt-mark hold caddy >/dev/null
  changed=1
fi

step "vercel token: $ENV_FILE"
if ! grep -q '^VERCEL_API_TOKEN=.' "$ENV_FILE" 2>/dev/null; then
  [[ -t 0 ]] || die "no VERCEL_API_TOKEN in $ENV_FILE. Run this in a terminal to be asked for one"
  read -rsp "Vercel API token (vercel.com/account/tokens): " token
  echo
  install -m 0600 /dev/null "$ENV_FILE"
  printf 'VERCEL_API_TOKEN=%s\n' "$token" >"$ENV_FILE"
  changed=1
fi
VERCEL_API_TOKEN=$(sed -n 's/^VERCEL_API_TOKEN=//p' "$ENV_FILE")

step "port: tailnet :443"
tailscale serve status --json | node -e '
  const s = JSON.parse(require("fs").readFileSync(0, "utf8") || "{}")
  process.exit((s.TCP || {})["443"] ? 1 : 0)
' || die "tailscale serve uses :443. Free it: tailscale funnel --https=443 off"

IP4=$(tailscale ip -4)
IP6=$(tailscale ip -6)

step "caddy: /etc/caddy/Caddyfile /etc/caddy/sites/$NAME.caddy $DROPIN"
grep -q 'caddy/setup.sh' /etc/caddy/Caddyfile 2>/dev/null || cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.orig 2>/dev/null || true
install -d /etc/caddy/sites "$(dirname "$DROPIN")"
put /etc/caddy/Caddyfile "$(sed "s|@TS_IPS@|$IP4 $IP6|" "$HERE/Caddyfile")"
put "/etc/caddy/sites/$NAME.caddy" "$(printf '%s {\n\timport tailnet\n\treverse_proxy %s\n}' "$HOST" "$UPSTREAM")"
if [[ ! -f $DROPIN ]] || [[ $(cat "$DROPIN") != "$(cat "$HERE/caddy.conf")" ]]; then
  cp "$HERE/caddy.conf" "$DROPIN"
  systemctl daemon-reload
  changed=1
fi
caddy validate --config /etc/caddy/Caddyfile >/dev/null || die "caddy config is invalid"
[[ $changed -eq 0 ]] || systemctl restart caddy

step "dns: $HOST -> $IP4 $IP6"
VERCEL_API_TOKEN=$VERCEL_API_TOKEN node --input-type=module -e '
  const [name, domain, ip4, ip6] = process.argv.slice(1)
  const api = async (path, method = "GET", body) => {
    const r = await fetch("https://api.vercel.com" + path, {
      method,
      headers: { Authorization: `Bearer ${process.env.VERCEL_API_TOKEN}`, "Content-Type": "application/json" },
      body: body && JSON.stringify(body),
    })
    if (!r.ok) throw new Error(`${method} ${path}: ${r.status} ${await r.text()}`)
    return r.json()
  }
  const { records } = await api(`/v4/domains/${domain}/records?limit=100`)
  for (const [type, value] of [["A", ip4], ["AAAA", ip6]]) {
    const old = records.find((r) => r.name === name && r.type === type)
    if (old?.value === value) console.log(`    ${type} ${value} (unchanged)`)
    else if (old) await api(`/v1/domains/records/${old.id}`, "PATCH", { value, ttl: 60 }).then(() => console.log(`    ${type} ${old.value} -> ${value}`))
    else await api(`/v2/domains/${domain}/records`, "POST", { name, type, value, ttl: 60 }).then(() => console.log(`    ${type} ${value} (added)`))
  }
' "$NAME" "$DOMAIN" "$IP4" "$IP6"

step "health check: https://$HOST"
for _ in $(seq 1 60); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --resolve "$HOST:443:$IP4" "https://$HOST/" 2>/dev/null || true)
  [[ $code =~ ^[2-5] ]] && break
  sleep 2
done
# Any HTTP answer (even 502 before the first deploy) means DNS and the cert work.
[[ $code =~ ^[2-5] ]] || die "https://$HOST did not answer (cert not issued yet?). See journalctl -u caddy"
echo "    https://$HOST answers ($code)"

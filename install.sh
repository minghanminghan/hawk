#!/usr/bin/env bash
# Installs or updates hawk on the mini PC. Run as root from a checkout; safe to re-run:
#   git pull && sudo ./install.sh
# Copies the checkout to /opt/hawk, links /usr/local/bin/hawk, creates hawk-runner, installs the
# heartbeat timer, the OnFailure alert unit and gatus (status page for every app in apps/), and serves
# https://status.<domain> to the tailnet. Asks for the ntfy topic and healthchecks.io URL once.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HAWK=/opt/hawk
ETC=/etc/hawk
DOMAIN=${DOMAIN:-andrewminghanjiang.com}
GATUS_VERSION=v5.38.0
GATUS_PORT=3400

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "run as root (sudo $0)"
for cmd in systemctl tailscale go node caddy curl rsync visudo useradd; do
  command -v "$cmd" >/dev/null || die "$cmd not found"
done

step "ports: apps/*.env"
dupes=$( (echo "PORT=$GATUS_PORT"; cat "$HERE"/apps/*.env) | sed -n 's/^PORT=//p' | sort | uniq -d)
[[ -z $dupes ]] || die "port used twice in apps/*.env (or by gatus): $dupes"

step "files: $HAWK, /usr/local/bin/hawk"
rsync -a --delete --exclude .git "$HERE/" "$HAWK/"
chown -R root:root "$HAWK"
ln -sfn "$HAWK/bin/hawk" /usr/local/bin/hawk

step "config: $ETC/hawk.env"
install -d -m 0755 "$ETC"
if [[ ! -f $ETC/hawk.env ]]; then
  [[ -t 0 ]] || die "no $ETC/hawk.env. Run this in a terminal to be asked for its values"
  read -rp "ntfy topic (a long random name; subscribe to it in the ntfy app): " topic
  read -rp "healthchecks.io ping URL (https://hc-ping.com/<uuid>): " hc
  install -m 0600 /dev/null "$ETC/hawk.env"
  printf 'NTFY_TOPIC=%s\nHC_PING_URL=%s\n' "$topic" "$hc" >"$ETC/hawk.env"
fi

step "user: hawk-runner"
if ! id -u hawk-runner >/dev/null 2>&1; then
  useradd --system --user-group --create-home --home-dir /home/hawk-runner --shell /bin/bash hawk-runner
fi

step "gatus: $GATUS_VERSION"
restart_gatus=0
if [[ $(go version -m /usr/local/bin/gatus 2>/dev/null | awk '$1 == "mod" { print $3 }') != "$GATUS_VERSION" ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  GOBIN=/usr/local/bin GOPATH=$tmp/go GOCACHE=$tmp/cache go install "github.com/TwiN/gatus/v5@$GATUS_VERSION"
  restart_gatus=1
fi
config=$(
  cat <<EOF
# Made by hawk's install.sh from apps/*.env. Do not edit.
web:
  address: 127.0.0.1
  port: $GATUS_PORT
storage:
  type: sqlite
  path: /var/lib/gatus/data.db
ui:
  title: hawk
  dashboard-heading: $(hostname)
alerting:
  ntfy:
    topic: "\${NTFY_TOPIC}"
    click: https://status.$DOMAIN
    default-alert:
      failure-threshold: 3
      send-on-resolved: true
endpoints:
EOF
  for f in "$HERE"/apps/*.env; do
    app=$(basename "$f" .env)
    health=$(sed -n 's/^HEALTH=//p' "$f")
    cat <<EOF
  - name: $app
    url: https://$app.$DOMAIN$health
    interval: 1m
    conditions:
      - "[STATUS] == 200"
      - "[RESPONSE_TIME] < 2000"
      - "[CERTIFICATE_EXPIRATION] > 168h"
    alerts:
      - type: ntfy
EOF
  done
)
if [[ $(cat "$ETC/gatus.yaml" 2>/dev/null) != "$config" ]]; then
  printf '%s\n' "$config" >"$ETC/gatus.yaml"
  restart_gatus=1
fi

step "systemd: $(cd "$HERE/systemd" && ls | xargs)"
reload=0
for f in "$HERE"/systemd/*; do
  dest=/etc/systemd/system/$(basename "$f")
  if [[ ! -f $dest ]] || ! cmp -s "$f" "$dest"; then
    cp "$f" "$dest"
    reload=1
    if [[ $(basename "$f") == gatus.service ]]; then restart_gatus=1; fi
  fi
done
((reload == 0)) || systemctl daemon-reload
systemctl enable --now hawk-heartbeat.timer >/dev/null
systemctl enable gatus >/dev/null
if ((restart_gatus)) || ! systemctl is-active --quiet gatus; then systemctl restart gatus; fi
systemctl is-active --quiet gatus || die "gatus did not start. See journalctl -u gatus"

"$HAWK/caddy/setup.sh" status "127.0.0.1:$GATUS_PORT"

cat <<EOF

Done. Status page: https://status.$DOMAIN
Test the alerts:  sudo hawk notify "hello from hawk"  &&  sudo systemctl start hawk-heartbeat

Next, for each app:
  sudo hawk runner https://github.com/<owner>/<repo> <token>   # one per repo until they share an org
    token: gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token -q .token
  sudo hawk setup <app> [checkout]
EOF

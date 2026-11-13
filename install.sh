#!/usr/bin/env bash
# Installs or updates hawk on the mini PC. Run as root from a checkout; safe to re-run:
#   git pull && sudo ./install.sh
# Copies the checkout to /opt/hawk, links /usr/local/bin/hawk, creates hawk-runner, installs the
# heartbeat timer, the OnFailure alert unit, gatus (uptime page for every app in apps/), the hawk
# status page and an MLflow server on its own 10G volume, and serves https://status.<domain>,
# https://hawk.<domain> and https://mlflow.<domain> to the tailnet. Alerts are
# emails through Resend. The first run takes /etc/hawk/hawk.env from ./hawk.env (git-ignored) if it
# exists, or asks for its values.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HAWK=/opt/hawk
ETC=/etc/hawk
DOMAIN=${DOMAIN:-andrewminghanjiang.com}
GATUS_VERSION=v5.38.0
GATUS_PORT=3400
MLFLOW_VERSION=3.18.0
MLFLOW_PORT=3401
MLFLOW_DATA=/var/lib/mlflow

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "run as root (sudo $0)"
for cmd in systemctl tailscale go node caddy curl jq rsync visudo useradd git flock uv findmnt blkid; do
  command -v "$cmd" >/dev/null || die "$cmd not found"
done

step "ports: apps/*.env"
dupes=$( (echo "PORT=$GATUS_PORT"; echo "PORT=$MLFLOW_PORT"; cat "$HERE"/apps/*.env) | sed -n 's/^PORT=//p' | sort | uniq -d)
[[ -z $dupes ]] || die "port used twice in apps/*.env (or by gatus/mlflow): $dupes"

step "files: $HAWK, /usr/local/bin/hawk"
rsync -a --delete --exclude .git --exclude hawk.env --exclude node_modules "$HERE/" "$HAWK/"
git -c safe.directory="$HERE" -C "$HERE" rev-parse HEAD >"$HAWK/COMMIT" 2>/dev/null || echo unknown >"$HAWK/COMMIT"
chown -R root:root "$HAWK"
ln -sfn "$HAWK/bin/hawk" /usr/local/bin/hawk

# hawk-update deploys GitHub main (pnpm ship runs it). The user who ran sudo may run it with no password.
step "ship: /usr/local/sbin/hawk-update"
install -o root -g root -m 0755 "$HERE/bin/hawk-update" /usr/local/sbin/hawk-update
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
  rule="$SUDO_USER ALL=(root) NOPASSWD: /usr/local/sbin/hawk-update \"\""
  if [[ $(cat /etc/sudoers.d/hawk-update 2>/dev/null) != "$rule" ]]; then
    printf '%s\n' "$rule" >/etc/sudoers.d/hawk-update.tmp
    visudo -cqf /etc/sudoers.d/hawk-update.tmp || { rm -f /etc/sudoers.d/hawk-update.tmp; die "bad sudoers rule"; }
    chmod 0440 /etc/sudoers.d/hawk-update.tmp
    mv /etc/sudoers.d/hawk-update.tmp /etc/sudoers.d/hawk-update
  fi
fi

step "config: $ETC/hawk.env"
install -d -m 0755 "$ETC"
if [[ ! -f $ETC/hawk.env ]]; then
  [[ -t 0 ]] || die "no $ETC/hawk.env. Run this in a terminal to be asked for its values"
  if [[ -f $HERE/hawk.env ]]; then
    install -m 0600 "$HERE/hawk.env" "$ETC/hawk.env"
  else
    [[ -t 0 ]] || die "no $ETC/hawk.env. Run this in a terminal to be asked for its values"
    read -rsp "Resend API key: " key
    echo
    read -rp "Email from (a verified Resend domain, e.g. hawk <hawk@$DOMAIN>): " from
    read -rp "Email to: " to
    read -rp "healthchecks.io ping URL (https://hc-ping.com/<uuid>): " hc
    install -m 0600 /dev/null "$ETC/hawk.env"
    printf "RESEND_API_KEY=%s\nEMAIL_FROM='%s'\nEMAIL_TO=%s\nHC_PING_URL=%s\n" "$key" "$from" "$to" "$hc" >"$ETC/hawk.env"
  fi
fi
for key in RESEND_API_KEY EMAIL_FROM EMAIL_TO HC_PING_URL; do
  grep -q "^$key=." "$ETC/hawk.env" || die "no $key in $ETC/hawk.env. Fix it: sudo -e $ETC/hawk.env"
done

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
  resend:
    api-key: "\${RESEND_API_KEY}"
    from: "\${EMAIL_FROM}"
    to: "\${EMAIL_TO}"
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
      - type: resend
EOF
  done
  cat <<EOF
  - name: mlflow
    url: https://mlflow.$DOMAIN/health
    interval: 1m
    conditions:
      - "[STATUS] == 200"
      - "[RESPONSE_TIME] < 2000"
      - "[CERTIFICATE_EXPIRATION] > 168h"
    alerts:
      - type: resend
EOF
)
if [[ $(cat "$ETC/gatus.yaml" 2>/dev/null) != "$config" ]]; then
  printf '%s\n' "$config" >"$ETC/gatus.yaml"
  restart_gatus=1
fi

# MLflow data is its own 10G ext4 fs, so a full store cannot fill /. An LV when ubuntu-vg has room,
# else a loop image. Formats only a device with no filesystem on it; never prompts.
step "mlflow: $MLFLOW_VERSION, $MLFLOW_DATA (10G)"
restart_mlflow=0
id -u mlflow >/dev/null 2>&1 || useradd --system --user-group --no-create-home --home-dir "$MLFLOW_DATA" --shell /usr/sbin/nologin mlflow
if ! findmnt -n "$MLFLOW_DATA" >/dev/null; then
  opts=defaults,nofail
  vg_free=$(vgs --noheadings --units g --nosuffix -o vg_free ubuntu-vg 2>/dev/null | awk '{printf "%d", $1}')
  if [[ -e /dev/ubuntu-vg/mlflow ]]; then
    dev=/dev/ubuntu-vg/mlflow
  elif [[ -e /var/lib/mlflow.img ]]; then
    dev=/var/lib/mlflow.img opts+=,loop
  elif ((${vg_free:-0} >= 10)); then
    lvcreate -q -y -L 10G -n mlflow ubuntu-vg >/dev/null
    dev=/dev/ubuntu-vg/mlflow
  else
    fallocate -l 10G /var/lib/mlflow.img
    dev=/var/lib/mlflow.img opts+=,loop
  fi
  [[ -n $(blkid -o value -s TYPE "$dev" 2>/dev/null) ]] || mkfs.ext4 -q -F "$dev"
  if ! awk -v m="$MLFLOW_DATA" '$1 !~ /^#/ && $2 == m { f = 1 } END { exit !f }' /etc/fstab; then
    printf '%s %s ext4 %s 0 2\n' "$dev" "$MLFLOW_DATA" "$opts" >>/etc/fstab
    systemctl daemon-reload
  fi
  mkdir -p "$MLFLOW_DATA"
  mount "$MLFLOW_DATA"
fi
install -d -o mlflow -g mlflow -m 0750 "$MLFLOW_DATA" "$MLFLOW_DATA/artifacts" /var/backups/mlflow
if [[ $(/opt/mlflow/bin/python -c 'import importlib.metadata as m; print(m.version("mlflow"))' 2>/dev/null) != "$MLFLOW_VERSION" ]]; then
  [[ -x /opt/mlflow/bin/python ]] || uv venv -q --python /usr/bin/python3.12 /opt/mlflow
  uv pip install -q --python /opt/mlflow/bin/python "mlflow==$MLFLOW_VERSION"
  restart_mlflow=1
fi

step "systemd: $(cd "$HERE/systemd" && ls | xargs)"
reload=0
for f in "$HERE"/systemd/*; do
  dest=/etc/systemd/system/$(basename "$f")
  if [[ ! -f $dest ]] || ! cmp -s "$f" "$dest"; then
    cp "$f" "$dest"
    reload=1
    if [[ $(basename "$f") == gatus.service ]]; then restart_gatus=1; fi
    if [[ $(basename "$f") == mlflow.service ]]; then restart_mlflow=1; fi
  fi
done
((reload == 0)) || systemctl daemon-reload
systemctl enable --now hawk-heartbeat.timer >/dev/null
systemctl enable --now hawk-status.timer >/dev/null
systemctl enable --now mlflow-backup.timer >/dev/null
systemctl start hawk-status
systemctl enable gatus >/dev/null
if ((restart_gatus)) || ! systemctl is-active --quiet gatus; then systemctl restart gatus; fi
systemctl is-active --quiet gatus || die "gatus did not start. See journalctl -u gatus"
systemctl enable mlflow >/dev/null
if ((restart_mlflow)) || ! systemctl is-active --quiet mlflow; then systemctl restart mlflow; fi
for _ in $(seq 1 60); do curl -fsS -m 2 "http://127.0.0.1:$MLFLOW_PORT/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS -m 2 "http://127.0.0.1:$MLFLOW_PORT/health" >/dev/null 2>&1 || die "mlflow did not start. See journalctl -u mlflow"

"$HAWK/caddy/setup.sh" status "127.0.0.1:$GATUS_PORT"
"$HAWK/caddy/setup.sh" hawk /var/lib/hawk-status
"$HAWK/caddy/setup.sh" mlflow "127.0.0.1:$MLFLOW_PORT"

cat <<EOF

Done. Status pages: https://hawk.$DOMAIN (deploys) and https://status.$DOMAIN (uptime). MLflow: https://mlflow.$DOMAIN
Test the alerts:  sudo hawk notify "hello from hawk"  &&  sudo systemctl start hawk-heartbeat

Next, for each app:
  sudo hawk runner https://github.com/<owner>/<repo> <token>   # one per repo until they share an org
    token: gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token -q .token
  sudo hawk setup <app> [checkout]
EOF

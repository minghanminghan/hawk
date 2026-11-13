#!/usr/bin/env bash
# Ships the current branch end to end: pnpm ship [--task HAWK-12]
# check → push → pr → ci → merge → box → verify → task → sync.
# box runs `sudo hawk-update` on the mini PC: hawk goes to main, and `hawk setup` re-runs for each app.
# Safe to re-run: each step asks git/GitHub/the box whether it is done and skips if so.
# On failure prints `SHIP FAILED at <step>`, the command, a hint, the rerun command, then the
# command's error, and exits with that command's exit code.
set -uo pipefail

REPO=minghanminghan/hawk
SERVER=andrewj@andrewsserver
TITLE_RE='^(feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert)(\([a-z0-9-]+\))?!?: .+'
SHELL_FILES=(bin/hawk bin/hawk-update install.sh caddy/setup.sh scripts/ship.sh)
TOTAL=9

TASK=
while (($#)); do
  case $1 in
    --task) TASK=${2:-}; shift 2 || shift ;;
    --task=*) TASK=${1#*=}; shift ;;
    *) echo "usage: pnpm ship [--task HAWK-12]" >&2; exit 1 ;;
  esac
done
RERUN="pnpm ship${TASK:+ --task $TASK}"

ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT
STEP='' HINT='' N=0 OUT=''

step() { STEP=$1 HINT='' N=$((N + 1)); echo "==> [$N/$TOTAL] $1"; }
say() { echo "    $*"; }

# fail <exit code> <command> <error text>
fail() {
  {
    echo
    echo "SHIP FAILED at $STEP"
    echo "cmd: $2"
    if [[ -n $HINT ]]; then echo "hint: $HINT"; fi
    echo "rerun: $RERUN"
    echo "---"
    printf '%s\n' "$3" | tail -n 50
  } >&2
  exit "$1"
}

# Runs a command and keeps its stdout in $OUT. On failure reports it and exits with its code.
run() {
  OUT=$("$@" 2>"$ERR")
  local rc=$?
  local text=$OUT
  [[ -s $ERR ]] && text+=${text:+$'\n'}$(cat "$ERR")
  if ((rc != 0)); then fail "$rc" "$*" "$text"; fi
}

run_id() { [[ $1 =~ /runs/([0-9]+) ]] && echo "${BASH_REMATCH[1]}"; }

failed_log() { gh run view "$1" -R "$REPO" --log-failed 2>&1 | cut -c1-300 | tail -n 50; }

load_pr() {
  run gh pr list -R "$REPO" --head "$BRANCH" --state all --limit 1 \
    --json number,state,title,url,mergeCommit --jq '.[0] // empty'
  PR_JSON=$OUT
  PR=$(jaq -r '.number // empty' <<<"$PR_JSON")
  PR_STATE=$(jaq -r '.state // empty' <<<"$PR_JSON")
  PR_URL=$(jaq -r '.url // empty' <<<"$PR_JSON")
}

# ---------------------------------------------------------------------------
step check
BRANCH=$(git branch --show-current)
if [[ -z $BRANCH || $BRANCH == main ]]; then
  HINT="ship runs on a feature branch. Commit your work on one first"
  fail 1 "git branch --show-current" "current branch: ${BRANCH:-detached HEAD}"
fi
dirty=$(git status --porcelain)
if [[ -n $dirty ]]; then
  HINT="commit or stash these files first"
  fail 1 "git status --porcelain" "$dirty"
fi
HINT="sign in with: gh auth login"
run gh auth status -h github.com
if [[ -n $TASK ]]; then
  HINT="check the task key, or run without --task"
  run sparrow show "$TASK" --json
  TASK=$(jaq -r .id <<<"$OUT")
fi
HINT=
run git fetch -q origin main
git fetch -q origin "$BRANCH" 2>/dev/null
load_pr
if [[ $PR_STATE == CLOSED ]]; then
  HINT="the PR was closed without a merge. Reopen it: gh pr reopen $PR"
  fail 1 "gh pr list --head $BRANCH" "PR #$PR is closed: $PR_URL"
fi
MERGED=false
[[ $PR_STATE == MERGED ]] && MERGED=true

if $MERGED; then
  say "PR #$PR already merged, skipping local checks"
else
  run git log --format=%s origin/main..HEAD
  if [[ -z $OUT ]]; then
    HINT="commit your work first"
    fail 1 "git log origin/main..HEAD" "branch $BRANCH has no commits ahead of origin/main"
  fi
  if [[ -n $PR ]]; then
    TITLE=$(jaq -r .title <<<"$PR_JSON")
    HINT="fix it with: gh pr edit $PR --title 'type(scope): summary'"
  else
    TITLE=$(tail -n1 <<<"$OUT")
    HINT="the PR title comes from the branch's first commit. Reword that commit, or open the PR yourself: gh pr create --title 'type(scope): summary', then rerun"
  fi
  if ! grep -Eq "$TITLE_RE" <<<"$TITLE"; then
    fail 1 "title check" "not a conventional commit: $TITLE"$'\n'"must match: $TITLE_RE"
  fi
  HINT="rebase on main and fix the conflicts: git rebase origin/main"
  run git merge-tree --write-tree --name-only --no-messages origin/main HEAD
  if command -v shellcheck >/dev/null; then
    HINT="fix the errors, commit, then rerun"
    run shellcheck "${SHELL_FILES[@]}"
    say "title, conflicts, shellcheck ok"
  else
    say "title, conflicts ok (no local shellcheck; CI runs it)"
  fi
fi

# ---------------------------------------------------------------------------
step push
if $MERGED; then
  say "skipped (merged)"
elif [[ $(git rev-parse HEAD) == $(git rev-parse -q --verify "origin/$BRANCH") ]]; then
  say "origin/$BRANCH is up to date"
else
  HINT="if the push was rejected after a rebase, run: git push --force-with-lease, then rerun"
  run git push -q -u origin HEAD
  say "pushed $BRANCH"
fi

# ---------------------------------------------------------------------------
step pr
if [[ -z $PR ]]; then
  body=$(git log --reverse --format='- %s' origin/main..HEAD)
  [[ -n $TASK ]] && body="Task: $TASK"$'\n\n'"$body"
  run gh pr create -R "$REPO" --head "$BRANCH" --base main --title "$TITLE" --body "$body"
  load_pr
  say "opened #$PR $PR_URL"
else
  say "#$PR $PR_URL ($PR_STATE)"
fi

# ---------------------------------------------------------------------------
# Waits for the PR's checks to finish. Fails with the failed job's log.
wait_ci() {
  local start=$SECONDS json pending failed link
  while :; do
    json=$(gh pr checks "$PR" -R "$REPO" --json name,bucket,link 2>/dev/null)
    [[ -z $json ]] && json='[]'
    if [[ $(jaq length <<<"$json") == 0 ]]; then
      if ((SECONDS - start > 60)); then
        HINT="no CI run started for 60s. See: gh run list -R $REPO --branch $BRANCH"
        fail 1 "gh pr checks $PR" "no checks reported on the '$BRANCH' branch"
      fi
    else
      failed=$(jaq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | join(", ")' <<<"$json")
      if [[ -n $failed ]]; then
        link=$(jaq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel")][0].link' <<<"$json")
        HINT="fix the code, commit, then rerun. Full log: $link"
        fail 1 "gh pr checks $PR" "failed: $failed"$'\n'"$(failed_log "$(run_id "$link")")"
      fi
      pending=$(jaq '[.[] | select(.bucket == "pending")] | length' <<<"$json")
      if [[ $pending == 0 ]]; then return; fi
    fi
    if ((SECONDS - start > 1200)); then
      HINT="CI ran for over 20 min. See: gh pr checks $PR"
      fail 1 "gh pr checks $PR" "$json"
    fi
    sleep 10
  done
}

step ci
if $MERGED; then
  say "skipped (merged)"
else
  wait_ci
  say "checks passed"
fi

# ---------------------------------------------------------------------------
step merge
if $MERGED; then
  say "skipped (merged)"
else
  for _ in 1 2 3; do
    for _ in $(seq 1 15); do
      run gh pr view "$PR" -R "$REPO" --json mergeStateStatus --jq .mergeStateStatus
      [[ $OUT != UNKNOWN && $OUT != BLOCKED ]] && break
      sleep 2
    done
    [[ $OUT != BEHIND ]] && break
    say "branch is behind main, updating it"
    run gh pr update-branch "$PR" -R "$REPO"
    sleep 5
    wait_ci
  done
  case $OUT in
    CLEAN | UNSTABLE | HAS_HOOKS) ;;
    DIRTY) HINT="rebase on main and fix the conflicts: git rebase origin/main, then rerun"
      fail 1 "gh pr view $PR --json mergeStateStatus" "PR #$PR has merge conflicts (DIRTY)" ;;
    *) HINT="see why: gh pr view $PR --json mergeStateStatus,reviewDecision,statusCheckRollup"
      fail 1 "gh pr view $PR --json mergeStateStatus" "PR #$PR cannot merge: $OUT" ;;
  esac
  run gh pr merge "$PR" -R "$REPO" --squash
  load_pr
  say "merged #$PR"
fi
SHA=$(jaq -r '.mergeCommit.oid // empty' <<<"$PR_JSON")
if [[ -z $SHA ]]; then
  fail 1 "gh pr list --head $BRANCH --json mergeCommit" "PR #$PR has no merge commit"
fi
run git fetch -q origin main

# True when the box runs $SHA or a later main commit.
box_has_sha() {
  BOX=$(ssh "$SERVER" 'cat /opt/hawk/COMMIT 2>/dev/null')
  [[ -n $BOX ]] && git cat-file -e "$BOX^{commit}" 2>/dev/null && git merge-base --is-ancestor "$SHA" "$BOX"
}

# ---------------------------------------------------------------------------
step box
if box_has_sha; then
  say "box already runs ${BOX:0:7}"
else
  HINT="if sudo asks for a password, hawk-update is not set up yet. Once: pnpm box:install, then rerun"
  # Not through run(): the output streams so a Tailscale SSH check link shows up.
  ssh "$SERVER" sudo -n /usr/local/sbin/hawk-update 2>&1 | tee "$ERR" | sed 's/^/    /'
  rc=${PIPESTATUS[0]}
  ((rc == 0)) || fail "$rc" "ssh $SERVER sudo -n /usr/local/sbin/hawk-update" "$(cat "$ERR")"
fi

# ---------------------------------------------------------------------------
step verify
HINT="see the box: ssh $SERVER 'cat /opt/hawk/COMMIT; systemctl --failed'"
if ! box_has_sha; then
  fail 1 "ssh $SERVER cat /opt/hawk/COMMIT" "box runs '${BOX:-nothing}', expected $SHA or later"
fi
# shellcheck disable=SC2016
run ssh "$SERVER" 'bad=; for f in /opt/hawk/apps/*.env; do . "$f"; [ -e "/opt/$(basename "$f" .env)/current" ] || continue;
  for u in $SERVICES; do systemctl is-active -q "$u" || bad="$bad $u"; done; done
  for u in gatus mlflow caddy hawk-status.timer hawk-heartbeat.timer; do systemctl is-active -q "$u" || bad="$bad $u"; done
  [ -z "$bad" ] || { echo "not active:$bad"; exit 1; }'
say "box runs ${BOX:0:7}; all services active"

# ---------------------------------------------------------------------------
step task
if [[ -z $TASK ]]; then
  say "skipped (no --task)"
else
  HINT="check the task: sparrow show $TASK"
  run sparrow show "$TASK" --json
  if jaq -e --arg u "$PR_URL" 'any(.comments[]; .body | contains($u))' <<<"$OUT" >/dev/null; then
    say "$TASK already has a comment for this PR"
  else
    run sparrow comment "$TASK" --body "Shipped in PR #$PR $PR_URL. The box runs ${SHA:0:7}; hawk setup re-ran for each app."
    say "commented on $TASK"
  fi
  run sparrow update "$TASK" --status 'done'
  say "$TASK is done"
fi

# ---------------------------------------------------------------------------
step sync
HINT="you can finish this by hand: git switch main (or git switch --detach origin/main in a worktree) && git branch -D $BRANCH"
# In a worktree, main is checked out elsewhere, so detach at origin/main instead.
if git switch -q main 2>/dev/null; then run git pull -q --ff-only; else run git switch -q --detach origin/main; fi
run git branch -D "$BRANCH"
if [[ -n $(git ls-remote --heads origin "$BRANCH") ]]; then run git push -q origin --delete "$BRANCH"; fi
say "on $(git branch --show-current | grep . || echo 'detached origin/main') at $(git log --oneline -1)"

echo
echo "SHIPPED #$PR${TASK:+ ($TASK done)}"

#!/usr/bin/env bash
# tower coordinator — the ONLY writer of the state branch.
# Serialization is guaranteed by the caller workflow's `concurrency: tower` group;
# the push-retry below is belt-and-braces only.
set -euo pipefail

REPO="${GITHUB_REPOSITORY}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { echo "::notice::tower: $*"; }

# ---------------------------------------------------------------- state clone
clone_state() {
  git init -q "$WORK/state"
  cd "$WORK/state"
  git config user.name "tower-bot"
  git config user.email "tower-bot@users.noreply.github.com"
  git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"
  if git fetch -q --depth 1 origin "$STATE_BRANCH" 2>/dev/null; then
    git checkout -q -b "$STATE_BRANCH" FETCH_HEAD
  else
    log "state branch missing — seeding $STATE_BRANCH"
    git checkout -q --orphan "$STATE_BRANCH"
    mkdir -p state
    echo '{"version":1,"leases":[]}' > state/leases.json
    echo '{"actors":{}}' > state/activity.json
  fi
  mkdir -p state
  [ -f state/leases.json ]   || echo '{"version":1,"leases":[]}' > state/leases.json
  [ -f state/activity.json ] || echo '{"actors":{}}' > state/activity.json
}

commit_state() {
  cd "$WORK/state"
  render_status
  git add -A
  git diff --cached --quiet && { log "no state change"; return 0; }
  git commit -q -m "$1"
  for attempt in 1 2 3; do
    git push -q origin "$STATE_BRANCH" && return 0
    log "push rejected (attempt $attempt) — rebasing"
    git fetch -q origin "$STATE_BRANCH" && git rebase -q FETCH_HEAD
  done
  echo "::error::tower: failed to push state after 3 attempts" && return 1
}

# ---------------------------------------------------------------- rendering
render_status() {
  {
    echo "# 🗼 Tower STATUS — ${REPO}"
    echo ""
    echo "_Rendered ${NOW} by the coordinator. Read this before editing anything._"
    echo ""
    echo "## Active actors"
    echo ""
    echo "| Actor | Type | Last seen | Task | Branch |"
    echo "|---|---|---|---|---|"
    jq -r '.actors | to_entries[] |
      "| \(.key) | \(.value.type) | \(.value.last_seen) | \(.value.task // "—") | \(.value.branch // "—") |"' \
      state/activity.json
    echo ""
    echo "## Active leases"
    echo ""
    echo "| Actor | Task | Mode | Paths | Expires |"
    echo "|---|---|---|---|---|"
    jq -r '.leases[] |
      "| \(.actor) | #\(.task) | \(.mode) | \(.paths | join(", ")) | \(.expires_at) |"' \
      state/leases.json
    echo ""
    echo "> Protocol: https://github.com/isobed18/gh-tower/blob/main/docs/PROTOCOL.md"
  } > STATUS.md
}

# ---------------------------------------------------------------- gh helpers
comment() { # comment <issue#> <body>
  gh api "repos/${REPO}/issues/$1/comments" -f body="$2" --silent
}

expiry() { date -u -d "+${LEASE_TTL_MIN} minutes" +%Y-%m-%dT%H:%M:%SZ; }

paths_to_json() { # stdin: comma-separated paths -> compact JSON array (safe on empty input)
  tr -d '\r' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF' \
    | jq -R . | jq -sc .
}

issue_paths() { # extract "Paths: a, b" line from issue body
  local line
  line="$(gh api "repos/${REPO}/issues/$1" --jq '.body // ""' | grep -im1 '^paths:' || true)"
  [ -z "$line" ] && { echo '[]'; return; }
  echo "$line" | sed 's/^[Pp]aths:[[:space:]]*//' | paths_to_json
}

touch_activity() { # touch_activity <actor> <type> <task|null> <branch|null> <source>
  jq --arg a "$1" --arg t "$2" --argjson task "$3" --arg br "$4" --arg src "$5" --arg now "$NOW" \
    '.actors[$a] = {type:$t, last_seen:$now, task:$task, branch:(if $br=="" then null else $br end), source:$src}' \
    state/activity.json > state/activity.json.tmp && mv state/activity.json.tmp state/activity.json
}

drop_lease() { # drop_lease <actor>
  jq --arg a "$1" '.leases |= map(select(.actor != $a))' \
    state/leases.json > state/leases.json.tmp && mv state/leases.json.tmp state/leases.json
}

add_lease() { # add_lease <actor> <type> <task> <branch> <pathsJson>
  local id; id="lease-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  jq --arg id "$id" --arg a "$1" --arg t "$2" --argjson task "$3" --arg br "$4" \
     --argjson paths "$5" --arg now "$NOW" --arg exp "$(expiry)" \
    '.leases += [{id:$id, actor:$a, actor_type:$t, task:$task, branch:$br,
                  paths:$paths, mode:"advisory", acquired_at:$now, expires_at:$exp, renewals:0}]' \
    state/leases.json > state/leases.json.tmp && mv state/leases.json.tmp state/leases.json
}

overlap_warning() { # overlap_warning <actor> <pathsJson> -> prints colliding "actor:path" lines
  jq -r --arg me "$1" --argjson mine "$2" \
    '.leases[] | select(.actor != $me) as $l | $l.paths[] as $p
     | select(($mine | index($p)) != null) | "\($l.actor) also holds \($p) (task #\($l.task))"' \
    state/leases.json
}

# ---------------------------------------------------------------- commands
cmd_claim() { # <actor> <type> <issue> <pathsJson>
  local actor="$1" type="$2" issue="$3" paths="$4"
  local assignees
  assignees="$(gh api "repos/${REPO}/issues/${issue}" --jq '[.assignees[].login] | join(",")')"
  if [ -n "$assignees" ] && [ "$assignees" != "$actor" ]; then
    comment "$issue" "🗼 \`/claim\` denied — already claimed by **${assignees}**. Pick another Ready task, or ask for \`/handoff\`."
    return 0
  fi
  gh api -X POST "repos/${REPO}/issues/${issue}/assignees" -f "assignees[]=${actor}" --silent || true
  local slug branch
  slug="$(gh api "repos/${REPO}/issues/${issue}" --jq '.title' \
        | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g;s/^-\|-$//g' | cut -c1-30)"
  branch="${actor}/${issue}-${slug}"
  drop_lease "$actor"                      # one lease per actor: replace
  add_lease "$actor" "$type" "$issue" "$branch" "$paths"
  touch_activity "$actor" "$type" "$issue" "$branch" "claim"
  local warn body
  warn="$(overlap_warning "$actor" "$paths" || true)"
  body="🗼 **Claimed by @${actor}** — lease acquired ($(echo "$paths" | jq -r 'join(", ") | if .=="" then "no paths declared" else . end'), TTL ${LEASE_TTL_MIN}m).
Branch: \`${branch}\`"
  [ -n "$warn" ] && body="$body

⚠️ **Advisory overlap:**
$warn
Wound-wait applies: the earlier claim wins if diffs collide."
  comment "$issue" "$body"
}

cmd_release() { # <actor> <issue> <note>
  drop_lease "$1"
  jq --arg a "$1" --arg now "$NOW" \
    '.actors[$a].task = null | .actors[$a].branch = null | .actors[$a].last_seen = $now' \
    state/activity.json > state/activity.json.tmp && mv state/activity.json.tmp state/activity.json
  gh api -X DELETE "repos/${REPO}/issues/$2/assignees" -f "assignees[]=$1" --silent || true
  comment "$2" "🗼 Released by @$1. ${3:-"(no context note left — next claimant starts cold)"}"
}

cmd_heartbeat() { # <actor> <type> <issue|null>
  touch_activity "$1" "$2" "${3:-null}" "" "heartbeat"
  jq --arg a "$1" --arg exp "$(expiry)" \
    '.leases |= map(if .actor == $a then .expires_at = $exp | .renewals += 1 else . end)' \
    state/leases.json > state/leases.json.tmp && mv state/leases.json.tmp state/leases.json
}

cmd_status() { # <issue>
  render_status
  comment "$1" "$(cat STATUS.md)"
}

reap() {
  # expired leases → notify + drop
  jq -c --arg now "$NOW" '.leases[] | select(.expires_at < $now)' state/leases.json |
  while read -r lease; do
    local_task="$(echo "$lease" | jq -r .task)"
    local_actor="$(echo "$lease" | jq -r .actor)"
    comment "$local_task" "🗼 ⏰ Lease of @${local_actor} **expired** and was reaped. Heartbeat to renew, or the task returns to Ready on the stale sweep." || true
  done
  jq --arg now "$NOW" '.leases |= map(select(.expires_at >= $now))' \
    state/leases.json > state/leases.json.tmp && mv state/leases.json.tmp state/leases.json

  # stale actors holding tasks → unassign + reset
  jq -r --arg now "$NOW" --argjson hm "$HUMAN_STALE_MIN" --argjson am "$AGENT_STALE_MIN" '
    .actors | to_entries[] | select(.value.task != null) |
    select( (($now | fromdateiso8601) - (.value.last_seen | fromdateiso8601)) >
            (if .value.type == "agent" then $am*60 else $hm*60 end) ) |
    "\(.key) \(.value.task)"' state/activity.json |
  while read -r actor task; do
    gh api -X DELETE "repos/${REPO}/issues/${task}/assignees" -f "assignees[]=${actor}" --silent || true
    comment "$task" "🗼 ♻️ @${actor} went silent — task **reclaimed** and back to Ready. Anyone may \`/claim\`." || true
    jq --arg a "$actor" '.actors[$a].task = null | .actors[$a].branch = null' \
      state/activity.json > state/activity.json.tmp && mv state/activity.json.tmp state/activity.json
    drop_lease "$actor"
  done
}

# ---------------------------------------------------------------- entrypoint
clone_state

if [ "$MODE" = "reap" ]; then
  reap
  commit_state "reap @ ${NOW}"
  exit 0
fi

EVENT="${GITHUB_EVENT_PATH}"
if [ "${GITHUB_EVENT_NAME}" = "issue_comment" ]; then
  BODY="$(jq -r '.comment.body' "$EVENT")"
  ACTOR="$(jq -r '.comment.user.login' "$EVENT")"
  UTYPE="$(jq -r '.comment.user.type' "$EVENT")"
  ISSUE="$(jq -r '.issue.number' "$EVENT")"
  TYPE="human"; [ "$UTYPE" = "Bot" ] && TYPE="agent"
  FIRST="$(echo "$BODY" | head -n1 | tr -d '\r')"
  VERB="$(echo "$FIRST" | awk '{print $1}')"
  ARGS="$(echo "$FIRST" | cut -s -d' ' -f2-)"
  case "$VERB" in
    /claim)
      PATHS="$(echo "$ARGS" | paths_to_json)"
      [ "$PATHS" = "[]" ] && PATHS="$(issue_paths "$ISSUE")"
      cmd_claim "$ACTOR" "$TYPE" "$ISSUE" "$PATHS" ;;
    /release)  cmd_release "$ACTOR" "$ISSUE" "$ARGS" ;;
    /heartbeat) cmd_heartbeat "$ACTOR" "$TYPE" "$ISSUE" ;;
    /handoff)
      cmd_release "$ACTOR" "$ISSUE" "handing off"
      comment "$ISSUE" "🗼 @${ACTOR} hands this off to ${ARGS} — please \`/claim\` to accept." ;;
    /status)   cmd_status "$ISSUE" ;;
    /ack)      cmd_heartbeat "$ACTOR" "$TYPE" "$ISSUE" ;;
    *) log "not a tower command: $VERB"; exit 0 ;;
  esac
  commit_state "${VERB#/} by ${ACTOR} on #${ISSUE}"
elif [ "${GITHUB_EVENT_NAME}" = "repository_dispatch" ]; then
  # strictness: reject payloads that don't match schemas/command.schema.json shape
  jq -e '.client_payload
         | (.command | type == "string" and IN("claim","heartbeat","release","handoff","status","ack"))
           and (.actor | type == "string" and length > 0)
           and ((.task // 0) | type == "number")' "$EVENT" >/dev/null \
    || { echo "::error::tower: dispatch payload failed schema check — rejected"; exit 1; }
  CMD="$(jq -r '.client_payload.command' "$EVENT")"
  ACTOR="$(jq -r '.client_payload.actor' "$EVENT")"
  TYPE="$(jq -r '.client_payload.actor_type // "agent"' "$EVENT")"
  TASK="$(jq -r '.client_payload.task // "null"' "$EVENT")"
  SENDER="$(jq -r '.sender.login // "unknown"' "$EVENT")"  # authenticated identity behind the payload
  case "$CMD" in
    heartbeat) cmd_heartbeat "$ACTOR" "$TYPE" "$TASK" ;;
    claim)
      PATHS="$(jq -c '.client_payload.paths // []' "$EVENT")"
      cmd_claim "$ACTOR" "$TYPE" "$TASK" "$PATHS" ;;
    release)   cmd_release "$ACTOR" "$TASK" "$(jq -r '.client_payload.note // ""' "$EVENT")" ;;
    *) log "unknown dispatch command: $CMD"; exit 0 ;;
  esac
  commit_state "${CMD} (dispatch) by ${ACTOR} via ${SENDER}"
fi

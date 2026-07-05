#!/usr/bin/env bash
# tower self-heal — diagnostic envelopes + fix routing with a retry budget.
set -euo pipefail

REPO="${GITHUB_REPOSITORY}"
EVENT="${GITHUB_EVENT_PATH}"
MARKER="tower:envelope:v1"

CONCLUSION="$(jq -r '.workflow_run.conclusion' "$EVENT")"
[ "$CONCLUSION" = "failure" ] || { echo "::notice::self-heal: conclusion=$CONCLUSION, nothing to do"; exit 0; }

RUN_ID="$(jq -r '.workflow_run.id' "$EVENT")"
HEAD_BRANCH="$(jq -r '.workflow_run.head_branch' "$EVENT")"
PR="$(jq -r '.workflow_run.pull_requests[0].number // empty' "$EVENT")"
if [ -z "$PR" ]; then # fork PRs / detached runs: resolve by head branch
  PR="$(gh pr list --repo "$REPO" --state open --head "$HEAD_BRANCH" --json number --jq '.[0].number // empty')"
fi
[ -z "$PR" ] && { echo "::notice::self-heal: no PR for run $RUN_ID"; exit 0; }

# ---- budget check
ATTEMPTS="$(gh api "repos/${REPO}/issues/${PR}/comments" --paginate \
           --jq "[.[] | select(.body | contains(\"${MARKER}\"))] | length")"
ATTEMPT="$((ATTEMPTS + 1))"
if [ "$ATTEMPT" -gt "$MAX_ATTEMPTS" ]; then
  HAS_LABEL="$(gh api "repos/${REPO}/issues/${PR}/labels" --jq '[.[].name] | index("needs-human") != null')"
  if [ "$HAS_LABEL" != "true" ]; then
    gh api -X POST "repos/${REPO}/issues/${PR}/labels" -f "labels[]=needs-human" --silent || true
    gh api "repos/${REPO}/issues/${PR}/comments" -f body="## 🔧 Self-heal budget exhausted (${MAX_ATTEMPTS} attempts)
Automated repair is **stopped** for this PR. A human needs to look at it. 🙋" --silent
  fi
  exit 0
fi

# ---- harvest diagnostics
FAILED_JOBS="$(gh run view "$RUN_ID" --repo "$REPO" --json jobs \
              --jq '[.jobs[] | select(.conclusion == "failure") | .name] | join(", ")')"
LOGS="$(gh run view "$RUN_ID" --repo "$REPO" --log-failed 2>/dev/null | tail -n 150 || echo "(logs unavailable)")"
SUSPECTS="$(gh pr view "$PR" --repo "$REPO" --json files --jq '[.files[].path]')"

PAYLOAD="$(jq -nc --argjson run "$RUN_ID" --argjson attempt "$ATTEMPT" \
  --argjson max "$MAX_ATTEMPTS" --arg jobs "$FAILED_JOBS" --argjson paths "$SUSPECTS" \
  '{run:$run, attempt:$attempt, max:$max, verdict:"fail", failed_jobs:($jobs|split(", ")), suspect_paths:$paths}')"

BODY="## 🔧 Diagnostic Envelope — run ${RUN_ID}, attempt ${ATTEMPT}/${MAX_ATTEMPTS}
**Verdict:** FAIL · **Failed jobs:** ${FAILED_JOBS:-unknown} · **Branch:** \`${HEAD_BRANCH}\`

<details><summary>Failing steps — last 150 log lines</summary>

\`\`\`text
${LOGS}
\`\`\`
</details>

<!-- ${MARKER} ${PAYLOAD} -->"

# ---- routing: agent PRs get an automatic fix summon
IS_AGENT=0
AUTHOR="$(gh pr view "$PR" --repo "$REPO" --json author --jq '.author.login')"
case "$AUTHOR" in *"[bot]"|*-bot) IS_AGENT=1 ;; esac
IFS=',' read -ra PREFIXES <<< "$AGENT_PREFIXES"
for p in "${PREFIXES[@]}"; do
  case "$HEAD_BRANCH" in "$p"*) IS_AGENT=1 ;; esac
done

if [ "$IS_AGENT" = 1 ]; then
  BODY="$BODY

${FIX_MENTION} fix the failures listed in the diagnostic envelope above. Rebase onto the default branch first if it has moved. Push the fix to this same branch."
fi

gh api "repos/${REPO}/issues/${PR}/comments" -f body="$BODY" --silent
echo "::notice::self-heal: envelope ${ATTEMPT}/${MAX_ATTEMPTS} posted on PR #${PR} (agent=${IS_AGENT})"

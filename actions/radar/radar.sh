#!/usr/bin/env bash
# tower conflict radar — pre-merge overlap detection.
# v0.1 granularity: file-level (🔴 = same file also changed in another open PR,
# 🟡 = same file under someone else's lease). Hunk-level is a roadmap item.
set -euo pipefail

REPO="${GITHUB_REPOSITORY}"
PR="$(jq -r '.pull_request.number' "$GITHUB_EVENT_PATH")"
MARKER="tower:radar:v1"

# ---- my changed files
MY_FILES="$(gh pr view "$PR" --repo "$REPO" --json files --jq '.files[].path')"
[ -z "$MY_FILES" ] && { echo "::notice::radar: empty diff"; exit 0; }

# ---- leases from the state branch (best effort)
LEASES='{"leases":[]}'
if git fetch -q --depth 1 origin "$STATE_BRANCH" 2>/dev/null; then
  LEASES="$(git show FETCH_HEAD:state/leases.json 2>/dev/null || echo '{"leases":[]}')"
fi

# ---- other open PRs and their files
OTHERS="$(gh pr list --repo "$REPO" --state open --limit 50 \
          --json number,headRefName,author,files \
          --jq "[.[] | select(.number != ${PR})]")"

ROWS=""
HIGH=0
while IFS= read -r f; do
  prs="$(echo "$OTHERS" | jq -r --arg f "$f" \
        '[.[] | select(.files[].path == $f) | "#\(.number) (\(.author.login))"] | unique | join(", ")')"
  lease_hits="$(echo "$LEASES" | jq -r --arg f "$f" \
        '[.leases[] | select(.paths[]? == $f) | "\(.actor) lease→#\(.task)"] | unique | join(", ")')"
  risk="🟢"
  [ -n "$lease_hits" ] && risk="🟡"
  [ -n "$prs" ] && { risk="🔴"; HIGH=1; }
  if [ "$risk" != "🟢" ]; then
    ROWS="${ROWS}| \`$f\` | ${prs:-—} | ${lease_hits:-—} | $risk |
"
  fi
done <<< "$MY_FILES"

PAYLOAD="$(jq -nc --argjson pr "$PR" --arg risk "$([ "$HIGH" = 1 ] && echo high || echo low)" \
  '{pr:$pr, risk:$risk}')"

if [ -z "$ROWS" ]; then
  BODY="## 🎯 Conflict Radar — PR #${PR}

🟢 **No overlap** with active leases or other open PRs. Clear skies.

<!-- ${MARKER} ${PAYLOAD} -->"
else
  BODY="## 🎯 Conflict Radar — PR #${PR}

| Path | Also changed in open PR | Under lease by | Risk |
|---|---|---|---|
${ROWS}
**Protocol:** the PR earlier in the merge order wins; the later one rebases after it lands. 🔴 rows mean *the same file is in flight twice* — coordinate before both merge. ([wound-wait rules](https://github.com/isobed18/gh-tower/blob/main/docs/PROTOCOL.md#6-contention--negotiation-wound-wait))

<!-- ${MARKER} ${PAYLOAD} -->"
fi

# ---- upsert sticky comment
CID="$(gh api "repos/${REPO}/issues/${PR}/comments" --paginate \
      --jq "[.[] | select(.body | contains(\"${MARKER}\")) | .id][0] // empty")"
if [ -n "$CID" ]; then
  gh api -X PATCH "repos/${REPO}/issues/comments/${CID}" -f body="$BODY" --silent
else
  gh api "repos/${REPO}/issues/${PR}/comments" -f body="$BODY" --silent
fi

# ---- label
if [ "$HIGH" = 1 ]; then
  gh api -X POST "repos/${REPO}/issues/${PR}/labels" -f "labels[]=overlap:high" --silent || true
else
  gh api -X DELETE "repos/${REPO}/issues/${PR}/labels/overlap%3Ahigh" --silent 2>/dev/null || true
fi

#!/usr/bin/env bash
# spec-approval.sh: may a PR whose code breaks the BASE spec merge anyway? Only if the repository
# owner applied the label owner-approved-spec-change AFTER the latest push to the PR branch (a
# later push revokes it). Fork PRs never. env: REPO PR OWNER BRANCH HEAD_REPO GH_TOKEN
set -uo pipefail
LABEL="${SPEC_LABEL:-owner-approved-spec-change}"
for v in REPO PR OWNER BRANCH HEAD_REPO; do [ -n "${!v:-}" ] || { echo "SPEC-APPROVAL missing env $v"; exit 2; }; done
[ "$HEAD_REPO" = "$REPO" ] || { echo "SPEC-APPROVAL denied: fork PR"; exit 1; }
gh api "repos/$REPO/issues/$PR/labels" --jq '.[].name' | grep -qx "$LABEL" \
  || { echo "SPEC-APPROVAL denied: label $LABEL not present"; exit 1; }
pushed="$(gh api "repos/$REPO/activity?ref=refs/heads/$BRANCH&activity_type=push&per_page=1" --jq '.[0].timestamp // empty')"
[ -n "$pushed" ] || { echo "SPEC-APPROVAL denied: no push activity for $BRANCH"; exit 1; }
labeled="$(gh api --paginate "repos/$REPO/issues/$PR/events" \
  --jq ".[] | select(.event==\"labeled\" and .label.name==\"$LABEL\" and .actor.login==\"$OWNER\" and .actor.type==\"User\") | .created_at" | sort | tail -1)"
[ -n "$labeled" ] || { echo "SPEC-APPROVAL denied: $LABEL not applied by owner $OWNER"; exit 1; }
[[ "$labeled" > "$pushed" ]] || { echo "SPEC-APPROVAL denied: owner label ($labeled) predates last push ($pushed)"; exit 1; }
echo "SPEC-APPROVAL granted: owner $OWNER labeled at $labeled after last push $pushed"

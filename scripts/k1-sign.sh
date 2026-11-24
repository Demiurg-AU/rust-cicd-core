#!/usr/bin/env bash
# K1: the owner signs an approval of one pipeline PR, on the owner's own machine (docs/k1-owner-approval.md).
#   k1-sign.sh <owner/repo> <pr> <private key> [hours valid, default 24, at most 72]
# Reads the live repository id, head, base and the default branch's policy blob from GitHub, shows the text, signs it
# with ssh-keygen -Y sign (namespace rcc-approval) and, after a yes, posts it as a PR comment. The key never leaves
# this machine; the agent's environment must not have it.
set -euo pipefail
R="${1:?owner/repo}" N="${2:?pr number}" KEY="${3:?private key file}" H="${4:-24}"
[[ "$H" =~ ^[0-9]+$ ]] && [ "$H" -ge 1 ] && [ "$H" -le 72 ] || { echo "K1 hours must be 1..72"; exit 1; }
[ -f "$KEY" ] || { echo "K1 key not found: $KEY"; exit 1; }
rid=$(gh api "repos/$R" --jq .id); def=$(gh api "repos/$R" --jq .default_branch)
head=$(gh api "repos/$R/pulls/$N" --jq .head.sha); base=$(gh api "repos/$R/pulls/$N" --jq .base.sha)
blob=$(gh api "repos/$R/contents/scripts/agent-pr-policy.sh?ref=$def" --jq .sha)
exp=$(date -u -d "+$H hours" +%Y-%m-%dT%H:%M:%SZ)
nonce=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
printf 'RCC-APPROVAL-V1\nrepository: %s (id %s)\npr: %s\naction: merge-pipeline-change\nhead: %s\nbase: %s\npolicy: %s\nexpires: %s\nnonce: %s\n' \
  "$R" "$rid" "$N" "$head" "$base" "$blob" "$exp" "$nonce" > "$t/msg"
echo "K1 approval to sign:"; cat "$t/msg"
read -r -p "Sign and post this approval for PR #$N? [yes/no] " a; [ "$a" = yes ] || { echo "K1 not signed"; exit 1; }
ssh-keygen -Y sign -f "$KEY" -n rcc-approval "$t/msg" > /dev/null
{ echo '```'; cat "$t/msg" "$t/msg.sig"; echo '```'; } > "$t/body"
gh pr comment "$N" --repo "$R" --body-file "$t/body"
echo "K1 posted: head $head, base $base, policy $blob, expires $exp"

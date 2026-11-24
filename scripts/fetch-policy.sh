#!/usr/bin/env bash
# Fetch the default branch's policy for T1 (ext: controls) and T3 (K10 ruleset snapshot):
#   <dir>/rules.json     GET repos/{repo}/rules/branches/{default}   (effective rules)
#   <dir>/rulesets.json  GET repos/{repo}/rulesets/{id} for each branch ruleset (enforcement, conditions, bypass)
# Prints EXT_RULES=... and EXT_RULESETS=... lines (append to $GITHUB_ENV in Actions, or eval/export locally).
set -euo pipefail
repo="${1:?usage: fetch-policy.sh <owner/repo> <dir>}"; dir="${2:?usage: fetch-policy.sh <owner/repo> <dir>}"
mkdir -p "$dir"
branch="$(gh api "repos/$repo" --jq .default_branch)"
gh api "repos/$repo/rules/branches/$branch" > "$dir/rules.json"
ids="$(gh api "repos/$repo/rulesets" --jq '.[] | select(.target == "branch") | .id')"
{ printf '['; sep=''; for i in $ids; do printf '%s' "$sep"; gh api "repos/$repo/rulesets/$i"; sep=','; done; printf ']\n'; } > "$dir/rulesets.json"
echo "EXT_RULES=$dir/rules.json"
echo "EXT_RULESETS=$dir/rulesets.json"

#!/usr/bin/env bash
# agent-pr-policy.sh <facts-dir>   (threat CI-7)
# Decides from PR facts collected by agent-pr-facts.sh (or canary fixtures), no network:
#   author_kind = agent  (branch copilot/|codex/|claude/, an AI login, or an AI Co-Authored-By trailer)
#               | bot    (any other [bot] author/committer, e.g. dependabot)
#               | human
#   agent|bot touching the pipeline  -> needs label OWNER_LABEL, last applied by a human repo owner
#                                       (the workflow removes that label on every new push)
#   agent                            -> Codex review completed on the HEAD commit with no unresolved findings
set -euo pipefail
F="${1:?facts dir}"
LABEL="${OWNER_LABEL:-owner-approved-pipeline}"
PIPE='^(\.github/|scripts/|threat-model\.tsv$|deny\.toml$|rust-toolchain\.toml$|lean-toolchain$|proof-map\.tsv$|mutants-exclusions\.tsv$)'
for f in branch.txt head_sha.txt commits.tsv files.txt labels.tsv labels_now.txt codex.tsv owners.txt; do
  [ -f "$F/$f" ] || { echo "AGENT facts missing: $f"; exit 1; }
done
[ -s "$F/commits.tsv" ] && [ -s "$F/head_sha.txt" ] || { echo "AGENT facts missing: no commits"; exit 1; }
branch=$(cat "$F/branch.txt"); head=$(cat "$F/head_sha.txt")

kind=human
if grep -Eqi '^(copilot|codex|claude)/' <<< "$branch" || awk -F'\t' '
    { a = tolower($1); c = tolower($2) }
    a ~ /^(copilot|copilot-swe-agent\[bot\]|chatgpt-codex-connector\[bot\])$/ || a ~ /^(codex|claude)/ ||
    c ~ /^(copilot|copilot-swe-agent\[bot\]|chatgpt-codex-connector\[bot\])$/ || c ~ /^(codex|claude)/ ||
    $3 == "1" { f = 1 }
    END { exit !f }' "$F/commits.tsv"; then
  kind=agent
elif awk -F'\t' '$1 ~ /\[bot\]$/ || $2 ~ /\[bot\]$/ { f = 1 } END { exit !f }' "$F/commits.tsv"; then
  kind=bot
fi
echo "author_kind=$kind"

fail=0
if [ "$kind" != human ]; then
  touched=$(grep -E "$PIPE" "$F/files.txt" || true)
  if [ -n "$touched" ]; then
    ok=0
    if grep -qxF "$LABEL" "$F/labels_now.txt"; then
      last=$(awk -F'\t' -v l="$LABEL" '$1 == l' "$F/labels.tsv" | tail -n 1)
      actor=$(cut -f2 <<< "$last"); type=$(cut -f3 <<< "$last")
      if [ -n "$last" ] && [ "$type" = User ] && grep -qxF "$actor" "$F/owners.txt"; then ok=1; fi
    fi
    [ "$ok" = 1 ] || { echo "AGENT PR touches pipeline without owner label: $(tr '\n' ' ' <<< "$touched")"; fail=1; }
  fi
fi
if [ "$kind" = agent ]; then
  row=$(awk -F'\t' -v h="$head" '$1 == h' "$F/codex.tsv" | tail -n 1)
  if [ -z "$row" ] || [ "$(cut -f2 <<< "$row")" != completed ]; then
    echo "AGENT PR head not reviewed by Codex: $head"; fail=1
  elif [ "$(cut -f3 <<< "$row")" != false ]; then
    echo "AGENT PR has unresolved Codex findings: $head"; fail=1
  fi
fi
[ "$fail" = 0 ] && echo "AGENT policy ok"
exit "$fail"

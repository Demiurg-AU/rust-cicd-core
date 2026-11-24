#!/usr/bin/env bash
# agent-pr-policy.sh <facts-dir>   (threat CI-7)
# Decides from PR facts collected by agent-pr-facts.sh (or canary fixtures), no network:
#   author_kind = agent | bot | human is REPORTED ONLY (#45 item 6, owner decision 2026-11-20, option C): agents push
#   with the owner's own token and their markers (branch prefix, Co-Authored-By trailer) are self-declared, so no
#   decision may depend on them. Every PR, whoever claims to have written it, needs:
#   touching the pipeline -> label OWNER_LABEL whose LAST application is by a human repo owner
#                            AND later than the latest push to the PR branch
#   always                -> review state from the exact Codex integration (login + Bot type)
#                            completed on the HEAD commit, no unresolved findings
# K1 (docs/k1-owner-approval.md): an owner approval is an SSH signature (namespace rcc-approval) over a text naming the
#   repository (name + id), PR, full head and base SHAs, this policy's blob id, an expiry (at most 72 h ahead) and a
#   nonce. The text is REBUILT from live values here, so a signature for any other head/base/PR/policy cannot verify.
#   Keys: .github/k1-allowed-signers of the default branch (the checkout this policy runs from; a PR cannot add its
#   own). Mode .github/k1-mode: off (label only) | observe (label decides, K1 verdict reported) | required (a valid
#   signature is the approval; the label alone approves nothing).
set -euo pipefail
F="${1:?facts dir}"
LABEL="${OWNER_LABEL:-owner-approved-pipeline}"
CODEX_LOGIN="${CODEX_LOGIN:-chatgpt-codex-connector[bot]}"
PIPE='^(\.github/|\.clusterfuzzlite/|scripts/|\.cargo/|\.config/|threat-model\.tsv$|ext-controls\.tsv$|ruleset-snapshot\.json$|deny\.toml$|supply-chain/|rust-toolchain\.toml$|lean-toolchain$|proof-map\.tsv$|mutants-exclusions\.tsv$|kani-harnesses\.tsv$|kani-canaries\.tsv$|claims\.tsv$|assumptions\.tsv$|spec-paths\.txt$|spec-epoch-canaries\.tsv$|fuzz/fuzz-targets\.tsv$|fuzz/fuzz-canaries\.tsv$|\.?clippy\.toml$|\.?rustfmt\.toml$)'
for f in branch.txt head_sha.txt pushed_at.txt commits.tsv files.txt labels.tsv labels_now.txt codex.tsv owners.txt; do
  [ -f "$F/$f" ] || { echo "AGENT facts missing: $f"; exit 1; }
done
[ -s "$F/commits.tsv" ] && [ -s "$F/head_sha.txt" ] || { echo "AGENT facts missing: no commits"; exit 1; }
branch=$(cat "$F/branch.txt"); head=$(cat "$F/head_sha.txt"); pushed=$(cat "$F/pushed_at.txt")
K1_ROOT="${K1_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
k1_mode=off; [ -f "$K1_ROOT/.github/k1-mode" ] && k1_mode=$(tr -d '[:space:]' < "$K1_ROOT/.github/k1-mode")
case "$k1_mode" in off|observe|required) ;; *) echo "AGENT K1 mode unknown: $k1_mode"; exit 2 ;; esac

# k1_check: prints "valid" or the first reason no approval holds; exit 0 only for a valid one
k1_check() {
  local signers="$K1_ROOT/.github/k1-allowed-signers" d="$F/approvals" f t k v reason="no signed approval"
  [ -s "$signers" ] || { echo "no allowed signers on the default branch"; return 1; }
  for k in repo.txt repo_id.txt pr.txt base_sha.txt; do [ -s "$F/$k" ] || { echo "facts missing: $k"; return 1; }; done
  local repo rid pr base blob now; repo=$(cat "$F/repo.txt"); rid=$(cat "$F/repo_id.txt"); pr=$(cat "$F/pr.txt")
  base=$(cat "$F/base_sha.txt"); blob=$(git hash-object --no-filters "${BASH_SOURCE[0]}"); now=$(date -u +%s)
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [[ "$base" =~ ^[0-9a-f]{40}$ ]] || { echo "live head/base is not a full SHA"; return 1; }
  [ -d "$d" ] || { echo "$reason"; return 1; }
  t="$(mktemp -d)"
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    local exp nonce got want field ok=1 i
    exp=$(sed -n 's/^expires: //p' "$f" | head -1); nonce=$(sed -n 's/^nonce: //p' "$f" | head -1)
    for i in "repository:$repo (id $rid)" "pr:$pr" "action:merge-pipeline-change" "head:$head" "base:$base" "policy:$blob"; do
      field="${i%%:*}"; want="${i#*:}"; got=$(sed -n "s/^$field: //p" "$f" | head -1)
      [ "$got" = "$want" ] || { reason="$field does not match (signed '${got:-none}', live '$want')"; ok=0; break; }
    done
    [ $ok = 1 ] || continue
    [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] || { reason="nonce is not 32 hex"; continue; }
    [[ "$exp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && v=$(date -u -d "$exp" +%s 2>/dev/null) \
      || { reason="expires is not a UTC timestamp"; continue; }
    [ "$v" -gt "$now" ] || { reason="approval expired at $exp"; continue; }
    [ $((v - now)) -le 259200 ] || { reason="expires more than 72 h ahead"; continue; }
    printf 'RCC-APPROVAL-V1\nrepository: %s (id %s)\npr: %s\naction: merge-pipeline-change\nhead: %s\nbase: %s\npolicy: %s\nexpires: %s\nnonce: %s\n' \
      "$repo" "$rid" "$pr" "$head" "$base" "$blob" "$exp" "$nonce" > "$t/msg"
    sed -n '/^-----BEGIN SSH SIGNATURE-----$/,/^-----END SSH SIGNATURE-----$/p' "$f" > "$t/sig"
    [ -s "$t/sig" ] || { reason="no signature block"; continue; }
    if ssh-keygen -Y verify -f "$signers" -I owner -n rcc-approval -s "$t/sig" < "$t/msg" > /dev/null 2>&1; then
      rm -rf "$t"; echo valid; return 0; fi
    reason="signature not valid for an allowed signer"
  done
  rm -rf "$t"; echo "$reason"; return 1
}

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
{
  touched=$(grep -E "$PIPE" "$F/files.txt" || true)
  if [ -n "$touched" ]; then
    why=""
    k1=""; [ "$k1_mode" = off ] || k1=$(k1_check) || true
    if [ "$k1_mode" = required ]; then
      [ "$k1" = valid ] && echo "K1 owner signature valid" \
        || { echo "AGENT PR touches pipeline without a valid owner signature (K1: $k1): $(tr '\n' ' ' <<< "$touched")"; fail=1; }
      why=skip
    elif [ "$k1_mode" = observe ]; then
      [ "$k1" = valid ] && echo "K1 observe: owner signature valid (required mode would ACCEPT)" \
        || echo "K1 observe: $k1 (required mode would BLOCK)"
    fi
    if [ "$why" = skip ]; then why=""
    elif ! grep -qxF "$LABEL" "$F/labels_now.txt"; then why="no label"
    else
      last=$(awk -F'\t' -v l="$LABEL" '$1 == l' "$F/labels.tsv" | tail -n 1)
      actor=$(cut -f2 <<< "$last"); type=$(cut -f3 <<< "$last"); at=$(cut -f4 <<< "$last")
      if [ -z "$last" ] || [ "$type" != User ] || ! grep -qxF "$actor" "$F/owners.txt"; then why="label not applied by a human owner"
      elif [ -z "$pushed" ] || [[ ! "$at" > "$pushed" ]]; then why="label predates the latest push ($at <= ${pushed:-unknown})"
      fi
    fi
    [ -z "$why" ] || { echo "AGENT PR touches pipeline without owner label ($why): $(tr '\n' ' ' <<< "$touched")"; fail=1; }
  fi
}
{
  row=$(awk -F'\t' -v h="$head" -v l="$CODEX_LOGIN" '$1 == h && $4 == l && $5 == "Bot"' "$F/codex.tsv" | tail -n 1)
  if [ -z "$row" ] || [ "$(cut -f2 <<< "$row")" != completed ]; then
    echo "AGENT PR head not reviewed by Codex: $head"; fail=1
  elif [ "$(cut -f3 <<< "$row")" != false ]; then
    echo "AGENT PR has unresolved Codex findings: $head"; fail=1
  fi
}
[ "$fail" = 0 ] && echo "AGENT policy ok"
exit "$fail"

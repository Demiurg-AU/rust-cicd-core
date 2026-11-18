#!/usr/bin/env bash
# spec-approval.sh [canary]
# May a PR whose code breaks the BASE spec merge anyway? Only if the label owner-approved-spec-change
# is present now AND its LAST application (by anyone) was made by the repository owner (a human) AND
# that application is later than the latest push to the PR branch (a later push revokes it).
# Fork PRs never. Same rule as agent-pr-policy.sh for owner-approved-pipeline.
#   live:   env REPO PR OWNER BRANCH HEAD_REPO GH_TOKEN (facts fetched from the GitHub REST API)
#   facts:  env FACTS=<dir> with repo.txt head_repo.txt owner.txt labels_now.txt pushed_at.txt labels.tsv
#           (labels.tsv: label<TAB>actor<TAB>actor_type<TAB>created_at, "labeled" events, oldest first)
#   canary: fixtures for every decision; exit 1 if any decision is wrong or for the wrong reason
set -uo pipefail
LABEL="${SPEC_LABEL:-owner-approved-spec-change}"

decide() { # <facts-dir>
  local F="$1" repo head_repo owner pushed last actor type at
  repo="$(cat "$F/repo.txt")"; head_repo="$(cat "$F/head_repo.txt")"; owner="$(cat "$F/owner.txt")"
  pushed="$(cat "$F/pushed_at.txt")"
  [ "$head_repo" = "$repo" ] || { echo "SPEC-APPROVAL denied: fork PR"; return 1; }
  grep -qxF "$LABEL" "$F/labels_now.txt" || { echo "SPEC-APPROVAL denied: label $LABEL not present"; return 1; }
  last="$(awk -F'\t' -v l="$LABEL" '$1 == l' "$F/labels.tsv" | tail -n 1)"
  actor="$(cut -f2 <<< "$last")"; type="$(cut -f3 <<< "$last")"; at="$(cut -f4 <<< "$last")"
  if [ -z "$last" ] || [ "$type" != User ] || [ "$actor" != "$owner" ]; then
    echo "SPEC-APPROVAL denied: last application of $LABEL not by owner $owner (${actor:-none})"; return 1; fi
  [ -n "$pushed" ] || { echo "SPEC-APPROVAL denied: no push activity for the branch"; return 1; }
  [[ "$at" > "$pushed" ]] || { echo "SPEC-APPROVAL denied: owner label ($at) predates last push ($pushed)"; return 1; }
  echo "SPEC-APPROVAL granted: owner $owner labeled at $at after last push $pushed"
}

fetch() { # <out-dir>
  local O="$1" v
  for v in REPO PR OWNER BRANCH HEAD_REPO; do [ -n "${!v:-}" ] || { echo "SPEC-APPROVAL missing env $v"; return 2; }; done
  printf '%s\n' "$REPO" > "$O/repo.txt"; printf '%s\n' "$HEAD_REPO" > "$O/head_repo.txt"; printf '%s\n' "$OWNER" > "$O/owner.txt"
  gh api "repos/$REPO/issues/$PR/labels" --jq '.[].name' > "$O/labels_now.txt" || return 2
  gh api "repos/$REPO/activity?ref=refs/heads/$BRANCH&activity_type=push&per_page=1" --jq '.[0].timestamp // empty' > "$O/pushed_at.txt" || return 2
  gh api --paginate "repos/$REPO/issues/$PR/events" \
    --jq '.[] | select(.event == "labeled") | [.label.name, .actor.login, .actor.type, .created_at] | @tsv' \
    | sort -t$'\t' -k4,4 > "$O/labels.tsv" || return 2
}

canary() {
  local T rc=0; T="$(mktemp -d)"
  mk() { # <name> <head_repo> <labels_now> <labels.tsv>
    mkdir -p "$T/$1"; printf 'o/r\n' > "$T/$1/repo.txt"; printf '%s\n' "$2" > "$T/$1/head_repo.txt"
    printf 'own\n' > "$T/$1/owner.txt"; printf '2026-01-01T00:00:00Z\n' > "$T/$1/pushed_at.txt"
    printf '%b' "$3" > "$T/$1/labels_now.txt"; printf '%b' "$4" > "$T/$1/labels.tsv"; }
  L="$LABEL"
  mk ok o/r "$L\n" "$L\town\tUser\t2026-01-02T00:00:00Z\n"
  mk fork x/r "$L\n" "$L\town\tUser\t2026-01-02T00:00:00Z\n"
  mk none o/r "" "$L\town\tUser\t2026-01-02T00:00:00Z\n"
  mk relabel o/r "$L\n" "$L\town\tUser\t2026-01-02T00:00:00Z\n$L\tmallory\tUser\t2026-01-03T00:00:00Z\n"
  mk bot o/r "$L\n" "$L\town\tBot\t2026-01-02T00:00:00Z\n"
  mk stale o/r "$L\n" "$L\town\tUser\t2025-12-31T00:00:00Z\n"
  chk() { local o r; o="$(decide "$T/$1")"; r=$?
    if [ "$r" -eq "$2" ] && grep -qE "$3" <<< "$o"; then echo "SPEC-APPROVAL canary $1 ok"
    else echo "SPEC-APPROVAL canary $1 WRONG: rc=$r out='$o'"; rc=1; fi; }
  chk ok 0 '^SPEC-APPROVAL granted'
  chk fork 1 'fork PR'
  chk none 1 'not present'
  chk relabel 1 'not by owner own \(mallory\)'
  chk bot 1 'not by owner own \(own\)'
  chk stale 1 'predates last push'
  rm -rf "$T"; return "$rc"
}

case "${1:-}" in
  canary) canary ;;
  "") if [ -n "${FACTS:-}" ]; then decide "$FACTS"
      else D="$(mktemp -d)"; fetch "$D" || exit 2; decide "$D"; fi ;;
  *) echo "usage: spec-approval.sh [canary]"; exit 2 ;;
esac

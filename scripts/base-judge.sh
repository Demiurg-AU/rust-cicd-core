#!/usr/bin/env bash
# K3: judge a PR's code with the judge of its base commit, so the code under test cannot have edited its own judge.
#   assemble <repo> <base-ref> <head-ref> <out-dir>
#     out-dir = the head tree, with every judge file (the agent-pr-policy pipeline paths, except the spec files that
#     spec-epoch already takes from the base) replaced by the base commit's version, and judge files that exist only
#     in the head removed. Prints "JUDGE base=<sha> head=<sha> replaced=<n> removed=<n>".
#   run <repo> <base-ref> <head-ref> <out-dir>   assemble, then run the base judge (scripts/ci-local.sh) there
set -euo pipefail
die() { echo "JUDGE $*"; exit 1; }
# the judge: what decides a verdict, not what states the claim (claims/specs are judged by spec-epoch from the base)
JUDGE='^(\.github/|scripts/|\.cargo/|\.config/|threat-model\.tsv$|ext-controls\.tsv$|ruleset-snapshot\.json$|deny\.toml$|supply-chain/|rust-toolchain\.toml$|lean-toolchain$|mutants-exclusions\.tsv$|\.?clippy\.toml$|\.?rustfmt\.toml$)'
assemble() {
  local repo="$1" base head out b h n=0 r=0 f
  b="$(git -C "$repo" rev-parse --verify -q "$2^{commit}")" || die "base ref not found: $2"
  h="$(git -C "$repo" rev-parse --verify -q "$3^{commit}")" || die "head ref not found: $3"
  out="$4"; [ ! -e "$out" ] || [ -z "$(ls -A "$out")" ] || die "out dir not empty: $out"
  mkdir -p "$out"
  git -C "$repo" archive "$h" | tar -x -C "$out"
  while IFS= read -r f; do
    [[ "$f" =~ $JUDGE ]] || continue
    if git -C "$repo" cat-file -e "$b:$f" 2>/dev/null; then
      mkdir -p "$out/$(dirname "$f")"; git -C "$repo" show "$b:$f" > "$out/$f"
      n=$((n + 1))
    else rm -f "$out/$f"; r=$((r + 1)); fi
  done < <(git -C "$repo" ls-tree -r --name-only "$h")
  # judge files the base has and the head deleted come back too
  while IFS= read -r f; do
    [[ "$f" =~ $JUDGE ]] || continue
    [ -e "$out/$f" ] && continue
    mkdir -p "$out/$(dirname "$f")"; git -C "$repo" show "$b:$f" > "$out/$f"; n=$((n + 1))
  done < <(git -C "$repo" ls-tree -r --name-only "$b")
  chmod +x "$out"/scripts/*.sh 2>/dev/null || true
  # the assembled tree is a repository at the head's commit id, so evidence names the code that was judged
  git -C "$out" init -q && git -C "$out" add -A && git -C "$out" -c user.name=judge -c user.email=judge@local commit -qm "base judge of $h on $b"
  echo "JUDGE base=$b head=$h replaced=$n removed=$r"
}
case "${1:-}" in
  assemble) [ $# -eq 5 ] || die "usage: assemble <repo> <base-ref> <head-ref> <out-dir>"; assemble "$2" "$3" "$4" "$5" ;;
  run) [ $# -eq 5 ] || die "usage: run <repo> <base-ref> <head-ref> <out-dir>"; assemble "$2" "$3" "$4" "$5"; bash "$5/scripts/ci-local.sh" ;;
  *) die "usage: $0 assemble|run <repo> <base-ref> <head-ref> <out-dir>" ;;
esac

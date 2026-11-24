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
  # the head's committed bytes, blob by blob: git archive / checkout would apply the head's own .gitattributes
  # (export-ignore drops files, eol/text rewrites them - Codex P1 on #56), so neither is used
  local mode type sha path
  while IFS= read -r -d '' line; do
    mode="${line%% *}"; line="${line#* }"; type="${line%% *}"; line="${line#* }"; sha="${line%%$'\t'*}"; path="${line#*$'\t'}"
    case "$type" in
      blob) mkdir -p "$out/$(dirname "$path")"
            if [ "$mode" = 120000 ]; then ln -s "$(git -C "$repo" cat-file blob "$sha")" "$out/$path"
            else git -C "$repo" cat-file blob "$sha" > "$out/$path"; [ "$mode" = 100755 ] && chmod +x "$out/$path"; fi ;;
      commit) mkdir -p "$out/$path" ;;   # a submodule: its commit is not part of this tree's bytes
    esac
  done < <(git -C "$repo" ls-tree -r -z --full-tree "$h")
  # 1. every judge entry of the head goes: files, and symlinks (a head symlink scripts/ci-local.sh -> sandbox.sh would
  #    make the restore below write THROUGH it, Codex P1 on #56), including a symlinked judge directory itself
  while IFS= read -r f; do
    [[ "$f" =~ $JUDGE ]] || continue
    rm -f "$out/$f"; r=$((r + 1))
  done < <(git -C "$repo" ls-tree -r --name-only "$h")
  local l rel
  while IFS= read -r l; do rel="${l#"$out"/}"
    if [[ "$rel" =~ $JUDGE ]] || [[ "$rel/" =~ $JUDGE ]]; then rm -f "$l"; r=$((r + 1)); fi
  done < <(find "$out" -type l)
  # 2. the base's judge files, written as new regular files
  while IFS= read -r f; do
    [[ "$f" =~ $JUDGE ]] || continue
    mkdir -p "$out/$(dirname "$f")"; rm -f "$out/$f"; git -C "$repo" show "$b:$f" > "$out/$f"; n=$((n + 1))
  done < <(git -C "$repo" ls-tree -r --name-only "$b")
  # 3. verify: no symlink on any judge path, every judge file byte-equal to the base's blob
  while IFS= read -r f; do
    [[ "$f" =~ $JUDGE ]] || continue
    local p="$out"; local part
    IFS=/ read -ra parts <<< "$f"
    for part in "${parts[@]}"; do p="$p/$part"; [ -L "$p" ] && die "judge path is a symlink after assembly: ${p#"$out"/}"; done
    [ "$(git hash-object --no-filters "$out/$f")" = "$(git -C "$repo" rev-parse "$b:$f")" ] || die "judge file differs from the base: $f"
  done < <(git -C "$repo" ls-tree -r --name-only "$b")
  chmod +x "$out"/scripts/*.sh 2>/dev/null || true
  # the assembled tree is a repository whose one commit is a pure function of (base, head): fixed identity, the head's
  # committer date, base and head named in the message. ci-local records it as git_head, so two judgements of the same
  # pair are comparable witnesses for evidence-compare (Codex P2 on #56: a timestamped commit differed on every run)
  local when; when="$(git -C "$repo" log -1 --format=%cI "$h")"
  git -C "$out" init -q && git -C "$out" add -A \
    && GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$out" -c user.name=judge -c user.email=judge@local \
       -c commit.gpgsign=false commit -q --no-verify -m "base judge" -m "Judged-Head: $h" -m "Judged-Base: $b"
  echo "JUDGE base=$b head=$h replaced=$n removed=$r"
}
case "${1:-}" in
  assemble) [ $# -eq 5 ] || die "usage: assemble <repo> <base-ref> <head-ref> <out-dir>"; assemble "$2" "$3" "$4" "$5" ;;
  run) [ $# -eq 5 ] || die "usage: run <repo> <base-ref> <head-ref> <out-dir>"; assemble "$2" "$3" "$4" "$5"
       # a PR that changes the branch policy also changes ruleset-snapshot.json; the live policy can equal only one of the
       # two snapshots, so the base judge's T3 may accept the PR's own snapshot as well (core already demands it). The
       # file lives outside the judged tree, so the PR's code cannot plant it.
       hs="${5%/}.head-ruleset-snapshot.json"; rm -f "$hs"
       hc="$(git -C "$2" rev-parse --verify -q "$4^{commit}")"
       if git -C "$2" cat-file -e "$hc:ruleset-snapshot.json" 2>/dev/null; then
         git -C "$2" cat-file blob "$hc:ruleset-snapshot.json" > "$hs"; T3_HEAD_SNAPSHOT="$hs" bash "$5/scripts/ci-local.sh"
       else bash "$5/scripts/ci-local.sh"; fi ;;
  *) die "usage: $0 assemble|run <repo> <base-ref> <head-ref> <out-dir>" ;;
esac

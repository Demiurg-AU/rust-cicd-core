#!/usr/bin/env bash
# Spec epochs: the BASE branch's spec must still pass on the PR's code. The list of spec paths
# (spec-paths.txt) is read from BASE, never from the PR. Configuration only, per crate:
#   spec-paths.txt              spec files/dirs relative to the crate root
#   spec-epoch-canaries.tsv     planted "break the code AND weaken the spec" attacks that must be caught
# Usage (from anywhere inside the repo; CRATE = crate dir relative to the repo root, default .):
#   spec-epoch.sh test   <base-ref>    base tests x head code
#   spec-epoch.sh kani   <base-ref>    base Kani harnesses (via KANI_GATE, default scripts/kani-gate.sh) x head code
#   spec-epoch.sh canary               every canary in spec-epoch-canaries.tsv must be caught for its reason
#   spec-epoch.sh code-changed <base-ref>   prints yes/no: did the PR change non-spec crate files?
set -uo pipefail
CRATE="${CRATE:-.}"
TOP="$(git rev-parse --show-toplevel)" || exit 2
KANI_GATE="${KANI_GATE:-$TOP/scripts/kani-gate.sh}"
# PR code runs jailed (threat CI-9): it must not reach GITHUB_ENV/GITHUB_OUTPUT of later steps
# (e.g. BASH_ENV into the owner-approval step) or this script. sandbox.sh sits next to this file.
SANDBOX_SH="$(dirname "${BASH_SOURCE[0]}")/sandbox.sh"
# shellcheck source=sandbox.sh
[ -f "$SANDBOX_SH" ] && . "$SANDBOX_SH" || { echo "SPEC-EPOCH missing $SANDBOX_SH (no unjailed mode)"; exit 2; }
sandbox_enable

spec_list() { git -C "$TOP" show "$1:$CRATE/spec-paths.txt" 2>/dev/null; }

epoch() { # <base-ref> <head-ref> <test|kani>
  local base head mode="$3" wt list rc
  # resolve BEFORE entering a worktree: there, HEAD names the PR's own commit
  base="$(git -C "$TOP" rev-parse --verify "$1^{commit}")" || { echo "SPEC-EPOCH bad base ref: $1"; return 2; }
  head="$(git -C "$TOP" rev-parse --verify "$2^{commit}")" || { echo "SPEC-EPOCH bad head ref: $2"; return 2; }
  list="$(spec_list "$base")" || { echo "SPEC-EPOCH bootstrap: $base has no $CRATE/spec-paths.txt"; return 0; }
  wt="$(mktemp -d)"; git -C "$TOP" worktree add -q --detach "$wt" "$head" || return 2
  (
    cd "$wt/$CRATE" || exit 2
    export SANDBOX_WORK="$wt"
    while IFS= read -r p || [ -n "$p" ]; do
      [[ -z "$p" || "$p" = \#* ]] && continue
      rm -rf -- "$p"
      git cat-file -e "$base:$CRATE/$p" 2>/dev/null && git checkout -q "$base" -- "$p"
    done <<< "$list"
    echo "SPEC-EPOCH base spec $(git rev-parse --short "$base") x head code $(git rev-parse --short "$head") [$mode]"
    case "$mode" in
      test) unset CARGO_TARGET_DIR; cargo fetch --locked >/dev/null 2>&1 || { echo "SPEC-EPOCH dependency fetch failed"; exit 2; }
            cargo test --locked -q 2>&1 | tail -30; exit "${PIPESTATUS[0]}" ;;
      kani) bash "$KANI_GATE" run . "$(mktemp -d)" 2>&1 | grep '^KANI' ; exit "${PIPESTATUS[0]}" ;;
      *) echo "SPEC-EPOCH bad mode: $mode"; exit 2 ;;
    esac
  ); rc=$?
  git -C "$TOP" worktree remove --force "$wt"
  if [ "$rc" -ne 0 ]; then echo "SPEC-EPOCH old spec fails on new code [$mode]"; return 1; fi
  echo "SPEC-EPOCH old spec holds on new code [$mode]"
}

code_changed() { # <base-ref>
  local base list; base="$(git -C "$TOP" rev-parse --verify "$1^{commit}")" || return 2
  list="$(spec_list "$base")" || { echo yes; return 0; }
  local -a ex=()
  while IFS= read -r p || [ -n "$p" ]; do [[ -z "$p" || "$p" = \#* ]] || ex+=(":(exclude)$CRATE/$p"); done <<< "$list"
  if git -C "$TOP" diff --quiet "$base" HEAD -- "$CRATE" "${ex[@]}"; then echo no; else echo yes; fi
}

canaries() {
  local cfg="$TOP/$CRATE/spec-epoch-canaries.tsv" rc=0 n=0 id mode cf co cn sf so sn want
  [ -f "$cfg" ] || { echo "SPEC-EPOCH missing $cfg"; return 2; }
  local base; base="$(git -C "$TOP" rev-parse HEAD)"
  while IFS=$'\t' read -r id mode cf co cn sf so sn want || [ -n "$id" ]; do
    [[ -z "$id" || "$id" = \#* ]] && continue
    n=$((n + 1)); local wt; wt="$(mktemp -d)"; git -C "$TOP" worktree add -q --detach "$wt" "$base" || return 2
    if ! ( cd "$wt/$CRATE" && python3 - "$cf" "$co" "$cn" "$sf" "$so" "$sn" <<'PY'
import os, sys
cf, co, cn, sf, so, sn = sys.argv[1:7]
u = lambda t: t.replace("\\n", "\n")
def rep(p, old, new):
    s = open(p).read()
    if s.count(old) != 1: sys.exit(f"canary text found {s.count(old)} times in {p}")
    open(p, "w").write(s.replace(old, new))
rep(cf, u(co), u(cn))
if so == "-": os.remove(sf)
else: rep(sf, u(so), u(sn))
PY
    ) || ! git -C "$wt" -c user.name=canary -c user.email=canary@invalid commit -qam "canary $id"; then
      echo "SPEC-EPOCH CANARY $id cannot be planted"; rc=1; git -C "$TOP" worktree remove --force "$wt"; continue
    fi
    local head out erc; head="$(git -C "$wt" rev-parse HEAD)"
    out="$(epoch "$base" "$head" "$mode" 2>&1)"; erc=$?
    git -C "$TOP" worktree remove --force "$wt"
    if [ "$erc" -ne 0 ] && grep -Eq "$want" <<< "$out"; then echo "SPEC-EPOCH CANARY $id caught"
    else echo "SPEC-EPOCH CANARY $id NOT caught (exit $erc)"; printf '%s\n' "$out" | tail -8; rc=1; fi
  done < "$cfg"
  [ "$n" -gt 0 ] || { echo "SPEC-EPOCH no canary listed"; return 2; }
  return "$rc"
}

case "${1:-}" in
  test|kani) epoch "${2:?base ref}" HEAD "$1" ;;
  canary) canaries ;;
  code-changed) code_changed "${2:?base ref}" ;;
  *) echo "usage: spec-epoch.sh test|kani <base-ref> | canary | code-changed <base-ref>"; exit 2 ;;
esac

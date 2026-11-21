#!/usr/bin/env bash
# evidence-compare.sh — a second witness, compared line by line (gap G8).
#
#   compare <evidence-dir A> <evidence-dir B>   every gate both ran has the same verdict and the same check
#                                               signature; gates only one side ran are listed; exit 1 on any
#                                               difference. A and B: a local run and a CI run of the SAME commit.
#   fetch <run-id> <out-dir>                    download the evidence artifact of a GitHub Actions run (gh CLI)
#   sign <evidence-dir> <ssh private key>       sign SHA256SUMS with the owner's SSH key (ssh-keygen -Y sign)
#   verify <evidence-dir> <allowed_signers>     check that signature against the owner's public key
#
# Both evidence dirs must be sealed (SHA256SUMS valid) before they are compared: an edited results.tsv is refused.
set -uo pipefail

die() { echo "EVIDENCE $*"; exit 1; }
sealed() { # <dir>: SHA256SUMS present and valid
  [ -f "$1/SHA256SUMS" ] || die "not sealed: $1 has no SHA256SUMS"
  ( cd "$1" && sha256sum --quiet -c SHA256SUMS ) >/dev/null 2>&1 || die "seal broken: $1 (SHA256SUMS does not match)"
}
commit_of() { sed -n "s/^git_head=//p" "$1/env.txt" 2>/dev/null | head -1; }

compare() {
  local a="$1" b="$2"
  sealed "$a"; sealed "$b"
  local ca cb; ca="$(commit_of "$a")"; cb="$(commit_of "$b")"
  [ -n "$ca" ] && [ "$ca" = "$cb" ] || die "different commits: ${ca:-?} vs ${cb:-?} (compare runs of the same commit)"
  python3 - "$a" "$b" <<'PY'
import sys
def load(d):
    res, sig = {}, {}
    for l in open(f"{d}/results.tsv").read().splitlines()[1:]:
        f = l.split("\t")
        if len(f) == 6: res[f[0]] = f[5]
    try:
        for l in open(f"{d}/signatures.tsv"):
            f = l.rstrip("\n").split("\t")
            if len(f) == 2: sig[f[0]] = f[1]
    except FileNotFoundError:
        pass
    return res, sig
(ra, sa), (rb, sb) = load(sys.argv[1]), load(sys.argv[2])
bad = []
for g in sorted(set(ra) & set(rb)):
    if ra[g] != rb[g]: bad.append(f"EVIDENCE verdict differs {g}: {ra[g]} vs {rb[g]}")
    elif g in sa and g in sb and sa[g] != sb[g]: bad.append(f"EVIDENCE check differs {g}: the two runs ran different commands")
only_a, only_b = sorted(set(ra) - set(rb)), sorted(set(rb) - set(ra))
if only_a: print("EVIDENCE only in A: " + " ".join(only_a))
if only_b: print("EVIDENCE only in B: " + " ".join(only_b))
both = len(set(ra) & set(rb))
for x in bad: print(x)
print(f"EVIDENCE {'MISMATCH' if bad else 'MATCH'} {both - len(bad)}/{both} common gates")
sys.exit(1 if bad else 0)
PY
}

case "${1:-}" in
  compare) [ $# -eq 3 ] || die "usage: compare <dir A> <dir B>"; compare "$2" "$3" ;;
  fetch)
    [ $# -eq 3 ] || die "usage: fetch <run-id> <out-dir>"
    command -v gh >/dev/null || die "gh CLI missing"
    mkdir -p "$3" && gh run download "$2" --pattern 'evidence-*' --dir "$3" || die "download failed for run $2"
    find "$3" -name results.tsv -printf '%h\n' ;;
  sign)
    [ $# -eq 3 ] || die "usage: sign <dir> <ssh private key>"
    sealed "$2"; ssh-keygen -Y sign -q -n rcc-evidence -f "$3" "$2/SHA256SUMS" && echo "EVIDENCE signed: $2/SHA256SUMS.sig" ;;
  verify)
    [ $# -eq 3 ] || die "usage: verify <dir> <allowed_signers>"
    sealed "$2"; [ -f "$2/SHA256SUMS.sig" ] || die "unsigned: $2"
    local_id="$(awk 'NF && $1 !~ /^#/ {print $1; exit}' "$3")"; [ -n "$local_id" ] || die "no signer in $3"
    ssh-keygen -Y verify -n rcc-evidence -f "$3" -I "$local_id" -s "$2/SHA256SUMS.sig" < "$2/SHA256SUMS" >/dev/null 2>&1 \
      && echo "EVIDENCE signature ok ($local_id)" || die "signature invalid for $local_id" ;;
  *) die "usage: compare <A> <B> | fetch <run-id> <out> | sign <dir> <key> | verify <dir> <allowed_signers>" ;;
esac

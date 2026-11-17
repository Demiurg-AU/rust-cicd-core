#!/usr/bin/env bash
# release-source-check.sh <git-ref> <commit-sha> <approved-branch>
# Approved-source policy for releases (SLSA-D "build from unofficial ref"):
#   - the ref is a strict semver tag refs/tags/vX.Y.Z (or refs/heads/main for a dry run; publish is tag-gated),
#   - a tag points exactly at the built commit,
#   - the built commit is reachable from the protected branch (so it passed required CI before release).
# Reproducibility proves WHAT was built; this check proves the source was AUTHORIZED.
set -euo pipefail
ref="${1:?ref}" sha="${2:?sha}" main="${3:?approved branch}"
case "$ref" in
  refs/heads/main) ;;
  refs/tags/*)
    [[ "$ref" =~ ^refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "RELEASE ref not approved: $ref"; exit 1; } ;;
  *) echo "RELEASE ref not approved: $ref"; exit 1 ;;
esac
git cat-file -e "$sha^{commit}" 2>/dev/null || { echo "RELEASE source commit unknown: $sha"; exit 1; }
if [[ "$ref" == refs/tags/* ]]; then
  t=$(git rev-parse -q --verify "$ref^{commit}") || { echo "RELEASE tag missing: $ref"; exit 1; }
  [ "$t" = "$(git rev-parse "$sha^{commit}")" ] || { echo "RELEASE tag does not point at built commit: $ref"; exit 1; }
fi
git rev-parse -q --verify "$main^{commit}" >/dev/null || { echo "RELEASE approved branch missing: $main"; exit 1; }
git merge-base --is-ancestor "$sha" "$main" || { echo "RELEASE source not approved: $sha is not on $main"; exit 1; }
echo "RELEASE source approved: $ref $sha on $main"

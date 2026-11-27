# Verifying a release (consumer side)

Walked through on 2026-11-26 for `v0.1.0` (ROADMAP plan, improvement 3). Every value below is what that run printed.

## Steps

1. **Version → commit.** `gh api repos/Demiurg-AU/rust-cicd-core/git/ref/tags/v0.1.0` gives the annotated tag
   `089edc2`, which points to commit `8c4f96bcd88f07def6bb0a667eeff0516b1da7f5`.
2. **Download and digest.** Release assets: the binary, `SHA256SUMS`, the SBOM (`rust-cicd-core.cdx.json`) and two
   Sigstore bundles. `sha256sum -c SHA256SUMS` → both entries `OK`; binary
   `sha256:7fe807643b3cc39e4120c81a25357a3f61a06a611ecb37d1463f9b625b0d585f` (equal to GitHub's asset digest).
   `SHA256SUMS` itself is not signed: the attestation below is what binds the digest to the build.
3. **Provenance.**

   ```
   gh attestation verify rust-cicd-core-x86_64-unknown-linux-gnu --repo Demiurg-AU/rust-cicd-core \
     --bundle rust-cicd-core-x86_64-unknown-linux-gnu.provenance.sigstore.json \
     --signer-workflow Demiurg-AU/rust-cicd-core/.github/workflows/build-reusable.yml \
     --source-ref refs/tags/v0.1.0 --deny-self-hosted-runners
   ```

   Exit 0. The verified certificate names: source `https://github.com/Demiurg-AU/rust-cicd-core` at
   `8c4f96bcd88f07def6bb0a667eeff0516b1da7f5`, ref `refs/tags/v0.1.0`; signer
   `.github/workflows/build-reusable.yml@refs/tags/v0.1.0` at the same commit; run
   `actions/runs/44135648667` (workflow `release`, event `push`, conclusion success); GitHub-hosted runner; issuer
   `token.actions.githubusercontent.com`; predicate `https://slsa.dev/provenance/v1`; subject digest as in step 2; one
   transparency-log entry. Without `--bundle` the same command fetches the attestation from GitHub.

4. **Run.** `chmod +x rust-cicd-core-x86_64-unknown-linux-gnu && ./rust-cicd-core-x86_64-unknown-linux-gnu` prints
   `5` (the template's `checked_add(2, 3)`) and exits 0.

## Expected refusals (each one change, exit 1)

| Change | Result |
|---|---|
| one byte appended to the binary (sha256 `41075d77…`) | `Error: verifying with issuer "sigstore.dev"` — the subject digest no longer matches |
| `--signer-workflow …/ci.yml` (another workflow) | `Error: verifying with issuer "sigstore.dev"` |
| `--source-ref refs/heads/main` | `Error: expected SourceRepositoryRef to be refs/heads/main, got refs/tags/v0.1.0` |

## Gap found and closed here

`release.yml` also builds and attests on `workflow_dispatch` (a dry run from main). The command in the release notes
had no `--source-ref`, so an attested dry-run binary would have passed it as well: it proved "built by this
repository's workflow", not "the artifact of this release". The notes now pin `--source-ref refs/tags/<tag>` and
`--deny-self-hosted-runners`.

No SLSA level is claimed: the build-track requirements have not each been checked against this workflow.

## When the Sigstore trust root cannot be fetched

`gh attestation verify` first downloads the Sigstore trust root over TUF from `tuf-repo-cdn.sigstore.dev`. If that
host is blocked (a proxy that allows only GitHub), gh stops before it verifies anything:
`error creating Sigstore verifier: no valid Sigstore verifiers could be initialized`, exit 1. This is a refusal, not a
pass. Seen on 2026-11-27 while repeating the `v0.2.0` check.

Workaround used then: take the public-good trust root that ships inside the `sigstore` Python package (4.6.0, from
PyPI). gh wants it as JSON Lines, so put it on one line, then add `--custom-trusted-root` to the same command:

```
python3 -m venv venv && venv/bin/pip install sigstore==4.6.0
python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])),separators=(",",":")))' \
  "venv/lib/python3.13/site-packages/sigstore/_store/https%3A%2F%2Ftuf-repo-cdn.sigstore.dev/trusted_root.json" \
  > trusted_root.jsonl
gh attestation verify … --custom-trusted-root trusted_root.jsonl
```

With it, `v0.2.0` gave exit 0, and the three expected refusals above each gave exit 1. This root is only as fresh as
the package release: if Sigstore rotates its keys after that release, use the TUF-fetched root instead.

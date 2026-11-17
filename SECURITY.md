# Security policy

## Reporting a vulnerability
Please report vulnerabilities **privately** via GitHub: *Security → Report a vulnerability* on this repository (private vulnerability reporting is enabled). Do not open a public issue.

Include: affected commit or release, a minimal reproduction, and impact. You will get an acknowledgement within 7 days.

## Scope
- `scripts/ci-local.sh` and the GitHub workflows: any way to make a gate report PASS without performing its check ("silent skip"), to bypass a canary, or to forge evidence (`results.tsv`, `SHA256SUMS`, `expected-gates.txt`) is in scope and treated as a vulnerability.
- Release artifacts: provenance/SBOM attestation bypass.

## Supported versions
Only the `main` branch is supported.

# Security policy

## Reporting a vulnerability
Report vulnerabilities **privately** through GitHub private vulnerability reporting:
https://github.com/Demiurg-AU/rust-cicd-core/security/advisories/new

Please do not open a public issue for a vulnerability. Include the affected commit or release, a minimal reproduction, and the impact you expect.

## Disclosure process and timeline
- Acknowledgement within **7 days** of the report.
- Assessment and severity (CVSS) within **14 days**.
- Fix or mitigation target: **30 days** for high/critical, **90 days** otherwise.
- Coordinated disclosure: a GitHub Security Advisory (with CVE where applicable) is published when the fix is released, or after **90 days** at the latest, crediting the reporter unless they prefer otherwise.

## Scope
- `scripts/ci-local.sh` and the GitHub workflows: any way to make a gate report PASS without performing its check ("silent skip"), to bypass a canary, or to forge or replace evidence (`results.tsv`, `SHA256SUMS`, `expected-gates.txt`) is a vulnerability.
- Release artifacts: bypass of provenance or SBOM attestation verification.
- The threat model in `threat-model.tsv` lists known PARTIAL/OPEN threats with tracking issues; those are known gaps, not new reports.

## Supported versions
Only the `main` branch is supported.

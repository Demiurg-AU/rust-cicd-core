# K1 — owner approval as a signature

Status: **implemented, mode `observe`** (owner decision 2026-11-24: use K1; key ed25519
`SHA256:1PwNTB4rzqGJvTb+Ti+XykVpfnzKZVZmJ4ryaJ+XBxw`, private key on the owner's machine only; the agent gets its
own GitHub App identity). `scripts/agent-pr-policy.sh` verifies the signature on every pipeline PR.

| `.github/k1-mode` | what approves a pipeline PR |
|---|---|
| `off` | the `owner-approved-pipeline` label (as before K1) |
| `observe` | still the label; the status also says whether `required` would ACCEPT or BLOCK the PR |
| `required` | a valid signature only; the label alone approves nothing |

Switching to `required` is a separate pipeline PR, made only after `observe` has shown both cases on a live PR:
a valid signature ("would ACCEPT") and the label without a signature ("would BLOCK").

## How the owner signs (own machine, own `gh` session)

```
git -C ~/rcc-verify pull --ff-only
bash ~/rcc-verify/scripts/k1-sign.sh Demiurg-AU/rust-cicd-core <PR> ~/.ssh/rcc-approval 24
```

The script reads the live repository id, head, base and the default branch's policy blob, shows the text, asks for
`yes`, signs (`ssh-keygen -Y sign -n rcc-approval`) and posts the comment. One more push to the PR, a moved base or a
changed policy voids the approval: sign again.

## What the owner signs

One UTF-8 text, LF line endings, exactly these lines in this order (`ssh-keygen -Y sign -n rcc-approval`):

```
RCC-APPROVAL-V1
repository: <owner>/<repo> (id <numeric repository id>)
pr: <number>
action: merge-pipeline-change
head: <40-hex head commit of the PR>
base: <40-hex base commit the PR was checked against>
policy: <40-hex blob id of scripts/agent-pr-policy.sh on the base>
expires: <UTC timestamp, at most 72 h after signing>
nonce: <32 hex random>
```

- **head** binds the approval to the exact code: one more push makes it void (as the label revocation does today).
- **base** binds it to what the PR was checked against: with K8 (strict up to date), a moved base forces a new
  check and therefore a new approval.
- **policy** binds it to the rules the owner approved under: an approval cannot be replayed under a weakened policy.
- **expires** and **nonce** stop replay of an old approval; the policy records used nonces in the PR's status.

## Verification (agent-pr-policy, base version)

1. The PR comment holds the text above and an `-----BEGIN SSH SIGNATURE-----` block.
2. `ssh-keygen -Y verify -f allowed_signers -I owner -n rcc-approval` succeeds; `allowed_signers` is read from the
   **base** commit (the PR cannot add its own key).
3. The policy REBUILDS the text from live values (repository name and id, PR number, head, base, its own blob id) plus
   `expires` and `nonce` from the comment, so a signature over any other value cannot verify; `expires` must be in
   the future and at most 72 h ahead; `nonce` must be 32 hex. Nonces are not recorded across PRs: a replay can only
   re-approve the identical head, base and policy it was signed for, within its expiry.
4. Otherwise: the policy fails with the first field that did not match.

## Canaries (ci-local.sh, threat CI-7)

A3 valid signature approves (required); A4 observe reports "would BLOCK" for the label alone; C98 label alone;
C99 key not in allowed_signers; C100 other head; C101 other base; C102 other policy blob; C103 expired;
C104 expiry more than 72 h ahead; C105 a field changed after signing.

## Owner decisions (2026-11-24)

1. K1 is used; `required` after both cases were seen in `observe`.
2. Private key: `~/.ssh/rcc-approval` on the owner's machine, passphrase-protected, never in the agent's environment.
3. The agent moves to its own GitHub App (repository-scoped, no administration, no ruleset bypass).

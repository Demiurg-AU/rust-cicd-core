# K1 — owner approval as a signature (specification, decision open)

Status: **owner decision open**. Nothing here is wired into the policy yet; `agent-pr-policy.sh` still reads the
`owner-approved-pipeline` label (threat CI-1 residual, #45 item 6: an agent holding the owner's token can apply it).

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
3. Every field equals the live value (repository id, PR number, head, base, policy blob); `expires` is in the future.
4. Otherwise: the policy fails with the first field that did not match.

## Canaries (to add with the implementation)

- signature by a key not in the base's `allowed_signers`;
- correct signature, other head (one more push);
- correct signature, other base;
- correct signature, other policy blob;
- expired;
- the label alone, without a signature.

## What the owner has to decide

1. Use K1 at all, or keep the label (and accept residual #45 item 6).
2. Where the private key lives (hardware key recommended); the agent's environment must not have it.
3. Whether the agent keeps the owner's GitHub token (then K1 is the only barrier) or gets its own identity (App).

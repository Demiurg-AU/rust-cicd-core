#!/usr/bin/env bash
# agent-pr-facts.sh <owner/repo> <pr-number> <out-dir>  -- collects PR facts for agent-pr-policy.sh via the GitHub API
set -euo pipefail
R="${1:?repo}" N="${2:?pr}" O="${3:?out dir}"
mkdir -p "$O"
gh api "repos/$R/pulls/$N" --jq '.head.ref' > "$O/branch.txt"
gh api "repos/$R/pulls/$N" --jq '.head.sha' > "$O/head_sha.txt"
gh api "repos/$R/pulls/$N" --jq '.labels[].name' > "$O/labels_now.txt"
# time of the latest push to the PR branch (approval must be newer); empty -> policy fails closed
gh api "repos/$R/activity?ref=refs/heads/$(cat "$O/branch.txt")&per_page=1" --jq '.[0].timestamp // empty' > "$O/pushed_at.txt" || : > "$O/pushed_at.txt"
gh api --paginate "repos/$R/pulls/$N/commits" --jq '.[] | [(.author.login // "-"), (.committer.login // "-"),
  (if (.commit.message | test("(?im)^co-authored-by:.*(claude|copilot|codex|openai|anthropic)")) then "1" else "0" end),
  .sha] | @tsv' > "$O/commits.tsv"
# renames: the SOURCE path counts too (moving a workflow away is a pipeline change)
gh api --paginate "repos/$R/pulls/$N/files" --jq '.[] | .filename, (.previous_filename // empty)' > "$O/files.txt"
gh api --paginate "repos/$R/issues/$N/events" --jq '.[] | select(.event == "labeled") |
  [.label.name, .actor.login, .actor.type, .created_at] | @tsv' > "$O/labels.tsv"
# every review-state comment with its author identity; the policy trusts only the exact integration
gh api --paginate "repos/$R/issues/$N/comments" --jq '.[] | . as $c | .body |
  (capture("codex-review-state:v1 (?<j>\\{.*\\})")? // empty) | .j | fromjson |
  [.code_review.commit_sha, .code_review.status, (.code_review.has_unresolved_findings | tostring),
   $c.user.login, $c.user.type] | @tsv' > "$O/codex.tsv"
gh api "repos/$R" --jq '.owner.login' > "$O/owners.txt"

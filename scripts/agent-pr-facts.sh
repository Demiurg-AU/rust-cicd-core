#!/usr/bin/env bash
# agent-pr-facts.sh <owner/repo> <pr-number> <out-dir>  -- collects PR facts for agent-pr-policy.sh via the GitHub API
set -euo pipefail
R="${1:?repo}" N="${2:?pr}" O="${3:?out dir}"
mkdir -p "$O"
gh api "repos/$R/pulls/$N" --jq '.head.ref' > "$O/branch.txt"
gh api "repos/$R/pulls/$N" --jq '.head.sha' > "$O/head_sha.txt"
gh api "repos/$R/pulls/$N" --jq '.labels[].name' > "$O/labels_now.txt"
gh api --paginate "repos/$R/pulls/$N/commits" --jq '.[] | [(.author.login // "-"), (.committer.login // "-"),
  (if (.commit.message | test("(?im)^co-authored-by:.*(claude|copilot|codex|openai|anthropic)")) then "1" else "0" end),
  .sha] | @tsv' > "$O/commits.tsv"
gh api --paginate "repos/$R/pulls/$N/files" --jq '.[].filename' > "$O/files.txt"
gh api --paginate "repos/$R/issues/$N/events" --jq '.[] | select(.event == "labeled") |
  [.label.name, .actor.login, .actor.type, .created_at] | @tsv' > "$O/labels.tsv"
gh api --paginate "repos/$R/issues/$N/comments" --jq '.[] | select(.user.login | test("codex"; "i")) | .body |
  (capture("codex-review-state:v1 (?<j>\\{.*\\})")? // empty) | .j | fromjson |
  [.code_review.commit_sha, .code_review.status, (.code_review.has_unresolved_findings | tostring)] | @tsv' > "$O/codex.tsv"
gh api "repos/$R" --jq '.owner.login' > "$O/owners.txt"

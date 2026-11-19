---
name: gh-git-ops
description: >-
  Safe scripts for pushing, force-pushing (--force-with-lease), creating GitHub PRs, posting inline
  PR review comments, requesting changes, and deleting branches, with an optional --as <account> to
  run as one of @@KIT_GH_ACCOUNTS@@. Use whenever an agent needs to push,
  force-push, open a PR, comment on PR lines, request changes, or delete a local/remote branch, e.g.
  "push this", "force push", "open a PR", "comment on line 42", "request changes", "delete the branch".
  Any agent may call it at any time.
---

# gh-git-ops

Bash scripts, run from inside the repo. From PowerShell, call them via `bash`.

## Fill-in templates

Copy a command, replace every `<PLACEHOLDER>` (keep the quotes), drop optional lines you don't need.

| Placeholder | Meaning |
|---|---|
| `<ACCOUNT>` | one of @@KIT_GH_ACCOUNTS@@; omit `--as <ACCOUNT>` to use the active account |
| `<BRANCH>` | branch name, e.g. `feat/MYH-1234-short-name` |
| `<BASE_BRANCH>` | PR target branch, e.g. `main` or `develop` |
| `<PR_TITLE>` | PR title, conventional-commit style, e.g. `feat: add login page` |
| `<PR_DESCRIPTION>` | PR body (markdown) |

### Push current branch
```bash
bash .github/skills/gh-git-ops/scripts/push.sh --as <ACCOUNT>
```

### Force-push current branch (only when the user asked)
```bash
bash .github/skills/gh-git-ops/scripts/force-push.sh --as <ACCOUNT>
```

### Create a PR from the current branch
```bash
bash .github/skills/gh-git-ops/scripts/create-pr.sh --as <ACCOUNT> \
  --base "<BASE_BRANCH>" \
  --title "<PR_TITLE>" \
  --body "$(cat <<'PR_BODY'
## Summary
<PR_DESCRIPTION>

## Changes
- <CHANGE_1>
- <CHANGE_2>

## Testing
- <HOW_IT_WAS_TESTED>
PR_BODY
)"
```
Optional: add `--draft`, or pass extra `gh pr create` flags after `--`, e.g. `-- --reviewer <REVIEWER> --label <LABEL>`.
Append the repo's required attribution line to the body if there is one.

### Post inline review comments on a PR
`<FILE_PATH>` is repo-relative (e.g. `src/app/login.ts`). `<LINE>` is the line number in the PR's new version of the file, or a range `<START>-<END>`; the line must be part of the PR diff. Repeat `--comment` once per comment. Omit `--pr` to use the current branch's PR.
```bash
bash .github/skills/gh-git-ops/scripts/post-comment.sh --as <ACCOUNT> --pr <PR_NUMBER> \
  --body "<REVIEW_SUMMARY>" \
  --comment "<FILE_PATH>" <LINE> "<COMMENT_TEXT>" \
  --comment "<FILE_PATH>" <START>-<END> "<COMMENT_TEXT>"
```
Only a general PR comment (no line): pass just `--body "<COMMENT_TEXT>"`.

### Request changes on a PR
Same as above, `--body` is required. GitHub rejects requesting changes on your own PR.
```bash
bash .github/skills/gh-git-ops/scripts/request-changes.sh --as <ACCOUNT> --pr <PR_NUMBER> \
  --body "<WHY_CHANGES_ARE_NEEDED>" \
  --comment "<FILE_PATH>" <LINE> "<WHAT_TO_CHANGE>"
```
Add `--dry-run` to either script to print the GitHub API call without posting.

### Delete a branch (only when the user asked)
```bash
bash .github/skills/gh-git-ops/scripts/delete-branch.sh "<BRANCH>" --as <ACCOUNT>                  # local (merged only) + origin
bash .github/skills/gh-git-ops/scripts/delete-branch.sh "<BRANCH>" --local-only --force            # local, even if unmerged
bash .github/skills/gh-git-ops/scripts/delete-branch.sh "<BRANCH>" --remote-only --as <ACCOUNT>    # origin only
```

Every script accepts `--as <account>` (one of @@KIT_GH_ACCOUNTS@@): it switches gh to that account via the `gh-switch-account` skill for the run and switches back afterwards. HTTPS pushes to github.com authenticate with the active gh account (gh is the git credential helper), so `--as` controls who pushes. It does **not** change the commit author (`git config user.name/email`).

## Guardrails (built in)
- Protected branches: `main`, `master`, `develop` and the repo's default branch.
- `push.sh` refuses protected branches unless `--allow-protected` (only when the user explicitly asked).
- `force-push.sh` never runs on protected branches and always uses `--force-with-lease`.
- `create-pr.sh` refuses from a protected branch, pushes unpushed commits first, and returns the existing PR URL if one is already open.
- `delete-branch.sh` refuses protected and checked-out branches; local delete is `-d` (merged only) unless `--force`.

## Agent rules
- Force-pushing and deleting branches are destructive: only do them when the user asked for it.
- Follow the repo's PR conventions (title format, attribution lines) when passing `--title`/`--body`.
- Report the result (branch, PR URL, account used) back to the user.

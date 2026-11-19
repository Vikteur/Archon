---
name: gh-switch-account
description: >-
  Switch the active GitHub CLI (gh) account between the accounts
  @@KIT_GH_ACCOUNTS@@. Use whenever a gh or git operation needs a specific account (push/PR/clone rejected with
  403/404, wrong author, repo owned by another account), or when the user says "switch gh account",
  "use <account>", "use my work account". Any agent may call it at any time.
---

# gh-switch-account

Switches `gh auth switch` between the accounts of `gh_accounts` in `.archon/kit.yaml` (all must already be logged in via `gh auth login`):

| Account | Use |
|---|---|
| @@KIT_GH_ACCOUNTS@@ | this project |

## Run

Bash / Git Bash:
```bash
bash .github/skills/gh-switch-account/scripts/gh-switch.sh                              # cycle to next
bash .github/skills/gh-switch-account/scripts/gh-switch.sh <account>                    # explicit
bash .github/skills/gh-switch-account/scripts/gh-switch.sh --status                     # show active
```

PowerShell:
```powershell
& ".github\skills\gh-switch-account\scripts\gh-switch.ps1"            # cycle to next
& ".github\skills\gh-switch-account\scripts\gh-switch.ps1" <account>
& ".github\skills\gh-switch-account\scripts\gh-switch.ps1" -Status
```

## Notes
- Always pass an explicit account name; cycling (through @@KIT_GH_ACCOUNTS@@ in that order) depends on current state.
- Names are case-insensitive.
- The switch is global for the machine's gh config; it affects every terminal and agent. Tell the user which account is now active.
- `git push` over HTTPS uses gh as credential helper only if `gh auth setup-git` was run.

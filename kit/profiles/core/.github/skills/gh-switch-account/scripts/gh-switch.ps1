# Switch the active gh account between @@KIT_GH_ACCOUNTS@@ (gh_accounts in .archon/kit.yaml).
# Usage: gh-switch.ps1            -> cycle to the next account
#        gh-switch.ps1 <account>  -> switch to that account (case-insensitive)
#        gh-switch.ps1 -Status    -> print active account only
param([string]$Account, [switch]$Status)
$ErrorActionPreference = 'Stop'

$Accounts = @('@@KIT_GH_ACCOUNTS@@' -split ',\s*' | Where-Object { $_ })
$HostName = 'github.com'

$active = (gh api user --jq .login 2>$null)

if ($Status) { "active: $(if ($active) { $active } else { 'none' })"; exit 0 }

if ($Account) {
  $target = $Accounts | Where-Object { $_ -ieq $Account } | Select-Object -First 1
  if (-not $target) { Write-Error "unknown account '$Account' (expected one of: $($Accounts -join ', '))"; exit 2 }
} else {
  $i = [Array]::FindIndex([string[]]$Accounts, [Predicate[string]]{ param($a) $a -ieq $active })
  $target = $Accounts[($i + 1) % $Accounts.Count]
}

if ($active -ieq $target) { "already active: $target"; exit 0 }

gh auth switch --hostname $HostName --user $target | Out-Null
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$now = (gh api user --jq .login)
"switched: $(if ($active) { $active } else { 'none' }) -> $now"

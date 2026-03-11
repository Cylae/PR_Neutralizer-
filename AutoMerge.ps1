#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string]$Repo = "Cylae/GoldenCrown",

    [Parameter(Mandatory = $false)]
    [ValidateSet("merge", "squash", "rebase")]
    [string]$MergeMethod = "merge",

    [Parameter(Mandatory = $false)]
    [switch]$DeleteBranch = $true,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR","SUCCESS")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = @{ INFO = "Cyan"; WARN = "Yellow"; ERROR = "Red"; SUCCESS = "Green" }[$Level]
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# ─────────────────────────────────────────────
# PREREQUISITES
# ─────────────────────────────────────────────
function Assert-Prerequisites {
    Write-Log "Checking prerequisites..."

    foreach ($tool in @("git", "gh")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Write-Log "'$tool' not found in PATH." "ERROR"
            throw "Missing required tool: $tool"
        }
        Write-Log "'$tool' found: $((Get-Command $tool).Source)" "SUCCESS"
    }

    # Check gh auth (Sécurisation du flux d'erreur)
    $authStatus = gh auth status 2>&1 | ForEach-Object { $_.ToString() }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "GitHub CLI is not authenticated. Run 'gh auth login'." "ERROR"
        throw "gh auth check failed."
    }
    Write-Log "GitHub CLI authenticated." "SUCCESS"

    # Check repo exists and is accessible (Sécurisation du flux d'erreur)
    $repoCheck = gh repo view $Repo --json name 2>&1 | ForEach-Object { $_.ToString() }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Repository '$Repo' not found or not accessible." "ERROR"
        throw "Repository check failed."
    }
    Write-Log "Repository '$Repo' is accessible." "SUCCESS"
}

# ─────────────────────────────────────────────
# FETCH OPEN PRs
# ─────────────────────────────────────────────
function Get-OpenPullRequests {
    Write-Log "Fetching open pull requests from '$Repo'..."

    # Sécurisation du flux d'erreur pour éviter le NativeCommandError
    $raw = gh pr list --repo $Repo --state open --json number,title,headRefName,mergeable,statusCheckRollup `
        --jq '.[] | [.number, .title, .headRefName, .mergeable] | @tsv' 2>&1 | ForEach-Object { $_.ToString() }

    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to fetch PRs: $raw" "ERROR"
        throw "gh pr list failed."
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $prs = @()
    # Concaténation et découpage conformes à PS 5.1
    foreach ($line in ($raw -split "`n" | Where-Object { $_ -match '\S' })) {
        $parts = $line -split "`t"
        if ($parts.Count -ge 4) {
            $prs += [PSCustomObject]@{
                Number    = [int]($parts[0].Trim())
                Title     = $parts[1].Trim()
                Branch    = $parts[2].Trim()
                Mergeable = $parts[3].Trim()
            }
        }
    }

    Write-Log "Found $($prs.Count) open PR(s)." "INFO"
    return $prs
}

# ─────────────────────────────────────────────
# MERGE ONE PR
# ─────────────────────────────────────────────
function Invoke-MergePR {
    param([PSCustomObject]$PR)

    Write-Log "Processing PR #$($PR.Number): '$($PR.Title)' [$($PR.Branch)]"

    # Mergeability check
    if ($PR.Mergeable -eq "CONFLICTING") {
        Write-Log "PR #$($PR.Number) has conflicts — skipping." "WARN"
        return [PSCustomObject]@{ PR = $PR.Number; Status = "SKIPPED"; Reason = "Merge conflict" }
    }

    if ($PR.Mergeable -eq "UNKNOWN") {
        Write-Log "PR #$($PR.Number) mergeability is unknown — attempting anyway." "WARN"
    }

    if ($DryRun) {
        Write-Log "[DRY-RUN] Would merge PR #$($PR.Number) via '$MergeMethod'." "WARN"
        return [PSCustomObject]@{ PR = $PR.Number; Status = "DRY-RUN"; Reason = "Dry run mode" }
    }

    $mergeArgs = @(
        "pr", "merge", $PR.Number,
        "--repo", $Repo,
        "--$MergeMethod"
    )
    if ($DeleteBranch) { $mergeArgs += "--delete-branch" }

    # Sécurisation du flux d'erreur
    $output = & gh @mergeArgs 2>&1 | ForEach-Object { $_.ToString() }
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Write-Log "PR #$($PR.Number) failed (exit $exitCode): $output" "ERROR"
        return [PSCustomObject]@{ PR = $PR.Number; Status = "FAILED"; Reason = $output }
    }

    Write-Log "PR #$($PR.Number) merged successfully." "SUCCESS"
    return [PSCustomObject]@{ PR = $PR.Number; Status = "MERGED"; Reason = "" }
}

# ─────────────────────────────────────────────
# REPORT
# ─────────────────────────────────────────────
function Write-Report {
    param([array]$Results)

    Write-Log "─────────────────── REPORT ───────────────────" "INFO"
    $Results | ForEach-Object {
        $level = switch ($_.Status) {
            "MERGED"  { "SUCCESS" }
            "SKIPPED" { "WARN"    }
            "FAILED"  { "ERROR"   }
            default   { "INFO"    }
        }
        $msg = "PR #$($_.PR) → $($_.Status)"
        if ($_.Reason) { $msg += " ($($_.Reason))" }
        Write-Log $msg $level
    }

    $merged  = ($Results | Where-Object { $_.Status -eq "MERGED"  }).Count
    $skipped = ($Results | Where-Object { $_.Status -eq "SKIPPED" }).Count
    $failed  = ($Results | Where-Object { $_.Status -eq "FAILED"  }).Count

    Write-Log "Total: $($Results.Count) | Merged: $merged | Skipped: $skipped | Failed: $failed" "INFO"

    if ($failed -gt 0) {
        Write-Log "Some PRs failed. Review errors above." "WARN"
        exit 1
    }
}

# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────
try {
    Write-Log "=== PR Auto-Merge Script starting ==="
    if ($DryRun) { Write-Log "DRY-RUN mode enabled — no changes will be made." "WARN" }

    Assert-Prerequisites

    $openPRs = Get-OpenPullRequests

    if ($openPRs.Count -eq 0) {
        Write-Log "No open PRs found. Nothing to do." "SUCCESS"
        exit 0
    }

    $results = @()
    foreach ($pr in $openPRs) {
        $results += Invoke-MergePR -PR $pr
    }

    Write-Report -Results $results
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    exit 2
}
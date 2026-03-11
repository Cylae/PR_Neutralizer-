#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────
#  LOGGING
# ─────────────────────────────────────────────
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","PROMPT")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = @{
        INFO    = "Cyan"
        WARN    = "Yellow"
        ERROR   = "Red"
        SUCCESS = "Green"
        PROMPT  = "Magenta"
    }[$Level]
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Write-Banner {
    param([string]$Text)
    $line = "─" * ($Text.Length + 4)
    Write-Host ""
    Write-Host "  $line"  -ForegroundColor DarkCyan
    Write-Host "  │ $Text │" -ForegroundColor Cyan
    Write-Host "  $line"  -ForegroundColor DarkCyan
    Write-Host ""
}

# ─────────────────────────────────────────────
#  SAFE READ-HOST (never empty unless allowed)
# ─────────────────────────────────────────────
function Read-Input {
    param(
        [string]$Prompt,
        [string]$Default = "",
        [switch]$AllowEmpty
    )
    while ($true) {
        if ($Default) {
            Write-Host "  ► $Prompt " -ForegroundColor Magenta -NoNewline
            Write-Host "[défaut: $Default] " -ForegroundColor DarkGray -NoNewline
        } else {
            Write-Host "  ► $Prompt " -ForegroundColor Magenta -NoNewline
        }
        $input = (Read-Host).Trim()
        if ([string]::IsNullOrWhiteSpace($input)) {
            if ($Default) { return $Default }
            if ($AllowEmpty) { return "" }
            Write-Log "Ce champ est requis." "WARN"
        } else {
            return $input
        }
    }
}

function Read-Choice {
    param(
        [string]$Prompt,
        [string[]]$Options,
        [string]$Default
    )
    Write-Host ""
    Write-Host "  ► $Prompt" -ForegroundColor Magenta
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = if ($Options[$i] -eq $Default) { " ◄ défaut" } else { "" }
        Write-Host "      [$($i+1)] $($Options[$i])$marker" -ForegroundColor White
    }
    while ($true) {
        Write-Host "  Choix (1-$($Options.Count)): " -ForegroundColor Magenta -NoNewline
        $raw = (Read-Host).Trim()
        if ([string]::IsNullOrWhiteSpace($raw) -and $Default) { return $Default }
        if ($raw -match '^\d+$') {
            $idx = [int]$raw - 1
            if ($idx -ge 0 -and $idx -lt $Options.Count) { return $Options[$idx] }
        }
        Write-Log "Choix invalide. Entrez un numéro entre 1 et $($Options.Count)." "WARN"
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { "O/n" } else { "o/N" }
    while ($true) {
        Write-Host "  ► $Prompt [$hint]: " -ForegroundColor Magenta -NoNewline
        $raw = (Read-Host).Trim().ToLower()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        if ($raw -in @("o","oui","y","yes")) { return $true  }
        if ($raw -in @("n","non","no"))      { return $false }
        Write-Log "Répondez par o (oui) ou n (non)." "WARN"
    }
}

# ─────────────────────────────────────────────
#  PREREQUISITES
# ─────────────────────────────────────────────
function Assert-Prerequisites {
    Write-Log "Vérification des prérequis..."
    foreach ($tool in @("git", "gh")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Write-Log "'$tool' est introuvable dans le PATH." "ERROR"
            throw "Outil manquant : $tool. Installez-le et relancez le script."
        }
        Write-Log "'$tool' détecté : $((Get-Command $tool).Source)" "SUCCESS"
    }

    $authCheck = gh auth status 2>&1 | ForEach-Object { $_.ToString() }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "GitHub CLI non authentifié." "ERROR"
        Write-Log "Lancez 'gh auth login' puis relancez le script." "WARN"
        throw "Authentification GitHub requise."
    }
    Write-Log "GitHub CLI authentifié." "SUCCESS"
}

# ─────────────────────────────────────────────
#  REPO RESOLUTION
# ─────────────────────────────────────────────
function Resolve-Repo {
    param([string]$Input)

    # Format owner/repo direct
    if ($Input -match '^[\w.\-]+/[\w.\-]+$') { return $Input }

    # URL GitHub
    if ($Input -match 'github\.com[:/]([\w.\-]+/[\w.\-]+?)(?:\.git)?$') {
        return $Matches[1]
    }

    # Nom court → cherche dans les repos de l'utilisateur
    Write-Log "Recherche du repo '$Input' dans vos repos GitHub..." "INFO"
    $found = gh repo list --limit 200 --json nameWithOwner --jq ".[].nameWithOwner" 2>&1 | ForEach-Object { $_.ToString() } |
             Where-Object { $_ -like "*/$Input" -or $_ -eq $Input }

    if ($found -is [string] -and $found) { return $found }
    if ($found -is [array]  -and $found.Count -eq 1) { return $found[0] }
    if ($found -is [array]  -and $found.Count -gt 1) {
        Write-Log "Plusieurs repos correspondent à '$Input' :" "WARN"
        return Read-Choice -Prompt "Lequel voulez-vous utiliser ?" -Options $found -Default $found[0]
    }

    throw "Impossible de résoudre le repo '$Input'. Utilisez le format owner/repo."
}

# ─────────────────────────────────────────────
#  FETCH PRs (avec filtre optionnel de branche)
# ─────────────────────────────────────────────
function Get-OpenPullRequests {
    param([string]$Repo, [string]$BranchFilter = "")

    Write-Log "Récupération des Pull Requests ouvertes sur '$Repo'..."

    $raw = gh pr list --repo $Repo --state open `
        --json number,title,headRefName,baseRefName,author,mergeable,createdAt `
        --jq '.[] | [.number, .title, .headRefName, .baseRefName, .author.login, .mergeable, .createdAt] | @tsv' 2>&1 | ForEach-Object { $_.ToString() }

    if ($LASTEXITCODE -ne 0) {
        Write-Log "Échec de la récupération des PRs : $raw" "ERROR"
        throw "gh pr list a échoué."
    }

    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    $prs = @()
    foreach ($line in ($raw -split "`n" | Where-Object { $_ -match '\S' })) {
        $p = $line -split "`t"
        if ($p.Count -ge 6) {
            $pr = [PSCustomObject]@{
                Number    = [int]($p[0].Trim())
                Title     = $p[1].Trim()
                Head      = $p[2].Trim()
                Base      = $p[3].Trim()
                Author    = $p[4].Trim()
                Mergeable = $p[5].Trim()
                CreatedAt = $p[6].Trim()
            }
            # Filtre de branche cible si spécifié
            if ($BranchFilter -and $pr.Base -ne $BranchFilter -and $pr.Head -ne $BranchFilter) {
                continue
            }
            $prs += $pr
        }
    }
    return $prs
}

# ─────────────────────────────────────────────
#  AFFICHAGE DE LA LISTE DES PRs
# ─────────────────────────────────────────────
function Show-PRTable {
    param([array]$PRs)
    Write-Host ""
    Write-Host ("  {0,-6} {1,-45} {2,-22} {3,-12} {4}" -f "N°", "Titre", "Branche HEAD → BASE", "Auteur", "Mergeable") -ForegroundColor DarkCyan
    Write-Host ("  " + "─" * 105) -ForegroundColor DarkGray
    foreach ($pr in $PRs) {
        $mergeColor = switch ($pr.Mergeable) {
            "MERGEABLE"   { "Green"  }
            "CONFLICTING" { "Red"    }
            default       { "Yellow" }
        }
        $branches = "$($pr.Head) → $($pr.Base)"
        Write-Host ("  {0,-6} {1,-45} {2,-22} {3,-12}" -f "#$($pr.Number)", ($pr.Title -replace '.{44}$','…'), ($branches -replace '.{21}$','…'), $pr.Author) -ForegroundColor White -NoNewline
        Write-Host (" $($pr.Mergeable)") -ForegroundColor $mergeColor
    }
    Write-Host ""
}

# ─────────────────────────────────────────────
#  SÉLECTION DES PRs À MERGER
# ─────────────────────────────────────────────
function Select-PRsToMerge {
    param([array]$AllPRs)

    Write-Host "  ► Quelles PRs merger ?" -ForegroundColor Magenta
    Write-Host "      [1] Toutes les PRs mergeables" -ForegroundColor White
    Write-Host "      [2] Seulement certaines PRs (saisie manuelle)" -ForegroundColor White
    Write-Host "      [3] Exclure certaines PRs" -ForegroundColor White
    Write-Host "  Choix (1-3): " -ForegroundColor Magenta -NoNewline

    $choice = (Read-Host).Trim()

    switch ($choice) {
        "1" {
            return $AllPRs | Where-Object { $_.Mergeable -ne "CONFLICTING" }
        }
        "2" {
            Write-Log "Entrez les numéros de PRs à merger, séparés par des virgules (ex: 12,15,18)" "PROMPT"
            Write-Host "  Numéros : " -ForegroundColor Magenta -NoNewline
            $raw = (Read-Host).Trim()
            $numbers = $raw -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
            return $AllPRs | Where-Object { $_.Number -in $numbers }
        }
        "3" {
            Write-Log "Entrez les numéros de PRs à EXCLURE, séparés par des virgules" "PROMPT"
            Write-Host "  Numéros à exclure : " -ForegroundColor Magenta -NoNewline
            $raw = (Read-Host).Trim()
            $excluded = $raw -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
            return $AllPRs | Where-Object { $_.Number -notin $excluded -and $_.Mergeable -ne "CONFLICTING" }
        }
        default {
            return $AllPRs | Where-Object { $_.Mergeable -ne "CONFLICTING" }
        }
    }
}

# ─────────────────────────────────────────────
#  MERGE D'UNE PR
# ─────────────────────────────────────────────
function Invoke-MergePR {
    param(
        [PSCustomObject]$PR,
        [string]$Repo,
        [string]$MergeMethod,
        [bool]$DeleteBranch,
        [bool]$DryRun
    )

    Write-Log "PR #$($PR.Number) — '$($PR.Title)' ($($PR.Head) → $($PR.Base))" "INFO"

    if ($PR.Mergeable -eq "CONFLICTING") {
        Write-Log "PR #$($PR.Number) ignorée : conflits détectés." "WARN"
        return [PSCustomObject]@{ Number = $PR.Number; Title = $PR.Title; Status = "SKIPPED"; Reason = "Conflit" }
    }

    if ($DryRun) {
        Write-Log "[DRY-RUN] Aurait mergé PR #$($PR.Number) via '$MergeMethod'." "WARN"
        return [PSCustomObject]@{ Number = $PR.Number; Title = $PR.Title; Status = "DRY-RUN"; Reason = "" }
    }

    $args = @("pr", "merge", $PR.Number, "--repo", $Repo, "--$MergeMethod")
    if ($DeleteBranch) { $args += "--delete-branch" }

    $output = & gh @args 2>&1 | ForEach-Object { $_.ToString() }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Échec PR #$($PR.Number) : $output" "ERROR"
        return [PSCustomObject]@{ Number = $PR.Number; Title = $PR.Title; Status = "FAILED"; Reason = "$output" }
    }

    Write-Log "PR #$($PR.Number) mergée avec succès." "SUCCESS"
    return [PSCustomObject]@{ Number = $PR.Number; Title = $PR.Title; Status = "MERGED"; Reason = "" }
}

# ─────────────────────────────────────────────
#  RAPPORT FINAL
# ─────────────────────────────────────────────
function Write-Report {
    param([array]$Results)

    Write-Banner "RAPPORT FINAL"

    foreach ($r in $Results) {
        $level = switch ($r.Status) {
            "MERGED"  { "SUCCESS" }
            "SKIPPED" { "WARN"    }
            "FAILED"  { "ERROR"   }
            default   { "INFO"    }
        }
        $msg = "PR #$($r.Number) [$($r.Title)] → $($r.Status)"
        if ($r.Reason) { $msg += " ($($r.Reason))" }
        Write-Log $msg $level
    }

    Write-Host ""
    $merged  = ($Results | Where-Object Status -eq "MERGED").Count
    $skipped = ($Results | Where-Object Status -eq "SKIPPED").Count
    $failed  = ($Results | Where-Object Status -eq "FAILED").Count
    $dryrun  = ($Results | Where-Object Status -eq "DRY-RUN").Count

    Write-Host ("  Total : {0}  |  ✓ Mergées : {1}  |  ⚠ Ignorées : {2}  |  ✗ Échouées : {3}  |  ◌ Dry-run : {4}" `
        -f $Results.Count, $merged, $skipped, $failed, $dryrun) -ForegroundColor Cyan
    Write-Host ""

    if ($failed -gt 0) { exit 1 }
}

# ═════════════════════════════════════════════
#  POINT D'ENTRÉE INTERACTIF
# ═════════════════════════════════════════════
try {
    Clear-Host
    Write-Banner "GitHub PR Auto-Merge  ·  Script Universel"

    # ── Prérequis ───────────────────────────
    Assert-Prerequisites

    # ── Repo ────────────────────────────────
    Write-Host ""
    Write-Log "Saisissez le repo cible. Formats acceptés :" "INFO"
    Write-Host "      owner/repo   |   URL GitHub   |   nom court (recherche automatique)" -ForegroundColor DarkGray
    $repoInput = Read-Input -Prompt "Repository"
    $repo = Resolve-Repo -Input $repoInput
    Write-Log "Repo résolu : $repo" "SUCCESS"

    # ── Filtre de branche ────────────────────
    $branchFilter = Read-Input -Prompt "Filtrer par branche (HEAD ou BASE) ? Laissez vide pour tout voir" -AllowEmpty

    # ── Récupération des PRs ─────────────────
    $allPRs = Get-OpenPullRequests -Repo $repo -BranchFilter $branchFilter

    if ($allPRs.Count -eq 0) {
        Write-Log "Aucune Pull Request ouverte trouvée. Rien à faire." "SUCCESS"
        exit 0
    }

    Write-Log "$($allPRs.Count) PR(s) trouvée(s) :" "INFO"
    Show-PRTable -PRs $allPRs

    # ── Sélection des PRs ────────────────────
    $selectedPRs = Select-PRsToMerge -AllPRs $allPRs

    if ($selectedPRs.Count -eq 0) {
        Write-Log "Aucune PR sélectionnée. Annulation." "WARN"
        exit 0
    }

    Write-Log "$($selectedPRs.Count) PR(s) sélectionnée(s) pour le merge." "INFO"

    # ── Méthode de merge ─────────────────────
    $mergeMethod = Read-Choice `
        -Prompt "Méthode de merge :" `
        -Options @("merge", "squash", "rebase") `
        -Default "merge"

    # ── Suppression de branche ───────────────
    $deleteBranch = Read-YesNo -Prompt "Supprimer les branches après merge ?" -Default $true

    # ── Mode Dry-Run ─────────────────────────
    $dryRun = Read-YesNo -Prompt "Mode Dry-Run ? (simulation sans modification)" -Default $false

    # ── Confirmation finale ──────────────────
    Write-Host ""
    Write-Host "  ┌─ Récapitulatif ──────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  │  Repo          : $repo" -ForegroundColor White
    $prNumbers = $selectedPRs | ForEach-Object { "#$($_.Number)" }
    $prString = $prNumbers -join ', '
    Write-Host "  │  PRs           : $prString" -ForegroundColor White
    Write-Host "  │  Méthode       : $mergeMethod" -ForegroundColor White
    Write-Host "  │  Suppr. branch : $deleteBranch" -ForegroundColor White
    Write-Host "  │  Dry-Run       : $dryRun" -ForegroundColor White
    Write-Host "  └───────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    $confirm = Read-YesNo -Prompt "Confirmer et lancer l'opération ?" -Default $true
    if (-not $confirm) {
        Write-Log "Opération annulée par l'utilisateur." "WARN"
        exit 0
    }

    # ── Exécution ────────────────────────────
    Write-Banner "Exécution"
    $results = @()
    foreach ($pr in $selectedPRs) {
        $results += Invoke-MergePR -PR $pr -Repo $repo -MergeMethod $mergeMethod `
                                   -DeleteBranch $deleteBranch -DryRun $dryRun
    }

    Write-Report -Results $results
}
catch {
    Write-Log "ERREUR FATALE : $($_.Exception.Message)" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    exit 2
}

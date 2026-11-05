# install-mods.ps1 — instala MODS do Claude Code (templates/mods/<nome>/) em ~/.claude/skills/<nome>.
# Passo OPT-IN (-WithMods) e NÃO bloqueante: falha vira WARN, nunca Failed. Pasta com
# .claude-plugin/plugin.json em ~/.claude/skills/ carrega como @skills-dir (sem enabledPlugins nem
# trust). Mod não tem sandbox e o terminal exige Claude Code v2.1.287+ — por isso é opt-in e fica
# FORA de templates/global-claude (que é espelhado por inteiro em todo install).
# Requer lib.ps1 carregado (Write-Step, Backup-File, Get-FileSha256). PS 5.1+ e PS 7+.

Set-StrictMode -Version Latest

function Get-ModPlan {
    # PURA (só lê). Para cada pasta de $ModsRoot devolve { Name; Src; Dst; Files; State }.
    # State: 'ausente' (nada no destino) | 'ok' (todo arquivo idêntico) | 'divergente'.
    param(
        [Parameter(Mandatory)][string]$ModsRoot,
        [Parameter(Mandatory)][string]$SkillsDir
    )
    if (-not (Test-Path -LiteralPath $ModsRoot -PathType Container)) { return @() }
    foreach ($dir in (Get-ChildItem -LiteralPath $ModsRoot -Directory | Sort-Object Name)) {
        $dst = Join-Path $SkillsDir $dir.Name
        $root = $dir.FullName
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {
                [pscustomobject]@{ Rel = $_.FullName.Substring($root.Length).TrimStart('\', '/'); Src = $_.FullName }
            })
        $state = 'ok'
        if (-not (Test-Path -LiteralPath $dst -PathType Container)) { $state = 'ausente' }
        else {
            foreach ($f in $files) {
                if ((Get-FileSha256 -Path $f.Src) -ne (Get-FileSha256 -Path (Join-Path $dst $f.Rel))) { $state = 'divergente'; break }
            }
        }
        [pscustomobject]@{ Name = $dir.Name; Src = $root; Dst = $dst; Files = $files; State = $state }
    }
}

function Invoke-ModsSetup {
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$UserHome,
        [switch]$Check,
        [switch]$DryRun
    )
    try {
        $skillsDir = Join-Path (Join-Path $UserHome '.claude') 'skills'
        $plan = @(Get-ModPlan -ModsRoot (Join-Path $RepoRoot 'templates/mods') -SkillsDir $skillsDir)
        if ($plan.Count -eq 0) { Write-Step SKIP 'nenhum mod em templates/mods'; $Summary.Skipped++; return }
        foreach ($m in $plan) {
            if ($m.State -eq 'ok') { Write-Step SKIP "mod $($m.Name): já instalado e idêntico"; $Summary.Skipped++; continue }
            if ($Check)  { Write-Step INFO "mod $($m.Name): $($m.State) (-Check, nada alterado)"; continue }
            if ($DryRun) { Write-Step DRY  "mod $($m.Name): instalaria $($m.Files.Count) arquivo(s) em $($m.Dst) [$($m.State)]"; continue }
            foreach ($f in $m.Files) {
                $dstFile = Join-Path $m.Dst $f.Rel
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dstFile)
                $bak = Backup-File -Path $dstFile
                if ($bak) { Write-Step BACKUP (Split-Path -Leaf $bak); $Summary.Backup++ }
                Copy-Item -LiteralPath $f.Src -Destination $dstFile -Force
            }
            Write-Step INSTALL "mod $($m.Name) ($($m.State) → instalado em $($m.Dst)); abra uma sessão nova do Claude Code (v2.1.287+)"
            $Summary.Installed++
        }
    }
    catch {
        Write-Step WARN "mods: $($_.Exception.Message)"
        $Summary.Warn++
    }
}

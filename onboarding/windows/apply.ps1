# apply.ps1 — orquestrador Windows. Executa A1 (CLIs) + A2 (baseline ~/.claude).
# Normalmente chamado por ../install.ps1, mas pode rodar direto.
# Compatível com Windows PowerShell 5.1+ e PowerShell 7+.

[CmdletBinding()]
param(
    [switch]$SkipClis,
    [switch]$Check,
    [switch]$DryRun,
    [switch]$NonInteractive,
    [ValidateSet('Ask', 'Yes', 'No')][string]$ManagedPolicy = 'Ask',
    [switch]$ExtraPlugins,
    [string[]]$Themes = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Carrega helpers e instalador de CLIs.
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'install-clis.ps1')

# Raiz do repo = onboarding/.. (este arquivo está em onboarding/windows/).
$RepoRoot   = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path
$SourceRoot = Join-Path $RepoRoot 'templates\global-claude'
$DestRoot   = Join-Path $env:USERPROFILE '.claude'

$summary = New-InstallSummary
$watch   = [System.Diagnostics.Stopwatch]::StartNew()

$mode = if ($Check) { 'CHECK (sem alterações)' } elseif ($DryRun) { 'DRY-RUN (sem alterações)' } else { 'INSTALAÇÃO' }

# --- Preflight (informativo) ---------------------------------------------
Write-Host ''
Write-Step INFO "Modo: $mode | SkipClis: $SkipClis"
Write-Step INFO "PowerShell: $($PSVersionTable.PSVersion) | ExecutionPolicy: $(Get-ExecutionPolicy)"
if (-not $SkipClis) {
    if (Test-CommandExists 'winget') {
        Write-Step OK   'winget disponível'
    } else {
        Write-Step WARN 'winget ausente — a etapa de CLIs vai falhar (instale o App Installer)'
    }
}
Write-Step INFO "Repo: $RepoRoot"
Write-Host ''

# --- A1: dependências / CLIs ---------------------------------------------
if ($SkipClis) {
    Write-Step SKIP 'A1 (CLIs) pulado por -SkipClis'
}
else {
    Invoke-InstallClis -Summary $summary -Check:$Check -DryRun:$DryRun
}

# --- A2: baseline ~/.claude (descoberta dinâmica) ------------------------
Write-Host ''
Write-Step INFO "Baseline ~/.claude (origem: templates\global-claude)"
$map = Get-BaselineMap -SourceRoot $SourceRoot -DestRoot $DestRoot
if (-not $map -or @($map).Count -eq 0) {
    Write-Step INFO 'Nenhum artefato de baseline encontrado no repo.'
}
else {
    foreach ($item in $map) {
        Install-BaselineItem -Item $item -Summary $summary -Check:$Check -DryRun:$DryRun
    }
}

# --- A2b: shim de conveniência no $PROFILE (New-SddProject / nsp) ----------
Write-Host ''
Write-Step INFO 'Shim do profile (atalho New-SddProject / nsp)'
# Profile do PowerShell 7 (CurrentUserAllHosts). Resolve MyDocuments via API
# para respeitar redirecionamento do OneDrive; independe do host que roda o install.
$pwshProfile = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\profile.ps1'
Install-ProfileShim -ProfilePath $pwshProfile -RepoRoot $RepoRoot -Summary $summary -Check:$Check -DryRun:$DryRun

# --- A2c: context7 MCP (opcional, NÃO bloqueante) ------------------------
# Registra o context7 user-scoped (transporte local npx). Qualquer falha vira WARN —
# nunca quebra A1/A2. Runtime degrada via docs-first (entrada 'unverified').
Write-Host ''
Write-Step INFO 'context7 (MCP, opcional)'
. (Join-Path $PSScriptRoot 'install-mcp.ps1')
Invoke-Context7Setup -Summary $summary -Check:$Check -DryRun:$DryRun

# --- A2e: suplementos extra (OPT-IN via -ExtraPlugins, NÃO bloqueante) ------
# Instala suplementos (plugins/skills) de DOMÍNIO/superfície opcional user-scoped ("global
# dormente"): disponíveis em todo projeto, auto-ativam só no trabalho da categoria. Opt-in de
# propósito p/ não acoplar o scaffold a um domínio (V2). -Themes filtra por tema (vazio = todos;
# -ExtraPlugins sozinho continua = todos, retrocompat). Falha = WARN, nunca quebra A1/A2.
if ($ExtraPlugins) {
    Write-Host ''
    $temaLabel = if ($Themes -and $Themes.Count -gt 0) { " [temas: $($Themes -join ', ')]" } else { '' }
    Write-Step INFO "Suplementos extra (opt-in, user scope)$temaLabel"
    . (Join-Path $PSScriptRoot 'install-plugins.ps1')
    Invoke-PluginsSetup -Summary $summary -Themes $Themes -Check:$Check -DryRun:$DryRun
}

# --- A2d: managed policy (opt-in interativo, exige admin) -----------------
# Política de governança inviolável (topo da hierarquia). NÃO é aplicada à força: pergunta
# ao usuário e exige elevação (UAC) para escrever no caminho de sistema. Em -Check/-DryRun
# só relata o estado, sem perguntar.
Write-Host ''
Write-Step INFO 'Managed policy (opcional, exige admin)'
$mpSource = Join-Path $RepoRoot 'templates\managed-policy\managed-settings.json'
# -NonInteractive sem escolha explícita → não pergunta (pula), p/ não travar automação no prompt.
$mpDecision = $ManagedPolicy
if ($NonInteractive -and $ManagedPolicy -eq 'Ask') { $mpDecision = 'No' }
Install-ManagedPolicy -SourcePath $mpSource -Summary $summary -Check:$Check -DryRun:$DryRun -Decision $mpDecision

$watch.Stop()
Write-Summary -Summary $summary -Elapsed $watch.Elapsed

if (-not $Check -and -not $DryRun -and -not $SkipClis) {
    Write-Host ''
    Write-Step INFO 'Dica: reabra o terminal para carregar os novos comandos no PATH.'
}

# Exit code: 1 se houve falha, senão 0.
if ($summary.Failed -gt 0) { exit 1 } else { exit 0 }

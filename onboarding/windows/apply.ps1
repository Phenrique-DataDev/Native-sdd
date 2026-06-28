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
    [string[]]$Themes = @(),
    [switch]$WithLocalAi,
    [string]$LocalAiModel = 'gpt-oss:20b',
    [string]$LocalAiOllamaHost = 'http://localhost:11434'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Carrega helpers e instalador de CLIs.
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'install-clis.ps1')

# Raiz do repo = onboarding/.. (este arquivo está em onboarding/windows/).
$os          = Get-OnboardingOS
$userHome    = Get-UserHome -OS $os
$nativeHooks = ($os -eq 'Windows')   # reescrever hooks p/ pwsh só no Windows (J4)
$RepoRoot    = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') '..')).Path
$SourceRoot  = Join-Path $RepoRoot 'templates/global-claude'
$DestRoot    = Join-Path $userHome '.claude'

$summary = New-InstallSummary
$watch   = [System.Diagnostics.Stopwatch]::StartNew()

$mode = if ($Check) { 'CHECK (sem alterações)' } elseif ($DryRun) { 'DRY-RUN (sem alterações)' } else { 'INSTALAÇÃO' }

# --- Preflight (informativo) ---------------------------------------------
Write-Host ''
Write-Step INFO "Modo: $mode | SkipClis: $SkipClis"
Write-Step INFO "SO: $os | Home: $userHome"
Write-Step INFO "PowerShell: $($PSVersionTable.PSVersion) | ExecutionPolicy: $(Get-ExecutionPolicy)"
if (-not $SkipClis -and $os -eq 'Windows') {
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
elseif ($os -ne 'Windows') {
    Write-Step SKIP "A1 (CLIs) pulado — em $os as dependências são instaladas por onboarding/install.sh"
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
        Install-BaselineItem -Item $item -Summary $summary -HomePath $userHome -NativeHooks $nativeHooks -Check:$Check -DryRun:$DryRun
    }
}

# --- A2b: shim de conveniência (atalhos nsp/sddcheck) ---------------------
Write-Host ''
if ($os -eq 'Windows') {
    Write-Step INFO 'Shim do profile (atalho New-SddProject / nsp)'
    # Profile do PowerShell 7 (CurrentUserAllHosts). Resolve MyDocuments via API
    # para respeitar redirecionamento do OneDrive; independe do host que roda o install.
    $pwshProfile = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\profile.ps1'
    Install-ProfileShim -ProfilePath $pwshProfile -RepoRoot $RepoRoot -Summary $summary -Check:$Check -DryRun:$DryRun
}
else {
    Write-Step INFO 'Shim de shell (atalhos nsp / sddcheck)'
    # bash sempre; zsh só se o usuário usa zsh (evita criar ~/.zshrc à toa).
    Install-BashShim -RcPath (Join-Path $userHome '.bashrc') -RepoRoot $RepoRoot -Summary $summary -Check:$Check -DryRun:$DryRun
    $zshrc = Join-Path $userHome '.zshrc'
    if ((Test-Path -LiteralPath $zshrc -PathType Leaf) -or (Test-CommandExists 'zsh')) {
        Install-BashShim -RcPath $zshrc -RepoRoot $RepoRoot -Summary $summary -Check:$Check -DryRun:$DryRun
    }
    # fish: sintaxe própria (Get-FishShimBlock); só se o usuário usa fish.
    $fishCfg = Join-Path $userHome '.config/fish/config.fish'
    if ((Test-Path -LiteralPath $fishCfg -PathType Leaf) -or (Test-CommandExists 'fish')) {
        Install-BashShim -RcPath $fishCfg -RepoRoot $RepoRoot -Block (Get-FishShimBlock -RepoRoot $RepoRoot) -Summary $summary -Check:$Check -DryRun:$DryRun
    }
}

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

# --- A2f: local-ai MCP (OPT-IN via -WithLocalAi, NÃO bloqueante) ------------
# Registra o MCP "local-ai" (modelo local via Ollama) user-scoped + prepara o server
# versionado (onboarding/local-ai). Opt-in de propósito: baixa modelo pesado (GBs) e exige
# Ollama/uv. Falha = WARN, nunca quebra A1/A2. O server degrada com mensagem amigável se o
# Ollama não estiver no ar. Reinicie o Claude Code após instalar p/ carregar o MCP.
if ($WithLocalAi) {
    Write-Host ''
    Write-Step INFO "local-ai (MCP local via Ollama, opt-in) [modelo: $LocalAiModel]"
    . (Join-Path $PSScriptRoot 'install-local-ai.ps1')
    $localAiServerDir = Join-Path $RepoRoot 'onboarding/local-ai'
    Invoke-LocalAiSetup -Summary $summary -ServerDir $localAiServerDir -Model $LocalAiModel -OllamaHost $LocalAiOllamaHost -Check:$Check -DryRun:$DryRun
}

# --- A2d: managed policy (opt-in interativo, exige admin) -----------------
# Política de governança inviolável (topo da hierarquia). NÃO é aplicada à força: pergunta
# ao usuário e exige elevação (UAC) para escrever no caminho de sistema. Em -Check/-DryRun
# só relata o estado, sem perguntar.
Write-Host ''
Write-Step INFO 'Managed policy (opcional, exige admin)'
$mpSource = Join-Path $RepoRoot 'templates/managed-policy/managed-settings.json'
# -NonInteractive sem escolha explícita → não pergunta (pula), p/ não travar automação no prompt.
$mpDecision = $ManagedPolicy
if ($NonInteractive -and $ManagedPolicy -eq 'Ask') { $mpDecision = 'No' }
# Caminho de sistema da managed policy por SO (Linux/macOS escrevem via sudo).
$mpDestDir = if ($os -eq 'Windows') { 'C:\Program Files\ClaudeCode' }
             elseif ($os -eq 'macOS') { '/Library/Application Support/ClaudeCode' }
             else { '/etc/claude-code' }
Install-ManagedPolicy -SourcePath $mpSource -Summary $summary -DestDir $mpDestDir -OS $os -Check:$Check -DryRun:$DryRun -Decision $mpDecision

$watch.Stop()
Write-Summary -Summary $summary -Elapsed $watch.Elapsed

if (-not $Check -and -not $DryRun -and -not $SkipClis) {
    Write-Host ''
    Write-Step INFO 'Dica: reabra o terminal para carregar os novos comandos no PATH.'
}

# Exit code: 1 se houve falha, senão 0.
if ($summary.Failed -gt 0) { exit 1 } else { exit 0 }

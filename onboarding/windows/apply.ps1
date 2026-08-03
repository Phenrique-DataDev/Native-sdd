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
    [string]$LocalAiOllamaHost = 'http://localhost:11434',
    [switch]$WithSemanticKb,
    [string]$SemanticKbModel = 'nomic-embed-text',
    [string]$SemanticKbOllamaHost = 'http://localhost:11434',
    [switch]$WithClaudex,
    [switch]$WithHerdr,
    [switch]$WithCliProxy,
    [switch]$SetDefaultShell,
    [switch]$KeepRetired,
    [switch]$Force
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

# --- A0: idempotência versionada (DESIGN_INSTALADOR_UPDATE.md) -----------
# Compara a versão instalada (~/.claude/.native-sdd-version) com o VERSION do checkout atual.
# Sem rede: nunca consulta tags/releases remotas. -Check/-DryRun sempre relatam, nunca pulam
# por versão (só uma instalação REAL pode ser pulada). Addons opt-in (A2e/A2f/A2g) ficam fora
# deste gate — rodam sempre que a flag é passada, para não regredir "só quero ligar um addon".
$versionFile     = Join-Path $RepoRoot 'VERSION'
$currentVersion  = if (Test-Path -LiteralPath $versionFile -PathType Leaf) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { $null }
$installedMarker = Read-NativeSddVersionMarker -Path $DestRoot
$installedVersion = if ($installedMarker) { $installedMarker.InstalledVersion } else { $null }
$upToDate = (-not $Check) -and (-not $DryRun) -and (Test-NativeSddUpToDate -InstalledVersion $installedVersion -CurrentVersion $currentVersion -Force:$Force)

if ($currentVersion) {
    $installedLabel = if ($installedVersion) { $installedVersion } else { '(nenhuma)' }
    Write-Step INFO "Versão instalada: $installedLabel | Versão do checkout: $currentVersion"
    if ($upToDate) {
        Write-Step OK "já atualizado (v$currentVersion) — pulando A1/A2/shim/context7/managed policy; use -Force para refazer"
    }
} else {
    Write-Step WARN 'VERSION não encontrado no checkout — idempotência versionada desativada nesta execução'
}
Write-Host ''

# --- A1: dependências / CLIs ---------------------------------------------
if ($upToDate) {
    Write-Step SKIP 'A1 (CLIs) pulado — já atualizado'
}
elseif ($SkipClis) {
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
if ($upToDate) {
    Write-Step SKIP 'A2 (baseline ~/.claude) pulado — já atualizado'
}
else {
    Write-Step INFO "Baseline ~/.claude (origem: templates\global-claude)"
    $map = Get-BaselineMap -SourceRoot $SourceRoot -DestRoot $DestRoot
    if (-not $map -or @($map).Count -eq 0) {
        Write-Step INFO 'Nenhum artefato de baseline encontrado no repo.'
    }
    else {
        # Lido ANTES de instalar: o manifest é o baseline da rodada anterior. $null = máquina
        # instalada antes desta feature -> Get-BaselineRetirementPlan devolve plano vazio (fail-safe).
        $baselineManifest = Read-BaselineManifest -Path $DestRoot

        # Proveniência dos .json (MERGE_ARRAYS): overlay como entregue na rodada anterior — é o
        # 3º braço do merge, que preserva hook custom do usuário sem quebrar a retirada de entrada.
        $jsonBaselineDir = Join-Path $DestRoot '.native-sdd-json-baseline'

        foreach ($item in $map) {
            Install-BaselineItem -Item $item -Summary $summary -HomePath $userHome -NativeHooks $nativeHooks -JsonBaselineDir $jsonBaselineDir -Check:$Check -DryRun:$DryRun
        }

        # --- Retirada: o que ENTREGAMOS e o framework não entrega mais ------------------------
        if ($KeepRetired) {
            Write-Step SKIP 'baseline: retirada pulada (-KeepRetired)'
        }
        else {
            $retirePlan = Get-BaselineRetirementPlan -Map $map -Manifest $baselineManifest -DestRoot $DestRoot
            if ($null -eq $baselineManifest) {
                # Primeira execução com manifest: nada é retirado, o baseline nasce agora. A partir
                # da PRÓXIMA execução a retirada funciona normalmente.
                Write-Step INFO 'baseline: sem manifest anterior — nada será retirado nesta rodada'
            }
            elseif (@($retirePlan).Count -gt 0) {
                Invoke-BaselineRetirement -Plan $retirePlan -Summary $summary -Check:$Check -DryRun:$DryRun
            }
        }

        # Manifest só é gravado quando a instalação REALMENTE aconteceu (mesma disciplina do
        # Write-NativeSddVersionMarker): em -Check/-DryRun nada é escrito no disco.
        if (-not $Check -and -not $DryRun) {
            Write-BaselineManifest -Path $DestRoot -Content (Get-BaselineManifestContent -Map $map) -Summary $summary
        }
    }
}

# --- A2b: shim de conveniência (atalhos nsp/sddcheck) ---------------------
Write-Host ''
if ($upToDate) {
    Write-Step SKIP 'A2b (shim) pulado — já atualizado'
}
elseif ($os -eq 'Windows') {
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
if ($upToDate) {
    Write-Step SKIP 'A2c (context7) pulado — já atualizado'
}
else {
    Write-Step INFO 'context7 (MCP, opcional)'
    . (Join-Path $PSScriptRoot 'install-mcp.ps1')
    Invoke-Context7Setup -Summary $summary -Check:$Check -DryRun:$DryRun
}

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

# --- A2g: semantic-kb MCP (OPT-IN via -WithSemanticKb, NÃO bloqueante) ------
# Registra o MCP "semantic-kb" (busca semântica local via Ollama + sqlite-vec) user-scoped +
# prepara o server versionado (onboarding/semantic-kb). Independente do -WithLocalAi (MCPs
# separados — ver .claude/sdd/features/DESIGN_RAG_HIBRIDO.md). Opt-in de propósito: exige
# Ollama/uv. Falha = WARN, nunca quebra A1/A2. O server degrada com mensagem amigável se o
# Ollama não estiver no ar. Reinicie o Claude Code após instalar p/ carregar o MCP.
if ($WithSemanticKb) {
    Write-Host ''
    Write-Step INFO "semantic-kb (MCP de busca semântica local via Ollama, opt-in) [modelo: $SemanticKbModel]"
    . (Join-Path $PSScriptRoot 'install-semantic-kb.ps1')
    $semanticKbServerDir = Join-Path $RepoRoot 'onboarding/semantic-kb'
    Invoke-SemanticKbSetup -Summary $summary -ServerDir $semanticKbServerDir -Model $SemanticKbModel -OllamaHost $SemanticKbOllamaHost -Check:$Check -DryRun:$DryRun
}

# --- A2i: claudex (OPT-IN via -WithClaudex, NÃO bloqueante) -----------------
# Provisiona o `claudex` (troca fina de modelo/provider Anthropic-compatível): seed do
# profiles.psd1 em ~/.claude/claudex, secrets/ com ACL restrita, função `claudex` no $PROFILE e
# marcador .native-sdd-claudex-version. Camada FINA — PowerShell puro, sem proxy/OAuth (fase
# futura gated). Opt-in de propósito. Falha = WARN, nunca quebra A1/A2. Roda SEMPRE que a flag é
# passada (fora do gate de versão — igual aos outros addons opt-in), p/ não regredir "só quero
# ligar o addon". Reabra o terminal após instalar p/ carregar a função `claudex`.
if ($WithClaudex) {
    Write-Host ''
    Write-Step INFO 'claudex (troca fina de modelo/provider, opt-in)'
    . (Join-Path $PSScriptRoot 'install-claudex.ps1')
    # Mesmo profile do shim sdd-workflow (A2b): CurrentUserAllHosts do pwsh, MyDocuments via API.
    $claudexProfile = if ($os -eq 'Windows') { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\profile.ps1' } else { '' }
    Invoke-ClaudexSetup -Summary $summary -RepoRoot $RepoRoot -UserHome $userHome -ProfilePath $claudexProfile -Version $currentVersion -OS $os -Check:$Check -DryRun:$DryRun
}

# --- A2j: herdr (OPT-IN via -WithHerdr, NÃO bloqueante) ---------------------
# Provisiona o binário `herdr` (multiplexador de agentes terminal-native, de terceiro — repo
# público ogulcancelik/herdr): baixa o asset da versão pinada (onboarding/herdr/herdr.psd1),
# VERIFICA o SHA-256 antes de instalar (mismatch = aborta, nunca instala) e o coloca em
# ~/.claude/tools/herdr/<versão>, com marcador .native-sdd-herdr-version. Clean-room: só fonte
# pública (herdr.dev + release do GitHub). Opt-in de propósito (baixa binário de terceiro). Falha =
# WARN, nunca quebra A1/A2. Roda SEMPRE que a flag é passada (fora do gate de versão — igual aos
# outros addons opt-in).
if ($WithHerdr) {
    Write-Host ''
    Write-Step INFO 'herdr (multiplexador de agentes terminal-native, opt-in)'
    . (Join-Path $PSScriptRoot 'install-herdr.ps1')
    Invoke-HerdrSetup -Summary $summary -RepoRoot $RepoRoot -UserHome $userHome -OS $os -Check:$Check -DryRun:$DryRun
}

# --- A2k: cliproxy (OPT-IN via -WithCliProxy, NÃO bloqueante) ---------------
# Provisiona o binário `cli-proxy-api` (CLIProxyAPI, de terceiro — repo público
# router-for-me/CLIProxyAPI): é o motor que o claudex usa p/ o caminho de LOGIN DE ASSINATURA
# (OAuth) em vez de chave de API. Baixa o asset da versão pinada (onboarding/cliproxy/
# cliproxy.psd1), VERIFICA o SHA-256 antes de instalar (mismatch = aborta, nunca instala),
# EXTRAI o archive e coloca em ~/.claude/tools/cliproxy/<versão>. Opt-in de propósito: baixa
# binário de terceiro E o uso de assinatura por proxy é decisão do usuário (ver a nota de ToS
# no /claudex-add-model). NÃO faz login: isso é ato do usuário, via `claudex -Login`.
# Falha = WARN, nunca quebra A1/A2.
if ($WithCliProxy) {
    Write-Host ''
    Write-Step INFO 'cliproxy (motor de login por assinatura, opt-in)'
    . (Join-Path $PSScriptRoot 'install-cliproxy.ps1')
    Invoke-CliProxySetup -Summary $summary -RepoRoot $RepoRoot -UserHome $userHome -OS $os -Check:$Check -DryRun:$DryRun
}

# --- A2h: shell padrão do Windows Terminal (OPT-IN via -SetDefaultShell) ----
# Instalar o PowerShell 7 (A1) não faz ninguém USÁ-LO: o Windows Terminal segue abrindo o
# "Windows PowerShell" (5.1), e é lá que o usuário digita `nsp` — justamente o runtime não
# suportado (ver a guarda de relaunch do new-project.ps1 e o bug do manifest na v0.8.28).
# Opt-in de propósito: mexe numa ferramenta do usuário. Falha = WARN, e faz backup antes.
if ($SetDefaultShell) {
    Write-Host ''
    Write-Step INFO 'Shell padrão do Windows Terminal (opcional)'
    . (Join-Path $PSScriptRoot 'install-default-shell.ps1')
    Invoke-DefaultShellSetup -Summary $summary -Check:$Check -DryRun:$DryRun
}

# --- A2d: managed policy (opt-in interativo, exige admin) -----------------
# Política de governança inviolável (topo da hierarquia). NÃO é aplicada à força: pergunta
# ao usuário e exige elevação (UAC) para escrever no caminho de sistema. Em -Check/-DryRun
# só relata o estado, sem perguntar.
Write-Host ''
if ($upToDate) {
    Write-Step SKIP 'A2d (managed policy) pulado — já atualizado'
}
else {
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
}

# --- A0b: grava o marcador de versão (só numa instalação real) -----------
if (-not $Check -and -not $DryRun -and $currentVersion) {
    Write-NativeSddVersionMarker -Path $DestRoot -Version $currentVersion -Summary $summary
}

$watch.Stop()
Write-Summary -Summary $summary -Elapsed $watch.Elapsed

if (-not $Check -and -not $DryRun -and -not $SkipClis) {
    Write-Host ''
    Write-Step INFO 'Dica: reabra o terminal para carregar os novos comandos no PATH.'
}

# Exit code: 1 se houve falha, senão 0.
if ($summary.Failed -gt 0) { exit 1 } else { exit 0 }

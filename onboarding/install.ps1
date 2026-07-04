<#
.SYNOPSIS
  Instalador do ambiente no Windows (deps + ~/.claude pessoal). Em Linux/macOS use o
  entrypoint POSIX: onboarding/install.sh.

.DESCRIPTION
  Deixa a máquina pronta para trabalhos de dev/dados com Claude Code:
   - A1: instala dependências fixas via winget (inclui PowerShell 7) + Claude Code + VS Code
   - A2: monta ~/.claude por descoberta dinâmica (espelha templates/global-claude)
  Idempotente. Faz backup antes de sobrescrever. Compatível com Windows PowerShell 5.1+.

.PARAMETER SkipClis
  Pula A1 (CLIs); só configura ~/.claude.

.PARAMETER Check
  Não instala/escreve nada; só relata o que falta.

.PARAMETER DryRun
  Mostra cada ação que faria, sem executar.

.PARAMETER NonInteractive
  Nunca pergunta. A managed policy (opt-in) é pulada por padrão (use -ManagedPolicy para forçar).
  Evita travar automações no prompt (a sessão do Bash tool conta como interativa).

.PARAMETER ManagedPolicy
  Controla a etapa de managed policy: Ask (padrão, pergunta) | Yes (aplica, eleva via UAC) |
  No (pula). Com -NonInteractive, o default vira No.

.PARAMETER ExtraPlugins
  Opt-in: instala suplementos extra user-scoped ("global dormente") do repertório curado
  (tools/supplements.psd1), por disciplina: design, reporting, data, security, dev, meta, ai.
  Disponíveis em todo projeto, auto-ativam só no trabalho da categoria. Off por padrão p/ manter o
  scaffold context-free. Não bloqueante (WARN).

.PARAMETER Themes
  Filtra os suplementos por tema (design | reporting | data | security | docs | meta | ai). Vazio = todos.
  Usado junto de -ExtraPlugins (-ExtraPlugins sozinho = todos, retrocompat).

.PARAMETER WithLocalAi
  Opt-in: provisiona o MCP "local-ai" (modelo local via Ollama) user-scoped — prepara o server
  versionado (onboarding/local-ai), baixa o modelo e registra no Claude Code. Exige Ollama + uv.
  Não bloqueante (WARN). Reinicie o Claude Code após instalar p/ carregar o MCP.

.PARAMETER LocalAiModel
  Modelo do Ollama a usar no local-ai (default: gpt-oss:20b). Use um menor se a VRAM/RAM for
  limitada (ex.: qwen2.5-coder:7b). Só tem efeito com -WithLocalAi. O instalador avisa (best-effort,
  NVIDIA) quando a VRAM detectada é menor que a sugerida para o modelo.

.PARAMETER LocalAiOllamaHost
  Endpoint do Ollama a registrar no local-ai (default: http://localhost:11434). Use para apontar a
  um Ollama em outra máquina/porta. Só tem efeito com -WithLocalAi.

.PARAMETER Help
  Mostra esta ajuda.

.EXAMPLE
  .\install.ps1                       # instalação completa
  .\install.ps1 -Check               # só verifica
  .\install.ps1 -DryRun              # simula
  .\install.ps1 -SkipClis            # só ~/.claude
  .\install.ps1 -NonInteractive      # automação (não trava em prompt)
  .\install.ps1 -ManagedPolicy Yes   # aplica a managed policy (UAC)
  .\install.ps1 -ExtraPlugins        # + suplementos user-scoped (todos os temas)
  .\install.ps1 -ExtraPlugins -Themes design   # só os de design (ui-ux-pro-max, impeccable)
  .\install.ps1 -WithLocalAi                   # + MCP local-ai (Ollama, gpt-oss:20b)
  .\install.ps1 -WithLocalAi -LocalAiModel qwen2.5-coder:7b  # local-ai com modelo mais leve
  .\install.ps1 -WithLocalAi -LocalAiOllamaHost http://192.168.0.10:11434  # Ollama em outra máquina
  .\install.ps1 -Check -WithLocalAi            # "doctor": relata o que falta p/ o local-ai

.NOTES
  Máquina recém-formatada (execution policy Restricted)? Rode via bootstrap:
    powershell -ExecutionPolicy Bypass -NoProfile -File .\onboarding\install.ps1
#>
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
    [switch]$Help
)

Set-StrictMode -Version Latest

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    return
}

Write-Host ''
Write-Host '╔══════════════════════════════════════════╗'
Write-Host '║   Instalador de ambiente · SDD workflow   ║'
Write-Host '╚══════════════════════════════════════════╝'

# Detecção de OS compatível com 5.1 (onde $IsWindows não existe).
# PowerShell <= 5.x é exclusivo do Windows; o '-or' faz short-circuit e não
# avalia $IsWindows sob StrictMode no 5.1.
$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows

if ($onWindows) {
    & (Join-Path $PSScriptRoot 'windows\apply.ps1') -SkipClis:$SkipClis -Check:$Check -DryRun:$DryRun `
        -NonInteractive:$NonInteractive -ManagedPolicy $ManagedPolicy -ExtraPlugins:$ExtraPlugins -Themes $Themes `
        -WithLocalAi:$WithLocalAi -LocalAiModel $LocalAiModel -LocalAiOllamaHost $LocalAiOllamaHost
    exit $LASTEXITCODE
}
elseif ($IsMacOS) {
    Write-Host '[INFO   ] macOS: use o entrypoint POSIX — bash ./onboarding/install.sh (apply.sh ainda é stub).'
    exit 2
}
elseif ($IsLinux) {
    Write-Host '[INFO   ] Linux: use o entrypoint POSIX — bash ./onboarding/install.sh (ou onboarding/linux/apply.sh).'
    exit 2
}
else {
    Write-Host '[FAIL   ] SO não reconhecido.'
    exit 2
}

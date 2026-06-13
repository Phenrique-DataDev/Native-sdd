<#
.SYNOPSIS
  Instalador do ambiente (deps + ~/.claude pessoal). Windows-first.

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

.PARAMETER Help
  Mostra esta ajuda.

.EXAMPLE
  .\install.ps1                       # instalação completa
  .\install.ps1 -Check               # só verifica
  .\install.ps1 -DryRun              # simula
  .\install.ps1 -SkipClis            # só ~/.claude
  .\install.ps1 -NonInteractive      # automação (não trava em prompt)
  .\install.ps1 -ManagedPolicy Yes   # aplica a managed policy (UAC)

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
        -NonInteractive:$NonInteractive -ManagedPolicy $ManagedPolicy
    exit $LASTEXITCODE
}
elseif ($IsMacOS) {
    Write-Host '[INFO   ] macOS ainda não implementado. Ver onboarding/macos/apply.sh (stub).'
    exit 2
}
elseif ($IsLinux) {
    Write-Host '[INFO   ] Linux ainda não implementado. Ver onboarding/linux/apply.sh (stub).'
    exit 2
}
else {
    Write-Host '[FAIL   ] SO não reconhecido.'
    exit 2
}

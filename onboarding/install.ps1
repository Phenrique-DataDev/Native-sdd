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
  Opt-in: instala suplementos extra user-scoped do repertório curado (tools/supplements.psd1), por
  disciplina: design, reporting, data, security, docs, meta, ai, orchestration. Os PLUGINS nascem
  DESABILITADOS: ficam no disco sem custar contexto, e você liga o que for usar pelo /plugin (o que
  tiver MCP termina em /mcp). Skills do repertório não têm esse estado e entram ativas. Off por
  padrão p/ manter o scaffold context-free. Não bloqueante (WARN).

.PARAMETER Themes
  Filtra os suplementos por tema (design | reporting | data | security | docs | meta | ai | orchestration). Vazio = todos.
  Usado junto de -ExtraPlugins (-ExtraPlugins sozinho = todos, retrocompat).

.PARAMETER WithHerdr
  Opt-in: provisiona o binário `herdr` (multiplexador de agentes terminal-native, de terceiro —
  repo público herdrdev/herdr) user-scoped. Baixa o asset da versão PINADA (onboarding/herdr/
  herdr.psd1), VERIFICA o SHA-256 antes de instalar (mismatch = aborta, nunca instala) e o instala
  em ~/.claude/tools/herdr/<versão>. Idempotente, marcador ~/.claude/.native-sdd-herdr-version.
  No Windows também grava `[terminal] default_shell = "pwsh.exe"` no config do herdr (com backup,
  sem sobrescrever outro shell escolhido) — sem isso os panes abrem no Windows PowerShell 5.1, onde
  o `nsp` não existe. Não bloqueante (WARN). Windows x64 é o alvo primário. Docs: https://herdr.dev/docs/

.PARAMETER SetDefaultShell
  Opt-in: define o PowerShell 7 como perfil PADRÃO do Windows Terminal (settings.json, com backup)
  e como shell dos panes do herdr, se ele estiver instalado (%APPDATA%\herdr\config.toml, com backup).
  Instalar o pwsh não faz ninguém usá-lo — sem isto o terminal e o herdr seguem abrindo o Windows
  PowerShell 5.1, onde o `nsp` não existe (o shim mora só no profile do pwsh 7). Não bloqueante (WARN).
  Só afeta o Windows Terminal; NÃO mexe na associação de arquivos .ps1 (decisão de segurança —
  ver o cabeçalho de windows/install-default-shell.ps1).

.PARAMETER KeepRetired
  Não retira do ~/.claude os arquivos que o framework deixou de entregar. Por padrão o instalador
  RETIRA (com backup .bak-<stamp>) todo arquivo que consta no manifest ~/.claude/.native-sdd-manifest,
  sumiu do template e continua intacto no disco — senão uma decisão de produto ("este hook sai")
  nunca alcança quem já instalou. Nunca toca no que você editou (fica preservado e é reportado) nem
  no que nunca foi entregue por nós. Máquina sem manifest: nada é retirado, o manifest é criado.

.PARAMETER OverwriteCustom
  Sobrescreve TAMBÉM os arquivos do baseline que VOCÊ customizou (classes 'conflito'/'desconhecido'),
  sempre com backup .bak-*. Sem esta flag eles são PRESERVADOS e apenas listados — quem não editou
  continua recebendo as melhorias normalmente. Mesma semântica do -Force do new-project.ps1.

  Deliberadamente SEPARADA do -Force: aqui -Force só refaz a instalação na mesma versão (uso
  inócuo, que a própria saída do script recomenda). Juntar as duas faria quem só quer reinstalar
  perder customização sem esperar.

.PARAMETER Force
  Força a reinstalação mesmo quando a versão instalada (~/.claude/.native-sdd-version) já bate
  com o VERSION do checkout atual. Sem esta flag, uma 2ª execução na mesma versão só relata
  "já atualizado" e pula A1/A2/shim/context7/managed policy (idempotência versionada).

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
  .\install.ps1 -WithHerdr                     # + binário herdr (multiplexador de agentes, verifica SHA-256)
  .\install.ps1 -Check -WithHerdr              # relata: ausente / pinado / divergente
  .\install.ps1 -SetDefaultShell               # + pwsh como padrão do Windows Terminal e do herdr
  .\install.ps1 -Force                         # reinstala mesmo já estando atualizado

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
    [switch]$WithHerdr,
    [switch]$SetDefaultShell,
    [switch]$KeepRetired,
    [switch]$OverwriteCustom,
    [switch]$Force,
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
    # Zerado ANTES da chamada: se o apply.ps1 morrer no parser (é o que acontece no 5.1 quando o
    # arquivo perde o BOM — incidente de 2026-07-20), ele nunca executa o próprio `exit`, e o
    # $LASTEXITCODE que sobrou de um comando nativo anterior faria o instalador sair 0 com o
    # instalador quebrado. Medido em 2026-07-30: sem isto, `-Check` sob 5.1 sai 0 com ParserError.
    $global:LASTEXITCODE = $null
    & (Join-Path $PSScriptRoot 'windows\apply.ps1') -SkipClis:$SkipClis -Check:$Check -DryRun:$DryRun `
        -NonInteractive:$NonInteractive -ManagedPolicy $ManagedPolicy -ExtraPlugins:$ExtraPlugins -Themes $Themes `
        -WithHerdr:$WithHerdr `
        -SetDefaultShell:$SetDefaultShell -KeepRetired:$KeepRetired -Force:$Force -OverwriteCustom:$OverwriteCustom
    # $null aqui = o apply.ps1 não chegou a rodar o próprio `exit` (parse error, arquivo ausente).
    # Falha silenciosa é pior que falha ruidosa: sai 1 para o CI e para quem chama por script.
    if ($null -eq $global:LASTEXITCODE) {
        Write-Host '[FAIL   ] onboarding/windows/apply.ps1 não chegou a executar (erro de parse ou arquivo ausente).'
        exit 1
    }
    exit $global:LASTEXITCODE
}
elseif ($IsMacOS) {
    Write-Host '[INFO   ] macOS: use o entrypoint POSIX — bash ./onboarding/install.sh (ou onboarding/macos/apply.sh).'
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

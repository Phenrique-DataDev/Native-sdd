<#
.SYNOPSIS
    Hook PreToolUse (matcher "Bash") — guard ASK do destrutivo NÃO-git (J5).

.DESCRIPTION
    Hook de segurança (irmão do secret-guard). Em cada tool Bash:
      - destrutivo não-git arriscado (rm -rf de alvo absoluto/home/var/glob, chmod -R 777,
        curl|sh)  -> permissionDecision "ask"
      - qualquer outro caso                                                  -> PASSTHROUGH (exit 0)

    Fecha o buraco que o modo `auto` abre: o Bash geral é auto-aprovado e a managed policy (C3)
    só nega o catastrófico por PREFIXO; este hook tokeniza/normaliza e pede confirmação nas
    VARIANTES que escapam ao prefixo.

    NUNCA usa "deny" (postura por design — igual push/secret-guard): só pede confirmação. O bloqueio
    inviolável fica na managed policy. Como NÃO consulta git nem rede, não há fail-safe assimétrico:
    o lado seguro é sempre **silêncio** (na dúvida, não atrapalha — a managed policy ainda cobre o
    catastrófico).

    Detecção vem da lib ÚNICA lib/destructive-patterns.ps1 (dot-sourced); sem ela degrada p/
    passthrough. Espelhado por destructive-guard.sh (paridade por Pester). Schema do hook
    verificado via context7 (/anthropics/claude-code): igual aos demais guards.

    Funções puras são dot-sourceáveis; o fluxo só roda quando NÃO é dot-sourced (guard no fim).
#>

Set-StrictMode -Version Latest

# Lib única de detecção (mesma pasta, sob lib/). Sem ela, o hook degrada para passthrough.
$script:DestructiveLib = Join-Path $PSScriptRoot 'lib/destructive-patterns.ps1'
if (Test-Path -LiteralPath $script:DestructiveLib) { . $script:DestructiveLib }

# --- Acesso seguro a propriedade sob StrictMode (PSCustomObject do ConvertFrom-Json) ----------
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# --- PURA: extrai os 5 campos canonicos do payload ja parseado (contrato H5/HARNESS-CONTRACT.md).
#     Ponto unico de acesso aos campos -- usado pelo fluxo do hook e por qualquer adapter de
#     harness que ja produza o payload no formato canonico (nao precisa reimplementar o acesso).
function Read-NormalizedEvent {
    param([Parameter(Mandatory)][AllowNull()]$Payload)
    $toolInput = Get-PropOrNull $Payload 'tool_input'
    return [pscustomobject]@{
        HookEventName = [string](Get-PropOrNull $Payload 'hook_event_name')
        ToolName      = [string](Get-PropOrNull $Payload 'tool_name')
        Command       = [string](Get-PropOrNull $toolInput 'command')
        FilePath      = [string](Get-PropOrNull $toolInput 'file_path')
        Cwd           = [string](Get-PropOrNull $Payload 'cwd')
    }
}

# --- PURA: monta o JSON da decisao (schema PreToolUse) ----------------------------------------
function New-HookDecisionJson {
    param(
        [Parameter(Mandatory)][ValidateSet('allow', 'ask', 'deny')][string]$Decision,
        [string]$Reason
    )
    $obj = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName            = 'PreToolUse'
            permissionDecision       = $Decision
            permissionDecisionReason = $Reason
        }
        systemMessage = $Reason
    }
    return ($obj | ConvertTo-Json -Depth 6 -Compress)
}

# --- I/O (só env): o contexto que a lib pura recebe por parâmetro (GUARD_RM_ESCOPO, D2) ---------
# O env do hook é o do shell do agente em outra forma (medido 2026-09-28): `C:\...\Temp` aqui,
# `/c/.../Temp` e `/tmp` no Git Bash. No Windows, o `/tmp` do Git Bash É o %TEMP% (montagem
# `usertemp` do Git for Windows), então entra como segunda forma do temp.
function Get-DestructiveGuardContext {
    param([string]$Cwd)
    $temp = @([IO.Path]::GetTempPath())
    # 8.3 (2026-10-01): o .NET expande o TEMP em nome curto (`RUNNER~1`) para a forma LONGA, e o lado .sh
    # conhece a forma crua. Sem a crua aqui, o `rm` no temp escrito na forma curta virava `ask` so neste
    # runtime. O GetTempPath segue em 1o: o `mktemp` e resolvido pelo primeiro temp.
    foreach ($n in 'TEMP', 'TMP') {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v -and $temp -notcontains $v) { $temp += $v }
    }
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { $temp += '/tmp' }
    $tempVars = @{}
    foreach ($n in 'TEMP', 'TMP', 'TMPDIR') {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { $tempVars[$n] = $v }
    }
    return @{ Cwd = $Cwd; TempDir = $temp; HomeDir = $HOME; TempVars = $tempVars }
}

# --- Fluxo principal --------------------------------------------------------------------------
function Invoke-DestructiveGuard {
    # -Payload: quando o dispatcher consolidado ja leu/parseou o stdin. Ausente = le stdin
    #           (comportamento historico, preservado para quem invoca o arquivo direto).
    param([AllowNull()]$Payload)

    # 0) Forca stdout em UTF-8 sem BOM: o texto emitido tem acentuacao (pt-BR) e o console do
    #    pwsh no Windows NAO escreve UTF-8 em stdout redirecionado -- sem isto o JSON sai na
    #    codepage OEM e chega corrompido ao modelo (medido byte a byte). Molde repetido em
    #    todos os hooks que emitem texto -- auto-suficiente de proposito, sem apontar para um
    #    arquivo vizinho: ate 2026-09-01 este comentario citava o agent-graph-context.ps1, que
    #    foi REMOVIDO do scaffold, e o ponteiro teria sobrevivido ao alvo. Falha aqui NAO aborta
    #    o hook: encoding ruim e' melhor que
    #    hook desativado (num guard, o `return` viraria passthrough silencioso).
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

    # 1) Payload: ja parseado (bash-guards.ps1 consolidado, le stdin UMA vez) ou stdin
    #    (invocacao direta -- adapters de harness, /guards-check e os testes chamam assim).
    #    Falha de leitura/parse -> passthrough.
    if ($null -eq $Payload) {
        try { $raw = [Console]::In.ReadToEnd() } catch { return }
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        try { $Payload = $raw | ConvertFrom-Json } catch { return }
    }

    # 2) Pré-condições (qualquer não-match -> passthrough)
    $evt = Read-NormalizedEvent $payload
    # PowerShell: a tool nativa do Claude Code no Windows, mesmo `tool_input.command` (GUARDS_CEGOS_A_TOOL_POWERSHELL).
    if ($evt.ToolName -notin @('Bash', 'PowerShell')) { return }
    if ([string]::IsNullOrWhiteSpace($evt.Command)) { return }

    # Sem a lib de deteccao nao ha como decidir -> passthrough (degradacao graciosa).
    if (-not (Get-Command Get-DestructiveDecision -ErrorAction SilentlyContinue)) { return }

    # 3) Decidir (erro aqui -> silencio: nao ha git/rede, o lado seguro e' nao atrapalhar)
    try {
        $ctx = Get-DestructiveGuardContext -Cwd $evt.Cwd
        $decision = Get-DestructiveDecision -Command $evt.Command @ctx
        if ($decision.Decision -eq 'ask') {
            Write-Output (New-HookDecisionJson -Decision 'ask' -Reason $decision.Reason)
        }
    }
    catch { return }
}

# --- Guard: roda o fluxo so quando NAO dot-sourced (Pester faz `. destructive-guard.ps1`) ------
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DestructiveGuard
}

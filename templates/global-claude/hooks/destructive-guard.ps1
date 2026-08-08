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

# --- Fluxo principal --------------------------------------------------------------------------
function Invoke-DestructiveGuard {
    # 1) Ler payload (falha de leitura/parse -> passthrough)
    try { $raw = [Console]::In.ReadToEnd() } catch { return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    try { $payload = $raw | ConvertFrom-Json } catch { return }

    # 2) Pré-condições (qualquer não-match -> passthrough)
    $evt = Read-NormalizedEvent $payload
    if ($evt.ToolName -ne 'Bash') { return }
    if ([string]::IsNullOrWhiteSpace($evt.Command)) { return }

    # Sem a lib de deteccao nao ha como decidir -> passthrough (degradacao graciosa).
    if (-not (Get-Command Get-DestructiveDecision -ErrorAction SilentlyContinue)) { return }

    # 3) Decidir (erro aqui -> silencio: nao ha git/rede, o lado seguro e' nao atrapalhar)
    try {
        $decision = Get-DestructiveDecision $evt.Command
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

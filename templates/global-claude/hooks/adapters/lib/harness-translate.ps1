<#
.SYNOPSIS
    Lib pura de traducao harness-nativo <-> contrato canonico (H5, docs/HARNESS-CONTRACT.md).
    Dot-sourceada pelos adapters de Cursor/Codex. NAO le stdin nem spawna processo -- isso e'
    responsabilidade do adapter que a consome (mesma separacao I/O x pura dos hooks originais).

.DESCRIPTION
    Todo mapeamento aqui e' rastreavel a uma celula do docs/HARNESS-CONTRACT.md. Onde a doc
    oficial do harness deixa uma lacuna (ex.: Codex nao documenta "ask" em PreToolUse), a funcao
    degrada para o lado MAIS RESTRITIVO (nunca "allow" silencioso) -- ver comentarios inline.
#>

Set-StrictMode -Version Latest

# --- Acesso seguro a propriedade sob StrictMode (compartilhado com os hooks) -------------------
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# --- Roteamento canonico -> qual script-alvo decide (compartilhado entre harnesses) ------------
function Get-GuardTarget {
    <#
    .OUTPUTS
        'destructive-guard' | 'curation-nudge' | $null (evento sem script-alvo mapeado)
    #>
    param([Parameter(Mandatory)][AllowNull()]$Canonical)
    if ($null -eq $Canonical) { return $null }
    switch ([string]$Canonical.hook_event_name) {
        'PreToolUse'   { if ([string]$Canonical.tool_name -eq 'Bash') { return 'destructive-guard' }; return $null }
        'PostToolUse'  { if ([string]$Canonical.tool_name -in @('Edit', 'Write')) { return 'curation-nudge' }; return $null }
        'SessionStart' { return 'curation-nudge' }
        default        { return $null }
    }
}

# ================================================================================================
# CURSOR (cursor.com/docs/hooks, fetch 2026-07-06)
# ================================================================================================

function ConvertTo-CanonicalFromCursor {
    <#
    .SYNOPSIS
        Mapeia um payload Cursor (qualquer evento) para o objeto canonico que
        destructive-guard/curation-nudge ja sabem ler. $null = evento nao mapeado (adapter nao atua).
    #>
    param([Parameter(Mandatory)][AllowNull()]$CursorPayload)
    if ($null -eq $CursorPayload) { return $null }
    $evt = [string](Get-PropOrNull $CursorPayload 'hook_event_name')

    switch ($evt) {
        'beforeShellExecution' {
            return [pscustomobject]@{
                hook_event_name = 'PreToolUse'
                tool_name       = 'Bash'
                tool_input      = [pscustomobject]@{ command = [string](Get-PropOrNull $CursorPayload 'command') }
                cwd             = [string](Get-PropOrNull $CursorPayload 'cwd')
            }
        }
        'preToolUse' {
            $ti = Get-PropOrNull $CursorPayload 'tool_input'
            return [pscustomobject]@{
                hook_event_name = 'PreToolUse'
                tool_name       = [string](Get-PropOrNull $CursorPayload 'tool_name')
                tool_input      = [pscustomobject]@{
                    command   = [string](Get-PropOrNull $ti 'command')
                    file_path = [string](Get-PropOrNull $ti 'file_path')
                }
                cwd             = [string](Get-PropOrNull $CursorPayload 'cwd')
            }
        }
        'afterFileEdit' {
            # Cursor nao tem `cwd` neste evento -- so `workspace_roots` (array). Melhor esforco:
            # 1o elemento. Documentado aqui para nao esconder a aproximacao (nao inventar em silencio).
            $roots = @(Get-PropOrNull $CursorPayload 'workspace_roots')
            return [pscustomobject]@{
                hook_event_name = 'PostToolUse'
                tool_name       = 'Edit'
                tool_input      = [pscustomobject]@{ file_path = [string](Get-PropOrNull $CursorPayload 'file_path') }
                cwd             = if ($roots.Count -gt 0) { [string]$roots[0] } else { '' }
            }
        }
        'sessionStart' {
            $roots = @(Get-PropOrNull $CursorPayload 'workspace_roots')
            return [pscustomobject]@{
                hook_event_name = 'SessionStart'
                tool_name       = ''
                tool_input      = [pscustomobject]@{}
                cwd             = if ($roots.Count -gt 0) { [string]$roots[0] } else { '' }
            }
        }
        default { return $null }
    }
}

function ConvertTo-CursorOutput {
    <#
    .SYNOPSIS
        Traduz o stdout canonico do script-alvo (JSON ou vazio) para o shape nativo do Cursor.
        $null = nada a imprimir (adapter fica em silencio -- o proprio Cursor trata isso como OK).
    .DESCRIPTION
        Fail-safe: erro de parse do stdout do script-alvo -> "ask" explicito, NUNCA depende do
        exit-code (o Cursor e' fail-open em exit-code fora de {0,2} -- doc oficial).
    #>
    param(
        [AllowNull()][string]$CanonicalStdout,
        [Parameter(Mandatory)][string]$CursorEventName
    )

    if ([string]::IsNullOrWhiteSpace($CanonicalStdout)) {
        # Silencio do script-alvo. Só beforeShellExecution exige uma decisao explicita (allow) --
        # os demais eventos nao tem "permission" no contrato de saida do Cursor.
        if ($CursorEventName -eq 'beforeShellExecution') {
            return (@{ permission = 'allow' } | ConvertTo-Json -Compress)
        }
        return $null
    }

    try { $decision = $CanonicalStdout | ConvertFrom-Json }
    catch {
        return (@{ permission = 'ask'; user_message = 'adapter: saida do guard ilegivel — revise manualmente' } | ConvertTo-Json -Compress)
    }

    $perm = [string](Get-PropOrNull (Get-PropOrNull $decision 'hookSpecificOutput') 'permissionDecision')
    $reason = [string](Get-PropOrNull (Get-PropOrNull $decision 'hookSpecificOutput') 'permissionDecisionReason')
    if ($perm) {
        if ($CursorEventName -eq 'preToolUse' -and $perm -eq 'ask') {
            # preToolUse do Cursor so aceita allow|deny (doc oficial) -- "ask" nao suportado aqui.
            # Degrada para o lado MAIS restritivo (deny), nunca para allow.
            $perm = 'deny'
        }
        return (@{ permission = $perm; user_message = $reason; agent_message = $reason } | ConvertTo-Json -Compress)
    }

    $ctx = [string](Get-PropOrNull (Get-PropOrNull $decision 'hookSpecificOutput') 'additionalContext')
    if ($ctx) {
        return (@{ additional_context = $ctx } | ConvertTo-Json -Compress)
    }
    return $null
}

# ================================================================================================
# CODEX (developers.openai.com/codex/hooks, fetch 2026-07-06)
# ================================================================================================

function ConvertTo-CanonicalFromCodex {
    <#
    .SYNOPSIS
        Mapeia um payload Codex para o canonico. Codex converge quase campo-a-campo com o Claude
        Code (hook_event_name/cwd identicos) -- esta funcao e' quase identidade, mantida explicita
        (nao passthrough cru) para isolar qualquer divergencia futura de schema.
    #>
    param([Parameter(Mandatory)][AllowNull()]$CodexPayload)
    if ($null -eq $CodexPayload) { return $null }
    $evt = [string](Get-PropOrNull $CodexPayload 'hook_event_name')
    if ($evt -notin @('PreToolUse', 'PostToolUse', 'SessionStart')) { return $null }

    $ti = Get-PropOrNull $CodexPayload 'tool_input'
    return [pscustomobject]@{
        hook_event_name = $evt
        tool_name       = [string](Get-PropOrNull $CodexPayload 'tool_name')
        tool_input      = [pscustomobject]@{
            command   = [string](Get-PropOrNull $ti 'command')
            file_path = [string](Get-PropOrNull $ti 'file_path')
        }
        cwd             = [string](Get-PropOrNull $CodexPayload 'cwd')
    }
}

function ConvertTo-CodexOutput {
    <#
    .SYNOPSIS
        Traduz o stdout canonico do script-alvo para o shape nativo do Codex --
        hookSpecificOutput.permissionDecision/additionalContext (nomes IDENTICOS ao canonico).
    #>
    param(
        [AllowNull()][string]$CanonicalStdout,
        [Parameter(Mandatory)][string]$CodexEventName
    )

    if ([string]::IsNullOrWhiteSpace($CanonicalStdout)) { return $null }  # silencio = allow implicito

    try { $decision = $CanonicalStdout | ConvertFrom-Json }
    catch {
        return (@{ hookSpecificOutput = @{ hookEventName = $CodexEventName; permissionDecision = 'deny'; permissionDecisionReason = 'adapter: saida do guard ilegivel' } } | ConvertTo-Json -Compress -Depth 5)
    }

    $perm = [string](Get-PropOrNull (Get-PropOrNull $decision 'hookSpecificOutput') 'permissionDecision')
    $reason = [string](Get-PropOrNull (Get-PropOrNull $decision 'hookSpecificOutput') 'permissionDecisionReason')
    if ($perm) {
        if ($CodexEventName -eq 'PreToolUse' -and $perm -eq 'ask') {
            # Doc oficial do Codex nao documenta "ask" para PreToolUse (so allow|deny) -- degrada
            # para o lado mais restritivo (deny), nunca allow.
            $perm = 'deny'
        }
        return (@{ hookSpecificOutput = @{ hookEventName = $CodexEventName; permissionDecision = $perm; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 5)
    }

    $ctx = [string](Get-PropOrNull (Get-PropOrNull $decision 'hookSpecificOutput') 'additionalContext')
    if ($ctx) {
        return (@{ hookSpecificOutput = @{ hookEventName = $CodexEventName; additionalContext = $ctx } } | ConvertTo-Json -Compress -Depth 5)
    }
    return $null
}

# --- Resolucao do script-alvo (cascata tooling.md adaptada p/ os adapters) ---------------------
function Resolve-GuardScript {
    <#
    .SYNOPSIS
        Acha o script-alvo (.ps1) por 2 vias: (1) relativo ao adapter -- uso dentro deste repo ou
        copia manual completa; (2) $env:SDD_WORKFLOW_HOME -- instalacao padrao do onboarding.
        Sem nenhuma via -> $null (o adapter decide o fail-safe, nao esta funcao).
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptName,   # 'destructive-guard.ps1' | 'curation-nudge.ps1'
        [Parameter(Mandatory)][string]$AdapterDir    # $PSScriptRoot do adapter chamador
    )

    $globalRel = Join-Path $AdapterDir "../../$ScriptName"
    if (Test-Path -LiteralPath $globalRel -PathType Leaf) { return (Resolve-Path $globalRel).Path }

    if ($ScriptName -eq 'curation-nudge.ps1') {
        $projRel = Join-Path $AdapterDir "../../../../project-scaffold/.claude/hooks/$ScriptName"
        if (Test-Path -LiteralPath $projRel -PathType Leaf) { return (Resolve-Path $projRel).Path }
    }

    if ($env:SDD_WORKFLOW_HOME) {
        $viaGlobal = Join-Path $env:SDD_WORKFLOW_HOME "templates/global-claude/hooks/$ScriptName"
        if (Test-Path -LiteralPath $viaGlobal -PathType Leaf) { return (Resolve-Path $viaGlobal).Path }
        if ($ScriptName -eq 'curation-nudge.ps1') {
            $viaProj = Join-Path $env:SDD_WORKFLOW_HOME "templates/project-scaffold/.claude/hooks/$ScriptName"
            if (Test-Path -LiteralPath $viaProj -PathType Leaf) { return (Resolve-Path $viaProj).Path }
        }
    }

    return $null
}

<#
.SYNOPSIS
    Adapter Cursor (H5) -- traduz o dialeto de hook do Cursor para o contrato canonico e invoca,
    SEM MODIFICAR, o script real (destructive-guard.ps1 / curation-nudge.ps1).

.DESCRIPTION
    Registrado no .cursor/hooks.json do PROJETO-ALVO (ver hooks.json.example nesta pasta) para os
    eventos beforeShellExecution / preToolUse / afterFileEdit / sessionStart. O proprio payload do
    Cursor identifica o evento (`hook_event_name`) -- este script se auto-roteia, sem precisar de
    registro separado por evento.

    Fail-safe (critico): o Cursor e' FAIL-OPEN em exit-code fora de {0,2} (doc oficial) -- por isso
    este adapter NUNCA depende do exit code para o lado seguro. Todo erro produz um JSON explicito
    com `permission: "ask"`, sempre com exit 0.

    Verificacao: nao ha Cursor instalado neste ambiente -- testado com fixtures sinteticas fieis ao
    schema documentado (tools/tests/harness-adapters.Tests.ps1), nao e2e ao vivo. Ver DESIGN_ADAPTER.md.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '../lib/harness-translate.ps1')

function New-CursorFailSafeOutput {
    param([Parameter(Mandatory)][string]$Reason)
    return (@{ permission = 'ask'; user_message = "adapter: $Reason" } | ConvertTo-Json -Compress)
}

function Invoke-CursorAdapter {
    try { $raw = [Console]::In.ReadToEnd() } catch { Write-Output (New-CursorFailSafeOutput 'stdin ilegivel'); return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }   # sem payload: nada a traduzir

    try { $cursorPayload = $raw | ConvertFrom-Json }
    catch { Write-Output (New-CursorFailSafeOutput 'JSON do Cursor invalido'); return }

    $canonical = ConvertTo-CanonicalFromCursor $cursorPayload
    if ($null -eq $canonical) { return }   # evento nao mapeado (ex.: stop/afterAgentThought) -> passthrough

    $targetName = Get-GuardTarget $canonical
    if (-not $targetName) { return }

    $scriptPath = Resolve-GuardScript -ScriptName "$targetName.ps1" -AdapterDir $PSScriptRoot
    if (-not $scriptPath) {
        Write-Output (New-CursorFailSafeOutput "script $targetName.ps1 nao encontrado (configure `$env:SDD_WORKFLOW_HOME)")
        return
    }

    $canonicalJson = ($canonical | ConvertTo-Json -Compress -Depth 6)
    $eventName = [string](Get-PropOrNull $cursorPayload 'hook_event_name')

    try {
        $stdout = $canonicalJson | & pwsh -NoProfile -Command "& '$scriptPath'" 2>$null
    }
    catch {
        Write-Output (New-CursorFailSafeOutput "falha ao rodar ${targetName}: $($_.Exception.Message)")
        return
    }

    $out = ConvertTo-CursorOutput -CanonicalStdout ($stdout -join "`n") -CursorEventName $eventName
    if ($out) { Write-Output $out }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-CursorAdapter }

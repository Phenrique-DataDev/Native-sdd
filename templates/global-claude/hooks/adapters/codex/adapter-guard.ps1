<#
.SYNOPSIS
    Adapter Codex (H5) -- traduz o dialeto de hook do Codex CLI para o contrato canonico e invoca,
    SEM MODIFICAR, o script real (destructive-guard.ps1 / curation-nudge.ps1).

.DESCRIPTION
    Registrado no ~/.codex/hooks.json ou config.toml (ver hooks.json.example/config.toml.example
    nesta pasta). O schema de hook do Codex converge quase campo-a-campo com o Claude Code
    (hook_event_name/cwd identicos; hookSpecificOutput.permissionDecision/additionalContext
    identicos) -- este adapter e' quase uma tradução de identidade, mantida explicita para isolar
    qualquer divergencia futura de schema (nao um passthrough cru).

    Verificacao: nao ha Codex instalado neste ambiente -- testado com fixtures sinteticas fieis ao
    schema documentado (tools/tests/harness-adapters.Tests.ps1), nao e2e ao vivo. Ver DESIGN_ADAPTER.md.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '../lib/harness-translate.ps1')

function New-CodexFailSafeOutput {
    param([Parameter(Mandatory)][string]$EventName, [Parameter(Mandatory)][string]$Reason)
    return (@{ hookSpecificOutput = @{ hookEventName = $EventName; permissionDecision = 'deny'; permissionDecisionReason = "adapter: $Reason" } } | ConvertTo-Json -Compress -Depth 5)
}

function Invoke-CodexAdapter {
    try { $raw = [Console]::In.ReadToEnd() } catch { Write-Output (New-CodexFailSafeOutput 'PreToolUse' 'stdin ilegivel'); return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }

    try { $codexPayload = $raw | ConvertFrom-Json }
    catch { Write-Output (New-CodexFailSafeOutput 'PreToolUse' 'JSON do Codex invalido'); return }

    $eventName = [string](Get-PropOrNull $codexPayload 'hook_event_name')
    $canonical = ConvertTo-CanonicalFromCodex $codexPayload
    if ($null -eq $canonical) { return }   # evento nao mapeado -> passthrough

    $targetName = Get-GuardTarget $canonical
    if (-not $targetName) { return }

    $scriptPath = Resolve-GuardScript -ScriptName "$targetName.ps1" -AdapterDir $PSScriptRoot
    if (-not $scriptPath) {
        Write-Output (New-CodexFailSafeOutput $eventName "script $targetName.ps1 nao encontrado (configure `$env:SDD_WORKFLOW_HOME)")
        return
    }

    $canonicalJson = ($canonical | ConvertTo-Json -Compress -Depth 6)
    try {
        $stdout = $canonicalJson | & pwsh -NoProfile -Command "& '$scriptPath'" 2>$null
    }
    catch {
        Write-Output (New-CodexFailSafeOutput $eventName "falha ao rodar ${targetName}: $($_.Exception.Message)")
        return
    }

    $out = ConvertTo-CodexOutput -CanonicalStdout ($stdout -join "`n") -CodexEventName $eventName
    if ($out) { Write-Output $out }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-CodexAdapter }

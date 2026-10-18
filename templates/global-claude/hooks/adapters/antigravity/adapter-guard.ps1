<#
.SYNOPSIS
    Adapter Antigravity -- traduz o hook PreToolUse do Antigravity CLI para o contrato canonico e
    invoca, SEM MODIFICAR, o destructive-guard.ps1.

.DESCRIPTION
    Registrado no ~/.gemini/config/hooks.json (o install.ps1 grava a chave `native-sdd-guard`
    quando acha o `agy` no PATH; a linha sai de Get-AntigravityGuardHookEntry, em
    onboarding/windows/install-harness-guards.ps1) com o matcher `run_command`.
    O Antigravity le `toolCall` no stdin e espera `{"decision": ..., "reason": ...}` no stdout
    (antigravity.google/docs/hooks; payload medido no agy 1.4.2, 2026-10-18).

    "ask" do guard sai como "force_ask" (ver ConvertTo-AntigravityOutput). Todo erro tambem sai
    como "force_ask" explicito, nunca silencio: a doc nao diz o que o Antigravity faz com exit code
    de hook, entao o lado seguro nao pode depender dele.

    Verificacao: fixtures do payload real (tools/tests/harness-adapters.Tests.ps1) e e2e ao vivo
    no agy 1.4.2, com o limite medido de que "force_ask" nao pergunta sob dangerouslySkipPermissions.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '../lib/harness-translate.ps1')

function New-AntigravityFailSafeOutput {
    param([Parameter(Mandatory)][string]$Reason)
    return (@{ decision = 'force_ask'; reason = "adapter: $Reason" } | ConvertTo-Json -Compress)
}

function Invoke-AntigravityAdapter {
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { $null = $_ }   # encoding ruim e' melhor que adapter mudo
    try { $raw = [Console]::In.ReadToEnd() } catch { Write-Output (New-AntigravityFailSafeOutput 'stdin ilegivel'); return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }

    try { $payload = $raw | ConvertFrom-Json }
    catch { Write-Output (New-AntigravityFailSafeOutput 'JSON do Antigravity invalido'); return }

    $canonical = ConvertTo-CanonicalFromAntigravity $payload
    if ($null -eq $canonical) { return }   # nao e' run_command -> passthrough

    $targetName = Get-GuardTarget $canonical
    if (-not $targetName) { return }

    $scriptPath = Resolve-GuardScript -ScriptName "$targetName.ps1" -AdapterDir $PSScriptRoot
    if (-not $scriptPath) {
        Write-Output (New-AntigravityFailSafeOutput "script $targetName.ps1 nao encontrado (configure `$env:SDD_WORKFLOW_HOME)")
        return
    }

    $canonicalJson = ($canonical | ConvertTo-Json -Compress -Depth 6)
    try {
        $stdout = $canonicalJson | & pwsh -NoProfile -Command "& '$scriptPath'" 2>$null
    }
    catch {
        Write-Output (New-AntigravityFailSafeOutput "falha ao rodar ${targetName}: $($_.Exception.Message)")
        return
    }

    $out = ConvertTo-AntigravityOutput -CanonicalStdout ($stdout -join "`n")
    if ($out) { Write-Output $out }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-AntigravityAdapter }

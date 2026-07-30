<#
.SYNOPSIS
    Hook peer-heartbeat (EPIC H, H10) — publica a presença da sessão no quadro de peers. READ-ONLY
    quanto à curadoria; o único lugar escrito é .claude/.cache/peers/ (gitignored).

.DESCRIPTION
    Registrado no .claude/settings.json (hooks.SessionStart matcher "*" e hooks.PostToolUse matcher
    "Write|Edit"), ao lado do curation-nudge. Em cada disparo:
      - SessionStart -> grava/atualiza a presença (id=session_id, branch, summary derivado) e emite
                        additionalContext: o PRÓPRIO id do peer + peers ativos + recados (habilita /peers).
      - PostToolUse  -> refresca só o heartbeat, respeitando o cooldown (silêncio).
      - stdin inválido / fora de projeto / tools ausente / qualquer erro -> SILÊNCIO (exit 0).

    Toda a lógica determinística vive em tools/peers.ps1 (resolvido pela cascata $toolsRoot da
    rules/tooling.md) e é coberta por Pester. NUNCA chama rede (corta o auto-summary OpenAI do
    claude-peers original). Schema do input verificado via context7 (/anthropics/claude-code,
    2026-06-21): todo hook recebe { session_id, cwd, hook_event_name, ... } no stdin.

    O par peer-heartbeat.sh é degradação CONSCIENTE (sem pwsh, o peering não ativa) — molde J4
    (curation-nudge.sh): peering é conveniência, não guarda de segurança.

    Funções puras (Get-PropOrNull / Resolve-ToolsRoot / New-PeerHeartbeatJson) são dot-sourceáveis;
    o fluxo só roda quando o script NÃO é dot-sourced (guard no fim).
#>

Set-StrictMode -Version Latest

# --- Acesso seguro a propriedade sob StrictMode -----------------------------------------------
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# --- PURA: cascata de resolução da camada tools/ (ver rules/tooling.md) ------------------------
function Resolve-ToolsRoot {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$StartDir,
        [AllowNull()][string]$WorkflowHome = $env:SDD_WORKFLOW_HOME
    )
    $none = [pscustomobject]@{ Path = $null; Source = 'none'; Degraded = $true }
    if ([string]::IsNullOrWhiteSpace($StartDir)) { return $none }
    $rel = Join-Path $StartDir 'tools'
    if (Test-Path -LiteralPath $rel -PathType Container) {
        return [pscustomobject]@{ Path = $rel; Source = 'relative'; Degraded = $false }
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkflowHome)) {
        $envTools = Join-Path $WorkflowHome 'tools'
        if (Test-Path -LiteralPath $envTools -PathType Container) {
            return [pscustomobject]@{ Path = $envTools; Source = 'env'; Degraded = $false }
        }
    }
    return $none
}

# --- PURA: JSON de saída informativo (additionalContext) --------------------------------------
function New-PeerHeartbeatJson {
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][string]$EventName
    )
    $obj = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName     = $EventName
            additionalContext = $Context
        }
    }
    return ($obj | ConvertTo-Json -Depth 6 -Compress)
}

# --- PURA: monta o texto do anúncio de SessionStart -------------------------------------------
function Format-PeerAnnounce {
    param(
        [Parameter(Mandatory)][string]$SelfId,
        [AllowEmptyCollection()][object[]]$ActivePeers = @(),
        [int]$UnreadCount = 0
    )
    $lines = @("peers: sua sessão é '$SelfId' (use este id no /peers).")
    $act = @($ActivePeers | Where-Object { $_ })
    if ($act.Count -gt 0) {
        $names = @($act | ForEach-Object { "$($_.id)$(if ($_.git_branch) { " [$($_.git_branch)]" })" })
        $lines += "$($act.Count) peer(s) ativo(s): $($names -join '; ')."
    }
    else {
        $lines += 'Nenhum outro peer ativo neste projeto.'
    }
    if ($UnreadCount -gt 0) { $lines += "$UnreadCount recado(s) na sua caixa — rode /peers para ler." }
    $lines += '(peer-heartbeat: presença file-based; nada da curadoria foi alterado)'
    return ($lines -join "`n")
}

# --- Fluxo principal --------------------------------------------------------------------------
function Invoke-PeerHeartbeat {
    # 1) payload (falha -> silêncio)
    try { $raw = [Console]::In.ReadToEnd() } catch { return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    try { $payload = $raw | ConvertFrom-Json } catch { return }

    # 2) contexto: evento + raiz + id da sessão
    $eventName = [string](Get-PropOrNull $payload 'hook_event_name')
    if (-not $eventName) { $eventName = 'SessionStart' }
    $root = [string](Get-PropOrNull $payload 'cwd')
    if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath (Join-Path $root '.claude') -PathType Container)) { return }
    $selfId = [string](Get-PropOrNull $payload 'session_id')
    if ([string]::IsNullOrWhiteSpace($selfId)) { return }   # sem id estável -> não há peer

    # 3) resolve tools/ (cascata) -> sem ela, fail-safe silêncio
    $tools = Resolve-ToolsRoot -StartDir $root
    if ($tools.Degraded) { return }
    try { . (Join-Path $tools.Path 'peers.ps1') } catch { return }

    $board = Resolve-PeerBoard -Root $root

    if ($eventName -eq 'PostToolUse') {
        # refresca o heartbeat (cooldown interno); silêncio sempre
        try { Update-PeerHeartbeat -BoardDir $board -Id $selfId | Out-Null } catch { Write-Verbose "heartbeat não atualizado: $($_.Exception.Message)" }
        return
    }

    # SessionStart: grava presença (summary derivado, sem rede) + poda stale + anuncia
    try {
        $branch = Get-PeerGitBranch -Root $root
        $summary = Get-DerivedSummary -Branch $branch -Phase (Get-PeerSddPhase -Root $root) -RecentFiles (Get-PeerRecentFiles -Root $root)
        Write-PeerPresence -BoardDir $board -Id $selfId -Cwd $root -Branch $branch -Summary $summary | Out-Null
        Remove-StalePeers -BoardDir $board | Out-Null
        $peers = @(Get-PeerInventory -BoardDir $board -SelfId $selfId | Where-Object { -not $_.IsStale -and -not $_.IsSelf })
        $unread = @(Get-ChildItem -LiteralPath (Join-Path (Join-Path $board ($selfId -replace '[^A-Za-z0-9_.-]', '_')) 'inbox') -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
        $text = Format-PeerAnnounce -SelfId $selfId -ActivePeers $peers -UnreadCount $unread
        Write-Output (New-PeerHeartbeatJson -Context $text -EventName $eventName)
    }
    catch { return }
}

# --- Guard: roda o fluxo só quando NÃO dot-sourced (Pester faz `. peer-heartbeat.ps1`) ---------
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PeerHeartbeat
}

<#
.SYNOPSIS
    Hook curation-nudge (EPIC J) — avisa staleness da curadoria. READ-ONLY e não-bloqueante.

.DESCRIPTION
    Registrado no .claude/settings.json do projeto (hooks.SessionStart matcher "*" e
    hooks.PostToolUse matcher "Write|Edit"). Em cada disparo decide:
      - stdin inválido / fora de projeto / cooldown / path fora de escopo / tools ausente
                                                          -> SILÊNCIO (exit 0, sem stdout)
      - curadoria com ≥1 sinal de staleness              -> emite additionalContext (nudge)
      - tudo em dia                                       -> SILÊNCIO

    Sinais (reusa inventários existentes, NÃO reimplementa varredura):
      - curation : Get-CurationStatus (init.ps1) — NextStep ≠ done
      - skills   : Get-SkillInventory+Get-SkillHealth (update-skills.ps1) — orphan/malformed
      - index    : Build-KbIndex/Build-AgentMap (sync-context.ps1) — gerado ≠ em disco

    NUNCA altera .claude/kb|agents|rules. O único arquivo escrito é o marcador de cooldown
    .claude/.cache/nudge-state.json (transitório; .gitignore cobre .cache/).

    Schema dos hooks verificado via context7 (/anthropics/claude-code, 2026-06-06):
      saída informativa = { hookSpecificOutput: { hookEventName, additionalContext } }
      silêncio          = exit 0 sem stdout
      stdin             = { hook_event_name, cwd, tool_input:{ file_path }, ... }

    Funções puras (Test-IsCuratedPath / Get-StalenessSignals / Test-CooldownElapsed /
    Format-Nudge / New-NudgeHookJson) são dot-sourceáveis para teste; o fluxo só roda quando
    o script NÃO é dot-sourced (guard no fim).
#>

Set-StrictMode -Version Latest

# Janela de cooldown do PostToolUse (segundos). SessionStart não aplica (baseline 1×/sessão).
$script:CooldownSeconds = 1800

# --- Acesso seguro a propriedade sob StrictMode (PSCustomObject do ConvertFrom-Json) ----------
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# --- PURA: resolve a raiz de tools/ pela cascata (ver rules/tooling.md) ------------------------
function Resolve-ToolsRoot {
    <#
    .SYNOPSIS
        Cascata de resolução da camada tools/: (1) tools/ relativo a -StartDir; (2)
        $WorkflowHome/tools; (3) degradação. Read-only (Test-Path). Mesma ordem do snippet
        canônico em rules/tooling.md (não compartilham código: resolve tools/ antes de tê-lo).
    .OUTPUTS
        [pscustomobject] { Path = <dir> | $null ; Source = 'relative'|'env'|'none' ; Degraded = [bool] }
    #>
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

# --- PURA: extrai os 5 campos canonicos do payload ja parseado (contrato H5/HARNESS-CONTRACT.md).
#     Ponto unico de acesso aos campos -- usado pelo fluxo do hook e por qualquer adapter de
#     harness que ja produza o payload no formato canonico. Espelha destructive-guard.ps1.
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

# --- PURA: o path editado cai sob a curadoria? ------------------------------------------------
function Test-IsCuratedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.Replace('\', '/')
    return [bool]($p -match '(?i)\.claude/(kb|agents|rules)/')
}

# --- PURA: snapshot -> lista de sinais disparados ---------------------------------------------
function Get-StalenessSignals {
    param([psobject]$Snapshot)
    if ($null -eq $Snapshot) { return @() }
    $signals = @()

    $cs = Get-PropOrNull $Snapshot 'CurationStatus'
    if ($cs) {
        $next = [string](Get-PropOrNull $cs 'NextStep')
        if ($next -and $next -ne 'done') {
            $cmd = switch ($next) {
                'setup'        { '/setup' }
                'audit-agents' { '/audit-agents' }
                'train-kb'     { '/train-kb' }
                'sync-context' { '/sync-context' }
                default        { '/init' }
            }
            $signals += [pscustomobject]@{ Signal = 'curation'; Detail = "curadoria incompleta (proximo: $next)"; Command = $cmd }
        }
    }

    $stale = [int](Get-PropOrNull $Snapshot 'StaleSkills')
    if ($stale -gt 0) {
        $signals += [pscustomobject]@{ Signal = 'skills'; Detail = "$stale skill(s) com problema (orphan/malformed)"; Command = '/update-skills' }
    }

    if ([bool](Get-PropOrNull $Snapshot 'IndexDrift')) {
        $detail = [string](Get-PropOrNull $Snapshot 'IndexDetail')
        if (-not $detail) { $detail = 'indices divergem do estado real' }
        $signals += [pscustomobject]@{ Signal = 'index'; Detail = $detail; Command = '/sync-context' }
    }

    if ([bool](Get-PropOrNull $Snapshot 'KbOverBudget')) {
        $detail = [string](Get-PropOrNull $Snapshot 'KbBudgetDetail')
        if (-not $detail) { $detail = 'KB acima do budget agregado' }
        $signals += [pscustomobject]@{ Signal = 'reflect'; Detail = $detail; Command = '/reflect' }
    }

    if ([bool](Get-PropOrNull $Snapshot 'LessonsReady')) {
        $detail = [string](Get-PropOrNull $Snapshot 'LessonsDetail')
        if (-not $detail) { $detail = 'lições candidatas acumuladas no acervo' }
        $signals += [pscustomobject]@{ Signal = 'learn'; Detail = $detail; Command = '/learn' }
    }

    return @($signals)
}

# --- PURA: cooldown decorreu? -----------------------------------------------------------------
function Test-CooldownElapsed {
    param([long]$LastEpoch, [long]$NowEpoch, [int]$WindowSeconds)
    if ($LastEpoch -le 0) { return $true }
    return [bool](($NowEpoch - $LastEpoch) -ge $WindowSeconds)
}

# --- PURA: monta o texto do nudge -------------------------------------------------------------
function Format-Nudge {
    param([pscustomobject[]]$Signals)
    $Signals = @($Signals | Where-Object { $_ })
    if ($Signals.Count -eq 0) { return '' }
    $lines = @('Curadoria deste projeto possivelmente desatualizada:')
    foreach ($s in $Signals) {
        $lines += ("- {0} -> rode {1}" -f $s.Detail, $s.Command)
    }
    $lines += '(curation-nudge: aviso read-only; nada foi alterado)'
    return ($lines -join "`n")
}

# --- PURA: JSON de saída informativo (sem permissionDecision) ---------------------------------
function New-NudgeHookJson {
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

# --- PURA: normaliza texto p/ comparação de drift (CRLF->LF, trim final) ----------------------
function ConvertTo-NormalizedText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return ((($Text -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd())
}

# --- I/O: marcador de cooldown (único arquivo escrito) ----------------------------------------
function Get-NudgeStatePath {
    param([Parameter(Mandatory)][string]$Root)
    return (Join-Path $Root '.claude/.cache/nudge-state.json')
}

function Read-NudgeState {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return [pscustomobject]@{ LastEpoch = [long]0; LastSignals = @() }
        }
        $o = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) | ConvertFrom-Json
        $epoch = [long](Get-PropOrNull $o 'last_nudge_epoch')
        $sigs = Get-PropOrNull $o 'last_signals'
        if ($null -eq $sigs) { $sigs = @() }
        return [pscustomobject]@{ LastEpoch = $epoch; LastSignals = @($sigs) }
    }
    catch { return [pscustomobject]@{ LastEpoch = [long]0; LastSignals = @() } }
}

function Write-NudgeState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Epoch,
        [AllowEmptyCollection()][string[]]$Signals = @()
    )
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $obj = [ordered]@{ last_nudge_epoch = $Epoch; last_signals = @($Signals) }
        Set-Content -LiteralPath $Path -Value ($obj | ConvertTo-Json -Depth 5 -Compress) -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Falha de escrita do marcador é não-fatal: o nudge já foi emitido. Pior caso: sem cooldown.
        Write-Verbose "nudge-state não gravado: $($_.Exception.Message)"
    }
}

# --- I/O: reúne os inventários (read-only), isolando falha por sinal --------------------------
function Get-CurationSnapshot {
    <#
    .SYNOPSIS
        Reúne os 3 sinais reusando os inventários de tools/ em -Root. Cada sinal é coletado em seu
        próprio try/catch — falha de um (ex.: tools incompleto) não derruba os demais. Read-only.
    .OUTPUTS
        [pscustomobject] { CurationStatus; StaleSkills; IndexDrift; IndexDetail }
    #>
    param([Parameter(Mandatory)][string]$Root)

    $toolsDir = (Resolve-ToolsRoot -StartDir $Root).Path
    $snap = [pscustomobject]@{ CurationStatus = $null; StaleSkills = [int]0; IndexDrift = $false; IndexDetail = ''; KbOverBudget = $false; KbBudgetDetail = ''; LessonsReady = $false; LessonsDetail = '' }

    # 1) curation status (init.ps1 já dot-source agent-lint + kb-lint)
    try {
        . (Join-Path $toolsDir 'init.ps1')
        $snap.CurationStatus = Get-CurationStatus -Root $Root
    }
    catch { Write-Verbose "sinal curation indisponível: $($_.Exception.Message)" }

    # 2) skills com problema (orphan/malformed; baseline-free -> determinístico e sem dependência)
    try {
        . (Join-Path $toolsDir 'update-skills.ps1')
        $projSkills = Join-Path $Root '.claude/skills'
        $inv = @(Get-SkillInventory -GlobalRoot $null -ProjectRoot $projSkills)
        $bad = 0
        foreach ($s in $inv) {
            $h = Get-SkillHealth -Skill $s -BaselineMap @()
            if ($h.Health -in @('orphan', 'malformed')) { $bad++ }
        }
        $snap.StaleSkills = $bad
    }
    catch { Write-Verbose "sinal skills indisponível: $($_.Exception.Message)" }

    # 3) drift de índice (gerado × em disco; só p/ arquivos existentes)
    try {
        . (Join-Path $toolsDir 'sync-context.ps1')
        . (Join-Path $toolsDir 'agent-lint.ps1')
        . (Join-Path $toolsDir 'kb-lint.ps1')

        $drift = $false
        $details = @()

        $mapPath = Join-Path $Root '.claude/agents/AGENT_MAP.md'
        if (Test-Path -LiteralPath $mapPath -PathType Leaf) {
            $agents = @(Get-AgentInventory -Dir (Join-Path $Root '.claude/agents'))
            $cmdDir = Join-Path $Root '.claude/commands'
            $cmds = @()
            if (Test-Path -LiteralPath $cmdDir -PathType Container) {
                $cmds = @(Get-ChildItem -LiteralPath $cmdDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
                        ForEach-Object { $_.BaseName })
            }
            $gen = Build-AgentMap -Agents $agents -Commands $cmds
            $disk = Get-Content -LiteralPath $mapPath -Raw -ErrorAction Stop
            if ((ConvertTo-NormalizedText $gen) -ne (ConvertTo-NormalizedText $disk)) {
                $drift = $true; $details += 'AGENT_MAP.md'
            }
        }

        $idxPath = Join-Path $Root '.claude/kb/_index.yaml'
        if (Test-Path -LiteralPath $idxPath -PathType Leaf) {
            $kb = @(Get-KbInventory -Dir (Join-Path $Root '.claude/kb'))
            $gen = Build-KbIndex -Entries $kb
            $disk = Get-Content -LiteralPath $idxPath -Raw -ErrorAction Stop
            if ((ConvertTo-NormalizedText $gen) -ne (ConvertTo-NormalizedText $disk)) {
                $drift = $true; $details += '_index.yaml'
            }
        }

        $snap.IndexDrift = $drift
        if ($drift) { $snap.IndexDetail = "indices divergem do estado real: $($details -join ', ')" }
    }
    catch { Write-Verbose "sinal index indisponível: $($_.Exception.Message)" }

    # 4) KB acima do budget agregado -> sugere /reflect (G6; reusa reflect.ps1 -> kb-lint/B7)
    try {
        $kbDir = Join-Path $Root '.claude/kb'
        if (Test-Path -LiteralPath $kbDir -PathType Container) {
            . (Join-Path $toolsDir 'reflect.ps1')
            $b = Test-KbOverBudget -Dir $kbDir
            if ($b.OverBudget) {
                $snap.KbOverBudget = $true
                $snap.KbBudgetDetail = "KB grande ($($b.Reason))"
            }
        }
    }
    catch { Write-Verbose "sinal reflect indisponível: $($_.Exception.Message)" }

    # 5) Acervo de lições candidatas >= limiar -> sugere /learn (G7; reusa learn.ps1 -> kb-lint/B7)
    try {
        $archiveDir = Join-Path $Root '.claude/sdd/archive'
        if (Test-Path -LiteralPath $archiveDir -PathType Container) {
            . (Join-Path $toolsDir 'learn.ps1')
            $ls = Test-LessonsReady -ArchiveDir $archiveDir -KbDir (Join-Path $Root '.claude/kb')
            if ($ls.Ready) {
                $snap.LessonsReady = $true
                $snap.LessonsDetail = "lições candidatas acumuladas ($($ls.PendingCount) pendentes)"
            }
        }
    }
    catch { Write-Verbose "sinal learn indisponível: $($_.Exception.Message)" }

    return $snap
}

# --- Fluxo principal --------------------------------------------------------------------------
function Invoke-CurationNudge {
    # 1) Ler payload (falha -> silêncio)
    try { $raw = [Console]::In.ReadToEnd() } catch { return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    try { $payload = $raw | ConvertFrom-Json } catch { return }

    # 2) Contexto: evento + raiz do projeto
    $evt = Read-NormalizedEvent $payload
    $eventName = $evt.HookEventName
    if (-not $eventName) { $eventName = 'SessionStart' }
    $root = $evt.Cwd
    if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath (Join-Path $root '.claude') -PathType Container)) { return }

    $statePath = Get-NudgeStatePath -Root $root
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # 3) PostToolUse: filtra por escopo de path + cooldown (SessionStart não filtra: é o baseline)
    if ($eventName -eq 'PostToolUse') {
        if (-not (Test-IsCuratedPath $evt.FilePath)) { return }
        $state = Read-NudgeState -Path $statePath
        if (-not (Test-CooldownElapsed -LastEpoch $state.LastEpoch -NowEpoch $now -WindowSeconds $script:CooldownSeconds)) { return }
    }

    # 4) Resolve a camada tools/ pela cascata (rules/tooling.md): relativo -> SDD_WORKFLOW_HOME ->
    #    degradação. Degradada (nenhuma via) -> fail-safe silêncio. Reativa o nudge no projeto-alvo.
    if ((Resolve-ToolsRoot -StartDir $root).Degraded) { return }

    # 5) Reúne sinais (read-only) e decide
    try { $snapshot = Get-CurationSnapshot -Root $root } catch { return }
    $signals = @(Get-StalenessSignals -Snapshot $snapshot)
    if ($signals.Count -eq 0) { return }   # tudo em dia -> silêncio total

    $text = Format-Nudge -Signals $signals
    if ([string]::IsNullOrWhiteSpace($text)) { return }

    Write-Output (New-NudgeHookJson -Context $text -EventName $eventName)
    Write-NudgeState -Path $statePath -Epoch $now -Signals @($signals | ForEach-Object { $_.Signal })
}

# --- Guard: roda o fluxo só quando NÃO dot-sourced (Pester faz `. curation-nudge.ps1`) ---------
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-CurationNudge
}

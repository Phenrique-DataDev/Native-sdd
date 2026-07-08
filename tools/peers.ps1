<#
.SYNOPSIS
    peers (EPIC H, H10) — coordenação entre sessões concorrentes do Claude Code, file-based.

.DESCRIPTION
    Lógica determinística do quadro de peers. Versão nativa low-friction da tática do
    claude-peers-mcp: SEM daemon/SQLite/Bun/canal experimental — só arquivos sob
    .claude/.cache/peers/ (gitignored), escritos pelo hook peer-heartbeat e lidos pelo /peers.

    Modelo do board (1 arquivo por sessão evita contenção de escrita; ver DESIGN D-002):
      .claude/.cache/peers/<session-id>.json        -> presença de uma sessão
      .claude/.cache/peers/<dest>/inbox/<ts>-<from>.json  -> 1 recado (não append num .jsonl)
      .claude/.cache/peers/<dest>/inbox/.read/       -> recados já lidos (read-once por mover)

    Funções PURAS (New-PeerRecord / Get-DerivedSummary / Test-PeerStale / Format-PeerReport /
    Format-PeerAge / ConvertTo-PeerMessageFile) + I/O por-sinal — dot-sourceáveis para teste
    (sem guard de fluxo: este arquivo é biblioteca, não roda nada ao ser dot-sourced).

    Reuso (DESIGN D-006): o summary derivado puxa branch + fase SDD de tools/status.ps1
    (Get-GitContext / Get-SddFeatureStatus) quando disponível; degrada p/ branch-only.
    NUNCA chama rede (corta o auto-summary OpenAI do original).
#>

Set-StrictMode -Version Latest

# Janela de "peer ativo" (s) e cooldown do heartbeat (s). Ver DESIGN D-003.
$script:PeerTtlSeconds = 900          # 15 min sem heartbeat -> peer considerado morto
$script:PeerHeartbeatCooldown = 60    # PostToolUse reescreve no máx. 1x/min

# --- Acesso seguro a propriedade sob StrictMode (PSCustomObject do ConvertFrom-Json) ----------
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# --- PURA: epoch UTC atual (isolável em teste via -NowEpoch dos chamadores) --------------------
function Get-PeerNow {
    return [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# --- PURA: objeto de presença -----------------------------------------------------------------
function New-PeerRecord {
    param(
        [Parameter(Mandatory)][string]$Id,
        [AllowEmptyString()][string]$Cwd = '',
        [AllowEmptyString()][string]$Branch = '',
        [AllowEmptyString()][string]$Summary = '',
        [Parameter(Mandatory)][long]$StartedAt,
        [Parameter(Mandatory)][long]$HeartbeatAt
    )
    return [ordered]@{
        id           = $Id
        cwd          = $Cwd
        git_branch   = $Branch
        summary      = $Summary
        started_at   = $StartedAt
        heartbeat_at = $HeartbeatAt
    }
}

# --- PURA: monta o summary derivado (branch + fase SDD + arquivos recentes). SÓ NOMES ----------
function Get-DerivedSummary {
    param(
        [AllowEmptyString()][string]$Branch = '',
        [AllowEmptyString()][string]$Phase = '',
        [AllowEmptyCollection()][string[]]$RecentFiles = @()
    )
    $parts = @()
    if ($Branch) { $parts += $Branch }
    if ($Phase) { $parts += $Phase }
    $files = @($RecentFiles | Where-Object { $_ } | Select-Object -First 3)
    if ($files.Count -gt 0) { $parts += ($files -join ', ') }
    if ($parts.Count -eq 0) { return '(sem contexto)' }
    return ($parts -join ' · ')
}

# --- PURA: o peer está morto? (heartbeat + TTL < agora) ---------------------------------------
function Test-PeerStale {
    param(
        [Parameter(Mandatory)][long]$HeartbeatAt,
        [Parameter(Mandatory)][long]$NowEpoch,
        [int]$TtlSeconds = $script:PeerTtlSeconds
    )
    if ($HeartbeatAt -le 0) { return $true }
    return [bool](($NowEpoch - $HeartbeatAt) -ge $TtlSeconds)
}

# --- PURA: idade legível ("há 2 min", "agora") ------------------------------------------------
function Format-PeerAge {
    param([long]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    if ($Seconds -lt 45) { return 'agora' }
    $min = [math]::Round($Seconds / 60)
    if ($min -lt 60) { return "há $min min" }
    $h = [math]::Round($min / 60)
    return "há ${h}h"
}

# --- PURA: nome de arquivo de recado (ts-from.json), saneado ----------------------------------
function ConvertTo-PeerMessageFile {
    param(
        [Parameter(Mandatory)][long]$At,
        [Parameter(Mandatory)][string]$From
    )
    $safe = ($From -replace '[^A-Za-z0-9_.-]', '_')
    return ("{0}-{1}.json" -f $At, $safe)
}

# --- PURA: relatório do /peers (peers ativos + caixa de entrada) ------------------------------
function Format-PeerReport {
    param(
        [AllowEmptyCollection()][object[]]$Peers = @(),
        [AllowEmptyCollection()][object[]]$Inbox = @(),
        [Parameter(Mandatory)][long]$NowEpoch,
        [AllowEmptyString()][string]$SelfId = ''
    )
    $active = @($Peers | Where-Object { $_ -and -not $_.IsStale -and $_.id -ne $SelfId })
    $lines = [System.Collections.Generic.List[string]]::new()

    if ($active.Count -eq 0) {
        $lines.Add('Peers ativos: nenhum (você está sozinho neste projeto).')
    }
    else {
        $lines.Add("Peers ativos ($($active.Count)):")
        foreach ($p in ($active | Sort-Object { [long]$_.heartbeat_at } -Descending)) {
            $age = Format-PeerAge -Seconds ([long]$NowEpoch - [long]$p.heartbeat_at)
            $branch = if ($p.git_branch) { "[$($p.git_branch)]" } else { '[?]' }
            $sum = if ($p.summary) { $p.summary } else { '(sem summary)' }
            $lines.Add(("  - {0}  {1}  {2}  ({3})" -f $p.id, $branch, $sum, $age))
        }
    }

    $msgs = @($Inbox | Where-Object { $_ })
    if ($msgs.Count -gt 0) {
        $lines.Add('')
        $lines.Add("Sua caixa ($($msgs.Count) novo(s)):")
        foreach ($m in ($msgs | Sort-Object { [long](Get-PropOrNull $_ 'at') })) {
            $from = [string](Get-PropOrNull $m 'from')
            $text = [string](Get-PropOrNull $m 'text')
            $at = [long](Get-PropOrNull $m 'at')
            $age = Format-PeerAge -Seconds ([long]$NowEpoch - $at)
            $lines.Add(("  - de {0}: {1}  ({2})" -f $from, $text, $age))
        }
    }
    return ($lines -join "`n")
}

# --- I/O: resolve a raiz do board (.claude/.cache/peers) sob -Root ----------------------------
function Resolve-PeerBoard {
    param([Parameter(Mandatory)][string]$Root)
    return (Join-Path $Root '.claude/.cache/peers')
}

# --- I/O leitura: branch git (read-only, fail-safe '') ----------------------------------------
function Get-PeerGitBranch {
    param([Parameter(Mandatory)][string]$Root)
    try {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
        $b = & git -C $Root rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { return '' }
        return ([string]$b).Trim()
    }
    catch { return '' }
}

# --- I/O leitura: fase SDD da feature in-flight (reusa status.ps1; fail-safe '') ---------------
function Get-PeerSddPhase {
    param([Parameter(Mandatory)][string]$Root)
    try {
        $statusScript = Join-Path $PSScriptRoot 'status.ps1'
        if (-not (Test-Path -LiteralPath $statusScript -PathType Leaf)) { return '' }
        . $statusScript
        $feats = @(Get-SddFeatureStatus -Root $Root | Where-Object { -not $_.Shipped })
        if ($feats.Count -eq 0) { return '' }
        # a feature mais avançada in-flight
        $f = $feats | Sort-Object { @('brainstorm', 'define', 'design', 'build').IndexOf([string]$_.Phase) } -Descending | Select-Object -First 1
        return ("{0}:{1}" -f $f.Phase, $f.Feature)
    }
    catch { return '' }
}

# --- I/O leitura: até 3 arquivos recentes do working tree (só nomes; fail-safe @()) -----------
# Usa `git status --porcelain` -> pega modificados E novos (untracked) = sinal de colisão real.
function Get-PeerRecentFiles {
    param([Parameter(Mandatory)][string]$Root)
    try {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return @() }
        $out = @(& git -C $Root status --porcelain 2>$null)
        if ($LASTEXITCODE -ne 0) { return @() }
        return @($out |
                Where-Object { $_ } |
                ForEach-Object { ($_.Substring([math]::Min(3, $_.Length))).Trim('"') } |
                Where-Object { $_ } |
                ForEach-Object { Split-Path $_ -Leaf } |
                Select-Object -First 3)
    }
    catch { return @() }
}

# --- I/O: lê o arquivo de presença de um id (ou $null) ----------------------------------------
function Read-PeerFile {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        return ((Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) | ConvertFrom-Json)
    }
    catch { return $null }
}

# --- I/O: grava/atualiza a presença da própria sessão -----------------------------------------
function Write-PeerPresence {
    param(
        [Parameter(Mandatory)][string]$BoardDir,
        [Parameter(Mandatory)][string]$Id,
        [AllowEmptyString()][string]$Cwd = '',
        [AllowEmptyString()][string]$Branch = '',
        [AllowEmptyString()][string]$Summary = '',
        [long]$NowEpoch = (Get-PeerNow)
    )
    try {
        if (-not (Test-Path -LiteralPath $BoardDir -PathType Container)) {
            New-Item -ItemType Directory -Path $BoardDir -Force -ErrorAction Stop | Out-Null
        }
        $path = Join-Path $BoardDir ("{0}.json" -f ($Id -replace '[^A-Za-z0-9_.-]', '_'))
        $existing = Read-PeerFile -Path $path
        $started = if ($existing) { [long](Get-PropOrNull $existing 'started_at') } else { $NowEpoch }
        if ($started -le 0) { $started = $NowEpoch }
        $rec = New-PeerRecord -Id $Id -Cwd $Cwd -Branch $Branch -Summary $Summary -StartedAt $started -HeartbeatAt $NowEpoch
        Set-Content -LiteralPath $path -Value ($rec | ConvertTo-Json -Depth 5 -Compress) -Encoding UTF8 -ErrorAction Stop
        return $true
    }
    catch {
        Write-Verbose "peer presence não gravada: $($_.Exception.Message)"
        return $false
    }
}

# --- I/O: refresca só o heartbeat se passou o cooldown (PostToolUse) ---------------------------
function Update-PeerHeartbeat {
    param(
        [Parameter(Mandatory)][string]$BoardDir,
        [Parameter(Mandatory)][string]$Id,
        [long]$NowEpoch = (Get-PeerNow),
        [int]$CooldownSeconds = $script:PeerHeartbeatCooldown
    )
    try {
        $path = Join-Path $BoardDir ("{0}.json" -f ($Id -replace '[^A-Za-z0-9_.-]', '_'))
        $existing = Read-PeerFile -Path $path
        if (-not $existing) { return $false }   # sem presença -> SessionStart cria; PostToolUse não inventa
        $last = [long](Get-PropOrNull $existing 'heartbeat_at')
        if (($NowEpoch - $last) -lt $CooldownSeconds) { return $false }   # dentro do cooldown
        $rec = New-PeerRecord -Id ([string](Get-PropOrNull $existing 'id')) `
            -Cwd ([string](Get-PropOrNull $existing 'cwd')) `
            -Branch ([string](Get-PropOrNull $existing 'git_branch')) `
            -Summary ([string](Get-PropOrNull $existing 'summary')) `
            -StartedAt ([long](Get-PropOrNull $existing 'started_at')) `
            -HeartbeatAt $NowEpoch
        Set-Content -LiteralPath $path -Value ($rec | ConvertTo-Json -Depth 5 -Compress) -Encoding UTF8 -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

# --- I/O: override manual do summary ----------------------------------------------------------
function Set-PeerSummary {
    param(
        [Parameter(Mandatory)][string]$BoardDir,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [long]$NowEpoch = (Get-PeerNow)
    )
    $path = Join-Path $BoardDir ("{0}.json" -f ($Id -replace '[^A-Za-z0-9_.-]', '_'))
    $existing = Read-PeerFile -Path $path
    $branch = if ($existing) { [string](Get-PropOrNull $existing 'git_branch') } else { '' }
    $cwd = if ($existing) { [string](Get-PropOrNull $existing 'cwd') } else { '' }
    return (Write-PeerPresence -BoardDir $BoardDir -Id $Id -Cwd $cwd -Branch $branch -Summary $Text -NowEpoch $NowEpoch)
}

# --- I/O: lê o board e devolve os peers (anexa IsStale; opcional exclui self) ------------------
function Get-PeerInventory {
    param(
        [Parameter(Mandatory)][string]$BoardDir,
        [AllowEmptyString()][string]$SelfId = '',
        [long]$NowEpoch = (Get-PeerNow),
        [int]$TtlSeconds = $script:PeerTtlSeconds
    )
    if (-not (Test-Path -LiteralPath $BoardDir -PathType Container)) { return @() }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($f in (Get-ChildItem -LiteralPath $BoardDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $o = Read-PeerFile -Path $f.FullName
        if ($null -eq $o) { continue }
        $id = [string](Get-PropOrNull $o 'id')
        if (-not $id) { continue }
        $hb = [long](Get-PropOrNull $o 'heartbeat_at')
        $out.Add([pscustomobject]@{
                id           = $id
                cwd          = [string](Get-PropOrNull $o 'cwd')
                git_branch   = [string](Get-PropOrNull $o 'git_branch')
                summary      = [string](Get-PropOrNull $o 'summary')
                started_at   = [long](Get-PropOrNull $o 'started_at')
                heartbeat_at = $hb
                IsStale      = (Test-PeerStale -HeartbeatAt $hb -NowEpoch $NowEpoch -TtlSeconds $TtlSeconds)
                IsSelf       = ($id -eq $SelfId)
            })
    }
    return @($out)
}

# --- I/O: poda os arquivos de peers stale (heartbeat > TTL); devolve nº podado -----------------
function Remove-StalePeers {
    param(
        [Parameter(Mandatory)][string]$BoardDir,
        [long]$NowEpoch = (Get-PeerNow),
        [int]$TtlSeconds = $script:PeerTtlSeconds
    )
    if (-not (Test-Path -LiteralPath $BoardDir -PathType Container)) { return 0 }
    $n = 0
    foreach ($f in (Get-ChildItem -LiteralPath $BoardDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $o = Read-PeerFile -Path $f.FullName
        if ($null -eq $o) { continue }
        $hb = [long](Get-PropOrNull $o 'heartbeat_at')
        if (Test-PeerStale -HeartbeatAt $hb -NowEpoch $NowEpoch -TtlSeconds $TtlSeconds) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++ }
            catch { Write-Verbose "peer stale não podado: $($_.Exception.Message)" }
        }
    }
    return $n
}

# --- I/O: envia 1 recado (1 arquivo por mensagem; sem corrida de append) -----------------------
function Add-PeerMessage {
    param(
        [Parameter(Mandatory)][string]$BoardDir,
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [long]$NowEpoch = (Get-PeerNow)
    )
    try {
        $inbox = Join-Path (Join-Path $BoardDir ($Dest -replace '[^A-Za-z0-9_.-]', '_')) 'inbox'
        if (-not (Test-Path -LiteralPath $inbox -PathType Container)) {
            New-Item -ItemType Directory -Path $inbox -Force -ErrorAction Stop | Out-Null
        }
        $name = ConvertTo-PeerMessageFile -At $NowEpoch -From $From
        $path = Join-Path $inbox $name
        # colisão no mesmo segundo do mesmo remetente -> sufixo incremental
        $i = 1
        while (Test-Path -LiteralPath $path -PathType Leaf) {
            $path = Join-Path $inbox (($name -replace '\.json$', "_$i.json")); $i++
        }
        $msg = [ordered]@{ from = $From; to = $Dest; text = $Text; at = $NowEpoch }
        Set-Content -LiteralPath $path -Value ($msg | ConvertTo-Json -Depth 5 -Compress) -Encoding UTF8 -ErrorAction Stop
        return $true
    }
    catch {
        Write-Verbose "recado não enviado: $($_.Exception.Message)"
        return $false
    }
}

# --- I/O: lê a caixa de um id e MOVE p/ inbox/.read/ (read-once) -------------------------------
function Read-PeerInbox {
    param(
        [Parameter(Mandatory)][string]$BoardDir,
        [Parameter(Mandatory)][string]$Id
    )
    $inbox = Join-Path (Join-Path $BoardDir ($Id -replace '[^A-Za-z0-9_.-]', '_')) 'inbox'
    if (-not (Test-Path -LiteralPath $inbox -PathType Container)) { return @() }
    $readDir = Join-Path $inbox '.read'
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($f in (Get-ChildItem -LiteralPath $inbox -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $o = Read-PeerFile -Path $f.FullName
        if ($null -ne $o) { $out.Add($o) }
        try {
            if (-not (Test-Path -LiteralPath $readDir -PathType Container)) {
                New-Item -ItemType Directory -Path $readDir -Force -ErrorAction Stop | Out-Null
            }
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $readDir $f.Name) -Force -ErrorAction Stop
        }
        catch { Write-Verbose "recado não movido p/ .read/: $($_.Exception.Message)" }
    }
    return @($out)
}

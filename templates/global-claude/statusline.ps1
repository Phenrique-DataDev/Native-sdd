# statusline.ps1 — HUD do Claude Code (2 linhas).
# Recebe o JSON de status no stdin e imprime a linha de status.
# Invocado via:  pwsh -NoProfile -File ~/.claude/statusline.ps1
# Doc do schema: https://code.claude.com/docs/en/statusline
# Sem StrictMode de propósito: acesso a campo ausente retorna $null (resiliente).

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

# --- lê o JSON do stdin ---------------------------------------------------
$raw  = [Console]::In.ReadToEnd()
$data = if ($raw) { $raw | ConvertFrom-Json } else { $null }

# --- cores (Dracula) ------------------------------------------------------
$ESC = [char]27
function Paint([int]$r, [int]$g, [int]$b, [string]$t, [string]$mode = '') {
    $pre = switch ($mode) { 'bold' { '1;' } 'dim' { '2;' } default { '' } }
    return "$ESC[${pre}38;2;$r;$g;${b}m$t$ESC[0m"
}
$Purple = @(189, 147, 249); $Cyan = @(139, 233, 253); $Green = @(80, 250, 123)
$Yellow = @(241, 250, 140); $Orange = @(255, 184, 108); $Red = @(255, 85, 85)
$Pink = @(255, 121, 198);   $Comment = @(98, 114, 164); $Track = @(68, 71, 90)
function P($c, $t, $m = '') { Paint $c[0] $c[1] $c[2] $t $m }
$SEP = (P $Comment '  ·  ')

# --- helpers de formato ---------------------------------------------------
$inv = [System.Globalization.CultureInfo]::InvariantCulture
function Fmt-Tokens([double]$n) {
    if ($n -ge 1000000) { return ([string]::Format($inv, '{0:0.0}M', $n / 1000000)) }
    if ($n -ge 1000)    { return ([string]::Format($inv, '{0:0}k', $n / 1000)) }
    return ([int]$n).ToString()
}
function Fmt-Size([double]$n) {
    if ($n -ge 900000) { return '1M' }
    if ($n -ge 150000) { return '200k' }
    return (Fmt-Tokens $n)
}
function Fmt-Duration([double]$ms) {
    $s = [int]($ms / 1000); $m = [int]($s / 60); $sec = $s % 60
    if ($m -gt 0) { return "${m}m${sec}s" }
    return "${sec}s"
}

# --- extrai campos (com defaults) ----------------------------------------
$model   = if ($data.model.display_name) { $data.model.display_name } elseif ($data.model.id) { $data.model.id } else { '?' }
$cwd     = if ($data.workspace.current_dir) { $data.workspace.current_dir } elseif ($data.cwd) { $data.cwd } else { (Get-Location).Path }
$projDir = if ($data.workspace.project_dir) { $data.workspace.project_dir } else { $cwd }
$version = $data.version
$dir     = Split-Path -Leaf $cwd

$ctxSize = if ($data.context_window.context_window_size) { [double]$data.context_window.context_window_size } else { 200000 }
$usedPct = $data.context_window.used_percentage
$ctxKnown = ($null -ne $usedPct)
$usedInt = if ($ctxKnown) { [int][math]::Round([double]$usedPct) } else { 0 }
$ctxTokens = [int]([math]::Round($ctxSize * $usedInt / 100))

$totIn  = [double]($data.context_window.total_input_tokens  | ForEach-Object { $_ }); if (-not $totIn)  { $totIn = 0 }
$totOut = [double]($data.context_window.total_output_tokens | ForEach-Object { $_ }); if (-not $totOut) { $totOut = 0 }
$totTokens = $totIn + $totOut

$cost   = [double]($data.cost.total_cost_usd); if (-not $cost) { $cost = 0 }
$durMs  = [double]($data.cost.total_duration_ms); if (-not $durMs) { $durMs = 0 }

# --- git (lock-free, resiliente) -----------------------------------------
$branch = ''; $staged = 0; $modified = 0; $untracked = 0
$gitRoot = if (Test-Path (Join-Path $cwd '.git')) { $cwd } elseif (Test-Path (Join-Path $projDir '.git')) { $projDir } else { '' }
if ($gitRoot) {
    $branch = (git -C $gitRoot --no-optional-locks symbolic-ref --short HEAD 2>$null)
    if (-not $branch) {
        $sha = (git -C $gitRoot --no-optional-locks rev-parse --short HEAD 2>$null)
        if ($sha) { $branch = "detached:$sha" }
    }
    $staged    = @(git -C $gitRoot --no-optional-locks diff --cached --name-only 2>$null).Count
    $modified  = @(git -C $gitRoot --no-optional-locks diff --name-only 2>$null).Count
    $untracked = @(git -C $gitRoot --no-optional-locks ls-files --others --exclude-standard 2>$null).Count
}

# ═══════════════ LINHA 1: modelo · git · dir · versão ═══════════════
$l1 = ' ' + (P $Purple $model 'bold')
if ($branch) {
    $l1 += $SEP + (P $Yellow ("$([char]0x2387) $branch"))
    if ($staged -gt 0)    { $l1 += ' ' + (P $Green   "+$staged") }
    if ($modified -gt 0)  { $l1 += ' ' + (P $Orange  "~$modified") }
    if ($untracked -gt 0) { $l1 += ' ' + (P $Comment "?$untracked") }
}
$l1 += $SEP + (P $Cyan $dir)
if ($version) { $l1 += $SEP + (P $Comment "v$version") }

# ═══════════════ LINHA 2: barra ctx · % · tokens · tempo · custo ═══════════════
$barWidth = 14
$filled = [int]([math]::Round($barWidth * $usedInt / 100))
if ($filled -lt 0) { $filled = 0 } elseif ($filled -gt $barWidth) { $filled = $barWidth }
$barColor =
    if ($usedInt -ge 80) { $Red } elseif ($usedInt -ge 60) { $Orange }
    elseif ($usedInt -ge 40) { $Yellow } else { $Green }
# Barra sólida: bloco cheio █ em tudo; cor viva no preenchido, cinza discreto no vazio.
$bar = ''
for ($i = 0; $i -lt $barWidth; $i++) {
    if ($i -lt $filled) { $bar += (P $barColor ([char]0x2588)) }
    else { $bar += (P $Track ([char]0x2588)) }
}

$pctStr = if ($ctxKnown) { (P $barColor "$usedInt%") } else { (P $Comment '--') }
$l2 = ' ' + $bar + ' ' + $pctStr + ' ' + (P $Comment ("$(Fmt-Tokens $ctxTokens)/$(Fmt-Size $ctxSize)"))
$l2 += $SEP + (P $Purple ("$([char]0x23F1) $(Fmt-Duration $durMs)"))
if ($totTokens -gt 0) { $l2 += $SEP + (P $Cyan ("tok $(Fmt-Tokens $totTokens)")) }
$l2 += $SEP + (P $Green ([string]::Format($inv, '${0:0.00}', $cost)))

[Console]::Out.Write($l1 + "`n" + $l2)

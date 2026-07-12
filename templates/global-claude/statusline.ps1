# statusline.ps1 — HUD do Claude Code (2 linhas).
# Recebe o JSON de status no stdin e imprime a linha de status.
# Invocado via:  pwsh -NoProfile -File ~/.claude/statusline.ps1
# Doc do schema: https://code.claude.com/docs/en/statusline
# Sem StrictMode de propósito: acesso a campo ausente retorna $null (resiliente).
#
# Temas (role-based): primary/accent/success/warning/caution/danger/muted/track.
#   Seleção, em ordem de precedência:
#     1) ~/.claude/statusline.theme   2) $env:SDD_STATUSLINE_THEME   3) 'dracula' (default)
#   O arquivo .theme aceita linhas:  theme = <nome>  |  <role> = R,G,B  |  th_low|th_mid|th_high = N
#   Ver exemplo comentado em ~/.claude/statusline.theme.example.
# Guard de harness: sem o schema do Claude Code no stdin, sai silencioso (exit 0) — assim o
#   comando não polui a status line de outra harness que porventura reutilize este settings.

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}

# --- lê o JSON do stdin ---------------------------------------------------
$raw  = [Console]::In.ReadToEnd()
$data = if ($raw) { try { $raw | ConvertFrom-Json } catch { $null } } else { $null }

# --- guard de harness -----------------------------------------------------
# Só renderiza p/ o schema do statusline do Claude Code. Se nenhum campo-chave existe, o stdin
# não é do CC (vazio, outra harness, invocação manual): sai mudo em vez de imprimir uma linha torta.
$isClaudeCode = $data -and (
    $data.PSObject.Properties['model'] -or
    $data.PSObject.Properties['workspace'] -or
    $data.PSObject.Properties['context_window']
)
if (-not $isClaudeCode) { exit 0 }

# --- temas (role-based) ---------------------------------------------------
$Themes = @{
    dracula = @{
        primary = @(189, 147, 249); accent  = @(139, 233, 253); success = @(80, 250, 123)
        warning = @(241, 250, 140); caution = @(255, 184, 108); danger  = @(255, 85, 85)
        muted   = @(98, 114, 164);  track   = @(68, 71, 90)
        th_low  = 40; th_mid = 60; th_high = 80
    }
    onedark = @{
        primary = @(198, 120, 221); accent  = @(86, 182, 194); success = @(152, 195, 121)
        warning = @(229, 192, 123); caution = @(209, 154, 102); danger  = @(224, 108, 117)
        muted   = @(92, 99, 112);   track   = @(60, 64, 72)
        th_low  = 40; th_mid = 60; th_high = 80
    }
    catppuccin = @{  # Mocha
        primary = @(203, 166, 247); accent  = @(137, 220, 235); success = @(166, 227, 161)
        warning = @(249, 226, 175); caution = @(250, 179, 135); danger  = @(243, 139, 168)
        muted   = @(108, 112, 134); track   = @(69, 71, 90)
        th_low  = 40; th_mid = 60; th_high = 80
    }
}

function Resolve-Theme {
    # Default → env → arquivo (o mais específico vence; overrides de role/threshold acumulam).
    $themeName = if ($env:SDD_STATUSLINE_THEME) { $env:SDD_STATUSLINE_THEME.Trim().ToLower() } else { 'dracula' }
    $overrides = @{}
    $roleKeys  = @('primary', 'accent', 'success', 'warning', 'caution', 'danger', 'muted', 'track')
    $thKeys    = @('th_low', 'th_mid', 'th_high')
    $themeFile = Join-Path $HOME '.claude/statusline.theme'
    if (Test-Path -LiteralPath $themeFile) {
        foreach ($line in (Get-Content -LiteralPath $themeFile)) {
            $t = "$line".Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            $kv = $t -split '=', 2
            if ($kv.Count -ne 2) { continue }
            $k = $kv[0].Trim().ToLower(); $v = $kv[1].Trim()
            if ($k -eq 'theme') { $themeName = $v.ToLower(); continue }
            if (($thKeys -contains $k) -and ($v -match '^\d+$')) { $overrides[$k] = [int]$v; continue }
            if (($roleKeys -contains $k) -and ($v -match '^\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*$')) {
                $overrides[$k] = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
            }
        }
    }
    $base = if ($Themes.ContainsKey($themeName)) { $Themes[$themeName] } else { $Themes['dracula'] }
    $theme = @{}
    foreach ($k in $base.Keys) { $theme[$k] = $base[$k] }
    foreach ($k in $overrides.Keys) { $theme[$k] = $overrides[$k] }
    return $theme
}
$T = Resolve-Theme

# --- pintura --------------------------------------------------------------
# Modo de cor, por precedência:
#   NO_COLOR (no-color.org) → 'off'  |  $env:SDD_STATUSLINE_COLOR (off|256|truecolor)  |
#   COLORTERM=truecolor/24bit → 'truecolor'  |  default 'truecolor' (preserva o comportamento atual).
# 256 é opt-in de propósito: não caímos p/ 256 só por COLORTERM ausente (regrediria terminais
# que suportam truecolor sem anunciar via COLORTERM — a maioria). Use 256 em tmux sem RGB capability.
function Resolve-ColorMode {
    if (-not [string]::IsNullOrEmpty($env:NO_COLOR)) { return 'off' }
    $c = "$env:SDD_STATUSLINE_COLOR".Trim().ToLower()
    if ($c -in @('off', 'none', '0'))          { return 'off' }
    if ($c -in @('256', '8bit', 'ansi256'))    { return '256' }
    if ($c -in @('truecolor', '24bit', 'rgb')) { return 'truecolor' }
    if ("$env:COLORTERM".Trim().ToLower() -in @('truecolor', '24bit')) { return 'truecolor' }
    return 'truecolor'
}
$ColorMode = Resolve-ColorMode
$ESC = [char]27
function ConvertTo-Ansi256([int]$r, [int]$g, [int]$b) {
    # RGB → índice xterm-256 (cubo 6×6×6 + rampa de cinzas), p/ tmux sem truecolor.
    if ($r -eq $g -and $g -eq $b) {
        if ($r -lt 8)   { return 16 }
        if ($r -gt 248) { return 231 }
        return [int][math]::Round(($r - 8) / 247.0 * 24) + 232
    }
    $ri = [int][math]::Round($r / 255.0 * 5)
    $gi = [int][math]::Round($g / 255.0 * 5)
    $bi = [int][math]::Round($b / 255.0 * 5)
    return 16 + 36 * $ri + 6 * $gi + $bi
}
function Paint([int]$r, [int]$g, [int]$b, [string]$t, [string]$mode = '') {
    if ($ColorMode -eq 'off') { return $t }
    $pre = switch ($mode) { 'bold' { '1;' } 'dim' { '2;' } default { '' } }
    if ($ColorMode -eq '256') {
        $c = ConvertTo-Ansi256 $r $g $b
        return "$ESC[${pre}38;5;${c}m$t$ESC[0m"
    }
    return "$ESC[${pre}38;2;$r;$g;${b}m$t$ESC[0m"
}
function P($c, $t, $m = '') { Paint $c[0] $c[1] $c[2] $t $m }
function Get-LevelColor([double]$p) {
    if ($p -ge $T.th_high) { return $T.danger }
    if ($p -ge $T.th_mid)  { return $T.caution }
    if ($p -ge $T.th_low)  { return $T.warning }
    return $T.success
}
$SEP = (P $T.muted '  ·  ')

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
function Get-MiniBar([double]$pct) {
    # micro-barra de 4 blocos p/ uma janela de rate limit; ▰ preenchido (cor da faixa), ▱ vazio (track).
    $w = 4; $f = [int][math]::Round($w * $pct / 100)
    if ($f -lt 0) { $f = 0 } elseif ($f -gt $w) { $f = $w }
    $col = Get-LevelColor $pct
    $s = ''
    for ($i = 0; $i -lt $w; $i++) {
        if ($i -lt $f) { $s += (P $col ([char]0x25B0)) } else { $s += (P $T.track ([char]0x25B1)) }
    }
    return $s
}
function Fmt-Reset([int]$sec) {
    # segundos até o reset, unidade única resumida: >=1d → "2d", >=1h → "2h", senão "20m".
    if ($sec -lt 0) { $sec = 0 }
    if ($sec -ge 86400) { return "$([int]($sec / 86400))d" }
    if ($sec -ge 3600)  { return "$([int]($sec / 3600))h" }
    return "$([int]($sec / 60))m"
}
function Format-RateWindow([string]$label, [double]$pct, $resetEpoch, [bool]$withReset) {
    # etiqueta em accent fixo (o que é) + mini-barra + valor colorido (quanto está); reset só se pedido.
    $seg = (P $T.accent $label 'bold') + ' ' + (Get-MiniBar $pct) + ' ' + (P (Get-LevelColor $pct) ("$([int][math]::Round($pct))%"))
    if ($withReset -and $resetEpoch) {
        $delta = [int]([double]$resetEpoch - $nowEpoch)
        if ($delta -gt 0) { $seg += ' ' + (P $T.muted (Fmt-Reset $delta)) }
    }
    return $seg
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

$cost   = [double]($data.cost.total_cost_usd); if (-not $cost) { $cost = 0 }
$durMs  = [double]($data.cost.total_duration_ms); if (-not $durMs) { $durMs = 0 }

# rate limits: só p/ assinantes Claude.ai (Pro/Max), após a 1ª resposta; cada janela pode faltar.
$rl = $data.rate_limits
$rate5 = if ($rl -and $null -ne $rl.five_hour.used_percentage) { [double]$rl.five_hour.used_percentage } else { $null }
$rate7 = if ($rl -and $null -ne $rl.seven_day.used_percentage) { [double]$rl.seven_day.used_percentage } else { $null }
$reset5 = if ($rl -and $rl.five_hour.resets_at) { [double]$rl.five_hour.resets_at } else { $null }
$reset7 = if ($rl -and $rl.seven_day.resets_at) { [double]$rl.seven_day.resets_at } else { $null }
$nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

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
$l1 = ' ' + (P $T.primary $model 'bold')
if ($branch) {
    $l1 += $SEP + (P $T.warning ("$([char]0x2387) $branch"))
    if ($staged -gt 0)    { $l1 += ' ' + (P $T.success "+$staged") }
    if ($modified -gt 0)  { $l1 += ' ' + (P $T.caution "~$modified") }
    if ($untracked -gt 0) { $l1 += ' ' + (P $T.muted   "?$untracked") }
}
$l1 += $SEP + (P $T.accent $dir)
if ($version) { $l1 += $SEP + (P $T.muted "v$version") }

# ═══════════════ LINHA 2: barra ctx · % · tokens · rates · tempo · custo ═══════════════
$barWidth = 14
$filled = [int]([math]::Round($barWidth * $usedInt / 100))
if ($filled -lt 0) { $filled = 0 } elseif ($filled -gt $barWidth) { $filled = $barWidth }
$barColor = Get-LevelColor $usedInt
# Barra: bloco cheio █ no preenchido. No vazio, cor track (█) quando há cor; sem cor (NO_COLOR),
# usa ░ p/ o vazio ainda ser distinguível do preenchido sem depender da cor.
$emptyCh = if ($ColorMode -eq 'off') { [char]0x2591 } else { [char]0x2588 }
$bar = ''
for ($i = 0; $i -lt $barWidth; $i++) {
    if ($i -lt $filled) { $bar += (P $barColor ([char]0x2588)) }
    else { $bar += (P $T.track $emptyCh) }
}

$pctStr = if ($ctxKnown) { (P $barColor "$usedInt%") } else { (P $T.muted '--') }
$l2 = ' ' + $bar + ' ' + $pctStr + ' ' + (P $T.muted ("$(Fmt-Tokens $ctxTokens)/$(Fmt-Size $ctxSize)"))

# rates: mini-barra + % por janela (5h/7d); reset ⟳ só na de MAIOR uso (a que aperta). Degrada se ausente.
$rateStr = ''
$dom5 = ($null -ne $rate5) -and (($null -eq $rate7) -or ($rate5 -ge $rate7))
if ($null -ne $rate5) { $rateStr += (Format-RateWindow '5h' $rate5 $reset5 $dom5) }
if ($null -ne $rate7) {
    if ($rateStr) { $rateStr += (P $T.muted ' · ') }
    $rateStr += (Format-RateWindow '7d' $rate7 $reset7 (-not $dom5))
}
if ($rateStr) { $l2 += $SEP + $rateStr }

$l2 += $SEP + (P $T.primary ("$([char]0x23F1) $(Fmt-Duration $durMs)"))
if ($cost -gt 0) { $l2 += $SEP + (P $T.success ([string]::Format($inv, '${0:0.00}', $cost))) }

[Console]::Out.Write($l1 + "`n" + $l2)

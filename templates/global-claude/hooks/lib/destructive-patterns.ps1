<#
.SYNOPSIS
    Fonte ÚNICA dos detectores de comando destrutivo (lib compartilhada) — J5.

.DESCRIPTION
    Funções PURAS, dot-sourceáveis e testáveis. É a fonte de verdade consumida pelo
    hook `destructive-guard.ps1` (PreToolUse, modo "ask"). Espelhada em
    `lib/destructive-patterns.sh` (paridade travada por tools/tests/destructive-guard.Tests.ps1).

    NÃO tem efeitos colaterais ao carregar (só define funções). Sem prompts, sem I/O, sem git/rede.

    Filosofia: a postura é **ask** (educar, não barrar) — o `deny` inviolável vive na managed
    policy (C3). A decisão é por **tokenização** (não expande nem roda o shell): o lado seguro,
    na dúvida, é sempre **pass** (silêncio). FN exótico é aceitável (≤ ao estado atual sob `auto`).

    Compatível com PowerShell 7+.
#>

Set-StrictMode -Version Latest

# --- PURA: divide o comando em segmentos por separadores de shell ------------------------------
function Split-CommandSegment {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return @() }
    return [regex]::Split($Command, '&&|\|\||;|\r?\n|\|')
}

# --- PURA: o segmento é um `rm` recursivo E force? (flags normalizadas, ordem livre) -----------
function Test-IsDestructiveRm {
    param([string]$Segment)
    if ([string]::IsNullOrWhiteSpace($Segment)) { return $false }
    if ($Segment -notmatch '(?:^|\s)(?:sudo\s+)?rm(?:\s|$)') { return $false }
    $hasRec = $false; $hasForce = $false
    foreach ($tok in ($Segment -split '\s+')) {
        if ($tok -eq '--recursive') { $hasRec = $true; continue }
        if ($tok -eq '--force') { $hasForce = $true; continue }
        if ($tok -match '^-[A-Za-z]+$') {        # cluster curto: -rf, -fr, -Rf, -r, -f…
            $cluster = $tok.Substring(1)
            if ($cluster -match '[rR]') { $hasRec = $true }
            if ($cluster -match 'f') { $hasForce = $true }
        }
    }
    return ($hasRec -and $hasForce)
}

# --- PURA: alvos (tokens não-flag) de um segmento `rm` -----------------------------------------
function Get-RmTarget {
    param([string]$Segment)
    $targets = @()
    $seen = $false
    foreach ($tok in ($Segment -split '\s+')) {
        if ($tok -eq '') { continue }
        if (-not $seen) {
            if ($tok -eq 'rm') { $seen = $true }
            continue
        }
        if ($tok.StartsWith('-')) { continue }   # flag
        $targets += $tok
    }
    return , $targets
}

# --- PURA: o alvo é "arriscado"? (absoluto / home / var não-expandida / glob amplo) ------------
function Test-IsRiskyTarget {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    $t = $Token.Trim().Trim('"', "'")
    if ($t -eq '') { return $false }
    if ($t -match '\$') { return $true }          # var não-expandida ($DIR, ${HOME})
    if ($t.StartsWith('~')) { return $true }      # home (~ , ~/x)
    if ($t.StartsWith('/')) { return $true }      # absoluto (/ , /etc , /* )
    if ($t.StartsWith('*')) { return $true }      # glob amplo (* , */ , *.bak)
    if ($t -eq '.*') { return $true }             # glob .*
    return $false                                 # relativo-sob-cwd: ./build, build, node_modules, ../x
}

# --- PURA: o segmento é um `chmod` recursivo com modo perigoso? --------------------------------
function Test-IsRiskyChmod {
    param([string]$Segment)
    if ([string]::IsNullOrWhiteSpace($Segment)) { return $false }
    if ($Segment -notmatch '(?:^|\s)(?:sudo\s+)?chmod(?:\s|$)') { return $false }
    $hasRec = $false; $hasMode = $false
    foreach ($tok in ($Segment -split '\s+')) {
        if ($tok -eq '--recursive' -or $tok -match '^-[A-Za-z]*R[A-Za-z]*$') { $hasRec = $true }
        if ($tok -match '^(?:777|666|000)$' -or $tok -eq 'a+rwx') { $hasMode = $true }
    }
    return ($hasRec -and $hasMode)
}

# --- PURA: o comando baixa um script e o executa direto no shell? (no comando bruto) ----------
function Test-IsDownloadToShell {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    return ($Command -match '(?i)\b(?:curl|wget|fetch)\b[^|]*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|ksh|dash|pwsh|powershell|python[0-9.]*|perl|ruby|node)\b')
}

# --- PURA: comando -> decisão { Decision = 'ask'|'pass'; Reason } ------------------------------
function Get-DestructiveDecision {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) {
        return [pscustomobject]@{ Decision = 'pass'; Reason = '' }
    }
    # 1) download-to-shell roda no comando bruto (antes do split, que quebraria `curl x | sh`).
    if (Test-IsDownloadToShell $Command) {
        return [pscustomobject]@{ Decision = 'ask'
            Reason = 'Download de script executado direto no shell (curl/wget | sh). Confirmacao exigida.'
        }
    }
    foreach ($seg in (Split-CommandSegment $Command)) {
        if (Test-IsDestructiveRm $seg) {
            $risky = @(Get-RmTarget $seg | Where-Object { Test-IsRiskyTarget $_ })
            if ($risky.Count -gt 0) {
                return [pscustomobject]@{ Decision = 'ask'
                    Reason = "Comando destrutivo (rm recursivo de alvo arriscado): $($risky -join ', '). Confirmacao exigida."
                }
            }
        }
        if (Test-IsRiskyChmod $seg) {
            return [pscustomobject]@{ Decision = 'ask'
                Reason = 'Permissao recursiva perigosa (chmod -R 777/666/000). Confirmacao exigida.'
            }
        }
    }
    return [pscustomobject]@{ Decision = 'pass'; Reason = '' }
}

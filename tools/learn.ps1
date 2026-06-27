<#
.SYNOPSIS
    learn (G7) — parte determinística do /learn: inventário de lições candidatas no acervo de
    SHIPPED, gatilho (candidatas não-promovidas ≥ limiar) + verificação de proveniência da
    promoção à KB (promoted_from).

.DESCRIPTION
    Funções PURAS (read-only), dot-sourceáveis e testáveis. **Reusa o B7** (dot-source de
    `kb-lint.ps1`): `Get-KbInventory`/`Test-KbFrontmatter` — para achar as entradas KB e conferir
    conformidade da entrada promovida. O JULGAMENTO (qual lição é recorrente; a qualidade da
    promoção) é runtime do LLM; aqui mora só o que é objetivo:
      - GATILHO     : Test-LessonsReady — nº de lições [candidata] do acervo cujo `feature` ainda
                      NÃO consta em nenhum `promoted_from` da KB ≥ limiar. Reusado pelo
                      curation-nudge (J3). Idempotente: já-promovida (feature ∈ promoted_from)
                      não conta.
      - PÓS-CONDIÇÃO: Test-LessonProvenance — toda entrada KB que declara `promoted_from` aponta
                      ≥1 feature EXISTENTE no acervo `archive/` (nada promovido sem origem).

    A marca no SHIPPED é uma tag inline nos bullets da seção "## Lições aprendidas":
    `- **[candidata]** ...` (promovível) / `- **[pontual]** ...` (one-off). Retrocompat: bullets
    sem tag são ignorados.

    Compatível com PowerShell 7+. Ver DESIGN_LEARN.md (G7).
#>

Set-StrictMode -Version Latest

# Reusa o B7 (inventário/validação da KB). kb-lint.ps1 só define funções + $script: (sem side-effects).
$script:LearnKbLintPath = Join-Path $PSScriptRoot 'kb-lint.ps1'
if (-not (Test-Path -LiteralPath $script:LearnKbLintPath -PathType Leaf)) {
    throw "learn.ps1 requer tools/kb-lint.ps1 (não encontrado em $script:LearnKbLintPath)."
}
. $script:LearnKbLintPath

# Limiar de candidatas NÃO-promovidas que dispara o /learn. Ponto único e afinável (espelha o
# padrão de $script:KbReflectMinOverBudget do G6). Generoso: promover custa (fan-out + curadoria).
$script:LearnMinCandidates = 3

# --- PURA: parse de lista YAML inline (`[a, b]`) -> string[] (molde ConvertFrom-KbInlineList) ---
function ConvertFrom-LearnInlineList {
    [CmdletBinding()]
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    $t = $Raw.Trim()
    if ($t -eq '[]') { return @() }
    if ($t.StartsWith('[') -and $t.EndsWith(']')) {
        $inner = $t.Substring(1, $t.Length - 2)
        return @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
    }
    return @($t.Trim('"', "'"))   # escalar único
}

# --- PURA: lições [candidata] do acervo de SHIPPED -------------------------------------------
function Get-LessonInventory {
    <#
    .SYNOPSIS
        Varre <ArchiveDir>/**/SHIPPED_*.md; na seção '## Lições aprendidas' extrai os bullets
        marcados [candidata]. Feature = pasta archive/<feature>/; Source = path do SHIPPED.
        Ignora [pontual] e bullets sem tag (retrocompat).
    .OUTPUTS
        [pscustomobject[]] @{ Feature; Source; Lesson; Kind='candidata' }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchiveDir)

    if (-not (Test-Path -LiteralPath $ArchiveDir -PathType Container)) { return @() }

    $rxLessonHeading = '^\s*##\s+Lições aprendidas\s*$'
    $rxOtherHeading  = '^\s*##\s+'
    $rxCandidate     = '^\s*-\s*(?:\*\*)?\[candidata\](?:\*\*)?\s*(.+?)\s*$'

    $results = @()
    $files = @(Get-ChildItem -LiteralPath $ArchiveDir -Filter 'SHIPPED_*.md' -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $feature = Split-Path -Leaf (Split-Path -Parent $f.FullName)
        $lines = @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)
        $inLessons = $false
        foreach ($line in $lines) {
            if ($line -match $rxLessonHeading) { $inLessons = $true; continue }
            if ($inLessons -and ($line -match $rxOtherHeading)) { $inLessons = $false; continue }
            if ($inLessons -and ($line -match $rxCandidate)) {
                $results += [pscustomobject]@{
                    Feature = $feature
                    Source  = $f.FullName
                    Lesson  = $Matches[1].Trim()
                    Kind    = 'candidata'
                }
            }
        }
    }
    return @($results)
}

# --- PURA: lê id + promoted_from do frontmatter (inline OU multilinha) -------------------------
function Read-KbPromotedFrom {
    <#
    .OUTPUTS [pscustomobject] @{ Id; PromotedFrom=[string[]]; HasPromotedFrom=[bool] }
        HasPromotedFrom distingue "chave ausente" (entrada KB comum) de "chave presente porém
        vazia" (entrada promovida sem origem → finding).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $empty = [pscustomobject]@{ Id = $null; PromotedFrom = @(); HasPromotedFrom = $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $empty }
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($lines.Count -lt 2 -or $lines[0].Trim() -ne '---') { return $empty }

    $id = $null
    $promoted = @()
    $hasKey = $false
    $currentKey = $null
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim() -eq '---') { break }                 # fim do frontmatter
        if ($line -match '^\s*-\s+(.+)$') {                    # item de array multilinha
            $val = $Matches[1].Trim().Trim('"', "'")
            if ($val -and $currentKey -eq 'promoted_from') { $promoted += $val }
            continue
        }
        $idx = $line.IndexOf(':')
        if ($idx -lt 1) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        $currentKey = $key
        switch ($key) {
            'id'            { $id = $val.Trim('"', "'") }
            'promoted_from' { $hasKey = $true; $promoted += (ConvertFrom-LearnInlineList $val) }
        }
    }
    return [pscustomobject]@{
        Id              = $id
        PromotedFrom    = @($promoted | Where-Object { $_ })
        HasPromotedFrom = $hasKey
    }
}

# --- PURA: features já promovidas (união dos promoted_from da KB) ------------------------------
function Get-PromotedFeatures {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$KbDir)
    if (-not (Test-Path -LiteralPath $KbDir -PathType Container)) { return @() }
    $promoted = @()
    foreach ($e in @(Get-KbInventory -Dir $KbDir)) {
        $p = Read-KbPromotedFrom -Path $e.Path
        foreach ($f in @($p.PromotedFrom)) { if ($f) { $promoted += $f } }
    }
    return @($promoted | Select-Object -Unique)
}

# --- PURA: o acervo tem candidatas não-promovidas suficientes p/ disparar? ---------------------
function Test-LessonsReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchiveDir,
        [Parameter(Mandatory)][string]$KbDir
    )

    $candidates = @(Get-LessonInventory -ArchiveDir $ArchiveDir)
    $promoted   = @(Get-PromotedFeatures -KbDir $KbDir)
    $pending    = @($candidates | Where-Object { $promoted -notcontains $_.Feature })
    $threshold  = $script:LearnMinCandidates
    $ready      = $pending.Count -ge $threshold

    $reason = if ($ready) {
        "$($pending.Count) lição(ões) candidata(s) não-promovida(s) >= limiar $threshold"
    }
    else {
        "$($pending.Count) candidata(s) pendente(s) < limiar $threshold (nada a promover)"
    }

    return [pscustomobject]@{
        Candidates       = $candidates
        PromotedFeatures = $promoted
        PendingCount     = $pending.Count
        Threshold        = $threshold
        Ready            = $ready
        Reason           = $reason
    }
}

# --- PURA: toda entrada promovida tem origem rastreável no acervo? -----------------------------
function Test-LessonProvenance {
    <#
    .SYNOPSIS
        Para cada entrada KB que DECLARA promoted_from: a chave deve listar ≥1 feature EXISTENTE
        (pasta em archive/). Vazia ou apontando feature inexistente -> finding. Entrada SEM a
        chave = entrada KB comum (não promovida) -> ignorada.
    .OUTPUTS [pscustomobject[]] findings (vazio = tudo rastreável)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$KbDir,
        [Parameter(Mandatory)][string]$ArchiveDir
    )

    $features = @()
    if (Test-Path -LiteralPath $ArchiveDir -PathType Container) {
        $features = @(Get-ChildItem -LiteralPath $ArchiveDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }

    $findings = @()
    if (-not (Test-Path -LiteralPath $KbDir -PathType Container)) { return $findings }

    foreach ($e in @(Get-KbInventory -Dir $KbDir)) {
        $p = Read-KbPromotedFrom -Path $e.Path
        if (-not $p.HasPromotedFrom) { continue }            # entrada comum, não promovida

        $sources = @($p.PromotedFrom)
        $missing = @($sources | Where-Object { $features -notcontains $_ })
        if ($sources.Count -eq 0) {
            $findings += [pscustomobject]@{
                Severity = 'error'
                Rule     = 'lesson-without-source'
                Id       = $p.Id
                Message  = "entrada '$($p.Id)' tem promoted_from vazio (promoção sem origem rastreável)."
            }
        }
        elseif ($missing.Count -gt 0) {
            $findings += [pscustomobject]@{
                Severity = 'error'
                Rule     = 'lesson-without-source'
                Id       = $p.Id
                Message  = "entrada '$($p.Id)' referencia feature(s) inexistente(s) em archive/: $($missing -join ', ')."
            }
        }
    }
    return @($findings)
}

# --- PURA: relatório legível (mesmo estilo dos demais lints) ----------------------------------
function Format-LearnReport {
    [CmdletBinding()]
    param(
        [pscustomobject]$Status,
        [AllowEmptyCollection()][object[]]$Findings = @()
    )
    $lines = @()
    if ($Status) {
        $state = if ($Status.Ready) { 'PRONTO' } else { 'sob limiar' }
        $lines += "learn: $state — candidatas pendentes=$($Status.PendingCount)/$($Status.Threshold); já-promovidas=$(@($Status.PromotedFeatures).Count)"
        if ($Status.Reason) { $lines += "  gatilho: $($Status.Reason)" }
    }
    if ($Findings -and $Findings.Count -gt 0) {
        foreach ($f in $Findings) { $lines += ('[{0}] {1} — {2}' -f $f.Severity.ToUpper(), $f.Rule, $f.Message) }
    }
    else {
        $lines += 'proveniência: OK (nenhuma entrada promovida sem origem).'
    }
    return ($lines -join "`n")
}

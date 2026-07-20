<#
.SYNOPSIS
    reflect (G6) — parte determinística do /reflect: gatilho de budget agregado + verificação
    id-provenance da consolidação da KB.

.DESCRIPTION
    Funções PURAS (read-only), dot-sourceáveis e testáveis. **Reusa o B7** (dot-source de
    `kb-lint.ps1`): `Get-KbInventory`/`Measure-KbContentSize`/`Read-KbBody`/`Test-KbEntrySize` —
    não reimplementa medição. O JULGAMENTO (o que fundir/podar/resumir) é runtime do LLM; aqui
    mora só o que é objetivo:
      - GATILHO     : Test-KbOverBudget — KB acima do budget agregado (tamanho total OU nº de
                      entradas individualmente estouradas). Reusado pelo curation-nudge (J3).
      - PÓS-CONDIÇÃO: Test-ReflectProvenance — todo `id` removido pela consolidação aparece num
                      `consolidates`/`supersedes` de entrada sobrevivente (nada some sem rastro).

    Só considera entradas KB **válidas** (frontmatter ok) — exclui auxiliares e o ledger
    `_reflections/` (que não têm frontmatter de entrada).

    Compatível com PowerShell 7+. Ver DESIGN_REFLECT_KB.md (G6).
#>

Set-StrictMode -Version Latest

# Reusa o B7 (medição da KB). kb-lint.ps1 só define funções + $script: de budget (sem side-effects).
$script:ReflectKbLintPath = Join-Path $PSScriptRoot 'kb-lint.ps1'
if (-not (Test-Path -LiteralPath $script:ReflectKbLintPath -PathType Leaf)) {
    throw "reflect.ps1 requer tools/kb-lint.ps1 (não encontrado em $script:ReflectKbLintPath)."
}
. $script:ReflectKbLintPath

# Budget AGREGADO da KB (chars do corpo, exclui code fences). Ponto único e afinável — espelha o
# padrão de $script:KbSizeBudget do B7. Generoso de propósito (dispara só quando a KB cresce mesmo).
$script:KbAggregateBudget   = 120000   # ~30.000 tokens de corpo somado
$script:KbReflectMinOverBudget = 5     # nº de entradas individualmente OverBudget que também dispara

# --- PURA: tamanho agregado do corpo das entradas VÁLIDAS (exclui code fences, via B7) ---------
function Get-KbAggregateSize {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 0 }
    $total = 0
    foreach ($e in @(Get-KbInventory -Dir $Dir | Where-Object { $_.Valid })) {
        $total += Measure-KbContentSize -BodyLines (Read-KbBody -Path $e.Path)
    }
    return $total
}

# --- PURA: budget agregado configurado --------------------------------------------------------
function Get-KbAggregateBudget {
    [CmdletBinding()]
    param()
    return $script:KbAggregateBudget
}

# --- PURA: a KB cruzou o budget agregado? (tamanho total OU nº de entradas estouradas) ---------
function Test-KbOverBudget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)

    $aggSize   = Get-KbAggregateSize -Dir $Dir
    $aggBudget = Get-KbAggregateBudget
    $overEntries = 0
    if (Test-Path -LiteralPath $Dir -PathType Container) {
        foreach ($e in @(Get-KbInventory -Dir $Dir | Where-Object { $_.Valid })) {
            $sz = Test-KbEntrySize -Path $e.Path
            if ($sz.OverBudget) { $overEntries++ }
        }
    }

    $bySize  = $aggSize -gt $aggBudget
    $byCount = $overEntries -ge $script:KbReflectMinOverBudget
    $over = $bySize -or $byCount
    $reason = ''
    if ($bySize) { $reason = "tamanho agregado $aggSize > budget $aggBudget" }
    elseif ($byCount) { $reason = "$overEntries entradas acima do budget individual (limiar $($script:KbReflectMinOverBudget))" }

    return [pscustomobject]@{
        AggregateSize     = $aggSize
        AggregateBudget   = $aggBudget
        OverBudgetEntries = $overEntries
        MinOverBudget     = $script:KbReflectMinOverBudget
        OverBudget        = $over
        Reason            = $reason
    }
}

# --- PURA: parse de lista YAML inline (`[a, b]`) -> string[] -----------------------------------
function ConvertFrom-KbInlineList {
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

# --- PURA: lê id + proveniência (consolidates/supersedes) do frontmatter (inline OU multilinha) -
function Read-KbProvenance {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $empty = [pscustomobject]@{ Id = $null; Consolidates = @(); Supersedes = @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $empty }
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($lines.Count -lt 2 -or $lines[0].Trim() -ne '---') { return $empty }

    $id = $null
    $consolidates = @()
    $supersedes = @()
    $currentKey = $null
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim() -eq '---') { break }                 # fim do frontmatter
        if ($line -match '^\s*-\s+(.+)$') {                    # item de array multilinha
            $val = $Matches[1].Trim().Trim('"', "'")
            if ($val) {
                if ($currentKey -eq 'consolidates') { $consolidates += $val }
                elseif ($currentKey -eq 'supersedes') { $supersedes += $val }
            }
            continue
        }
        $idx = $line.IndexOf(':')
        if ($idx -lt 1) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        $currentKey = $key
        switch ($key) {
            'id'           { $id = $val.Trim('"', "'") }
            'consolidates' { $consolidates += (ConvertFrom-KbInlineList $val) }
            'supersedes'   { $supersedes += (ConvertFrom-KbInlineList $val) }
        }
    }
    return [pscustomobject]@{
        Id           = $id
        Consolidates = @($consolidates | Where-Object { $_ })
        Supersedes   = @($supersedes | Where-Object { $_ })
    }
}

# --- PURA: todo id removido tem rastro? (removidos ⊆ referenciados nas sobreviventes) ----------
function Test-ReflectProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$BeforeIds,
        [Parameter(Mandatory)][string]$Dir
    )

    $entries = @()
    if (Test-Path -LiteralPath $Dir -PathType Container) {
        $entries = @(Get-KbInventory -Dir $Dir | Where-Object { $_.Id })
    }

    $surviving = [System.Collections.Generic.HashSet[string]]::new()
    $referenced = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($e in $entries) {
        [void]$surviving.Add([string]$e.Id)
        $prov = Read-KbProvenance -Path $e.Path
        foreach ($r in (@($prov.Consolidates) + @($prov.Supersedes))) {
            if ($r) { [void]$referenced.Add([string]$r) }
        }
    }

    $findings = @()
    foreach ($id in $BeforeIds) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if ($surviving.Contains($id)) { continue }            # ainda existe -> ok
        if (-not $referenced.Contains($id)) {
            $findings += [pscustomobject]@{
                Severity = 'error'
                Rule     = 'id-lost-without-trace'
                Id       = $id
                Message  = "id '$id' foi removido sem rastro (ausente de consolidates/supersedes das entradas sobreviventes)."
            }
        }
    }
    return @($findings)
}

# --- PURA: relatório legível (mesmo estilo dos demais lints) ----------------------------------
function Format-ReflectReport {
    [CmdletBinding()]
    param(
        [pscustomobject]$Budget,
        [AllowEmptyCollection()][object[]]$Findings = @()
    )
    $lines = @()
    if ($Budget) {
        $state = if ($Budget.OverBudget) { 'ACIMA do budget' } else { 'sob budget' }
        $lines += "reflect: KB $state — agregado=$($Budget.AggregateSize)/$($Budget.AggregateBudget); entradas estouradas=$($Budget.OverBudgetEntries)/$($Budget.MinOverBudget)"
        if ($Budget.OverBudget -and $Budget.Reason) { $lines += "  gatilho: $($Budget.Reason)" }
    }
    if ($Findings -and $Findings.Count -gt 0) {
        foreach ($f in $Findings) { $lines += ('[{0}] {1} — {2}' -f $f.Severity.ToUpper(), $f.Rule, $f.Message) }
    }
    else {
        $lines += 'id-provenance: OK (nenhuma entrada removida sem rastro).'
    }
    return ($lines -join "`n")
}

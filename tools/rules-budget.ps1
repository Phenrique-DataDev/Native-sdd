<#
.SYNOPSIS
    Orçamento ADVISORY do contexto always-on: mede o footprint (chars→tokens) das rules sempre-ativas
    (.claude/rules/*.md) + os arquivos-âncora (CLAUDE.md / AGENTS.md), sinaliza outlier por-arquivo e
    drift agregado — mas NUNCA bloqueia (exit 0 sempre). Espelha a filosofia "educar ≠ barrar" do B7
    (kb.char_limit). Ver DESIGN_CONTEXT_BUDGET.md (G8).

.DESCRIPTION
    Funções puras/read-only (molde kb-lint/config-lint/standards-lint). Reusa Measure-KbContentSize do
    kb-lint.ps1 (dot-source) — a MESMA medição do B7: conta o corpo excluindo fenced code blocks.
    Rules não têm frontmatter, então o arquivo inteiro é o corpo.

    O contexto de .claude/rules/ é auto-carregado pelo Claude Code como sempre-ativo (validado
    empíricamente); cada rule é imposto permanente de token na inicialização. Este check torna o custo
    VISÍVEL e mede o drift — sem nunca falhar o build.

    Tetos GENEROSOS de propósito (pegam só o que destoa; restrição-mãe: token nunca reduz
    qualidade/velocidade). Afináveis no topo. Isenção por-arquivo via marcador de comentário.

    Uso: `. ./tools/rules-budget.ps1 ; Invoke-RulesBudget`  (ou `pwsh tools/rules-budget.ps1`, exit 0).
#>

[CmdletBinding()]
param(
    [string]$RulesDir,
    [string[]]$AnchorFiles,
    [switch]$Quiet
)

Set-StrictMode -Version Latest

# Reusa Measure-KbContentSize (B7): mesma verdade de "como medir tamanho de contexto" (exclui código).
. (Join-Path $PSScriptRoot 'kb-lint.ps1')

# Orçamento ADVISORY (tokens; ~4 chars/token, convenção do projeto). Generoso — silencioso hoje; pega
# outlier/drift. Ponto único e afinável (molde $script:KbSizeBudget do B7 / $script:LearnMinCandidates do G7).
$script:RuleBudgetPerFile   = 2500     # ~10.000 chars — teto por-arquivo (só pega outlier)
$script:RuleBudgetAggregate = 16000    # ~64.000 chars — teto do conjunto always-on (pega drift)
$script:CharsPerToken       = 4
# Isenção por-arquivo: rules não têm frontmatter (≠ KB), então a isenção é um comentário no arquivo.
$script:RxBudgetExempt = '(?im)<!--\s*context-budget:\s*exempt\s*-->'

# --- PURA: arquivo declara isenção de orçamento? ---------------------------------------------
function Test-RuleExempt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    return [bool]($raw -match $script:RxBudgetExempt)
}

# --- PURA: inventário do contexto always-on (rules + âncoras) ---------------------------------
function Get-AlwaysOnInventory {
    <#
    .SYNOPSIS
        Mede cada .md de RulesDir + cada AnchorFile existente. Chars via Measure-KbContentSize (exclui
        fenced code); rules sem frontmatter => o arquivo inteiro é o corpo. Dir ausente => só as âncoras
        (ou @() se nenhuma).
    .OUTPUTS
        [pscustomobject[]] @{ Path; Name; Kind('rule'|'anchor'); Chars; Tokens; Exempt; OverBudget }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RulesDir,
        [string[]]$AnchorFiles = @()
    )

    $targets = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $RulesDir -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $RulesDir -Filter '*.md' -File | Sort-Object Name)) {
            $targets.Add(@{ Path = $f.FullName; Kind = 'rule' })
        }
    }
    foreach ($a in $AnchorFiles) {
        if ($a -and (Test-Path -LiteralPath $a -PathType Leaf)) {
            $targets.Add(@{ Path = (Resolve-Path -LiteralPath $a).Path; Kind = 'anchor' })
        }
    }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $targets) {
        $lines  = @(Get-Content -LiteralPath $t.Path -ErrorAction SilentlyContinue)
        $chars  = Measure-KbContentSize -BodyLines $lines
        $tokens = [int][math]::Ceiling($chars / $script:CharsPerToken)
        $exempt = Test-RuleExempt -Path $t.Path
        $over   = (-not $exempt) -and ($tokens -gt $script:RuleBudgetPerFile)
        $items.Add([pscustomobject]@{
            Path       = $t.Path
            Name       = (Split-Path $t.Path -Leaf)
            Kind       = $t.Kind
            Chars      = $chars
            Tokens     = $tokens
            Exempt     = $exempt
            OverBudget = $over
        })
    }
    return $items.ToArray()
}

# --- PURA: avalia o inventário contra os tetos (advisory; nunca vira exit code) ---------------
function Test-RuleOverBudget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory)

    $total = 0
    foreach ($i in $Inventory) { $total += [int]$i.Tokens }   # robusto sob StrictMode e p/ inventário vazio
    $over  = @($Inventory | Where-Object { $_.OverBudget })

    return [pscustomobject]@{
        PerFileBudget   = $script:RuleBudgetPerFile
        AggregateBudget = $script:RuleBudgetAggregate
        TotalTokens     = $total
        OverFiles       = $over
        AggregateOver   = ($total -gt $script:RuleBudgetAggregate)
        Headroom        = ($script:RuleBudgetAggregate - $total)
    }
}

# --- PURA: resumo SEMPRE impresso (awareness de drift, mesmo tudo sob o teto) ------------------
function Format-AlwaysOnSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Result)
    $pct = if ($Result.AggregateBudget -gt 0) {
        [int][math]::Round(100.0 * $Result.TotalTokens / $Result.AggregateBudget)
    } else { 0 }
    return ('always-on: ~{0} / {1} tok ({2}%, headroom {3})' -f `
        $Result.TotalTokens, $Result.AggregateBudget, $pct, $Result.Headroom)
}

# --- PURA: texto advisory (educar ≠ barrar) — '' quando nada estoura --------------------------
function Format-AlwaysOnAdvisory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Result)

    if ($Result.OverFiles.Count -eq 0 -and -not $Result.AggregateOver) { return '' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('── orçamento de contexto always-on (advisory — nunca bloqueia) ──')
    foreach ($f in $Result.OverFiles) {
        $lines.Add(('  • {0}: ~{1} tok > teto por-arquivo {2}' -f $f.Name, $f.Tokens, $Result.PerFileBudget))
    }
    if ($Result.AggregateOver) {
        $lines.Add(('  • agregado: ~{0} tok > teto {1}' -f $Result.TotalTokens, $Result.AggregateBudget))
    }
    $lines.Add('  saídas: (1) enxugar prosa  (2) dividir a rule  (3) <!-- context-budget: exempt -->  (4) aceitar')
    $lines.Add('  o always-on carrega TODA sessão; reduzir é bônus — qualidade/verificação vêm primeiro.')
    return ($lines -join [Environment]::NewLine)
}

# --- Orquestra (read-only; imprime; SEMPRE exit 0 quando chamada como script) -----------------
function Invoke-RulesBudget {
    [CmdletBinding()]
    param(
        [string]$RulesDir,
        [string[]]$AnchorFiles,
        [switch]$Quiet
    )

    if (-not $RulesDir) {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $scaffold = Join-Path $repoRoot 'templates/project-scaffold'
        $RulesDir = Join-Path $scaffold '.claude/rules'
        if (-not $PSBoundParameters.ContainsKey('AnchorFiles')) {
            $AnchorFiles = @((Join-Path $scaffold 'CLAUDE.md'), (Join-Path $scaffold 'AGENTS.md'))
        }
    }
    if (-not $AnchorFiles) { $AnchorFiles = @() }

    $inv      = Get-AlwaysOnInventory -RulesDir $RulesDir -AnchorFiles $AnchorFiles
    $res      = Test-RuleOverBudget -Inventory $inv
    $summary  = Format-AlwaysOnSummary -Result $res
    $advisory = Format-AlwaysOnAdvisory -Result $res

    if (-not $Quiet) {
        Write-Host $summary
        if ($advisory) { Write-Host $advisory }
    }
    return [pscustomobject]@{ Inventory = $inv; Result = $res; Summary = $summary; Advisory = $advisory }
}

# --- Guard: roda só quando NÃO dot-sourced. ADVISORY: exit 0 SEMPRE ---------------------------
if ($MyInvocation.InvocationName -ne '.') {
    # Splat condicional: só passa o que foi dado, p/ não bindar -AnchorFiles vazio (anularia o default
    # de incluir as âncoras CLAUDE.md/AGENTS.md). Sem args => default completo (rules + âncoras).
    $splat = @{ Quiet = $Quiet }
    if ($RulesDir)    { $splat.RulesDir = $RulesDir }
    if ($AnchorFiles) { $splat.AnchorFiles = $AnchorFiles }
    $null = Invoke-RulesBudget @splat
    exit 0
}

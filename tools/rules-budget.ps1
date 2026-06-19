<#
.SYNOPSIS
    Retrato ADVISORY do contexto always-on: mede o footprint (chars→tokens) das rules sempre-ativas
    (.claude/rules/*.md) + os arquivos-âncora (CLAUDE.md / AGENTS.md) e imprime o **total absoluto +
    ranking por-arquivo** (maior→menor). NUNCA bloqueia (exit 0 sempre).

.DESCRIPTION
    Funções puras/read-only (molde kb-lint/config-lint). Reusa Measure-KbContentSize do kb-lint.ps1
    (dot-source) — a MESMA medição do B7: conta o corpo excluindo fenced code blocks. Rules não têm
    frontmatter, então o arquivo inteiro é o corpo.

    O contexto de .claude/rules/ é auto-carregado pelo Claude Code como sempre-ativo (validado
    empíricamente); cada rule é imposto permanente de token na inicialização. Este check torna o custo
    VISÍVEL — **sem teto, sem %, sem headroom, sem flag** (revisão G8 v2, 2026-06-16): informar ≠ julgar
    ([[orcamento-token-servo-da-qualidade]]). Um teto fixo seria arbitrário e dispararia falso-positivo
    sobre crescimento legítimo do framework. Drift fica a olho / git.

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

# Convenção do projeto p/ estimar tokens a partir de chars (~4 chars/token). Único parâmetro — NÃO há
# teto/orçamento: o relatório é puro (retrato), nunca compara contra uma barra.
$script:CharsPerToken = 4

# --- PURA: inventário do contexto always-on (rules + âncoras) ---------------------------------
function Get-AlwaysOnInventory {
    <#
    .SYNOPSIS
        Mede cada .md de RulesDir + cada AnchorFile existente. Chars via Measure-KbContentSize (exclui
        fenced code); rules sem frontmatter => o arquivo inteiro é o corpo. Dir ausente => só as âncoras
        (ou @() se nenhuma).
    .OUTPUTS
        [pscustomobject[]] @{ Path; Name; Kind('rule'|'anchor'); Chars; Tokens }
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
        $items.Add([pscustomobject]@{
            Path   = $t.Path
            Name   = (Split-Path $t.Path -Leaf)
            Kind   = $t.Kind
            Chars  = $chars
            Tokens = $tokens
        })
    }
    return $items.ToArray()
}

# --- PURA: monta o retrato (total + ranking por-arquivo, tokens-desc) -------------------------
function Format-AlwaysOnReport {
    <#
    .SYNOPSIS
        Recebe o inventário e devolve o retrato: total absoluto, contagem e o ranking por-arquivo
        (maior→menor; desempate por Name). SEM teto, SEM %, SEM headroom, SEM flag.
    .OUTPUTS
        [pscustomobject] @{ Total; FileCount; Summary; Lines }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory)

    $total = 0
    foreach ($i in $Inventory) { $total += [int]$i.Tokens }   # robusto sob StrictMode e p/ inventário vazio
    $count = @($Inventory).Count

    $ranked = @($Inventory | Sort-Object @{ e = { [int]$_.Tokens }; Descending = $true }, Name)
    $width  = 0
    foreach ($i in $ranked) { if ($i.Name.Length -gt $width) { $width = $i.Name.Length } }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($i in $ranked) {
        $lines.Add(('  {0}  {1,6} tok' -f ([string]$i.Name).PadRight($width), [int]$i.Tokens))
    }

    return [pscustomobject]@{
        Total     = $total
        FileCount = $count
        Summary   = ('always-on: ~{0} tok ({1} arquivos)' -f $total, $count)
        Lines     = $lines.ToArray()
    }
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

    $inv    = Get-AlwaysOnInventory -RulesDir $RulesDir -AnchorFiles $AnchorFiles
    $report = Format-AlwaysOnReport -Inventory $inv
    $reportText = ($report.Lines -join [Environment]::NewLine)

    if (-not $Quiet) {
        Write-Host $report.Summary
        if ($reportText) { Write-Host $reportText }
    }
    return [pscustomobject]@{
        Inventory = $inv
        Total     = $report.Total
        Summary   = $report.Summary
        Report    = $reportText
    }
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

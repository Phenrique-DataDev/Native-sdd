<#
.SYNOPSIS
    project-check (B12-frente-3) — parte determinística do /check: verifica a CONFORMIDADE dos
    artefatos `.claude/` CURADOS no projeto-alvo (KB, agentes de domínio, settings.json) e devolve
    um veredito agregado. Read-only.

.DESCRIPTION
    Funções PURAS/read-only, dot-sourceáveis e testáveis. **Reusa os lints existentes** (dot-source de
    `kb-lint.ps1`/`agent-lint.ps1`/`config-lint.ps1`) — NÃO reimplementa parsing de frontmatter/JSON:
      - KB     : Get-KbInventory (frontmatter por-entrada: Errors→error, OverBudget→warn — advisory/B7)
                 + Invoke-KbLint (relacional: dangling-related). Get-KbInventory NÃO roda no check.ps1
                 do framework (KB do scaffold é vazia) → o /check é a porta de execução dele no alvo.
      - AGENT  : Invoke-AgentLint (frontmatter + colisão + corpo + relacional, numa chamada).
      - CONFIG : Invoke-ConfigLint (forma/permissions amplo/hook arriscado) sobre settings*.json.

    Distinto do `tools/check.ps1` (runner do FRAMEWORK: PSScriptAnalyzer + todos os lints + Pester,
    roda no repo da metodologia). Aqui o alvo é um PROJETO scaffolded e o escopo são só os 3 lints
    aplicáveis. Seção sem alvo (ex.: KB vazia) → 'n/a' (não falha). Veredito: error→issues,
    só-warn→warnings, senão ok.

    Compatível com PowerShell 7+. Ver DESIGN_CHECK.md (B12-frente-3).
#>

Set-StrictMode -Version Latest

# Reusa os 3 lints aplicáveis ao alvo. Cada *-lint.ps1 só define funções (sem side-effects no boot).
foreach ($dep in @('kb-lint.ps1', 'agent-lint.ps1', 'config-lint.ps1')) {
    $p = Join-Path $PSScriptRoot $dep
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "project-check.ps1 requer tools/$dep (não encontrado em $p)."
    }
    . $p
}

# --- PURA: finding uniforme (mesmo shape de New-KbFinding/New-AgentFinding/New-ConfigFinding) -----
function New-CheckFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

# --- PURA: Get-KbInventory[] -> finding[] (Errors=>error, OverBudget=>warn advisory/B7, D-003) -----
function ConvertFrom-KbInventory {
    <#
    .SYNOPSIS  Converte o inventário da KB no shape de finding do /check.
    .OUTPUTS   finding[] (vazio = todas as entradas válidas e dentro do budget)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory)

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $Inventory) {
        $src = if ($e.PSObject.Properties['Path'] -and $e.Path) { [string]$e.Path } else { '<kb>' }
        if ($e.PSObject.Properties['Valid'] -and -not $e.Valid) {
            foreach ($msg in @($e.Errors)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$msg)) {
                    $findings.Add((New-CheckFinding -Severity error -Rule 'frontmatter' -Path $src -Message ([string]$msg)))
                }
            }
        }
        # OverBudget é ADVISORY (B7: educar, não barrar) -> warn, nunca error (D-003).
        if ($e.PSObject.Properties['OverBudget'] -and $e.OverBudget) {
            $findings.Add((New-CheckFinding -Severity warn -Rule 'over-budget' -Path $src `
                        -Message 'entrada acima do orçamento de tamanho sugerido (advisory)'))
        }
    }
    return $findings.ToArray()
}

# --- PURA: agrega severidades de um conjunto de findings -> veredito (D-004) ----------------------
function Get-CheckVerdict {
    <#
    .SYNOPSIS  ≥1 error => 'issues'; 0 error ∧ ≥1 warn => 'warnings'; senão 'ok'.
    .OUTPUTS   [string] ok | warnings | issues
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0) { return 'issues' }
    if (@($Findings | Where-Object { $_.Severity -eq 'warn' }).Count -gt 0) { return 'warnings' }
    return 'ok'
}

# --- I/O: roda o(s) lint(s) de uma seção -> { Name; Status; Findings } (fail-safe) ----------------
function Get-CheckSection {
    <#
    .SYNOPSIS  Verifica uma seção ('kb'|'agent'|'config'). Alvo ausente => Status 'n/a' (não falha).
    .OUTPUTS   pscustomobject { Name; Status; Findings[] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('kb', 'agent', 'config')][string]$Kind,
        [Parameter(Mandatory)][string]$Root
    )

    $claude = Join-Path $Root '.claude'
    try {
        switch ($Kind) {
            'kb' {
                $dir = Join-Path $claude 'kb'
                # "A KB tem entradas?" pela MESMA fonte única do lint/inventário/grafo (Get-KbEntryFile).
                $hasEntries = @(Get-KbEntryFile -Dir $dir).Count -gt 0
                if (-not $hasEntries) { return [pscustomobject]@{ Name = 'kb'; Status = 'n/a'; Findings = @() } }
                $f = @()
                $f += ConvertFrom-KbInventory -Inventory @(Get-KbInventory -Dir $dir)
                $f += @(Invoke-KbLint -Dir $dir)
            }
            'agent' {
                $dir = Join-Path $claude 'agents'
                $hasAgents = (Test-Path -LiteralPath $dir -PathType Container) -and
                    @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -ne 'AGENT_MAP.md' -and -not $_.Name.StartsWith('_') }).Count -gt 0
                if (-not $hasAgents) { return [pscustomobject]@{ Name = 'agent'; Status = 'n/a'; Findings = @() } }
                $f = @(Invoke-AgentLint -Dir $dir)
            }
            'config' {
                $paths = @('settings.json', 'settings.local.json') |
                    ForEach-Object { Join-Path $claude $_ } |
                    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
                if (@($paths).Count -eq 0) { return [pscustomobject]@{ Name = 'config'; Status = 'n/a'; Findings = @() } }
                $f = @(Invoke-ConfigLint -Path @($paths))
            }
        }
        $f = @($f)
        return [pscustomobject]@{ Name = $Kind; Status = (Get-CheckVerdict -Findings $f); Findings = $f }
    }
    catch {
        # Fail-safe: falha interna da seção não aborta o painel (D / Error Handling).
        $fin = @(New-CheckFinding -Severity error -Rule 'section-failed' -Path $Kind `
                -Message "falha ao verificar a seção '$Kind': $($_.Exception.Message)")
        return [pscustomobject]@{ Name = $Kind; Status = 'error-internal'; Findings = $fin }
    }
}

# --- I/O: monta o report agregado (3 seções + veredito global) -----------------------------------
function Get-ProjectCheckReport {
    <#
    .SYNOPSIS  Verifica kb/agent/config do projeto em -Root e agrega o veredito. Read-only.
    .OUTPUTS   pscustomobject { Root; Sections[]; Verdict }
    #>
    [CmdletBinding()]
    param([Parameter()][string]$Root = '.')

    $sections = @(
        Get-CheckSection -Kind kb     -Root $Root
        Get-CheckSection -Kind agent  -Root $Root
        Get-CheckSection -Kind config -Root $Root
    )
    # Veredito global só sobre seções que rodaram (n/a não contribui).
    $allFindings = @($sections | Where-Object { $_.Status -ne 'n/a' } | ForEach-Object { $_.Findings } | Where-Object { $_ })
    return [pscustomobject]@{
        Root     = $Root
        Sections = $sections
        Verdict  = (Get-CheckVerdict -Findings @($allFindings))
    }
}

# --- PURA: formata o painel determinístico -------------------------------------------------------
function Format-ProjectCheckReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][psobject]$Report)

    $bar = ('=' * 50)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($bar)
    $root = if ($Report -and $Report.Root) { $Report.Root } else { '.' }
    $lines.Add("CHECK - conformidade da curadoria - $root")
    $lines.Add($bar)

    if ($null -eq $Report) {
        $lines.Add('  indisponivel (camada tools/ nao resolvida?)')
        return ($lines -join [Environment]::NewLine)
    }

    foreach ($s in @($Report.Sections)) {
        $label = $s.Name.PadRight(8)
        if ($s.Status -eq 'n/a') {
            $lines.Add("  $label : n/a (sem alvo no projeto)")
            continue
        }
        $errs = @($s.Findings | Where-Object { $_.Severity -eq 'error' }).Count
        $warns = @($s.Findings | Where-Object { $_.Severity -eq 'warn' }).Count
        $lines.Add(("  {0} : {1} | {2} error / {3} warn" -f $label, $s.Status, $errs, $warns))
        foreach ($f in @($s.Findings)) {
            $lines.Add(("      [{0}] {1} - {2} ({3})" -f $f.Severity, $f.Rule, $f.Message, $f.Path))
        }
    }

    $lines.Add($bar)
    $verdict = if ($Report.Verdict) { $Report.Verdict } else { 'ok' }
    switch ($verdict) {
        'issues' { $lines.Add('  VEREDITO: ISSUES - ha inconformidade (error). Corrija antes de confiar na curadoria.') }
        'warnings' { $lines.Add('  VEREDITO: CONFORME COM AVISOS - so warnings (advisory). Revisar opcional.') }
        default { $lines.Add('  VEREDITO: CONFORME - artefatos curados em ordem.') }
    }
    return ($lines -join [Environment]::NewLine)
}

# Uso por função (igual aos outros tools, ex.: status/reflect): dot-source + chamada —
#   . ./tools/project-check.ps1 ; Format-ProjectCheckReport (Get-ProjectCheckReport -Root .)
# Sem entry-point de script: o comando /check resolve $toolsRoot e dot-sources este arquivo.

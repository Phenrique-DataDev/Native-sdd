<#
.SYNOPSIS
    simulate (O3) — parte determinística do /simulate: detecção de CAPACIDADE de simulação
    (agente role: simulation) + verificação de CONFORMIDADE do relatório de simulação.

.DESCRIPTION
    Funções PURAS (read-only), dot-sourceáveis e testáveis. **Reusa o agent-lint** (dot-source de
    `agent-lint.ps1`): `Read-AgentFrontmatter`/`Get-MarkdownHeadings`/`Get-MarkdownSectionBody` —
    não reimplementa parsing. A SIMULAÇÃO real (rodar `dbt build --empty`, comparar dados) e o
    julgamento "o fix funcionaria?" são runtime do LLM/domínio; aqui mora só o objetivo:
      - CAPACIDADE : Get-SimulationCapability — há agente `role: simulation` em `agents/domain/`?
                     Vazio → o /simulate degrada (orienta /audit-agents); nunca inventa números.
      - CONTRATO   : Test-SimulationReportConforms — o relatório tem as 6 seções obrigatórias
                     (Baseline/Proposta/Resultado/Diff/Premissas/Isolamento). `Isolamento` é a
                     prova DECLARADA de que produção não foi tocada (nunca-destrutivo verificável).

    Compatível com PowerShell 7+. Ver DESIGN_SIMULATION.md (O3).
#>

Set-StrictMode -Version Latest

# Reusa o agent-lint (parsing de frontmatter + headings). Só define funções + $script: (sem side-effects).
$script:SimulateAgentLintPath = Join-Path $PSScriptRoot 'agent-lint.ps1'
if (-not (Test-Path -LiteralPath $script:SimulateAgentLintPath -PathType Leaf)) {
    throw "simulate.ps1 requer tools/agent-lint.ps1 (não encontrado em $script:SimulateAgentLintPath)."
}
. $script:SimulateAgentLintPath

# O papel que marca um simulador de domínio. É o CONTRATO (não o nome do arquivo).
$script:SimulationRole = 'simulation'

# As 6 seções H2 obrigatórias do relatório de simulação. Ponto único e afinável.
$script:RequiredReportSections = @('Baseline', 'Proposta', 'Resultado', 'Diff', 'Premissas', 'Isolamento')

# --- PURA: simuladores de domínio disponíveis (frontmatter role: simulation) -------------------
function Get-SimulationCapability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    # Mesmo filtro do agent-lint: ignora o mapa e auxiliares (_*.md).
    $files = Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'AGENT_MAP.md' -and -not $_.Name.StartsWith('_') }

    $caps = foreach ($f in $files) {
        $fm = Read-AgentFrontmatter -Path $f.FullName
        if ($fm -and $fm.Contains('role') -and ($fm['role'] -eq $script:SimulationRole)) {
            [pscustomobject]@{
                Name = if ($fm.Contains('name') -and $fm['name']) { [string]$fm['name'] } else { $f.BaseName }
                Path = $f.FullName
            }
        }
    }
    return @($caps)
}

# --- PURA: o relatório de simulação cumpre o contrato das 6 seções? ----------------------------
function Test-SimulationReportConforms {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $headings = @(Get-MarkdownHeadings -Text $Text)
    $findings = [System.Collections.Generic.List[object]]::new()

    foreach ($section in $script:RequiredReportSections) {
        $present = @($headings | Where-Object { $_.Trim() -ieq $section }).Count -gt 0
        $body = if ($present) {
            Get-MarkdownSectionBody -Text $Text -HeadingPattern ('^' + [regex]::Escape($section) + '$')
        }
        else { '' }

        if (-not $present -or [string]::IsNullOrWhiteSpace($body)) {
            $rule = if ($section -eq 'Isolamento') { 'isolation-not-declared' } else { 'missing-section' }
            $findings.Add([pscustomobject]@{
                    Severity = 'error'
                    Rule     = $rule
                    Section  = $section
                    Message  = "seção obrigatória '$section' ausente ou vazia no relatório de simulação."
                })
        }
    }
    return @($findings.ToArray())
}

# --- PURA: relatório legível (mesmo estilo dos demais lints) -----------------------------------
function Format-SimulationReport {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Capability = @(),
        [AllowEmptyCollection()][object[]]$Findings = @()
    )

    $lines = @()
    if ($Capability -and $Capability.Count -gt 0) {
        $names = ($Capability | ForEach-Object { $_.Name }) -join ', '
        $lines += "simulate: capacidade disponível — $($Capability.Count) simulador(es): $names"
    }
    else {
        $lines += 'simulate: sem capacidade de simulação para este domínio (rode /audit-agents).'
    }

    if ($Findings -and $Findings.Count -gt 0) {
        foreach ($f in $Findings) { $lines += ('[{0}] {1} — {2}' -f $f.Severity.ToUpper(), $f.Rule, $f.Message) }
    }
    else {
        $lines += 'relatório: conforme (6 seções presentes, isolamento declarado).'
    }
    return ($lines -join "`n")
}

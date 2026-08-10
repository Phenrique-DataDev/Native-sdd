<#
.SYNOPSIS
    sdd-lint — invariante do ciclo SDD: relatório de build de feature JÁ ARQUIVADA não pode
    continuar em `.claude/sdd/reports/`.

.DESCRIPTION
    O `/ship` (passo 3) MOVE os artefatos da feature para `archive/<FEATURE>/`. Enquanto o passo
    era ambíguo ("mova/aponte") e ninguém verificava, o relatório ficava para trás e o `/status`
    passava a mentir: feature encerrada aparecendo como *build em andamento*, com o "próximo passo"
    sugerindo `/ship` de algo já shipado (observado em uso real, 2026-07-23).

    É a família "regra sem mecanismo" que esta metodologia batiza, aplicada ao próprio `/ship`:
    a redação do command é a disciplina, este lint é o backstop determinístico. Molde do
    `resync-lint.ps1` — casca fina sobre a fonte única da detecção (`Get-OrphanBuildReports`,
    em `status.ps1`), sem reimplementar o casamento de slug.

    Regra emitida: `orphan-build-report` (error). Sem `.claude/sdd/` no alvo, não há findings —
    o lint é inerte fora de um projeto SDD (o `/check` do scaffold roda em projeto real; o
    `check.ps1` do framework roda no dogfood da própria raiz).
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'status.ps1')   # Get-OrphanBuildReports, Resolve-ReportOwnerKey

function New-SddFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-SddLintFindings {
    <#
    .SYNOPSIS  PURA: órfãos (de Get-OrphanBuildReports) -> findings orphan-build-report.
    .OUTPUTS   [pscustomobject[]] (vazio = invariante intacta).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Orphans)

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($o in $Orphans) {
        $findings.Add((New-SddFinding -Severity error -Rule 'orphan-build-report' -Path ([string]$o.Path) `
                    -Message ("feature '$($o.Feature)' ja tem SHIPPED em archive/ — mova este relatorio para " +
                        ".claude/sdd/archive/$($o.Feature)/ (entrega em levas: N relatorios convivem no mesmo diretorio)")))
    }
    return $findings.ToArray()
}

function Format-SddLintReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'sdd-lint: ok (nenhum relatorio orfao)' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("sdd-lint: $(@($Findings).Count) achado(s)")
    foreach ($f in $Findings) { $lines.Add(("  [{0}] {1} - {2} ({3})" -f $f.Severity, $f.Rule, $f.Message, $f.Path)) }
    return ($lines -join [Environment]::NewLine)
}

function Test-SddLintGate {
    <#
    .SYNOPSIS  PURA: passa quando não há finding `error`.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -eq 0)
}

function Invoke-SddLint {
    <#
    .SYNOPSIS  Driver: lê o alvo e devolve os findings. Read-only.
    .OUTPUTS   [pscustomobject[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    return @(Get-SddLintFindings -Orphans @(Get-OrphanBuildReports -Root $Root))
}

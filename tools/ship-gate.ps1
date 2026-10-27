<#
.SYNOPSIS
    ship-gate — a pré-condição do /ship vira verificação: o BUILD_REPORT da feature está ✅, com o
    mapa de cobertura preenchido, e os comandos de verificação do projeto passam AGORA
    (SHIP_COM_PRECONDICAO_SO_EM_PROMPT, 2026-10-19).

.DESCRIPTION
    Antes, "BUILD_REPORT completo e verificado (status ✅)" era instrução em prompt: o agente que
    afirmasse o ✅ seguia para o SHIPPED. Aqui ninguém afirma; o gate lê e roda.

      - Get-BuildReportStatus : `**Geral:**` do relatório → complete / in-progress / blocked / unfilled.
      - Get-PendingCriteria   : AT/JH com ⏳ na tabela; reprova mesmo com o ✅ na linha Geral.
      - Get-FeatureBuildReports : os BUILD_REPORT da feature em `reports/`, pelo mesmo casamento por
                                  segmentos do /ship (`Resolve-ReportOwnerKey`): `F_LEVA2` é de F,
                                  `FZ` não.
      - Test-ShipReady        : junta as três provas e devolve { Ready; Failures; Warnings; Verifier }.

    Reusa: `Get-CoverageMapFindings` (sdd-lint.ps1), `Get-VerificationCommand` e `Get-VerifierResult`
    (iterate.ps1, que traz verification.ps1). Compatível com PowerShell 7+.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'sdd-lint.ps1')   # Get-CoverageMapFindings, Resolve-ReportOwnerKey, ConvertTo-SlugKey
. (Join-Path $PSScriptRoot 'iterate.ps1')    # Get-VerifierResult, Get-VerificationCommand

function Get-BuildReportStatus {
    <#
    .SYNOPSIS
        Lê a linha `**Geral:**` (ou `**Overall:**`). O placeholder do template `{✅ … / 🔄 … / ❌ …}`
        conta como `unfilled`, não como ✅ — ele contém o ✅.
    .OUTPUTS
        [string] complete | in-progress | blocked | unfilled
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $line = @($Lines | Where-Object { $_ -match '^\s*\*\*(Geral|Overall):\*\*' }) | Select-Object -Last 1
    if (-not $line) { return 'unfilled' }
    $value = ($line -replace '^\s*\*\*(Geral|Overall):\*\*', '').Trim()
    # placeholder do template, ou as opções coladas sem escolher uma
    $options = @('✅', '🔄', '❌' | Where-Object { $value.Contains($_) }).Count
    if ($value -match '\{' -or $options -gt 1) { return 'unfilled' }
    if ($value -match '❌|BLOCKED|BLOQUEADO') { return 'blocked' }
    if ($value -match '🔄|IN PROGRESS|EM ANDAMENTO') { return 'in-progress' }
    if ($value -match '✅|COMPLETE|COMPLETO') { return 'complete' }
    return 'unfilled'
}

function Get-PendingCriteria {
    <#
    .SYNOPSIS
        IDs das linhas `| AT-nnn |`/`| JH-nnn |` cuja célula de status tem ⏳. A célula do template
        (`⏳/✅/❌`, várias opções) não conta: aí o status já sai `unfilled`.
    .OUTPUTS
        [string[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    foreach ($l in $Lines) {
        if ($l -notmatch '^\s*\|\s*((?:AT|JH)-\d+)\s*\|([^|]*)\|') { continue }
        $cell = $Matches[2]
        $options = @('✅', '⏳', '❌' | Where-Object { $cell.Contains($_) }).Count
        if ($cell.Contains('⏳') -and $options -eq 1) { $Matches[1] }
    }
}

function Get-FeatureBuildReports {
    <#
    .SYNOPSIS  Os BUILD_REPORT_*.md em `reports/` que pertencem à feature (todas as levas).
    .OUTPUTS   [string[]] caminhos completos
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Feature
    )
    $key = ConvertTo-SlugKey $Feature
    return @(Get-BuildReportPath -Root $Root | Where-Object {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($_) -replace '^BUILD_REPORT_', ''
            (Resolve-ReportOwnerKey -ReportName $name -ShippedKeys @($key)) -eq $key
        })
}

function Test-ShipReady {
    <#
    .SYNOPSIS
        A feature pode ser shipada? Reprova (Failures) se: não há BUILD_REPORT dela em `reports/`;
        algum não está ✅; algum tem AT/JH em ⏳; algum tem o mapa `## Não exercitado` ausente ou vazio; a verificação
        declarada no project-context.md reprova agora. Sem verificação declarada, avisa (Warnings) e
        não reprova: o projeto antigo não tem a seção.
    .OUTPUTS
        [pscustomobject] { Ready; Failures[]; Warnings[]; Verifier }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Feature,
        [switch]$SkipVerification,
        [int]$TimeoutSec = 0
    )

    $failures = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $reports = @(Get-FeatureBuildReports -Root $Root -Feature $Feature)
    if ($reports.Count -eq 0) {
        $failures.Add("nenhum BUILD_REPORT de $Feature em .claude/sdd/reports/ — volte ao /build")
    }
    foreach ($r in $reports) {
        $name  = Split-Path -Leaf $r
        $lines = @(Get-Content -LiteralPath $r -Encoding utf8 -ErrorAction SilentlyContinue)
        $status = Get-BuildReportStatus -Lines $lines
        if ($status -ne 'complete') { $failures.Add("${name}: status $status, não ✅ COMPLETE") }
        # ⏳ = AT não rodado ou juiz que não respondeu: o ✅ da linha Geral não vale por cima disso
        $pending = @(Get-PendingCriteria -Lines $lines)
        if ($pending.Count -gt 0) { $failures.Add("${name}: critério pendente (⏳): $($pending -join ', ')") }
        foreach ($f in @(Get-CoverageMapFindings -Path $r -Lines $lines)) {
            $failures.Add("${name}: $($f.Rule)")
        }
    }

    $verifier = ''
    if (-not $SkipVerification) {
        $cmd = Get-VerificationCommand -Root $Root
        if (-not $cmd) {
            $warnings.Add('sem teste declarado em "## Verificação" do project-context.md: a verificação não rodou')
        }
        else {
            $verifier = [string]$cmd.Verifier
            $push = Push-Location -LiteralPath $Root -PassThru
            try { $result = Get-VerifierResult -Verifier $verifier -Required $cmd.Required -TimeoutSec $TimeoutSec }
            finally { if ($push) { Pop-Location } }
            foreach ($c in @($cmd.Required)) {
                if (-not $result.$c) { $failures.Add("verificação reprovou ($c): $verifier") }
            }
        }
    }

    return [pscustomobject]@{
        Ready    = ($failures.Count -eq 0)
        Failures = @($failures)
        Warnings = @($warnings)
        Verifier = $verifier
    }
}

<#
.SYNOPSIS
    Lint da convenção anti-racionalização (D4) nos artefatos SDD com gate:
    verifica que cada artefato declara a tabela "Racionalizações comuns" e uma
    seção de red flags ("O que NÃO fazer" / "Red flags").

.DESCRIPTION
    Funções PURAS (recebem texto Markdown, sem tocar disco) + um I/O fino.
    Espelha tools/config-lint.ps1 e tools/agent-lint.ps1 (sem módulo externo).

    A convenção (ver methodology/03-standards) torna os gates determinísticos
    do projeto difíceis de "racionalizar para fora": cada artefato com gate
    documenta as desculpas comuns (desculpa -> realidade) e os red flags.

    Checks (cada achado = { Rule; Severity; Path; Message }):
      - missing-rationalizations (error) sem heading "Racionalizações comuns".
      - missing-redflags         (error) sem heading "O que NÃO fazer" / "Red flags".
      - rationalizations-no-table (warn) heading presente mas sem linha de tabela
                                         (|...|) na seção — tabela vazia/ausente.

    Severidade: error bloqueia o CI (gate); warn é advisory (reporta, não quebra).
    Escopo: roda só sobre o CONJUNTO declarado de artefatos com gate (passado em
    -Path) — não força a convenção em todo command/agent.
#>

Set-StrictMode -Version Latest

# Heading da tabela de racionalizações (case-insensitive, tolera acento ausente).
$script:RxRationalizations = 'racionaliza'
# Heading de red flags: "O que NÃO fazer" (com/sem acento) OU "Red flags".
$script:RxRedFlags = '(o que n[ãa]o fazer|red\s*flags?)'

function New-StandardsFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-MarkdownHeadings {
    <#
    .SYNOPSIS  Lista os headings (texto após os '#') de um Markdown, na ordem.
    .OUTPUTS   [string[]] (vazio se não houver heading)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $headings = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -match '^\s*#{1,6}\s+(.+?)\s*$') { $headings.Add($Matches[1]) }
    }
    return $headings.ToArray()
}

function Test-SectionHasTable {
    <#
    .SYNOPSIS  true se a seção cujo heading casa $HeadingPattern tem ≥1 linha de tabela
               (|...|) antes do próximo heading. false se a seção não existe ou é vazia.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$HeadingPattern
    )

    $lines = $Text -split "\r?\n"
    $inSection = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*#{1,6}\s+(.+?)\s*$') {
            # entrou/saiu de seção ao cruzar um heading
            $inSection = ($Matches[1] -imatch $HeadingPattern)
            continue
        }
        if ($inSection -and $line -match '^\s*\|.*\|\s*$') { return $true }
    }
    return $false
}

function Get-StandardsFindings {
    <#
    .SYNOPSIS  Roda a convenção anti-racionalização sobre o TEXTO de um artefato.
               Tag Path com "$Source#".
    .OUTPUTS   [pscustomobject[]] (vazio = conforme)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source
    )

    $headings = Get-MarkdownHeadings -Text $Text
    $hasRationalizations = @($headings | Where-Object { $_ -imatch $script:RxRationalizations }).Count -gt 0
    $hasRedFlags = @($headings | Where-Object { $_ -imatch $script:RxRedFlags }).Count -gt 0

    $findings = [System.Collections.Generic.List[object]]::new()

    if (-not $hasRationalizations) {
        $findings.Add((New-StandardsFinding -Severity error -Rule missing-rationalizations -Path '/' `
                    -Message 'falta a seção "Racionalizações comuns" (tabela desculpa -> realidade)'))
    }
    elseif (-not (Test-SectionHasTable -Text $Text -HeadingPattern $script:RxRationalizations)) {
        $findings.Add((New-StandardsFinding -Severity warn -Rule rationalizations-no-table -Path '/' `
                    -Message 'seção "Racionalizações comuns" sem tabela (|desculpa|realidade|)'))
    }

    if (-not $hasRedFlags) {
        $findings.Add((New-StandardsFinding -Severity error -Rule missing-redflags -Path '/' `
                    -Message 'falta a seção de red flags ("O que NÃO fazer" / "Red flags")'))
    }

    foreach ($f in $findings) { $f.Path = "$Source#$($f.Path)" }
    return $findings.ToArray()
}

function Format-StandardsLintReport {
    <# .SYNOPSIS  Painel legível dos achados, agrupado por arquivo. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'standards-lint: OK (0 achados)' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $byFile = $Findings | Group-Object { ($_.Path -split '#', 2)[0] }
    foreach ($g in $byFile) {
        $lines.Add("• $($g.Name)")
        foreach ($f in $g.Group) {
            $node = ($f.Path -split '#', 2)[1]
            $lines.Add("    [$($f.Severity)] $($f.Rule) $node — $($f.Message)")
        }
    }
    return ($lines -join [Environment]::NewLine)
}

function Test-StandardsLintGate {
    <# .SYNOPSIS  $false se houver ≥1 achado 'error' (bloqueia o CI). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-StandardsLint {
    <#
    .SYNOPSIS  I/O fino: lê cada artefato com gate e agrega os achados.
    .OUTPUTS   [pscustomobject[]] de achados.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Path)

    $all = @()
    foreach ($p in $Path) {
        try {
            $text = Get-Content -LiteralPath $p -Raw -ErrorAction Stop
        }
        catch {
            $all += New-StandardsFinding -Severity error -Rule unreadable -Path "$p#/" `
                -Message "arquivo ilegível: $($_.Exception.Message)"
            continue
        }
        $all += Get-StandardsFindings -Text $text -Source $p
    }
    return @($all)
}

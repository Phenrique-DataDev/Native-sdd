<#
.SYNOPSIS
    Lint de contrato do doubt-driven (D5): verifica que a rule e o comando declaram
    a postura adversarial in-flight conforme o DESIGN.

.DESCRIPTION
    Funções PURAS (recebem texto Markdown, sem tocar disco) + um I/O fino.
    Espelha tools/standards-lint.ps1 e tools/config-lint.ps1 (sem módulo externo).

    Verifica o CONTRATO documentado (presença de seções/marcadores), não o
    comportamento em runtime — coerente com o Out of Scope do DEFINE.

    Checks da RULE (cada achado = { Rule; Severity; Path; Message }):
      - missing-doubt-cycle      (error) sem seção do ciclo CLAIM..STOP.
      - missing-reviewer-contract(error) sem "contrato do revisor adversarial".
      - missing-when-apply       (error) sem "quando aplicar".
      - missing-redflags         (error) sem "O que NÃO fazer" / "Red flags".
      - redflags-no-table        (warn)  red flags presente mas sem linha de tabela.

    Checks do COMANDO (/doubt):
      - missing-omit-conclusion  (error) não declara montar o pacote SEM a conclusão.
      - missing-agent-invocation (error) não menciona invocar Agent / fresh-context.
      - missing-doubts-output    (error) não declara saída = dúvidas.
      - verdict-leak             (warn)  contém escala de veredito (🔴/🟡/🟢 ou aprovad/reprovad).

    Severidade: error bloqueia o CI (gate); warn é advisory (reporta, não quebra).
    Escopo: roda só sobre a rule + o comando do doubt-driven (não força a convenção
    em todo arquivo).
#>

Set-StrictMode -Version Latest

# --- Headings obrigatórios da rule (case-insensitive, tolera acento ausente) ---
$script:RxCycle = 'ciclo|claim.*stop'
$script:RxReviewer = 'revisor adversarial|contrato do revisor'
$script:RxWhen = 'quando (aplicar|duvidar)'
$script:RxRedFlags = '(o que n[ãa]o fazer|red\s*flags?)'

# --- Marcadores de conteúdo do comando /doubt ---
$script:RxOmitConclusion = 'sem a conclus|omit\w* a conclus'
$script:RxAgentInvoke = 'fresh-context|agent'
$script:RxDoubtsOut = 'd[úu]vidas?'
$script:RxVerdictLeak = '🔴|🟡|🟢|aprovad|reprovad'

function New-DoubtFinding {
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
            $inSection = ($Matches[1] -imatch $HeadingPattern)
            continue
        }
        if ($inSection -and $line -match '^\s*\|.*\|\s*$') { return $true }
    }
    return $false
}

function Get-DoubtRuleFindings {
    <#
    .SYNOPSIS  Roda o contrato sobre o TEXTO da rule doubt-driven. Tag Path com "$Source#".
    .OUTPUTS   [pscustomobject[]] (vazio = conforme)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source
    )

    $headings = Get-MarkdownHeadings -Text $Text
    $hasCycle = @($headings | Where-Object { $_ -imatch $script:RxCycle }).Count -gt 0
    $hasReviewer = @($headings | Where-Object { $_ -imatch $script:RxReviewer }).Count -gt 0
    $hasWhen = @($headings | Where-Object { $_ -imatch $script:RxWhen }).Count -gt 0
    $hasRedFlags = @($headings | Where-Object { $_ -imatch $script:RxRedFlags }).Count -gt 0

    $findings = [System.Collections.Generic.List[object]]::new()

    if (-not $hasCycle) {
        $findings.Add((New-DoubtFinding -Severity error -Rule missing-doubt-cycle -Path '/' `
                    -Message 'falta a seção do ciclo CLAIM->EXTRACT->DOUBT->RECONCILE->STOP'))
    }
    if (-not $hasReviewer) {
        $findings.Add((New-DoubtFinding -Severity error -Rule missing-reviewer-contract -Path '/' `
                    -Message 'falta a seção "Contrato do revisor adversarial"'))
    }
    if (-not $hasWhen) {
        $findings.Add((New-DoubtFinding -Severity error -Rule missing-when-apply -Path '/' `
                    -Message 'falta a seção "Quando aplicar" (opt-in)'))
    }
    if (-not $hasRedFlags) {
        $findings.Add((New-DoubtFinding -Severity error -Rule missing-redflags -Path '/' `
                    -Message 'falta a seção de red flags ("O que NÃO fazer" / "Red flags")'))
    }
    elseif (-not (Test-SectionHasTable -Text $Text -HeadingPattern $script:RxRedFlags)) {
        $findings.Add((New-DoubtFinding -Severity warn -Rule redflags-no-table -Path '/' `
                    -Message 'seção de red flags sem tabela (|red flag|o que indica|)'))
    }

    foreach ($f in $findings) { $f.Path = "$Source#$($f.Path)" }
    return $findings.ToArray()
}

function Get-DoubtCommandFindings {
    <#
    .SYNOPSIS  Roda o contrato sobre o TEXTO do comando /doubt. Tag Path com "$Source#".
    .OUTPUTS   [pscustomobject[]] (vazio = conforme)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    if ($Text -notmatch $script:RxOmitConclusion) {
        $findings.Add((New-DoubtFinding -Severity error -Rule missing-omit-conclusion -Path '/' `
                    -Message 'comando não declara montar o pacote SEM a conclusão do autor'))
    }
    if ($Text -notmatch $script:RxAgentInvoke) {
        $findings.Add((New-DoubtFinding -Severity error -Rule missing-agent-invocation -Path '/' `
                    -Message 'comando não menciona invocar o Agent nativo (fresh-context)'))
    }
    if ($Text -notmatch $script:RxDoubtsOut) {
        $findings.Add((New-DoubtFinding -Severity error -Rule missing-doubts-output -Path '/' `
                    -Message 'comando não declara a saída como dúvidas'))
    }
    if ($Text -match $script:RxVerdictLeak) {
        $findings.Add((New-DoubtFinding -Severity warn -Rule verdict-leak -Path '/' `
                    -Message 'comando contém escala de veredito (🔴/🟡/🟢 ou aprovado/reprovado) — a saída deve ser dúvidas'))
    }

    foreach ($f in $findings) { $f.Path = "$Source#$($f.Path)" }
    return $findings.ToArray()
}

function Format-DoubtLintReport {
    <# .SYNOPSIS  Painel legível dos achados, agrupado por arquivo. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'doubt-lint: OK (0 achados)' }

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

function Test-DoubtLintGate {
    <# .SYNOPSIS  $false se houver ≥1 achado 'error' (bloqueia o CI). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-DoubtLint {
    <#
    .SYNOPSIS  I/O fino: lê a rule + o comando e agrega os achados.
    .OUTPUTS   [pscustomobject[]] de achados.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RulePath,
        [Parameter(Mandatory)][string]$CommandPath
    )

    $all = @()

    foreach ($pair in @(
            @{ Path = $RulePath; Kind = 'rule' },
            @{ Path = $CommandPath; Kind = 'command' }
        )) {
        try {
            $text = Get-Content -LiteralPath $pair.Path -Raw -ErrorAction Stop
        }
        catch {
            $all += New-DoubtFinding -Severity error -Rule unreadable -Path "$($pair.Path)#/" `
                -Message "arquivo ilegível: $($_.Exception.Message)"
            continue
        }
        if ($pair.Kind -eq 'rule') {
            $all += Get-DoubtRuleFindings -Text $text -Source $pair.Path
        }
        else {
            $all += Get-DoubtCommandFindings -Text $text -Source $pair.Path
        }
    }
    return @($all)
}

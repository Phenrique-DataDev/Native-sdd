<#
.SYNOPSIS
    Lint de contrato do documenter (B10): verifica que a rule e o comando declaram a
    postura "Proativo seguro" (doc/registro humano×LLM fora da KB) conforme o DESIGN.

.DESCRIPTION
    Funções PURAS (recebem texto Markdown, sem tocar disco) + um I/O fino.
    Espelha tools/doubt-lint.ps1 e tools/standards-lint.ps1 (sem módulo externo).

    Verifica o CONTRATO documentado (presença de seções/marcadores), não o
    comportamento em runtime — coerente com o Out of Scope do DEFINE (a postura
    proativa real é validada no e2e pós-ship).

    Checks da RULE documentation.md (cada achado = { Rule; Severity; Path; Message }):
      - missing-when-document  (error) sem seção "Quando documentar" (postura proativa).
      - missing-append-only    (error) sem o termo "append-only" (registros imutáveis).
      - missing-nondestructive (error) sem "pontual"/"nunca-destrutiv" (doc de código).
      - missing-precondition   (error) sem a pré-condição (ativo só após o 1º /train-kb).
      - missing-redflags       (error) sem "O que NÃO fazer" / "Red flags".
      - redflags-no-table      (warn)  red flags presente mas sem linha de tabela.

    Checks do COMANDO /document:
      - missing-agent-invocation (error) não menciona invocar Agent / subagent documenter.
      - missing-approval-flow    (error) não declara plano/diff → aprovação → aplica.
      - missing-nondestructive-cmd (error) não declara nunca-destrutivo (append-only/pontual).
      - missing-not-kb           (error) não declara que NÃO escreve na KB.

    Severidade: error bloqueia o CI (gate); warn é advisory (reporta, não quebra).
    Escopo: roda só sobre a rule + o comando do documenter (não força a convenção
    em todo arquivo).
#>

Set-StrictMode -Version Latest

# --- Headings/termos obrigatórios da rule (case-insensitive, tolera acento ausente) ---
$script:RxWhenDocument = 'quando documentar'
$script:RxRedFlags = '(o que n[ãa]o fazer|red\s*flags?)'
$script:RxAppendOnly = 'append-only'
$script:RxNonDestructive = 'pontual|nunca-destrutiv'
$script:RxPrecondition = 'train-kb'   # sequência KB→docs: documenter ativo só após o 1º /train-kb

# --- Marcadores de conteúdo do comando /document ---
$script:RxAgentInvoke = 'documenter|agent'
$script:RxApprovalFlow = 'aprova|confirma'
$script:RxNotKb = 'escreve\w*\s+na\s+kb|fora da kb'

function New-DocFinding {
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

function Get-DocRuleFindings {
    <#
    .SYNOPSIS  Roda o contrato sobre o TEXTO da rule documentation.md. Tag Path com "$Source#".
    .OUTPUTS   [pscustomobject[]] (vazio = conforme)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source
    )

    $headings = Get-MarkdownHeadings -Text $Text
    $hasWhen = @($headings | Where-Object { $_ -imatch $script:RxWhenDocument }).Count -gt 0
    $hasRedFlags = @($headings | Where-Object { $_ -imatch $script:RxRedFlags }).Count -gt 0

    $findings = [System.Collections.Generic.List[object]]::new()

    if (-not $hasWhen) {
        $findings.Add((New-DocFinding -Severity error -Rule missing-when-document -Path '/' `
                    -Message 'falta a seção "Quando documentar" (postura proativa)'))
    }
    if ($Text -notmatch $script:RxAppendOnly) {
        $findings.Add((New-DocFinding -Severity error -Rule missing-append-only -Path '/' `
                    -Message 'rule não declara registros "append-only"'))
    }
    if ($Text -notmatch $script:RxNonDestructive) {
        $findings.Add((New-DocFinding -Severity error -Rule missing-nondestructive -Path '/' `
                    -Message 'rule não declara doc de código "pontual"/"nunca-destrutivo"'))
    }
    if ($Text -notmatch $script:RxPrecondition) {
        $findings.Add((New-DocFinding -Severity error -Rule missing-precondition -Path '/' `
                    -Message 'rule não declara a pré-condição (documenter ativo só após o 1º /train-kb)'))
    }
    if (-not $hasRedFlags) {
        $findings.Add((New-DocFinding -Severity error -Rule missing-redflags -Path '/' `
                    -Message 'falta a seção de red flags ("O que NÃO fazer" / "Red flags")'))
    }
    elseif (-not (Test-SectionHasTable -Text $Text -HeadingPattern $script:RxRedFlags)) {
        $findings.Add((New-DocFinding -Severity warn -Rule redflags-no-table -Path '/' `
                    -Message 'seção de red flags sem tabela (|não faça|por quê|)'))
    }

    foreach ($f in $findings) { $f.Path = "$Source#$($f.Path)" }
    return $findings.ToArray()
}

function Get-DocCommandFindings {
    <#
    .SYNOPSIS  Roda o contrato sobre o TEXTO do comando /document. Tag Path com "$Source#".
    .OUTPUTS   [pscustomobject[]] (vazio = conforme)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    if ($Text -notmatch $script:RxAgentInvoke) {
        $findings.Add((New-DocFinding -Severity error -Rule missing-agent-invocation -Path '/' `
                    -Message 'comando não menciona invocar o subagent documenter via Agent (fan-out)'))
    }
    if ($Text -notmatch $script:RxApprovalFlow) {
        $findings.Add((New-DocFinding -Severity error -Rule missing-approval-flow -Path '/' `
                    -Message 'comando não declara plano/diff → aprovação → aplica'))
    }
    if ($Text -notmatch $script:RxNonDestructive -and $Text -notmatch $script:RxAppendOnly) {
        $findings.Add((New-DocFinding -Severity error -Rule missing-nondestructive-cmd -Path '/' `
                    -Message 'comando não declara nunca-destrutivo (append-only / pontual)'))
    }
    if ($Text -notmatch $script:RxNotKb) {
        $findings.Add((New-DocFinding -Severity error -Rule missing-not-kb -Path '/' `
                    -Message 'comando não declara que NÃO escreve na KB'))
    }

    foreach ($f in $findings) { $f.Path = "$Source#$($f.Path)" }
    return $findings.ToArray()
}

function Format-DocLintReport {
    <# .SYNOPSIS  Painel legível dos achados, agrupado por arquivo. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'doc-lint: OK (0 achados)' }

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

function Test-DocLintGate {
    <# .SYNOPSIS  $false se houver ≥1 achado 'error' (bloqueia o CI). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-DocLint {
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
            $all += New-DocFinding -Severity error -Rule unreadable -Path "$($pair.Path)#/" `
                -Message "arquivo ilegível: $($_.Exception.Message)"
            continue
        }
        if ($pair.Kind -eq 'rule') {
            $all += Get-DocRuleFindings -Text $text -Source $pair.Path
        }
        else {
            $all += Get-DocCommandFindings -Text $text -Source $pair.Path
        }
    }
    return @($all)
}

<#
.SYNOPSIS
    Lint de conformidade dos commands à camada tools/ (B11): nenhum command faz dot-source
    CRU de `tools/*.ps1` — deve resolver pela cascata `$toolsRoot` (rules/tooling.md).

.DESCRIPTION
    Funções PURAS (recebem texto Markdown, sem tocar disco) + um I/O fino que varre o
    diretório de commands. Espelha tools/doc-lint.ps1 / tools/doubt-lint.ps1 (sem módulo externo).

    Motivação: no projeto-alvo o `cwd` é o projeto e `tools/` não está por path relativo. Um
    `. tools/X.ps1` cru não resolve → curadoria degrada em silêncio. A cascata (rules/tooling.md)
    resolve `$toolsRoot` (relativo → $env:SDD_WORKFLOW_HOME → degradação); este lint garante que
    nenhum command volte ao path cru (regressão).

    O que é VIOLAÇÃO (error, bloqueia o CI):
      - dot-source de path literal `tools/…​.ps1`  (ex.: `. tools/kb-lint.ps1`, `. ./tools/reflect.ps1`,
        inline `` `. tools/telemetry.ps1; …` ``). Casado por âncora de dot-source (início de linha,
        backtick de code-span ou `;`) + `.` + espaço + `tools/…​.ps1`.

    O que NÃO é violação (não casa, por construção):
      - `. "$toolsRoot/X.ps1"`            → após `. ` vem `"$toolsRoot/`, não `tools/`.
      - camada de KB homônima `` `tools/` `` → não tem `.ps1` após.
      - prosa referencial ("valide com `tools/kb-lint.ps1`", "funções em `tools/x.ps1`") → o
        `tools/` não é precedido pelo operador de dot-source (`. `).

    Severidade: só `error` (alvo determinístico/binário; sem `warn`). Gate bloqueia o CI.
#>

Set-StrictMode -Version Latest

# Dot-source CRU de tools/: âncora (início de linha | backtick de code-span | ';') + '. ' +
# ('./'?) + 'tools/' + nome + '.ps1'. Single-quoted: '' = aspas simples literal; backtick literal.
$script:RxRawToolsDotSource = '(?:^|`|;)\s*\.\s+(?:\./)?tools/[^\s"''`;]*\.ps1'

function New-CommandFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-CommandLintFindings {
    <#
    .SYNOPSIS  Varre o TEXTO de um command por dot-source cru de tools/. Tag Path "$Source#L<n>".
    .OUTPUTS   [pscustomobject[]] (vazio = conforme)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return $findings.ToArray() }

    $lineNo = 0
    foreach ($line in ($Text -split "\r?\n")) {
        $lineNo++
        $m = [regex]::Matches($line, $script:RxRawToolsDotSource)
        foreach ($hit in $m) {
            $findings.Add((New-CommandFinding -Severity error -Rule raw-tools-dotsource `
                        -Path "$Source#L$lineNo" `
                        -Message "dot-source cru de tools/ ($($hit.Value.Trim())) — use a cascata `$toolsRoot (rules/tooling.md)"))
        }
    }
    return $findings.ToArray()
}

function Format-CommandLintReport {
    <# .SYNOPSIS  Painel legível dos achados, agrupado por arquivo. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'command-lint: OK (0 achados)' }

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

function Test-CommandLintGate {
    <# .SYNOPSIS  $false se houver ≥1 achado 'error' (bloqueia o CI). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-CommandLint {
    <#
    .SYNOPSIS  I/O fino: varre todos os *.md de -Dir e agrega os achados.
    .OUTPUTS   [pscustomobject[]] de achados.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)

    $all = @()
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        return @(New-CommandFinding -Severity error -Rule missing-dir -Path "$Dir#/" `
                -Message "diretório de commands inexistente")
    }

    $files = Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        try {
            $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
        }
        catch {
            $all += New-CommandFinding -Severity error -Rule unreadable -Path "$($file.Name)#/" `
                -Message "arquivo ilegível: $($_.Exception.Message)"
            continue
        }
        $all += Get-CommandLintFindings -Text $text -Source $file.Name
    }
    return @($all)
}

<#
.SYNOPSIS
    Lint de drift entre a tabela de commands do scaffold (região marcada do CLAUDE.md) e os
    arquivos reais em .claude/commands/ (idea #9 da validação E2E).

.DESCRIPTION
    Funções PURAS (recebem texto + listas, sem tocar disco) + um I/O fino que lê o CLAUDE.md e
    varre o diretório de commands. Espelha tools/command-lint.ps1 (sem módulo externo).

    Motivação: a tabela `<!-- sync-context:start:commands -->` … `:end:commands -->` do
    `templates/project-scaffold/CLAUDE.md` é mantida (idealmente regenerada por /sync-context) e
    SILENCIOSAMENTE DRIFTA dos arquivos reais — um command novo em `.claude/commands/` não aparece
    no picker documentado; um removido vira linha-fantasma. Este lint trava essa divergência no CI.

    O que é VIOLAÇÃO (error, bloqueia o CI):
      - `missing-region`     : CLAUDE.md sem os marcadores `commands` (ou fora de ordem) — nada a comparar.
      - `missing-from-table` : existe `.claude/commands/<x>.md` mas `/<x>` não está na tabela.
      - `extra-in-table`     : a tabela lista `/<x>` mas não há `.claude/commands/<x>.md`.

    O que NÃO é violação:
      - ordem das linhas / coluna de fase / texto de propósito — só o CONJUNTO de nomes importa.

    Severidade: só `error` (alvo determinístico/binário; sem `warn`). Gate bloqueia o CI.
#>

Set-StrictMode -Version Latest

# Nome de command numa linha de tabela: 1ª célula, opcionalmente entre crases (`/nome`).
# Ex.: "| `/sync-context` | — | … |" -> sync-context. Aceita letras/dígitos/hífen.
$script:RxTableCommand = '^\s*\|\s*`?/(?<name>[A-Za-z0-9][A-Za-z0-9-]*)`?\s*\|'

function Get-MarkedRegionInner {
    <#
    .SYNOPSIS  Devolve o miolo entre <!-- sync-context:start:NAME --> e :end:NAME -->, ou $null
               se ausente/fora de ordem. PURA (só texto). Espelha a semântica do Update-MarkedRegion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Name
    )
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $startMark = "<!-- sync-context:start:$Name -->"
    $endMark   = "<!-- sync-context:end:$Name -->"
    $si = $Text.IndexOf($startMark)
    $ei = $Text.IndexOf($endMark)
    if ($si -lt 0 -or $ei -lt 0 -or $ei -lt $si) { return $null }
    return $Text.Substring($si + $startMark.Length, $ei - ($si + $startMark.Length))
}

function Get-CommandTableNames {
    <#
    .SYNOPSIS  Nomes de command na tabela marcada `commands` do TEXTO (CLAUDE.md). Ordenado,
               único, sem o prefixo '/'. Vazio se a região não existir. PURA.
    .OUTPUTS   [string[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $inner = Get-MarkedRegionInner -Text $Text -Name 'commands'
    if ($null -eq $inner) { return @() }

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($inner -split "\r?\n")) {
        $m = [regex]::Match($line, $script:RxTableCommand)
        if ($m.Success) { $names.Add($m.Groups['name'].Value) }
    }
    return @($names | Sort-Object -Unique)
}

function New-CommandTableFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-CommandTableFindings {
    <#
    .SYNOPSIS  Compara o CONJUNTO de nomes da tabela (do TEXTO do CLAUDE.md) com a lista de
               nomes de arquivo de command. PURA (sem disco).
    .PARAMETER FileNames  Nomes dos commands existentes (basename sem .md), ex.: 'setup','build'.
    .OUTPUTS   [pscustomobject[]] (vazio = em dia)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$FileNames,
        [Parameter(Mandatory)][string]$Source
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    if ($null -eq (Get-MarkedRegionInner -Text $Text -Name 'commands')) {
        $findings.Add((New-CommandTableFinding -Severity error -Rule missing-region -Path "$Source#/" `
                    -Message 'região `<!-- sync-context:start:commands -->` ausente ou malformada — nada a comparar'))
        return $findings.ToArray()
    }

    $inTable = @(Get-CommandTableNames -Text $Text)
    $inFiles = @($FileNames | Sort-Object -Unique)

    foreach ($f in $inFiles) {
        if ($inTable -notcontains $f) {
            $findings.Add((New-CommandTableFinding -Severity error -Rule missing-from-table -Path "$Source#/" `
                        -Message "/$f existe em .claude/commands/ mas falta na tabela — rode /sync-context"))
        }
    }
    foreach ($t in $inTable) {
        if ($inFiles -notcontains $t) {
            $findings.Add((New-CommandTableFinding -Severity error -Rule extra-in-table -Path "$Source#/" `
                        -Message "/$t está na tabela mas não há .claude/commands/$t.md (linha-fantasma)"))
        }
    }
    return $findings.ToArray()
}

function Format-CommandTableLintReport {
    <# .SYNOPSIS  Painel legível dos achados. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'command-table-lint: OK (0 achados)' }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Findings) {
        $file = ($f.Path -split '#', 2)[0]
        $lines.Add("    [$($f.Severity)] $($f.Rule) $file — $($f.Message)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Test-CommandTableLintGate {
    <# .SYNOPSIS  $false se houver ≥1 achado 'error' (bloqueia o CI). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-CommandTableLint {
    <#
    .SYNOPSIS  I/O fino: lê o CLAUDE.md e lista os *.md de -CommandsDir; devolve os achados.
    .OUTPUTS   [pscustomobject[]] de achados.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClaudeMdPath,
        [Parameter(Mandatory)][string]$CommandsDir
    )

    if (-not (Test-Path -LiteralPath $ClaudeMdPath -PathType Leaf)) {
        return @(New-CommandTableFinding -Severity error -Rule missing-claudemd -Path "$ClaudeMdPath#/" `
                -Message 'CLAUDE.md inexistente')
    }
    if (-not (Test-Path -LiteralPath $CommandsDir -PathType Container)) {
        return @(New-CommandTableFinding -Severity error -Rule missing-dir -Path "$CommandsDir#/" `
                -Message 'diretório de commands inexistente')
    }

    try {
        $text = Get-Content -LiteralPath $ClaudeMdPath -Raw -ErrorAction Stop
    }
    catch {
        return @(New-CommandTableFinding -Severity error -Rule unreadable -Path "$ClaudeMdPath#/" `
                -Message "CLAUDE.md ilegível: $($_.Exception.Message)")
    }

    $names = @(Get-ChildItem -LiteralPath $CommandsDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.BaseName })

    return @(Get-CommandTableFindings -Text $text -FileNames $names -Source (Split-Path -Leaf $ClaudeMdPath))
}

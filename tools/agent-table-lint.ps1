<#
.SYNOPSIS
    Lint de drift + orçamento da tabela de agentes do `rules/agent-routing.md` (o irmão que faltava
    do tools/command-table-lint.ps1).

.DESCRIPTION
    Funções PURAS (texto + lista de nomes, sem tocar disco) + um I/O fino. Espelha
    `command-table-lint.ps1` deliberadamente: mesma família de defeito, mesma forma de achado.

    Motivação, medida em 2026-08-16: a tabela `## Catálogo genérico` de
    `templates/project-scaffold/.claude/rules/agent-routing.md` é escrita À MÃO, é always-on
    (a rule inteira carrega em toda sessão) e NÃO tinha lint nenhum — enquanto a tabela irmã de
    commands, no CLAUDE.md, já tinha. Duas consequências observadas no arquivo real:

      1. A coluna "Quando usar" REESCREVIA o `description` do frontmatter de cada agente — que o
         harness JÁ injeta (2 105 tok medidos em descritores de agents). 1 568 b dos 2 561 b da
         seção (61%) eram a segunda cópia da mesma superfície. É o mesmo defeito que o
         `SURFACE_REDUCTION` achou na tabela de commands, no arquivo vizinho.
      2. O único dado que a tabela tinha e o `description` NÃO dava — o wiring "usado pelo /review
         e ao fim do /build" — estava FALSO: nenhum dos dois commands menciona `code-reviewer`
         (grep). Quem de fato o invoca é /doubt, /iterate e /orchestrate. Wiring escrito à mão numa
         tabela que nada mede vira mentira em silêncio; por isso este lint trava o CONJUNTO de nomes
         e o ORÇAMENTO, e o wiring saiu da tabela em vez de ganhar uma regra que o vigiasse.

    O que é VIOLAÇÃO (error, bloqueia o CI):
      - `missing-table`      : a rule não tem tabela de catálogo reconhecível — nada a comparar.
      - `missing-from-table` : existe `.claude/agents/<x>.md` mas `<x>` não está na tabela.
      - `extra-in-table`     : a tabela lista `<x>` mas não há `.claude/agents/<x>.md` (linha-fantasma).

    O que é AVISO (warn, NÃO bloqueia):
      - `table-row-too-long` : a célula "Quando usar" passa do orçamento de ~12 palavras. Warn e não
        error pela MESMA razão do lint irmão: o orçamento é aproximado e reprovar por uma palavra
        seria arbitrário. O aviso existe porque reescrever a célula "caprichado" restaura a
        duplicação em silêncio — foi exatamente o que estava no arquivo (7 das 11 linhas acima do
        orçamento, `git-workflow` com 34 palavras).

    DIFERENÇA de forma em relação ao lint irmão, e ela é deliberada: lá a célula de propósito é a
    ÚLTIMA da linha; aqui a última é `Modo` (read-only / escreve+roda / outward), que é dado próprio
    do framework e NÃO entra no orçamento. A célula medida é a TERCEIRA (nome | role | quando usar |
    modo). Linha com menos de 4 células não é medida.

    O que NÃO é violação: ordem das linhas, conteúdo do `role`, conteúdo do `Modo`.
#>

Set-StrictMode -Version Latest

# Linha de agente na tabela: 1ª célula com o nome entre crases. Ex.: "| `explorer` | search | … | … |"
$script:RxAgentRow = '^\s*\|\s*`(?<name>[a-z][a-z0-9-]*)`\s*\|'

function Get-AgentTableRow {
    <#
    .SYNOPSIS  Linhas de agente da tabela do TEXTO: nome + nº de palavras da célula "Quando usar".
               PURA (só texto).
    .OUTPUTS   [pscustomobject[]] com Name e Words
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ($Text -split "\r?\n")) {
        $m = [regex]::Match($line, $script:RxAgentRow)
        if (-not $m.Success) { continue }
        $cells = @($line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        # 4 colunas: nome | role | quando usar | modo. A 3ª é a única orçada.
        $quando = if ($cells.Count -ge 4) { $cells[2] } else { '' }
        $words = @($quando -split '\s+' | Where-Object { $_ }).Count
        $rows.Add([pscustomobject]@{ Name = $m.Groups['name'].Value; Words = $words })
    }
    return $rows.ToArray()
}

function Get-AgentTableNames {
    <# .SYNOPSIS  Conjunto de nomes de agente da tabela do TEXTO. Ordenado, único. PURA. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return @(Get-AgentTableRow -Text $Text | ForEach-Object { $_.Name } | Sort-Object -Unique)
}

function New-AgentTableFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-AgentTableFindings {
    <#
    .SYNOPSIS  Compara o CONJUNTO de nomes da tabela com os arquivos de agente, e mede o orçamento
               de cada linha. PURA (sem disco).
    .PARAMETER FileNames  Basenames dos agentes existentes (sem .md), ex.: 'explorer','debugger'.
    .OUTPUTS   [pscustomobject[]] (vazio = em dia)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$FileNames,
        [Parameter(Mandatory)][string]$Source,
        [int]$MaxWords = 12
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $rows = @(Get-AgentTableRow -Text $Text)

    if ($rows.Count -eq 0) {
        $findings.Add((New-AgentTableFinding -Severity error -Rule missing-table -Path "$Source#/" `
                    -Message 'nenhuma linha de agente reconhecida na rule — a tabela do catálogo sumiu ou mudou de forma'))
        return $findings.ToArray()
    }

    $inTable = @($rows | ForEach-Object { $_.Name } | Sort-Object -Unique)
    $inFiles = @($FileNames | Sort-Object -Unique)

    foreach ($f in $inFiles) {
        if ($inTable -notcontains $f) {
            $findings.Add((New-AgentTableFinding -Severity error -Rule missing-from-table -Path "$Source#/" `
                        -Message "$f existe em .claude/agents/ mas falta na tabela do agent-routing.md — quem roteia nao vai saber que ele existe"))
        }
    }
    foreach ($t in $inTable) {
        if ($inFiles -notcontains $t) {
            $findings.Add((New-AgentTableFinding -Severity error -Rule extra-in-table -Path "$Source#/" `
                        -Message "$t esta na tabela mas nao ha .claude/agents/$t.md (linha-fantasma) — o lider vai delegar para um agente que nao existe"))
        }
    }
    foreach ($row in $rows) {
        if ($row.Words -le $MaxWords) { continue }
        $findings.Add((New-AgentTableFinding -Severity warn -Rule table-row-too-long -Path "$Source#/" `
                    -Message "$($row.Name): $($row.Words) palavras (orcamento ~$MaxWords) — a rule e always-on e o harness ja injeta a description; a celula carrega a fronteira com o vizinho, nao a description de novo"))
    }
    return $findings.ToArray()
}

function Format-AgentTableLintReport {
    <# .SYNOPSIS  Painel legível dos achados. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'agent-table-lint: OK (0 achados)' }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Findings) {
        $file = ($f.Path -split '#', 2)[0]
        $lines.Add("    [$($f.Severity)] $($f.Rule) $file — $($f.Message)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Test-AgentTableLintGate {
    <# .SYNOPSIS  $false se houver >=1 achado 'error' (bloqueia o CI). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-AgentTableLint {
    <#
    .SYNOPSIS  I/O fino: lê a rule e lista os *.md de -AgentsDir; devolve os achados.
    .OUTPUTS   [pscustomobject[]] de achados.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RulePath,
        [Parameter(Mandatory)][string]$AgentsDir
    )

    if (-not (Test-Path -LiteralPath $RulePath -PathType Leaf)) {
        return @(New-AgentTableFinding -Severity error -Rule missing-rule -Path "$RulePath#/" `
                -Message 'agent-routing.md inexistente')
    }
    if (-not (Test-Path -LiteralPath $AgentsDir -PathType Container)) {
        return @(New-AgentTableFinding -Severity error -Rule missing-dir -Path "$AgentsDir#/" `
                -Message 'diretorio de agents inexistente')
    }

    try {
        $text = Get-Content -LiteralPath $RulePath -Raw -ErrorAction Stop
    }
    catch {
        return @(New-AgentTableFinding -Severity error -Rule unreadable -Path "$RulePath#/" `
                -Message "agent-routing.md ilegivel: $($_.Exception.Message)")
    }

    # Mesma exclusão do Get-AgentInventory: o AGENT_MAP.md é derivado e auxiliares começam com '_'.
    $names = @(Get-ChildItem -LiteralPath $AgentsDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'AGENT_MAP.md' -and -not $_.Name.StartsWith('_') } |
            ForEach-Object { $_.BaseName })

    return @(Get-AgentTableFindings -Text $text -FileNames $names -Source (Split-Path -Leaf $RulePath))
}

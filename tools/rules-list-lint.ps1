<#
.SYNOPSIS
    Lint de drift entre a lista de rules do AGENTS.md (regiao marcada) e os arquivos reais de
    .claude/rules/.

.DESCRIPTION
    Funcoes PURAS (texto + listas, sem tocar disco) + um I/O fino. Mesmo molde do
    tools/command-table-lint.ps1 -- e existe pela MESMA razao, num bloco que ninguem vigiava.

    POR QUE EXISTE (o dano que o motivou, 2026-08-22): a lista
    `<!-- sync-context:start:rules -->` do `templates/project-scaffold/AGENTS.md` estava com
    10 de 12 rules -- faltavam `documentation.md` e `orchestration.md`. No Claude Code isso e'
    inofensivo (o diretorio inteiro auto-carrega e a lista e' decorativa); em Codex e Antigravity
    a lista E' O MECANISMO, porque nenhum dos dois varre `.claude/rules/`. O proprio
    `/sync-context` diz isso: "o sumario existe para os harnesses que NAO auto-carregam
    .claude/rules/". Uma das rules invisiveis era a `orchestration.md`, que carrega o gate de
    regime.

    O drift durou porque o bloco nao tinha mecanismo: `AGENT_MAP.md`, `graph.json` e
    `_index.yaml` sao regenerados por `Invoke-Resync` e travados pelo `resync-lint`; este bloco e'
    preenchido pelo AGENTE, por instrucao em prosa no command. Regra sem mecanismo.

    NAO regenera o bloco de proposito: a descricao de uma linha por rule e' redacao humana, e um
    gerador so' saberia repetir o titulo. O lint verifica COBERTURA (o conjunto de nomes), que e'
    o que drifta, e deixa a redacao para quem escreve.

    O que e' VIOLACAO (error, bloqueia o CI):
      - missing-region     : AGENTS.md sem os marcadores `rules` (ou fora de ordem).
      - missing-from-list  : existe .claude/rules/<x>.md mas <x>.md nao esta na lista.
      - extra-in-list      : a lista cita <x>.md mas nao ha .claude/rules/<x>.md.

    O que e' AVISO (warn, NAO bloqueia):
      - list-row-too-long  : a descricao passa do orcamento de ~12 palavras que o /sync-context
        prescreve. Warn e nao error pelo mesmo argumento do command-table-lint: "~12" e'
        aproximado, e reprovar por uma palavra seria arbitrario.

    O que NAO e' violacao: ordem das linhas, e o texto da descricao.
#>

Set-StrictMode -Version Latest

# Linha de rule na lista: "- [`nome.md`](.claude/rules/nome.md) - descricao".
# O nome canonico e' o do LINK (o alvo real), nao o do rotulo -- rotulo errado vira extra-in-list.
$script:RxRuleListItem = '^\s*-\s*\[`?(?<label>[^\]`]+?)`?\]\((?<target>[^)]*rules/(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)\.md)\)'

function Get-MarkedRegionInner {
    <# .SYNOPSIS  Miolo entre <!-- sync-context:start:NAME --> e :end:NAME -->, ou $null. PURA. #>
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

function Get-RulesListNames {
    <# .SYNOPSIS  Nomes de rule (basename sem .md) citados na regiao `rules`. Ordenado, unico. PURA.
       .OUTPUTS   [string[]] #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $inner = Get-MarkedRegionInner -Text $Text -Name 'rules'
    if ($null -eq $inner) { return @() }

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($inner -split "\r?\n")) {
        $m = [regex]::Match($line, $script:RxRuleListItem)
        if ($m.Success) { $names.Add($m.Groups['name'].Value) }
    }
    return @($names | Sort-Object -Unique)
}

function Get-RulesListRowBudget {
    <# .SYNOPSIS  Por linha de rule: nome + numero de palavras da descricao (o que vem depois do
       travessao). Sem travessao = 0 palavras, e nao vira achado. PURA.
       .OUTPUTS   [pscustomobject[]] com Name e Words #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $inner = Get-MarkedRegionInner -Text $Text -Name 'rules'
    if ($null -eq $inner) { return @() }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ($inner -split "\r?\n")) {
        $m = [regex]::Match($line, $script:RxRuleListItem)
        if (-not $m.Success) { continue }
        # Travessao em dash (U+2014) ou hifen cercado de espacos -- aceita as duas grafias.
        $desc = ''
        $dm = [regex]::Match($line, '(?:—|\s-\s)\s*(?<d>.+)$')
        if ($dm.Success) { $desc = $dm.Groups['d'].Value }
        $words = @($desc -split '\s+' | Where-Object { $_ }).Count
        $rows.Add([pscustomobject]@{ Name = $m.Groups['name'].Value; Words = $words })
    }
    return $rows.ToArray()
}

function New-RulesListFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-RulesListFindings {
    <# .SYNOPSIS  Compara o CONJUNTO de nomes da lista com os arquivos de rule. PURA (sem disco).
       .PARAMETER FileNames  basenames sem .md, ex.: 'workflow-sdd','tooling'.
       .OUTPUTS   [pscustomobject[]] (vazio = em dia) #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$FileNames,
        [Parameter(Mandatory)][string]$Source,
        [int]$MaxWords = 12
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    if ($null -eq (Get-MarkedRegionInner -Text $Text -Name 'rules')) {
        $findings.Add((New-RulesListFinding -Severity error -Rule missing-region -Path "$Source#/" `
                    -Message 'regiao `<!-- sync-context:start:rules -->` ausente ou malformada -- nada a comparar'))
        return $findings.ToArray()
    }

    $inList  = @(Get-RulesListNames -Text $Text)
    $inFiles = @($FileNames | Sort-Object -Unique)

    foreach ($f in $inFiles) {
        if ($inList -notcontains $f) {
            $findings.Add((New-RulesListFinding -Severity error -Rule missing-from-list -Path "$Source#/" `
                        -Message "$f.md existe em .claude/rules/ mas falta na lista -- em Codex/Antigravity essa rule fica INVISIVEL (eles nao varrem o diretorio); rode /sync-context"))
        }
    }
    foreach ($t in $inList) {
        if ($inFiles -notcontains $t) {
            $findings.Add((New-RulesListFinding -Severity error -Rule extra-in-list -Path "$Source#/" `
                        -Message "$t.md esta na lista mas nao ha .claude/rules/$t.md (linha-fantasma)"))
        }
    }
    foreach ($row in (Get-RulesListRowBudget -Text $Text)) {
        if ($row.Words -le $MaxWords) { continue }
        $findings.Add((New-RulesListFinding -Severity warn -Rule list-row-too-long -Path "$Source#/" `
                    -Message "$($row.Name): $($row.Words) palavras (orcamento ~$MaxWords) -- a lista e' always-on; encurte em vez de caprichar"))
    }
    return $findings.ToArray()
}

function Format-RulesListLintReport {
    <# .SYNOPSIS  Painel legivel dos achados. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'rules-list-lint: OK (0 achados)' }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Findings) {
        $file = ($f.Path -split '#', 2)[0]
        $lines.Add("    [$($f.Severity)] $($f.Rule) $file -- $($f.Message)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Test-RulesListLintGate {
    <# .SYNOPSIS  $false se houver pelo menos 1 achado 'error' (bloqueia o CI). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-RulesListLint {
    <# .SYNOPSIS  I/O fino: le o AGENTS.md e lista os *.md de -RulesDir; devolve os achados.
       .OUTPUTS   [pscustomobject[]] de achados. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AgentsMdPath,
        [Parameter(Mandatory)][string]$RulesDir
    )

    if (-not (Test-Path -LiteralPath $AgentsMdPath -PathType Leaf)) {
        return @(New-RulesListFinding -Severity error -Rule missing-agentsmd -Path "$AgentsMdPath#/" `
                -Message 'AGENTS.md inexistente')
    }
    if (-not (Test-Path -LiteralPath $RulesDir -PathType Container)) {
        return @(New-RulesListFinding -Severity error -Rule missing-dir -Path "$RulesDir#/" `
                -Message 'diretorio de rules inexistente')
    }

    try {
        $text = Get-Content -LiteralPath $AgentsMdPath -Raw -ErrorAction Stop
    }
    catch {
        return @(New-RulesListFinding -Severity error -Rule unreadable -Path "$AgentsMdPath#/" `
                -Message "AGENTS.md ilegivel: $($_.Exception.Message)")
    }

    $names = @(Get-ChildItem -LiteralPath $RulesDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.BaseName })

    return @(Get-RulesListFindings -Text $text -FileNames $names -Source (Split-Path -Leaf $AgentsMdPath))
}

<#
.SYNOPSIS
    Export do grafo de agentes (property-graph) — "estilo neo4j, SEM rodar neo4j" (H4, export-first).

.DESCRIPTION
    Lê os metadados relacionais que JÁ existem (role + connects_to do B9) dos agentes em
    .claude/agents/**.md e emite duas representações portáveis do mesmo property-graph:
      - graph.json   : nós + arestas p/ consulta/visualização sem dependência externa
      - graph.cypher : dump CREATE p/ importar no neo4j QUANDO o volume justificar (gatilho H4)

    Reusa o parser do agent-lint (Read-AgentFrontmatter, ConvertFrom-InlineList) — zero parser novo,
    zero módulo YAML. Funções puras + um driver de I/O fino (molde reflect.ps1 → kb-lint).
    Modelo nó/aresta idêntico ao do neo4j (label :Agent, propriedades, relação :CONNECTS_TO), então
    o "rodar neo4j" depois é só `cypher-shell < graph.cypher` — o servidor entra quando fizer sentido.
#>

Set-StrictMode -Version Latest

# Reusa o parser de frontmatter/array do agent-lint (biblioteca, sem auto-run).
. (Join-Path $PSScriptRoot 'agent-lint.ps1')

function Get-AgentGraph {
    <#
    .SYNOPSIS  Constrói (puro) o property-graph dos agentes de um diretório.
    .OUTPUTS   [pscustomobject] @{ Nodes = [pscustomobject[]]; Edges = [pscustomobject[]] }
               Node = @{ Id; Type='Agent'; Role; Description }
               Edge = @{ From; To; Type='CONNECTS_TO' }   (ordenados p/ determinismo)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        return [pscustomobject]@{ Nodes = @(); Edges = @() }
    }

    $nodes = [System.Collections.Generic.List[object]]::new()
    $edges = [System.Collections.Generic.List[object]]::new()

    # Só agentes: ignora o mapa (AGENT_MAP.md) e auxiliares (_*.md) — mesma regra do Get-AgentInventory.
    $files = Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'AGENT_MAP.md' -and -not $_.Name.StartsWith('_') }

    foreach ($f in $files) {
        $fm = Read-AgentFrontmatter -Path $f.FullName
        if ($null -eq $fm) { continue }
        $name = if ($fm.Contains('name')) { $fm['name'] } else { $null }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $role = if ($fm.Contains('role')) { [string]$fm['role'] } else { '' }
        $desc = if ($fm.Contains('description')) { [string]$fm['description'] } else { '' }
        $nodes.Add([pscustomobject]@{ Id = $name; Type = 'Agent'; Role = $role; Description = $desc })

        if ($fm.Contains('connects_to')) {
            foreach ($t in (ConvertFrom-InlineList -Value $fm['connects_to'])) {
                $edges.Add([pscustomobject]@{ From = $name; To = $t; Type = 'CONNECTS_TO' })
            }
        }
    }

    return [pscustomobject]@{
        Nodes = @($nodes | Sort-Object Id)
        Edges = @($edges | Sort-Object From, To)
    }
}

function ConvertTo-GraphJson {
    <#
    .SYNOPSIS  Serializa o grafo como JSON (property-graph portável).
    .OUTPUTS   [string]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Graph)
    return ($Graph | ConvertTo-Json -Depth 6)
}

function ConvertTo-GraphCypher {
    <#
    .SYNOPSIS  Serializa o grafo como dump Cypher (CREATE de nós + arestas) p/ neo4j.
    .OUTPUTS   [string]  (uma instrução por linha; aspas simples escapadas)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Graph)

    $esc = { param($s) ([string]$s).Replace('\', '\\').Replace("'", "\'") }
    $out = [System.Collections.Generic.List[string]]::new()

    foreach ($n in @($Graph.Nodes)) {
        $id = & $esc $n.Id; $role = & $esc $n.Role; $desc = & $esc $n.Description
        $out.Add("CREATE (:Agent {name: '$id', role: '$role', description: '$desc'});")
    }
    foreach ($e in @($Graph.Edges)) {
        $from = & $esc $e.From; $to = & $esc $e.To
        $out.Add("MATCH (a:Agent {name: '$from'}), (b:Agent {name: '$to'}) CREATE (a)-[:$($e.Type)]->(b);")
    }
    return ($out -join "`n")
}

function Invoke-GraphExport {
    <#
    .SYNOPSIS  I/O fino: lê os agentes, gera graph.json + graph.cypher no destino.
    .OUTPUTS   [pscustomobject] @{ Graph; JsonPath; CypherPath }
    #>
    [CmdletBinding()]
    param(
        [string]$Dir = (Join-Path '.claude' 'agents'),
        [string]$OutDir = '',
        [switch]$DryRun
    )

    if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = $Dir }
    $graph      = Get-AgentGraph -Dir $Dir
    $jsonPath   = Join-Path $OutDir 'graph.json'
    $cypherPath = Join-Path $OutDir 'graph.cypher'
    $nCount     = @($graph.Nodes).Count
    $eCount     = @($graph.Edges).Count

    if ($DryRun) {
        Write-Host "[DRY] $jsonPath + $cypherPath ($nCount nós, $eCount arestas)"
        return [pscustomobject]@{ Graph = $graph; JsonPath = $jsonPath; CypherPath = $cypherPath }
    }

    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($jsonPath, (ConvertTo-GraphJson -Graph $graph), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($cypherPath, (ConvertTo-GraphCypher -Graph $graph), [System.Text.UTF8Encoding]::new($false))
    Write-Host "graph.json + graph.cypher gerados: $nCount nós, $eCount arestas"
    return [pscustomobject]@{ Graph = $graph; JsonPath = $jsonPath; CypherPath = $cypherPath }
}

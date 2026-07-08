<#
.SYNOPSIS
    Export do grafo de agentes (property-graph) — "estilo neo4j, SEM rodar neo4j" (H4, export-first).

.DESCRIPTION
    Lê os metadados relacionais que JÁ existem (role + connects_to do B9) dos agentes em
    .claude/agents/**.md e emite duas representações portáveis do mesmo property-graph:
      - graph.json   : nós + arestas p/ consulta/visualização sem dependência externa
      - graph.cypher : dump idempotente (CONSTRAINT + MERGE) p/ importar no neo4j QUANDO o volume justificar (gatilho H4)

    Reusa o parser do agent-lint (Read-AgentFrontmatter, ConvertFrom-InlineList) — zero parser novo,
    zero módulo YAML. Funções puras + um driver de I/O fino (molde reflect.ps1 → kb-lint).
    Modelo nó/aresta idêntico ao do neo4j (label :Agent, propriedades, relação :CONNECTS_TO), então
    o "rodar neo4j" depois é só `cypher-shell < graph.cypher` — o servidor entra quando fizer sentido.
#>

Set-StrictMode -Version Latest

# Reusa parsers/inventários que JÁ existem (bibliotecas, sem auto-run — os Tests.ps1 já as dot-sourceiam).
# D-005: ordem fixa; nenhum auto-run no carregamento; colisão de nome coberta por smoke no Pester.
. (Join-Path $PSScriptRoot 'agent-lint.ps1')     # Read-AgentFrontmatter, ConvertFrom-InlineList, New-AgentFinding
. (Join-Path $PSScriptRoot 'kb-lint.ps1')        # Read-KbFrontmatter
. (Join-Path $PSScriptRoot 'update-skills.ps1')  # Get-SkillInventory
. (Join-Path $PSScriptRoot 'skill-gap.ps1')      # Get-DeclaredSkills

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

function Get-HubGraph {
    <#
    .SYNOPSIS  Grafo dos agentes + o HUB (modo MAX) como nó de 1ª classe (H7, contrato de hub).
    .DESCRIPTION
        Estende Get-AgentGraph com:
          - um nó :Hub (Id=$HubId) — o orquestrador-mestre do modo MAX;
          - uma aresta DEDICADA :ORCHESTRATES do hub p/ CADA agente (distinta do peer :CONNECTS_TO).
        Esse é o "contrato de hub exclusivo": qualquer agente que seja nó válido do grafo
        (role + connects_to, o que o agent-lint exige) AUTO-ADERE — a aresta é gerada p/ ele
        sem editar lista. Adicionar um agente (base ou de domínio via /audit-agents) = o hub o
        alcança. Base pronta p/ o neo4j (H4): o nó :Hub + :ORCHESTRATES exportam p/ graph.cypher.
    .OUTPUTS   [pscustomobject] @{ Nodes; Edges }  (mesmo formato de Get-AgentGraph)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string]$HubId = 'max'
    )

    $base  = Get-AgentGraph -Dir $Dir
    $nodes = [System.Collections.Generic.List[object]]::new()
    $edges = [System.Collections.Generic.List[object]]::new()

    # Hub como nó de 1ª classe (label :Hub, distinto de :Agent).
    $nodes.Add([pscustomobject]@{ Id = $HubId; Type = 'Hub'; Role = 'orchestrator-hub'; Description = 'Modo MAX — hub orquestrador-mestre do grafo de agentes (H7)' })

    foreach ($n in @($base.Nodes)) {
        $nodes.Add($n)
        # Aresta dedicada hub -> agente (não liga o hub a si mesmo se houver colisão de nome).
        if ($n.Id -ne $HubId) {
            $edges.Add([pscustomobject]@{ From = $HubId; To = $n.Id; Type = 'ORCHESTRATES' })
        }
    }
    # Preserva as arestas peer :CONNECTS_TO entre experts.
    foreach ($e in @($base.Edges)) { $edges.Add($e) }

    return [pscustomobject]@{
        Nodes = @($nodes | Sort-Object Id)
        Edges = @($edges | Sort-Object From, To, Type)
    }
}

function Test-HubReachability {
    <#
    .SYNOPSIS  Verifica (puro) que o hub alcança TODOS os agentes do grafo (0 órfão).
    .OUTPUTS   [pscustomobject] @{ Reached=[string[]]; Orphans=[string[]] }
               Orphans = agentes :Agent SEM aresta :ORCHESTRATES vinda do hub. Deve ser @().
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Graph,
        [string]$HubId = 'max'
    )
    $agents = @(@($Graph.Nodes) | Where-Object { $_.Type -eq 'Agent' } | ForEach-Object { $_.Id })
    $reachedTo = @(@($Graph.Edges) |
        Where-Object { $_.From -eq $HubId -and $_.Type -eq 'ORCHESTRATES' } |
        ForEach-Object { $_.To })

    return [pscustomobject]@{
        Reached = @($agents | Where-Object { $_ -in $reachedTo } | Sort-Object)
        Orphans = @($agents | Where-Object { $_ -notin $reachedTo } | Sort-Object)
    }
}

function ConvertTo-GraphJson {
    <#
    .SYNOPSIS  Serializa o grafo como JSON (property-graph portável).
    .OUTPUTS   [string]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Graph)
    # Normaliza p/ LF: ConvertTo-Json emite CRLF no Windows; o artefato é portável (.gitattributes
    # força *.json eol=lf) e precisa ser idempotente sob /sync-context (git diff vazio na 2ª passada).
    return (($Graph | ConvertTo-Json -Depth 6) -replace "`r`n", "`n")
}

function ConvertTo-GraphCypher {
    <#
    .SYNOPSIS  Serializa o grafo como dump Cypher IDEMPOTENTE (CONSTRAINT IF NOT EXISTS + MERGE + SET) p/ neo4j.
    .DESCRIPTION
        Carga re-executável (`cypher-shell < graph.cypher` 2× não duplica), alinhada à doc atual do Cypher:
        (1) uma uniqueness constraint por label (acelera o MATCH/MERGE e garante identidade);
        (2) nós via MERGE pela identidade (name) + SET das propriedades;
        (3) arestas via MERGE (MATCH agnóstico de label por name).
    .OUTPUTS   [string]  (uma instrução por linha; aspas simples escapadas)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Graph)

    $esc = { param($s) ([string]$s).Replace('\', '\\').Replace("'", "\'") }
    $out = [System.Collections.Generic.List[string]]::new()

    # (1) Constraints de unicidade por label (IF NOT EXISTS = idempotente). Ordem estável por label.
    foreach ($t in @(@($Graph.Nodes).Type | Sort-Object -Unique)) {
        $out.Add("CREATE CONSTRAINT node_$($t.ToLowerInvariant())_name IF NOT EXISTS FOR (n:$t) REQUIRE n.name IS UNIQUE;")
    }

    # (2) Nós: MERGE pela identidade (name) — re-rodar não duplica; SET aplica role/description/extras.
    foreach ($n in @($Graph.Nodes)) {
        # Label = Type do nó (Agent | Hub | KbEntry | Skill | Domain | Feature). role/description SEMPRE
        # no SET; props extras (Layer/Domain/ContentType/Status/Scope…) em ordem de definição, só não-vazias.
        $sets = [System.Collections.Generic.List[string]]::new()
        $sets.Add("n.role = '$(& $esc $n.Role)'")
        $sets.Add("n.description = '$(& $esc $n.Description)'")
        foreach ($p in $n.PSObject.Properties) {
            if ($p.Name -in @('Id', 'Type', 'Role', 'Description')) { continue }
            if ([string]::IsNullOrEmpty([string]$p.Value)) { continue }
            $sets.Add("n.$($p.Name.ToLowerInvariant()) = '$(& $esc $p.Value)'")
        }
        $out.Add("MERGE (n:$($n.Type) {name: '$(& $esc $n.Id)'}) SET $($sets -join ', ');")
    }
    # (3) Arestas: MATCH agnóstico de label (por name) p/ casar :Agent e :Hub; MERGE não duplica a aresta.
    foreach ($e in @($Graph.Edges)) {
        $from = & $esc $e.From; $to = & $esc $e.To
        $out.Add("MATCH (a {name: '$from'}), (b {name: '$to'}) MERGE (a)-[:$($e.Type)]->(b);")
    }
    return ($out -join "`n")
}

function ConvertTo-GraphHtml {
    <#
    .SYNOPSIS  "Ver o cérebro" SEM servidor (H9): grafo → HTML interativo self-contained (vis-network CDN).
    .DESCRIPTION
        Renderiza o property-graph como página HTML única (arrastar/zoom/clicar; cor por tipo de nó;
        rótulo por tipo de aresta). É a alternativa ao neo4j: nenhum serviço, só um arquivo que abre no
        navegador. Endpoints de aresta sem nó (ref cruzada de KB dangling) viram nó 'Unknown' (honesto).
    .OUTPUTS   [string]  (HTML; LF)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Graph, [string]$Title = 'Grafo do projeto')

    $color = @{
        Agent = '#4f86f7'; KbEntry = '#37b24d'; Skill = '#f08c00'; Domain = '#ae3ec9'
        Feature = '#868e96'; Hub = '#e8590c'; Unknown = '#fa5252'
    }
    $seen = @{}
    $visNodes = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @($Graph.Nodes)) {
        $seen[$n.Id] = $true
        $extra = (@($n.PSObject.Properties | Where-Object { $_.Name -notin @('Id', 'Role', 'Description') -and -not [string]::IsNullOrEmpty([string]$_.Value) } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' · ')
        $visNodes.Add([ordered]@{ id = [string]$n.Id; label = [string]$n.Id; group = [string]$n.Type; title = "$($n.Type): $($n.Id)`n$extra" })
    }
    foreach ($e in @($Graph.Edges)) {
        foreach ($ep in @([string]$e.From, [string]$e.To)) {
            if (-not $seen.ContainsKey($ep)) {
                $seen[$ep] = $true
                $visNodes.Add([ordered]@{ id = $ep; label = $ep; group = 'Unknown'; title = "ref sem nó (higiene da KB)" })
            }
        }
    }
    $visEdges = @($Graph.Edges | ForEach-Object { [ordered]@{ from = [string]$_.From; to = [string]$_.To; label = [string]$_.Type } })

    $toJsonArray = {
        param($items)
        $j = (@($items) | ConvertTo-Json -Depth 4 -Compress)
        if ([string]::IsNullOrWhiteSpace($j)) { return '[]' }
        if (-not $j.StartsWith('[')) { return "[$j]" }   # ConvertTo-Json desfaz array de 1 item
        return $j
    }
    $nodesJson  = & $toJsonArray $visNodes
    $edgesJson  = & $toJsonArray $visEdges
    $groupsJson = (($color.GetEnumerator() | Sort-Object Key | ForEach-Object { "`"$($_.Key)`":{color:{background:'$($_.Value)',border:'#333'},font:{color:'#fff'}}" }) -join ',')

    $tpl = @'
<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8">
<title>__TITLE__</title>
<script src="https://unpkg.com/vis-network@9/standalone/umd/vis-network.min.js"></script>
<style>
  body{margin:0;font-family:system-ui,Segoe UI,sans-serif;background:#1a1b1e;color:#e9ecef}
  #bar{padding:8px 14px;border-bottom:1px solid #333;font-size:13px}
  #bar b{color:#fff} .leg{display:inline-block;margin-left:12px}
  .dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:4px;vertical-align:middle}
  #net{width:100vw;height:calc(100vh - 40px)}
</style></head><body>
<div id="bar"><b>__TITLE__</b> — __NCOUNT__ nós · __ECOUNT__ arestas. Arraste/zoom/clique. <span id="legend"></span></div>
<div id="net"></div>
<script>
  const groups = {__GROUPS__};
  const nodes = new vis.DataSet(__NODES__);
  const edges = new vis.DataSet(__EDGES__);
  new vis.Network(document.getElementById('net'), {nodes,edges}, {
    groups, nodes:{shape:'dot',size:16,font:{color:'#e9ecef',size:13}},
    edges:{arrows:'to',color:{color:'#555',highlight:'#fff'},font:{color:'#adb5bd',size:10,strokeWidth:0},smooth:{type:'continuous'}},
    physics:{stabilization:true,barnesHut:{springLength:140}}, interaction:{hover:true}
  });
  document.getElementById('legend').innerHTML = Object.entries(groups)
    .map(([k,v])=>`<span class="leg"><span class="dot" style="background:${v.color.background}"></span>${k}</span>`).join('');
</script></body></html>
'@
    $html = $tpl.Replace('__TITLE__', $Title).Replace('__GROUPS__', $groupsJson).Replace('__NODES__', $nodesJson).Replace('__EDGES__', $edgesJson).Replace('__NCOUNT__', [string]@($Graph.Nodes).Count).Replace('__ECOUNT__', [string]@($Graph.Edges).Count)
    return ($html -replace "`r`n", "`n")
}

function Get-KbGraph {
    <#
    .SYNOPSIS  Property-graph (puro) das entradas de KB — a "base do cérebro" (H9, Base 1).
    .DESCRIPTION
        Reusa Read-KbFrontmatter (kb-lint) — zero parser novo. Nós :KbEntry (id/layer/domain/
        content_type/status) + arestas :RELATED_TO (related), :CONSOLIDATES, :SUPERSEDES,
        :PROMOTED_FROM (→ :Feature), :IN_DOMAIN (→ :Domain). Ignora auxiliares _*.md.
    .OUTPUTS   [pscustomobject] @{ Nodes; Edges }  (ordenados, determinístico)
    #>
    [CmdletBinding()]
    param([string]$Dir = (Join-Path '.claude' 'kb'))

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        return [pscustomobject]@{ Nodes = @(); Edges = @() }
    }
    $nodes = [System.Collections.Generic.List[object]]::new()
    $edges = [System.Collections.Generic.List[object]]::new()

    $files = Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Name.StartsWith('_') }

    foreach ($f in $files) {
        $fm = Read-KbFrontmatter -Path $f.FullName
        if ($null -eq $fm) { continue }
        $id = if ($fm.Contains('id')) { [string]$fm['id'] } else { $null }
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $domain = if ($fm.Contains('domain')) { [string]$fm['domain'] } else { '' }
        $nodes.Add([pscustomobject]@{
                Id          = $id
                Type        = 'KbEntry'
                Role        = ''
                Description = ''
                Layer       = if ($fm.Contains('layer')) { [string]$fm['layer'] } else { '' }
                Domain      = $domain
                ContentType = if ($fm.Contains('content_type')) { [string]$fm['content_type'] } else { '' }
                Status      = if ($fm.Contains('status')) { [string]$fm['status'] } else { '' }
            })

        if (-not [string]::IsNullOrWhiteSpace($domain)) {
            $edges.Add([pscustomobject]@{ From = $id; To = $domain; Type = 'IN_DOMAIN' })
        }
        foreach ($map in @(
                @{ Key = 'related'; Edge = 'RELATED_TO' },
                @{ Key = 'consolidates'; Edge = 'CONSOLIDATES' },
                @{ Key = 'supersedes'; Edge = 'SUPERSEDES' },
                @{ Key = 'promoted_from'; Edge = 'PROMOTED_FROM' }
            )) {
            if ($fm.Contains($map.Key)) {
                foreach ($t in (ConvertFrom-InlineList -Value $fm[$map.Key])) {
                    $edges.Add([pscustomobject]@{ From = $id; To = $t; Type = $map.Edge })
                }
            }
        }
    }
    return [pscustomobject]@{
        Nodes = @($nodes | Sort-Object Id)
        Edges = @($edges | Sort-Object From, To, Type)
    }
}

function Get-SkillGraph {
    <#
    .SYNOPSIS  Property-graph (puro) das skills (H9, Base 2). Nós :Skill + arestas :PRESUPPOSES.
    .DESCRIPTION
        Reusa Get-SkillInventory (I1) e Get-DeclaredSkills (skill-gap). Default = project-scope
        (determinístico/portável p/ o artefato commitado); -IncludeGlobal soma ~/.claude/skills
        (visão local, NÃO versionar). Skill pressuposta por onda mas ausente do inventário vira nó
        :Skill status='needed' (torna o gap visível, sem dangling).
    .OUTPUTS   [pscustomobject] @{ Nodes; Edges }
    #>
    [CmdletBinding()]
    param(
        [string]$Dir = (Join-Path '.claude' 'skills'),
        [string]$WavesRoot = (Join-Path (Join-Path '.claude' 'kb') '_waves'),
        [switch]$IncludeGlobal,
        [string]$GlobalRoot
    )
    $nodes = [System.Collections.Generic.List[object]]::new()
    $edges = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    $gRoot = if ($IncludeGlobal) {
        if ($GlobalRoot) { $GlobalRoot } else { Join-Path $HOME (Join-Path '.claude' 'skills') }
    } else { $null }

    foreach ($s in (Get-SkillInventory -ProjectRoot $Dir -GlobalRoot $gRoot)) {
        if ($seen.ContainsKey($s.Name)) { continue }
        $seen[$s.Name] = $true
        $nodes.Add([pscustomobject]@{
                Id = $s.Name; Type = 'Skill'; Role = ''; Description = ''
                Scope = $s.Scope; Status = if ($s.HasManifest) { 'valid' } else { 'scaffolded' }
            })
    }

    foreach ($d in (Get-DeclaredSkills -WavesRoot $WavesRoot)) {
        $domain = $d.Wave -replace '^\d+-[^-]+-', ''   # <NN>-<camada>-<domínio> → domínio
        $edges.Add([pscustomobject]@{ From = $domain; To = $d.Skill; Type = 'PRESUPPOSES' })
        if (-not $seen.ContainsKey($d.Skill)) {
            $seen[$d.Skill] = $true
            $nodes.Add([pscustomobject]@{
                    Id = $d.Skill; Type = 'Skill'; Role = ''; Description = ''
                    Scope = ''; Status = 'needed'
                })
        }
    }
    return [pscustomobject]@{
        Nodes = @($nodes | Sort-Object Id)
        Edges = @($edges | Sort-Object From, To, Type)
    }
}

function Get-AgentSkillLinks {
    <#
    .SYNOPSIS  (puro) Mapeia cada agente → seu domínio (pela PASTA domain/<d>/) e seu skills_used.
    .DESCRIPTION
        D-001: o domínio do agente é estrutural (1º segmento sob domain/); base agents (top-level) =
        universais (Domain=$null). skills_used (opcional) é o override do elo híbrido agente↔skill.
    .OUTPUTS   [pscustomobject[]] @{ Name; Domain; SkillsUsed }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $root = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\', '/')
    $out = [System.Collections.Generic.List[object]]::new()

    $files = Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'AGENT_MAP.md' -and -not $_.Name.StartsWith('_') }
    foreach ($f in $files) {
        $fm = Read-AgentFrontmatter -Path $f.FullName
        if ($null -eq $fm) { continue }
        $name = if ($fm.Contains('name')) { [string]$fm['name'] } else { $null }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/')
        $domain = if ($rel -match '(^|[\\/])domain[\\/]([^\\/]+)[\\/]') { $Matches[2] } else { $null }
        $skills = if ($fm.Contains('skills_used')) { @(ConvertFrom-InlineList -Value $fm['skills_used']) } else { @() }
        $out.Add([pscustomobject]@{ Name = $name; Domain = $domain; SkillsUsed = $skills })
    }
    return @($out | Sort-Object Name)
}

function Get-UnifiedGraph {
    <#
    .SYNOPSIS  Funde Agent + KB + Skill num grafo multi-tipo, com :Domain como junção (H9).
    .DESCRIPTION
        Cria nós :Domain (união dedup), arestas :IN_DOMAIN (agente→domínio, pela pasta) e :USES_SKILL
        (HÍBRIDO: derivado Agente→Domínio→Skill via :PRESUPPOSES + override skills_used). Garante que
        todo alvo de skill exista como nó (0-dangling por construção). -WithHub acrescenta o hub (H7).
    .OUTPUTS   [pscustomobject] @{ Nodes; Edges }
    #>
    [CmdletBinding()]
    param(
        [string]$AgentsDir = (Join-Path '.claude' 'agents'),
        [string]$KbDir = (Join-Path '.claude' 'kb'),
        [string]$SkillsDir = (Join-Path '.claude' 'skills'),
        [string]$WavesRoot = (Join-Path (Join-Path '.claude' 'kb') '_waves'),
        [switch]$IncludeGlobal,
        [switch]$NoHub
    )
    # O HUB (orquestrador-mestre do MAX) é o ÁPICE PERMANENTE do grafo (decisão de produto): o líder sempre
    # orquestra os experts via :ORCHESTRATES; o MAX só amplifica esse hub que já está no grafo. -NoHub dá
    # a view só-pares (raro, p/ inspecionar a estrutura sem o ápice).
    $agentG = if ($NoHub) { Get-AgentGraph -Dir $AgentsDir } else { Get-HubGraph -Dir $AgentsDir }
    $kbG    = Get-KbGraph -Dir $KbDir
    $skillG = Get-SkillGraph -Dir $SkillsDir -WavesRoot $WavesRoot -IncludeGlobal:$IncludeGlobal
    $links  = Get-AgentSkillLinks -Dir $AgentsDir

    $nodes = [System.Collections.Generic.List[object]]::new()
    $edges = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @($agentG.Nodes)) { $nodes.Add($n) }
    foreach ($n in @($kbG.Nodes))    { $nodes.Add($n) }
    foreach ($n in @($skillG.Nodes)) { $nodes.Add($n) }
    foreach ($e in @($agentG.Edges)) { $edges.Add($e) }
    foreach ($e in @($kbG.Edges))    { $edges.Add($e) }
    foreach ($e in @($skillG.Edges)) { $edges.Add($e) }

    # Índice domínio → skills pressupostas (das arestas :PRESUPPOSES).
    $skillNames = @{}; foreach ($n in @($skillG.Nodes)) { $skillNames[$n.Id] = $true }
    $byDomain = @{}
    foreach ($e in @($skillG.Edges | Where-Object { $_.Type -eq 'PRESUPPOSES' })) {
        if (-not $byDomain.ContainsKey($e.From)) { $byDomain[$e.From] = [System.Collections.Generic.List[string]]::new() }
        $byDomain[$e.From].Add($e.To)
    }

    # Domínios = união (KB + agentes + ondas). Cria nós :Domain.
    $domains = @{}
    foreach ($n in @($kbG.Nodes)) { if ($n.Domain) { $domains[$n.Domain] = $true } }
    foreach ($k in $byDomain.Keys) { $domains[$k] = $true }
    foreach ($l in @($links)) { if ($l.Domain) { $domains[$l.Domain] = $true } }
    foreach ($d in @($domains.Keys)) {
        $nodes.Add([pscustomobject]@{ Id = $d; Type = 'Domain'; Role = ''; Description = '' })
    }

    # Elo híbrido agente↔skill + agente→domínio.
    $usesSeen = @{}
    foreach ($l in @($links)) {
        if ($l.Domain) {
            $edges.Add([pscustomobject]@{ From = $l.Name; To = $l.Domain; Type = 'IN_DOMAIN' })
            # (a) derivado: domínio pressupõe skill → agente usa skill
            if ($byDomain.ContainsKey($l.Domain)) {
                foreach ($sk in $byDomain[$l.Domain]) {
                    $key = "$($l.Name)|$sk"
                    if (-not $usesSeen.ContainsKey($key)) { $usesSeen[$key] = $true
                        $edges.Add([pscustomobject]@{ From = $l.Name; To = $sk; Type = 'USES_SKILL' })
                    }
                }
            }
        }
        # (b) override explícito: skills_used
        foreach ($sk in @($l.SkillsUsed)) {
            $key = "$($l.Name)|$sk"
            if (-not $usesSeen.ContainsKey($key)) { $usesSeen[$key] = $true
                $edges.Add([pscustomobject]@{ From = $l.Name; To = $sk; Type = 'USES_SKILL' })
            }
            if (-not $skillNames.ContainsKey($sk)) { $skillNames[$sk] = $true
                $nodes.Add([pscustomobject]@{ Id = $sk; Type = 'Skill'; Role = ''; Description = ''; Scope = ''; Status = 'referenced' })
            }
        }
    }
    # :Feature p/ alvos de :PROMOTED_FROM (entidades externas — features arquivadas; G7). Garante 0-dangling
    # dessas arestas. (related/consolidates/supersedes ESPELHAM refs cruzadas da KB — dangling lá é sinal de
    # higiene da KB, não defeito do grafo: candidato a um check do kb-lint, não fabricamos o nó.)
    $featSeen = @{}
    foreach ($e in @($edges | Where-Object { $_.Type -eq 'PROMOTED_FROM' })) {
        if (-not $featSeen.ContainsKey($e.To)) {
            $featSeen[$e.To] = $true
            $nodes.Add([pscustomobject]@{ Id = $e.To; Type = 'Feature'; Role = ''; Description = '' })
        }
    }

    return [pscustomobject]@{
        Nodes = @($nodes | Sort-Object Type, Id)
        Edges = @($edges | Sort-Object From, To, Type)
    }
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
        [string]$KbDir = '',
        [string]$SkillsDir = '',
        [string]$WavesRoot = '',
        [switch]$IncludeGlobal,
        [switch]$NoHub,
        [switch]$Html,
        [switch]$DryRun
    )

    if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = $Dir }
    # Irmãos de .claude/agents por default: .claude/kb, .claude/skills, .claude/kb/_waves.
    $claudeRoot = Split-Path -Parent $Dir
    if ([string]::IsNullOrWhiteSpace($KbDir))     { $KbDir     = Join-Path $claudeRoot 'kb' }
    if ([string]::IsNullOrWhiteSpace($SkillsDir)) { $SkillsDir = Join-Path $claudeRoot 'skills' }
    if ([string]::IsNullOrWhiteSpace($WavesRoot)) { $WavesRoot = Join-Path $KbDir '_waves' }
    # H9: default = grafo UNIFICADO (agentes + KB + skills + domínios + o HUB orquestrador-mestre como
    # ápice). -NoHub dá a view só-pares; -IncludeGlobal soma skills globais (visão local, NÃO versionar).
    $graph      = Get-UnifiedGraph -AgentsDir $Dir -KbDir $KbDir -SkillsDir $SkillsDir -WavesRoot $WavesRoot -IncludeGlobal:$IncludeGlobal -NoHub:$NoHub
    $jsonPath   = Join-Path $OutDir 'graph.json'
    $cypherPath = Join-Path $OutDir 'graph.cypher'
    # -Html = visão "ver o cérebro" SEM servidor (gitignored, opt-in; NÃO é artefato versionado).
    $htmlPath   = if ($Html) { Join-Path $OutDir 'graph.html' } else { $null }
    $nCount     = @($graph.Nodes).Count
    $eCount     = @($graph.Edges).Count

    if ($DryRun) {
        Write-Host "[DRY] $jsonPath + $cypherPath$(if ($Html) { " + $htmlPath" }) ($nCount nós, $eCount arestas)"
        return [pscustomobject]@{ Graph = $graph; JsonPath = $jsonPath; CypherPath = $cypherPath; HtmlPath = $htmlPath }
    }

    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($jsonPath, (ConvertTo-GraphJson -Graph $graph), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($cypherPath, (ConvertTo-GraphCypher -Graph $graph), [System.Text.UTF8Encoding]::new($false))
    if ($Html) {
        [System.IO.File]::WriteAllText($htmlPath, (ConvertTo-GraphHtml -Graph $graph -Title 'Grafo do projeto'), [System.Text.UTF8Encoding]::new($false))
    }
    Write-Host "graph.json + graph.cypher$(if ($Html) { ' + graph.html' }) gerados: $nCount nós, $eCount arestas"
    return [pscustomobject]@{ Graph = $graph; JsonPath = $jsonPath; CypherPath = $cypherPath; HtmlPath = $htmlPath }
}

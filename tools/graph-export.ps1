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
    .SYNOPSIS  "Ver o cerebro" SEM servidor (H9): grafo -> HTML interativo self-contained (vis-network).
    .DESCRIPTION
        Renderiza o property-graph como pagina HTML unica. E a alternativa ao neo4j: nenhum
        servico, so um arquivo que abre no navegador. Endpoints de aresta sem no (ref cruzada de
        KB dangling) viram no 'Unknown' (honesto).

        O grafo e o indice de roteamento que os agentes consultam ("que arsenal eu aciono?"), entao
        a pagina e organizada para responder ISSO, nao para ser um enfeite: canvas a esquerda,
        painel de leitura a direita (lente -> legenda -> diretorio -> ficha). O diretorio lista TODO
        no, inclusive os que nao tem aresta nenhuma — no canvas eles somem na borda, e e justamente
        deles que se precisa saber.

        `-VisScript` recebe o BUNDLE do vis-network ja lido (o driver o le de tools/vendor/), e ele e
        embutido inline: "self-contained" no .SYNOPSIS era falso enquanto a pagina buscava a lib no
        unpkg — sem rede, o grafo nao abria, justamente na maquina offline em que ele precisa abrir.
        Sem `-VisScript` a pagina cai de volta na tag do CDN: degradacao consciente, nunca quebra.
        Pelo mesmo motivo nao ha webfont: a pagina usa a mono que a maquina ja tem.
    .OUTPUTS   [string]  (HTML; LF)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Graph,
        [string]$Title = 'Grafo do projeto',
        [string]$VisScript = ''
    )

    # Paleta alinhada a identidade do Native-SDD (mesma do site): fundo quase preto, laranja no
    # hub, ciano no agente. O tipo do no e a UNICA dimensao que ganha cor — aresta se distingue
    # por traco, senao a tela vira arco-iris e nada se le.
    $color = @{
        Agent = '#00E5FF'; KbEntry = '#10B981'; Skill = '#F59E0B'; Domain = '#A78BFA'
        Feature = '#7E8B9B'; Hub = '#FF5500'; Unknown = '#F43F5E'
    }
    $seen = @{}
    $visNodes = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @($Graph.Nodes)) {
        $seen[$n.Id] = $true
        $extra = (@($n.PSObject.Properties | Where-Object { $_.Name -notin @('Id', 'Role', 'Description') -and -not [string]::IsNullOrEmpty([string]$_.Value) } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' · ')
        # role/desc/meta viajam no proprio no: a ficha do painel le daqui, sem segundo dataset.
        # vis-network ignora campo que nao conhece, entao isto nao muda o render.
        $visNodes.Add([ordered]@{
            id = [string]$n.Id; label = [string]$n.Id; group = [string]$n.Type
            title = "$($n.Type): $($n.Id)`n$extra"
            role = [string]$n.Role; desc = [string]$n.Description; meta = $extra
        })
    }
    foreach ($e in @($Graph.Edges)) {
        foreach ($ep in @([string]$e.From, [string]$e.To)) {
            if (-not $seen.ContainsKey($ep)) {
                $seen[$ep] = $true
                $visNodes.Add([ordered]@{
                    id = $ep; label = $ep; group = 'Unknown'; title = "ref sem no (higiene da KB)"
                    role = ''; desc = 'Referencia sem no correspondente — higiene da KB.'; meta = ''
                })
            }
        }
    }
    $visEdges = @($Graph.Edges | ForEach-Object { [ordered]@{ from = [string]$_.From; to = [string]$_.To; label = [string]$_.Type; etype = [string]$_.Type } })

    $toJsonArray = {
        param($items)
        $j = (@($items) | ConvertTo-Json -Depth 4 -Compress)
        if ([string]::IsNullOrWhiteSpace($j)) { return '[]' }
        if (-not $j.StartsWith('[')) { return "[$j]" }   # ConvertTo-Json desfaz array de 1 item
        return $j
    }
    $nodesJson  = & $toJsonArray $visNodes
    $edgesJson  = & $toJsonArray $visEdges
    $groupsJson = (($color.GetEnumerator() | Sort-Object Key | ForEach-Object { "`"$($_.Key)`":{color:{background:'#0F1115',border:'$($_.Value)'},font:{color:'#F0F3F6'}}" }) -join ',')
    $paletteJson = (($color.GetEnumerator() | Sort-Object Key | ForEach-Object { "`"$($_.Key)`":'$($_.Value)'" }) -join ',')

    $tpl = @'
<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__</title>
__VISTAG__
<style>
  :root{
    --bg:#070809; --surface:#0F1115; --surface-2:#16191F;
    --line:rgba(240,243,246,.08); --line-strong:rgba(240,243,246,.18);
    --ink:#F0F3F6; --muted:#7E8B9B; --accent:#FF5500; --cyan:#00E5FF;
    --mono:ui-monospace,"JetBrains Mono","SF Mono",Menlo,Consolas,monospace;
    color-scheme:dark;
  }
  *,*::before,*::after{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--mono);font-size:13px}
  button{font:inherit;color:inherit}

  header{display:flex;align-items:center;gap:14px;padding:10px 16px;border-bottom:1px solid var(--line);background:var(--surface)}
  .brand{display:flex;align-items:center;gap:8px;font-size:11px;letter-spacing:.16em;color:var(--muted)}
  .brand b{color:var(--ink);font-weight:600}
  .live{width:6px;height:6px;border-radius:50%;background:var(--accent)}
  .counts{color:var(--muted);font-size:11px;font-variant-numeric:tabular-nums}
  .tools{margin-left:auto;display:flex;gap:4px}
  .tool{width:26px;height:26px;display:inline-flex;align-items:center;justify-content:center;
        background:transparent;border:1px solid var(--line);cursor:pointer;color:var(--muted)}
  .tool:hover{color:var(--accent);border-color:var(--accent)}
  .tool[aria-pressed="true"]{color:var(--accent);border-color:var(--accent)}

  main{display:grid;grid-template-columns:minmax(0,1fr) 320px;height:calc(100vh - 47px)}
  #stage{position:relative;min-width:0;
    background-image:linear-gradient(var(--line) 1px,transparent 1px),linear-gradient(90deg,var(--line) 1px,transparent 1px);
    background-size:36px 36px}
  #net{position:absolute;inset:0}
  #hint{position:absolute;left:12px;bottom:10px;color:var(--muted);font-size:10px;letter-spacing:.08em;pointer-events:none}

  aside{border-left:1px solid var(--line);background:var(--surface);overflow-y:auto;padding:14px}
  .sec{margin-bottom:18px}
  .sec-h{font-size:10px;letter-spacing:.18em;color:var(--muted);margin-bottom:8px}
  select,input[type=search]{width:100%;margin-bottom:6px;padding:6px 8px;background:var(--surface-2);
    border:1px solid var(--line);color:var(--ink);font:inherit;font-size:12px}
  input[type=search]::placeholder{color:var(--muted)}

  .leg{display:flex;align-items:center;gap:8px;padding:3px 0;cursor:pointer;color:var(--muted)}
  .leg:hover{color:var(--ink)}
  .leg.off{opacity:.35}
  .leg .dot{width:9px;height:9px;border-radius:50%;border:1.5px solid currentColor;flex:none}
  .leg .nm{color:var(--ink);flex:1}
  .leg.off .nm{color:var(--muted)}
  .leg .n{font-variant-numeric:tabular-nums}

  .dir-group{font-size:10px;letter-spacing:.14em;color:var(--accent);margin:10px 0 4px}
  .dir-item{display:flex;gap:8px;width:100%;text-align:left;padding:5px 6px;background:transparent;
    border:0;border-left:2px solid transparent;cursor:pointer}
  .dir-item:hover{background:var(--surface-2)}
  .dir-item.sel{border-left-color:var(--accent);background:var(--surface-2)}
  .dir-item .nm{flex:1;color:var(--ink);font-size:12px}
  .dir-item .rl{color:var(--muted);font-size:10px}
  .dir-item.orphan .nm::after{content:" ·";color:var(--accent)}

  .card{border:1px solid var(--line);background:var(--surface-2);padding:12px}
  .card h2{margin:0;font-size:14px}
  .card .kind{font-size:10px;letter-spacing:.14em;color:var(--cyan);margin:2px 0 8px}
  .card p{margin:0 0 10px;color:#C9D1D9;font-size:12px;line-height:1.5;font-family:system-ui,sans-serif}
  .card .blk{font-size:10px;letter-spacing:.14em;color:var(--muted);margin:10px 0 5px}
  .chip{display:inline-block;margin:0 4px 4px 0;padding:3px 6px;background:var(--bg);
    border:1px solid var(--line);color:var(--cyan);font-size:11px;cursor:pointer}
  .chip:hover{border-color:var(--accent);color:var(--accent)}
  .chip.flat{color:var(--muted);cursor:default}
  .chip.flat:hover{border-color:var(--line);color:var(--muted)}
  .note{color:var(--muted);font-size:11px;line-height:1.5}
  .empty{color:var(--muted);font-size:12px}
</style></head><body>
<header>
  <span class="brand"><span class="live"></span><b>__TITLE__</b></span>
  <span class="counts" id="counts"></span>
  <span class="tools">
    <button class="tool" id="zout" title="Afastar">&minus;</button>
    <button class="tool" id="zin" title="Aproximar">+</button>
    <button class="tool" id="zfit" title="Enquadrar tudo">&#9678;</button>
    <button class="tool" id="zphys" title="Congelar/soltar a fisica" aria-pressed="true">&#9832;</button>
    <button class="tool" id="zfull" title="Tela cheia">&#8599;</button>
  </span>
</header>
<main>
  <div id="stage"><div id="net"></div>
    <div id="hint">arraste um no &middot; clique para abrir e aproximar &middot; roda para zoom</div>
  </div>
  <aside>
    <div class="sec">
      <div class="sec-h">LENTE</div>
      <input type="search" id="q" placeholder="buscar no...">
      <select id="fedge">
        <option value="">aresta &middot; todas</option>
      </select>
    </div>
    <div class="sec">
      <div class="sec-h">LEGENDA &middot; clique para filtrar</div>
      <div id="legend"></div>
    </div>
    <div class="sec">
      <div class="sec-h">DIRETORIO</div>
      <div id="dir"></div>
    </div>
    <div class="sec" id="cardwrap"></div>
  </aside>
</main>
<script>
  var PALETTE = {__PALETTE__};
  var groups = {__GROUPS__};
  var rawNodes = __NODES__;
  var rawEdges = __EDGES__;

  var nodes = new vis.DataSet(rawNodes);
  var edges = new vis.DataSet(rawEdges);

  // Aresta se distingue por TRACO, nao por cor: continua legivel em monocromatico e nao
  // compete com a cor do no, que e a dimensao que importa.
  var EDGE_STYLE = {
    ORCHESTRATES: { color: '#FF5500', opacity: 0.55, dashes: false },
    CONNECTS_TO:  { color: '#00E5FF', opacity: 0.34, dashes: false },
    USES_SKILL:   { color: '#F59E0B', opacity: 0.40, dashes: [4, 4] },
    PRESUPPOSES:  { color: '#A78BFA', opacity: 0.40, dashes: [2, 3] },
    IN_DOMAIN:    { color: '#7E8B9B', opacity: 0.30, dashes: [1, 3] }
  };
  edges.forEach(function (e) {
    var s = EDGE_STYLE[e.etype] || { color: '#7E8B9B', opacity: 0.3, dashes: false };
    // Rotulo de aresta nasce OCULTO (size 0): com 38 arestas o miolo vira um borrao de
    // texto e o desenho para de responder "quem fala com quem". Ele volta quando a lente
    // isola UM tipo — ai sao poucas arestas e o nome ajuda em vez de atrapalhar.
    edges.update({ id: e.id, color: { color: s.color, opacity: s.opacity, highlight: s.color },
                   dashes: s.dashes, font: { color: '#7E8B9B', size: 0, strokeWidth: 0 } });
  });

  // Grau: o tamanho do no diz quanto ele participa do roteamento. Grau 0 fica pequeno E
  // aparece marcado no diretorio — no orfao e informacao, nao sujeira.
  var deg = {};
  nodes.forEach(function (n) { deg[n.id] = 0; });
  edges.forEach(function (e) { deg[e.from] = (deg[e.from] || 0) + 1; deg[e.to] = (deg[e.to] || 0) + 1; });
  nodes.forEach(function (n) {
    nodes.update({ id: n.id, value: deg[n.id], borderWidth: n.group === 'Hub' ? 3 : 2 });
  });

  var hidden = {};      // tipo de no -> escondido?
  var edgeFilter = '';  // '' = todas
  var query = '';

  var nodeView = new vis.DataView(nodes, { filter: function (n) {
    if (hidden[n.group]) return false;
    if (query && (n.id + ' ' + (n.role || '')).toLowerCase().indexOf(query) === -1) return false;
    return true;
  }});
  var edgeView = new vis.DataView(edges, { filter: function (e) {
    if (edgeFilter && e.etype !== edgeFilter) return false;
    var a = nodes.get(e.from), b = nodes.get(e.to);
    if (!a || !b) return false;
    if (hidden[a.group] || hidden[b.group]) return false;
    return true;
  }});

  var net = new vis.Network(document.getElementById('net'), { nodes: nodeView, edges: edgeView }, {
    groups: groups,
    nodes: { shape: 'dot', scaling: { min: 9, max: 26 },
             font: { color: '#F0F3F6', size: 12, face: 'ui-monospace, monospace', strokeWidth: 4, strokeColor: '#070809' } },
    edges: { arrows: { to: { enabled: true, scaleFactor: 0.45 } }, width: 1,
             smooth: { type: 'continuous' }, font: { align: 'top' } },
    // Fisica LIGADA de proposito: arrastar um no puxa a vizinhanca, que e como se le que o
    // grafo esta conectado. O botao de congelar existe para quem quiser posicionar a mao.
    physics: { stabilization: { iterations: 400 },
               barnesHut: { springLength: 210, gravitationalConstant: -9000,
                            centralGravity: 0.12, damping: 0.55, avoidOverlap: 0.35 } },
    interaction: { hover: true, tooltipDelay: 200, navigationButtons: false, keyboard: false }
  });

  /* ---------------------------------------------------------------- painel */

  var elCounts = document.getElementById('counts');
  var elLegend = document.getElementById('legend');
  var elDir = document.getElementById('dir');
  var elCard = document.getElementById('cardwrap');
  var selected = null;

  function countsByGroup() {
    var c = {};
    nodes.forEach(function (n) { c[n.group] = (c[n.group] || 0) + 1; });
    return c;
  }

  function renderCounts() {
    elCounts.textContent = nodeView.length + '/' + nodes.length + ' nos \u00b7 ' +
                           edgeView.length + '/' + edges.length + ' arestas';
  }

  function renderLegend() {
    var c = countsByGroup();
    elLegend.innerHTML = '';
    Object.keys(c).sort().forEach(function (g) {
      var row = document.createElement('div');
      row.className = 'leg' + (hidden[g] ? ' off' : '');
      row.style.color = PALETTE[g] || '#7E8B9B';
      row.innerHTML = '<span class="dot"></span><span class="nm"></span><span class="n"></span>';
      row.querySelector('.nm').textContent = g;
      row.querySelector('.n').textContent = c[g];
      row.title = (hidden[g] ? 'mostrar ' : 'ocultar ') + g;
      row.addEventListener('click', function () {
        hidden[g] = !hidden[g];
        nodeView.refresh(); edgeView.refresh();
        renderLegend(); renderDir(); renderCounts();
      });
      elLegend.appendChild(row);
    });
  }

  function renderDir() {
    var byGroup = {};
    nodes.forEach(function (n) {
      if (query && (n.id + ' ' + (n.role || '')).toLowerCase().indexOf(query) === -1) return;
      (byGroup[n.group] = byGroup[n.group] || []).push(n);
    });
    elDir.innerHTML = '';
    var keys = Object.keys(byGroup).sort();
    if (!keys.length) {
      elDir.innerHTML = '<div class="empty">nada casa com a busca.</div>';
      return;
    }
    keys.forEach(function (g) {
      var h = document.createElement('div');
      h.className = 'dir-group';
      h.textContent = g + ' (' + byGroup[g].length + ')';
      h.style.color = PALETTE[g] || '#7E8B9B';
      elDir.appendChild(h);
      byGroup[g].sort(function (a, b) { return a.id < b.id ? -1 : 1; }).forEach(function (n) {
        var b = document.createElement('button');
        b.className = 'dir-item' + (selected === n.id ? ' sel' : '') + (deg[n.id] ? '' : ' orphan');
        b.innerHTML = '<span class="nm"></span><span class="rl"></span>';
        b.querySelector('.nm').textContent = n.id;
        b.querySelector('.rl').textContent = deg[n.id] ? (n.role || n.group.toLowerCase()) : 'sem aresta';
        b.title = deg[n.id] ? (n.role || '') : 'nenhuma aresta chega ou sai deste no';
        b.addEventListener('click', function () { open(n.id); });
        elDir.appendChild(b);
      });
    });
  }

  function chip(label, goTo) {
    var b = document.createElement('button');
    b.className = 'chip' + (goTo ? '' : ' flat');
    b.textContent = label;
    if (goTo) b.addEventListener('click', function () { open(goTo); });
    return b;
  }

  function blk(parent, label) {
    var d = document.createElement('div');
    d.className = 'blk';
    d.textContent = label;
    parent.appendChild(d);
    var body = document.createElement('div');
    parent.appendChild(body);
    return body;
  }

  function renderCard(id) {
    var n = nodes.get(id);
    elCard.innerHTML = '';
    if (!n) return;
    var card = document.createElement('div');
    card.className = 'card';

    var h = document.createElement('h2');
    h.textContent = n.id;
    h.style.color = PALETTE[n.group] || '#F0F3F6';
    card.appendChild(h);

    var k = document.createElement('div');
    k.className = 'kind';
    k.textContent = (n.role ? n.role + ' \u00b7 ' : '') + n.group + ' \u00b7 ' + (deg[n.id] || 0) + ' conexoes';
    card.appendChild(k);

    if (n.desc) {
      var p = document.createElement('p');
      p.textContent = n.desc;
      card.appendChild(p);
    }

    var out = {}, inc = [];
    edges.forEach(function (e) {
      if (e.from === n.id) (out[e.etype] = out[e.etype] || []).push(e.to);
      if (e.to === n.id) inc.push(e.from);
    });
    Object.keys(out).sort().forEach(function (t) {
      var body = blk(card, t + ' (' + out[t].length + ')');
      out[t].forEach(function (x) { body.appendChild(chip(x, x)); });
    });
    if (inc.length) {
      var body = blk(card, 'INVOCADO POR (' + inc.length + ')');
      inc.forEach(function (x) { body.appendChild(chip(x, x)); });
    }
    if (!Object.keys(out).length && !inc.length) {
      var note = document.createElement('div');
      note.className = 'note';
      note.textContent = 'Nenhuma aresta. Este no existe no projeto mas nao e alcancado por ' +
                         'nenhum outro — quem o aciona nao esta neste grafo.';
      card.appendChild(note);
    }
    if (n.meta) {
      var m = document.createElement('div');
      m.className = 'note';
      m.style.marginTop = '10px';
      m.textContent = n.meta;
      card.appendChild(m);
    }
    elCard.appendChild(card);
  }

  function open(id) {
    selected = id;
    var visible = nodeView.get(id);
    if (visible) {
      net.selectNodes([id]);
      // Clicar aproxima: e o gesto de "entrar" no no, nao so o de destaca-lo.
      net.focus(id, { scale: 1.5, animation: { duration: 420, easingFunction: 'easeInOutQuad' } });
    }
    renderCard(id);
    renderDir();
  }

  net.on('selectNode', function (p) { if (p.nodes.length) open(p.nodes[0]); });
  net.on('deselectNode', function () { selected = null; elCard.innerHTML = ''; renderDir(); });

  /* -------------------------------------------------------------- controles */

  function zoom(f) { net.moveTo({ scale: net.getScale() * f, animation: { duration: 220 } }); }
  document.getElementById('zin').addEventListener('click', function () { zoom(1.35); });
  document.getElementById('zout').addEventListener('click', function () { zoom(1 / 1.35); });
  document.getElementById('zfit').addEventListener('click', function () {
    net.fit({ animation: { duration: 320 } });
  });

  var physOn = true;
  document.getElementById('zphys').addEventListener('click', function () {
    physOn = !physOn;
    net.setOptions({ physics: { enabled: physOn } });
    this.setAttribute('aria-pressed', physOn ? 'true' : 'false');
    this.title = physOn ? 'Congelar a fisica' : 'Soltar a fisica';
  });

  var full = document.getElementById('zfull');
  if (!document.fullscreenEnabled) { full.hidden = true; }
  full.addEventListener('click', function () {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen();
  });

  document.getElementById('q').addEventListener('input', function () {
    query = this.value.trim().toLowerCase();
    nodeView.refresh(); edgeView.refresh();
    renderDir(); renderCounts();
  });

  var fe = document.getElementById('fedge');
  Object.keys(EDGE_STYLE).forEach(function (t) {
    if (!edges.get({ filter: function (e) { return e.etype === t; } }).length) return;
    var o = document.createElement('option');
    o.value = t; o.textContent = 'aresta \u00b7 ' + t;
    fe.appendChild(o);
  });
  fe.addEventListener('change', function () {
    edgeFilter = this.value;
    // Um tipo isolado = poucas arestas na tela: o rotulo passa a caber e a informar.
    var size = edgeFilter ? 9 : 0;
    edges.forEach(function (e) { edges.update({ id: e.id, font: { color: '#7E8B9B', size: size, strokeWidth: 0 } }); });
    edgeView.refresh();
    renderCounts();
  });

  document.addEventListener('keydown', function (ev) {
    if (ev.key === 'Escape') { net.unselectAll(); selected = null; elCard.innerHTML = ''; renderDir(); }
  });

  renderLegend(); renderDir(); renderCounts();
  net.once('stabilizationIterationsDone', function () { net.fit({ animation: false }); });
</script></body></html>
'@
    # O bundle vendorizado nao contem a sequencia '</script' (conferido), entao inlina direto.
    $visTag = if ([string]::IsNullOrWhiteSpace($VisScript)) {
        '<script src="https://unpkg.com/vis-network@9/standalone/umd/vis-network.min.js"></script>'
    } else {
        "<script>`n$VisScript`n</script>"
    }
    $html = $tpl.Replace('__VISTAG__', $visTag).Replace('__TITLE__', $Title).Replace('__GROUPS__', $groupsJson).Replace('__PALETTE__', $paletteJson).Replace('__NODES__', $nodesJson).Replace('__EDGES__', $edgesJson).Replace('__NCOUNT__', [string]@($Graph.Nodes).Count).Replace('__ECOUNT__', [string]@($Graph.Edges).Count)
    return ($html -replace "`r`n", "`n")
}

function Get-KbGraph {
    <#
    .SYNOPSIS  Property-graph (puro) das entradas de KB — a "base do cérebro" (H9, Base 1).
    .DESCRIPTION
        Reusa Read-KbFrontmatter (kb-lint) — zero parser novo. Nós :KbEntry (id/layer/domain/
        content_type/status) + arestas :RELATED_TO (related), :CONSOLIDATES, :SUPERSEDES,
        :PROMOTED_FROM (→ :Feature), :IN_DOMAIN (→ :Domain). O que é entrada de KB vem de
        Get-KbEntryFile (kb-lint) — MESMA fonte única do lint/inventário/check, nunca uma cópia
        do filtro (era assim que um backup em _lessons/ virava nó duplicado aqui e invisível lá).
    .OUTPUTS   [pscustomobject] @{ Nodes; Edges }  (ordenados, determinístico)
    #>
    [CmdletBinding()]
    param([string]$Dir = (Join-Path '.claude' 'kb'))

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        return [pscustomobject]@{ Nodes = @(); Edges = @() }
    }
    $nodes = [System.Collections.Generic.List[object]]::new()
    $edges = [System.Collections.Generic.List[object]]::new()

    $files = Get-KbEntryFile -Dir $Dir

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
        # União dos DOIS campos, por semânticas distintas: `skills` é o campo OFICIAL do harness
        # (pré-carrega o conteúdo integral da skill no contexto do subagente — disparo determinístico,
        # só serve p/ skill interna, sempre presente); `skills_used` é metadado NOSSO (elo do grafo),
        # usado onde a skill é opcional/de terceiro e listá-la em `skills` geraria warning de skill
        # ausente. Para o grafo, ambos são a mesma aresta :USES_SKILL.
        $skills = @()
        foreach ($k in @('skills', 'skills_used')) {
            if ($fm.Contains($k) -and -not [string]::IsNullOrWhiteSpace($fm[$k])) {
                $skills += @(ConvertFrom-InlineList -Value $fm[$k])
            }
        }
        $skills = @($skills | Select-Object -Unique)
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
    .SYNOPSIS  I/O fino: lê os agentes, gera graph.json no destino. O .cypher é OPT-IN (-Cypher).
    .DESCRIPTION
        O `graph.cypher` NÃO é mais artefato versionado do scaffold (retirado em 2026-08-14):
        em ~2 meses nenhum consumidor apareceu — todas as menções o descreviam como "pronto p/ o
        neo4j SE o volume um dia justificar" — e ele custava manutenção real (o resync-lint cobrava
        staleness dele a cada /sync-context). A CAPACIDADE fica: `ConvertTo-GraphCypher` continua
        aqui e `-Cypher` a escreve, então o dia em que houver neo4j é um comando, não um port.
    .OUTPUTS   [pscustomobject] @{ Graph; JsonPath; CypherPath; HtmlPath }  (CypherPath = $null sem -Cypher)
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
        [switch]$Cypher,
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
    # -Cypher = dump p/ neo4j sob demanda; NÃO é artefato versionado (ver .DESCRIPTION).
    $cypherPath = if ($Cypher) { Join-Path $OutDir 'graph.cypher' } else { $null }
    # -Html = visão "ver o cérebro" SEM servidor (gitignored, opt-in; NÃO é artefato versionado).
    $htmlPath   = if ($Html) { Join-Path $OutDir 'graph.html' } else { $null }
    $nCount     = @($graph.Nodes).Count
    $eCount     = @($graph.Edges).Count

    if ($DryRun) {
        Write-Host "[DRY] $jsonPath$(if ($Cypher) { " + $cypherPath" })$(if ($Html) { " + $htmlPath" }) ($nCount nós, $eCount arestas)"
        return [pscustomobject]@{ Graph = $graph; JsonPath = $jsonPath; CypherPath = $cypherPath; HtmlPath = $htmlPath }
    }

    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($jsonPath, (ConvertTo-GraphJson -Graph $graph), [System.Text.UTF8Encoding]::new($false))
    if ($Cypher) {
        [System.IO.File]::WriteAllText($cypherPath, (ConvertTo-GraphCypher -Graph $graph), [System.Text.UTF8Encoding]::new($false))
    }
    if ($Html) {
        # Vendor local (tools/vendor/) em vez de CDN — o graph.html precisa abrir offline.
        # Ausente: segue com a tag do unpkg e avisa, em vez de falhar o export inteiro.
        $visPath = Join-Path $PSScriptRoot 'vendor/vis-network.min.js'
        $visJs = ''
        if (Test-Path -LiteralPath $visPath -PathType Leaf) {
            $visJs = [System.IO.File]::ReadAllText($visPath)
        } else {
            Write-Warning "vis-network vendorizado nao encontrado ($visPath) — graph.html vai depender do CDN unpkg e nao abrira offline"
        }
        [System.IO.File]::WriteAllText($htmlPath, (ConvertTo-GraphHtml -Graph $graph -Title 'Grafo do projeto' -VisScript $visJs), [System.Text.UTF8Encoding]::new($false))
    }
    Write-Host "graph.json$(if ($Cypher) { ' + graph.cypher' })$(if ($Html) { ' + graph.html' }) gerados: $nCount nós, $eCount arestas"
    return [pscustomobject]@{ Graph = $graph; JsonPath = $jsonPath; CypherPath = $cypherPath; HtmlPath = $htmlPath }
}

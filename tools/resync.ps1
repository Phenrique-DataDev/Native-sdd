<#
.SYNOPSIS
    Driver one-shot de ressincronização dos artefatos DERIVADOS do scaffold (auto-resync) —
    regenera AGENT_MAP.md + graph.json + kb/_index.yaml + docs/_index.md + sdd/archive/_index.md
    numa chamada.

.DESCRIPTION
    Fecha estruturalmente o drift dos artefatos derivados: adicionar um agente/skill/entrada de KB
    (pela curadoria OU à mão) deixa o grafo, o mapa e o índice da KB stale. Este driver é a FONTE
    ÚNICA da regeneração — usado tanto na CRIAÇÃO (/audit-agents · /train-kb · /skill-gap) quanto
    pelo /sync-context (G4). Reusa os geradores que JÁ existem (zero reimplementação):
      Build-AgentMap (sync-context.ps1) · ConvertTo-GraphJson + Get-UnifiedGraph
      (graph-export.ps1) · Build-KbIndex (sync-context.ps1) · Get-AgentInventory/Get-KbInventory
      (agent-lint.ps1 / kb-lint.ps1).

    Dois modos:
      -Check : gera cada artefato EM MEMÓRIA, compara com o commitado (normalizado p/ LF) e devolve
               um [DriftResult] por artefato. NÃO escreve (0 bytes).
      -Write : escreve só os artefatos divergentes (UTF-8 sem BOM, LF). Idempotente — 2× = mesmos bytes.

    Determinismo: os geradores são byte-determinísticos (ordenação estável, sem timestamp, LF) — é o
    que permite a comparação por string (e o staleness-lint em resync-lint.ps1 não dar falso-positivo).

    Funções puras (Get-ResyncPlan) + I/O fino (Get-ResyncContent, Invoke-Resync). Molde graph-export.ps1.
#>

Set-StrictMode -Version Latest

# Reusa os geradores existentes (bibliotecas; sem auto-run no carregamento — molde graph-export.ps1).
# Ordem fixa; colisão de nome coberta por smoke no Pester. graph-export.ps1 já re-traz agent-lint/kb-lint.
. (Join-Path $PSScriptRoot 'agent-lint.ps1')     # Get-AgentInventory
. (Join-Path $PSScriptRoot 'kb-lint.ps1')        # Get-KbInventory
. (Join-Path $PSScriptRoot 'sync-context.ps1')   # Build-AgentMap, Build-KbIndex
. (Join-Path $PSScriptRoot 'graph-export.ps1')   # Get-UnifiedGraph, ConvertTo-GraphJson

function Get-ResyncPlan {
    <#
    .SYNOPSIS  PURA: dado o diretório .claude, devolve os alvos derivados { Key; Paths }.
               Fonte ÚNICA dos caminhos (evita 3 paths hardcoded espalhados).
    .OUTPUTS   [pscustomobject[]] — Key ∈ {map, graph, kb-index}; Paths = 1 (map/kb-index) ou 2 (graph).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ClaudeDir)

    $agents = Join-Path $ClaudeDir 'agents'
    $kb     = Join-Path $ClaudeDir 'kb'
    # docs/ é IRMÃO de .claude/ (raiz do projeto), não filho — daí o Split-Path do pai.
    $docs   = Join-Path (Split-Path -Parent $ClaudeDir) 'docs'
    return @(
        [pscustomobject]@{ Key = 'map';        Paths = @((Join-Path $agents 'AGENT_MAP.md')) }
        # Só o graph.json. O graph.cypher saiu dos artefatos versionados em 2026-08-14 (sem consumidor
        # em ~2 meses); a capacidade ficou em `Invoke-GraphExport -Cypher`, sob demanda.
        [pscustomobject]@{ Key = 'graph';      Paths = @((Join-Path $agents 'graph.json')) }
        [pscustomobject]@{ Key = 'kb-index';   Paths = @((Join-Path $kb '_index.yaml')) }
        [pscustomobject]@{ Key = 'docs-index'; Paths = @((Join-Path $docs '_index.md')) }
        # O catálogo do archive (uma linha por feature): o que a busca por significado lê primeiro.
        # Substituiu o MCP semantic-kb (2026-09-11) — ver postures/semantic-search.md.
        [pscustomobject]@{ Key = 'archive-index'; Paths = @((Join-Path (Join-Path $ClaudeDir 'sdd/archive') '_index.md')) }
    )
}

function Get-ResyncContent {
    <#
    .SYNOPSIS  I/O: lê os inventários e GERA o conteúdo (LF) de cada artefato em memória — não escreve.
    .OUTPUTS   [hashtable] Path -> conteúdo gerado (string). As chaves são EXATAMENTE os Paths do plano.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ClaudeDir)

    $agentsDir = Join-Path $ClaudeDir 'agents'
    $kbDir     = Join-Path $ClaudeDir 'kb'
    $cmdDir    = Join-Path $ClaudeDir 'commands'
    $skillsDir = Join-Path $ClaudeDir 'skills'
    $wavesRoot = Join-Path $kbDir '_waves'
    $docsDir   = Join-Path (Split-Path -Parent $ClaudeDir) 'docs'

    $agents = @(Get-AgentInventory -Dir $agentsDir)
    # Arestas connects_to p/ o AGENT_MAP (H3): lê o frontmatter de cada agente (Read-AgentFrontmatter/
    # ConvertFrom-InlineList vêm do agent-lint, já dot-sourced). Build-AgentMap só desenha entre nós existentes.
    $connections = @{}
    foreach ($a in @($agents | Where-Object { $_.Name })) {
        $fm = Read-AgentFrontmatter -Path $a.Path
        if ($fm -and $fm.Contains('connects_to') -and -not [string]::IsNullOrWhiteSpace($fm['connects_to'])) {
            $connections[$a.Name] = @(ConvertFrom-InlineList -Value $fm['connects_to'])
        }
    }
    $cmds   = @(if (Test-Path -LiteralPath $cmdDir -PathType Container) {
            Get-ChildItem -LiteralPath $cmdDir -Filter '*.md' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName }
        })
    $kb     = @(Get-KbInventory -Dir $kbDir)
    # Mesmo grafo unificado que o Invoke-GraphExport produz (Get-UnifiedGraph + ConvertTo-* = os mesmos
    # blocos), mas gerado EM MEMÓRIA p/ -Check e -Write seguirem UMA rota — paridade byte-a-byte por construção.
    $graph  = Get-UnifiedGraph -AgentsDir $agentsDir -KbDir $kbDir -SkillsDir $skillsDir -WavesRoot $wavesRoot
    $docs   = @(Get-DocsInventory -DocsDir $docsDir)
    $archive = @(Get-ArchiveInventory -ArchiveDir (Join-Path $ClaudeDir 'sdd/archive'))

    $plan       = Get-ResyncPlan -ClaudeDir $ClaudeDir
    $mapPath    = @($plan | Where-Object { $_.Key -eq 'map' })[0].Paths[0]
    $graphPaths = @($plan | Where-Object { $_.Key -eq 'graph' })[0].Paths
    $kbPath     = @($plan | Where-Object { $_.Key -eq 'kb-index' })[0].Paths[0]
    $docsPath   = @($plan | Where-Object { $_.Key -eq 'docs-index' })[0].Paths[0]
    $archPath   = @($plan | Where-Object { $_.Key -eq 'archive-index' })[0].Paths[0]

    $content = @{}
    $content[$mapPath]       = (Build-AgentMap -Agents $agents -Commands @($cmds) -Connections $connections)
    $content[$graphPaths[0]] = (ConvertTo-GraphJson   -Graph $graph)   # graph.json
    $content[$kbPath]        = (Build-KbIndex -Entries @($kb))
    $content[$docsPath]      = (Build-DocsIndex -Docs $docs)           # docs/_index.md (B10 — antes órfão)
    $content[$archPath]      = (Build-ArchiveIndex -Entries $archive)  # sdd/archive/_index.md (catálogo)
    return $content
}

function Invoke-Resync {
    <#
    .SYNOPSIS  Driver: -Check (computa drift, não escreve) ou -Write (regenera os divergentes).
    .OUTPUTS   [pscustomobject[]] de DriftResult @{ Key; Paths; InSync; Reason }.
               Reason ∈ {'', 'content-drift', 'missing-on-disk'}. Default = -Check (seguro).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClaudeDir,
        [switch]$Check,
        [switch]$Write
    )

    # -Check (default, read-only) e -Write são mutuamente exclusivos; -Check é explícito p/ simetria de API.
    if ($Check -and $Write) { throw 'Invoke-Resync: use -Check OU -Write, não ambos.' }

    if (-not (Test-Path -LiteralPath $ClaudeDir -PathType Container)) {
        return @([pscustomobject]@{ Key = '_dir'; Paths = @($ClaudeDir); InSync = $false; Reason = 'missing-claudedir' })
    }

    $plan    = Get-ResyncPlan -ClaudeDir $ClaudeDir
    $content = Get-ResyncContent -ClaudeDir $ClaudeDir

    $drift = foreach ($t in $plan) {
        $inSync = $true
        $reason = ''
        foreach ($p in $t.Paths) {
            $gen = [string]$content[$p]
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
                $inSync = $false; $reason = 'missing-on-disk'; continue
            }
            $disk = (Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue) -replace "`r`n", "`n"
            if ($disk -ne $gen) { $inSync = $false; if (-not $reason) { $reason = 'content-drift' } }
        }
        [pscustomobject]@{ Key = $t.Key; Paths = $t.Paths; InSync = $inSync; Reason = $reason }
    }
    $drift = @($drift)

    if ($Write) {
        $enc = [System.Text.UTF8Encoding]::new($false)   # UTF-8 sem BOM (= Invoke-GraphExport)
        foreach ($d in @($drift | Where-Object { -not $_.InSync })) {
            foreach ($p in $d.Paths) {
                $dir = Split-Path -Parent $p
                if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
                [System.IO.File]::WriteAllText($p, [string]$content[$p], $enc)
            }
        }
    }

    return $drift
}

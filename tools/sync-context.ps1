<#
.SYNOPSIS
    Gerador/validador do G4 (/sync-context): produz os índices do projeto de forma
    determinística e atualiza regiões marcadas sem tocar conteúdo manual.

.DESCRIPTION
    Funções puras (sem efeitos colaterais) usadas pela validação automática do G4 e pelo
    comando em runtime. Reusam os inventários do G2 (Get-AgentInventory) e do G3
    (Get-KbInventory) — não reimplementam varredura.

      Build-AgentMap     -> texto completo do AGENT_MAP.md (cabeçalho + Mermaid determinístico)
      Build-KbIndex      -> YAML do kb/_index.yaml (domínios ordenados; layer/entries/unverified)
      Update-MarkedRegion-> substitui só o miolo entre <!-- sync-context:start:NAME --> e :end:NAME -->

    Determinismo: ordenação estável por nome/domínio; sem timestamps no conteúdo gerado
    (senão o git diff nunca seria vazio). Quebras de linha LF.
#>

Set-StrictMode -Version Latest

function ConvertTo-NodeId {
    <#
    .SYNOPSIS
        Sanitiza um nome para id de nó Mermaid (alfanumérico + underscore), com prefixo.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $safe = ($Name -replace '[^a-zA-Z0-9]', '_')
    return "$Prefix$safe"
}

function Build-AgentMap {
    <#
    .SYNOPSIS
        Monta o texto completo do AGENT_MAP.md a partir do inventário de agentes e da lista
        de comandos. Saída determinística (ordenação alfabética).
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Agents,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Commands,
        # Arestas peer connects_to (nome do agente -> nomes de destino). Opcional: vazio = sem
        # arestas (retrocompat). Renderiza o "mapa de ligação" (H3) só entre nós existentes.
        [Parameter()][hashtable]$Connections = @{}
    )

    $cmds  = @($Commands | Sort-Object)
    $core  = @($Agents | Where-Object { -not $_.Generated -and $_.Name } | Sort-Object Name)
    $dom   = @($Agents | Where-Object {      $_.Generated -and $_.Name } | Sort-Object Name)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("# Mapa de agentes`n`n")
    [void]$sb.Append("> ⚠️ **Gerado por `/sync-context` — não editar à mão.** Rode `/sync-context` para atualizar.`n`n")
    [void]$sb.Append("## Grafo`n`n")
    [void]$sb.Append('```mermaid' + "`n")
    [void]$sb.Append("graph TD`n")
    [void]$sb.Append("    user([Usuário]) --> lead[Sessão principal / agente líder]`n")

    [void]$sb.Append("`n    subgraph CMD[`"Slash commands`"]`n")
    foreach ($c in $cmds) {
        $id = ConvertTo-NodeId -Prefix 'c_' -Name $c
        [void]$sb.Append("        $id[`"/$c`"]`n")
    }
    [void]$sb.Append("    end`n")

    [void]$sb.Append("`n    subgraph CORE[`"Subagents genéricos`"]`n")
    foreach ($a in $core) {
        $id = ConvertTo-NodeId -Prefix 'a_' -Name $a.Name
        [void]$sb.Append("        $id[`"$($a.Name)`"]`n")
    }
    [void]$sb.Append("    end`n")

    if ($dom.Count -gt 0) {
        [void]$sb.Append("`n    subgraph DOM[`"Agentes de domínio (curadoria)`"]`n")
        foreach ($a in $dom) {
            $id = ConvertTo-NodeId -Prefix 'a_' -Name $a.Name
            [void]$sb.Append("        $id[`"$($a.Name)`"]`n")
        }
        [void]$sb.Append("    end`n")
    } else {
        [void]$sb.Append("`n    %% Agentes de domínio: nenhum (surgem via /audit-agents)`n")
    }

    [void]$sb.Append("`n    lead --> CMD`n")
    [void]$sb.Append("    lead --> CORE`n")
    if ($dom.Count -gt 0) { [void]$sb.Append("    lead --> DOM`n") }

    # Arestas connects_to (peer) entre agentes — o "mapa de ligação" (H3). Só quando há relações
    # informadas e ambos os nós existem no grafo. Determinístico (chaves/alvos ordenados).
    $validNames = @(@($core) + @($dom) | ForEach-Object { $_.Name })
    $edgeLines  = [System.Collections.Generic.List[string]]::new()
    foreach ($from in @($Connections.Keys | Sort-Object)) {
        if ($from -notin $validNames) { continue }
        foreach ($to in @($Connections[$from] | Sort-Object)) {
            if ($to -notin $validNames) { continue }
            $fid = ConvertTo-NodeId -Prefix 'a_' -Name $from
            $tid = ConvertTo-NodeId -Prefix 'a_' -Name $to
            [void]$edgeLines.Add("    $fid --> $tid")
        }
    }
    if ($edgeLines.Count -gt 0) {
        [void]$sb.Append("`n    %% Relações connects_to (peer)`n")
        foreach ($e in $edgeLines) { [void]$sb.Append("$e`n") }
    }

    [void]$sb.Append('```' + "`n")

    return $sb.ToString()
}

function Build-KbIndex {
    <#
    .SYNOPSIS
        Monta o YAML do kb/_index.yaml a partir do inventário de KB. Domínios ordenados;
        por domínio: camada predominante, total de entradas e quantas unverified.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("# .claude/kb/_index.yaml — gerado por /sync-context, não editar à mão`n")
    [void]$sb.Append("generated_by: sync-context`n")

    $valid = @($Entries | Where-Object { $_.Domain })
    if ($valid.Count -eq 0) {
        [void]$sb.Append("domains: {}`n")
        return $sb.ToString()
    }

    [void]$sb.Append("domains:`n")
    $byDomain = $valid | Group-Object Domain | Sort-Object Name
    foreach ($g in $byDomain) {
        # camada predominante (desempate alfabético)
        $layer = ($g.Group | Group-Object Layer | Sort-Object @{e={$_.Count};Descending=$true}, Name |
                   Select-Object -First 1).Name
        $count = $g.Count
        $unver = @($g.Group | Where-Object { -not $_.Verified }).Count
        [void]$sb.Append("  $($g.Name):`n")
        [void]$sb.Append("    layer: $layer`n")
        [void]$sb.Append("    entries: $count`n")
        [void]$sb.Append("    unverified: $unver`n")
    }
    return $sb.ToString()
}

function Get-DocTitle {
    <#
    .SYNOPSIS
        Título de um .md = o 1º heading ATX H1 (`# Título`). Sem H1 → '' (o caller usa o Path).
        Determinístico e barato (para na 1ª linha que casa). Fonte do Title de Get-DocsInventory.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ($line -match '^#\s+(.+?)\s*$') { return $Matches[1] }
    }
    return ''
}

function Get-DocsInventory {
    <#
    .SYNOPSIS
        Inventaria `docs/` -> [{ Path=<relativo a docs/, POSIX>; Title=<1º H1 ou ''> }], ordenado por
        Path (determinístico). Diretório ausente => coleção vazia (não é erro). É o insumo de
        Build-DocsIndex — os itens '_'-prefixados (ex.: _index.md, _ABOUT.md) são filtrados LÁ, não aqui.
    .OUTPUTS
        [pscustomobject[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DocsDir)

    if (-not (Test-Path -LiteralPath $DocsDir -PathType Container)) { return @() }
    $base = (Resolve-Path -LiteralPath $DocsDir).Path
    $files = @(Get-ChildItem -LiteralPath $DocsDir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue)
    $inv = foreach ($f in $files) {
        $rel = ($f.FullName.Substring($base.Length)).TrimStart('\', '/') -replace '\\', '/'
        [pscustomobject]@{ Path = $rel; Title = (Get-DocTitle -Path $f.FullName) }
    }
    return @($inv | Sort-Object { [string]$_.Path })
}

function Build-DocsIndex {
    <#
    .SYNOPSIS
        Monta o conteúdo de docs/_index.md a partir das docs do projeto (B10). Saída
        determinística (ordenação por Path, sem timestamp) → rodar 2x gera texto idêntico.
    .PARAMETER Docs
        Coleção de objetos { Path=<caminho relativo>; Title=<título ou ''> }. Itens
        auxiliares (basename começando com '_') são ignorados.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Docs)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("# docs/_index.md — gerado por /sync-context, não editar à mão`n")
    [void]$sb.Append("generated_by: sync-context`n`n")

    $valid = @($Docs | Where-Object {
            $_.Path -and -not ([System.IO.Path]::GetFileName([string]$_.Path)).StartsWith('_')
        } | Sort-Object { [string]$_.Path })

    if ($valid.Count -eq 0) {
        [void]$sb.Append("_(sem documentação ainda — gerada pelo `documenter` ou por `/document`)_`n")
        return $sb.ToString()
    }

    foreach ($d in $valid) {
        $path = [string]$d.Path
        $title = if ($d.Title) { [string]$d.Title } else { $path }
        [void]$sb.Append("- [$title]($path)`n")
    }
    return $sb.ToString()
}

function Get-ArchiveSummary {
    <#
    .SYNOPSIS
        Resumo de uma linha de um .md do archive: a 1ª linha de conteúdo depois do H1. Pula linha
        vazia, tabela, heading, cerca de código, link solto e o boilerplate "Feature encerrada";
        tira `>`, ênfase, crase e links markdown (o `[x](./y.md)` relativo à pasta da feature
        quebraria no catálogo, que mora um nível acima). Corta em -MaxLength. Nada útil → ''.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxLength = 220
    )

    $seenH1 = $false
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if (-not $seenH1) { if ($line -match '^#\s+') { $seenH1 = $true }; continue }
        $s = ($line.Trim() -replace '^>\s*', '').Trim()
        if (-not $s -or $s -match '^(\||#|---|```|\[)' -or $s -match '^(?i)feature encerrada') { continue }
        $s = [regex]::Replace($s, '\[([^\]]*)\]\([^)]*\)', '$1')
        $s = (($s -replace '[*`]', '') -replace '\s+', ' ').Trim()
        if (-not $s) { continue }
        if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength).TrimEnd() + '…' }
        return $s
    }
    return ''
}

function Get-ArchiveInventory {
    <#
    .SYNOPSIS
        Inventaria `.claude/sdd/archive/` -> uma entrada por pasta de feature:
        { Feature; File; Title; Summary }. Fonte de cada linha, em ordem: o SHIPPED_*.md (o registro
        do que foi entregue), senão o DEFINE_*.md, senão o 1º .md da pasta. Ordenado por Feature
        (determinístico). Diretório ausente => coleção vazia (não é erro). Insumo de Build-ArchiveIndex.
    .OUTPUTS
        [pscustomobject[]]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ArchiveDir)

    if (-not (Test-Path -LiteralPath $ArchiveDir -PathType Container)) { return @() }
    $inv = foreach ($d in @(Get-ChildItem -LiteralPath $ArchiveDir -Directory -ErrorAction SilentlyContinue)) {
        $mds = @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.md' -File -ErrorAction SilentlyContinue |
                Sort-Object { [string]$_.Name })
        if ($mds.Count -eq 0) { continue }
        $src = $mds | Where-Object { $_.Name -like 'SHIPPED_*' } | Select-Object -First 1
        if (-not $src) { $src = $mds | Where-Object { $_.Name -like 'DEFINE_*' } | Select-Object -First 1 }
        if (-not $src) { $src = $mds | Select-Object -First 1 }
        [pscustomobject]@{
            Feature = $d.Name
            File    = $src.Name
            Title   = (Get-DocTitle -Path $src.FullName)
            Summary = (Get-ArchiveSummary -Path $src.FullName)
        }
    }
    return @($inv | Sort-Object { [string]$_.Feature })
}

function Build-ArchiveIndex {
    <#
    .SYNOPSIS
        Monta o conteúdo de `.claude/sdd/archive/_index.md`: uma linha por feature arquivada (link +
        título + resumo). É o catálogo que a busca por significado lê PRIMEIRO
        (postures/semantic-search.md): o modelo casa a pergunta parafraseada com ~1 linha por
        feature, em vez de depender da palavra exata no Grep. Saída determinística (ordenação por
        Feature, sem timestamp) → rodar 2x gera texto idêntico.
    .PARAMETER Entries
        Coleção de { Feature; File; Title; Summary } (de Get-ArchiveInventory).
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("# .claude/sdd/archive/_index.md — gerado por /sync-context, não editar à mão`n")
    [void]$sb.Append("generated_by: sync-context`n`n")

    $valid = @($Entries | Where-Object { $_.Feature -and $_.File } | Sort-Object { [string]$_.Feature })
    if ($valid.Count -eq 0) {
        [void]$sb.Append("_(sem features arquivadas ainda — o ``/ship`` move cada feature para cá)_`n")
        return $sb.ToString()
    }

    foreach ($e in $valid) {
        $line = "- [$($e.Feature)/]($($e.Feature)/$($e.File))"
        if ($e.Title)   { $line += " — $($e.Title)" }
        if ($e.Summary) { $line += " — $($e.Summary)" }
        [void]$sb.Append("$line`n")
    }
    return $sb.ToString()
}

function Update-MarkedRegion {
    <#
    .SYNOPSIS
        Substitui o conteúdo entre <!-- sync-context:start:NAME --> e <!-- sync-context:end:NAME -->.
        Fail-safe: marcador ausente/malformado => não altera o texto e reporta erro (não lança).
    .OUTPUTS
        [pscustomobject] @{ Text; Changed; Ok; Error }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$NewContent
    )

    $startMark = "<!-- sync-context:start:$Name -->"
    $endMark   = "<!-- sync-context:end:$Name -->"

    $si = $Text.IndexOf($startMark)
    $ei = $Text.IndexOf($endMark)

    if ($si -lt 0 -or $ei -lt 0) {
        return [pscustomobject]@{ Text = $Text; Changed = $false; Ok = $false
            Error = "marcador ausente para a região '$Name'" }
    }
    if ($ei -lt $si) {
        return [pscustomobject]@{ Text = $Text; Changed = $false; Ok = $false
            Error = "marcadores fora de ordem para a região '$Name' (end antes de start)" }
    }

    $before = $Text.Substring(0, $si + $startMark.Length)
    $after  = $Text.Substring($ei)
    $rebuilt = $before + "`n" + $NewContent + "`n" + $after

    return [pscustomobject]@{
        Text    = $rebuilt
        Changed = ($rebuilt -ne $Text)
        Ok      = $true
        Error   = $null
    }
}

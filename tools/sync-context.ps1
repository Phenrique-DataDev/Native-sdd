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

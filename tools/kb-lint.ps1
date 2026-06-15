<#
.SYNOPSIS
    Lint da KB do scaffold: valida o frontmatter de entradas .md e o schema dos planos de onda.

.DESCRIPTION
    Funções puras (sem efeitos colaterais) usadas pela validação automática do G3
    (/train-kb) e reaproveitáveis pela curadoria/sync (G4/G5). Não dependem de módulo YAML —
    o frontmatter da KB e o plano de onda são planos o suficiente (key: value entre cercas
    '---' no .md; key: value de topo no .yaml da onda).

    Contrato de frontmatter de uma entrada KB (.claude/kb/<camada>/<domínio>/<tipo>/<id>.md):
      - bloco frontmatter presente
      - id:           presente e kebab-case (^[a-z0-9]+(-[a-z0-9]+)*$)
      - layer:        ∈ business | tools | implementation | operations
      - domain:       presente e não-vazio
      - content_type: ∈ concept | pattern | reference | spec | runbook | index | quick-reference
      - status:       ∈ active | scaffolded | wip | deprecated | archived | unverified
    Proveniência (condicional — só quando layer == tools e source == context7):
      - lib_id:     presente e não-vazio
      - checked_at: formato YYYY-MM-DD
      (proveniência ausente em entrada tools NÃO é erro; só marca Verified=$false)

    Contrato do plano de onda (.claude/kb/_waves/<NN>-<camada>-<domínio>.yaml):
      - wave, target_layer (∈ 4 camadas), domain, status (∈ pending|running|done), subagent
      - se target_layer == tools → exige a chave 'libs'
#>

Set-StrictMode -Version Latest

$script:KbLayers       = @('business', 'tools', 'implementation', 'operations')
$script:KbContentTypes = @('concept', 'pattern', 'reference', 'spec', 'runbook', 'index', 'quick-reference')
$script:KbStatuses     = @('active', 'scaffolded', 'wip', 'deprecated', 'archived', 'unverified')
$script:WaveStatuses   = @('pending', 'running', 'done')

# Orçamento de tamanho por entrada (ADVISORY — informativo, nunca impeditivo). Conta o CORPO em
# chars, excluindo frontmatter e fenced code. Tradução aproximada ~4 chars/token. Ponto único e
# afinável; generoso de propósito (sinaliza só o que destoa). Ver DESIGN_KB_CHAR_LIMIT.md (B7).
$script:KbSizeBudgetDefault = 16000          # ~4000 tokens — concept/pattern/reference
$script:KbSizeBudget = @{
    'quick-reference' = 4800                 # ~1200 tok — deve ser curto
    'index'           = 4800
    'runbook'         = 32000                # ~8000 tok — legitimamente longo
    'spec'            = 32000
}

function Read-KbFrontmatter {
    <#
    .SYNOPSIS
        Extrai o frontmatter (hashtable key->value) de um .md. $null se não houver bloco.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    if ($lines.Count -lt 2 -or $lines[0].Trim() -ne '---') { return $null }

    $fm = [ordered]@{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim() -eq '---') { return $fm }   # fecha o bloco
        $idx = $line.IndexOf(':')
        if ($idx -lt 1) { continue }                  # linha de continuação/array — ignora
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        if ($key) { $fm[$key] = $val }
    }
    return $null   # cerca de fechamento ausente => frontmatter malformado
}

function Test-KbFrontmatter {
    <#
    .SYNOPSIS
        Valida o frontmatter de uma entrada KB. Retorna Valid/Verified/Id/Layer/Domain/Errors.
    .OUTPUTS
        [pscustomobject] @{ Path; Id; Layer; Domain; Valid; Verified; Errors }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $errors = [System.Collections.Generic.List[string]]::new()
    $fm = Read-KbFrontmatter -Path $Path

    if ($null -eq $fm) {
        $errors.Add('frontmatter ausente ou malformado (esperado bloco entre cercas ---)')
        return [pscustomobject]@{
            Path = $Path; Id = $null; Layer = $null; Domain = $null
            Valid = $false; Verified = $false; Errors = $errors.ToArray()
        }
    }

    $id     = if ($fm.Contains('id')) { $fm['id'] } else { $null }
    $layer  = if ($fm.Contains('layer')) { $fm['layer'] } else { $null }
    $domain = if ($fm.Contains('domain')) { $fm['domain'] } else { $null }

    if ([string]::IsNullOrWhiteSpace($id)) {
        $errors.Add("chave 'id' ausente ou vazia")
    }
    elseif ($id -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
        $errors.Add("'id' não é kebab-case: '$id'")
    }

    if ([string]::IsNullOrWhiteSpace($layer)) {
        $errors.Add("chave 'layer' ausente ou vazia")
    }
    elseif ($layer -notin $script:KbLayers) {
        $errors.Add("'layer' fora do vocabulário: '$layer' (esperado: $($script:KbLayers -join ', '))")
    }

    if ([string]::IsNullOrWhiteSpace($domain)) {
        $errors.Add("chave 'domain' ausente ou vazia")
    }

    $ct = if ($fm.Contains('content_type')) { $fm['content_type'] } else { $null }
    if ([string]::IsNullOrWhiteSpace($ct)) {
        $errors.Add("chave 'content_type' ausente ou vazia")
    }
    elseif ($ct -notin $script:KbContentTypes) {
        $errors.Add("'content_type' fora do vocabulário: '$ct'")
    }

    $status = if ($fm.Contains('status')) { $fm['status'] } else { $null }
    if ([string]::IsNullOrWhiteSpace($status)) {
        $errors.Add("chave 'status' ausente ou vazia")
    }
    elseif ($status -notin $script:KbStatuses) {
        $errors.Add("'status' fora do vocabulário: '$status'")
    }

    # Proveniência (condicional): só exige quando é tools/ declarando source: context7.
    $source     = if ($fm.Contains('source')) { $fm['source'] } else { $null }
    $libId      = if ($fm.Contains('lib_id')) { $fm['lib_id'] } else { $null }
    $checkedAt  = if ($fm.Contains('checked_at')) { $fm['checked_at'] } else { $null }
    $claimsC7   = ($layer -eq 'tools') -and ($source -eq 'context7')

    if ($claimsC7) {
        if ([string]::IsNullOrWhiteSpace($libId)) {
            $errors.Add("entrada tools/ com source: context7 exige 'lib_id'")
        }
        if ([string]::IsNullOrWhiteSpace($checkedAt)) {
            $errors.Add("entrada tools/ com source: context7 exige 'checked_at'")
        }
        elseif ($checkedAt -notmatch '^\d{4}-\d{2}-\d{2}$') {
            $errors.Add("'checked_at' fora do formato YYYY-MM-DD: '$checkedAt'")
        }
    }

    # Verified: o conhecimento foi confirmado contra doc atual?
    #   - não-tools → context7 não se aplica => considerado verificado
    #   - tools     → verificado se source: context7 com lib_id + checked_at e status != unverified
    $verified =
        if ($status -eq 'unverified') { $false }
        elseif ($layer -ne 'tools')   { $true }
        else { $claimsC7 -and -not [string]::IsNullOrWhiteSpace($libId) -and -not [string]::IsNullOrWhiteSpace($checkedAt) }

    return [pscustomobject]@{
        Path     = $Path
        Id       = $id
        Layer    = $layer
        Domain   = $domain
        Valid    = ($errors.Count -eq 0)
        Verified = $verified
        Errors   = $errors.ToArray()
    }
}

function Get-KbBudget {
    <#
    .SYNOPSIS
        Orçamento de tamanho (chars) para um content_type. Override por tipo ou default global.
        Tipo vazio/desconhecido => default. Função pura; nunca lança.
    #>
    [CmdletBinding()]
    param([string]$ContentType)

    if ($ContentType -and $script:KbSizeBudget.ContainsKey($ContentType)) {
        return $script:KbSizeBudget[$ContentType]
    }
    return $script:KbSizeBudgetDefault
}

function Measure-KbContentSize {
    <#
    .SYNOPSIS
        Conta os chars do corpo EXCLUINDO fenced code blocks (``` ou ~~~). A própria cerca e o
        conteúdo entre cercas não contam (código não é inchaço). Fence aberto e nunca fechado:
        descarta até o fim (conservador — nunca infla). Função pura; nunca lança.
    .OUTPUTS
        [int] — chars das linhas mantidas, unidas por "`n". Corpo vazio/só-código => 0.
    #>
    [CmdletBinding()]
    param([string[]]$BodyLines)

    if (-not $BodyLines) { return 0 }

    $kept = [System.Collections.Generic.List[string]]::new()
    $inFence = $false
    foreach ($line in $BodyLines) {
        if ($line -match '^\s*(```|~~~)') {
            $inFence = -not $inFence
            continue                          # a própria cerca não conta
        }
        if ($inFence) { continue }            # conteúdo do bloco de código não conta
        $kept.Add($line)
    }
    if ($kept.Count -eq 0) { return 0 }
    return (($kept -join "`n").Length)
}

function Read-KbBody {
    <#
    .SYNOPSIS
        Extrai as linhas do CORPO de uma entrada .md (após a cerca de fechamento do frontmatter).
        Sem frontmatter, ou cerca de fechamento ausente => o arquivo inteiro é o corpo (degradação
        segura; a invalidez do frontmatter é reportada à parte por Test-KbFrontmatter).
    .OUTPUTS
        [string[]] — linhas do corpo (vazio se não houver).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }

    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    if ($lines.Count -lt 1) { return @() }
    if ($lines[0].Trim() -ne '---') { return $lines }     # sem frontmatter => tudo é corpo

    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') {                # cerca de fechamento
            if ($i + 1 -ge $lines.Count) { return @() }   # frontmatter sem corpo
            return $lines[($i + 1)..($lines.Count - 1)]
        }
    }
    return $lines                                          # cerca de fechamento ausente => tudo é corpo
}

function Test-KbEntrySize {
    <#
    .SYNOPSIS
        Mede o corpo de uma entrada KB contra o orçamento do seu content_type. ADVISORY: o veredito
        (OverBudget) é informativo e NÃO altera a validade do frontmatter. `size_exempt: true` no
        frontmatter pula o check.
    .OUTPUTS
        [pscustomobject] @{ Path; ContentType; Size; Budget; Exempt; OverBudget }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $fm = Read-KbFrontmatter -Path $Path
    $contentType = if ($fm -and $fm.Contains('content_type')) { $fm['content_type'] } else { $null }
    $exemptRaw   = if ($fm -and $fm.Contains('size_exempt'))  { $fm['size_exempt'] }  else { $null }
    $exempt = (-not [string]::IsNullOrWhiteSpace($exemptRaw)) -and ($exemptRaw.Trim().ToLowerInvariant() -eq 'true')

    $size   = Measure-KbContentSize -BodyLines (Read-KbBody -Path $Path)
    $budget = Get-KbBudget -ContentType $contentType
    $over   = (-not $exempt) -and ($size -gt $budget)

    return [pscustomobject]@{
        Path        = $Path
        ContentType = $contentType
        Size        = $size
        Budget      = $budget
        Exempt      = $exempt
        OverBudget  = $over
    }
}

function Get-KbInventory {
    <#
    .SYNOPSIS
        Inventaria as entradas KB de um diretório (recursivo) e detecta colisão de 'id'
        DENTRO do mesmo domínio (o mesmo id pode existir em domínios diferentes).
    .OUTPUTS
        [pscustomobject[]] um por .md, com Path/Id/Layer/Domain/Valid/Verified/Errors.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }

    # Ignora auxiliares (_ABOUT.md, _TEMPLATE.md, _index.yaml etc.).
    $files = Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Name.StartsWith('_') }
    $results = foreach ($f in $files) { Test-KbFrontmatter -Path $f.FullName }
    $results = @($results)

    # colisão de id por domínio: agrupa por "domain/id"
    $dupes = $results |
        Where-Object { $_.Id -and $_.Domain } |
        Group-Object { "$($_.Domain)/$($_.Id)" } |
        Where-Object { $_.Count -gt 1 } |
        Select-Object -ExpandProperty Name

    if ($dupes) {
        foreach ($r in $results) {
            if ($r.Id -and $r.Domain -and ("$($r.Domain)/$($r.Id)" -in $dupes)) {
                $r.Errors = @($r.Errors) + "colisão de 'id' no domínio '$($r.Domain)': '$($r.Id)' aparece em mais de uma entrada"
                $r.Valid = $false
            }
        }
    }

    # Sinal ADITIVO de tamanho (advisory): não toca Valid/Verified/Errors nem a assinatura que
    # init.ps1/sync-context.ps1 consomem. Consumidores antigos ignoram estes campos.
    foreach ($r in $results) {
        $sz = Test-KbEntrySize -Path $r.Path
        $r | Add-Member -NotePropertyName ContentType -NotePropertyValue $sz.ContentType -Force
        $r | Add-Member -NotePropertyName Size        -NotePropertyValue $sz.Size        -Force
        $r | Add-Member -NotePropertyName Budget      -NotePropertyValue $sz.Budget      -Force
        $r | Add-Member -NotePropertyName Exempt      -NotePropertyValue $sz.Exempt      -Force
        $r | Add-Member -NotePropertyName OverBudget  -NotePropertyValue $sz.OverBudget  -Force
    }

    return $results
}

function Test-WavePlan {
    <#
    .SYNOPSIS
        Valida o schema mínimo de um plano de onda (.yaml). Retorna Valid/Wave/Errors.
    .OUTPUTS
        [pscustomobject] @{ Path; Wave; Valid; Errors }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $errors = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $errors.Add('arquivo de onda inexistente')
        return [pscustomobject]@{ Path = $Path; Wave = $null; Valid = $false; Errors = $errors.ToArray() }
    }

    # Parse plano: chaves de topo (sem indentação) key: value. Listas/aninhados são ignorados
    # aqui — só checamos presença da CHAVE 'libs' quando necessário.
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    $top = [ordered]@{}
    $topKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\S') {
            $idx = $line.IndexOf(':')
            if ($idx -lt 1) { continue }
            $key = $line.Substring(0, $idx).Trim()
            $val = $line.Substring($idx + 1).Trim()
            if ($key) { $top[$key] = $val; [void]$topKeys.Add($key) }
        }
    }

    $wave = if ($top.Contains('wave')) { $top['wave'] } else { $null }
    if ([string]::IsNullOrWhiteSpace($wave)) { $errors.Add("chave 'wave' ausente ou vazia") }

    $layer = if ($top.Contains('target_layer')) { $top['target_layer'] } else { $null }
    if ([string]::IsNullOrWhiteSpace($layer)) {
        $errors.Add("chave 'target_layer' ausente ou vazia")
    }
    elseif ($layer -notin $script:KbLayers) {
        $errors.Add("'target_layer' fora do vocabulário: '$layer'")
    }

    if (-not $top.Contains('domain') -or [string]::IsNullOrWhiteSpace($top['domain'])) {
        $errors.Add("chave 'domain' ausente ou vazia")
    }

    $status = if ($top.Contains('status')) { $top['status'] } else { $null }
    if ([string]::IsNullOrWhiteSpace($status)) {
        $errors.Add("chave 'status' ausente ou vazia")
    }
    elseif ($status -notin $script:WaveStatuses) {
        $errors.Add("'status' da onda fora do vocabulário: '$status' (esperado: $($script:WaveStatuses -join ', '))")
    }

    if (-not $top.Contains('subagent') -or [string]::IsNullOrWhiteSpace($top['subagent'])) {
        $errors.Add("chave 'subagent' ausente ou vazia")
    }

    # Condicional: onda tools/ precisa declarar 'libs' (a chave existe mesmo que os itens
    # estejam indentados nas linhas seguintes).
    if ($layer -eq 'tools' -and ($topKeys -notcontains 'libs')) {
        $errors.Add("onda com target_layer: tools exige a chave 'libs'")
    }

    return [pscustomobject]@{
        Path   = $Path
        Wave   = $wave
        Valid  = ($errors.Count -eq 0)
        Errors = $errors.ToArray()
    }
}

function Format-KbBudgetAdvisory {
    <#
    .SYNOPSIS
        Texto ADVISORY (custo×benefício) das entradas acima do orçamento de tamanho. Educar ≠ barrar:
        explica o trade-off e as 3 saídas, sem rótulo de erro. Vazio ('') se nenhuma entrada estoura.
        Reusável por /sync-context e pelo futuro curation-nudge. Função pura; nunca lança.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param([object[]]$Inventory)

    if (-not $Inventory) { return '' }
    $over = @($Inventory | Where-Object { $_.PSObject.Properties['OverBudget'] -and $_.OverBudget })
    if ($over.Count -eq 0) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('KB · orçamento de tamanho (advisory — informativo, não impeditivo)')
    foreach ($e in $over) {
        $id  = if ($e.PSObject.Properties['Id'] -and $e.Id) { $e.Id } else { Split-Path -Leaf $e.Path }
        $tok = [math]::Round($e.Size / 4)
        [void]$sb.AppendLine(("  {0} [{1}]  {2}/{3} chars  (~{4} tok)" -f $id, $e.ContentType, $e.Size, $e.Budget, $tok))
    }
    [void]$sb.AppendLine('Por quê: cada entrada entra inteira no contexto; entradas enxutas economizam tokens e melhoram a recuperação.')
    [void]$sb.AppendLine('Saídas: (1) dividir em entradas atômicas · (2) isentar com `size_exempt: true` no frontmatter · (3) aceitar — nada bloqueia. Código em fenced block já é ignorado na contagem.')
    return $sb.ToString().TrimEnd()
}

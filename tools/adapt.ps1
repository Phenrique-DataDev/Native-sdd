<#
.SYNOPSIS
    Detecção/diagnóstico do G5 (/adapt): infere a stack e a higiene de um projeto existente
    (brownfield) para guiar a adoção da metodologia, sem tocar no repo-alvo.

.DESCRIPTION
    Funções puras (read-only, determinísticas) usadas pela validação automática do G5 e pelo
    comando em runtime. Detectam por PRESENÇA de manifestos/arquivos-sinal (glob), sem parsear
    conteúdo — barato e estável.

      Get-StackSignals   -> [pscustomobject[]] { Tech; Evidence[] }   (vazio se nada)
      Get-ProjectHygiene -> [pscustomobject]   { HasTests; HasCI; HasDocs; Evidence }
      Format-AdaptReport -> [string]           relatório determinístico (sem timestamp)

    Nada escreve no repo-alvo. Gravar o project-context.md e delegar ao /init são ações de
    runtime (sob confirmação), fora deste módulo. Determinismo: ordenação estável; sem datas.

    Feature ABSORVER (2026-07-05): quando o repo-alvo JÁ tem .claude/ não-trivial, inventaria os
    ativos contra o baseline do scaffold em vez de só avisar — ver
    .claude/sdd/features/DESIGN_ABSORVER.md.

      Test-AbsorptionApplicable -> [bool]              .claude/ não-trivial no repo-alvo?
      Resolve-AdaptBaselineRoot -> [string] | $null     raiz do baseline (cascata)
      Get-ClaudeAssetInventory  -> [pscustomobject[]]   { RelativePath; Bucket; Note }
      Compare-ClaudeSettingsKeys -> [pscustomobject[]]  { KeyPath; Bucket; TargetValue; BaselineValue }
      Format-AbsorptionReport   -> [string]             relatório determinístico (sem timestamp)
      Add-AdditiveAssets        -> [pscustomobject[]]   ÚNICA função mutadora — só copia itens Additive
#>

Set-StrictMode -Version Latest

# Manifestos/arquivos-sinal -> tecnologia (MVP). Cada padrão é um glob relativo à raiz,
# avaliado de forma recursiva curta (o sinal pode estar em subpasta de monorepo).
$script:StackMap = [ordered]@{
    python    = @('pyproject.toml', 'requirements.txt', 'setup.py')
    node      = @('package.json')
    dbt       = @('dbt_project.yml')
    go        = @('go.mod')
    dotnet    = @('*.csproj', '*.sln')
    docker    = @('Dockerfile', 'compose.yml', 'compose.yaml', 'docker-compose.yml')
    terraform = @('*.tf')
}

# Feature ABSORVER — escopo de ativos inventariados (DEFINE_ABSORVER.md): pastas soltas dentro
# de .claude/ (arquivo a arquivo) + os 2 arquivos de contexto na raiz. settings.json é tratado
# à parte (Compare-ClaudeSettingsKeys, diff por chave — JSON estruturado, não arquivo solto).
# .claude/commands/ e .claude/sdd/ ficam FORA de propósito (fora do escopo confirmado no DEFINE).
$script:AbsorptionAssetDirs  = @('skills', 'agents', 'kb', 'rules', 'hooks')
$script:AbsorptionRootFiles  = @('CLAUDE.md', 'AGENTS.md')
$script:AbsorptionSettingsFile = 'settings.json'

function Get-FilesMatching {
    <#
    .SYNOPSIS
        Nomes de arquivo (relativos a -Root) que casam um glob, recursivo. Read-only e ordenado.
        Ignora ruído comum (.git, node_modules, .venv) para não inflar a evidência.
    .OUTPUTS
        [string[]]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Pattern
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }

    $ignore = '\\(\.git|node_modules|\.venv|venv|__pycache__|dist|build)\\'
    $rootFull = (Resolve-Path -LiteralPath $Root).Path
    $hits = Get-ChildItem -LiteralPath $Root -Filter $Pattern -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $ignore } |
        ForEach-Object { $_.FullName.Substring($rootFull.Length).TrimStart('\', '/') -replace '\\', '/' }
    return @($hits | Sort-Object -Unique)
}

function Get-StackSignals {
    <#
    .SYNOPSIS
        Infere a stack do repo-alvo por presença de manifestos. Um objeto por tecnologia
        detectada (ordenado por Tech). Coleção vazia se nada for reconhecido (não inventa).
    .OUTPUTS
        [pscustomobject[]] { Tech; Evidence[] }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $result = foreach ($tech in $script:StackMap.Keys) {
        $evidence = foreach ($pat in $script:StackMap[$tech]) {
            Get-FilesMatching -Root $Root -Pattern $pat
        }
        $evidence = @($evidence | Sort-Object -Unique)
        if ($evidence.Count -gt 0) {
            [pscustomobject]@{ Tech = $tech; Evidence = $evidence }
        }
    }
    return @($result | Sort-Object Tech)
}

function Get-ProjectHygiene {
    <#
    .SYNOPSIS
        Gap-analysis de higiene retroativa nas 3 dimensões: Testes, CI, Docs/convenções.
        Cada flag = existe >=1 sinal da dimensão. Read-only.
    .OUTPUTS
        [pscustomobject] { HasTests; HasCI; HasDocs; Evidence }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    # Testes: pasta tests/ OU arquivos de teste comuns.
    $testHits = @()
    if (Test-Path -LiteralPath (Join-Path $Root 'tests') -PathType Container) { $testHits += 'tests/' }
    foreach ($pat in '*.Tests.ps1', '*_test.go', 'test_*.py', '*_test.py', '*.test.js', '*.spec.ts') {
        $testHits += Get-FilesMatching -Root $Root -Pattern $pat
    }
    $testHits = @($testHits | Sort-Object -Unique)

    # CI: pipelines comuns.
    $ciHits = @()
    $ciHits += Get-FilesMatching -Root $Root -Pattern '*.yml' | Where-Object { $_ -match '^\.github/workflows/' }
    $ciHits += Get-FilesMatching -Root $Root -Pattern '*.yaml' | Where-Object { $_ -match '^\.github/workflows/' }
    foreach ($f in '.gitlab-ci.yml', 'azure-pipelines.yml') {
        if (Test-Path -LiteralPath (Join-Path $Root $f) -PathType Leaf) { $ciHits += $f }
    }
    $ciHits = @($ciHits | Sort-Object -Unique)

    # Docs/convenções: README não-trivial (>10 linhas) e/ou contexto de IA (CLAUDE/AGENTS) e/ou convenções.
    $docHits = @()
    foreach ($r in 'README.md', 'README') {
        $p = Join-Path $Root $r
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $lines = @(Get-Content -LiteralPath $p -ErrorAction SilentlyContinue)
            if ($lines.Count -gt 10) { $docHits += $r }
        }
    }
    foreach ($f in 'CLAUDE.md', 'AGENTS.md', 'CONTRIBUTING.md') {
        if (Test-Path -LiteralPath (Join-Path $Root $f) -PathType Leaf) { $docHits += $f }
    }
    $docHits = @($docHits | Sort-Object -Unique)

    return [pscustomobject]@{
        HasTests = [bool]($testHits.Count -gt 0)
        HasCI    = [bool]($ciHits.Count   -gt 0)
        HasDocs  = [bool]($docHits.Count  -gt 0)
        Evidence = [pscustomobject]@{
            Tests = $testHits
            CI    = $ciHits
            Docs  = $docHits
        }
    }
}

function Format-AdaptReport {
    <#
    .SYNOPSIS
        Relatório determinístico do diagnóstico brownfield: stack inferida + checklist de higiene
        + retro-ondas (uma recomendação por dimensão em falta). Sem timestamp.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Stack = @(),
        [Parameter(Mandatory)][psobject]$Hygiene
    )

    $Stack = @($Stack | Where-Object { $null -ne $_ })

    # texto fixo da retro-onda por dimensão (só entra quando a dimensão está em falta)
    $retro = [ordered]@{
        Tests = 'Testes: criar suíte cobrindo o código existente'
        CI    = 'CI: adicionar pipeline (lint + testes) em .github/workflows/'
        Docs  = 'Docs: criar README útil + contexto de IA (CLAUDE.md/AGENTS.md)'
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    [void]$sb.Append("ADAPT — diagnóstico do projeto`n")

    if (@($Stack).Count -gt 0) {
        $parts = foreach ($s in (@($Stack) | Sort-Object Tech)) {
            "$($s.Tech) ($((@($s.Evidence) | Sort-Object) -join ', '))"
        }
        [void]$sb.Append("Stack inferida: $($parts -join '; ')`n")
    } else {
        [void]$sb.Append("Stack inferida: (nenhum manifesto reconhecido)`n")
    }

    [void]$sb.Append("Higiene:`n")
    [void]$sb.Append("  [$(if($Hygiene.HasTests){'✓'}else{'✗'})] Testes`n")
    [void]$sb.Append("  [$(if($Hygiene.HasCI){'✓'}else{'✗'})] CI`n")
    [void]$sb.Append("  [$(if($Hygiene.HasDocs){'✓'}else{'✗'})] Docs/convenções`n")

    $missing = @()
    if (-not $Hygiene.HasTests) { $missing += $retro['Tests'] }
    if (-not $Hygiene.HasCI)    { $missing += $retro['CI'] }
    if (-not $Hygiene.HasDocs)  { $missing += $retro['Docs'] }

    if ($missing.Count -gt 0) {
        [void]$sb.Append("Retro-ondas sugeridas:`n")
        foreach ($m in $missing) { [void]$sb.Append("  - $m`n") }
    } else {
        [void]$sb.Append("Retro-ondas sugeridas: nenhuma (higiene completa)`n")
    }

    [void]$sb.Append("Próximo: confirmar contexto e rodar /init`n")
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    return $sb.ToString()
}

# ─────────────────────────────────────────────────────────────────────────
# Feature ABSORVER (2026-07-05) — absorção de ativos .claude/ pré-existentes
# ─────────────────────────────────────────────────────────────────────────

function Test-AbsorptionApplicable {
    <#
    .SYNOPSIS
        true se o projeto-alvo já tem .claude/ NÃO-TRIVIAL (>=1 ativo relevante) — decide se o
        /adapt entra em modo absorção. false preserva o comportamento atual do G5 (AT-005: repo
        sem .claude/ não muda de comportamento). Read-only.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $claudeDir = Join-Path $Root '.claude'
    if (-not (Test-Path -LiteralPath $claudeDir -PathType Container)) { return $false }

    foreach ($dir in $script:AbsorptionAssetDirs) {
        $sub = Join-Path $claudeDir $dir
        if ((Test-Path -LiteralPath $sub -PathType Container) -and
            (Get-ChildItem -LiteralPath $sub -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            return $true
        }
    }
    if (Test-Path -LiteralPath (Join-Path $claudeDir $script:AbsorptionSettingsFile) -PathType Leaf) { return $true }
    foreach ($rf in $script:AbsorptionRootFiles) {
        if (Test-Path -LiteralPath (Join-Path $Root $rf) -PathType Leaf) { return $true }
    }
    return $false
}

function Resolve-AdaptBaselineRoot {
    <#
    .SYNOPSIS
        Resolve a raiz do baseline (.claude/ do scaffold) pela cascata: relativo ao cwd (rodando
        neste próprio repo) -> $env:SDD_WORKFLOW_HOME/... -> $null (degradação consciente, ver
        rules/tooling.md — mesma cascata, aplicada ao CONTEÚDO do scaffold, não só à camada
        tools/). $env:SDD_WORKFLOW_HOME é a raiz do repo clonado (onboarding/windows/lib.ps1).
    .OUTPUTS
        [string] ou $null
    #>
    [CmdletBinding()]
    param([string]$Cwd = (Get-Location).Path)

    $relative = Join-Path $Cwd 'templates/project-scaffold/.claude'
    if (Test-Path -LiteralPath $relative -PathType Container) { return $relative }

    if ($env:SDD_WORKFLOW_HOME) {
        $viaEnv = Join-Path $env:SDD_WORKFLOW_HOME 'templates/project-scaffold/.claude'
        if (Test-Path -LiteralPath $viaEnv -PathType Container) { return $viaEnv }
    }

    return $null
}

function Get-ClaudeAssetInventory {
    <#
    .SYNOPSIS
        Inventaria ativos .claude/{skills,agents,kb,rules,hooks} + CLAUDE.md/AGENTS.md do
        projeto-alvo contra o baseline do scaffold, classificando cada caminho relativo em
        Additive (só no baseline) | Own (só no projeto) | Conflict (nos dois, diverge) |
        Unchanged (nos dois, idêntico). Read-only, determinístico (settings.json fica de fora —
        ver Compare-ClaudeSettingsKeys, que trata JSON estruturado por chave).
    .OUTPUTS
        [pscustomobject[]] { RelativePath; Bucket; Note }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$BaselineRoot
    )

    $relPaths = [ordered]@{}

    foreach ($dir in $script:AbsorptionAssetDirs) {
        $rootSub     = Join-Path (Join-Path $Root '.claude') $dir
        $baselineSub = Join-Path (Join-Path $BaselineRoot '.claude') $dir
        foreach ($f in @(Get-FilesMatching -Root $rootSub -Pattern '*'))     { $relPaths[".claude/$dir/$f"] = $true }
        foreach ($f in @(Get-FilesMatching -Root $baselineSub -Pattern '*')) { $relPaths[".claude/$dir/$f"] = $true }
    }
    foreach ($rf in $script:AbsorptionRootFiles) {
        $inRoot     = Test-Path -LiteralPath (Join-Path $Root $rf) -PathType Leaf
        $inBaseline = Test-Path -LiteralPath (Join-Path $BaselineRoot $rf) -PathType Leaf
        if ($inRoot -or $inBaseline) { $relPaths[$rf] = $true }
    }

    $result = foreach ($rel in ($relPaths.Keys | Sort-Object)) {
        $rootPath     = Join-Path $Root $rel
        $baselinePath = Join-Path $BaselineRoot $rel
        $inRoot       = Test-Path -LiteralPath $rootPath -PathType Leaf
        $inBaseline   = Test-Path -LiteralPath $baselinePath -PathType Leaf

        $bucket = $null
        $note   = $null

        if ($inRoot -and -not $inBaseline) {
            $bucket = 'Own'; $note = 'só no projeto'
        }
        elseif (-not $inRoot -and $inBaseline) {
            $bucket = 'Additive'; $note = 'só no baseline'
        }
        else {
            try {
                $rootText     = Get-Content -LiteralPath $rootPath -Raw -ErrorAction Stop
                $baselineText = Get-Content -LiteralPath $baselinePath -Raw -ErrorAction Stop
                if ($rootText -eq $baselineText) { $bucket = 'Unchanged'; $note = 'idêntico ao baseline' }
                else                             { $bucket = 'Conflict';  $note = 'diverge do baseline — preservado' }
            } catch {
                $bucket = 'Conflict'; $note = 'conteúdo não comparável (erro de leitura)'
            }
        }

        [pscustomobject]@{ RelativePath = $rel; Bucket = $bucket; Note = $note }
    }
    return @($result)
}

function ConvertFrom-JsonOrNull {
    <# .SYNOPSIS texto JSON -> objeto; vazio/whitespace -> objeto vazio; malformado -> $null. #>
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return [pscustomobject]@{} }
    try { return (ConvertFrom-Json -InputObject $Text -ErrorAction Stop) }
    catch { return $null }
}

function Get-JsonSubKeyNames {
    <#
    .SYNOPSIS
        Nomes de propriedade de um bloco JSON; $null -> nenhum. Itera a COLEÇÃO
        .PSObject.Properties (nunca .Properties.Name direto): num objeto SEM propriedades
        (ex.: "hooks": {}) acessar .Name lança sob StrictMode Latest — mesmo bug documentado e
        corrigido em tools/config-lint.ps1 (Get-JsonProperty).
    #>
    [CmdletBinding()]
    param($Block)

    if ($null -eq $Block) { return @() }
    $names = foreach ($prop in $Block.PSObject.Properties) { $prop.Name }
    return @($names)
}

function Get-JsonSubKeyValue {
    <#
    .SYNOPSIS
        Valor de uma propriedade do bloco JSON, ou $null se ausente/bloco $null — via indexador
        .Properties[$Name] (StrictMode-safe mesmo em objeto sem propriedades), espelhando
        Get-JsonProperty de tools/config-lint.ps1.
    #>
    [CmdletBinding()]
    param($Block, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Block) { return $null }
    $prop = $Block.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    , $prop.Value
}

function Compare-ClaudeSettingsKeys {
    <#
    .SYNOPSIS
        Compara hooks.<Event> e permissions.<allow|deny|ask> entre o settings.json do projeto e
        o do baseline, por chave (dot-path) — não aplica merge, só relata. Read-only; aceita
        texto JSON diretamente (testável sem tocar disco). Ausente/vazio em qualquer lado é
        tratado como '{}' (nunca lança — cobre projeto sem settings.json, AT-006). JSON
        malformado em qualquer lado -> coleção vazia (comparação pulada, /adapt avisa e segue).
    .OUTPUTS
        [pscustomobject[]] { KeyPath; Bucket; TargetValue; BaselineValue }
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$TargetJson,
        [AllowNull()][string]$BaselineJson
    )

    $targetObj   = ConvertFrom-JsonOrNull -Text $TargetJson
    $baselineObj = ConvertFrom-JsonOrNull -Text $BaselineJson
    if ($null -eq $targetObj -or $null -eq $baselineObj) { return @() }

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($topKey in 'hooks', 'permissions') {
        $targetBlock   = Get-JsonSubKeyValue -Block $targetObj   -Name $topKey
        $baselineBlock = Get-JsonSubKeyValue -Block $baselineObj -Name $topKey

        $subKeys = @(@(Get-JsonSubKeyNames $targetBlock) + @(Get-JsonSubKeyNames $baselineBlock) | Sort-Object -Unique)

        foreach ($sub in $subKeys) {
            $targetProp   = if ($null -ne $targetBlock)   { $targetBlock.PSObject.Properties[$sub] }   else { $null }
            $baselineProp = if ($null -ne $baselineBlock) { $baselineBlock.PSObject.Properties[$sub] } else { $null }
            $inTarget     = $null -ne $targetProp
            $inBaseline   = $null -ne $baselineProp

            $targetValue   = if ($inTarget)   { $targetProp.Value }   else { $null }
            $baselineValue = if ($inBaseline) { $baselineProp.Value } else { $null }

            $bucket =
                if ($inTarget -and -not $inBaseline) { 'Own' }
                elseif (-not $inTarget -and $inBaseline) { 'Additive' }
                else {
                    $targetNorm   = $targetValue   | ConvertTo-Json -Depth 20 -Compress
                    $baselineNorm = $baselineValue | ConvertTo-Json -Depth 20 -Compress
                    if ($targetNorm -eq $baselineNorm) { 'Unchanged' } else { 'Conflict' }
                }

            $results.Add([pscustomobject]@{
                KeyPath       = "$topKey.$sub"
                Bucket        = $bucket
                TargetValue   = $targetValue
                BaselineValue = $baselineValue
            })
        }
    }

    return @($results | Sort-Object KeyPath)
}

function Format-AbsorptionReport {
    <#
    .SYNOPSIS
        Relatório determinístico da absorção: ativos .claude/* em 3 buckets visíveis (aditivo/
        próprio/conflito — Unchanged fica fora, sem ruído) + settings.json por chave. Sem
        timestamp; ordenação estável.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Inventory = @(),
        [AllowNull()][object[]]$SettingsDiff = @()
    )

    $Inventory    = @($Inventory | Where-Object { $null -ne $_ })
    $SettingsDiff = @($SettingsDiff | Where-Object { $null -ne $_ })

    $additive = @($Inventory | Where-Object { $_.Bucket -eq 'Additive' } | Sort-Object RelativePath)
    $own      = @($Inventory | Where-Object { $_.Bucket -eq 'Own' }      | Sort-Object RelativePath)
    $conflict = @($Inventory | Where-Object { $_.Bucket -eq 'Conflict' } | Sort-Object RelativePath)

    $sAdditive = @($SettingsDiff | Where-Object { $_.Bucket -eq 'Additive' } | Sort-Object KeyPath)
    $sOwn      = @($SettingsDiff | Where-Object { $_.Bucket -eq 'Own' }      | Sort-Object KeyPath)
    $sConflict = @($SettingsDiff | Where-Object { $_.Bucket -eq 'Conflict' } | Sort-Object KeyPath)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    [void]$sb.Append("ADAPT — absorção de ativos .claude/ existentes`n")

    [void]$sb.Append("Aditivos (no baseline, ausentes no projeto — candidatos a adicionar):`n")
    if ($additive.Count -gt 0) { foreach ($i in $additive) { [void]$sb.Append("  + $($i.RelativePath)`n") } }
    else { [void]$sb.Append("  (nenhum)`n") }

    [void]$sb.Append("Próprios (só no projeto — preservados, nada a fazer):`n")
    if ($own.Count -gt 0) { foreach ($i in $own) { [void]$sb.Append("  = $($i.RelativePath)`n") } }
    else { [void]$sb.Append("  (nenhum)`n") }

    [void]$sb.Append("Conflitos (nos dois, conteúdo diverge — preservado, decisão manual):`n")
    if ($conflict.Count -gt 0) { foreach ($i in $conflict) { [void]$sb.Append("  ! $($i.RelativePath)`n") } }
    else { [void]$sb.Append("  (nenhum)`n") }

    $sAdditiveTxt = if ($sAdditive.Count -gt 0) { ($sAdditive.KeyPath -join ', ') } else { '(nenhuma)' }
    $sOwnTxt      = if ($sOwn.Count -gt 0)      { ($sOwn.KeyPath -join ', ') }      else { '(nenhuma)' }
    $sConflictTxt = if ($sConflict.Count -gt 0) { ($sConflict.KeyPath -join ', ') } else { '(nenhuma)' }
    [void]$sb.Append("settings.json — chaves aditivas: $sAdditiveTxt`n")
    [void]$sb.Append("settings.json — chaves próprias: $sOwnTxt`n")
    [void]$sb.Append("settings.json — chaves em conflito: $sConflictTxt`n")

    [void]$sb.Append("Nada foi escrito — aditivos só entram após confirmação em lote`n")
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    return $sb.ToString()
}

function Add-AdditiveAssets {
    <#
    .SYNOPSIS
        Copia para o projeto-alvo SÓ os itens classificados 'Additive' pelo
        Get-ClaudeAssetInventory. ÚNICA função mutadora deste módulo — chamada apenas após
        confirmação explícita do usuário (AskUserQuestion, runtime do /adapt). Por construção, o
        destino nunca existe ainda para um item Additive (sem -Force: se existir, falha em vez
        de sobrescrever — nunca overwrite silencioso).
    .OUTPUTS
        [pscustomobject[]] { RelativePath; Copied }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$BaselineRoot,
        [Parameter(Mandatory)][object[]]$Inventory
    )

    $additive = @($Inventory | Where-Object { $_.Bucket -eq 'Additive' } | Sort-Object RelativePath)

    $results = foreach ($item in $additive) {
        $src    = Join-Path $BaselineRoot $item.RelativePath
        $dst    = Join-Path $Root $item.RelativePath
        $dstDir = Split-Path -Parent $dst
        if ($dstDir -and -not (Test-Path -LiteralPath $dstDir -PathType Container)) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dst
        [pscustomobject]@{ RelativePath = $item.RelativePath; Copied = $true }
    }
    return @($results)
}

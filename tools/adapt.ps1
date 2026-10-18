<#
.SYNOPSIS
    Detecção/diagnóstico do G5 (/adapt): infere a stack e a higiene de um projeto existente
    (brownfield) para guiar a adoção da metodologia, sem tocar no repo-alvo.

.DESCRIPTION
    Funções puras (read-only, determinísticas) usadas pela validação automática do G5 e pelo
    comando em runtime. Detectam por PRESENÇA de manifestos/arquivos-sinal (glob), sem parsear
    conteúdo — barato e estável.

      Get-StackSignals    -> [pscustomobject[]] { Tech; Evidence[] }   (vazio se nada)
      Get-WorkspaceLayout -> [pscustomobject]   { Markers[]; Packages[] } | $null (sem monorepo)
      Get-ProjectHygiene  -> [pscustomobject]   { HasTests; HasCI; HasDocs; Evidence }
      Format-AdaptReport  -> [string]           relatório determinístico (sem timestamp)

    Exceção ao "sem parsear": o Get-WorkspaceLayout lê a chave "workspaces" do package.json da raiz.

    Nada escreve no repo-alvo. Gravar o project-context.md e delegar ao /curate são ações de
    runtime (sob confirmação), fora deste módulo. Determinismo: ordenação estável; sem datas.

    Feature ABSORVER (2026-07-05): quando o repo-alvo JÁ tem .claude/ não-trivial, inventaria os
    ativos contra o baseline do scaffold em vez de só avisar — ver
    .claude/sdd/features/DESIGN_ABSORVER.md.

      Test-AbsorptionApplicable -> [bool]              .claude/ não-trivial no repo-alvo?
      Resolve-AdaptBaselineRoot -> [string] | $null     raiz do baseline (cascata)
      Get-ClaudeAssetInventory  -> [pscustomobject[]]   { RelativePath; Bucket; Note }
      Get-CommandMappingHint    -> [pscustomobject[]]   { Command; Target; Hint } (proposta, read-only)
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
    prisma    = @('schema.prisma')
}

# Monorepo (ADAPT_STACK_PLANA_EM_MONOREPO, 2026-10-17): marcadores na raiz que dizem "isto é um
# conjunto de pacotes". Sem eles, os package.json dos apps viravam só evidência de um único node.
# Framework web (Next etc.) fica fora de propósito: é a lista que cresce sem fim.
$script:WorkspaceMarkers = @('pnpm-workspace.yaml', 'turbo.json')

# Manifestos que definem um pacote (a pasta que o contém é o pacote). Docker/terraform/prisma são
# sinal de stack, não de pacote.
$script:PackageManifests = @('package.json', 'pyproject.toml', 'go.mod', 'dbt_project.yml', '*.csproj')

# Feature ABSORVER — escopo de ativos inventariados (DEFINE_ABSORVER.md): pastas soltas dentro
# de .claude/ (arquivo a arquivo) + os 2 arquivos de contexto na raiz. settings.json é tratado
# à parte (Compare-ClaudeSettingsKeys, diff por chave — JSON estruturado, não arquivo solto).
# commands entrou em 2026-10-17 (ADAPT_IGNORA_COMMANDS_DO_PROJETO): fora do inventário, um repo
# com commands próprios ganhava os do scaffold sem aviso e ficava com dois caminhos para o mesmo
# pedido. .claude/sdd/ continua fora (é estado do ciclo, não ativo).
$script:AbsorptionAssetDirs  = @('skills', 'agents', 'kb', 'rules', 'hooks', 'commands')
$script:AbsorptionRootFiles  = @('CLAUDE.md', 'AGENTS.md')
$script:AbsorptionSettingsFile = 'settings.json'

# Proposta de mapeamento de um command próprio para o equivalente do scaffold. Casa por TOKEN do
# nome (separado por - _ . :), na ordem da tabela — heurística barata e estável, que só sugere:
# o relatório diz "proposta", nunca reescreve o command.
$script:CommandMappingHints = [ordered]@{
    brainstorm    = @('brainstorm', 'explore', 'explorar', 'ideia', 'idea')
    define        = @('define', 'requisito', 'requisitos', 'requirement', 'requirements', 'prd')
    spec          = @('spec', 'design', 'arquitetura', 'architecture', 'plan', 'plano')
    build         = @('build', 'implement', 'implementa', 'implementar')
    ship          = @('ship', 'encerrar', 'wrap')
    dev           = @('dev', 'fix', 'hotfix', 'bug', 'quick', 'task')
    'review-diff' = @('review', 'revisar', 'revisa', 'cr')
    status        = @('status', 'progress', 'progresso')
    check         = @('check', 'conformidade')
    document      = @('doc', 'docs', 'document', 'documentar', 'adr')
    setup         = @('setup', 'init', 'onboard', 'onboarding')
}

# Fase SDD de cada command de fase (o resto é "substituído por").
$script:CommandPhase = @{
    brainstorm = 'fase 0 (Brainstorm)'
    define     = 'fase 1 (Define)'
    spec       = 'fase 2 (Design)'
    build      = 'fase 3 (Build)'
    ship       = 'fase 4 (Ship)'
}

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

function Get-WorkspaceLayout {
    <#
    .SYNOPSIS
        Detecta monorepo (pnpm-workspace.yaml, turbo.json ou "workspaces" no package.json da raiz)
        e lista os pacotes um a um, com a stack de cada (Get-StackSignals na pasta do pacote).
        $null se a raiz não tem marcador de workspace. Read-only; o único conteúdo lido é a
        chave "workspaces" do package.json da raiz (JSON malformado = sem marcador).
    .OUTPUTS
        [pscustomobject] { Markers[]; Packages[] { Path; Stack[] } } ou $null
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $markers = @(foreach ($m in $script:WorkspaceMarkers) {
        if (Test-Path -LiteralPath (Join-Path $Root $m) -PathType Leaf) { $m }
    })

    $rootPkg = Join-Path $Root 'package.json'
    if (Test-Path -LiteralPath $rootPkg -PathType Leaf) {
        $pkg = ConvertFrom-JsonOrNull -Text (Get-Content -LiteralPath $rootPkg -Raw -ErrorAction SilentlyContinue)
        if ($null -ne $pkg -and $null -ne $pkg.PSObject.Properties['workspaces']) { $markers += 'package.json#workspaces' }
    }
    if ($markers.Count -eq 0) { return $null }

    $dirs = foreach ($pat in $script:PackageManifests) {
        foreach ($f in @(Get-FilesMatching -Root $Root -Pattern $pat)) {
            $dir = ($f -replace '/?[^/]+$', '')
            if ($dir) { $dir }   # a raiz é o workspace, não um pacote
        }
    }

    $packages = foreach ($dir in @($dirs | Sort-Object -Unique)) {
        [pscustomobject]@{
            Path  = $dir
            Stack = @(Get-StackSignals -Root (Join-Path $Root $dir) | ForEach-Object { $_.Tech })
        }
    }

    return [pscustomobject]@{
        Markers  = @($markers | Sort-Object)
        Packages = @($packages)
    }
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
        [Parameter(Mandatory)][psobject]$Hygiene,
        [AllowNull()][psobject]$Workspace = $null
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

    if ($null -ne $Workspace) {
        $pkgs = @($Workspace.Packages | Sort-Object Path)
        [void]$sb.Append("Monorepo ($(@($Workspace.Markers) -join ', ')): $($pkgs.Count) pacote(s)`n")
        foreach ($p in $pkgs) {
            $techs = if (@($p.Stack).Count -gt 0) { (@($p.Stack) | Sort-Object) -join ', ' } else { '(sem stack reconhecida)' }
            [void]$sb.Append("  - $($p.Path): $techs`n")
        }
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

    [void]$sb.Append("Próximo: confirmar contexto e rodar /curate`n")
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
        Resolve a raiz do baseline (templates/project-scaffold, a pasta que CONTÉM .claude/ e os
        CLAUDE.md/AGENTS.md) pela cascata: relativo ao cwd (rodando neste próprio repo) ->
        $env:SDD_WORKFLOW_HOME/... -> $null (degradação consciente, ver rules/tooling.md — mesma
        cascata, aplicada ao CONTEÚDO do scaffold, não só à camada tools/).
        $env:SDD_WORKFLOW_HOME é a raiz do repo clonado (onboarding/windows/lib.ps1).
        Até 2026-10-17 devolvia a própria .claude/, e o Get-ClaudeAssetInventory, que junta
        '.claude/<dir>' à raiz, procurava em .claude/.claude/ — o baseline real nunca tinha
        nenhum item Additive.
    .OUTPUTS
        [string] ou $null
    #>
    [CmdletBinding()]
    param([string]$Cwd = (Get-Location).Path)

    $relative = Join-Path $Cwd 'templates/project-scaffold'
    if (Test-Path -LiteralPath (Join-Path $relative '.claude') -PathType Container) { return $relative }

    if ($env:SDD_WORKFLOW_HOME) {
        $viaEnv = Join-Path $env:SDD_WORKFLOW_HOME 'templates/project-scaffold'
        if (Test-Path -LiteralPath (Join-Path $viaEnv '.claude') -PathType Container) { return $viaEnv }
    }

    return $null
}

function Get-ClaudeAssetInventory {
    <#
    .SYNOPSIS
        Inventaria ativos .claude/{skills,agents,kb,rules,hooks,commands} + CLAUDE.md/AGENTS.md do
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

function Get-CommandMappingHint {
    <#
    .SYNOPSIS
        Para cada command do projeto no inventário (.claude/commands/*.md em Own ou Conflict),
        propõe o equivalente do scaffold: "aponta para a fase X" (commands de fase), "substituído
        por /y" (os demais) ou "sem equivalente". Conflict = homônimo de um command do scaffold:
        o do projeto fica. Read-only; é proposta para o relatório, nunca reescrita.
    .OUTPUTS
        [pscustomobject[]] { Command; Target; Hint }
    #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$Inventory = @())

    $Inventory = @($Inventory | Where-Object { $null -ne $_ })
    $commands  = @($Inventory |
        Where-Object { $_.RelativePath -like '.claude/commands/*.md' -and $_.Bucket -in 'Own', 'Conflict' } |
        Sort-Object RelativePath)

    $result = foreach ($item in $commands) {
        # subpasta vira namespace no Claude Code: commands/git/pr.md -> /git:pr
        $name = ($item.RelativePath.Substring('.claude/commands/'.Length) -replace '\.md$', '') -replace '/', ':'

        if ($item.Bucket -eq 'Conflict') {
            $target = $name
            $hint   = "homônimo de /$name do scaffold — o do projeto fica, o do scaffold não entra"
        } else {
            $tokens = @($name.ToLowerInvariant() -split '[-_.:]' | Where-Object { $_ })
            $target = $null
            foreach ($cmd in $script:CommandMappingHints.Keys) {
                if (@($script:CommandMappingHints[$cmd] | Where-Object { $tokens -contains $_ }).Count -gt 0) {
                    $target = $cmd
                    break
                }
            }
            $hint =
                if (-not $target) { 'sem equivalente no scaffold — segue como está' }
                elseif ($script:CommandPhase.ContainsKey($target)) { "aponta para a $($script:CommandPhase[$target]): /$target" }
                else { "substituído por /$target" }
        }

        [pscustomobject]@{
            Command = "/$name"
            Target  = if ($target) { "/$target" } else { $null }
            Hint    = $hint
        }
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

    # só aparece quando o projeto tem command próprio: repo sem commands não ganha seção vazia
    $hints = @(Get-CommandMappingHint -Inventory $Inventory)
    if ($hints.Count -gt 0) {
        [void]$sb.Append("Commands do projeto — proposta de mapeamento (nada é reescrito):`n")
        foreach ($h in $hints) { [void]$sb.Append("  > $($h.Command): $($h.Hint)`n") }
    }

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

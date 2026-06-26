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

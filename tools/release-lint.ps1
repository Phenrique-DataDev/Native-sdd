<#
.SYNOPSIS
    Release-lint: acusa versão documentada no CHANGELOG.md que nunca ganhou tag git.

    POR QUE EXISTE (o dano que o motivou, 2026-07-20): `VERSION` dizia 0.9.0 e o CHANGELOG
    documentava 0.9.0, 0.8.32 e 0.8.31 — enquanto a última tag do repositório era **v0.8.30**.
    Três releases publicadas sem tag, e nada avisou: NENHUM script cria tag (`grep "git tag"` em
    tools/ e .github/: zero). Taguear era ato de disciplina — e ato de disciplina é o que se esquece
    depois que o CHANGELOG foi escrito. É a falha que esta metodologia batiza, "regra sem mecanismo",
    aplicada ao próprio release: o `CHANGELOG` contava a história, mas `git checkout v0.9.0` não
    existia.

.DESCRIPTION
    Compara as versões declaradas no CHANGELOG.md (`## [x.y.z]`) com as tags `vx.y.z` do repositório.

    Regra única:
      - untagged-release (error) : versão no CHANGELOG, >= baseline, que não é a versão ATUAL, e não
                                   tem tag `v<versão>`.

    DUAS ISENÇÕES DELIBERADAS — sem elas o lint nasceria vermelho e viraria ruído:

    1. A VERSÃO ATUAL (a de `VERSION`) NÃO é cobrada. Entre o commit que bumpa a versão e o `git tag`
       existe uma janela legítima — normalmente de minutos, às vezes de dias, se a release espera
       revisão. Cobrar a atual reprovaria TODO commit dessa janela, transformando o gate em atrito e
       forçando um "taguear antes de terminar" que ninguém quer. O esquecimento da atual é pego
       assim que a PRÓXIMA versão sobe (aí ela deixa de ser a atual) — ou seja, o lint pega antes de
       ACUMULAR, que é exatamente o dano observado. Preço aceito conscientemente: uma release
       esquecida sozinha, sem sucessora, passa.

    2. BASELINE `0.8.10` — abaixo dela o histórico é irregular POR CONSTRUÇÃO, não por descuido:
       são 39 versões sem tag, e o próprio CHANGELOG registra que as 0.4.0–0.6.0 foram
       "reconstruídas a partir do histórico real de features shipadas", isto é, documentadas
       retroativamente para versões que nunca existiram como release tagueada. Cobrá-las seria pedir
       arqueologia (achar o commit de cada uma, com risco de errar o alvo) para consertar um passado
       que não causou dano. O baseline é o ponto a partir do qual a série está íntegra — de 0.8.10
       até hoje, toda versão do CHANGELOG tem tag.

    NÃO cobre a direção inversa (tag sem entrada no CHANGELOG — hoje 0.8.11/12/13). É um sinal mais
    fraco (tag a mais não quebra `git checkout`) e nasceria com 3 achados permanentes. Se um dia
    valer, é regra nova aqui, não alargamento desta.

    INERTE sem git (ou fora de um repositório): devolve zero achados. Não dá para afirmar que uma tag
    falta quando não há como listar tags — e o scaffold distribuído roda o check em máquinas onde
    isso vale. Nota honesta: usa as tags LOCAIS; um clone sem `git fetch --tags` pode acusar falso
    positivo, e a Message diz isso.

    Shape canônico dos demais lints (New-*Finding / Get-*Findings / Format-* / Test-*Gate / Invoke-*).
#>

Set-StrictMode -Version Latest

# Abaixo desta versão o histórico é irregular por construção — ver .DESCRIPTION, isenção 2.
$script:ReleaseLintBaseline = '0.8.10'

function ConvertTo-ReleaseVersion {
    <#
    .SYNOPSIS  PURA: 'x.y.z' -> [version] comparável. $null se não casar o formato.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ($Text -notmatch '^\s*(\d+)\.(\d+)\.(\d+)\s*$') { return $null }
    return [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
}

function Get-ChangelogVersion {
    <#
    .SYNOPSIS  PURA: extrai as versões dos cabeçalhos `## [x.y.z]` do texto do CHANGELOG.
    .OUTPUTS   [string[]] na ordem em que aparecem (vazio se nenhum cabeçalho casar).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^##\s*\[(\d+\.\d+\.\d+)\]') { $out.Add($Matches[1]) }
    }
    return $out.ToArray()
}

function New-ReleaseLintFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Rule = $Rule; Severity = $Severity; Path = $Path; Message = $Message }
}

function Get-ReleaseLintFindings {
    <#
    .SYNOPSIS
        PURA: dadas as versões do CHANGELOG, as tags existentes e a versão atual, devolve os
        achados `untagged-release`. Toda a política (baseline + isenção da atual) vive aqui —
        Invoke-ReleaseLint só faz I/O.
    .PARAMETER ChangelogVersions  versões declaradas no CHANGELOG ('0.9.0', ...).
    .PARAMETER Tags               nomes de tag do repo ('v0.9.0', ...); aceita com ou sem o 'v'.
    .PARAMETER CurrentVersion     conteúdo de VERSION — isenta, ver .DESCRIPTION do arquivo.
    .OUTPUTS  [pscustomobject[]] (vazio = série íntegra).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ChangelogVersions,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tags,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentVersion
    )

    $baseline = ConvertTo-ReleaseVersion -Text $script:ReleaseLintBaseline
    # Normaliza as tags para o número puro, para comparar sem depender do prefixo.
    $tagged = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
            $Tags | ForEach-Object { $_ -replace '^v', '' }
        ), [StringComparer]::OrdinalIgnoreCase)

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($v in $ChangelogVersions) {
        $sem = ConvertTo-ReleaseVersion -Text $v
        if ($null -eq $sem) { continue }                       # cabeçalho fora do formato: não é release
        if ($sem -lt $baseline) { continue }                   # isenção 2 (histórico pré-disciplina)
        if ($v -eq $CurrentVersion) { continue }               # isenção 1 (janela bump -> tag)
        if ($tagged.Contains($v)) { continue }

        $findings.Add((New-ReleaseLintFinding -Severity error -Rule 'untagged-release' -Path "CHANGELOG.md#$v" `
                    -Message ("versão $v documentada mas sem tag v$v — rode `git tag -a v$v <commit> -m '<resumo>' ; " +
                        'git push origin v' + $v + " (se o clone for raso: confira antes com ``git fetch --tags``)")))
    }
    return $findings.ToArray()
}

function Format-ReleaseLintReport {
    <# .SYNOPSIS  Painel legível dos achados. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) { return 'release-lint: OK (0 achados)' }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Findings) {
        $lines.Add("    [$($f.Severity)] $($f.Rule) $($f.Path) — $($f.Message)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Test-ReleaseLintGate {
    <# .SYNOPSIS  $false se houver >=1 achado 'error' (bloqueia o gate). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Severity -eq 'error' }).Count -gt 0)
}

function Invoke-ReleaseLint {
    <#
    .SYNOPSIS  I/O fino: lê CHANGELOG.md, VERSION e as tags do repo; delega a política à função pura.
    .OUTPUTS   [pscustomobject[]] de achados (vazio = íntegro OU git indisponível).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $changelog = Join-Path $RepoRoot 'CHANGELOG.md'
    $versionFile = Join-Path $RepoRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $changelog)) { return @() }

    # Inerte sem git / fora de repositório — não dá para afirmar ausência de tag sem listar tags.
    $tags = @()
    try {
        $raw = & git -C $RepoRoot tag -l 'v*' 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        $tags = @($raw | Where-Object { $_ })
    }
    catch { return @() }

    $current = ''
    if (Test-Path -LiteralPath $versionFile) { $current = (Get-Content -LiteralPath $versionFile -Raw).Trim() }

    $versions = Get-ChangelogVersion -Text (Get-Content -LiteralPath $changelog -Raw)
    return @(Get-ReleaseLintFindings -ChangelogVersions $versions -Tags $tags -CurrentVersion $current)
}

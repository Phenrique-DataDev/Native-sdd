# WIRING-EXEMPT: entry-point MANUAL por design — sobe a versão pinada de um binário de TERCEIRO,
# o que exige revisar o diff e commitar conscientemente. Rodar sozinho no CI transformaria o pin
# (a garantia) num alvo móvel. Coberto por tools/tests/bump-herdr.Tests.ps1.
<#
.SYNOPSIS
    Sobe o pin do herdr para a release mais recente que publica TODOS os assets, medindo o
    SHA-256 de cada um. "Last version" sob demanda, SEM abrir mão da verificação de integridade.

.DESCRIPTION
    O upstream (ogulcancelik/herdr) NÃO publica checksums — não há `.sha256` nem `checksums.txt`
    em nenhum release (verificado 2026-07-19). Logo, resolver "latest" em RUNTIME significaria
    instalar binário de terceiro sem verificar nada. Este script resolve o mesmo desejo pelo lado
    seguro: baixa aqui, hasheia aqui, e o hash entra COMMITADO no manifest — auditável no diff.

    Funções PURAS (seleção de release, parse da base estável, reescrita do texto do manifest)
    + um I/O fino (Invoke-HerdrBump) que orquestra 4 passos FAIL-FAST:

      1. RESOLVE  lista releases via `gh api` e escolhe a mais recente COM TODOS os assets.
      2. DOWNLOAD baixa cada asset para uma área temporária.
      3. HASH     mede o SHA-256 real de cada arquivo baixado.
      4. WRITE    reescreve Tag/Sha256/Bytes por asset no herdr.psd1, preservando os comentários.

    Nada é gravado antes do passo 4: abortar em 1–3 deixa o manifest intacto.

    POR QUE alinhar TODOS os assets à mesma tag: hoje o manifest é misto (windows de um `preview-*`,
    os outros 4 de `v0.7.4`) porque as releases estáveis v0.7.x não publicam binário Windows. Assets
    de tags diferentes = binários de COMMITS diferentes convivendo numa instalação. Este bump
    escolhe uma tag que sirva a todos, então as 5 plataformas passam a vir do mesmo commit.

    O campo `Version` do manifest continua SEMVER (o schema o valida com `^v?\d+\.\d+\.\d+$` —
    uma tag `preview-*` o REPROVARIA). Ele é o pin lógico/documental e recebe a "Base stable"
    declarada no corpo do release; a verdade por-asset mora em cada `Tag`.

    Uso por função (igual aos outros tools): `. ./tools/bump-herdr.ps1 ; Select-LatestHerdrRelease`.

.PARAMETER Check
    Só relata: mostra o pin atual, o candidato e se há bump disponível. Não baixa, não grava.

.PARAMETER DryRun
    Baixa e mede os hashes de verdade, mostra o diff que SERIA aplicado, mas não grava o manifest.

.PARAMETER Tag
    Força uma tag específica em vez de resolver a mais recente (ex.: voltar a um preview anterior).

.EXAMPLE
    pwsh tools/bump-herdr.ps1 -Check
.EXAMPLE
    pwsh tools/bump-herdr.ps1 -DryRun
.EXAMPLE
    pwsh tools/bump-herdr.ps1
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$DryRun,
    [string]$Tag,
    [string]$ManifestPath,
    [string]$Repo = 'ogulcancelik/herdr'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- PURA: caminho default do manifest (injetável em teste) -----------------------------------
function Get-HerdrManifestPath {
    param([string]$Override)
    if ($Override) { return $Override }
    return (Join-Path (Split-Path -Parent $PSScriptRoot) 'onboarding/herdr/herdr.psd1')
}

# --- PURA: os assets que uma release precisa ter para servir a TODAS as plataformas ------------
# Fonte única: o próprio manifest declara o AssetName de cada chave <os>-<arch>.
function Get-HerdrRequiredAsset {
    param([Parameter(Mandatory)][hashtable]$Manifest)
    $map = [ordered]@{}
    foreach ($key in ($Manifest.Assets.Keys | Sort-Object)) {
        $map[$key] = [string]$Manifest.Assets[$key].AssetName
    }
    return $map
}

# --- PURA: escolhe a release mais recente que publica TODOS os assets exigidos -----------------
# Releases sem o conjunto completo são REJEITADAS: um bump parcial reintroduziria exatamente o
# estado misto (assets de commits diferentes) que este script existe para eliminar.
function Select-LatestHerdrRelease {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Release,
        [Parameter(Mandatory)][string[]]$RequiredAsset
    )
    $ordered = @($Release | Sort-Object -Property published_at -Descending)
    foreach ($r in $ordered) {
        $names = @($r.assets | ForEach-Object { $_.name })
        $missing = @($RequiredAsset | Where-Object { $_ -notin $names })
        if ($missing.Count -eq 0) { return $r }
    }
    return $null
}

# --- PURA: extrai a "Base stable: vX.Y.Z" do corpo do release ---------------------------------
# Preview declara de qual estável saiu. Sem isso, cai para a tag (que só serve se ela mesma
# for semver) e, em último caso, devolve $null — o chamador mantém o Version atual.
function Get-HerdrBaseStable {
    param([string]$Body, [string]$TagName)
    if ($Body -match '(?im)^\s*Base stable:\s*(v?\d+\.\d+\.\d+)\s*$') { return $Matches[1] }
    if ($TagName -match '^v?\d+\.\d+\.\d+$') { return $TagName }
    return $null
}

# --- PURA: reescreve Tag/Sha256/Bytes de UM asset, preservando todo o resto do arquivo ---------
# Edição CIRÚRGICA por bloco: o herdr.psd1 carrega ~25 linhas de comentário com a proveniência de
# cada hash (o que foi executado em Docker, o que é só hash). Import-PowerShellDataFile +
# re-serialização apagaria isso — a documentação é o que torna o pin auditável.
function Update-HerdrManifestAsset {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$AssetKey,
        [Parameter(Mandatory)][string]$NewTag,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][long]$Bytes
    )
    if ($Sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "Update-HerdrManifestAsset: SHA-256 inválido para '$AssetKey': $Sha256"
    }
    $escaped = [regex]::Escape($AssetKey)
    # Casa do início do bloco do asset até a primeira `}` — o bloco não tem chaves aninhadas.
    $blockRx = "(?ms)('$escaped'\s*=\s*@\{)(.*?)(^\s*\})"
    $m = [regex]::Match($Content, $blockRx)
    if (-not $m.Success) { throw "Update-HerdrManifestAsset: asset '$AssetKey' não encontrado no manifest" }

    $body = $m.Groups[2].Value
    $body = [regex]::Replace($body, "(?m)^(\s*Tag\s*=\s*')[^']*(')", "`${1}$NewTag`${2}")
    $body = [regex]::Replace($body, "(?m)^(\s*Sha256\s*=\s*')[^']*(')", "`${1}$($Sha256.ToUpperInvariant())`${2}")
    $body = [regex]::Replace($body, "(?m)^(\s*Bytes\s*=\s*)\d+", "`${1}$Bytes")

    return $Content.Remove($m.Index, $m.Length).Insert($m.Index, $m.Groups[1].Value + $body + $m.Groups[3].Value)
}

# --- PURA: reescreve o campo Version (pin lógico, sempre semver) ------------------------------
function Update-HerdrManifestVersion {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Version
    )
    if ($Version -notmatch '^v?\d+\.\d+\.\d+$') {
        # O schema do install-herdr REPROVA não-semver; falhar aqui é melhor que gerar
        # um manifest que só quebra na próxima instalação.
        throw "Update-HerdrManifestVersion: '$Version' não é semver — o schema do manifest o reprovaria"
    }
    return [regex]::Replace($Content, "(?m)^(\s*Version\s*=\s*')[^']*(')", "`${1}$Version`${2}")
}

# --- EFEITO (rede): lista as releases do repo — ponto ÚNICO de rede na resolução --------------
function Get-HerdrRelease {
    param([Parameter(Mandatory)][string]$RepoName)
    $json = & gh api "repos/$RepoName/releases" --paginate 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh api falhou ao listar releases de $RepoName : $json" }
    return ($json | ConvertFrom-Json)
}

# --- EFEITO (rede): baixa um asset e devolve caminho + hash + tamanho -------------------------
function Get-HerdrAssetFact {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    $item = Get-Item -LiteralPath $Destination
    return [pscustomobject]@{
        Sha256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        Bytes  = [long]$item.Length
    }
}

# --- I/O: orquestra o bump ---------------------------------------------------------------------
function Invoke-HerdrBump {
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$CheckOnly,
        [switch]$NoWrite,
        [string]$ForceTag,
        [string]$RepoName = 'ogulcancelik/herdr'
    )

    $manifestPath = Get-HerdrManifestPath -Override $Path
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "manifest não encontrado: $manifestPath" }

    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    $required = Get-HerdrRequiredAsset -Manifest $manifest
    $currentTags = @($manifest.Assets.Keys | ForEach-Object { [string]$manifest.Assets[$_].Tag } | Sort-Object -Unique)

    Write-Host "manifest : $manifestPath"
    Write-Host "Version  : $($manifest.Version)   (pin lógico, semver)"
    Write-Host "tags hoje: $($currentTags -join ', ')"

    # 1. RESOLVE
    Write-Host '[..] resolvendo release mais recente com TODOS os assets...'
    $releases = @(Get-HerdrRelease -RepoName $RepoName)
    if ($ForceTag) {
        $target = $releases | Where-Object { $_.tag_name -eq $ForceTag } | Select-Object -First 1
        if (-not $target) { throw "tag '$ForceTag' não encontrada em $RepoName" }
    }
    else {
        $target = Select-LatestHerdrRelease -Release $releases -RequiredAsset @($required.Values)
        if (-not $target) { throw "nenhuma release publica os $($required.Count) assets exigidos" }
    }

    $base = Get-HerdrBaseStable -Body $target.body -TagName $target.tag_name
    Write-Host "[ok] candidato: $($target.tag_name)  ($($target.published_at.ToString('yyyy-MM-dd')))"
    if ($base) { Write-Host "     base stable: $base" }

    if ($currentTags.Count -eq 1 -and $currentTags[0] -eq $target.tag_name) {
        Write-Host '[=] já está na versão mais recente — nada a fazer.'
        return
    }
    if ($CheckOnly) {
        Write-Host "[!] bump DISPONÍVEL: $($currentTags -join ',') -> $($target.tag_name)"
        Write-Host '    rode sem -Check (ou com -DryRun) para medir os hashes.'
        return
    }

    # 2+3. DOWNLOAD + HASH
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "herdr-bump-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $facts = [ordered]@{}
    try {
        foreach ($key in $required.Keys) {
            $assetName = $required[$key]
            $url = "https://github.com/$RepoName/releases/download/$($target.tag_name)/$assetName"
            Write-Host "[..] $key : baixando $assetName"
            $fact = Get-HerdrAssetFact -Url $url -Destination (Join-Path $tmp $assetName)
            $facts[$key] = $fact
            Write-Host "     SHA-256 $($fact.Sha256)  ($([math]::Round($fact.Bytes / 1MB, 1)) MB)"
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 4. WRITE
    $content = Get-Content -LiteralPath $manifestPath -Raw
    foreach ($key in $facts.Keys) {
        $content = Update-HerdrManifestAsset -Content $content -AssetKey $key `
            -NewTag $target.tag_name -Sha256 $facts[$key].Sha256 -Bytes $facts[$key].Bytes
    }
    if ($base -and $base -ne [string]$manifest.Version) {
        $content = Update-HerdrManifestVersion -Content $content -Version $base
        Write-Host "[ok] Version: $($manifest.Version) -> $base"
    }

    if ($NoWrite) {
        Write-Host '[dry-run] manifest NÃO gravado. Hashes medidos acima.'
        return
    }

    # UTF-8 sem BOM: o manifest é lido por Import-PowerShellDataFile e vive no git.
    [System.IO.File]::WriteAllText($manifestPath, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Host ''
    Write-Host "[OK] herdr.psd1 atualizado: $($currentTags -join ',') -> $($target.tag_name)"
    Write-Host '     revise o diff (os hashes são a garantia) e commite.'
    Write-Host '     depois: pwsh tools/check.ps1'
}

# Dot-source não executa; só a invocação direta roda.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-HerdrBump -Path $ManifestPath -CheckOnly:$Check -NoWrite:$DryRun -ForceTag $Tag -RepoName $Repo
}

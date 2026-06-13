<#
.SYNOPSIS
    Publica o SUBSET DE PRODUTO no espelho público (Native-sdd): template repo + tarball
    versionado. Feature A9 (modelo de distribuição do 1.0).

.DESCRIPTION
    Funções PURAS (manifesto, gate, tag, detecção de refs — texto/listas, sem tocar disco/rede)
    + um I/O fino (Invoke-Publish) que orquestra 5 passos FAIL-FAST:

      1. VERIFY   roda tools/check.ps1 (gate de sanitização: pii-lint + lints + Pester).
      2. STAGE    monta o subset de produto numa área temporária (Get-DistributionManifest).
      3. SCAN     ref-denylist (nomes de repos-base externos) sobre o subset.
      4. PACK     git init órfão + 1 commit (sem história do canônico) + tarball .zip.
      5. PUBLISH  gh repo (ensure + --template) · git push --force · gh release create.

    Nenhum efeito outward-facing antes do passo 5: abortos em 1–4 deixam o espelho intacto.
    O canônico (sdd-workflow) segue PRIVATE e NÃO vira fork-pai do espelho (isolamento total).

    Manifesto = FONTE ÚNICA da fronteira produto×dev/meta (decisão F4). O subset é só-runtime:
    exclui dev/meta (features/, .claude/, CHANGELOG.md, docs/DECISOES.md) E infra de dev
    (tools/tests/, .github/).

    Uso por função (igual aos outros tools): `. ./tools/publish.ps1 ; Get-DistributionManifest`.
    Como script: `pwsh tools/publish.ps1 [-DryRun] [-Force] [-Mirror owner/Native-sdd]`.
#>

[CmdletBinding()]
param(
    [string]$Mirror = 'Native-sdd',
    [switch]$DryRun,
    [switch]$Force
)

Set-StrictMode -Version Latest

# Reusa o motor de varredura do pii-lint (sem reimplementar regex/loop) para o ref-denylist.
. (Join-Path $PSScriptRoot 'pii-lint.ps1')

# --- PURA: a fronteira produto×dev/meta (fonte única; decisão F4/A9) --------------------------
function Get-DistributionManifest {
    <# .SYNOPSIS  Dirs/arquivos do PRODUTO + prefixos EXCLUÍDOS. Única definição da fronteira. #>
    [CmdletBinding()] param()
    [pscustomobject]@{
        # Dirs varridos recursivamente (menos o que casar ExcludePrefix, ex.: tools/tests/).
        IncludeDirs   = @('onboarding', 'templates', 'methodology', 'tools')
        # Arquivos de produto na raiz/docs (os 3 docs de produto + config portável + VERSION).
        IncludeFiles  = @('README.md', 'VERSION', '.gitattributes', '.gitignore',
            'docs/VISAO.md', 'docs/USO.md', 'docs/HARNESS-CONTRACT.md')
        # Camada dev/meta + infra de dev: NUNCA entra no subset (verificado por Test-SubsetClean).
        ExcludePrefix = @('features/', '.claude/', '.github/', 'tools/tests/',
            'CHANGELOG.md', 'docs/DECISOES.md')
    }
}

# --- PURA: um caminho relativo casa algum prefixo excluído? -----------------------------------
function Test-PathExcluded {
    <# .SYNOPSIS  $true se $RelPath (separador '/') começa por algum prefixo de $ExcludePrefix. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExcludePrefix
    )
    $norm = $RelPath -replace '\\', '/'
    foreach ($p in $ExcludePrefix) {
        if ($norm -eq $p -or $norm.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# --- PURA: dada a lista de relpaths do subset, devolve os que violam um prefixo excluído -------
function Test-SubsetClean {
    <# .SYNOPSIS  Defesa em profundidade (SC-1): relpaths que NÃO deveriam estar no subset. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Files,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExcludePrefix
    )
    @($Files | Where-Object { Test-PathExcluded -RelPath $_ -ExcludePrefix $ExcludePrefix })
}

# --- PURA: qualifica o nome do espelho como OWNER/REPO ----------------------------------------
function Get-QualifiedRepo {
    <# .SYNOPSIS  'Native-sdd' + owner -> 'owner/Native-sdd'. Já-qualificado (com '/') passa direto.
       gh repo edit / release create --repo EXIGEM OWNER/REPO; gh repo create aceita ambos. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Mirror,
        [Parameter(Mandatory)][string]$Owner
    )
    if ($Mirror -match '/') { return $Mirror }
    return "$Owner/$Mirror"
}

# --- PURA: tag de release a partir do conteúdo de VERSION -------------------------------------
function Get-ReleaseTag {
    <# .SYNOPSIS  '0.6.5' -> 'v0.6.5'. Trim + prefixo 'v' (idempotente se já vier com 'v'). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Version)
    $v = $Version.Trim()
    if ($v -match '^v') { return $v }
    return "v$v"
}

# --- PURA: achados de refs externas (reusa Get-PiiFindings, remapeia p/ 'ref') -----------------
function Get-RefFindings {
    <# .SYNOPSIS  Termos da ref-denylist no texto. Reusa o motor do pii-lint; rotula 'ref'. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source,
        [string[]]$RefDenylist = @()
    )
    if ($RefDenylist.Count -eq 0) { return @() }
    $hits = @(Get-PiiFindings -Text $Text -Source $Source -Denylist $RefDenylist |
            Where-Object { $_.Rule -eq 'denylist' })
    @($hits | ForEach-Object {
            New-PiiFinding -Severity error -Rule ref -Path $_.Path `
                -Message ($_.Message -replace '^termo de PII \(denylist\)', 'ref externa')
        })
}

# --- PURA: o gate de publicação combina as 4 condições ----------------------------------------
function Test-PublishGate {
    <#
    .SYNOPSIS  Decide se publica. Reasons[] vira a mensagem de aborto (fail-fast).
    .OUTPUTS   [pscustomobject]@{ Passed=[bool]; Reasons=[string[]] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$ChecksOk,
        [Parameter(Mandatory)][int]$SubsetViolations,
        [Parameter(Mandatory)][int]$RefHits,
        [bool]$TagExists = $false,
        [bool]$Force = $false
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    if (-not $ChecksOk) { $reasons.Add('checks-failed: tools/check.ps1 reprovou (sanitização/lints/testes)') }
    if ($SubsetViolations -gt 0) { $reasons.Add("subset-dirty: $SubsetViolations arquivo(s) de dev/meta no subset") }
    if ($RefHits -gt 0) { $reasons.Add("ref-leak: $RefHits ref(s) externa(s) na superfície distribuída") }
    if ($TagExists -and -not $Force) { $reasons.Add('tag-exists: a tag de release já existe no espelho (use -Force)') }
    [pscustomobject]@{ Passed = ($reasons.Count -eq 0); Reasons = $reasons.ToArray() }
}

# --- I/O: enumera os arquivos do subset (relpaths, separador '/') ------------------------------
function Get-DistributionFileList {
    <# .SYNOPSIS  Aplica o manifesto sobre $Root: relpaths incluídos, menos os excluídos. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][pscustomobject]$Manifest
    )
    $root = (Resolve-Path -LiteralPath $Root).Path
    $out = [System.Collections.Generic.List[string]]::new()

    foreach ($d in $Manifest.IncludeDirs) {
        $full = Join-Path $root $d
        if (-not (Test-Path -LiteralPath $full)) { continue }
        Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = $_.FullName.Substring($root.Length + 1) -replace '\\', '/'
            if (-not (Test-PathExcluded -RelPath $rel -ExcludePrefix $Manifest.ExcludePrefix)) { $out.Add($rel) }
        }
    }
    foreach ($f in $Manifest.IncludeFiles) {
        $full = Join-Path $root $f
        if (Test-Path -LiteralPath $full -PathType Leaf) { $out.Add(($f -replace '\\', '/')) }
    }
    return $out.ToArray()
}

# --- I/O: copia o subset para a área de staging -----------------------------------------------
function Copy-Subset {
    <# .SYNOPSIS  Copia cada relpath de $Files de $Root para $Dest, preservando a estrutura. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)][string[]]$Files
    )
    $root = (Resolve-Path -LiteralPath $Root).Path
    foreach ($rel in $Files) {
        $src = Join-Path $root $rel
        $dst = Join-Path $Dest $rel
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
}

# --- I/O fino: orquestra os 5 passos ----------------------------------------------------------
function Invoke-Publish {
    <#
    .SYNOPSIS  VERIFY -> STAGE -> SCAN -> PACK -> PUBLISH. Fail-fast; -DryRun para após o PACK.
    .OUTPUTS   [pscustomobject]@{ Published; Mirror; Tag; SubsetCount; Gate }
    #>
    [CmdletBinding()]
    param(
        [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
        [string]$Mirror = 'Native-sdd',
        [switch]$DryRun,
        [switch]$Force
    )

    $steps = [System.Collections.Generic.List[string]]::new()
    $fail = { param($msg) Write-Host "❌ $msg"; return [pscustomobject]@{ Published = $false; Mirror = $Mirror; Tag = $null; SubsetCount = 0; Gate = $null } }

    # Pré-flight (cli-first): git/gh presentes.
    foreach ($cli in 'git', 'gh') {
        if (-not (Get-Command $cli -ErrorAction SilentlyContinue)) { return (& $fail "pré-flight: '$cli' não encontrado (instale o $cli)") }
    }

    $manifest = Get-DistributionManifest
    $tag = Get-ReleaseTag -Version (Get-Content -LiteralPath (Join-Path $RepoRoot 'VERSION') -Raw)
    # gh repo edit / release create EXIGEM OWNER/REPO — qualifica o espelho uma vez.
    $owner = (gh api user --jq '.login' 2>$null)
    $mirrorQ = if ($owner) { Get-QualifiedRepo -Mirror $Mirror -Owner $owner } else { $Mirror }

    # 1. VERIFY — gate de sanitização (reusa check.ps1; não reimplementa).
    Write-Host "▶ 1/5 VERIFY  (tools/check.ps1)"
    . (Join-Path $PSScriptRoot 'check.ps1')
    $check = Invoke-Check -Quiet
    $checksOk = [bool]$check.AllOk
    $steps.Add("VERIFY: $(if ($checksOk) {'ok'} else {'FALHOU'})")

    # 2. STAGE — monta o subset numa área temporária.
    Write-Host "▶ 2/5 STAGE   (subset de produto)"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("native-sdd-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $files = @(Get-DistributionFileList -Root $RepoRoot -Manifest $manifest)
        Copy-Subset -Root $RepoRoot -Dest $tmp -Files $files
        $violations = @(Test-SubsetClean -Files $files -ExcludePrefix $manifest.ExcludePrefix)
        $steps.Add("STAGE: $($files.Count) arquivo(s), $($violations.Count) violação(ões)")

        # 3. SCAN — ref-denylist sobre o subset.
        Write-Host "▶ 3/5 SCAN    (ref-denylist)"
        $refDeny = Read-PiiDenylist -Path (Join-Path $RepoRoot '.claude/ref-denylist.txt')
        $refHits = [System.Collections.Generic.List[object]]::new()
        foreach ($rel in $files) {
            $full = Join-Path $tmp $rel
            $text = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
            if ([string]::IsNullOrEmpty($text)) { continue }
            foreach ($h in (Get-RefFindings -Text $text -Source $rel -RefDenylist $refDeny)) { $refHits.Add($h) }
        }
        $steps.Add("SCAN: $($refHits.Count) ref(s) externa(s)")

        # Gate combinado (tag-exists só importa no publish real).
        $tagExists = $false
        if (-not $DryRun) {
            $existing = gh release view $tag --repo $mirrorQ --json tagName 2>$null
            $tagExists = [bool]$existing
        }
        $gate = Test-PublishGate -ChecksOk $checksOk -SubsetViolations $violations.Count `
            -RefHits $refHits.Count -TagExists $tagExists -Force:$Force
        if (-not $gate.Passed) {
            Write-Host "❌ gate reprovou:"; $gate.Reasons | ForEach-Object { Write-Host "   - $_" }
            return [pscustomobject]@{ Published = $false; Mirror = $Mirror; Tag = $tag; SubsetCount = $files.Count; Gate = $gate }
        }

        # 4. PACK — git órfão (1 commit, sem história do canônico) + tarball.
        Write-Host "▶ 4/5 PACK    (commit órfão + tarball)"
        Push-Location $tmp
        try {
            git init -q -b main 2>&1 | Out-Null
            git add -A 2>&1 | Out-Null
            git -c user.name='publish' -c user.email='publish@local' commit -q -m "release $tag" 2>&1 | Out-Null
        }
        finally { Pop-Location }
        $tarball = Join-Path ([System.IO.Path]::GetTempPath()) ("native-sdd-{0}.zip" -f $tag)
        if (Test-Path -LiteralPath $tarball) { Remove-Item -LiteralPath $tarball -Force }
        $toZip = Get-ChildItem -LiteralPath $tmp -Force | Where-Object { $_.Name -ne '.git' }
        Compress-Archive -Path $toZip.FullName -DestinationPath $tarball -Force
        $steps.Add("PACK: commit órfão + $(Split-Path -Leaf $tarball)")

        if ($DryRun) {
            Write-Host ""
            Write-Host "🔎 DRY-RUN — plano (nada publicado):"
            Write-Host "   espelho : $Mirror"
            Write-Host "   tag     : $tag"
            Write-Host "   subset  : $($files.Count) arquivo(s) · violações dev/meta: $($violations.Count) · refs: $($refHits.Count)"
            Write-Host "   tarball : $tarball"
            $steps | ForEach-Object { Write-Host "   ✓ $_" }
            return [pscustomobject]@{ Published = $false; Mirror = $Mirror; Tag = $tag; SubsetCount = $files.Count; Gate = $gate }
        }

        # 5. PUBLISH — ensure repo (template) · push --force · release.
        Write-Host "▶ 5/5 PUBLISH (gh + git push)"
        $exists = gh repo view $mirrorQ --json name 2>$null
        Push-Location $tmp
        try {
            if (-not $exists) {
                gh repo create $mirrorQ --public --source . --push --description 'SDD workflow — distribuição (produto, gerado por publish.ps1)' 2>&1 | Write-Host
            }
            else {
                $url = (gh repo view $mirrorQ --json url --jq '.url' 2>$null)
                git remote remove origin 2>&1 | Out-Null
                git remote add origin "$url.git" 2>&1 | Out-Null
                git push --force origin main 2>&1 | Write-Host
            }
        }
        finally { Pop-Location }
        gh repo edit $mirrorQ --template 2>&1 | Write-Host
        gh release create $tag $tarball --repo $mirrorQ --title $tag --notes "Distribuição $tag — produto SDD (template + tarball)." 2>&1 | Write-Host
        $steps.Add("PUBLISH: $mirrorQ @ $tag")

        Write-Host ""
        Write-Host "✅ publicado: $Mirror @ $tag ($($files.Count) arquivos)"
        return [pscustomobject]@{ Published = $true; Mirror = $Mirror; Tag = $tag; SubsetCount = $files.Count; Gate = $gate }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Guard: roda só quando NÃO dot-sourced (os testes fazem `. publish.ps1`) -------------------
if ($MyInvocation.InvocationName -ne '.') {
    $r = Invoke-Publish -Mirror $Mirror -DryRun:$DryRun -Force:$Force
    exit ([int](-not ($r.Published -or $DryRun)))
}

<#
.SYNOPSIS
    complementary-repos (REPOS_COMPLEMENTARES) — registro de repositórios complementares de
    referência, consultados read-only pelo agente e adaptados (nunca vendorizados) ao projeto.

.DESCRIPTION
    Camada determinística consumida pelo comando /complementary-repos e pela regra
    rules/complementary-repos.md. Registro em .claude/complementary-repos.psd1 (Import-
    PowerShellDataFile — sem módulo YAML, mesmo padrão de tools/supplements.psd1; ver DESIGN
    D1). Schema por entrada: Name (opcional), Path (opcional), Url (opcional), Reason
    (obrigatório) — ao menos um de Path/Url é exigido (Test-ComplementaryRepoEntryValid).

    Resolve-ComplementaryRepoLocation decide a origem de leitura:
      - Path existe no disco            -> usa direto (Source='path')
      - só Url, cache já clonado        -> usa o cache (Source='cache')
      - só Url, sem cache               -> `git clone --depth 1` p/ .claude/.cache/
                                            complementary-repos/<slug>/ (Source='cache', Cloned=$true)
      - nem Path válido nem Url         -> lança (registro órfão, AT-007 do DEFINE)

    Get-ComplementaryRepoProtectedPaths + Test-PathUnderProtected dão o boundary read-only
    consultado pelo hook complementary-repo-guard (ver DESIGN D3) — mas o hook NÃO dot-source
    este arquivo: ele duplica a checagem mínima inline (self-contido, molde secret-guard/
    destructive-guard) para não depender da cascata tools/ em runtime de guard de segurança.
    Estas funções aqui servem o comando /complementary-repos e testes/uso programático.

    Funções puras (Test-ComplementaryRepoEntryValid / Get-ComplementaryRepoSlug /
    Test-PathUnderProtected / ConvertTo-ComplementaryRepoPsd1Text) são dot-sourceáveis para
    teste; o restante é I/O read-only ou com efeito controlado (clone/escrita do registro).
#>

Set-StrictMode -Version Latest

$script:ComplementaryRepoDefaultRegistry = '.claude/complementary-repos.psd1'
$script:ComplementaryRepoDefaultCacheRoot = '.claude/.cache/complementary-repos'

# --- I/O: lê o registro (ausente -> lista vazia, sem erro) -------------------------------------
function Get-ComplementaryRepoRegistry {
    [CmdletBinding()]
    param([string]$Path = $script:ComplementaryRepoDefaultRegistry)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }

    $data = Import-PowerShellDataFile -LiteralPath $Path
    $repos = @($data.Repos)
    # Indexador [] (não dot-notation) — sob Set-StrictMode, dot-notation numa chave AUSENTE do
    # hashtable (entrada sem Url/Path, por serem opcionais) lança PropertyNotFoundException;
    # o indexador devolve $null de forma segura para chave que não existe.
    return @($repos | ForEach-Object {
            [pscustomobject]@{
                Name   = [string]$_['Name']
                Path   = [string]$_['Path']
                Url    = [string]$_['Url']
                Reason = [string]$_['Reason']
            }
        })
}

# --- PURA: entrada tem Reason + (Path OU Url)? --------------------------------------------------
function Test-ComplementaryRepoEntryValid {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry)

    $hasReason = -not [string]::IsNullOrWhiteSpace([string]$Entry.Reason)
    $hasLocator = (-not [string]::IsNullOrWhiteSpace([string]$Entry.Path)) `
        -or (-not [string]::IsNullOrWhiteSpace([string]$Entry.Url))
    return [bool]($hasReason -and $hasLocator)
}

# --- PURA: slug determinístico — Name > basename(Url sem .git) > basename(Path) (DESIGN D5) ----
function Get-ComplementaryRepoSlug {
    [CmdletBinding()]
    param(
        [string]$Name = '',
        [string]$Url = '',
        [string]$Path = ''
    )

    $raw = $null
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $raw = $Name
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Url)) {
        $trimmed = $Url.TrimEnd('/')
        $last = ($trimmed -split '/')[-1]
        $raw = $last -replace '\.git$', ''
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Path)) {
        $raw = Split-Path -Path ($Path.TrimEnd('\', '/')) -Leaf
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'Get-ComplementaryRepoSlug: entrada sem Name/Url/Path para derivar um slug.'
    }

    $slug = ($raw.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw 'Get-ComplementaryRepoSlug: slug vazio apos sanitizacao.'
    }
    return $slug
}

# --- Resolve onde ler a entrada; clona (efeito de rede/disco) só se necessário ------------------
function Resolve-ComplementaryRepoLocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [string]$CacheRoot = $script:ComplementaryRepoDefaultCacheRoot
    )

    $hasPath = -not [string]::IsNullOrWhiteSpace([string]$Entry.Path)
    if ($hasPath -and (Test-Path -LiteralPath $Entry.Path -PathType Container)) {
        return [pscustomobject]@{ LocalPath = $Entry.Path; Cloned = $false; Source = 'path' }
    }

    $hasUrl = -not [string]::IsNullOrWhiteSpace([string]$Entry.Url)
    if (-not $hasUrl) {
        throw "Resolve-ComplementaryRepoLocation: entrada '$($Entry.Name)' sem Path existente nem Url (registro orfao)."
    }

    $slug = Get-ComplementaryRepoSlug -Name $Entry.Name -Url $Entry.Url -Path $Entry.Path
    $dest = Join-Path $CacheRoot $slug
    if (Test-Path -LiteralPath $dest -PathType Container) {
        return [pscustomobject]@{ LocalPath = $dest; Cloned = $false; Source = 'cache' }
    }

    $parent = Split-Path -Parent $dest
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    & git clone --depth 1 -- $Entry.Url $dest 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dest -PathType Container)) {
        throw "Resolve-ComplementaryRepoLocation: falha ao clonar '$($Entry.Url)' para '$dest' (git exit $LASTEXITCODE)."
    }
    return [pscustomobject]@{ LocalPath = $dest; Cloned = $true; Source = 'cache' }
}

# --- Paths protegidos (consumido por Test-PathUnderProtected; uso programatico/testes) ----------
function Get-ComplementaryRepoProtectedPaths {
    [CmdletBinding()]
    param(
        [string]$RegistryPath = $script:ComplementaryRepoDefaultRegistry,
        [string]$CacheRoot = $script:ComplementaryRepoDefaultCacheRoot
    )

    $protectedPaths = @()
    if (Test-Path -LiteralPath $CacheRoot -PathType Container) {
        $protectedPaths += (Resolve-Path -LiteralPath $CacheRoot).Path
    }
    elseif (Test-Path -LiteralPath $RegistryPath -PathType Leaf) {
        $protectedPaths += $CacheRoot
    }

    foreach ($e in (Get-ComplementaryRepoRegistry -Path $RegistryPath)) {
        if (-not [string]::IsNullOrWhiteSpace($e.Path) -and (Test-Path -LiteralPath $e.Path -PathType Container)) {
            $protectedPaths += (Resolve-Path -LiteralPath $e.Path).Path
        }
    }
    return @($protectedPaths | Select-Object -Unique)
}

# --- PURA: file_path cai dentro de algum path protegido? ----------------------------------------
function Test-PathUnderProtected {
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [string[]]$ProtectedPaths
    )

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not $ProtectedPaths -or $ProtectedPaths.Count -eq 0) {
        return $false
    }
    $norm = $FilePath.Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    foreach ($p in $ProtectedPaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $pn = $p.Replace('\', '/').TrimEnd('/').ToLowerInvariant()
        if ($norm -eq $pn -or $norm.StartsWith("$pn/")) { return $true }
    }
    return $false
}

# --- PURA: serializa a lista de entradas de volta para texto .psd1 -----------------------------
function ConvertTo-ComplementaryRepoPsd1Text {
    [CmdletBinding()]
    param([AllowEmptyCollection()][array]$Entries = @())

    function Format-Psd1String([string]$Value) {
        return "'" + ($Value -replace "'", "''") + "'"
    }

    $lines = @(
        '# .claude/complementary-repos.psd1 — registro de repositorios complementares (leitura de referencia).'
        '# Gerado/atualizado por /complementary-repos — pode editar a mao (schema: Name/Path/Url/Reason).'
        '# Import-PowerShellDataFile le este arquivo; o topo e um hashtable com a chave Repos.'
        '@{'
        '    Repos = @('
    )
    foreach ($e in $Entries) {
        $lines += '        @{'
        if (-not [string]::IsNullOrWhiteSpace([string]$e.Name)) {
            $lines += "            Name   = $(Format-Psd1String $e.Name)"
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$e.Path)) {
            $lines += "            Path   = $(Format-Psd1String $e.Path)"
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$e.Url)) {
            $lines += "            Url    = $(Format-Psd1String $e.Url)"
        }
        $lines += "            Reason = $(Format-Psd1String ([string]$e.Reason))"
        $lines += '        }'
    }
    $lines += '    )'
    $lines += '}'
    return ($lines -join "`n")
}

# --- Escreve o registro (efeito de disco; usado pelo comando /complementary-repos) --------------
function Add-ComplementaryRepoEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Reason,
        [string]$Name = '',
        [string]$Path = '',
        [string]$Url = '',
        [string]$RegistryPath = $script:ComplementaryRepoDefaultRegistry
    )

    $entry = [pscustomobject]@{ Name = $Name; Path = $Path; Url = $Url; Reason = $Reason }
    if (-not (Test-ComplementaryRepoEntryValid -Entry $entry)) {
        throw 'Add-ComplementaryRepoEntry: entrada precisa de Reason + (Path ou Url).'
    }

    $entries = @(Get-ComplementaryRepoRegistry -Path $RegistryPath)
    $slug = Get-ComplementaryRepoSlug -Name $Name -Url $Url -Path $Path
    $entries = @($entries | Where-Object {
            (Get-ComplementaryRepoSlug -Name $_.Name -Url $_.Url -Path $_.Path) -ne $slug
        })
    $entries += $entry

    $dir = Split-Path -Parent $RegistryPath
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $RegistryPath -Value (ConvertTo-ComplementaryRepoPsd1Text -Entries $entries) -Encoding UTF8
    return $entry
}

function Remove-ComplementaryRepoEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$RegistryPath = $script:ComplementaryRepoDefaultRegistry
    )

    $entries = @(Get-ComplementaryRepoRegistry -Path $RegistryPath)
    $remaining = @($entries | Where-Object { $_.Name -ne $Name })
    if ($remaining.Count -eq $entries.Count) {
        throw "Remove-ComplementaryRepoEntry: nenhuma entrada com Name '$Name' encontrada."
    }
    Set-Content -LiteralPath $RegistryPath -Value (ConvertTo-ComplementaryRepoPsd1Text -Entries $remaining) -Encoding UTF8
}

# --- Painel read-only p/ o /complementary-repos list --------------------------------------------
function Format-ComplementaryRepoList {
    [CmdletBinding()]
    param(
        [string]$RegistryPath = $script:ComplementaryRepoDefaultRegistry,
        [string]$CacheRoot = $script:ComplementaryRepoDefaultCacheRoot
    )

    $entries = @(Get-ComplementaryRepoRegistry -Path $RegistryPath)
    if ($entries.Count -eq 0) { return 'Nenhum repositorio complementar registrado.' }

    $lines = @()
    foreach ($e in $entries) {
        $slug = Get-ComplementaryRepoSlug -Name $e.Name -Url $e.Url -Path $e.Path
        $status =
            if (-not [string]::IsNullOrWhiteSpace($e.Path) -and (Test-Path -LiteralPath $e.Path -PathType Container)) { 'path OK' }
            elseif (-not [string]::IsNullOrWhiteSpace($e.Path)) { 'path ORFAO (nao existe mais)' }
            elseif (Test-Path -LiteralPath (Join-Path $CacheRoot $slug) -PathType Container) { 'clonado em cache' }
            elseif (-not [string]::IsNullOrWhiteSpace($e.Url)) { 'pendente (clone lazy na proxima consulta)' }
            else { 'ORFAO (sem Path nem Url)' }
        $label = if ($e.Name) { $e.Name } else { $slug }
        $lines += "- $label [$status] — $($e.Reason)"
    }
    return ($lines -join "`n")
}

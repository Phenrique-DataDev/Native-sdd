# install-cliproxy.ps1 — provisiona o binário `cli-proxy-api` (CLIProxyAPI, de terceiro — repo
# público router-for-me/CLIProxyAPI) user-scoped. Passo OPT-IN (-WithCliProxy) e NÃO bloqueante:
# qualquer falha vira WARN, nunca Failed. Mesma disciplina de install-herdr.ps1.
#
# PARA QUE SERVE: é o motor que o claudex usa para o caminho de LOGIN DE ASSINATURA (OAuth) —
# `Engine = 'cliproxy'` nos perfis. O litellm cobre o caminho de chave de API; este cobre o de
# conta (Claude, Codex, Gemini/Antigravity, Kimi, xAI).
#
# O QUE FAZ (idempotente):
#   1. resolve o asset da versão PINADA (onboarding/cliproxy/cliproxy.psd1) p/ o OS/arch atual
#   2. baixa, VERIFICA o SHA-256 ANTES de instalar (mismatch ou placeholder = aborta, NUNCA
#      instala binário não verificado)
#   3. EXTRAI o arquivo (zip/tar.gz — este projeto distribui archive, não binário solto) e
#      instala em ~/.claude/tools/cliproxy/<versão>/cli-proxy-api(.exe)
#   4. grava ~/.claude/.native-sdd-cliproxy-version
#
# O QUE NÃO FAZ: não faz login, não escreve config, não sobe servidor. Login é ato do usuário
# (abre browser, credencial da conta dele) — ver `claudex -Login`. Requer lib.ps1 carregado
# (Write-Step, Backup-File, Get-OnboardingOS). Compatível com Windows PowerShell 5.1+ e PS7+.

Set-StrictMode -Version Latest

# --- PURA: importa o manifest pinado ----------------------------------------------------------
function Import-CliProxyManifest {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "cliproxy: manifest não encontrado em $Path"
    }
    return Import-PowerShellDataFile -LiteralPath $Path
}

# --- PURA: o hash é o placeholder "não verificado"? -------------------------------------------
function Test-CliProxyHashPlaceholder {
    param([string]$Hash)
    if ([string]::IsNullOrWhiteSpace($Hash)) { return $true }
    return ($Hash -notmatch '^[0-9a-fA-F]{64}$')
}

# --- PURA: valida o schema do manifest; devolve lista de erros (vazia = ok) --------------------
function Get-CliProxySchemaError {
    param([Parameter(Mandatory)]$Manifest)
    $errors = [System.Collections.Generic.List[string]]::new()

    if (-not ($Manifest -is [hashtable]) -or -not $Manifest.ContainsKey('Version')) {
        $errors.Add('manifest sem Version'); return $errors
    }
    if ([string]$Manifest.Version -notmatch '^v?\d+\.\d+\.\d+$') {
        $errors.Add("Version não-semver: $($Manifest.Version)")
    }
    if (-not $Manifest.ContainsKey('Assets') -or -not ($Manifest.Assets -is [hashtable]) -or $Manifest.Assets.Count -eq 0) {
        $errors.Add('manifest sem Assets'); return $errors
    }
    foreach ($key in $Manifest.Assets.Keys) {
        $a = $Manifest.Assets[$key]
        # Archive/BinaryPath são exigências DESTE manifest (o herdr distribui binário solto;
        # este distribui archive, então sem os dois o instalador não sabe o que extrair).
        foreach ($field in @('Tag', 'AssetName', 'UrlTemplate', 'Sha256', 'Archive', 'BinaryPath')) {
            if (-not $a.ContainsKey($field) -or [string]::IsNullOrWhiteSpace([string]$a[$field])) {
                $errors.Add("asset '$key' sem $field")
            }
        }
        if ($a.ContainsKey('Archive') -and [string]$a['Archive'] -notin @('zip', 'tar.gz')) {
            $errors.Add("asset '$key' Archive inválido (esperado zip | tar.gz): $($a['Archive'])")
        }
        $h = [string]$a['Sha256']
        if ($h -and (Test-CliProxyHashPlaceholder $h) -and $h -ne 'PENDENTE-verificar-manualmente') {
            $errors.Add("asset '$key' Sha256 inválido (nem 64 hex nem placeholder): $h")
        }
    }
    return $errors
}

# --- PURA: arch do host (injetável em teste) --------------------------------------------------
# ATENÇÃO: `$env:PROCESSOR_ARCHITECTURE` SÓ EXISTE NO WINDOWS. Usá-lo como fonte única fazia o
# arch vir vazio em Linux/macOS, e aí Resolve-CliProxyAssetKey devolvia $null — ou seja, os 4
# assets linux/macos que o manifest DECLARA eram inalcançáveis pelo instalador. Medido em
# container Linux (2026-07-19), não deduzido. Mesma família do "modelo listado ≠ utilizável":
# constar na fonte de dados não prova que o código chega nele.
# `RuntimeInformation::OSArchitecture` é multiplataforma (e existe no .NET Framework 4.7.1+, então
# vale também para o Windows PowerShell 5.1); a env var fica só como último recurso.
function Get-CliProxyHostArch {
    param(
        [string]$RawArch = $(
            try { [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture }
            catch { $env:PROCESSOR_ARCHITECTURE }
        )
    )
    if ([string]::IsNullOrWhiteSpace($RawArch)) { $RawArch = '' }
    if ($RawArch -match 'ARM64|aarch64') { return 'arm64' }
    if ($RawArch -match 'AMD64|x86_64|x64|Intel64') { return 'x64' }
    return ''
}

# --- PURA: chave <os>-<arch> do asset (ou $null se SO/arch não suportado) ----------------------
function Resolve-CliProxyAssetKey {
    param(
        [string]$OS   = (Get-OnboardingOS),
        [string]$Arch = (Get-CliProxyHostArch)
    )
    $osPart = switch ($OS) {
        'Windows' { 'windows' }
        'Linux'   { 'linux' }
        'macOS'   { 'macos' }
        default   { $null }
    }
    if (-not $osPart -or -not $Arch) { return $null }
    return "$osPart-$Arch"
}

# --- PURA: expande a URL do asset -------------------------------------------------------------
function Get-CliProxyAssetUrl {
    param([Parameter(Mandatory)][hashtable]$Asset)
    return ($Asset.UrlTemplate -replace '\{tag\}', [string]$Asset.Tag -replace '\{asset\}', [string]$Asset.AssetName)
}

# --- PURA: nome do binário instalado por SO ---------------------------------------------------
function Get-CliProxyBinaryName {
    param([string]$OS = (Get-OnboardingOS))
    if ($OS -eq 'Windows') { return 'cli-proxy-api.exe' }
    return 'cli-proxy-api'
}

# --- PURA: caminho de instalação do binário ---------------------------------------------------
function Get-CliProxyBinaryPath {
    param(
        [Parameter(Mandatory)][string]$UserHome,
        [Parameter(Mandatory)][string]$Version,
        [string]$OS = (Get-OnboardingOS)
    )
    $dir = Join-Path (Join-Path (Join-Path (Join-Path $UserHome '.claude') 'tools') 'cliproxy') $Version
    return (Join-Path $dir (Get-CliProxyBinaryName -OS $OS))
}

# --- Read-only: marcador de versão instalada --------------------------------------------------
function Read-CliProxyVersionMarker {
    param([Parameter(Mandatory)][string]$UserHome)
    $file = Join-Path (Join-Path $UserHome '.claude') '.native-sdd-cliproxy-version'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $version = $null; $tag = $null
    foreach ($line in (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
        if     ($line -match '^\s*installed_version\s*:\s*(.+?)\s*$') { $version = $Matches[1].Trim() }
        elseif ($line -match '^\s*asset_tag\s*:\s*(.+?)\s*$')         { $tag = $Matches[1].Trim() }
    }
    if (-not $version) { return $null }
    return [pscustomobject]@{ InstalledVersion = $version; AssetTag = $tag }
}

# --- PURA: molde do marcador de versão --------------------------------------------------------
function Get-CliProxyVersionMarkerContent {
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$AssetTag,
        [string]$Sha256,
        [string]$Stamp
    )
    if (-not $Stamp) { $Stamp = (Get-Date).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
    @(
        '# Native-SDD cliproxy marker — gerado por onboarding/install.ps1 -WithCliProxy'
        '# Identifica a versão do binário CLIProxyAPI provisionada nesta máquina.'
        "installed_version: $Version"
        "asset_tag: $AssetTag"
        "sha256: $Sha256"
        "installed_at: $Stamp"
    ) -join "`r`n"
}

# --- Read-only: estado da instalação (missing | pinned | divergent) ---------------------------
function Get-CliProxyInstallState {
    param(
        [Parameter(Mandatory)][string]$UserHome,
        [Parameter(Mandatory)][string]$Version,
        [string]$OS = (Get-OnboardingOS)
    )
    $marker = Read-CliProxyVersionMarker -UserHome $UserHome
    $binary = Get-CliProxyBinaryPath -UserHome $UserHome -Version $Version -OS $OS
    if (-not $marker) { return 'missing' }
    if ($marker.InstalledVersion -ne $Version) { return 'divergent' }
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { return 'missing' }
    return 'pinned'
}

# --- EFEITO (rede): baixa o asset — ponto ÚNICO de rede, mockável em teste --------------------
function Invoke-CliProxyDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile
    )
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    }
    finally { $ProgressPreference = $prev }
}

# --- PURA-ish: verifica o SHA-256 de um arquivo contra o esperado -----------------------------
function Test-CliProxyChecksum {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Expected
    )
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $false }
    if (Test-CliProxyHashPlaceholder $Expected) { return $false }
    try {
        $actual = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash
        return ($actual -eq $Expected.ToUpperInvariant())
    }
    catch { return $false }
}

# --- EFEITO: extrai o archive e devolve o caminho do binário extraído ------------------------
function Expand-CliProxyArchive {
    # Extrai $ArchivePath (zip|tar.gz) em $DestDir e devolve o caminho do executável, ou $null se
    # o binário esperado não apareceu. NUNCA lança — o chamador converte em WARN.
    # tar: presente nativamente no Windows 10+ e em qualquer Linux/macOS.
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestDir,
        [Parameter(Mandatory)][string]$ArchiveKind,
        [Parameter(Mandatory)][string]$BinaryPath
    )
    try {
        if (-not (Test-Path -LiteralPath $DestDir -PathType Container)) {
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
        }
        if ($ArchiveKind -eq 'zip') {
            # Expand-Archive existe no 5.1; -Force sobrescreve resto de extração anterior.
            Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestDir -Force -ErrorAction Stop
        }
        else {
            & tar -xzf $ArchivePath -C $DestDir 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
        }
        $direct = Join-Path $DestDir $BinaryPath
        if (Test-Path -LiteralPath $direct -PathType Leaf) { return $direct }
        # Alguns releases embrulham tudo numa subpasta; procura pelo nome, 1 nível abaixo.
        $found = Get-ChildItem -LiteralPath $DestDir -Recurse -File -Filter (Split-Path -Leaf $BinaryPath) -ErrorAction SilentlyContinue |
                    Select-Object -First 1
        if ($found) { return $found.FullName }
        return $null
    }
    catch { return $null }
}

function Invoke-CliProxySetup {
    <#
    .SYNOPSIS
        Provisiona o binário CLIProxyAPI (efeito colateral). Nunca lança; falha = WARN.
        Opt-in: só é chamado quando o orquestrador recebe -WithCliProxy.
    .NOTES
        Integridade primeiro: o binário só é instalado se o SHA-256 do download bater com o
        manifest. Mismatch OU hash placeholder = aborta este addon (WARN), sem instalar nada.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$UserHome,
        [string]$ManifestPath = (Join-Path $RepoRoot 'onboarding/cliproxy/cliproxy.psd1'),
        [string]$OS   = (Get-OnboardingOS),
        [string]$Arch = (Get-CliProxyHostArch),
        [switch]$Check,
        [switch]$DryRun,
        [switch]$Force
    )

    # --- manifest -------------------------------------------------------------------------
    try { $manifest = Import-CliProxyManifest -Path $ManifestPath }
    catch { Write-Step WARN "cliproxy: $($_.Exception.Message) — reinstale o onboarding"; $Summary.Warn++; return }

    $schemaErr = Get-CliProxySchemaError -Manifest $manifest
    if (@($schemaErr).Count -gt 0) {
        Write-Step WARN "cliproxy: manifest inválido — $(@($schemaErr) -join '; ')"; $Summary.Warn++; return
    }
    $version = [string]$manifest.Version

    # --- resolve o asset do OS/arch -------------------------------------------------------
    $key = Resolve-CliProxyAssetKey -OS $OS -Arch $Arch
    if (-not $key -or -not $manifest.Assets.ContainsKey($key)) {
        Write-Step WARN "cliproxy: sem asset pinado para '$key' (OS=$OS arch=$Arch) — pulei"; $Summary.Warn++; return
    }
    $asset  = $manifest.Assets[$key]
    $url    = Get-CliProxyAssetUrl -Asset $asset
    $binary = Get-CliProxyBinaryPath -UserHome $UserHome -Version $version -OS $OS
    $state  = Get-CliProxyInstallState -UserHome $UserHome -Version $version -OS $OS

    # --- -Check: só relata o estado, nunca baixa/escreve ---------------------------------
    if ($Check) {
        $label = switch ($state) {
            'pinned'    { "instalado na versão pinada ($version)" }
            'divergent' { "instalado em versão divergente da pinada ($version)" }
            default     { "ausente (instalaria $version, asset '$key')" }
        }
        Write-Step INFO "cliproxy: $label"
        return
    }

    # --- hash não verificado (placeholder) -> NUNCA instala -------------------------------
    if (Test-CliProxyHashPlaceholder ([string]$asset.Sha256)) {
        Write-Step WARN "cliproxy: SHA-256 do asset '$key' é placeholder (não verificado) — não instalo binário não verificado."
        $Summary.Warn++
        return
    }

    # --- idempotência ---------------------------------------------------------------------
    if ($state -eq 'pinned' -and -not $Force) {
        Write-Step SKIP "cliproxy: já instalado na versão pinada ($version)"; $Summary.Skipped++; return
    }
    if ($state -eq 'divergent') {
        Write-Step WARN "cliproxy: versão divergente encontrada — atualizando para a pinada ($version)"; $Summary.Warn++
    }

    if ($DryRun) {
        Write-Step DRY "cliproxy: baixaria $url, verificaria SHA-256, extrairia e instalaria em $binary"
        return
    }

    # --- download -> verifica -> extrai -> instala ----------------------------------------
    $stamp   = [guid]::NewGuid().ToString('N')
    $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("cliproxy-$stamp-" + [string]$asset.AssetName)
    $tmpDir  = Join-Path ([System.IO.Path]::GetTempPath()) "cliproxy-x-$stamp"
    try {
        Write-Step RUN "cliproxy: baixando $($asset.AssetName) ($($asset.Tag))"
        Invoke-CliProxyDownload -Url $url -OutFile $tmpFile

        if (-not (Test-CliProxyChecksum -FilePath $tmpFile -Expected ([string]$asset.Sha256))) {
            Write-Step WARN "cliproxy: SHA-256 do download NÃO bate com o manifest — abortado, binário NÃO instalado (esperado: $($asset.Sha256))"
            $Summary.Warn++
            return
        }
        Write-Step OK 'cliproxy: SHA-256 verificado'

        $extracted = Expand-CliProxyArchive -ArchivePath $tmpFile -DestDir $tmpDir `
                        -ArchiveKind ([string]$asset.Archive) -BinaryPath ([string]$asset.BinaryPath)
        if (-not $extracted) {
            Write-Step WARN "cliproxy: não achei '$($asset.BinaryPath)' dentro do archive — nada instalado"
            $Summary.Warn++
            return
        }

        $destDir = Split-Path -Parent $binary
        if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $binary -PathType Leaf) {
            $bak = Backup-File -Path $binary
            if ($bak) { Write-Step BACKUP (Split-Path -Leaf $bak); $Summary.Backup++ }
        }
        Move-Item -LiteralPath $extracted -Destination $binary -Force -ErrorAction Stop
        if ($OS -ne 'Windows') { & chmod +x $binary 2>$null }
        Write-Step OK "cliproxy: instalado em $binary"
        $Summary.Installed++

        # --- marcador de versão -----------------------------------------------------------
        $markerDir = Join-Path $UserHome '.claude'
        if (-not (Test-Path -LiteralPath $markerDir -PathType Container)) {
            New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
        }
        $markerFile = Join-Path $markerDir '.native-sdd-cliproxy-version'
        Set-Content -LiteralPath $markerFile -NoNewline -Value (
            Get-CliProxyVersionMarkerContent -Version $version -AssetTag ([string]$asset.Tag) -Sha256 ([string]$asset.Sha256)
        )
        Write-Step OK "cliproxy: marcador de versão atualizado ($version)"
        Write-Step INFO 'cliproxy: para usar assinatura em vez de chave, faça o login uma vez: claudex -Login claude|codex|gemini'
    }
    catch {
        Write-Step WARN "cliproxy: falha ao provisionar — $($_.Exception.Message)"
        $Summary.Warn++
    }
    finally {
        if (Test-Path -LiteralPath $tmpFile -PathType Leaf) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tmpDir -PathType Container) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

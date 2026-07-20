# install-herdr.ps1 — provisiona o binário `herdr` (multiplexador de agentes terminal-native, de
# terceiro — repo público ogulcancelik/herdr) user-scoped. Passo OPT-IN (-WithHerdr) e NÃO
# bloqueante: qualquer falha vira WARN, nunca Failed — A1 (CLIs) e A2 (baseline ~/.claude)
# permanecem intactos. Mesma disciplina de install-claudex.ps1 / install-semantic-kb.ps1.
#
# O QUE FAZ (idempotente):
#   1. resolve o asset da versão PINADA (onboarding/herdr/herdr.psd1) p/ o OS/arch atual
#   2. baixa o asset, VERIFICA o SHA-256 contra o manifest ANTES de instalar (mismatch = aborta,
#      NUNCA instala o binário) — e RECUSA hash placeholder (nunca instala binário não verificado)
#   3. instala em ~/.claude/tools/herdr/<versão>/herdr(.exe)
#   4. grava ~/.claude/.native-sdd-herdr-version
#
# CLEAN-ROOM: tudo aqui deriva só da doc pública (herdr.dev) e do release público no GitHub —
# zero relação com qualquer uso interno de terceiros. Requer que lib.ps1 já esteja carregado
# (Write-Step, Backup-File, Get-OnboardingOS). Compatível com Windows PowerShell 5.1+ e PowerShell 7+.

Set-StrictMode -Version Latest

# --- PURA: importa o manifest pinado ----------------------------------------------------------
function Import-HerdrManifest {
    # Import-PowerShellDataFile é seguro (não executa código arbitrário). Lança se o arquivo sumir.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "herdr: manifest não encontrado em $Path"
    }
    return Import-PowerShellDataFile -LiteralPath $Path
}

# --- PURA: o hash é o placeholder "não verificado"? -------------------------------------------
function Test-HerdrHashPlaceholder {
    param([string]$Hash)
    if ([string]::IsNullOrWhiteSpace($Hash)) { return $true }
    return ($Hash -notmatch '^[0-9a-fA-F]{64}$')
}

# --- PURA: valida o schema do manifest; devolve lista de erros (vazia = ok) --------------------
function Get-HerdrSchemaError {
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
        foreach ($field in @('Tag', 'AssetName', 'UrlTemplate', 'Sha256')) {
            if (-not $a.ContainsKey($field) -or [string]::IsNullOrWhiteSpace([string]$a[$field])) {
                $errors.Add("asset '$key' sem $field")
            }
        }
        # Hash: 64 hex OU o placeholder explícito — nada mais é aceito (nunca um hash "quase certo").
        $h = [string]$a['Sha256']
        if ($h -and (Test-HerdrHashPlaceholder $h) -and $h -ne 'PENDENTE-verificar-manualmente') {
            $errors.Add("asset '$key' Sha256 inválido (nem 64 hex nem placeholder): $h")
        }
    }
    return $errors
}

# --- PURA: arch do host (injetável em teste) --------------------------------------------------
# MESMO BUG que o de Get-CliProxyHostArch (2026-07-19): `$env:PROCESSOR_ARCHITECTURE` SÓ EXISTE NO
# WINDOWS, então em Linux/macOS o arch vinha vazio, Resolve-HerdrAssetKey devolvia $null e os 4
# assets linux/macos que herdr.psd1 DECLARA eram inalcançáveis — `-WithHerdr` dizia "SO/arch não
# suportado" numa plataforma cujo asset estava declarado logo ali. Medido em container Linux.
# Achado ao varrer a suíte atrás da MESMA classe de defeito depois de corrigir o cliproxy: o molde
# foi copiado, e o defeito veio junto. `RuntimeInformation::OSArchitecture` é multiplataforma
# (existe no .NET Framework 4.7.1+, então vale no Windows PowerShell 5.1); env var só como fallback.
function Get-HerdrHostArch {
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
function Resolve-HerdrAssetKey {
    param(
        [string]$OS   = (Get-OnboardingOS),
        [string]$Arch = (Get-HerdrHostArch)
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
function Get-HerdrAssetUrl {
    param([Parameter(Mandatory)][hashtable]$Asset)
    return ($Asset.UrlTemplate -replace '\{tag\}', [string]$Asset.Tag -replace '\{asset\}', [string]$Asset.AssetName)
}

# --- PURA: nome do binário instalado por SO ---------------------------------------------------
function Get-HerdrBinaryName {
    param([string]$OS = (Get-OnboardingOS))
    if ($OS -eq 'Windows') { return 'herdr.exe' }
    return 'herdr'
}

# --- PURA: caminho de instalação do binário ---------------------------------------------------
function Get-HerdrBinaryPath {
    param(
        [Parameter(Mandatory)][string]$UserHome,
        [Parameter(Mandatory)][string]$Version,
        [string]$OS = (Get-OnboardingOS)
    )
    $dir = Join-Path (Join-Path (Join-Path (Join-Path $UserHome '.claude') 'tools') 'herdr') $Version
    return (Join-Path $dir (Get-HerdrBinaryName -OS $OS))
}

# --- Read-only: marcador de versão instalada --------------------------------------------------
function Read-HerdrVersionMarker {
    # Lê ~/.claude/.native-sdd-herdr-version. $null se ausente/sem installed_version. Pura/read-only.
    param([Parameter(Mandatory)][string]$UserHome)
    $file = Join-Path (Join-Path $UserHome '.claude') '.native-sdd-herdr-version'
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
function Get-HerdrVersionMarkerContent {
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$AssetTag,
        [string]$Sha256,
        [string]$Stamp
    )
    if (-not $Stamp) { $Stamp = (Get-Date).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
    @(
        '# Native-SDD herdr marker — gerado por onboarding/install.ps1 -WithHerdr'
        '# Identifica a versão do binário herdr provisionada nesta máquina.'
        "installed_version: $Version"
        "asset_tag: $AssetTag"
        "sha256: $Sha256"
        "installed_at: $Stamp"
    ) -join "`r`n"
}

# --- Read-only: estado da instalação (missing | pinned | divergent) ---------------------------
function Get-HerdrInstallState {
    # 'missing'   -> sem marcador OU binário ausente
    # 'pinned'    -> marcador == versão pinada E binário presente
    # 'divergent' -> marcador presente mas != versão pinada
    param(
        [Parameter(Mandatory)][string]$UserHome,
        [Parameter(Mandatory)][string]$Version,
        [string]$OS = (Get-OnboardingOS)
    )
    $marker = Read-HerdrVersionMarker -UserHome $UserHome
    $binary = Get-HerdrBinaryPath -UserHome $UserHome -Version $Version -OS $OS
    if (-not $marker) { return 'missing' }
    if ($marker.InstalledVersion -ne $Version) { return 'divergent' }
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { return 'missing' }
    return 'pinned'
}

# --- EFEITO (rede): baixa o asset — ponto ÚNICO de rede, mockável em teste --------------------
function Invoke-HerdrDownload {
    # Baixa $Url -> $OutFile. Separado de propósito p/ o Pester poder Mock-ar (a suíte NUNCA baixa
    # de verdade). -UseBasicParsing: compat 5.1. Progress bar desligada durante o download.
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
function Test-HerdrChecksum {
    # $true só se o arquivo existe E o hash bate (case-insensitive). Nunca lança.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Expected
    )
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $false }
    if (Test-HerdrHashPlaceholder $Expected) { return $false }
    try {
        $actual = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash
        return ($actual -eq $Expected.ToUpperInvariant())
    }
    catch { return $false }
}

function Invoke-HerdrSetup {
    <#
    .SYNOPSIS
        Executa o provisionamento do herdr (efeito colateral). Nunca lança; falha = WARN.
        Opt-in: só é chamado quando o orquestrador recebe -WithHerdr.
    .NOTES
        Integridade primeiro: o binário só é instalado se o SHA-256 do download bater com o
        manifest. Mismatch OU hash placeholder = aborta este addon (WARN), sem escrever o binário.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$UserHome,
        [string]$ManifestPath = (Join-Path $RepoRoot 'onboarding/herdr/herdr.psd1'),
        [string]$OS   = (Get-OnboardingOS),
        [string]$Arch = (Get-HerdrHostArch),
        [switch]$Check,
        [switch]$DryRun,
        [switch]$Force
    )

    # --- manifest -------------------------------------------------------------------------
    try { $manifest = Import-HerdrManifest -Path $ManifestPath }
    catch { Write-Step WARN "herdr: $($_.Exception.Message) — reinstale o onboarding"; $Summary.Warn++; return }

    $schemaErr = Get-HerdrSchemaError -Manifest $manifest
    if (@($schemaErr).Count -gt 0) {
        Write-Step WARN "herdr: manifest inválido — $(@($schemaErr) -join '; ')"; $Summary.Warn++; return
    }
    $version = [string]$manifest.Version

    # --- resolve o asset do OS/arch -------------------------------------------------------
    $key = Resolve-HerdrAssetKey -OS $OS -Arch $Arch
    if (-not $key -or -not $manifest.Assets.ContainsKey($key)) {
        Write-Step WARN "herdr: sem asset pinado para '$key' (OS=$OS arch=$Arch) — pulei"; $Summary.Warn++; return
    }
    $asset  = $manifest.Assets[$key]
    $url    = Get-HerdrAssetUrl -Asset $asset
    $binary = Get-HerdrBinaryPath -UserHome $UserHome -Version $version -OS $OS
    $state  = Get-HerdrInstallState -UserHome $UserHome -Version $version -OS $OS

    # --- -Check: só relata o estado (ausente/pinado/divergente), nunca baixa/escreve ------
    if ($Check) {
        $label = switch ($state) {
            'pinned'    { "instalado na versão pinada ($version)" }
            'divergent' { "instalado em versão divergente da pinada ($version)" }
            default     { "ausente (instalaria $version, asset '$key')" }
        }
        Write-Step INFO "herdr: $label"
        return
    }

    # --- hash não verificado (placeholder) -> NUNCA instala -------------------------------
    if (Test-HerdrHashPlaceholder ([string]$asset.Sha256)) {
        Write-Step WARN "herdr: SHA-256 do asset '$key' é placeholder (não verificado) — não instalo binário não verificado. Verifique o hash no manifest primeiro."
        $Summary.Warn++
        return
    }

    # --- idempotência ---------------------------------------------------------------------
    if ($state -eq 'pinned' -and -not $Force) {
        Write-Step SKIP "herdr: já instalado na versão pinada ($version)"; $Summary.Skipped++; return
    }
    if ($state -eq 'divergent') {
        Write-Step WARN "herdr: versão divergente encontrada — atualizando para a pinada ($version)"; $Summary.Warn++
    }

    if ($DryRun) {
        Write-Step DRY "herdr: baixaria $url, verificaria SHA-256 e instalaria em $binary"
        return
    }

    # --- download -> verifica -> instala --------------------------------------------------
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("herdr-" + [guid]::NewGuid().ToString('N') + [System.IO.Path]::GetExtension($asset.AssetName))
    try {
        Write-Step RUN "herdr: baixando $($asset.AssetName) ($($asset.Tag))"
        Invoke-HerdrDownload -Url $url -OutFile $tmp

        if (-not (Test-HerdrChecksum -FilePath $tmp -Expected ([string]$asset.Sha256))) {
            Write-Step WARN "herdr: SHA-256 do download NÃO bate com o manifest — abortado, binário NÃO instalado (esperado: $($asset.Sha256))"
            $Summary.Warn++
            return
        }
        Write-Step OK 'herdr: SHA-256 verificado'

        $destDir = Split-Path -Parent $binary
        if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $binary -PathType Leaf) {
            $bak = Backup-File -Path $binary
            if ($bak) { Write-Step BACKUP (Split-Path -Leaf $bak); $Summary.Backup++ }
        }
        Move-Item -LiteralPath $tmp -Destination $binary -Force -ErrorAction Stop
        Write-Step OK "herdr: instalado em $binary"
        $Summary.Installed++

        # --- marcador de versão -----------------------------------------------------------
        $markerDir = Join-Path $UserHome '.claude'
        if (-not (Test-Path -LiteralPath $markerDir -PathType Container)) {
            New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
        }
        $markerFile = Join-Path $markerDir '.native-sdd-herdr-version'
        Set-Content -LiteralPath $markerFile -NoNewline -Value (
            Get-HerdrVersionMarkerContent -Version $version -AssetTag ([string]$asset.Tag) -Sha256 ([string]$asset.Sha256)
        )
        Write-Step OK "herdr: marcador de versão atualizado ($version)"
        Write-Step INFO "herdr: pronto — adicione $destDir ao PATH (ou chame o binário direto). Docs: https://herdr.dev/docs/"
    }
    catch {
        Write-Step WARN "herdr: falha ao provisionar — $($_.Exception.Message)"
        $Summary.Warn++
    }
    finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

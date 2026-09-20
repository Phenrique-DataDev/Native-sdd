# install-herdr.ps1 — provisiona o binário `herdr` (multiplexador de agentes terminal-native, de
# terceiro — repo público herdrdev/herdr) user-scoped. Passo OPT-IN (-WithHerdr) e NÃO
# bloqueante: qualquer falha vira WARN, nunca Failed — A1 (CLIs) e A2 (baseline ~/.claude)
# permanecem intactos. Mesma disciplina de install-mcp.ps1 e install-plugins.ps1.
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
# MESMO BUG achado na varredura de 2026-07-19: `$env:PROCESSOR_ARCHITECTURE` SÓ EXISTE NO
# WINDOWS, então em Linux/macOS o arch vinha vazio, Resolve-HerdrAssetKey devolvia $null e os 4
# assets linux/macos que herdr.psd1 DECLARA eram inalcançáveis — `-WithHerdr` dizia "SO/arch não
# suportado" numa plataforma cujo asset estava declarado logo ali. Medido em container Linux.
# Achado ao varrer a suíte atrás da MESMA classe de defeito: o molde
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

# --- PURA: o asset é um ARCHIVE (precisa extrair) ou o binário cru? ---------------------------
# Em 2026-07-29 o upstream trocou o asset do Windows de `herdr-windows-x86_64.exe` para `.zip`.
# MEDIDO abrindo o .zip real (preview-2026-08-04): ele NÃO embrulha só o binário — traz
# `herdr.exe` + `conpty/` (conpty.dll, OpenConsole x64 e arm64, herdr-conpty.json com os SHA-256
# de cada um) + THIRD-PARTY-NOTICES. As notas da v0.8.0 confirmam: *"Windows preview downloads now
# include Herdr and a modern app-local ConPTY runtime in one archive"*. Por isso a instalação
# copia a ÁRVORE INTEIRA — extrair só o `.exe` entregaria um herdr sem o runtime que o acompanha.
function Test-HerdrAssetIsArchive {
    param([string]$AssetName)
    return ([string]$AssetName -match '\.zip$')
}

# --- PURA: nome do binário instalado por SO ---------------------------------------------------
function Get-HerdrBinaryName {
    param([string]$OS = (Get-OnboardingOS))
    if ($OS -eq 'Windows') { return 'herdr.exe' }
    return 'herdr'
}

# --- EFEITO: expande o archive e instala a ÁRVORE no destino; devolve $true se o binário nasceu -
# A verificação de integridade continua sendo do ASSET BAIXADO (o .zip), feita ANTES de chamar
# isto — o hash do manifest é do arquivo publicado, não do conteúdo extraído. Aqui só se garante
# que o archive de fato produziu o binário esperado: um .zip com layout diferente do previsto
# instalaria uma pasta sem `herdr.exe` e o passo seguinte gravaria um marcador MENTIROSO.
function Expand-HerdrArchive {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestinationDir,
        [Parameter(Mandatory)][string]$BinaryName
    )
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("herdr-x-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $staging -Force -ErrorAction Stop
        $encontrado = Get-ChildItem -LiteralPath $staging -Filter $BinaryName -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $encontrado) { return $false }
        # A raiz é a PASTA do binário, não a do staging: alguns archives embrulham tudo numa
        # subpasta com o nome da release, e copiar o staging cru enterraria o binário um nível.
        $raiz = Split-Path -Parent $encontrado.FullName
        Copy-Item -Path (Join-Path $raiz '*') -Destination $DestinationDir -Recurse -Force -ErrorAction Stop
        return (Test-Path -LiteralPath (Join-Path $DestinationDir $BinaryName) -PathType Leaf)
    }
    finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
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

# --- Read-only (EFEITO leve): quem é o `herdr` que o PATH resolve? Mockável em teste ----------
# Separado de propósito: é um dos DOIS pontos que executam binário de terceiro (o outro é
# Test-HerdrBinaryRuns), e a suíte mocka os dois.
function Get-HerdrPathCommand {
    param([string]$Name = 'herdr')
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $null }
    $reported = ''
    try { $reported = [string](& $cmd.Source '--version' 2>$null | Select-Object -First 1) } catch { $reported = '' }
    return [pscustomobject]@{ Source = [string]$cmd.Source; Reported = $reported }
}

# --- EFEITO: bit de execução fora do Windows — mockável em teste ------------------------------
# HERDR_SEM_BIT_DE_EXECUCAO (2026-09-11): o `Move-Item` do download deixava o binário
# `-rw-r--r--` no macOS e no Linux (medido num Mac com o asset real), e o passo dizia OK sobre um
# arquivo que o shell recusa. Só existe fora do Windows: o NTFS não tem esse bit, e as APIs abaixo
# lançam PlatformNotSupportedException lá. `File.SetUnixFileMode` é do .NET 7 (pwsh 7.3+).
function Test-HerdrExecutableBit {
    param([Parameter(Mandatory)][string]$Path)
    try { return [bool]([System.IO.File]::GetUnixFileMode($Path) -band [System.IO.UnixFileMode]::UserExecute) }
    catch { return $false }
}

function Set-HerdrExecutableBit {
    param([Parameter(Mandatory)][string]$Path)
    $x = [System.IO.UnixFileMode]::UserExecute -bor [System.IO.UnixFileMode]::GroupExecute -bor [System.IO.UnixFileMode]::OtherExecute
    [System.IO.File]::SetUnixFileMode($Path, ([System.IO.File]::GetUnixFileMode($Path) -bor $x))
}

# --- EFEITO: o binário instalado RODA? — mockável em teste ------------------------------------
# O hash prova que o arquivo é o certo; não prova que ele executa (bit, arch, loader). Sem isto o
# passo gravava o marcador e dizia OK sobre um binário que dá `permission denied`.
function Test-HerdrBinaryRuns {
    param([Parameter(Mandatory)][string]$Path)
    try { & $Path '--version' *> $null; return ($LASTEXITCODE -eq 0) }
    catch { return $false }
}

# --- PURA: núcleo semver de um texto qualquer ('herdr 0.8.0-preview.2026-08-04' -> '0.8.0') ----
function Get-HerdrSemverCore {
    param([string]$Text)
    if ([string]$Text -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

# --- PURA: o binário do PATH é o que verificamos? Devolve as linhas do aviso (vazio = ok) -------
# POR QUE ISSO EXISTE: o onboarding pina um asset, confere o SHA-256 e o instala em
# ~/.claude/tools/herdr/<versao> — FORA do PATH (o próprio passo só diz "adicione ao PATH"). Quem
# resolve com `Get-Command herdr` (a skill `orchestrating-agents`, por exemplo) pode acabar num
# binário instalado por fora, mais VELHO e que a cadeia de integridade nunca cobriu — medido nesta
# máquina em 2026-08-08: PATH = 0.7.2 do instalador oficial, pinado = 0.7.4 conferido.
# O aviso é a fatia inteira, de propósito: mexer no PATH expandiria o footprint numa máquina onde o
# usuário JÁ escolheu instalar por fora. Dizer a verdade > decidir por ele.
function Format-HerdrPathDivergence {
    param(
        [AllowNull()][object]$PathCommand,
        [Parameter(Mandatory)][string]$PinnedBinary,
        [Parameter(Mandatory)][string]$PinnedVersion
    )
    # Nada no PATH: não há divergência a relatar (o passo já instrui a adicionar ao PATH).
    if (-not $PathCommand -or -not $PathCommand.Source) { return @() }

    # `GetFullPath` colapsa `.\` e barras mistas; sem isso, o MESMO arquivo escrito de duas formas
    # viraria "divergência" e o aviso perderia a credibilidade no primeiro uso.
    $norm = {
        param($x)
        try { [System.IO.Path]::GetFullPath([string]$x).TrimEnd([char[]]@('\', '/')) } catch { [string]$x }
    }
    if ((& $norm $PathCommand.Source) -eq (& $norm $PinnedBinary)) { return @() }

    $verPath   = Get-HerdrSemverCore ([string]$PathCommand.Reported)
    $verPinado = Get-HerdrSemverCore $PinnedVersion
    $sufixo = if ($verPath) { " ($verPath)" } else { ' (versão não lida)' }

    $linhas = @(
        "herdr: o binário do PATH NÃO é o que este onboarding verificou"
        "       PATH  : $($PathCommand.Source)$sufixo"
        "       pinado: $PinnedBinary ($(if ($verPinado) { $verPinado } else { $PinnedVersion }), SHA-256 conferido)"
        '       quem resolve com `Get-Command herdr` (ex.: a skill orchestrating-agents) usa o do PATH.'
    )
    if ($verPath -and $verPinado -and $verPath -ne $verPinado) {
        $linhas += "       as versões também divergem: $verPath (PATH) x $verPinado (pinado)."
    }
    return $linhas
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
    # Instalação anterior à 0.10.49 fora do Windows: pinada, mas gravada sem o bit de execução.
    $semBit = ($state -eq 'pinned') -and ($OS -ne 'Windows') -and -not (Test-HerdrExecutableBit -Path $binary)

    # --- -Check: só relata o estado (ausente/pinado/divergente), nunca baixa/escreve ------
    if ($Check) {
        $label = switch ($state) {
            'pinned'    { if ($semBit) { "instalado na versão pinada ($version), mas SEM bit de execução — rode -WithHerdr para reparar" } else { "instalado na versão pinada ($version)" } }
            'divergent' { "instalado em versão divergente da pinada ($version)" }
            default     { "ausente (instalaria $version, asset '$key')" }
        }
        Write-Step INFO "herdr: $label"
        foreach ($linha in (Format-HerdrPathDivergence -PathCommand (Get-HerdrPathCommand) -PinnedBinary $binary -PinnedVersion $version)) {
            Write-Step WARN $linha
        }
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
        if (-not $semBit) {
            Write-Step SKIP "herdr: já instalado na versão pinada ($version)"; $Summary.Skipped++; return
        }
        # O SKIP deixaria quebrado para sempre quem instalou antes do fix: o hash já foi conferido
        # naquela instalação, então o reparo é só o bit — sem novo download.
        if ($DryRun) { Write-Step DRY "herdr: ligaria o bit de execução de $binary"; return }
        try {
            Set-HerdrExecutableBit -Path $binary
            Write-Step OK "herdr: bit de execução reparado em $binary"
        }
        catch { Write-Step WARN "herdr: não consegui ligar o bit de execução de $binary — $($_.Exception.Message)"; $Summary.Warn++ }
        return
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
        if (Test-HerdrAssetIsArchive -AssetName ([string]$asset.AssetName)) {
            # Árvore inteira: o .zip do Windows traz o runtime ConPTY app-local junto do binário.
            # -OS repassado: sem ele o nome do binário vinha do SO do HOST, e não do asset pedido
            # (achado no runner macos-15: o .zip do Windows procurava `herdr`, não `herdr.exe`).
            if (-not (Expand-HerdrArchive -ArchivePath $tmp -DestinationDir $destDir -BinaryName (Get-HerdrBinaryName -OS $OS))) {
                Write-Step WARN "herdr: o archive $($asset.AssetName) não produziu $(Get-HerdrBinaryName -OS $OS) — abortado, nada instalado"
                $Summary.Warn++
                return
            }
            Write-Step OK "herdr: archive extraído (binário + runtime adjacente)"
        }
        else {
            Move-Item -LiteralPath $tmp -Destination $binary -Force -ErrorAction Stop
        }
        if ($OS -ne 'Windows') { Set-HerdrExecutableBit -Path $binary }

        # Sem marcador quando não roda: o estado fica 'missing' e o próximo -WithHerdr tenta de novo.
        if (-not (Test-HerdrBinaryRuns -Path $binary)) {
            Write-Step WARN "herdr: $binary foi gravado, mas '--version' falhou — marcador NÃO gravado"
            $Summary.Warn++
            return
        }
        Write-Step OK "herdr: instalado em $binary (--version respondeu)"
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

        # Depois de instalar, e não antes: o aviso só faz sentido comparando com o que ACABOU de
        # ficar no disco. Nunca incrementa Warn — é diagnóstico do ambiente, não falha do passo.
        foreach ($linha in (Format-HerdrPathDivergence -PathCommand (Get-HerdrPathCommand) -PinnedBinary $binary -PinnedVersion $version)) {
            Write-Step WARN $linha
        }
    }
    catch {
        Write-Step WARN "herdr: falha ao provisionar — $($_.Exception.Message)"
        $Summary.Warn++
    }
    finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

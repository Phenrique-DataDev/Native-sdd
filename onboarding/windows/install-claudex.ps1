# install-claudex.ps1 — provisiona o `claudex` (troca fina de modelo/provider Anthropic-
# compatível) user-scoped. Passo OPT-IN (-WithClaudex) e NÃO bloqueante: qualquer falha vira
# WARN, nunca Failed — A1 (CLIs) e A2 (baseline ~/.claude) permanecem intactos. Mesma disciplina
# de install-semantic-kb.ps1 / install-local-ai.ps1.
#
# O QUE FAZ (idempotente, backup antes de sobrescrever quando cabe):
#   1. cria ~/.claude/claudex/ e SEMEIA profiles.psd1 (só se ausente — NÃO clobbera customização)
#   2. cria ~/.claude/claudex/secrets/ com ACL restrita ao usuário atual (icacls/chmod)
#   3. registra a função `claudex` no $PROFILE (bloco próprio, mesmo molde de New-SddProject/nsp)
#   4. instala o command /claudex-add-model em ~/.claude/commands (este SIM é sobrescrito —
#      é conteúdo nosso versionado, não config do usuário; backup antes)
#   5. grava ~/.claude/.native-sdd-claudex-version
#
# O runtime do wrapper vive versionado em onboarding/claudex/ (claudex.ps1 + claudex-lib.ps1 +
# profiles.psd1 seed). Requer que lib.ps1 já esteja carregado (Write-Step, Backup-File,
# Get-OnboardingOS). Compatível com Windows PowerShell 5.1+ e PowerShell 7+.

Set-StrictMode -Version Latest

# Marcadores do bloco de shim do claudex — próprios (NÃO os de sdd-workflow), p/ o -WithClaudex
# ser auto-contido e idempotente sem perturbar o bloco always-on nem seus testes.
$script:ClaudexShimStart = '# >>> claudex >>>'
$script:ClaudexShimEnd   = '# <<< claudex <<<'

function Get-ClaudexShimBlock {
    # Texto do bloco a injetar no $PROFILE: define a função `claudex` delegando ao script
    # versionado. Resolve o caminho via $env:SDD_WORKFLOW_HOME (setado pelo bloco sdd-workflow;
    # re-setado aqui p/ ser auto-contido). Aspas simples no caminho são escapadas ('').
    param([Parameter(Mandatory)][string]$RepoRoot)
    $rootEsc = $RepoRoot -replace "'", "''"
    @(
        $script:ClaudexShimStart
        '# Gerado por onboarding/install.ps1 (-WithClaudex) — não edite à mão (regenerado a cada install).'
        "`$env:SDD_WORKFLOW_HOME = '$rootEsc'"
        'function claudex { & (Join-Path $env:SDD_WORKFLOW_HOME ''onboarding\claudex\claudex.ps1'') @args }'
        $script:ClaudexShimEnd
    ) -join "`r`n"
}

function Get-ClaudexVersionMarkerContent {
    # Pura: molde `key: value` do .native-sdd-version, arquivo/propósito distintos (versão do
    # addon claudex instalado nesta máquina). Recebe versão e stamp já resolvidos.
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$Stamp
    )
    if (-not $Stamp) { $Stamp = (Get-Date).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
    @(
        '# Native-SDD claudex marker — gerado por onboarding/install.ps1 -WithClaudex'
        '# Identifica a versão do addon claudex provisionada nesta máquina.'
        "installed_version: $Version"
        "installed_at: $Stamp"
    ) -join "`r`n"
}

function Set-ClaudexSecretsAcl {
    # Restringe o diretório de secrets ao usuário atual. Windows: icacls (remove herança, concede
    # só ao usuário) — assim "Users"/"Everyone" perdem acesso. POSIX: chmod 700. Falha = $false
    # (o chamador reporta WARN; não bloqueia). NÃO cria o diretório — assume que já existe.
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$OS = (Get-OnboardingOS)
    )
    try {
        if ($OS -eq 'Windows') {
            $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            # /inheritance:r remove ACEs herdadas (tira Users/Everyone); /grant:r reseta e concede
            # ao usuário atual controle total, com herança p/ os arquivos de segredo (OI)(CI).
            & icacls $Path /inheritance:r /grant:r "${user}:(OI)(CI)F" 2>&1 | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
        else {
            & chmod 700 $Path 2>&1 | Out-Null
            return ($LASTEXITCODE -eq 0)
        }
    }
    catch { return $false }
}

function Install-ClaudexShim {
    # Injeta/atualiza o bloco `claudex` no $PROFILE, idempotente (mesma técnica de regex do
    # Install-ProfileShim, com marcadores próprios). Ausente -> anexa; presente e igual -> SKIP;
    # presente e diferente -> backup + substitui.
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$Summary,
        [switch]$Check,
        [switch]$DryRun
    )
    $block   = Get-ClaudexShimBlock -RepoRoot $RepoRoot
    $exists  = Test-Path -LiteralPath $ProfilePath -PathType Leaf
    $current = if ($exists) { Get-Content -LiteralPath $ProfilePath -Raw } else { '' }

    $pattern  = '(?s)' + [regex]::Escape($script:ClaudexShimStart) + '.*?' + [regex]::Escape($script:ClaudexShimEnd)
    $hasBlock = [regex]::IsMatch($current, $pattern)

    if ($hasBlock) {
        $target = [regex]::Replace($current, $pattern, { $block }.GetNewClosure())
    }
    else {
        $sep    = if (-not $exists -or [string]::IsNullOrEmpty($current)) { '' }
                  elseif ($current.EndsWith("`n")) { '' } else { "`r`n" }
        $target = $current + $sep + $block + "`r`n"
    }

    if ($exists -and ($target.Trim() -eq $current.Trim())) {
        Write-Step SKIP 'claudex: shim do profile já atualizado'
        $Summary.Skipped++
        return
    }
    if ($Check)  { Write-Step INFO ("claudex: shim do profile ({0})" -f $(if ($hasBlock) { 'difere' } else { 'faltando' })); return }
    if ($DryRun) { Write-Step DRY  "claudex: escreve shim do profile: $ProfilePath"; return }

    try {
        $dir = Split-Path -Parent $ProfilePath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ($exists) {
            $bak = Backup-File -Path $ProfilePath
            if ($bak) { Write-Step BACKUP (Split-Path -Leaf $bak); $Summary.Backup++ }
        }
        [System.IO.File]::WriteAllText($ProfilePath, $target, [System.Text.UTF8Encoding]::new($false))
        Write-Step OK 'claudex: função claudex registrada no profile'
        $Summary.Installed++
    }
    catch {
        Write-Step WARN "claudex: falha ao gravar o shim do profile — $($_.Exception.Message)"
        $Summary.Warn++
    }
}

function Invoke-ClaudexSetup {
    <#
    .SYNOPSIS
        Executa o provisionamento do claudex (efeito colateral). Nunca lança; falha = WARN.
        Opt-in: só é chamado quando o orquestrador recebe -WithClaudex.
    .NOTES
        Seed do profiles.psd1: só CRIA se ausente. NÃO sobrescreve um profiles.psd1 existente —
        ele é config do usuário; clobberar destruiria perfis/segredos que ele adicionou (é o que
        garante a idempotência: rodar 2x não corrompe quem customizou).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$UserHome,
        [string]$ProfilePath,
        [string]$Version = '',
        [string]$OS = (Get-OnboardingOS),
        [switch]$Check,
        [switch]$DryRun
    )

    $seedProfiles = Join-Path $RepoRoot 'onboarding/claudex/profiles.psd1'
    if (-not (Test-Path -LiteralPath $seedProfiles -PathType Leaf)) {
        Write-Step WARN "claudex: seed profiles.psd1 não encontrado em $seedProfiles — reinstale o onboarding"
        $Summary.Warn++
        return
    }

    $claudexHome = Join-Path (Join-Path $UserHome '.claude') 'claudex'
    $secretsDir  = Join-Path $claudexHome 'secrets'
    $destProfiles = Join-Path $claudexHome 'profiles.psd1'

    # --- 1. diretório de config -----------------------------------------------------------
    if (-not (Test-Path -LiteralPath $claudexHome -PathType Container)) {
        if ($Check)      { Write-Step INFO "claudex: criaria $claudexHome" }
        elseif ($DryRun) { Write-Step DRY  "mkdir $claudexHome" }
        else {
            try { New-Item -ItemType Directory -Path $claudexHome -Force | Out-Null; Write-Step OK "claudex: $claudexHome" }
            catch { Write-Step WARN "claudex: falha ao criar $claudexHome — $($_.Exception.Message)"; $Summary.Warn++; return }
        }
    }

    # --- 2. seed do profiles.psd1 (só se ausente) -----------------------------------------
    if (Test-Path -LiteralPath $destProfiles -PathType Leaf) {
        Write-Step SKIP 'claudex: profiles.psd1 já existe (preservado — sua config)'
        $Summary.Skipped++
    }
    else {
        if ($Check)      { Write-Step INFO 'claudex: semearia profiles.psd1' }
        elseif ($DryRun) { Write-Step DRY  "copia seed -> $destProfiles" }
        else {
            try { Copy-Item -LiteralPath $seedProfiles -Destination $destProfiles -Force -ErrorAction Stop; Write-Step OK 'claudex: profiles.psd1 semeado'; $Summary.Installed++ }
            catch { Write-Step WARN "claudex: falha ao semear profiles.psd1 — $($_.Exception.Message)"; $Summary.Warn++ }
        }
    }

    # --- 3. diretório de secrets + ACL ----------------------------------------------------
    if ($Check)      { Write-Step INFO "claudex: garantiria $secretsDir com ACL restrita" }
    elseif ($DryRun) { Write-Step DRY  "mkdir $secretsDir + icacls/chmod restrito" }
    else {
        try {
            if (-not (Test-Path -LiteralPath $secretsDir -PathType Container)) {
                New-Item -ItemType Directory -Path $secretsDir -Force | Out-Null
            }
            if (Set-ClaudexSecretsAcl -Path $secretsDir -OS $OS) {
                Write-Step OK 'claudex: secrets/ com ACL restrita ao usuário'
            }
            else {
                Write-Step WARN "claudex: não foi possível endurecer a ACL de $secretsDir — verifique manualmente"
                $Summary.Warn++
            }
        }
        catch { Write-Step WARN "claudex: falha no diretório de secrets — $($_.Exception.Message)"; $Summary.Warn++ }
    }

    # --- 4. shim do profile (função claudex) ----------------------------------------------
    if ($OS -eq 'Windows' -and $ProfilePath) {
        Install-ClaudexShim -ProfilePath $ProfilePath -RepoRoot $RepoRoot -Summary $Summary -Check:$Check -DryRun:$DryRun
    }
    elseif ($ProfilePath) {
        # POSIX: mesma ideia via rc de shell fica p/ paridade futura; hoje o wrapper roda via
        # `pwsh -File onboarding/claudex/claudex.ps1` diretamente.
        Write-Step INFO 'claudex: shim de shell POSIX não instalado nesta fase (use pwsh -File onboarding/claudex/claudex.ps1)'
    }

    # --- 5. command /claudex-add-model (user-scoped) --------------------------------------
    # Vai p/ ~/.claude/commands/ e fica disponível em QUALQUER projeto — é um comando de
    # máquina (configura o claudex desta máquina), não de projeto. Ao contrário do
    # profiles.psd1, este arquivo É sobrescrito: é conteúdo nosso, versionado, não config
    # do usuário. Backup antes, como todo o resto.
    $seedCmdDir = Join-Path $RepoRoot 'onboarding/claudex/commands'
    if (Test-Path -LiteralPath $seedCmdDir -PathType Container) {
        $cmdDir = Join-Path (Join-Path $UserHome '.claude') 'commands'
        foreach ($seedCmd in @(Get-ChildItem -LiteralPath $seedCmdDir -Filter '*.md' -File)) {
            $destCmd = Join-Path $cmdDir $seedCmd.Name
            $slash   = '/' + [System.IO.Path]::GetFileNameWithoutExtension($seedCmd.Name)
            $same    = (Test-Path -LiteralPath $destCmd -PathType Leaf) -and
                       ((Get-Content -LiteralPath $destCmd -Raw) -eq (Get-Content -LiteralPath $seedCmd.FullName -Raw))
            if ($same) {
                Write-Step SKIP "claudex: $slash já atualizado"
                $Summary.Skipped++
                continue
            }
            if ($Check)  { Write-Step INFO "claudex: instalaria o command $slash"; continue }
            if ($DryRun) { Write-Step DRY  "copia command -> $destCmd"; continue }
            try {
                if (-not (Test-Path -LiteralPath $cmdDir -PathType Container)) {
                    New-Item -ItemType Directory -Path $cmdDir -Force | Out-Null
                }
                if (Test-Path -LiteralPath $destCmd -PathType Leaf) {
                    $bak = Backup-File -Path $destCmd
                    if ($bak) { Write-Step BACKUP (Split-Path -Leaf $bak); $Summary.Backup++ }
                }
                Copy-Item -LiteralPath $seedCmd.FullName -Destination $destCmd -Force -ErrorAction Stop
                Write-Step OK "claudex: command $slash instalado"
                $Summary.Installed++
            }
            catch { Write-Step WARN "claudex: falha ao instalar $slash — $($_.Exception.Message)"; $Summary.Warn++ }
        }
    }
    else {
        Write-Step WARN "claudex: dir de commands não encontrado em $seedCmdDir"
        $Summary.Warn++
    }

    # --- 6. marcador de versão ------------------------------------------------------------
    if (-not $Check -and -not $DryRun -and $Version) {
        $marker = Join-Path (Join-Path $UserHome '.claude') '.native-sdd-claudex-version'
        try {
            Set-Content -LiteralPath $marker -Value (Get-ClaudexVersionMarkerContent -Version $Version) -NoNewline
            Write-Step OK "claudex: marcador de versão atualizado (v$Version)"
        }
        catch { Write-Step WARN "claudex: não foi possível gravar o marcador de versão — $($_.Exception.Message)"; $Summary.Warn++ }
    }

    Write-Step INFO 'claudex: pronto — reabra o terminal e rode `claudex -List` / `claudex -Check`'
    Write-Step INFO 'claudex: para adicionar um modelo novo, rode `/claudex-add-model` numa sessão do Claude Code'
}

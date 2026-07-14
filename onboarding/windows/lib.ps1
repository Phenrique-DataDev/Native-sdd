# lib.ps1 — funções puras/reutilizáveis do instalador (Windows).
# Apenas DEFINE funções (sem efeitos colaterais ao carregar) — testável com Pester.
# Compatível com Windows PowerShell 5.1+ e PowerShell 7+ (sem ternário/3-arg Join-Path).

Set-StrictMode -Version Latest

# --- Detecção de SO (compatível 5.1) -------------------------------------
# PowerShell <= 5.x é exclusivo do Windows e não define $IsWindows/$IsLinux/$IsMacOS;
# o short-circuit '-or' evita avaliá-las sob StrictMode no 5.1. Retorna 'Windows'|'Linux'|'macOS'.
function Get-OnboardingOS {
    if (($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows) { return 'Windows' }
    if ($IsMacOS) { return 'macOS' }
    if ($IsLinux) { return 'Linux' }
    return 'Unknown'
}

# Home do usuário, agnóstico de SO. No Windows usamos $env:USERPROFILE (respeita perfis
# redirecionados); no resto, o $HOME que o pwsh já resolve. Parametrizável p/ testes.
function Get-UserHome {
    param([string]$OS = (Get-OnboardingOS))
    if ($OS -eq 'Windows') { return $env:USERPROFILE }
    return $HOME
}

# --- Logging padronizado --------------------------------------------------
function Write-Step {
    [CmdletBinding()]
    param(
        [ValidateSet('OK', 'SKIP', 'RUN', 'INSTALL', 'BACKUP', 'FAIL', 'WARN', 'INFO', 'DRY')]
        [string]$Status,
        [string]$Message
    )
    $color = switch ($Status) {
        'OK'      { 'Green' }
        'SKIP'    { 'DarkGray' }
        'RUN'     { 'Cyan' }
        'INSTALL' { 'Cyan' }
        'BACKUP'  { 'Yellow' }
        'FAIL'    { 'Red' }
        'WARN'    { 'Yellow' }
        'DRY'     { 'Magenta' }
        default   { 'Gray' }
    }
    Write-Host ("[{0,-7}] " -f $Status) -ForegroundColor $color -NoNewline
    Write-Host $Message
}

# --- Formatação de duração ------------------------------------------------
function Format-Duration {
    # Cultura invariante: usa '.' como separador em qualquer locale (logs consistentes).
    param([Parameter(Mandatory)][TimeSpan]$Span)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Span.TotalMinutes -ge 1) {
        return ([string]::Format($inv, '{0}m{1:00}s', [int][math]::Floor($Span.TotalMinutes), $Span.Seconds))
    }
    return ([string]::Format($inv, '{0:0.0}s', $Span.TotalSeconds))
}

# --- Sumário de execução --------------------------------------------------
function New-InstallSummary {
    # Hashtable é tipo-referência: passado adiante e mutado pelos passos.
    return @{ Installed = 0; Skipped = 0; Backup = 0; Failed = 0; Warn = 0; Failures = @() }
}

# --- Checagens ------------------------------------------------------------
function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-WingetInstalled {
    param([Parameter(Mandatory)][string]$Id)
    if (-not (Test-CommandExists 'winget')) { return $false }
    $out = winget list --id $Id -e --accept-source-agreements 2>$null | Out-String
    return ($LASTEXITCODE -eq 0 -and $out -match [regex]::Escape($Id))
}

# --- Recarrega o PATH da sessão (Machine + User) -------------------------
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

# --- Backup ---------------------------------------------------------------
function Backup-File {
    # Faz backup de $Path se existir. Retorna o caminho do backup, ou $null.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = "$Path.bak-$stamp"
    Copy-Item -LiteralPath $Path -Destination $bak -Force -ErrorAction Stop
    return $bak
}

# --- Descoberta dinâmica do baseline -------------------------------------
function Get-BaselineMap {
    # Espelha SourceRoot → DestRoot. Exclui qualquer README.md.
    # Retorna objetos { Src; Dst; Rel }.
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestRoot
    )
    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) { return @() }
    $root = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\', '/')
    Get-ChildItem -LiteralPath $root -Recurse -File |
        Where-Object { $_.Name -ne 'README.md' } |
        ForEach-Object {
            $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
            [pscustomobject]@{
                Src = $_.FullName
                Dst = (Join-Path $DestRoot $rel)
                Rel = $rel
            }
        }
}

# --- Comparação de conteúdo ----------------------------------------------
function Test-FilesDiffer {
    param([string]$A, [string]$B)
    if (-not (Test-Path -LiteralPath $B -PathType Leaf)) { return $true }
    $ha = (Get-FileHash -LiteralPath $A -Algorithm SHA256).Hash
    $hb = (Get-FileHash -LiteralPath $B -Algorithm SHA256).Hash
    return ($ha -ne $hb)
}

# --- Merge profundo de JSON (overlay vence; objetos recursam; arrays substituem) --
function Merge-JsonObject {
    param($Base, $Overlay)
    $result = [ordered]@{}
    if ($Base -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Base.PSObject.Properties) { $result[$p.Name] = $p.Value }
    }
    if ($Overlay -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Overlay.PSObject.Properties) {
            $oval = $p.Value
            if ($result.Contains($p.Name) -and
                ($result[$p.Name] -is [System.Management.Automation.PSCustomObject]) -and
                ($oval -is [System.Management.Automation.PSCustomObject])) {
                $result[$p.Name] = Merge-JsonObject $result[$p.Name] $oval
            }
            else { $result[$p.Name] = $oval }
        }
    }
    return [pscustomobject]$result
}

# --- Substitui placeholders nos templates de baseline --------------------
function Expand-BaselinePlaceholder {
    # {{HOME}} → caminho absoluto do perfil, com '\' escapado p/ embutir em JSON.
    # -HomePath default = USERPROFILE (retrocompat Windows); em Linux/macOS passe $HOME (sem '\',
    # logo o escape é inócuo). Mantém a função pura/testável.
    param(
        [string]$Text,
        [string]$HomePath = $env:USERPROFILE
    )
    $homeEsc = ($HomePath -replace '\\', '\\')
    return ($Text -replace '\{\{HOME\}\}', $homeEsc)
}

# --- Normaliza command de hook para o runtime nativo (Windows) -----------
# A dispatch-line portável (J4) `sh -c '… pwsh -File "$1" … bash "$2" …' _ "<ps1>" "<sh>"`
# depende de `sh` no PATH do Windows — que a instalação padrão do Git NÃO garante (só `usr\bin`
# tem o sh.exe, e ele costuma ficar fora do PATH). Como o onboarding roda no Windows e SEMPRE
# deixa `pwsh` instalado, aqui reescrevemos o command para a forma NATIVA `pwsh -File "<ps1>"`
# (zero dependência de `sh`, zero regressão). A dispatch-line fica no template só p/ quem consome
# sem passar por este instalador (ex.: sandbox Linux sem pwsh). Pura/testável.
function ConvertTo-NativeHookCommand {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $Command }
    if ($Command -match '^\s*sh\s+-c\b.*\s_\s+"([^"]+\.ps1)"\s+"[^"]+\.sh"\s*$') {
        return "pwsh -NoProfile -File `"$($Matches[1])`""
    }
    return $Command
}

# Aplica ConvertTo-NativeHookCommand a todo hooks.<Event>[].hooks[].command do objeto settings.
# Sem efeito em settings sem hooks (retorna o objeto como veio). Muta e devolve o mesmo objeto.
function ConvertTo-NativeHooks {
    param($Settings)
    if ($Settings -isnot [System.Management.Automation.PSCustomObject]) { return $Settings }
    $hooksProp = $Settings.PSObject.Properties['hooks']
    if (-not $hooksProp -or $hooksProp.Value -isnot [System.Management.Automation.PSCustomObject]) { return $Settings }
    foreach ($evt in $hooksProp.Value.PSObject.Properties) {
        if ($evt.Value -isnot [array]) { continue }
        foreach ($entry in $evt.Value) {
            if ($entry -isnot [System.Management.Automation.PSCustomObject]) { continue }
            $inner = $entry.PSObject.Properties['hooks']
            if (-not $inner -or $inner.Value -isnot [array]) { continue }
            foreach ($h in $inner.Value) {
                $cmd = $h.PSObject.Properties['command']
                if ($cmd) { $cmd.Value = ConvertTo-NativeHookCommand $cmd.Value }
            }
        }
    }
    return $Settings
}

# statusLine.command usa a MESMA dispatch-line portável (sh -c '… pwsh || bash …' _ "<ps1>" "<sh>").
# No Windows, onde `sh` não é garantido no PATH, reescrevemos p/ a forma nativa `pwsh -File "<ps1>"`
# (idêntico ao tratamento dos hooks — J4). Em Linux/macOS o template portável fica intacto. Pura.
function ConvertTo-NativeStatusLine {
    param($Settings)
    if ($Settings -isnot [System.Management.Automation.PSCustomObject]) { return $Settings }
    $slProp = $Settings.PSObject.Properties['statusLine']
    if (-not $slProp -or $slProp.Value -isnot [System.Management.Automation.PSCustomObject]) { return $Settings }
    $cmd = $slProp.Value.PSObject.Properties['command']
    if ($cmd) { $cmd.Value = ConvertTo-NativeHookCommand $cmd.Value }
    return $Settings
}

# --- Instalação de um baseline .json (MERGE no destino; cria se faltar) ---
function Install-JsonBaselineItem {
    param(
        [Parameter(Mandatory)][pscustomobject]$Item,
        [Parameter(Mandatory)][hashtable]$Summary,
        [string]$HomePath = $env:USERPROFILE,
        [bool]$NativeHooks = $true,
        [switch]$Check,
        [switch]$DryRun
    )
    try {
        $destExists = Test-Path -LiteralPath $Item.Dst -PathType Leaf
        $baseObj = if ($destExists) { (Get-Content -LiteralPath $Item.Dst -Raw) | ConvertFrom-Json } else { [pscustomobject]@{} }
        $overObj = (Expand-BaselinePlaceholder (Get-Content -LiteralPath $Item.Src -Raw) -HomePath $HomePath) | ConvertFrom-Json
        $merged  = Merge-JsonObject $baseObj $overObj
        # Reescreve hooks + statusLine p/ runtime nativo (pwsh) — só no Windows (J4), onde `sh` não
        # é garantido. Em Linux/macOS mantemos a dispatch-line portável (sh -c '… pwsh || bash …').
        if ($NativeHooks) { $merged = ConvertTo-NativeHooks $merged; $merged = ConvertTo-NativeStatusLine $merged }
        $newJson = ($merged | ConvertTo-Json -Depth 20)
        $current = if ($destExists) { (Get-Content -LiteralPath $Item.Dst -Raw) } else { '' }
        if ($destExists -and $newJson.Trim() -eq $current.Trim()) {
            Write-Step SKIP "baseline: $($Item.Rel) (json idêntico)"
            $Summary.Skipped++
            return
        }
        $verb = if ($destExists) { 'merge json' } else { 'cria json' }
        if ($Check)  { Write-Step INFO "baseline: $($Item.Rel) ($verb)"; return }
        if ($DryRun) { Write-Step DRY  "$verb`: $($Item.Rel)"; return }
        $bak = Backup-File -Path $Item.Dst
        if ($bak) { Write-Step BACKUP (Split-Path -Leaf $bak); $Summary.Backup++ }
        # Garante o diretório-pai (igual a Install-BaselineItem/Install-ProfileShim): num projeto
        # novo o settings.json é o 1º item a tocar .claude/, que ainda não existe — sem isto o
        # WriteAllText falha e o hook curation-nudge (J3) não é registrado.
        $destDir = Split-Path -Parent $Item.Dst
        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        # UTF-8 SEM BOM: no Windows PowerShell 5.1 'Set-Content -Encoding UTF8' grava BOM,
        # que quebra parsers JSON estritos (Node/Claude Code). WriteAllText garante no-BOM.
        [System.IO.File]::WriteAllText($Item.Dst, $newJson, [System.Text.UTF8Encoding]::new($false))
        Write-Step OK "baseline: $($Item.Rel) (merge json)"
        $Summary.Installed++
    }
    catch {
        Write-Step FAIL "baseline json: $($Item.Rel) — $($_.Exception.Message)"
        $Summary.Failed++
        $Summary.Failures += "json:$($Item.Rel)"
    }
}

# --- Instalação de um item do baseline (backup + cópia, idempotente) -----
function Install-BaselineItem {
    param(
        [Parameter(Mandatory)][pscustomobject]$Item,
        [Parameter(Mandatory)][hashtable]$Summary,
        [string]$HomePath = $env:USERPROFILE,
        [bool]$NativeHooks = $true,
        [switch]$Check,
        [switch]$DryRun
    )
    # .json → sempre via instalador JSON: expande {{HOME}}, reescreve hooks p/ nativo (J4, só Windows)
    # e, se o destino existir, faz MERGE (preserva a config do usuário); senão, cria.
    if (([System.IO.Path]::GetExtension($Item.Dst)) -ieq '.json') {
        Install-JsonBaselineItem -Item $Item -Summary $Summary -HomePath $HomePath -NativeHooks $NativeHooks -Check:$Check -DryRun:$DryRun
        return
    }
    $exists = Test-Path -LiteralPath $Item.Dst -PathType Leaf
    $differs = Test-FilesDiffer -A $Item.Src -B $Item.Dst

    if ($exists -and -not $differs) {
        Write-Step SKIP "baseline: $($Item.Rel) (idêntico)"
        $Summary.Skipped++
        return
    }
    if ($Check) {
        $state = if ($exists) { 'difere' } else { 'faltando' }
        Write-Step INFO "baseline: $($Item.Rel) ($state)"
        return
    }
    if ($DryRun) {
        if ($exists) { Write-Step DRY "backup + escreve: $($Item.Rel)" }
        else         { Write-Step DRY "escreve: $($Item.Rel)" }
        return
    }
    try {
        $destDir = Split-Path -Parent $Item.Dst
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        if ($exists) {
            $bak = Backup-File -Path $Item.Dst
            if ($bak) { Write-Step BACKUP (Split-Path -Leaf $bak); $Summary.Backup++ }
        }
        Copy-Item -LiteralPath $Item.Src -Destination $Item.Dst -Force -ErrorAction Stop
        Write-Step OK "baseline: $($Item.Rel)"
        $Summary.Installed++
    }
    catch {
        Write-Step FAIL "baseline: $($Item.Rel) — $($_.Exception.Message)"
        $Summary.Failed++
        $Summary.Failures += "baseline:$($Item.Rel)"
    }
}

# --- Instalação de um pacote winget (idempotente, com timing + verificação) --
function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Summary,
        [string]$Cmd,            # comando-CLI p/ detectar instalações fora do winget
        [switch]$Check,
        [switch]$DryRun
    )
    # Idempotência robusta: comando no PATH OU pacote conhecido pelo winget.
    if (($Cmd -and (Test-CommandExists $Cmd)) -or (Test-WingetInstalled -Id $Id)) {
        Write-Step SKIP "$Name já instalado"
        $Summary.Skipped++
        return
    }
    if ($Check)  { Write-Step INFO "$Name ($Id) faltando"; return }
    if ($DryRun) { Write-Step DRY  "winget install $Id"; return }

    Write-Step RUN "Instalando $Name ..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        # Tenta escopo de usuário (evita UAC); se não aplicável, tenta escopo padrão.
        winget install -e --id $Id --scope user --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            winget install -e --id $Id --silent --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { throw "winget exit $LASTEXITCODE" }
        }
        $sw.Stop()
        # Verificação pós-install: recarrega PATH e confirma que o comando resolve.
        Update-SessionPath
        $ok = (-not $Cmd) -or (Test-CommandExists $Cmd) -or (Test-WingetInstalled -Id $Id)
        if ($ok) {
            Write-Step OK "$Name ($(Format-Duration $sw.Elapsed))"
        }
        else {
            Write-Step WARN "$Name instalado, mas '$Cmd' não resolveu — reabra o terminal ($(Format-Duration $sw.Elapsed))"
            $Summary.Warn++
        }
        $Summary.Installed++
    }
    catch {
        $sw.Stop()
        Write-Step FAIL "$Name ($Id) — $($_.Exception.Message)"
        $Summary.Failed++
        $Summary.Failures += "winget:$Id"
    }
}

# --- Shim de conveniência no $PROFILE (New-SddProject/nsp + Invoke-SddCheck/sddcheck) --
# Marcadores delimitam um bloco gerado: pode ser regerado (regex) sem tocar no
# resto do profile do usuário.
$script:ShimMarkerStart = '# >>> sdd-workflow >>>'
$script:ShimMarkerEnd   = '# <<< sdd-workflow <<<'

function Get-ProfileShimBlock {
    # Texto do bloco a injetar no $PROFILE. Resolve o caminho do framework via
    # $env:SDD_WORKFLOW_HOME para que as funções funcionem mesmo se o clone mudar de lugar
    # (basta reinstalar): New-SddProject/nsp (cria projeto) e Invoke-SddCheck/sddcheck
    # (roda tools/check.ps1 de qualquer pasta). Aspas simples no caminho são escapadas ('' ).
    param([Parameter(Mandatory)][string]$RepoRoot)
    $rootEsc = $RepoRoot -replace "'", "''"
    @(
        $script:ShimMarkerStart
        '# Gerado por onboarding/install.ps1 — não edite à mão (regenerado a cada install).'
        "`$env:SDD_WORKFLOW_HOME = '$rootEsc'"
        'function New-SddProject { & (Join-Path $env:SDD_WORKFLOW_HOME ''onboarding\new-project.ps1'') @args }'
        'Set-Alias -Name nsp -Value New-SddProject'
        'function Invoke-SddCheck { & (Join-Path $env:SDD_WORKFLOW_HOME ''tools\check.ps1'') @args }'
        'Set-Alias -Name sddcheck -Value Invoke-SddCheck'
        $script:ShimMarkerEnd
    ) -join "`r`n"
}

function Install-ProfileShim {
    # Injeta/atualiza o bloco do shim no $PROFILE de forma idempotente.
    # - bloco ausente  → anexa (criando o profile/diretório se preciso)
    # - bloco presente e idêntico → SKIP
    # - bloco presente e diferente (ex.: novo RepoRoot) → backup + substitui
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$Summary,
        [switch]$Check,
        [switch]$DryRun
    )
    $block   = Get-ProfileShimBlock -RepoRoot $RepoRoot
    $exists  = Test-Path -LiteralPath $ProfilePath -PathType Leaf
    $current = if ($exists) { Get-Content -LiteralPath $ProfilePath -Raw } else { '' }

    $pattern  = '(?s)' + [regex]::Escape($script:ShimMarkerStart) + '.*?' + [regex]::Escape($script:ShimMarkerEnd)
    $hasBlock = [regex]::IsMatch($current, $pattern)

    # Calcula o conteúdo-alvo do profile (substitui o bloco ou anexa ao fim).
    if ($hasBlock) {
        # MatchEvaluator (scriptblock) evita interpretação de '$' do replacement como
        # backreference; o argumento do match é ignorado (substituição fixa pelo bloco).
        $target = [regex]::Replace($current, $pattern, { $block }.GetNewClosure())
    }
    else {
        $sep    = if (-not $exists -or [string]::IsNullOrEmpty($current)) { '' }
                  elseif ($current.EndsWith("`n")) { '' } else { "`r`n" }
        $target = $current + $sep + $block + "`r`n"
    }

    if ($exists -and ($target.Trim() -eq $current.Trim())) {
        Write-Step SKIP 'shim do profile (New-SddProject) já atualizado'
        $Summary.Skipped++
        return
    }
    if ($Check)  { Write-Step INFO ("shim do profile ({0})" -f $(if ($hasBlock) { 'difere' } else { 'faltando' })); return }
    if ($DryRun) { Write-Step DRY  "escreve shim do profile: $ProfilePath"; return }

    try {
        $dir = Split-Path -Parent $ProfilePath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        if ($exists) {
            $bak = Backup-File -Path $ProfilePath
            if ($bak) { Write-Step BACKUP (Split-Path -Leaf $bak); $Summary.Backup++ }
        }
        # UTF-8 sem BOM (consistente com Install-JsonBaselineItem).
        [System.IO.File]::WriteAllText($ProfilePath, $target, [System.Text.UTF8Encoding]::new($false))
        Write-Step OK 'shim do profile (New-SddProject / nsp)'
        $Summary.Installed++
    }
    catch {
        Write-Step FAIL "shim do profile — $($_.Exception.Message)"
        $Summary.Failed++
        $Summary.Failures += 'profile:shim'
    }
}

# --- Shim de conveniência para shells POSIX (bash/zsh) -------------------
# Equivalente Linux/macOS do shim do $PROFILE: define nsp/sddcheck no rc do shell, chamando
# pwsh (runtime do framework em todo SO). Reusa os mesmos marcadores do bloco gerado.
function Get-BashShimBlock {
    # Texto do bloco a injetar em ~/.bashrc / ~/.zshrc. RepoRoot é normalizado p/ POSIX e as
    # aspas simples são escapadas ('\'' ) p/ embutir com segurança. Linhas separadas por LF.
    param([Parameter(Mandatory)][string]$RepoRoot)
    $root    = $RepoRoot -replace '\\', '/'
    $rootEsc = $root -replace "'", "'\''"
    @(
        $script:ShimMarkerStart
        '# Gerado por onboarding/install.sh — não edite à mão (regenerado a cada install).'
        "export SDD_WORKFLOW_HOME='$rootEsc'"
        'nsp() { pwsh -NoProfile -File "$SDD_WORKFLOW_HOME/onboarding/new-project.ps1" "$@"; }'
        'sddcheck() { pwsh -NoProfile -File "$SDD_WORKFLOW_HOME/tools/check.ps1" "$@"; }'
        $script:ShimMarkerEnd
    ) -join "`n"
}

# Variante fish: sintaxe própria (function … end, set -gx, $argv) p/ ~/.config/fish/config.fish.
function Get-FishShimBlock {
    # Mesmos marcadores ('#' também comenta em fish). LF. Aspas simples no caminho escapam com \'.
    param([Parameter(Mandatory)][string]$RepoRoot)
    $root    = $RepoRoot -replace '\\', '/'
    $rootEsc = $root -replace "'", "\'"
    @(
        $script:ShimMarkerStart
        '# Gerado por onboarding/install.sh — não edite à mão (regenerado a cada install).'
        "set -gx SDD_WORKFLOW_HOME '$rootEsc'"
        'function nsp; pwsh -NoProfile -File "$SDD_WORKFLOW_HOME/onboarding/new-project.ps1" $argv; end'
        'function sddcheck; pwsh -NoProfile -File "$SDD_WORKFLOW_HOME/tools/check.ps1" $argv; end'
        $script:ShimMarkerEnd
    ) -join "`n"
}

function Install-BashShim {
    # Injeta/atualiza o bloco do shim num rc de shell POSIX, idempotente (igual a Install-ProfileShim,
    # porém com LF). Chame uma vez por arquivo (~/.bashrc, ~/.zshrc, config.fish). -Block permite
    # passar um bloco específico (ex.: fish); vazio = usa o bloco bash/zsh padrão.
    param(
        [Parameter(Mandatory)][string]$RcPath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$Summary,
        [string]$Block = '',
        [switch]$Check,
        [switch]$DryRun
    )
    if (-not $Block) { $Block = Get-BashShimBlock -RepoRoot $RepoRoot }
    $block   = $Block
    $exists  = Test-Path -LiteralPath $RcPath -PathType Leaf
    $current = if ($exists) { Get-Content -LiteralPath $RcPath -Raw } else { '' }
    $rcName  = Split-Path -Leaf $RcPath

    $pattern  = '(?s)' + [regex]::Escape($script:ShimMarkerStart) + '.*?' + [regex]::Escape($script:ShimMarkerEnd)
    $hasBlock = [regex]::IsMatch($current, $pattern)

    if ($hasBlock) {
        $target = [regex]::Replace($current, $pattern, { $block }.GetNewClosure())
    }
    else {
        $sep    = if (-not $exists -or [string]::IsNullOrEmpty($current)) { '' }
                  elseif ($current.EndsWith("`n")) { '' } else { "`n" }
        $target = $current + $sep + $block + "`n"
    }

    if ($exists -and ($target.Trim() -eq $current.Trim())) {
        Write-Step SKIP "shim $rcName (nsp/sddcheck) já atualizado"
        $Summary.Skipped++
        return
    }
    if ($Check)  { Write-Step INFO ("shim $rcName ({0})" -f $(if ($hasBlock) { 'difere' } else { 'faltando' })); return }
    if ($DryRun) { Write-Step DRY  "escreve shim: $RcPath"; return }

    try {
        $dir = Split-Path -Parent $RcPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        if ($exists) {
            $bak = Backup-File -Path $RcPath
            if ($bak) { Write-Step BACKUP (Split-Path -Leaf $bak); $Summary.Backup++ }
        }
        # UTF-8 sem BOM e LF (rc de shell não deve ter BOM nem CRLF).
        [System.IO.File]::WriteAllText($RcPath, $target, [System.Text.UTF8Encoding]::new($false))
        Write-Step OK "shim $rcName (nsp / sddcheck)"
        $Summary.Installed++
    }
    catch {
        Write-Step FAIL "shim $rcName — $($_.Exception.Message)"
        $Summary.Failed++
        $Summary.Failures += "shim:$rcName"
    }
}

# --- Managed policy (opt-in interativo, exige admin) ---------------------
# Política de governança inviolável (topo da hierarquia de loading). Vive num caminho de
# SISTEMA — escrever exige elevação. NÃO é aplicada à força: o onboarding pergunta e só
# então copia (direto se já elevado; senão relança só este passo via UAC).
function Test-IsAdmin {
    # True se a sessão atual está elevada (Administrador). Apenas Windows; fora dele, $false.
    if (-not ((($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows))) { return $false }
    $id  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = [System.Security.Principal.WindowsPrincipal]::new($id)
    return $pri.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Copy-ManagedPolicyFile {
    # Copia managed-settings.json -> destino (cria dir, backup se existir). Operação de
    # arquivo pura — sem prompt/elevação. Retorna $true em sucesso; atualiza $Summary em falha.
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath,
        [Parameter(Mandatory)][hashtable]$Summary
    )
    try {
        $destDir = Split-Path -Parent $DestPath
        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $DestPath -PathType Leaf) {
            $bak = Backup-File -Path $DestPath
            if ($bak) { Write-Step BACKUP (Split-Path -Leaf $bak); $Summary.Backup++ }
        }
        Copy-Item -LiteralPath $SourcePath -Destination $DestPath -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-Step FAIL "managed policy — $($_.Exception.Message)"
        $Summary.Failed++
        $Summary.Failures += 'managed-policy'
        return $false
    }
}

function Invoke-ElevatedManagedPolicyCopy {
    # Relança um PowerShell elevado (UAC) só para copiar o managed-settings.json ao caminho de
    # sistema. Retorna $true se o destino existir após a operação. Cancelar o UAC -> $false.
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath
    )
    $destDir = Split-Path -Parent $DestPath
    # Aspas simples escapadas ('') para embutir caminhos como literais seguros no -Command.
    $srcEsc = $SourcePath -replace "'", "''"
    $dstEsc = $DestPath   -replace "'", "''"
    $dirEsc = $destDir    -replace "'", "''"
    $inner  = "New-Item -ItemType Directory -Force -Path '$dirEsc' | Out-Null; " +
              "Copy-Item -LiteralPath '$srcEsc' -Destination '$dstEsc' -Force"
    $exe = (Get-Process -Id $PID).Path   # pwsh.exe ou powershell.exe da sessão atual
    try {
        $p = Start-Process -FilePath $exe `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $inner) `
            -Verb RunAs -Wait -PassThru -ErrorAction Stop
        return ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $DestPath -PathType Leaf))
    }
    catch {
        # UAC cancelado lança exceção -> tratado como recusa.
        return $false
    }
}

# --- Elevação POSIX (Linux/macOS) p/ a managed policy --------------------
function Test-IsRoot {
    # True se a sessão POSIX é root (EUID 0). Em Windows, sempre $false.
    if ((($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows)) { return $false }
    try { return ((& id -u) -eq '0') } catch { return $false }
}

function Invoke-SudoManagedPolicyCopy {
    # Copia o managed-settings.json p/ um caminho de sistema POSIX via sudo (cria dir, modo 644).
    # Retorna $true se o destino existir após a operação. Sem sudo no PATH -> $false.
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath
    )
    if (-not (Test-CommandExists 'sudo')) { return $false }
    $destDir = Split-Path -Parent $DestPath
    try {
        & sudo install -d -m 755 $destDir
        if ($LASTEXITCODE -ne 0) { return $false }
        & sudo install -m 644 $SourcePath $DestPath
        return ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $DestPath -PathType Leaf))
    }
    catch { return $false }
}

function Install-ManagedPolicy {
    # Aplica (opt-in) a managed policy num caminho de sistema. Por padrão PERGUNTA ao usuário;
    # escrever exige elevação — no Windows relança via UAC, em Linux/macOS copia via sudo.
    # -Decision Ask|Yes|No controla o prompt (Yes/No injetáveis em testes/automação).
    # -IsAdmin é resolvido por SO quando não informado (Test-IsAdmin/Test-IsRoot; injetável em testes).
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][hashtable]$Summary,
        [string]$DestDir = 'C:\Program Files\ClaudeCode',
        [ValidateSet('Ask', 'Yes', 'No')][string]$Decision = 'Ask',
        [string]$OS = (Get-OnboardingOS),
        [switch]$Check,
        [switch]$DryRun,
        [switch]$IsAdmin
    )
    if (-not $PSBoundParameters.ContainsKey('IsAdmin')) {
        $IsAdmin = if ($OS -eq 'Windows') { [bool](Test-IsAdmin) } else { [bool](Test-IsRoot) }
    }

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        Write-Step WARN "managed policy: template não encontrado ($SourcePath)"
        $Summary.Warn++
        return
    }

    $destPath = Join-Path $DestDir 'managed-settings.json'
    $exists   = Test-Path -LiteralPath $destPath -PathType Leaf

    # Já aplicada e idêntica -> nada a fazer (não pergunta).
    if ($exists -and -not (Test-FilesDiffer -A $SourcePath -B $destPath)) {
        Write-Step SKIP 'managed policy já aplicada (idêntica)'
        $Summary.Skipped++
        return
    }
    if ($Check) {
        $state = if ($exists) { 'difere' } else { 'não aplicada' }
        Write-Step INFO "managed policy ($state)"
        return
    }
    if ($DryRun) {
        Write-Step DRY "aplicaria managed policy em $destPath"
        return
    }

    # --- decisão do usuário (interativa por padrão) ---
    $accept = switch ($Decision) {
        'Yes' { $true }
        'No' { $false }
        default {
            if (-not [Environment]::UserInteractive) {
                Write-Step SKIP 'managed policy: sessão não interativa — pulada (opt-in)'
                $Summary.Skipped++
                return
            }
            Write-Host ''
            Write-Host '  Aplicar managed policy? ' -NoNewline
            Write-Host '(exige admin) ' -ForegroundColor DarkGray -NoNewline
            Write-Host '(altamente recomendado)' -ForegroundColor Green
            ((Read-Host '  [s/N]') -match '^\s*(s|sim|y|yes)\s*$')
        }
    }
    if (-not $accept) {
        Write-Step SKIP 'managed policy não aplicada (opt-in recusado)'
        $Summary.Skipped++
        return
    }

    # --- aplicação (exige admin) ---
    if ($IsAdmin) {
        if (Copy-ManagedPolicyFile -SourcePath $SourcePath -DestPath $destPath -Summary $Summary) {
            Write-Step OK 'managed policy aplicada (reinicie o Claude Code)'
            $Summary.Installed++
        }
        return
    }

    if ($OS -eq 'Windows') {
        Write-Step INFO 'managed policy exige admin — solicitando elevação (UAC)...'
        $elevated = Invoke-ElevatedManagedPolicyCopy -SourcePath $SourcePath -DestPath $destPath
    }
    else {
        Write-Step INFO 'managed policy exige root — copiando via sudo...'
        $elevated = Invoke-SudoManagedPolicyCopy -SourcePath $SourcePath -DestPath $destPath
    }
    if ($elevated) {
        Write-Step OK 'managed policy aplicada via elevação (reinicie o Claude Code)'
        $Summary.Installed++
    }
    else {
        Write-Step WARN 'managed policy não aplicada (elevação cancelada ou falhou)'
        $Summary.Warn++
    }
}

# --- Conteúdo do marcador de versão do scaffold (.claude/.scaffold-version) --
function Get-ScaffoldVersionContent {
    # Metadado gravado no projeto gerado: identifica qual framework/commit o produziu,
    # habilitando `new-project.ps1 -Update`. Recebe commit e versão já resolvidos
    # (mantém a função pura/testável, sem chamar git nem ler o VERSION do disco).
    #
    # POR QUE template_version (2026-07-13): o marcador nasceu (A6) só com framework_commit — um SHA
    # curto que NÃO serve de baseline comparável. Ele vira 'unknown' quando o framework foi baixado
    # como zip (sem git), e o espelho publicado (Native-sdd) tem histórico git PRÓPRIO, então o SHA
    # de lá não existe aqui. Resultado: dava para dizer "veio de a1b2c3d" e não dar para responder
    # "está quantas versões atrás?". A versão semântica (VERSION) é a mesma nos dois repositórios e
    # sobrevive ao zip. Os dois campos convivem: commit para rastrear, versão para comparar.
    #
    # -Version é MANDATORY de propósito: um default silencioso ('unknown') faria o chamador que o
    # esquece gravar um marcador ERRADO sem nenhum erro — a mesma armadilha que produziu o nudge
    # eterno do /sync-context (Build-AgentMap -Connections, opcional, default @{}; v0.8.15). Quem não
    # tem a versão passa 'unknown' EXPLICITAMENTE — e Get-FrameworkVersion já garante sempre um valor.
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Version,
        [string]$Commit = 'unknown',
        [string]$Stamp
    )
    if (-not $Stamp) {
        $Stamp = (Get-Date).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $rootEsc = $RepoRoot -replace '\\', '/'
    @(
        '# Scaffold version — gerado por onboarding/new-project.ps1'
        '# Identifica o framework que gerou este projeto (para upgrades futuros).'
        "generated_at: $Stamp"
        "template_version: $Version"
        "framework_commit: $Commit"
        "framework_root: $rootEsc"
    ) -join "`r`n"
}

function Get-FrameworkVersion {
    # FONTE ÚNICA da leitura do arquivo VERSION do framework. Devolve a versão semântica
    # (ex.: '0.8.17') ou 'unknown' se o arquivo não existir/estiver vazio — nunca lança:
    # não ter VERSION não pode impedir a criação de um projeto.
    param([Parameter(Mandatory)][string]$RepoRoot)

    $file = Join-Path $RepoRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return 'unknown' }
    $raw = (Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($raw)) { return 'unknown' }
    return $raw.Trim()
}

function Read-ScaffoldVersion {
    # Lê o marcador .claude/.scaffold-version de um projeto já gerado e devolve os campos
    # (FrameworkCommit/TemplateVersion/GeneratedAt/FrameworkRoot). Pura/read-only. Retorna $null se o
    # marcador estiver ausente ou sem framework_commit (não é um projeto scaffolded reconhecível).
    #
    # RETROCOMPAT: template_version só passou a ser gravado em 2026-07-13 (v0.8.17). Projetos criados
    # ANTES não têm o campo — TemplateVersion vem 'unknown', e isso NÃO os desqualifica como projeto
    # scaffolded (o predicado de reconhecimento segue sendo framework_commit). Quem compara versões
    # precisa tratar 'unknown' como "não sei", nunca como "desatualizado".
    param([Parameter(Mandatory)][string]$Path)

    $file = Join-Path $Path '.claude\.scaffold-version'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }

    $commit = $null; $generated = $null; $root = $null; $version = $null
    foreach ($line in (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*framework_commit\s*:\s*(.+?)\s*$')    { $commit = $Matches[1].Trim() }
        elseif ($line -match '^\s*template_version\s*:\s*(.+?)\s*$') { $version = $Matches[1].Trim() }
        elseif ($line -match '^\s*generated_at\s*:\s*(.+?)\s*$')    { $generated = $Matches[1].Trim() }
        elseif ($line -match '^\s*framework_root\s*:\s*(.+?)\s*$')  { $root = $Matches[1].Trim() }
    }
    if (-not $commit) { return $null }

    return [pscustomobject]@{
        FrameworkCommit = $commit
        TemplateVersion = if ($version) { $version } else { 'unknown' }
        GeneratedAt     = $generated
        FrameworkRoot   = $root
    }
}

function Test-SameNameNesting {
    # PURA. Detecta o pé-na-jaca de copiar/colar o comando: estar DENTRO de 'meu-projeto\' e rodar
    # `nsp meu-projeto` — o -Path é relativo ao cwd, então o destino vira 'meu-projeto\meu-projeto'
    # (projeto ANINHADO: a raiz não é a pasta que o usuário acha, e o Claude Code passa a carregar
    # dois CLAUDE.md/AGENTS.md). Verdadeiro só no caso inequívoco: -Path RELATIVO, um NOME simples
    # (sem separador), diferente de '.'/'..', e igual ao nome da pasta atual (case-insensitive no
    # Windows). Não toca o disco — quem chama decide o que fazer (e checa se o alvo já existe).
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$CurrentDir
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $false }

    $p = $Path.Trim().TrimEnd('\', '/')
    if ($p -in @('.', '..', '')) { return $false }
    if ($p.Contains('\') -or $p.Contains('/')) { return $false }   # 'sub/dir' é intenção explícita

    $leaf = Split-Path -Leaf ($CurrentDir.TrimEnd('\', '/'))
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $false }     # raiz de drive (C:\) não tem leaf

    return [string]::Equals($p, $leaf, [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-NestingChoice {
    # PURA. Mapeia a resposta do menu de aninhamento -> ação. Separada do Read-Host de propósito:
    # o I/O fica numa linha só no new-project.ps1 e a DECISÃO (inclusive o default seguro) é
    # testável. Qualquer coisa que não seja '1'/'2' (vazio, Enter, lixo, Ctrl-C→'') = 'cancel':
    # fail-closed — na dúvida não escreve nada.
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Choice)

    switch (([string]$Choice).Trim()) {
        '1'     { return 'use-current' }   # equipar a pasta atual (o que o usuário quase sempre quer)
        '2'     { return 'nested' }        # criar a subpasta de mesmo nome, ciente
        default { return 'cancel' }
    }
}

function Find-ScaffoldedAncestor {
    # Sobe a árvore a partir de -Dir (exclusive) procurando um projeto JÁ scaffolded
    # (.claude/.scaffold-version). Devolve o caminho do ancestral, ou $null. Read-only.
    # Usado para avisar que o destino cairia DENTRO de outro projeto (scaffold aninhado).
    param([Parameter(Mandatory)][string]$Dir)

    $cur = Split-Path -Parent $Dir.TrimEnd('\', '/')
    while ($cur -and (Test-Path -LiteralPath $cur -PathType Container)) {
        if (Read-ScaffoldVersion -Path $cur) { return $cur }
        $next = Split-Path -Parent $cur
        if ($next -eq $cur) { break }      # chegou na raiz do drive
        $cur = $next
    }
    return $null
}

# --- Manifest do scaffold (.claude/.scaffold-manifest) --------------------
# O QUE É: o SHA-256 de cada arquivo COMO ELE FICOU NO DESTINO no momento em que o projeto foi
# criado/atualizado. É a memória de "o que nós entregamos" — sem ela, um update não consegue
# distinguir "este arquivo mudou porque o TEMPLATE evoluiu" de "mudou porque o USUÁRIO editou",
# e a única saída segura seria sobrescrever tudo (perdendo customização) ou nada (upgrade morto).
#
# POR QUE O HASH DO DESTINO, E NÃO O DO TEMPLATE-FONTE: (1) os .json passam por MERGE na instalação,
# então o arquivo no destino NUNCA é byte-idêntico ao do template — hashear a fonte marcaria
# settings.json como "customizado" para sempre; (2) o hash do destino torna o projeto AUTO-CONTIDO:
# a classificação não precisa recuperar o template antigo, logo funciona sem git, sem tags e mesmo
# que a pasta do framework tenha sumido. Um projeto que veio de .zip atualiza igual.
function Test-BinaryContent {
    # Heurística padrão (a mesma do git): há um NUL byte nos primeiros 8k? Então é binário.
    # Só arquivo de TEXTO tem line-ending para normalizar — normalizar um .png o corromperia.
    #
    # AllowEmptyCollection: arquivo VAZIO (todo .gitkeep do scaffold é 0 byte) chega aqui como array
    # vazio, e um [byte[]] Mandatory o REJEITA no binding. Sem isto o manifest não era gravado — e
    # pior, em silêncio: o try/catch de cima engolia o erro e o resumo ainda dizia "Falhou: 0".
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $limite = [Math]::Min($Bytes.Length, 8000)
    for ($i = 0; $i -lt $limite; $i++) { if ($Bytes[$i] -eq 0) { return $true } }
    return $false
}

function Get-FileSha256 {
    # $null se o arquivo não existir — "ausente" é um estado normal aqui, não um erro.
    #
    # NORMALIZA CRLF -> LF em arquivos de TEXTO antes de hashear (v0.8.25). Sem isto o manifest é
    # frágil a algo que acontece em TODO projeto versionado: o new-project escreve CRLF (Windows) e
    # grava esse hash como baseline; o git então reescreve o arquivo no disco como LF (autocrlf/
    # .gitattributes). No update seguinte baseline != disco, e o classificador conclui "o usuário
    # editou" -> FALSO CONFLITO, num arquivo que ninguém tocou. Medido no IAIMG: 4 dos 14 conflitos
    # eram exatamente isto (3 .gitkeep + um template de skill), byte-a-byte idênticos ao template.
    #
    # -Raw devolve o hash do byte bruto (sem normalizar) — usado só para RECONHECER manifest antigo,
    # gravado antes desta mudança. Ver Get-ScaffoldUpgradePlan.
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Raw
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if (-not $Raw -and -not (Test-BinaryContent -Bytes $bytes)) {
        # CRLF -> LF direto nos BYTES: passar por UTF8.GetString/GetBytes destruiria qualquer byte
        # que não seja UTF-8 válido (viraria U+FFFD). Aqui só se remove o 0x0D que precede 0x0A —
        # um CR solto (Mac clássico) fica intacto, e nenhum outro byte é tocado.
        $saida = [System.Collections.Generic.List[byte]]::new($bytes.Length)
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 0x0D -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 0x0A) { continue }
            $saida.Add($bytes[$i])
        }
        $bytes = $saida.ToArray()
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-ScaffoldManifestContent {
    # Lê o disco do DESTINO (os caminhos absolutos já vêm em Map.Dst — daí não haver um -DestRoot:
    # seria decorativo). Formato `<sha256>  <rel>`, uma linha por arquivo, ordenado por Rel —
    # determinístico, diffável e sem dependência de parser de YAML/JSON.
    #
    # -Skip: os arquivos que NÃO foram escritos (preservados por serem customizados). Para eles, o
    # manifest MANTÉM a entrada anterior (-Previous) ou OMITE — jamais fotografa o disco.
    #
    # POR QUE (bug de PERDA DE DADOS achado ao validar no IAIMG, 2026-07-13): a primeira versão
    # hasheava TODO o destino, inclusive o customizado que acabara de preservar. Efeito: no update
    # seguinte, a customização do usuário estava gravada como "foi isto que entregamos" -> classe
    # 'intacto' -> SOBRESCRITA EM SILÊNCIO. O -Update era seguro na 1ª rodada e destrutivo na 2ª.
    # O e2e não pegou porque só rodava UM update. Regra: o manifest registra o que NÓS escrevemos,
    # nunca o que o usuário escreveu.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Map,
        [AllowNull()][hashtable]$Previous,
        [string[]]$Skip = @()
    )
    $skipSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Skip), [System.StringComparer]::OrdinalIgnoreCase)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Scaffold manifest — gerado por onboarding/new-project.ps1')
    $lines.Add('# SHA-256 de cada arquivo do template COMO ENTREGUE. Não edite: é o baseline que o')
    $lines.Add('# -Update usa para saber o que você customizou (e portanto NÃO deve sobrescrever).')
    foreach ($item in (@($Map) | Sort-Object Rel)) {
        if ($skipSet.Contains($item.Rel)) {
            # Preservado: mantém o baseline ANTIGO (se havia). Sem baseline anterior, fica FORA do
            # manifest — "não sei o que foi entregue aqui" segue sendo a verdade, e o arquivo
            # continua caindo em 'desconhecido' (preservado) até uma decisão humana.
            if ($Previous -and $Previous.ContainsKey($item.Rel)) {
                $lines.Add("$($Previous[$item.Rel])  $($item.Rel)")
            }
            continue
        }
        $hash = Get-FileSha256 -Path $item.Dst
        if ($hash) { $lines.Add("$hash  $($item.Rel)") }
    }
    # Newline final: sem ela, um append (Add-Content) cola a linha nova na última existente e
    # corrompe as duas em silêncio. Custa 2 bytes.
    return (($lines -join "`r`n") + "`r`n")
}

function Read-ScaffoldManifest {
    # Lê <Path>/.claude/.scaffold-manifest -> hashtable Rel -> Hash. Devolve $null (não @{}) se o
    # arquivo não existir: "não tenho manifest" é diferente de "manifest vazio", e quem classifica
    # PRECISA distinguir os dois — sem baseline, nada pode ser declarado intacto.
    param([Parameter(Mandatory)][string]$Path)

    $file = Join-Path $Path '.claude\.scaffold-manifest'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }

    $map = @{}
    foreach ($line in (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*([0-9A-Fa-f]{64})\s\s?(.+?)\s*$') { $map[$Matches[2]] = $Matches[1].ToUpperInvariant() }
    }
    return $map
}

function Test-ScaffoldedProject {
    # Reconhece um projeto scaffolded PELO CONTEÚDO, não pelo marcador. Read-only.
    #
    # POR QUE EXISTE (achado em uso real, 2026-07-13): o -Update exigia .claude/.scaffold-version e
    # RECUSAVA o IAIMG — o único projeto real do usuário — porque ele nasceu ANTES do marcador (A6).
    # O caminho de upgrade não funcionava no único lugar onde ele importava. Pior: a mensagem mandava
    # "rode sem -Update", e o modo CRIAÇÃO sobrescreve tudo que difere SEM classificar — ou seja, a
    # saída sugerida era a destrutiva.
    #
    # O predicado é o MESMO que o AGENTS.md já usa na "Guarda de escopo" para decidir se uma sessão
    # está dentro de um projeto scaffolded — de propósito: um só conceito de "isto é um projeto SDD",
    # não dois que podem divergir.
    param([Parameter(Mandatory)][string]$Path)

    foreach ($rel in @('.claude\rules\workflow-sdd.md', '.claude\rules\project-context.md')) {
        if (Test-Path -LiteralPath (Join-Path $Path $rel) -PathType Leaf) { return $true }
    }
    return $false
}

function Get-ScaffoldFileClass {
    # PURA — o coração do upgrade. Recebe só hashes e devolve a classe do arquivo. Sem disco, sem I/O:
    # toda a decisão de "posso sobrescrever isto?" mora aqui, e é exercível caso a caso no teste.
    #
    # BaselineHash = o que entregamos (manifest, $null se projeto legado/arquivo novo no template)
    # DiskHash     = o que está lá agora  ($null se o arquivo não existe no projeto)
    # TemplateHash = o que queremos entregar ($null se o arquivo saiu do template)
    #
    # NÃO HÁ CASO ESPECIAL PARA .json — e isso é deliberado. A v0.8.18 tinha uma classe 'merge' que
    # dava passe livre a todo .json, sob a premissa de que "o merge preserva a config do usuário por
    # construção". FALSO: Merge-JsonObject SUBSTITUI arrays. Ao validar no IAIMG, isso apagou 855
    # linhas do .claude/agents/graph.json (o grafo do projeto, todo feito de arrays) trocando-o pelo
    # do template. E a proteção era DESNECESSÁRIA: ela existia para o settings.json não ficar
    # "customizado para sempre" — o que só aconteceria se o manifest hasheasse a FONTE. Como ele
    # hasheia o DESTINO (pós-merge), o settings.json intacto bate com o baseline e cai em 'intacto'
    # naturalmente. A salvaguarda cobria um problema que o desenho já resolvia, e abriu um buraco.
    param(
        [AllowNull()][string]$BaselineHash,
        [AllowNull()][string]$DiskHash,
        [AllowNull()][string]$TemplateHash
    )
    # ── O template NÃO tem mais este arquivo (v0.8.23) ────────────────────────────────────────────
    # Sem isto, o upgrade só sabia ADICIONAR: uma rule que o framework removeu ficava no projeto
    # PARA SEMPRE, e o corte de always-on nunca chegava a quem já tinha projeto criado. O manifest é
    # o que torna a remoção segura — ele diz o que NÓS entregamos, e só isso é nosso para apagar.
    if (-not $TemplateHash) {
        if (-not $DiskHash)     { return 'ausente' }   # não existe em lugar nenhum: nada a fazer
        if (-not $BaselineHash) { return 'local' }     # nunca foi nosso -> é do usuário. NÃO TOCAR.
        # Entregamos e o usuário não mexeu -> podemos retirar com segurança.
        if ($DiskHash -eq $BaselineHash) { return 'removido' }
        # Entregamos, o template retirou, MAS o usuário editou. Apagar aqui é apagar trabalho:
        # preserva e reporta (fail-safe, mesma disciplina do 'conflito').
        return 'orfao'
    }

    # Ausente no projeto: é adição pura, não há o que preservar.
    if (-not $DiskHash) { return 'novo' }

    # Já é exatamente o que o template quer entregar — inclusive quando o usuário editou "para o
    # mesmo lugar". Nada a fazer.
    if ($DiskHash -eq $TemplateHash) { return 'em-dia' }

    # Sem baseline (projeto criado antes do manifest) E difere do template: NÃO DÁ PARA SABER se a
    # diferença é customização ou atraso de versão. Fail-safe: não toca, reporta. Nunca 'intacto' —
    # o custo de errar aqui é apagar trabalho do usuário em silêncio.
    if (-not $BaselineHash) { return 'desconhecido' }

    # Intacto desde a entrega: o usuário nunca mexeu -> fast-forward seguro.
    if ($DiskHash -eq $BaselineHash) { return 'intacto' }

    # Mexeram no arquivo E o template quer outra coisa: única classe que exige decisão humana.
    return 'conflito'
}

function Get-ScaffoldGeneratedFile {
    # Artefatos DERIVADOS: o próprio projeto os regenera (`/sync-context` -> Invoke-Resync). Divergem
    # do template POR CONSTRUÇÃO, em 100% dos projetos, assim que a curadoria roda — chamar isso de
    # 'conflito' é ruído: pede atenção humana para algo que nunca vai precisar dela. No IAIMG eram 4
    # dos 10 conflitos restantes.
    #
    # E o template nunca precisa entregá-los de volta: o resync os reconstrói a partir dos agentes/KB
    # REAIS do projeto — inclusive dos agentes novos que o próprio upgrade acabou de trazer.
    #
    # FONTE: tools/resync.ps1 (Get-ResyncArtifact). Não dá para dot-source dali — o onboarding é
    # standalone, não depende da camada tools/. A concordância entre as duas listas é VERIFICADA em
    # onboarding/tests/scaffold-upgrade.Tests.ps1: se o resync ganhar um derivado novo e esta lista
    # não, o CI reprova.
    return @(
        '.claude\agents\AGENT_MAP.md'
        '.claude\agents\graph.json'
        '.claude\agents\graph.cypher'
        '.claude\kb\_index.yaml'
    )
}

function Get-ScaffoldUpgradePlan {
    # Classifica CADA arquivo do template para o destino. Read-only, determinístico (ordena por Rel).
    # -Manifest $null = projeto legado (sem baseline) -> tudo que difere cai em 'desconhecido'.
    # Devolve { Rel; Class; Action } — Action: 'apply' (escreve), 'skip' (nada), 'hold' (humano).
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestRoot,
        [AllowNull()][hashtable]$Manifest
    )

    $map = @(Get-BaselineMap -SourceRoot $SourceRoot -DestRoot $DestRoot)
    $gerados = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(Get-ScaffoldGeneratedFile), [System.StringComparer]::OrdinalIgnoreCase)

    # UNIÃO template ∪ manifest — não só o template. O que o template REMOVEU só aparece no baseline;
    # iterar apenas a fonte torna a remoção invisível (o upgrade só sabia adicionar). v0.8.23.
    $doTemplate = @{}
    foreach ($item in $map) { $doTemplate[$item.Rel] = $true }
    $sumidos = @()
    if ($Manifest) {
        $sumidos = @($Manifest.Keys | Where-Object { -not $doTemplate.ContainsKey($_) } | ForEach-Object {
            [pscustomobject]@{
                Rel = $_
                Src = $null                                   # não existe mais no template
                Dst = (Join-Path $DestRoot $_)
            }
        })
    }

    $plan = foreach ($item in ($map + $sumidos)) {
        $baseline = if ($Manifest -and $Manifest.ContainsKey($item.Rel)) { $Manifest[$item.Rel] } else { $null }
        # Src é $null para o que saiu do template. Get-FileSha256 tem -Path [string] Mandatory: passar
        # $null vira '' e o BINDING LANÇA antes de a função rodar — o guarda tem de ser aqui.
        $tplHash  = if ($item.Src) { Get-FileSha256 -Path $item.Src } else { $null }
        $diskHash = Get-FileSha256 -Path $item.Dst

        # RETROCOMPAT (v0.8.25): manifest gravado ANTES da normalização guarda o hash BRUTO. Sem
        # isto, todo projeto existente veria seus arquivos 'intacto' virarem 'conflito' na primeira
        # rodada — o upgrade pararia de entregar exatamente onde era seguro entregar. Se o baseline
        # bate com o hash bruto do disco, o arquivo ESTÁ intacto: só o hash mudou de forma, não o
        # conteúdo. O manifest é regravado normalizado ao fim, então isto se resolve numa rodada.
        if ($baseline -and $diskHash -ne $baseline -and (Get-FileSha256 -Path $item.Dst -Raw) -eq $baseline) {
            $diskHash = $baseline
        }

        $class    = Get-ScaffoldFileClass -BaselineHash $baseline `
                                          -DiskHash $diskHash `
                                          -TemplateHash $tplHash

        # DERIVADO que já existe no projeto: o resync manda nele, não o template. Só reclassifica se
        # o disco TEM o arquivo — se ainda não existe (projeto novo), 'novo' vale e ele é entregue,
        # senão o dia 0 ficaria sem mapa nenhum.
        if ($gerados.Contains($item.Rel) -and $class -notin @('novo', 'ausente')) { $class = 'gerado' }

        $action = switch ($class) {
            'gerado'       { 'skip' }    # nunca sobrescreve, nunca pede atenção: o /sync-context cuida
            'novo'         { 'apply' }
            'intacto'      { 'apply' }
            'em-dia'       { 'skip' }
            'removido'     { 'delete' }  # nós entregamos, o template retirou, o usuário não mexeu
            'local'        { 'skip' }    # nunca foi nosso — é do usuário
            'ausente'      { 'skip' }    # já não existe em lugar nenhum
            'conflito'     { 'hold' }
            'orfao'        { 'hold' }    # o template retirou, mas o usuário editou -> humano decide
            'desconhecido' { 'hold' }
            default        { 'hold' }   # classe nova sem action = fail-safe, não escreve
        }
        [pscustomobject]@{ Rel = $item.Rel; Class = $class; Action = $action }
    }
    return @($plan | Sort-Object Rel)
}

# NOTA (v0.8.18): Get-ScaffoldUpdatePlan (A7) foi REMOVIDA — devolvia { Rel; Status=new|changed },
# um "plano de update" que só sabia dizer QUE difere, não POR QUE difere, e por isso mandava
# sobrescrever customização do usuário. Get-ScaffoldUpgradePlan (acima) a substitui inteira. Deixar
# as duas seria manter dois predicados do mesmo fato — a duplicação que já produziu drift 3x aqui.

# --- Marcador de versão instalada (~/.claude/.native-sdd-version) --------
# Idempotência versionada do próprio instalador (DESIGN_INSTALADOR_UPDATE.md): distinto do
# .claude/.scaffold-version acima (aquele marca o framework_commit que gerou um PROJETO
# scaffolded; este marca a versão do Native-SDD instalada NUMA MÁQUINA). Mesmo molde de
# arquivo `key: value`, propósito e leitor diferentes — não reusar um pelo outro.
function Get-NativeSddVersionMarkerContent {
    # Pura: recebe a versão e o stamp já resolvidos (sem tocar disco/relógio).
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$Stamp
    )
    if (-not $Stamp) {
        $Stamp = (Get-Date).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    @(
        '# Native-SDD install marker — gerado por onboarding/install.ps1 (ou install.sh)'
        '# Identifica a versão instalada nesta máquina (idempotência do instalador).'
        "installed_version: $Version"
        "installed_at: $Stamp"
    ) -join "`r`n"
}

function Read-NativeSddVersionMarker {
    # Lê o marcador de <Path>/.native-sdd-version. Pura/read-only. Retorna $null se o arquivo
    # estiver ausente ou sem installed_version (marcador inexistente/corrompido — tratado como
    # "sem versão instalada", nunca como erro).
    param([Parameter(Mandatory)][string]$Path)

    $file = Join-Path $Path '.native-sdd-version'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }

    $version = $null; $installedAt = $null
    foreach ($line in (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*installed_version\s*:\s*(.+?)\s*$') { $version = $Matches[1].Trim() }
        elseif ($line -match '^\s*installed_at\s*:\s*(.+?)\s*$')  { $installedAt = $Matches[1].Trim() }
    }
    if (-not $version) { return $null }

    return [pscustomobject]@{
        InstalledVersion = $version
        InstalledAt      = $installedAt
    }
}

function Test-NativeSddUpToDate {
    # Gate puro: decide se a instalação pode ser pulada. -Force sempre força "não está em dia"
    # (nunca pula). Versão ausente de qualquer lado (1ª instalação, ou VERSION sumiu do
    # checkout) também força "não está em dia" — o caminho seguro é reinstalar, não travar.
    param(
        [string]$InstalledVersion,
        [string]$CurrentVersion,
        [switch]$Force
    )
    if ($Force) { return $false }
    if ([string]::IsNullOrWhiteSpace($InstalledVersion)) { return $false }
    if ([string]::IsNullOrWhiteSpace($CurrentVersion))   { return $false }
    return $InstalledVersion -eq $CurrentVersion
}

function Write-NativeSddVersionMarker {
    # Grava/atualiza o marcador ao fim de uma instalação real. Nunca chamada em -Check/-DryRun
    # (decisão fica no chamador, igual aos outros passos Install-*). Falha ao escrever vira WARN,
    # nunca FAIL — o resto da instalação já rodou.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Version,
        [hashtable]$Summary
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $file = Join-Path $Path '.native-sdd-version'
    try {
        Set-Content -LiteralPath $file -Value (Get-NativeSddVersionMarkerContent -Version $Version) -NoNewline
        Write-Step OK "marcador de versão atualizado (v$Version)"
    }
    catch {
        Write-Step WARN "não foi possível gravar o marcador de versão: $($_.Exception.Message)"
        if ($Summary) { $Summary.Warn++ }
    }
}

function Write-Summary {
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [TimeSpan]$Elapsed
    )
    Write-Host ''
    Write-Host '──────────── SUMMARY ────────────'
    Write-Host ("  Instalado : {0}" -f $Summary.Installed)
    Write-Host ("  Pulado    : {0}" -f $Summary.Skipped)
    Write-Host ("  Backup    : {0}" -f $Summary.Backup)
    if ($Summary.Warn -gt 0) {
        Write-Host ("  Avisos    : {0}" -f $Summary.Warn) -ForegroundColor Yellow
    }
    Write-Host ("  Falhou    : {0}" -f $Summary.Failed)
    if ($Summary.Failed -gt 0) {
        Write-Host ("  Falhas    : {0}" -f ($Summary.Failures -join ', ')) -ForegroundColor Red
    }
    if ($PSBoundParameters.ContainsKey('Elapsed')) {
        Write-Host ("  Tempo     : {0}" -f (Format-Duration $Elapsed))
    }
    Write-Host '─────────────────────────────────'
}

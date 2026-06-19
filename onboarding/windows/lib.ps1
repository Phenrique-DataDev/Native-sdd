# lib.ps1 — funções puras/reutilizáveis do instalador (Windows).
# Apenas DEFINE funções (sem efeitos colaterais ao carregar) — testável com Pester.
# Compatível com Windows PowerShell 5.1+ e PowerShell 7+ (sem ternário/3-arg Join-Path).

Set-StrictMode -Version Latest

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
    param([string]$Text)
    $homeEsc = ($env:USERPROFILE -replace '\\', '\\')
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

# --- Instalação de um baseline .json (MERGE no destino; cria se faltar) ---
function Install-JsonBaselineItem {
    param(
        [Parameter(Mandatory)][pscustomobject]$Item,
        [Parameter(Mandatory)][hashtable]$Summary,
        [switch]$Check,
        [switch]$DryRun
    )
    try {
        $destExists = Test-Path -LiteralPath $Item.Dst -PathType Leaf
        $baseObj = if ($destExists) { (Get-Content -LiteralPath $Item.Dst -Raw) | ConvertFrom-Json } else { [pscustomobject]@{} }
        $overObj = (Expand-BaselinePlaceholder (Get-Content -LiteralPath $Item.Src -Raw)) | ConvertFrom-Json
        $merged  = Merge-JsonObject $baseObj $overObj
        # Reescreve hooks p/ runtime nativo (pwsh) — remove a dependência de `sh` no Windows (J4).
        $merged  = ConvertTo-NativeHooks $merged
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
        [switch]$Check,
        [switch]$DryRun
    )
    # .json → sempre via instalador JSON: expande {{HOME}}, reescreve hooks p/ nativo (J4) e,
    # se o destino existir, faz MERGE (preserva a config do usuário); senão, cria.
    if (([System.IO.Path]::GetExtension($Item.Dst)) -ieq '.json') {
        Install-JsonBaselineItem -Item $Item -Summary $Summary -Check:$Check -DryRun:$DryRun
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

function Install-ManagedPolicy {
    # Aplica (opt-in) a managed policy num caminho de sistema. Por padrão PERGUNTA ao usuário;
    # escrever exige admin — se a sessão não está elevada, relança só este passo via UAC.
    # -Decision Ask|Yes|No controla o prompt (Yes/No injetáveis em testes/automação).
    # -IsAdmin é resolvido via Test-IsAdmin quando não informado (injetável em testes).
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][hashtable]$Summary,
        [string]$DestDir = 'C:\Program Files\ClaudeCode',
        [ValidateSet('Ask', 'Yes', 'No')][string]$Decision = 'Ask',
        [switch]$Check,
        [switch]$DryRun,
        [switch]$IsAdmin
    )
    if (-not $PSBoundParameters.ContainsKey('IsAdmin')) { $IsAdmin = [bool](Test-IsAdmin) }

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

    Write-Step INFO 'managed policy exige admin — solicitando elevação (UAC)...'
    if (Invoke-ElevatedManagedPolicyCopy -SourcePath $SourcePath -DestPath $destPath) {
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
    # habilitando um futuro `new-project.ps1 -Update`. Recebe o commit já resolvido
    # (mantém a função pura/testável, sem chamar git).
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
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
        "framework_commit: $Commit"
        "framework_root: $rootEsc"
    ) -join "`r`n"
}

function Read-ScaffoldVersion {
    # Lê o marcador .claude/.scaffold-version de um projeto já gerado e devolve os campos
    # (FrameworkCommit/GeneratedAt/FrameworkRoot). Pura/read-only. Retorna $null se o marcador
    # estiver ausente ou sem framework_commit (não é um projeto scaffolded reconhecível).
    param([Parameter(Mandatory)][string]$Path)

    $file = Join-Path $Path '.claude\.scaffold-version'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }

    $commit = $null; $generated = $null; $root = $null
    foreach ($line in (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*framework_commit\s*:\s*(.+?)\s*$')   { $commit = $Matches[1].Trim() }
        elseif ($line -match '^\s*generated_at\s*:\s*(.+?)\s*$')   { $generated = $Matches[1].Trim() }
        elseif ($line -match '^\s*framework_root\s*:\s*(.+?)\s*$') { $root = $Matches[1].Trim() }
    }
    if (-not $commit) { return $null }

    return [pscustomobject]@{
        FrameworkCommit = $commit
        GeneratedAt     = $generated
        FrameworkRoot   = $root
    }
}

function Get-ScaffoldUpdatePlan {
    # Plano de upgrade dirigido por diff: itens do scaffold que FALTAM ou DIFEREM no destino.
    # Read-only e determinístico (ordenado por Rel). Reusa Get-BaselineMap + Test-FilesDiffer —
    # não duplica a descoberta nem a comparação. Itens idênticos ficam de fora (nada a fazer).
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestRoot
    )

    $plan = foreach ($item in (Get-BaselineMap -SourceRoot $SourceRoot -DestRoot $DestRoot)) {
        if (-not (Test-Path -LiteralPath $item.Dst -PathType Leaf)) {
            [pscustomobject]@{ Rel = $item.Rel; Status = 'new' }
        }
        elseif (Test-FilesDiffer -A $item.Src -B $item.Dst) {
            [pscustomobject]@{ Rel = $item.Rel; Status = 'changed' }
        }
    }
    return @($plan | Sort-Object Rel)
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

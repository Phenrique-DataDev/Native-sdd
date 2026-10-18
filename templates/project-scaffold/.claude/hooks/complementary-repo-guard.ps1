<#
.SYNOPSIS
    Hook PreToolUse (matcher "Write|Edit|Bash|PowerShell") — backstop do boundary read-only de repositorios
    complementares (REPOS_COMPLEMENTARES, DESIGN D3).

.DESCRIPTION
    Irmao dos guards globais (secret-guard/destructive-guard), mas de PROJETO: em cada
    Write/Edit (e em cada Bash/PowerShell, pelo destino de escrita do comando) decide:
      - file_path cai dentro de um Path registrado em .claude/complementary-repos.psd1 (que
        ainda existe no disco) OU dentro do cache .claude/.cache/complementary-repos/
                                                                        -> permissionDecision "ask"
      - qualquer outro caso                                           -> PASSTHROUGH (exit 0)

    NUNCA usa "deny" (mesma filosofia dos demais guards): so pede confirmacao. A regra
    complementary-repos.md e' quem ensina a nunca escrever ali; este hook e' o backstop
    deterministico caso a regra falhe/seja ignorada.

    Fail-safe ASSIMETRICO (molde secret-guard.ps1): registro AUSENTE -> passthrough (nada a
    proteger). Registro PRESENTE mas erro ao ler/parsear -> "ask" (nao da pra confirmar que e'
    seguro escrever, entao pergunta).

    Self-contido de proposito: NAO dot-source tools/complementary-repos.ps1 (cascata
    rules/tooling.md) para nao depender de $env:SDD_WORKFLOW_HOME em tempo de guard de
    seguranca — Import-PowerShellDataFile e' nativo do PowerShell 5.1+/7+, sem dependencia
    externa. tools/complementary-repos.ps1 continua sendo a fonte para o comando
    /complementary-repos (add/list/remove) e uso programatico/testes.

    Bash/PowerShell (2026-10-17): le o comando e pede confirmacao quando ele escreve num path
    protegido -- redirecao (> >>), tee/cp/mv/rm/touch/mkdir e os cmdlets equivalentes, sed -i,
    perl -i e git que muda o repositorio (inclusive por `cd` ou `git -C`). Ler passa. Limitacao
    honesta: e' heuristica de texto; escrita por script (python -c, node -e) ou caminho em
    variavel nao e' vista, e a disciplina da regra cobre esse caso.

    Schema do hook (PreToolUse) no mesmo molde de secret-guard.ps1/destructive-guard.ps1.
    Funcoes puras sao dot-sourceaveis para teste; o fluxo so roda quando NAO e' dot-sourced.
#>

Set-StrictMode -Version Latest

$script:ComplementaryRepoRegistryRelPath = '.claude/complementary-repos.psd1'
$script:ComplementaryRepoCacheRelPath = '.claude/.cache/complementary-repos'

# --- Acesso seguro a propriedade sob StrictMode (PSCustomObject do ConvertFrom-Json) ----------
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# --- PURA: extrai os campos canonicos do payload ja parseado (contrato H5/HARNESS-CONTRACT.md) -
function Read-NormalizedEvent {
    param([Parameter(Mandatory)][AllowNull()]$Payload)
    $toolInput = Get-PropOrNull $Payload 'tool_input'
    return [pscustomobject]@{
        ToolName = [string](Get-PropOrNull $Payload 'tool_name')
        FilePath = [string](Get-PropOrNull $toolInput 'file_path')
        Command  = [string](Get-PropOrNull $toolInput 'command')
        Cwd      = [string](Get-PropOrNull $Payload 'cwd')
    }
}

# --- PURA: monta o JSON da decisao (schema PreToolUse) ----------------------------------------
function New-HookDecisionJson {
    param(
        [Parameter(Mandatory)][ValidateSet('allow', 'ask', 'deny')][string]$Decision,
        [string]$Reason
    )
    $obj = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName            = 'PreToolUse'
            permissionDecision       = $Decision
            permissionDecisionReason = $Reason
        }
        systemMessage = $Reason
    }
    return ($obj | ConvertTo-Json -Depth 6 -Compress)
}

# --- PURA: file_path cai dentro de algum path protegido? (mesma logica de tools/complementary-repos.ps1)
function Test-PathUnderProtected {
    param([string]$FilePath, [string[]]$ProtectedPaths)
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

# --- PURA: token de caminho do comando -> absoluto normalizado (barra, minusculo, sem `.`/`..`).
#     $null quando nao da pra resolver sem executar (variavel, vazio). `/c/x` (MSYS) vira `c:/x`
#     so quando a base e' Windows; em POSIX `/c/x` e' um caminho de verdade.
function Resolve-CommandPathToken {
    param([string]$Token, [string]$BaseDir, [string]$HomeDir)
    $t = $Token.Trim().Trim('"', "'")
    if ([string]::IsNullOrWhiteSpace($t) -or $t.Contains('$')) { return $null }
    $t = $t.Replace('\', '/')
    $base = ([string]$BaseDir).Replace('\', '/')
    if ($t -eq '~' -or $t.StartsWith('~/')) {
        if ([string]::IsNullOrWhiteSpace($HomeDir)) { return $null }
        $t = $HomeDir.Replace('\', '/').TrimEnd('/') + $t.Substring(1)
    }
    if ($base -match '^[a-zA-Z]:' -and $t -match '^/([a-zA-Z])(/|$)') {
        $t = "$($Matches[1]):/" + $(if ($t.Length -gt 3) { $t.Substring(3) } else { '' })
    }
    # No Git Bash o `/tmp` e' o %TEMP% (montagem `usertemp` do Git for Windows; o destructive-guard
    # mede o mesmo). `cygpath -u` de um caminho sob o TEMP devolve `/tmp/...`. GetTempPath e nao o
    # $env:TEMP: no runner o TEMP vem em nome curto (`RUNNER~1`) e o registro, na forma longa.
    if ($base -match '^[a-zA-Z]:' -and $t -match '^/tmp(/|$)') {
        $t = [IO.Path]::GetTempPath().Replace('\', '/').TrimEnd('/') + $t.Substring(4)
    }
    if ($t -notmatch '^(?:[a-zA-Z]:/|/)') {
        if ([string]::IsNullOrWhiteSpace($base)) { return $null }
        $t = $base.TrimEnd('/') + '/' + $t
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $t.Split('/')) {
        if ($c -eq '' -or $c -eq '.') { continue }
        if ($c -eq '..') { if ($parts.Count -gt 1 -or ($parts.Count -eq 1 -and $parts[0] -notmatch ':$')) { $parts.RemoveAt($parts.Count - 1) }; continue }
        $parts.Add($c)
    }
    $out = ($parts -join '/')
    if ($t.StartsWith('/')) { $out = '/' + $out }
    elseif ($out -match '^[a-zA-Z]:$') { $out += '/' }
    return $out.ToLowerInvariant()
}

# Comandos que escrevem em QUALQUER argumento, que escrevem so no DESTINO (o ultimo argumento ou o
# -Destination) e subcomandos do git que mexem no repositorio. Ler (cat, rg, git log) passa: consultar
# o repo complementar e' o motivo de ele estar registrado.
$script:BashWriteAnyArg = @('tee', 'touch', 'mkdir', 'md', 'rm', 'rmdir', 'rd', 'del', 'erase', 'ln', 'chmod', 'chown',
    'truncate', 'mv', 'move', 'ren', 'set-content', 'sc', 'add-content', 'ac', 'out-file', 'new-item', 'ni',
    'remove-item', 'ri', 'move-item', 'mi', 'rename-item', 'rni', 'clear-content', 'clc')
$script:BashWriteDestArg = @('cp', 'copy', 'copy-item', 'cpi', 'rsync', 'install', 'scp')
$script:GitWriteSub = @('add', 'am', 'apply', 'checkout', 'cherry-pick', 'clean', 'commit', 'merge', 'mv', 'pull',
    'push', 'rebase', 'reset', 'restore', 'revert', 'rm', 'switch', 'worktree')
$script:CdCommands = @('cd', 'pushd', 'set-location', 'sl', 'push-location')
# Espelhado no .sh (BASH_WRITE_PREFILTER, sem o `(?i)`: la o `grep -i` faz esse papel; teste trava a
# igualdade). Cobre todo nome das tres listas acima.
$script:BashWritePrefilter = '(?i)>|(^|[^a-z0-9_-])(tee|touch|mkdir|md|rm|rmdir|rd|del|erase|ln|chmod|chown|truncate|mv|move|ren|set-content|sc|add-content|ac|out-file|new-item|ni|remove-item|ri|move-item|mi|rename-item|rni|clear-content|clc|cp|copy|copy-item|cpi|rsync|install|scp|sed|perl|git)([^a-z0-9_-]|$)'

# --- PURA: o comando Bash/PowerShell escreve dentro de um path protegido? Devolve o caminho atingido
#     ou $null. Heuristica de texto: separa em segmentos (&& || ; | quebra de linha), acompanha `cd`,
#     olha redirecao (> e >>), os comandos de escrita acima, `sed -i`/`perl -i` e o git (com -C).
#     Escrita por script (python -c, node -e) nao e' vista -- a disciplina da regra cobre esse caso.
function Get-BashProtectedWrite {
    param([string]$Command, [string]$Cwd, [string[]]$ProtectedPaths, [string]$HomeDir)
    if ([string]::IsNullOrWhiteSpace($Command) -or -not $ProtectedPaths -or $ProtectedPaths.Count -eq 0) { return $null }
    # Pre-filtro (so desempenho): sem redirecao nem nome de comando que escreve, nada abaixo acharia.
    if ($Command -notmatch $script:BashWritePrefilter) { return $null }
    $curDir = $Cwd
    $hit = {
        param($tok)
        $r = Resolve-CommandPathToken -Token $tok -BaseDir $curDir -HomeDir $HomeDir
        if ($r -and (Test-PathUnderProtected -FilePath $r -ProtectedPaths $ProtectedPaths)) { return $r }
        return $null
    }
    foreach ($rawSeg in ($Command -split '\|\||&&|[;|&\r\n]')) {
        $seg = $rawSeg.Trim().TrimStart('(').TrimEnd(')').Trim()
        if ($seg -eq '') { continue }
        $redirRe = '\d?>{1,2}\s*("[^"]*"|''[^'']*''|[^\s;|&<>()]+)'
        foreach ($m in [regex]::Matches($seg, $redirRe)) {
            $r = & $hit $m.Groups[1].Value
            if ($r) { return $r }
        }
        $seg = [regex]::Replace($seg, $redirRe, ' ')
        $toks = @([regex]::Matches($seg, '"[^"]*"|''[^'']*''|\S+') | ForEach-Object { $_.Value.Trim('"', "'") })
        $i = 0
        while ($i -lt $toks.Count -and ($toks[$i] -match '^[A-Za-z_][A-Za-z0-9_]*=' -or $toks[$i] -in @('sudo', 'command', 'builtin', 'exec', 'nohup', 'time'))) { $i++ }
        if ($i -ge $toks.Count) { continue }
        $cmd = $toks[$i].ToLowerInvariant()
        $cmd = ($cmd -split '/')[-1] -replace '\.exe$', ''
        $argv = @(if ($i + 1 -lt $toks.Count) { $toks[($i + 1)..($toks.Count - 1)] } else { @() })
        $pos = @($argv | Where-Object { $_ -notmatch '^-' })

        if ($cmd -in $script:CdCommands) {
            $target = @($argv | Where-Object { $_ -notmatch '^-' } | Select-Object -First 1)
            if ($target.Count -gt 0) {
                $r = Resolve-CommandPathToken -Token $target[0] -BaseDir $curDir -HomeDir $HomeDir
                if ($r) { $curDir = $r }
            }
            continue
        }
        if ($cmd -in $script:BashWriteAnyArg) {
            foreach ($a in $pos) { $r = & $hit $a; if ($r) { return $r } }
            continue
        }
        if ($cmd -in $script:BashWriteDestArg) {
            $dest = $null
            for ($k = 0; $k -lt $argv.Count; $k++) {
                if (($argv[$k] -match '^-(?:destination|dest)$' -or $argv[$k] -ceq '-t') -and $k + 1 -lt $argv.Count) { $dest = $argv[$k + 1] }
                elseif ($argv[$k] -match '^--target-directory=(.+)$') { $dest = $Matches[1] }
            }
            if (-not $dest -and $pos.Count -gt 0) { $dest = $pos[-1] }
            if ($dest) { $r = & $hit $dest; if ($r) { return $r } }
            continue
        }
        if ($cmd -in @('sed', 'perl') -and @($argv | Where-Object { $_ -cmatch '^-[a-zA-Z]*i|^--in-place' }).Count -gt 0) {
            foreach ($a in $pos) { $r = & $hit $a; if ($r) { return $r } }
            continue
        }
        if ($cmd -eq 'git') {
            $gitDir = $curDir; $sub = $null
            for ($k = 0; $k -lt $argv.Count; $k++) {
                $a = $argv[$k]
                if ($a -cin @('-C', '--work-tree', '--git-dir') -and $k + 1 -lt $argv.Count) {
                    $r = Resolve-CommandPathToken -Token $argv[$k + 1] -BaseDir $gitDir -HomeDir $HomeDir
                    if ($r) { $gitDir = $r }
                    $k++; continue
                }
                if ($a -cin @('-c', '--namespace', '--config-env')) { $k++; continue }
                if ($a -match '^-') { continue }
                $sub = $a.ToLowerInvariant(); break
            }
            # `stash list`/`stash show` so leem; o resto (push, pop, drop, o `stash` puro) mexe na arvore.
            if ($sub -eq 'stash') {
                $next = @($argv | Select-Object -Skip ($k + 1) | Where-Object { $_ -notmatch '^-' } | Select-Object -First 1)
                if ($next.Count -eq 0 -or $next[0] -notin @('list', 'show')) { $sub = 'stash-write' }
            }
            if ($sub -and ($sub -in $script:GitWriteSub -or $sub -eq 'stash-write')) {
                $r = Resolve-CommandPathToken -Token '.' -BaseDir $gitDir -HomeDir $HomeDir
                if ($r -and (Test-PathUnderProtected -FilePath $r -ProtectedPaths $ProtectedPaths)) { return $r }
            }
            continue
        }
    }
    return $null
}

# --- I/O (read-only): le o registro + deriva os paths protegidos (self-contido, sem tools/) ----
function Get-ComplementaryRepoProtectedPathsInline {
    param([Parameter(Mandatory)][string]$Cwd)

    $registryPath = Join-Path $Cwd $script:ComplementaryRepoRegistryRelPath
    $cacheRoot = Join-Path $Cwd $script:ComplementaryRepoCacheRelPath

    $protectedPaths = @()
    if (Test-Path -LiteralPath $cacheRoot -PathType Container) {
        $protectedPaths += (Resolve-Path -LiteralPath $cacheRoot).Path
    }
    else {
        $protectedPaths += $cacheRoot
    }

    $data = Import-PowerShellDataFile -LiteralPath $registryPath
    foreach ($entry in @($data.Repos)) {
        $p = [string]$entry['Path']
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p -PathType Container)) {
            $protectedPaths += (Resolve-Path -LiteralPath $p).Path
        }
    }
    return @($protectedPaths | Select-Object -Unique)
}

# --- Fluxo principal ----------------------------------------------------------------------------
function Invoke-ComplementaryRepoGuard {
    # 0) Forca stdout em UTF-8 sem BOM: o texto emitido tem acentuacao (pt-BR) e o console do
    #    pwsh no Windows NAO escreve UTF-8 em stdout redirecionado -- sem isto o JSON sai na
    #    codepage OEM e chega corrompido ao modelo (medido byte a byte). Molde repetido em
    #    todos os hooks que emitem texto -- auto-suficiente de proposito, sem apontar para um
    #    arquivo vizinho: ate 2026-09-01 este comentario citava o agent-graph-context.ps1, que
    #    foi REMOVIDO do scaffold, e o ponteiro teria sobrevivido ao alvo. Falha aqui NAO aborta
    #    o hook: encoding ruim e' melhor que
    #    hook desativado (num guard, o `return` viraria passthrough silencioso).
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

    # 1) Ler payload (falha -> passthrough)
    try { $raw = [Console]::In.ReadToEnd() } catch { return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    try { $payload = $raw | ConvertFrom-Json } catch { return }

    # 2) Pre-condicoes (qualquer nao-match -> passthrough)
    $evt = Read-NormalizedEvent $payload
    # Bash/PowerShell (2026-10-17): a regra `permissions.ask Edit(...)` nao alcanca escrita via shell
    # (medido em 4 bracos com claude -p 2.1.302), entao o proprio guard le o comando.
    $isShell = $evt.ToolName -in @('Bash', 'PowerShell')
    if (-not $isShell -and $evt.ToolName -notin @('Write', 'Edit')) { return }
    if ($isShell -and [string]::IsNullOrWhiteSpace($evt.Command)) { return }
    if (-not $isShell -and [string]::IsNullOrWhiteSpace($evt.FilePath)) { return }

    $cwd = $evt.Cwd
    if ([string]::IsNullOrWhiteSpace($cwd)) { $cwd = (Get-Location).Path }

    # O registro mora na raiz do projeto. O cwd do shell persiste entre chamadas: depois de um
    # `cd` para dentro do repo complementar, a raiz so se acha pelo CLAUDE_PROJECT_DIR.
    $root = $cwd
    if (-not (Test-Path -LiteralPath (Join-Path $root $script:ComplementaryRepoRegistryRelPath) -PathType Leaf) -and $env:CLAUDE_PROJECT_DIR) {
        $root = $env:CLAUDE_PROJECT_DIR
    }
    $registryPath = Join-Path $root $script:ComplementaryRepoRegistryRelPath
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { return }   # nada registrado -> passthrough

    # 3) Registro presente: erro ao ler/resolver = "ask" no Write/Edit (fail-safe assimetrico,
    #    Decisao 4). No shell, silencio: pedir em todo `ls` por um registro quebrado e' ruido.
    try {
        $protectedPaths = Get-ComplementaryRepoProtectedPathsInline -Cwd $root
    }
    catch {
        if ($isShell) { return }
        Write-Output (New-HookDecisionJson -Decision 'ask' `
                -Reason 'Nao foi possivel verificar o registro de repositorios complementares (.claude/complementary-repos.psd1). Confirmacao exigida.')
        return
    }

    if ($isShell) {
        $alvo = $null
        try { $alvo = Get-BashProtectedWrite -Command $evt.Command -Cwd $cwd -ProtectedPaths $protectedPaths -HomeDir $HOME } catch { return }
        if ($alvo) {
            Write-Output (New-HookDecisionJson -Decision 'ask' `
                    -Reason "O comando escreve em '$alvo', que pertence a um repositorio complementar registrado (leitura-only). Confirme que quer mesmo escrever fora do projeto atual.")
        }
        return
    }

    if (Test-PathUnderProtected -FilePath $evt.FilePath -ProtectedPaths $protectedPaths) {
        Write-Output (New-HookDecisionJson -Decision 'ask' `
                -Reason "O caminho '$($evt.FilePath)' pertence a um repositorio complementar registrado (leitura-only). Confirme que quer mesmo escrever fora do projeto atual.")
    }
}

# --- Guard: roda o fluxo so quando NAO dot-sourced (Pester faz `. complementary-repo-guard.ps1`)
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ComplementaryRepoGuard
}

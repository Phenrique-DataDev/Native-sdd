<#
.SYNOPSIS
    /doctor — health-check do RUNTIME instalado dos guards de seguranca (R2).

.DESCRIPTION
    O `check.ps1` valida os TEMPLATES (fonte); ninguem valida o estado INSTALADO em
    `~/.claude`. R2: pos-install o `settings.json` registra `pwsh -NoProfile -File <guard>.ps1`
    (forma nativa, sem fallback `sh` no Windows). Se o `pwsh` sair do PATH ou um guard for
    movido/quebrado, o spawn falha (exit 9009/127) — que NAO e' exit 2 → o Claude Code prossegue
    e os guards "ask" desligam EM SILENCIO. O usuario acredita estar protegido e nao esta.

    O doctor fecha esse buraco: roda no `pwsh` (que funciona no momento em que o usuario o invoca)
    e PROVA que os guards disparam — nao so que a config existe:
      1. pwsh-no-path     — `pwsh` (bare) resolve no PATH? (o que o spawn do hook precisa).
      2. settings/hooks   — `~/.claude/settings.json` existe e registra os guards; cada command-path
                            aponta p/ um arquivo .ps1 que EXISTE em disco.
      3. dry-run sintetico — invoca cada guard via `pwsh -NoProfile -File <ps1>` com um payload que
                            DEVE disparar `ask` (secret: `cat .env`; destructive: `rm -rf /`) e
                            confere a `permissionDecision`. Prova o COMPORTAMENTO, nao so a config.

    Funcoes PURAS (texto/dados, sem disco) + I/O fino, dot-sourceaveis p/ teste; espelha o padrao
    dos tools/*.ps1. Read-only: nao escreve em `~/.claude` nem em produção. Compativel com
    PowerShell 7+.

    Status de cada achado: `ok` (verde) · `fail` (bloqueia o gate) · `skip` (nao-aplicavel). Como
    script: `pwsh tools/doctor.ps1 [-SettingsPath <p>]` (exit 0/1).
#>

param(
    [string]$SettingsPath,
    [string]$ClaudeJsonPath
)

Set-StrictMode -Version Latest

# --- PURA: acesso seguro a propriedade sob StrictMode (PSCustomObject do ConvertFrom-Json) -----
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# --- PURA: monta um achado (mesmo shape legivel dos demais checks) -----------------------------
function New-DoctorFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('ok', 'fail', 'skip')][string]$Status,
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][string]$Message
    )
    [pscustomobject]@{ Status = $Status; Check = $Check; Message = $Message }
}

# --- PURA: extrai o path do .ps1 de um command de hook -----------------------------------------
# Cobre a forma nativa `pwsh -NoProfile -File "<ps1>"` e a portavel `sh -c '…' _ "<ps1>" "<sh>"`
# (1o .ps1 entre aspas). Sem aspas, casa o 1o token terminando em .ps1.
function Get-HookPs1Path {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $m = [regex]::Match($Command, '"([^"]+\.ps1)"')
    if ($m.Success) { return $m.Groups[1].Value }
    $m2 = [regex]::Match($Command, '(\S+\.ps1)')
    if ($m2.Success) { return $m2.Groups[1].Value }
    return $null
}

# --- PURA: pelo nome do arquivo do guard, o payload sintetico que DEVE disparar `ask` ----------
# $null = hook desconhecido (nao testamos comportamento, so existencia).
function Get-GuardCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $leaf = (Split-Path -Leaf $Path).ToLowerInvariant()
    switch ($leaf) {
        'secret-guard.ps1' {
            [pscustomobject]@{ Name = 'secret-guard'; Expect = 'ask'; ExpectReasonMatch = $null
                Payload = '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}' }
        }
        'destructive-guard.ps1' {
            [pscustomobject]@{ Name = 'destructive-guard'; Expect = 'ask'; ExpectReasonMatch = $null
                Payload = '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' }
        }
        # Dispatcher consolidado: UM processo roda os dois guards. O payload dispara ambos de
        # proposito, e a razao precisa citar os DOIS -- senao um guard poderia ter morrido dentro
        # do dispatcher (ex.: dot-source falho) e o doctor veria o 'ask' do outro e diria OK.
        'bash-guards.ps1' {
            [pscustomobject]@{ Name = 'bash-guards'; Expect = 'ask'
                ExpectReasonMatch = '(?s)segredo.*destrutivo|destrutivo.*segredo'
                Payload = '{"tool_name":"Bash","tool_input":{"command":"rm -rf / && cat .env"}}' }
        }
        default { $null }
    }
}

# --- PURA: gate — $false se ha >=1 achado 'fail' ('skip' nao reprova) --------------------------
function Test-DoctorGate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    return -not (@($Findings | Where-Object { $_.Status -eq 'fail' }).Count -gt 0)
}

# --- PURA: relatorio legivel (estilo do check.ps1) ---------------------------------------------
function Format-DoctorReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)
    $tag = @{ ok = '[ OK ]'; fail = '[FAIL]'; skip = '[SKIP]' }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Findings) {
        $lines.Add(('{0} {1,-20} {2}' -f $tag[$f.Status], $f.Check, $f.Message))
    }
    $fails = @($Findings | Where-Object { $_.Status -eq 'fail' }).Count
    $lines.Add('')
    if ($fails -eq 0) {
        $lines.Add("OK — guards de runtime saudaveis ($(@($Findings).Count) checks)")
    }
    else {
        $lines.Add("FALHOU — $fails check(s) reprovados: os guards podem estar INATIVOS no runtime")
    }
    return ($lines -join [Environment]::NewLine)
}

# --- I/O: lista os commands de hooks.PreToolUse do settings.json instalado ---------------------
# $null = arquivo ausente (distingue de "existe mas sem hooks" = array vazio).
function Read-SettingsHookCommands {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SettingsPath)
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { return $null }
    try { $s = Get-Content -LiteralPath $SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch { return @() }
    $cmds = [System.Collections.Generic.List[string]]::new()
    # @(...) normaliza escalar-ou-array: ConvertFrom-Json devolve escalar p/ array de 1 elemento.
    # Atribui a um temp ANTES do foreach (inline `@(Get-PropOrNull ...)` no foreach nao itera certo).
    $entries = @(Get-PropOrNull (Get-PropOrNull $s 'hooks') 'PreToolUse')
    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }
        $inner = @(Get-PropOrNull $entry 'hooks')
        foreach ($h in $inner) {
            if ($null -eq $h) { continue }
            $c = Get-PropOrNull $h 'command'
            if ($c) { $cmds.Add([string]$c) }
        }
    }
    return , $cmds.ToArray()
}

# --- I/O: invoca o guard via `pwsh -File` com o payload no stdin; devolve a decisao -------------
# Replica FIELMENTE o spawn do Claude Code (pwsh bare + -NoProfile -File).
function Invoke-GuardDryRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Ps1Path,
        [Parameter(Mandatory)][string]$Payload
    )
    if (-not (Test-Path -LiteralPath $Ps1Path -PathType Leaf)) {
        return [pscustomobject]@{ Ran = $false; Decision = $null; Reason = $null; Error = 'arquivo do guard inexistente' }
    }
    try {
        $raw = ($Payload | & pwsh -NoProfile -File $Ps1Path 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [pscustomobject]@{ Ran = $true; Decision = $null; Reason = $null; Error = 'sem saida (passthrough ou spawn sem efeito)' }
        }
        try {
            $obj = $raw | ConvertFrom-Json
            $hso = Get-PropOrNull $obj 'hookSpecificOutput'
            $dec = Get-PropOrNull $hso 'permissionDecision'
            $rea = [string](Get-PropOrNull $hso 'permissionDecisionReason')
            return [pscustomobject]@{ Ran = $true; Decision = $dec; Reason = $rea; Error = $null }
        }
        catch {
            return [pscustomobject]@{ Ran = $true; Decision = $null; Reason = $null; Error = "saida nao-JSON: $raw" }
        }
    }
    catch {
        return [pscustomobject]@{ Ran = $false; Decision = $null; Reason = $null; Error = $_.Exception.Message }
    }
}

# --- PURA: os MCPs que ESTE repositorio registra (fonte unica) --------------------------------
# So conferimos o que o nosso onboarding instalou (install-mcp.ps1). O inventario do que o USUARIO
# registrou por conta propria e' do /doctor do Claude Code, nao nosso -- ver o gate 5/5 de
# DOCTOR_NAO_VE_MCP_NEM_PLUGIN (2026-09-18), que travou o escopo nesse minimo.
function Get-FrameworkMcpNames {
    [CmdletBinding()] param()
    return , @('context7')
}

# --- PURA: as linhas JSON-RPC do probe (initialize + tools/list) -------------------------------
function Get-McpProbeLines {
    [CmdletBinding()] param()
    return , @(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"sdd-doctor","version":"1"}}}'
        '{"jsonrpc":"2.0","method":"notifications/initialized"}'
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    )
}

# --- PURA: le a resposta bruta do servidor -> o que ele PROVOU --------------------------------
# Server que nao falou = Initialized $false e 0 tools. E' esta funcao que impede o check de dizer
# `ok` sem ter conversado: sem bytes de resposta, nao ha como fabricar tool nenhuma.
function Read-McpProbeResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Raw)

    $init = $false
    $tools = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Raw)) {
        foreach ($line in ($Raw -split "`r?`n")) {
            $t = $line.Trim()
            if (-not $t.StartsWith('{')) { continue }
            try { $o = $t | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            $res = Get-PropOrNull $o 'result'
            if ($null -eq $res) { continue }
            if (Get-PropOrNull $res 'serverInfo') { $init = $true }
            foreach ($tool in @(Get-PropOrNull $res 'tools')) {
                if ($null -eq $tool) { continue }
                $n = Get-PropOrNull $tool 'name'
                if ($n) { $tools.Add([string]$n) }
            }
        }
    }
    return [pscustomobject]@{ Initialized = $init; ToolNames = $tools.ToArray() }
}

# --- PURA: resultado do probe -> achado do doctor ---------------------------------------------
# `skip` = nao registrado (o passo do onboarding e' opcional e nao-bloqueante, nao reprova).
# `ok` exige tool listada: handshake sozinho nao prova que o servidor serve.
function Get-McpFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Registered,
        $Probe
    )
    $check = "mcp:$Name"
    if (-not $Registered) {
        return New-DoctorFinding -Status skip -Check $check -Message "nao registrado (o passo do context7 e' opcional no install)"
    }
    if ($null -eq $Probe -or -not $Probe.Spawned) {
        $err = if ($null -ne $Probe) { $Probe.Error } else { 'sem resultado' }
        return New-DoctorFinding -Status fail -Check $check -Message "registrado, mas o processo NAO subiu: $err"
    }
    if ($Probe.TimedOut) {
        return New-DoctorFinding -Status fail -Check $check -Message "registrado, mas nao respondeu em $($Probe.TimeoutMs)ms -- o Claude Code veria CONNECT_TIMEOUT"
    }
    $n = @($Probe.Result.ToolNames).Count
    if (-not $Probe.Result.Initialized -or $n -eq 0) {
        return New-DoctorFinding -Status fail -Check $check -Message "registrado e subiu, mas nao completou o handshake (initialize=$($Probe.Result.Initialized), tools=$n)"
    }
    return New-DoctorFinding -Status ok -Check $check -Message "responde em $($Probe.ElapsedMs)ms com $n tool(s): $(@($Probe.Result.ToolNames) -join ', ')"
}

# --- I/O: le a entrada de um MCP em ~/.claude.json (escopo user) -------------------------------
# $null = nao registrado. Objeto com ReadError = registro ILEGIVEL, que NAO e' a mesma coisa:
# medido em 2026-09-18 numa maquina real, o `ConvertFrom-Json` sem -AsHashtable recusa o arquivo
# inteiro quando ele tem duas chaves que so diferem em maiuscula/minuscula ("C:/..." e "c:/...",
# que o proprio Claude Code grava em .projects). Engolir isso como "nao registrado" daria SKIP
# verde justamente no caso em que nao se sabe de nada -- o modo de falha que este check existe
# para matar. Nunca devolve `env`/`headers`: segredo nao entra em achado nem em log.
function Read-RegisteredMcpServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClaudeJsonPath,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $ClaudeJsonPath -PathType Leaf)) { return $null }
    try { $j = Get-Content -LiteralPath $ClaudeJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch {
        return [pscustomobject]@{ Name = $Name; Command = $null; Args = @(); ReadError = $_.Exception.Message }
    }
    if (-not $j.ContainsKey('mcpServers')) { return $null }
    $servers = $j['mcpServers']
    if ($null -eq $servers -or -not $servers.ContainsKey($Name)) { return $null }
    $entry = $servers[$Name]
    if ($null -eq $entry -or -not $entry.ContainsKey('command')) { return $null }   # http/sse: fora do probe por stdio
    $cmd = $entry['command']
    if (-not $cmd) { return $null }
    $argList = @()
    if ($entry.ContainsKey('args') -and $entry['args']) { $argList = @($entry['args'] | ForEach-Object { [string]$_ }) }
    return [pscustomobject]@{ Name = $Name; Command = [string]$cmd; Args = $argList; ReadError = $null }
}

# --- I/O: resolve o comando para um executavel que o Process.Start consiga iniciar -------------
# `Process.Start` NAO resolve shim do PATH: `npx` (npx.cmd/npx.ps1 no Windows) falha com "arquivo
# nao encontrado" mesmo com o node instalado e funcionando. O cliente do Claude Code resolve, entao
# um probe ingenuo reprovaria justamente as maquinas em que o MCP esta SAO -- alarme falso, que num
# health-check custa mais caro que nao checar. Medido em 2026-09-18: `npx` bare -> Spawned=False;
# `npx.cmd` com caminho completo -> sobe. $null = nao resolve mesmo (ai o fail e' legitimo).
function Resolve-McpCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Command)
    if (Test-Path -LiteralPath $Command -PathType Leaf) { return $Command }
    $app = @(Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue)
    if ($app.Count -gt 0) { return $app[0].Source }
    return $null
}

# --- I/O: sobe o servidor por stdio e mede o handshake -----------------------------------------
# Fecha o stdin de proposito: servidor MCP por stdio encerra no EOF, e e' isso que da um fim
# deterministico ao probe sem precisar parsear stream aberto.
function Invoke-McpProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [AllowEmptyCollection()][string[]]$ArgList = @(),
        [int]$TimeoutMs = 30000
    )
    $resolved = Resolve-McpCommand -Command $Command
    if (-not $resolved) {
        return [pscustomobject]@{ Spawned = $false; TimedOut = $false; ElapsedMs = 0
            TimeoutMs = $TimeoutMs; Result = (Read-McpProbeResult -Raw ''); Error = "comando '$Command' nao resolve no PATH" }
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $resolved
    foreach ($a in $ArgList) { [void]$psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch {
        return [pscustomobject]@{ Spawned = $false; TimedOut = $false; ElapsedMs = 0
            TimeoutMs = $TimeoutMs; Result = (Read-McpProbeResult -Raw ''); Error = $_.Exception.Message }
    }
    try {
        foreach ($l in (Get-McpProbeLines)) { $p.StandardInput.WriteLine($l) }
        $p.StandardInput.Flush()
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEndAsync()
        $exited = $p.WaitForExit($TimeoutMs)
        $sw.Stop()
        if (-not $exited) {
            try { $p.Kill($true) } catch { Write-Verbose "falha ao matar o probe: $($_.Exception.Message)" }
            return [pscustomobject]@{ Spawned = $true; TimedOut = $true; ElapsedMs = $sw.ElapsedMilliseconds
                TimeoutMs = $TimeoutMs; Result = (Read-McpProbeResult -Raw ''); Error = $null }
        }
        $raw = ''
        if ($out.Wait(2000)) { $raw = [string]$out.Result }
        return [pscustomobject]@{ Spawned = $true; TimedOut = $false; ElapsedMs = $sw.ElapsedMilliseconds
            TimeoutMs = $TimeoutMs; Result = (Read-McpProbeResult -Raw $raw); Error = $null }
    }
    catch {
        $sw.Stop()
        return [pscustomobject]@{ Spawned = $true; TimedOut = $false; ElapsedMs = $sw.ElapsedMilliseconds
            TimeoutMs = $TimeoutMs; Result = (Read-McpProbeResult -Raw ''); Error = $_.Exception.Message }
    }
    finally { try { $p.Dispose() } catch { Write-Verbose "falha no Dispose do probe: $($_.Exception.Message)" } }
}

# --- I/O fino: orquestra o health-check completo -----------------------------------------------
function Invoke-SddDoctor {
    [CmdletBinding()]
    param(
        [string]$SettingsPath = (Join-Path $HOME '.claude/settings.json'),
        [string]$ClaudeJsonPath = (Join-Path $HOME '.claude.json')
    )
    $findings = [System.Collections.Generic.List[object]]::new()

    # 1. pwsh resolve no PATH? (o que o spawn nativo do hook precisa)
    $pw = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pw) {
        $findings.Add((New-DoctorFinding -Status ok -Check 'pwsh-no-path' -Message "pwsh resolve no PATH ($($pw.Version)) — $($pw.Source)"))
    }
    else {
        $findings.Add((New-DoctorFinding -Status fail -Check 'pwsh-no-path' -Message 'pwsh (bare) NAO resolve no PATH — o hook nativo `pwsh -File` nao spawna; os guards ficam inativos'))
    }

    # 2. settings instalado + guards registrados
    $cmds = Read-SettingsHookCommands -SettingsPath $SettingsPath
    if ($null -eq $cmds) {
        $findings.Add((New-DoctorFinding -Status fail -Check 'settings' -Message "settings.json nao encontrado em '$SettingsPath' — rode o onboarding (install.ps1)"))
        $arr = $findings.ToArray()
        return [pscustomobject]@{ Findings = $arr; AllOk = (Test-DoctorGate -Findings $arr); SettingsPath = $SettingsPath }
    }

    $known = @($cmds | Where-Object { $p = Get-HookPs1Path $_; $p -and (Get-GuardCheck $p) })
    if ($known.Count -eq 0) {
        $findings.Add((New-DoctorFinding -Status fail -Check 'hooks-registrados' -Message 'nenhum guard (secret/destructive) em hooks.PreToolUse do settings.json'))
    }
    else {
        $findings.Add((New-DoctorFinding -Status ok -Check 'hooks-registrados' -Message "$($known.Count) guard(s) em hooks.PreToolUse"))
    }

    # 3. dry-run sintetico de cada guard
    foreach ($cmd in $cmds) {
        $hookPath = Get-HookPs1Path $cmd
        if (-not $hookPath) { continue }
        $gc = Get-GuardCheck $hookPath
        if (-not $gc) { continue }   # hook desconhecido — sem payload sintetico

        if (-not (Test-Path -LiteralPath $hookPath -PathType Leaf)) {
            $findings.Add((New-DoctorFinding -Status fail -Check "guard:$($gc.Name)" -Message "arquivo do hook nao existe em disco: $hookPath"))
            continue
        }

        $r = Invoke-GuardDryRun -Ps1Path $hookPath -Payload $gc.Payload
        if ($r.Ran -and $r.Decision -eq $gc.Expect -and $gc.ExpectReasonMatch -and $r.Reason -notmatch $gc.ExpectReasonMatch) {
            $findings.Add((New-DoctorFinding -Status fail -Check "guard:$($gc.Name)" -Message "disparou ($($r.Decision)), mas a razao nao cita os dois guards -- um pode ter morrido dentro do dispatcher: '$($r.Reason)'"))
        }
        elseif ($r.Ran -and $r.Decision -eq $gc.Expect) {
            $findings.Add((New-DoctorFinding -Status ok -Check "guard:$($gc.Name)" -Message "dispara ($($r.Decision)) com payload sintetico"))
        }
        elseif ($r.Ran) {
            $findings.Add((New-DoctorFinding -Status fail -Check "guard:$($gc.Name)" -Message "NAO disparou como esperado (decisao='$($r.Decision)'; $($r.Error))"))
        }
        else {
            $findings.Add((New-DoctorFinding -Status fail -Check "guard:$($gc.Name)" -Message "NAO executou: $($r.Error)"))
        }
    }

    # 4. os MCPs que o NOSSO onboarding registra sobem e listam tools?
    # O passo 3 prova os guards; este fecha o mesmo raciocinio para o resto do que instalamos.
    foreach ($mcpName in (Get-FrameworkMcpNames)) {
        $srv = Read-RegisteredMcpServer -ClaudeJsonPath $ClaudeJsonPath -Name $mcpName
        if ($null -eq $srv) {
            $findings.Add((Get-McpFinding -Name $mcpName -Registered $false))
            continue
        }
        if ($srv.ReadError) {
            $findings.Add((New-DoctorFinding -Status fail -Check "mcp:$mcpName" `
                        -Message "nao deu para LER o registro em $ClaudeJsonPath -- sem saber se o MCP esta de pe: $($srv.ReadError)"))
            continue
        }
        $probe = Invoke-McpProbe -Command $srv.Command -ArgList $srv.Args
        $findings.Add((Get-McpFinding -Name $mcpName -Registered $true -Probe $probe))
    }

    $arr = $findings.ToArray()
    return [pscustomobject]@{ Findings = $arr; AllOk = (Test-DoctorGate -Findings $arr); SettingsPath = $SettingsPath }
}

# --- Guard: roda so quando NAO dot-sourced (Pester/commands fazem `. doctor.ps1`) --------------
if ($MyInvocation.InvocationName -ne '.') {
    $params = @{}
    if ($SettingsPath) { $params['SettingsPath'] = $SettingsPath }
    if ($ClaudeJsonPath) { $params['ClaudeJsonPath'] = $ClaudeJsonPath }
    $result = Invoke-SddDoctor @params
    Write-Host (Format-DoctorReport -Findings $result.Findings)
    exit ([int](-not $result.AllOk))
}

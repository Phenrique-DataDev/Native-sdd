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
    [string]$SettingsPath
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
            [pscustomobject]@{ Name = 'secret-guard'; Expect = 'ask'
                Payload = '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}' }
        }
        'destructive-guard.ps1' {
            [pscustomobject]@{ Name = 'destructive-guard'; Expect = 'ask'
                Payload = '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' }
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
        return [pscustomobject]@{ Ran = $false; Decision = $null; Error = 'arquivo do guard inexistente' }
    }
    try {
        $raw = ($Payload | & pwsh -NoProfile -File $Ps1Path 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [pscustomobject]@{ Ran = $true; Decision = $null; Error = 'sem saida (passthrough ou spawn sem efeito)' }
        }
        try {
            $obj = $raw | ConvertFrom-Json
            $dec = Get-PropOrNull (Get-PropOrNull $obj 'hookSpecificOutput') 'permissionDecision'
            return [pscustomobject]@{ Ran = $true; Decision = $dec; Error = $null }
        }
        catch {
            return [pscustomobject]@{ Ran = $true; Decision = $null; Error = "saida nao-JSON: $raw" }
        }
    }
    catch {
        return [pscustomobject]@{ Ran = $false; Decision = $null; Error = $_.Exception.Message }
    }
}

# --- I/O fino: orquestra o health-check completo -----------------------------------------------
function Invoke-SddDoctor {
    [CmdletBinding()]
    param(
        [string]$SettingsPath = (Join-Path $HOME '.claude/settings.json')
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
        if ($r.Ran -and $r.Decision -eq $gc.Expect) {
            $findings.Add((New-DoctorFinding -Status ok -Check "guard:$($gc.Name)" -Message "dispara ($($r.Decision)) com payload sintetico"))
        }
        elseif ($r.Ran) {
            $findings.Add((New-DoctorFinding -Status fail -Check "guard:$($gc.Name)" -Message "NAO disparou como esperado (decisao='$($r.Decision)'; $($r.Error))"))
        }
        else {
            $findings.Add((New-DoctorFinding -Status fail -Check "guard:$($gc.Name)" -Message "NAO executou: $($r.Error)"))
        }
    }

    $arr = $findings.ToArray()
    return [pscustomobject]@{ Findings = $arr; AllOk = (Test-DoctorGate -Findings $arr); SettingsPath = $SettingsPath }
}

# --- Guard: roda so quando NAO dot-sourced (Pester/commands fazem `. doctor.ps1`) --------------
if ($MyInvocation.InvocationName -ne '.') {
    $params = @{}
    if ($SettingsPath) { $params['SettingsPath'] = $SettingsPath }
    $result = Invoke-SddDoctor @params
    Write-Host (Format-DoctorReport -Findings $result.Findings)
    exit ([int](-not $result.AllOk))
}

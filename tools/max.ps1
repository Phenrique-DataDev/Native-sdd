<#
.SYNOPSIS
    /max (H6) — estado + aviso do MODO DE OPERAÇÃO MÁXIMA. Funções PURAS/I-O leve, sem motor.

.DESCRIPTION
    O modo MAX é uma POSTURA comportamental (rule max-mode.md): lê todo o contexto, reduz a fricção
    do não-crítico via o modo `auto` da SESSÃO, RECOMENDA potência (não seta), aciona o orquestrador.
    Decisão D-001 (context7 /anthropics/claude-code): hooks/settings carregam no INÍCIO da sessão e
    editar em runtime NÃO afeta a sessão corrente → o MAX **não** escreve permissions/settings/hooks.
    Os 4 guardas seguem ativos por construção (carregados no boot, intocados; deny>ask>allow).

    Este script só gerencia um FLAG de sessão (.claude/.cache/max-mode.json) — auxiliar de /max status,
    sobrevivência a compactação e telemetria; NÃO é lido por hook nenhum e NÃO controla permissão.
    Estado é FAIL-CLOSED + session-bound + TTL: qualquer erro/corrupção/staleness ⇒ desligado.

    Funções dot-sourceáveis para teste; o arquivo NÃO auto-executa (igual aos demais tools/*.ps1).
#>

Set-StrictMode -Version Latest

# Validade (horas) do flag de sessão: passada a janela, o modo é considerado desligado (não-persistência
# entre sessões). Afinável.
$script:MaxTtlHours = 8

# --- PURA: acesso seguro a propriedade sob StrictMode (PSCustomObject do ConvertFrom-Json) ------
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# --- PURA: coerção defensiva a [long] (epoch do JSON pode vir Int32/Int64/Double/string) --------
function ConvertTo-LongOrZero {
    param($Value)
    try { return [long]$Value } catch { return [long]0 }
}

# --- PURA: classes não-críticas (referência da postura; NÃO é escrita em settings — D-002) ------
function Get-NonCriticalClasses {
    <#
    .OUTPUTS [pscustomobject] { NonCritical=[string[]]; AlwaysCritical=[string[]] }
    .NOTES  Lista canônica usada no aviso e na conformância (AT-007). O enforcement real continua no
            modo `auto` da sessão + nos hooks (que vencem o allow). NUNCA aplicada a permissions.
    #>
    [pscustomobject]@{
        NonCritical    = @(
            'Read', 'Grep', 'Glob', 'LS',
            'Bash:read-only (ls, cat, rg, git status|diff|log, gh * list|view)'
        )
        AlwaysCritical = @(
            'escrita/edicao destrutiva',
            'git push | merge',
            'leitura de segredo (.env, secrets/**)',
            'rm -rf',
            'chmod -R / chown -R',
            'CLIs de dados/cloud destrutivas (DROP/TRUNCATE, aws s3 rm, terraform destroy)'
        )
    }
}

# --- I/O: caminho do flag de estado (único arquivo tocado; .gitignore cobre .cache/) ------------
function Get-MaxStatePath {
    param([Parameter(Mandatory)][string]$StateDir)
    return (Join-Path $StateDir 'max-mode.json')
}

# --- PURA: o flag expirou? (now >= expires_at). expires_at ausente/0 ⇒ expirado (fail-closed) ---
function Test-MaxExpired {
    param(
        [Parameter(Mandatory)][AllowNull()][psobject]$State,
        [long]$NowEpoch = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    )
    $exp = ConvertTo-LongOrZero (Get-PropOrNull $State 'ExpiresAt')
    if ($exp -le 0) { return $true }
    return [bool]($NowEpoch -ge $exp)
}

# --- I/O: liga o modo — grava flag + session_id + started/expires (cria dir; UTF-8 s/ BOM) ------
function Enable-MaxMode {
    <#
    .OUTPUTS [pscustomobject] { Enabled=$true; SessionId; StartedAt; ExpiresAt; Reason }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [AllowNull()][AllowEmptyString()][string]$SessionId = '',
        [int]$TtlHours = $script:MaxTtlHours,
        [long]$NowEpoch = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    )
    $expires = $NowEpoch + ([long]$TtlHours * 3600)
    $obj = [ordered]@{
        enabled    = $true
        session_id = [string]$SessionId
        started_at = $NowEpoch
        expires_at = $expires
    }
    try {
        if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) {
            New-Item -ItemType Directory -Path $StateDir -Force -ErrorAction Stop | Out-Null
        }
        $path = Get-MaxStatePath -StateDir $StateDir
        [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 4 -Compress), [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        # Falha de escrita é não-fatal: a postura ainda vale na conversa (o flag é auxiliar).
        Write-Verbose "max-mode flag não gravado: $($_.Exception.Message)"
    }
    return [pscustomobject]@{ Enabled = $true; SessionId = [string]$SessionId; StartedAt = $NowEpoch; ExpiresAt = $expires; Reason = 'ligado' }
}

# --- I/O: desliga o modo — grava enabled:false (idempotente; sem erro se ausente) ---------------
function Disable-MaxMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [long]$NowEpoch = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    )
    $obj = [ordered]@{ enabled = $false; session_id = ''; started_at = $NowEpoch; expires_at = $NowEpoch }
    try {
        if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) {
            New-Item -ItemType Directory -Path $StateDir -Force -ErrorAction Stop | Out-Null
        }
        $path = Get-MaxStatePath -StateDir $StateDir
        [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 4 -Compress), [System.Text.UTF8Encoding]::new($false))
    }
    catch { Write-Verbose "max-mode flag não limpo: $($_.Exception.Message)" }
    return [pscustomobject]@{ Enabled = $false; Reason = 'desligado' }
}

# --- I/O: lê o estado com DEFAULT FAIL-CLOSED -------------------------------------------------
function Get-MaxState {
    <#
    .OUTPUTS [pscustomobject] { Enabled; SessionId; StartedAt; ExpiresAt; Reason }
    .NOTES  Enabled=$false (lado seguro) quando: arquivo ausente | JSON inválido | enabled≠true |
            expirado (TTL) | SessionId fornecido e ≠ session_id do estado. Nunca lança.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [AllowNull()][AllowEmptyString()][string]$SessionId = '',
        [long]$NowEpoch = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    )
    function New-Off { param([string]$Reason) [pscustomobject]@{ Enabled = $false; SessionId = ''; StartedAt = [long]0; ExpiresAt = [long]0; Reason = $Reason } }

    $path = Get-MaxStatePath -StateDir $StateDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return (New-Off 'sem estado') }

    try { $o = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop) | ConvertFrom-Json }
    catch { return (New-Off 'estado corrompido') }

    if ((Get-PropOrNull $o 'enabled') -ne $true) { return (New-Off 'desligado') }

    $state = [pscustomobject]@{
        Enabled   = $true
        SessionId = [string](Get-PropOrNull $o 'session_id')
        StartedAt = ConvertTo-LongOrZero (Get-PropOrNull $o 'started_at')
        ExpiresAt = ConvertTo-LongOrZero (Get-PropOrNull $o 'expires_at')
        Reason    = 'ligado'
    }

    if (Test-MaxExpired -State $state -NowEpoch $NowEpoch) { return (New-Off 'expirado (TTL)') }

    if (-not [string]::IsNullOrEmpty($SessionId) -and -not [string]::IsNullOrEmpty($state.SessionId) -and ($SessionId -ne $state.SessionId)) {
        return (New-Off 'outra sessao')
    }
    return $state
}

# --- PURA: monta o AVISO obrigatório ao ligar (transparência — R6 do /doubt) -------------------
function Format-MaxNotice {
    <#
    .OUTPUTS [string] — bloco do aviso (reduzido / potência recomendada / contexto / GUARDAS ATIVOS).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][psobject]$State,
        [Parameter(Mandatory)][AllowNull()][psobject]$Classes,
        [AllowNull()][AllowEmptyString()][string]$ContextSummary = ''
    )
    $nc = @(Get-PropOrNull $Classes 'NonCritical')
    $ncTxt = if ($nc.Count -gt 0) { $nc -join ', ' } else { 'leitura/busca/navegacao' }
    $ctx = if ([string]::IsNullOrWhiteSpace($ContextSummary)) { '(bootstrap nao executado)' } else { $ContextSummary }

    # Validade do flag (do State) — reforça que o modo é session-bound + TTL (não persiste).
    $exp = ConvertTo-LongOrZero (Get-PropOrNull $State 'ExpiresAt')
    $validade = if ($exp -gt 0) { ([DateTimeOffset]::FromUnixTimeSeconds($exp)).LocalDateTime.ToString('yyyy-MM-dd HH:mm') } else { 'n/d' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('=== MODO MAX ATIVADO ===')
    $lines.Add('  Reduzido      : prompts de permissao do NAO-CRITICO (via modo auto da sessao)')
    $lines.Add("                  nao-critico: $ncTxt")
    $lines.Add('  Potencia      : RECOMENDADA (modelo maior + effort alto) -- nao setada a forca')
    $lines.Add("  Contexto      : $ctx")
    $lines.Add('  GUARDAS ATIVOS: main-push | secret | destructive | managed-deny (interceptam o critico)')
    $lines.Add('  Qualidade     : testes/lint/gates/fases SDD permanecem (nao sao relaxados)')
    $lines.Add("  Validade      : flag expira ~$validade (session-bound; nao persiste entre sessoes)")
    $lines.Add('  Desligar      : /max off')
    return ($lines -join [Environment]::NewLine)
}

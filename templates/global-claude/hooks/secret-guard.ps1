<#
.SYNOPSIS
    Hook PreToolUse (matcher "Bash") — guard de SEGREDOS em modo "ask" (educar, nao barrar).

.DESCRIPTION
    Irmao do destructive-guard. Em cada tool Bash decide:
      - comando le/exfiltra arquivo de segredo (cat/type/Get-Content .env, *.pem, secrets/…)
          -> permissionDecision "ask"  (fecha o bypass do `Read(.env)` da managed policy)
      - `git commit` cujo diff STAGED contem segredo de ALTA confianca -> "ask"
      - `git push`  cujo diff a ENVIAR contem segredo de ALTA confianca -> "ask"
      - qualquer outro caso                                          -> PASSTHROUGH (exit 0)

    Confidence no commit/push = 'High' (mesmo nivel do pre-commit deterministico): so
    formatos especificos de credencial (AKIA…, gh?_…, BEGIN PRIVATE KEY…, JWT). Assignments
    genericos (Medium) NAO viram prompt aqui — evitam falso-positivo em config/docs/testes.
    A leitura de arquivo de segredo (.env/chave) segue em "ask" independente de confidence.

    NUNCA usa "deny": apenas pede confirmacao. A rede DETERMINISTICA (bloqueio real) é o
    git pre-commit do scaffold (.githooks/secret-scan.ps1) + a managed policy. Este hook é a
    camada que ainda pega o segredo mesmo quando o pre-commit é pulado (`--no-verify`).

    Fail-safe ASSIMÉTRICO (igual ao destructive-guard): antes de confirmar que o comando é relevante,
    qualquer erro vira PASSTHROUGH; DEPOIS, qualquer erro vira "ask" — nunca silencia por engano.

    Deteccao vem da lib UNICA lib/secret-patterns.ps1 (dot-sourced). Schema do hook verificado
    via context7 (/websites/code_claude, 2026-06-07): igual ao destructive-guard.

    Funcoes puras sao dot-sourceaveis para teste; o fluxo so roda quando NAO é dot-sourced.
#>

Set-StrictMode -Version Latest

# Lib unica de deteccao (mesma pasta, sob lib/). Sem ela, o hook degrada para passthrough.
$script:SecretLib = Join-Path $PSScriptRoot 'lib/secret-patterns.ps1'
if (Test-Path -LiteralPath $script:SecretLib) { . $script:SecretLib }

# --- Acesso seguro a propriedade sob StrictMode (PSCustomObject do ConvertFrom-Json) ----------
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
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

# --- PURA: o comando é um `git <…> <sub>`? ----------------------------------------------------
function Test-IsGitSubcommand {
    param([string]$Command, [Parameter(Mandatory)][string]$Sub)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    foreach ($seg in [regex]::Split($Command, '&&|\|\||;|\r?\n|\|')) {
        if ($seg -match ('(?:^|\s)git\s+(?:\S+\s+)*' + [regex]::Escape($Sub) + '(?:\s|$)')) { return $true }
    }
    return $false
}

# --- PURA: o comando le/exfiltra um arquivo de segredo? ---------------------------------------
function Test-IsSecretRead {
    # Casa leitores comuns (cat/type/Get-Content/gc/bat/less/more/head/tail/strings) cujo
    # argumento aponta para um arquivo de segredo (Test-IsSecretFilePath, da lib).
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    if (-not (Get-Command Test-IsSecretFilePath -ErrorAction SilentlyContinue)) { return $false }
    $readers = '(?:cat|type|gc|Get-Content|bat|less|more|head|tail|strings|nl)'
    foreach ($seg in [regex]::Split($Command, '&&|\|\||;|\r?\n|\|')) {
        if ($seg -notmatch ('(?i)(?:^|\s)' + $readers + '\s')) { continue }
        # Tokeniza o segmento e testa cada token que pareca um caminho.
        foreach ($tok in ($seg -split '\s+')) {
            $t = $tok.Trim('"', "'")
            if ($t -and -not $t.StartsWith('-') -and (Test-IsSecretFilePath $t)) { return $true }
        }
    }
    return $false
}

# --- PURA: extrai as linhas ADICIONADAS de um diff unificado ----------------------------------
function Get-AddedLine {
    param([string]$DiffText)
    if ([string]::IsNullOrEmpty($DiffText)) { return '' }
    $added = foreach ($line in ($DiffText -split "`r?`n")) {
        if ($line.StartsWith('+') -and -not $line.StartsWith('+++')) { $line.Substring(1) }
    }
    return ($added -join "`n")
}

# --- I/O (read-only): diffs ------------------------------------------------------------------
function Get-StagedDiffText {
    try {
        $d = & git diff --cached --unified=0 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($d -join "`n")
    }
    catch { return $null }
}

function Get-PushDiffText {
    # Conteudo que o push levaria: diff do upstream..HEAD; sem upstream, usa a default.
    try {
        $d = & git diff --unified=0 '@{upstream}...HEAD' 2>$null
        if ($LASTEXITCODE -ne 0) {
            $def = 'main'
            try {
                $ref = & git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null
                if ($LASTEXITCODE -eq 0 -and $ref) { $def = (([string]$ref).Trim() -replace '^origin/', '') }
            }
            catch { $def = 'main' }
            $d = & git diff --unified=0 "$def...HEAD" 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
        }
        return ($d -join "`n")
    }
    catch { return $null }
}

# --- PURA: achados -> texto curto para o motivo do "ask" --------------------------------------
function Format-SecretReason {
    param([string]$Context, $Findings)
    $names = @($Findings | ForEach-Object { $_.Pattern } | Select-Object -Unique)
    $list = if ($names.Count -gt 0) { ($names -join ', ') } else { '(indeterminado)' }
    return "$Context contem possivel segredo ($list). Confirmacao exigida — revise antes de prosseguir."
}

# --- Fluxo principal --------------------------------------------------------------------------
function Invoke-SecretGuard {
    # 1) Ler payload (falha -> passthrough)
    try { $raw = [Console]::In.ReadToEnd() } catch { return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    try { $payload = $raw | ConvertFrom-Json } catch { return }

    # 2) Pre-condicoes (qualquer nao-match -> passthrough)
    if ((Get-PropOrNull $payload 'tool_name') -ne 'Bash') { return }
    $command = [string](Get-PropOrNull (Get-PropOrNull $payload 'tool_input') 'command')
    if ([string]::IsNullOrWhiteSpace($command)) { return }

    # Sem a lib de deteccao nao ha como decidir -> passthrough (degradacao graciosa).
    if (-not (Get-Command Find-SecretMatch -ErrorAction SilentlyContinue)) { return }

    # 3) Leitura/exfiltracao de arquivo de segredo (independe de git) -> ask
    if (Test-IsSecretRead $command) {
        Write-Output (New-HookDecisionJson -Decision 'ask' `
                -Reason 'Comando le um arquivo de segredo (.env/chave). Confirmacao exigida.')
        return
    }

    $isCommit = Test-IsGitSubcommand $command 'commit'
    $isPush   = Test-IsGitSubcommand $command 'push'
    if (-not $isCommit -and -not $isPush) { return }   # nao é relevante -> passthrough

    # 4) Daqui é relevante: erro = ask (fail-safe assimetrico)
    try {
        if ($isCommit) {
            $added = Get-AddedLine (Get-StagedDiffText)
            $findings = Find-SecretMatch -Text $added -MinConfidence 'High'
            if ($findings.Count -gt 0) {
                Write-Output (New-HookDecisionJson -Decision 'ask' -Reason (Format-SecretReason 'O commit (staged)' $findings))
                return
            }
        }
        if ($isPush) {
            $added = Get-AddedLine (Get-PushDiffText)
            $findings = Find-SecretMatch -Text $added -MinConfidence 'High'
            if ($findings.Count -gt 0) {
                Write-Output (New-HookDecisionJson -Decision 'ask' -Reason (Format-SecretReason 'O push' $findings))
                return
            }
        }
        # relevante mas sem segredo detectado -> passthrough (nao atrapalha)
    }
    catch {
        Write-Output (New-HookDecisionJson -Decision 'ask' `
                -Reason 'Nao foi possivel verificar segredos no diff. Confirmacao exigida.')
    }
}

# --- Guard: roda o fluxo so quando NAO dot-sourced (Pester faz `. secret-guard.ps1`) -----------
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-SecretGuard
}

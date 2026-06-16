<#
.SYNOPSIS
    Hook PreToolUse (C6) — guard determinístico de push na branch default.

.DESCRIPTION
    Registrado em ~/.claude/settings.json (hooks.PreToolUse, matcher "Bash"). Em cada tool Bash,
    decide:
      - comando ≠ `git push`  OU  branch ≠ default  -> PASSTHROUGH (exit 0, sem stdout)
      - na branch default, push SOMENTE-DOCS         -> permissionDecision "allow"
      - na branch default, push com ≥1 arquivo nao-doc -> permissionDecision "ask"

    Fail-safe ASSIMÉTRICO: antes de confirmar "push na default", qualquer erro vira PASSTHROUGH
    (não atrapalha comandos alheios); DEPOIS de confirmar, qualquer erro vira "ask" — nunca
    "allow" por engano.

    Critério de "doc" (fixado no DEFINE/DESIGN C6): extensão .md em qualquer lugar, OU path sob
    docs/ | methodology/ | features/.

    Schema do hook verificado via context7 (/anthropics/claude-code, 2026-06-04):
      saída  = { hookSpecificOutput: { hookEventName, permissionDecision, permissionDecisionReason }, systemMessage }
      stdin  = { tool_name, tool_input: { command }, ... }

    Funções puras (Test-IsGitPush / Test-IsDocPath / Get-PushDecision / New-HookDecisionJson) são
    dot-sourceáveis para teste; o fluxo só roda quando o script NÃO é dot-sourced (guard no fim).
#>

Set-StrictMode -Version Latest

# --- Acesso seguro a propriedade sob StrictMode (PSCustomObject do ConvertFrom-Json) ----------
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# --- PURA: o comando Bash é um `git … push`? --------------------------------------------------
function Test-IsGitPush {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    # Divide em segmentos por separadores de shell e testa cada um isoladamente.
    $segments = [regex]::Split($Command, '&&|\|\||;|\r?\n|\|')
    foreach ($seg in $segments) {
        # `git` seguido (tolerando flags/-C/remote) do subcomando `push` como palavra.
        if ($seg -match '(?:^|\s)git\s+(?:\S+\s+)*push(?:\s|$)') { return $true }
    }
    return $false
}

# --- PURA: o path é documentação? -------------------------------------------------------------
function Test-IsDocPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.Trim().Replace('\', '/')
    if ($p -match '\.md$') { return $true }                       # .md em qualquer lugar
    if ($p -match '^(docs|methodology|features)/') { return $true } # pastas de docs
    return $false
}

# --- PURA: paths -> decisão -------------------------------------------------------------------
function Get-PushDecision {
    param([string[]]$ChangedPaths)
    if ($null -eq $ChangedPaths -or $ChangedPaths.Count -eq 0) {
        return [pscustomobject]@{ Decision = 'ask'; NonDocs = @() }   # fail-safe
    }
    $nonDocs = @($ChangedPaths | Where-Object { -not (Test-IsDocPath $_) })
    if ($nonDocs.Count -eq 0) {
        return [pscustomobject]@{ Decision = 'allow'; NonDocs = @() }
    }
    return [pscustomobject]@{ Decision = 'ask'; NonDocs = $nonDocs }
}

# --- PURA: monta o JSON da decisão ------------------------------------------------------------
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

# --- I/O (read-only): branch atual / default / paths a enviar ---------------------------------
function Get-CurrentBranch {
    try {
        $b = (& git rev-parse --abbrev-ref HEAD 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
        return ([string]$b).Trim()
    }
    catch { return $null }
}

function Get-DefaultBranch {
    try {
        $ref = (& git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $ref) {
            return (([string]$ref).Trim() -replace '^origin/', '')
        }
    }
    catch { Write-Verbose "default branch indeterminada; fallback 'main' ($_)" }
    return 'main'   # fallback conservador
}

function Get-PushPaths {
    # Arquivos que o push levaria: diff do merge-base(upstream,HEAD)..HEAD. Sem upstream, usa a
    # default. Qualquer falha -> $null (o chamador converte em "ask").
    try {
        $paths = & git diff --name-only '@{upstream}...HEAD' 2>$null
        if ($LASTEXITCODE -ne 0) {
            $def = Get-DefaultBranch
            $paths = & git diff --name-only "$def...HEAD" 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
        }
        $list = @($paths | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() })
        return , $list
    }
    catch { return $null }
}

# --- Fluxo principal --------------------------------------------------------------------------
function Invoke-MainPushGuard {
    # 1) Ler payload (falha de leitura/parse -> passthrough)
    try { $raw = [Console]::In.ReadToEnd() } catch { return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    try { $payload = $raw | ConvertFrom-Json } catch { return }

    # 2) Pré-condições (qualquer não-match -> passthrough)
    if ((Get-PropOrNull $payload 'tool_name') -ne 'Bash') { return }
    $command = [string](Get-PropOrNull (Get-PropOrNull $payload 'tool_input') 'command')
    if (-not (Test-IsGitPush $command)) { return }

    $current = Get-CurrentBranch
    $default = Get-DefaultBranch
    if (-not $current -or -not $default -or ($current -ne $default)) { return }

    # 3) Estamos na default com um `git push` -> decidir (daqui, erro = ask)
    try {
        $decision = Get-PushDecision (Get-PushPaths)
        if ($decision.Decision -eq 'allow') {
            Write-Output (New-HookDecisionJson -Decision 'allow' `
                    -Reason "push somente-docs na '$default': liberado.")
        }
        else {
            $list = if ($decision.NonDocs.Count -gt 0) { ($decision.NonDocs -join ', ') } else { '(indeterminado)' }
            Write-Output (New-HookDecisionJson -Decision 'ask' `
                    -Reason "push na '$default' com arquivos nao-doc: $list. Confirmacao exigida.")
        }
    }
    catch {
        Write-Output (New-HookDecisionJson -Decision 'ask' `
                -Reason "push na '$default': nao foi possivel verificar o diff. Confirmacao exigida.")
    }
}

# --- Guard: roda o fluxo só quando NÃO dot-sourced (Pester faz `. main-push-guard.ps1`) --------
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-MainPushGuard
}

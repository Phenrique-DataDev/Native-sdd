# install-mcp.ps1 — registra o context7 como MCP user-scoped (transporte local npx).
# Passo OPCIONAL e NÃO bloqueante (A8 / fecha J1): qualquer falha vira WARN, nunca Failed —
# A1 (CLIs) e A2 (baseline ~/.claude) permanecem intactos.
# Requer que lib.ps1 já esteja carregado (Test-CommandExists, Write-Step).
# Compatível com Windows PowerShell 5.1+ e PowerShell 7+.

Set-StrictMode -Version Latest

function Get-Context7Plan {
    <#
    .SYNOPSIS
        Decide (puro) o que fazer com o registro do context7, a partir do ambiente.
    .OUTPUTS
        [pscustomobject] @{ Action = 'add'|'skip'|'warn'; Args = [string[]]; Reason = [string] }
        - Args só é preenchido em 'add' (pronto p/ splatting: claude @Args).
        - Reason NUNCA contém o valor da API key (a key vai só nos Args).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$ClaudePresent,
        [Parameter(Mandatory)][bool]$NpxPresent,
        [Parameter(Mandatory)][bool]$AlreadyRegistered,
        [AllowEmptyString()][string]$ApiKey = ''
    )

    if (-not $ClaudePresent) {
        return [pscustomobject]@{
            Action = 'warn'; Args = @()
            Reason = 'Claude Code (claude) ausente — pulei o context7; registre depois com: claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp'
        }
    }
    if (-not $NpxPresent) {
        return [pscustomobject]@{
            Action = 'warn'; Args = @()
            Reason = 'npx/Node ausente — pulei o context7 (transporte local precisa de npx)'
        }
    }
    if ($AlreadyRegistered) {
        return [pscustomobject]@{
            Action = 'skip'; Args = @()
            Reason = 'context7 já registrado (user scope)'
        }
    }

    $cmdArgs = @('mcp', 'add', '--scope', 'user', 'context7', '--', 'npx', '-y', '@upstash/context7-mcp')
    $reason = 'registrar context7 via npx (transporte local, user scope)'
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $cmdArgs += @('--api-key', $ApiKey)
        $reason = 'registrar context7 via npx (transporte local, user scope) com API key do ambiente'
    }

    return [pscustomobject]@{ Action = 'add'; Args = $cmdArgs; Reason = $reason }
}

function Get-MaskedArgs {
    <#
    .SYNOPSIS
        Versão dos args com o valor da --api-key mascarado, para log/DryRun (não vaza segredo).
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgList)

    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        $out.Add($ArgList[$i])
        if ($ArgList[$i] -eq '--api-key' -and $i + 1 -lt $ArgList.Count) {
            $out.Add('***'); $i++
        }
    }
    return ($out -join ' ')
}

function Invoke-Context7Setup {
    <#
    .SYNOPSIS
        Executa o plano do context7 (wrapper com efeito colateral). Nunca lança; falha = WARN.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [switch]$Check,
        [switch]$DryRun
    )

    $claudePresent = Test-CommandExists 'claude'
    $npxPresent    = Test-CommandExists 'npx'

    # "Já registrado?" só faz sentido se o claude existe; read-only via exit code.
    $already = $false
    if ($claudePresent) {
        try {
            claude mcp get context7 2>&1 | Out-Null
            $already = ($LASTEXITCODE -eq 0)
        }
        catch { $already = $false }
    }

    $apiKey = if ($env:CONTEXT7_API_KEY) { $env:CONTEXT7_API_KEY } else { '' }

    $plan = Get-Context7Plan -ClaudePresent $claudePresent -NpxPresent $npxPresent `
        -AlreadyRegistered $already -ApiKey $apiKey

    switch ($plan.Action) {
        'skip' {
            Write-Step SKIP "context7: $($plan.Reason)"
            $Summary.Skipped++
            return
        }
        'warn' {
            Write-Step WARN "context7: $($plan.Reason)"
            $Summary.Warn++
            return
        }
        'add' {
            $masked = Get-MaskedArgs -ArgList $plan.Args
            if ($Check)  { Write-Step INFO "context7: $($plan.Reason)"; return }
            if ($DryRun) { Write-Step DRY  "claude $masked"; return }

            try {
                claude @($plan.Args) 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Step OK "context7 registrado (claude $masked)"
                    $Summary.Installed++
                }
                else {
                    # NÃO bloqueante: registra WARN e segue (A1/A2 intactos).
                    Write-Step WARN "context7: 'claude mcp add' retornou $LASTEXITCODE — registre manualmente depois"
                    $Summary.Warn++
                }
            }
            catch {
                Write-Step WARN "context7: falha ao registrar — $($_.Exception.Message)"
                $Summary.Warn++
            }
        }
    }
}

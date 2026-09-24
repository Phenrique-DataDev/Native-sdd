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
    .DESCRIPTION
        Duas formas de transporte local, nesta ordem de preferência:

          1. `<node> <entrypoint>` — quando o pacote já está resolvido em disco. É a forma RÁPIDA.
          2. `npx -y @upstash/context7-mcp` — fallback, quando não há entrypoint resolvido.

        Por que a ordem: o `-y` faz o npx consultar o registry A CADA inicialização, e isso entra
        no orçamento de 30s que o cliente dá ao connect do MCP. Medido em 2026-09-18 com o probe do
        `tools/doctor.ps1`, 3 execuções por rota na mesma máquina e mesmo servidor:

          npx -y  : 17.264 ms (1ª execução, cache do npm frio) · 2.719 ms · 2.679 ms
          node    :    582 ms ·   625 ms ·   621 ms

        A 1ª execução é justamente a da máquina recém-onboardada, e sozinha consome 58% do
        orçamento. Foi assim que o context7 do próprio autor caiu em CONNECT_TIMEOUT com o
        registro que ESTE script produzia.

        O fallback fica: `npx` continua sendo o caminho portável quando o pacote não está em disco,
        e perder o context7 seria pior que registrá-lo lento.
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
        [AllowEmptyString()][string]$ApiKey = '',
        # Caminho do executável do node e do entrypoint .js já resolvidos em disco. Os dois vazios
        # (ou só um deles) => cai no npx. Quem resolve é o wrapper de I/O; aqui é decisão pura.
        [AllowEmptyString()][string]$NodeCommand = '',
        [AllowEmptyString()][string]$Entrypoint = ''
    )

    $temEntrypoint = -not [string]::IsNullOrWhiteSpace($NodeCommand) -and
                     -not [string]::IsNullOrWhiteSpace($Entrypoint)

    if (-not $ClaudePresent) {
        return [pscustomobject]@{
            Action = 'warn'; Args = @()
            Reason = 'Claude Code (claude) ausente — pulei o context7; registre depois com: claude mcp add --scope user context7 -- npx -y @upstash/context7-mcp'
        }
    }
    # Sem entrypoint resolvido o npx é o único transporte que sobra; com ele, o npx é dispensável.
    if (-not $NpxPresent -and -not $temEntrypoint) {
        return [pscustomobject]@{
            Action = 'warn'; Args = @()
            Reason = 'npx/Node ausente — pulei o context7 (transporte local precisa de npx ou do pacote resolvido em disco)'
        }
    }
    if ($AlreadyRegistered) {
        return [pscustomobject]@{
            Action = 'skip'; Args = @()
            Reason = 'context7 já registrado (user scope)'
        }
    }

    if ($temEntrypoint) {
        $cmdArgs = @('mcp', 'add', '--scope', 'user', 'context7', '--', $NodeCommand, $Entrypoint)
        $reason  = 'registrar context7 por entrypoint resolvido (transporte local, user scope, sem npx no caminho)'
    }
    else {
        $cmdArgs = @('mcp', 'add', '--scope', 'user', 'context7', '--', 'npx', '-y', '@upstash/context7-mcp')
        $reason  = 'registrar context7 via npx (transporte local, user scope)'
    }
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        # Forma de DOIS tokens de propósito: é a única que Get-MaskedArgs sabe mascarar (AT-MCP-09).
        $cmdArgs += @('--api-key', $ApiKey)
        $reason  += ' com API key do ambiente'
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

function Get-Context7Entrypoint {
    <#
    .SYNOPSIS
        Resolve (I/O) o entrypoint .js do context7 no node_modules global. '' = não resolvido.
    .DESCRIPTION
        Portável nos 3 SOs de propósito: `npm root -g` devolve o diretório global de cada
        plataforma (Windows: %APPDATA%\npm\node_modules; Unix: <prefix>/lib/node_modules), então
        nada aqui hardcoda caminho de SO — foi o modo de falha de SUPPLEMENTS_USERPROFILE_FORA_DO_WINDOWS.

        Não instala nada: só olha. Quem decide instalar é o wrapper, e a falta de entrypoint é um
        fallback legítimo (npx), não um erro.
    #>
    [CmdletBinding()]
    param([switch]$Install)

    if (-not (Test-CommandExists 'npm')) { return '' }

    if ($Install) {
        try { npm install -g '@upstash/context7-mcp' 2>&1 | Out-Null } catch { return '' }
    }

    $root = ''
    try { $root = (npm root -g 2>$null | Select-Object -First 1) } catch { return '' }
    if ([string]::IsNullOrWhiteSpace($root)) { return '' }

    $entry = Join-Path $root '@upstash/context7-mcp/dist/index.js'
    if (Test-Path -LiteralPath $entry -PathType Leaf) { return $entry }
    return ''
}

function Get-NodeCommandPath {
    <#
    .SYNOPSIS
        Caminho ABSOLUTO do executável do node. '' se não resolve.
    .DESCRIPTION
        Absoluto de propósito: o MCP é spawnado sem shell de login, então um `node` que só existe
        no PATH interativo não serve. Mesmo motivo pelo qual o probe do /doctor precisou do
        Resolve-McpCommand.
    #>
    [CmdletBinding()] param()
    $n = @(Get-Command -Name 'node' -CommandType Application -ErrorAction SilentlyContinue)
    if ($n.Count -gt 0) { return $n[0].Source }
    return ''
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

    # Resolve o transporte rapido ANTES de planejar. -Check/-DryRun nao instalam nada: so olham
    # o que ja existe, senao um "mostre o que aconteceria" mexeria na maquina.
    $node  = Get-NodeCommandPath
    $entry = ''
    if ($claudePresent -and -not $already) {
        $entry = Get-Context7Entrypoint -Install:(-not ($Check -or $DryRun))
    }

    $plan = Get-Context7Plan -ClaudePresent $claudePresent -NpxPresent $npxPresent `
        -AlreadyRegistered $already -ApiKey $apiKey -NodeCommand $node -Entrypoint $entry

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

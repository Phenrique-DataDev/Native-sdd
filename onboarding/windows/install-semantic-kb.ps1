# install-semantic-kb.ps1 — registra o MCP "semantic-kb" (busca semântica local via Ollama +
# sqlite-vec) user-scoped. Passo OPT-IN (-WithSemanticKb) e NÃO bloqueante: qualquer falha vira
# WARN, nunca Failed — A1 (CLIs) e A2 (baseline ~/.claude) permanecem intactos. Molde direto de
# install-local-ai.ps1 — mesma disciplina, sem a checagem de VRAM (modelo de embedding é leve,
# ~274MB, não precisa de aviso de hardware).
# O servidor versionado vive em onboarding/semantic-kb/ (server.py + pyproject.toml).
# Opt-in INDEPENDENTE do local-ai — ambos usam Ollama, mas baixam modelos diferentes (embedding
# vs. chat) e são registrados como MCPs separados (ver .claude/sdd/features/DESIGN_RAG_HIBRIDO.md).
# Requer que lib.ps1 já esteja carregado (Test-CommandExists, Write-Step).
# Compatível com Windows PowerShell 5.1+ e PowerShell 7+.

Set-StrictMode -Version Latest

$script:SemanticKbDefaultModel = 'nomic-embed-text'
$script:SemanticKbOllamaHost   = 'http://localhost:11434'

function Get-SemanticKbRegisterArgs {
    <#
    .SYNOPSIS
        Monta (puro) os args de `claude mcp add` para o MCP semantic-kb. Pronto p/ splatting.
    .OUTPUTS
        [string[]] — ex.: 'mcp','add','--scope','user','semantic-kb','-e','EMBED_MODEL=...', '--','uv',...
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerDir,
        [string]$Model = $script:SemanticKbDefaultModel,
        [string]$OllamaHost = $script:SemanticKbOllamaHost
    )
    return @(
        'mcp', 'add', '--scope', 'user', 'semantic-kb',
        '-e', "EMBED_MODEL=$Model",
        '-e', "OLLAMA_HOST=$OllamaHost",
        '--', 'uv', 'run', '--directory', $ServerDir, 'server.py'
    )
}

function Get-SemanticKbPlan {
    <#
    .SYNOPSIS
        Decide (puro) o plano de provisionamento do semantic-kb a partir do ambiente. Mesmo
        formato de Get-LocalAiPlan (install-local-ai.ps1) — sem campo de hardware/VRAM.
    .OUTPUTS
        [pscustomobject] com:
          Register : 'add'|'skip'|'block'   registrar o MCP, já registrado, ou impossível
          Sync     : 'sync'|'block'         rodar `uv sync` no ServerDir, ou impossível (sem uv)
          Pull      : 'pull'|'skip'|'defer'  baixar o modelo, já presente, ou adiar (Ollama não utilizável)
          Ollama    : 'ok'|'stopped'|'missing'  eco do -OllamaState recebido
          Reason    : [string]              resumo legível (sem segredos — não há)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$ClaudePresent,
        [Parameter(Mandatory)][bool]$UvPresent,
        # 'stopped' (CLI presente, serviço parado) é um estado de PRIMEIRA CLASSE, não um detalhe:
        # era ele que, colapsado em "presente", produzia o pull inútil e o WARN mentiroso.
        # Ver Get-OllamaState em lib.ps1 para o histórico completo.
        [Parameter(Mandatory)][ValidateSet('ok', 'stopped', 'missing')][string]$OllamaState,
        [Parameter(Mandatory)][bool]$ModelPresent,
        [Parameter(Mandatory)][bool]$AlreadyRegistered
    )

    $sync = if ($UvPresent) { 'sync' } else { 'block' }

    # Só com o serviço no ar o $ModelPresent significa alguma coisa: com ele parado, `ollama list`
    # falha e "não achei o modelo" é indistinguível de "não consegui perguntar". Adiar é a única
    # resposta honesta — e o pull não funcionaria mesmo.
    $pull =
        if ($OllamaState -ne 'ok') { 'defer' }
        elseif ($ModelPresent)     { 'skip' }
        else                       { 'pull' }

    $register =
        if (-not $ClaudePresent)   { 'block' }
        elseif (-not $UvPresent)   { 'block' }
        elseif ($AlreadyRegistered){ 'skip' }
        else                       { 'add' }

    $reasons = @()
    if (-not $UvPresent)     { $reasons += 'uv ausente (transporte do server)' }
    if (-not $ClaudePresent) { $reasons += 'claude ausente' }
    if ($OllamaState -eq 'missing') { $reasons += 'Ollama ausente (instale: winget install Ollama.Ollama)' }
    if ($OllamaState -eq 'stopped') { $reasons += 'Ollama instalado mas fora do ar (inicie: ollama serve)' }
    $reason = if ($reasons.Count -gt 0) { $reasons -join ' · ' } else { 'ambiente pronto' }

    return [pscustomobject]@{
        Register = $register
        Sync     = $sync
        Pull     = $pull
        Ollama   = $OllamaState
        Reason   = $reason
    }
}

function Test-SemanticKbModelPresent {
    <#
    .SYNOPSIS
        Read-only: o modelo de embedding já está baixado no Ollama? (via `ollama list`).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Model)
    if (-not (Test-CommandExists 'ollama')) { return $false }
    try {
        $out = ollama list 2>$null | Out-String
        return ($LASTEXITCODE -eq 0 -and $out -match [regex]::Escape($Model))
    }
    catch { return $false }
}

function Invoke-SemanticKbSetup {
    <#
    .SYNOPSIS
        Executa o plano do semantic-kb (wrapper com efeito colateral). Nunca lança; falha =
        WARN. Opt-in: só é chamado quando o orquestrador recebe -WithSemanticKb.
    .NOTES
        Passos (todos não-bloqueantes, na ordem): uv sync → ollama pull → claude mcp add.
        O registro do MCP NÃO exige o Ollama no ar — o server degrada com mensagem amigável
        em runtime se o serviço/modelo faltar (ver onboarding/semantic-kb/server.py). O pull do
        modelo é leve (~274MB, bem menor que os modelos de chat do local-ai) mas só roda fora
        de -Check/-DryRun e quando o Ollama está presente.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [Parameter(Mandatory)][string]$ServerDir,
        [string]$Model = $script:SemanticKbDefaultModel,
        [string]$OllamaHost = $script:SemanticKbOllamaHost,
        [switch]$Check,
        [switch]$DryRun
    )

    if (-not (Test-Path -LiteralPath $ServerDir -PathType Container)) {
        Write-Step WARN "semantic-kb: server não encontrado em $ServerDir — reinstale o onboarding"
        $Summary.Warn++
        return
    }

    $claudePresent = Test-CommandExists 'claude'
    $uvPresent     = Test-CommandExists 'uv'
    $ollamaState   = Get-OllamaState -CliPresent (Test-CommandExists 'ollama') `
        -Serving (Test-OllamaServing -OllamaHost $OllamaHost)
    # Só consulta o modelo quando a resposta é confiável (serviço no ar) — ver Get-SemanticKbPlan.
    $modelPresent  = if ($ollamaState -eq 'ok') { Test-SemanticKbModelPresent -Model $Model } else { $false }

    $already = $false
    if ($claudePresent) {
        try {
            claude mcp get semantic-kb 2>&1 | Out-Null
            $already = ($LASTEXITCODE -eq 0)
        }
        catch { $already = $false }
    }

    $plan = Get-SemanticKbPlan -ClaudePresent $claudePresent -UvPresent $uvPresent `
        -OllamaState $ollamaState -ModelPresent $modelPresent -AlreadyRegistered $already

    $hostNote = if ($OllamaHost -ne $script:SemanticKbOllamaHost) { " · host: $OllamaHost" } else { '' }
    Write-Step INFO "semantic-kb: $($plan.Reason) (modelo: $Model$hostNote)"

    # --- Ollama (CLI/serviço) — só avisa; o registro não depende dele -------
    if ($plan.Ollama -eq 'missing') {
        Write-Step WARN 'semantic-kb: Ollama ausente — instale (winget install Ollama.Ollama) e rode `ollama serve`'
        $Summary.Warn++
    }
    elseif ($plan.Ollama -eq 'stopped') {
        Write-Step WARN "semantic-kb: Ollama instalado mas não responde em $OllamaHost — inicie o serviço (``ollama serve``) e rode de novo; o modelo pode já estar baixado"
        $Summary.Warn++
    }

    # --- uv sync (instala deps do server no diretório versionado) -----------
    switch ($plan.Sync) {
        'block' {
            Write-Step WARN 'semantic-kb: uv ausente — não dá p/ preparar o server (instale o uv) — pulei sync e registro'
            $Summary.Warn++
            return
        }
        'sync' {
            if ($Check)      { Write-Step INFO "semantic-kb: uv sync em $ServerDir" }
            elseif ($DryRun) { Write-Step DRY  "uv sync --directory `"$ServerDir`"" }
            else {
                try {
                    Push-Location -LiteralPath $ServerDir
                    try { uv sync 2>&1 | Out-Null } finally { Pop-Location }
                    if ($LASTEXITCODE -eq 0) {
                        Write-Step OK 'semantic-kb: deps do server instaladas (uv sync)'
                    }
                    else {
                        Write-Step WARN "semantic-kb: 'uv sync' retornou $LASTEXITCODE — rode manualmente em $ServerDir"
                        $Summary.Warn++
                    }
                }
                catch {
                    Write-Step WARN "semantic-kb: falha no uv sync — $($_.Exception.Message)"
                    $Summary.Warn++
                }
            }
        }
    }

    # --- ollama pull (modelo de embedding) — leve; só real, fora de Check/DryRun
    switch ($plan.Pull) {
        'defer' { } # já avisado acima (Ollama ausente ou fora do ar)
        'skip'  { Write-Step SKIP "semantic-kb: modelo $Model já baixado" ; $Summary.Skipped++ }
        'pull'  {
            if ($Check)      { Write-Step INFO "semantic-kb: baixaria o modelo $Model (ollama pull)" }
            elseif ($DryRun) { Write-Step DRY  "ollama pull $Model" }
            else {
                Write-Step RUN "semantic-kb: baixando modelo $Model..."
                try {
                    ollama pull $Model 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Step OK "semantic-kb: modelo $Model baixado"
                    }
                    else {
                        Write-Step WARN "semantic-kb: 'ollama pull $Model' retornou $LASTEXITCODE — baixe manualmente depois"
                        $Summary.Warn++
                    }
                }
                catch {
                    Write-Step WARN "semantic-kb: falha no pull do modelo — $($_.Exception.Message)"
                    $Summary.Warn++
                }
            }
        }
    }

    # --- claude mcp add (registro user-scoped) ------------------------------
    switch ($plan.Register) {
        'block' {
            Write-Step WARN 'semantic-kb: claude/uv ausente — pulei o registro do MCP (registre depois)'
            $Summary.Warn++
        }
        'skip' {
            Write-Step SKIP 'semantic-kb: MCP já registrado (user scope) — reinicie o Claude Code p/ recarregar'
            $Summary.Skipped++
        }
        'add' {
            $regArgs = Get-SemanticKbRegisterArgs -ServerDir $ServerDir -Model $Model -OllamaHost $OllamaHost
            if ($Check)      { Write-Step INFO 'semantic-kb: registraria o MCP (user scope)'; return }
            if ($DryRun)     { Write-Step DRY  "claude $($regArgs -join ' ')"; return }
            try {
                claude @regArgs 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Step OK 'semantic-kb registrado (reinicie o Claude Code para carregar o MCP)'
                    $Summary.Installed++
                }
                else {
                    Write-Step WARN "semantic-kb: 'claude mcp add' retornou $LASTEXITCODE — registre manualmente depois"
                    $Summary.Warn++
                }
            }
            catch {
                Write-Step WARN "semantic-kb: falha ao registrar — $($_.Exception.Message)"
                $Summary.Warn++
            }
        }
    }
}

# install-local-ai.ps1 — registra o MCP "local-ai" (modelo local via Ollama) user-scoped.
# Passo OPT-IN (-WithLocalAi) e NÃO bloqueante: qualquer falha vira WARN, nunca Failed —
# A1 (CLIs) e A2 (baseline ~/.claude) permanecem intactos. Mesma disciplina do install-mcp.ps1.
# O servidor versionado vive em onboarding/local-ai/ (server.py + pyproject.toml).
# Requer que lib.ps1 já esteja carregado (Test-CommandExists, Write-Step).
# Compatível com Windows PowerShell 5.1+ e PowerShell 7+.

Set-StrictMode -Version Latest

$script:LocalAiDefaultModel = 'gpt-oss:20b'
$script:LocalAiOllamaHost   = 'http://localhost:11434'

function Get-LocalAiRegisterArgs {
    <#
    .SYNOPSIS
        Monta (puro) os args de `claude mcp add` para o MCP local-ai. Pronto p/ splatting.
    .OUTPUTS
        [string[]] — ex.: 'mcp','add','--scope','user','local-ai','-e','CODE_MODEL=...', '--','uv',...
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerDir,
        [string]$Model = $script:LocalAiDefaultModel,
        [string]$OllamaHost = $script:LocalAiOllamaHost
    )
    return @(
        'mcp', 'add', '--scope', 'user', 'local-ai',
        '-e', "CODE_MODEL=$Model",
        '-e', "SECURITY_MODEL=$Model",
        '-e', "GENERAL_MODEL=$Model",
        '-e', "OLLAMA_HOST=$OllamaHost",
        '--', 'uv', 'run', '--directory', $ServerDir, 'server.py'
    )
}

function Get-LocalAiPlan {
    <#
    .SYNOPSIS
        Decide (puro) o plano de provisionamento do local-ai a partir do ambiente.
    .OUTPUTS
        [pscustomobject] com:
          Register : 'add'|'skip'|'block'   registrar o MCP, já registrado, ou impossível
          Sync     : 'sync'|'block'         rodar `uv sync` no ServerDir, ou impossível (sem uv)
          Pull      : 'pull'|'skip'|'defer'  baixar o modelo, já presente, ou adiar (ollama ausente)
          Ollama    : 'ok'|'missing'         serviço/CLI presente
          Reason    : [string]              resumo legível (sem segredos — não há)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$ClaudePresent,
        [Parameter(Mandatory)][bool]$UvPresent,
        [Parameter(Mandatory)][bool]$OllamaPresent,
        [Parameter(Mandatory)][bool]$ModelPresent,
        [Parameter(Mandatory)][bool]$AlreadyRegistered
    )

    $ollama = if ($OllamaPresent) { 'ok' } else { 'missing' }
    $sync   = if ($UvPresent) { 'sync' } else { 'block' }

    $pull =
        if (-not $OllamaPresent) { 'defer' }
        elseif ($ModelPresent)   { 'skip' }
        else                     { 'pull' }

    $register =
        if (-not $ClaudePresent)   { 'block' }
        elseif (-not $UvPresent)   { 'block' }
        elseif ($AlreadyRegistered){ 'skip' }
        else                       { 'add' }

    $reasons = @()
    if (-not $UvPresent)     { $reasons += 'uv ausente (transporte do server)' }
    if (-not $ClaudePresent) { $reasons += 'claude ausente' }
    if (-not $OllamaPresent) { $reasons += 'Ollama ausente (instale: winget install Ollama.Ollama)' }
    $reason = if ($reasons.Count -gt 0) { $reasons -join ' · ' } else { 'ambiente pronto' }

    return [pscustomobject]@{
        Register = $register
        Sync     = $sync
        Pull     = $pull
        Ollama   = $ollama
        Reason   = $reason
    }
}

function Test-LocalAiModelPresent {
    <#
    .SYNOPSIS
        Read-only: o modelo já está baixado no Ollama? (consulta /api/tags via CLI).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Model)
    if (-not (Test-CommandExists 'ollama')) { return $false }
    try {
        $out = ollama list 2>$null | Out-String
        # 'ollama list' lista 'NAME' como '<modelo>:<tag>'. Match pelo nome exato pedido.
        return ($LASTEXITCODE -eq 0 -and $out -match [regex]::Escape($Model))
    }
    catch { return $false }
}

function Get-LocalAiModelMinVramGB {
    <#
    .SYNOPSIS
        Estima (puro) a VRAM recomendada (GB) p/ um modelo, pelo nº de bilhões de parâmetros
        no nome (~0.7 GB/bilhão em quantização Q4). Heurística conservadora; nome sem "<N>b"
        reconhecível -> 0 (desconhecido, não avisa). MoE (ex.: gpt-oss) ainda precisa caber
        inteiro na memória, então a estimativa por params totais segue válida.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Model)
    if ($Model -match '(\d+(?:\.\d+)?)\s*b\b') {
        $params = [double]$Matches[1]
        return [int][math]::Max(4, [math]::Round($params * 0.7))
    }
    return 0
}

function Get-NvidiaVramGB {
    <#
    .SYNOPSIS
        Lê (efeito) a VRAM total da 1ª GPU NVIDIA via nvidia-smi. Retorna [int] GB, ou 0 quando
        desconhecida (sem nvidia-smi / GPU AMD/Intel / CPU-only) — detecção best-effort.
    #>
    if (-not (Test-CommandExists 'nvidia-smi')) { return 0 }
    try {
        $out = nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
        if ($LASTEXITCODE -eq 0 -and "$out" -match '(\d+)') {
            return [int][math]::Round([double]$Matches[1] / 1024)
        }
    }
    catch { return 0 }   # detecção best-effort: qualquer falha = VRAM desconhecida
    return 0
}

function Get-LocalAiVramWarning {
    <#
    .SYNOPSIS
        Monta (puro) o aviso quando a VRAM detectada (>0) é menor que o mínimo do modelo.
        VRAM/min em 0 = desconhecido -> $null (não avisa). Retorna [string] ou $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DetectedVramGB,
        [Parameter(Mandatory)][int]$MinVramGB,
        [Parameter(Mandatory)][string]$Model
    )
    if ($DetectedVramGB -le 0 -or $MinVramGB -le 0) { return $null }
    if ($DetectedVramGB -ge $MinVramGB) { return $null }
    return ("GPU com ~$DetectedVramGB GB de VRAM < ~$MinVramGB GB sugeridos p/ '$Model'. O modelo será " +
        'baixado, mas pode rodar lento ou falhar — considere -LocalAiModel menor (ex.: qwen2.5-coder:7b).')
}

function Invoke-LocalAiSetup {
    <#
    .SYNOPSIS
        Executa o plano do local-ai (wrapper com efeito colateral). Nunca lança; falha = WARN.
        Opt-in: só é chamado quando o orquestrador recebe -WithLocalAi.
    .NOTES
        Passos (todos não-bloqueantes, na ordem): uv sync → ollama pull → claude mcp add.
        O registro do MCP NÃO exige o Ollama no ar — o server degrada com mensagem amigável
        em runtime se o serviço/modelo faltar. O pull do modelo é pesado (~GBs); só roda fora
        de -Check/-DryRun e quando o Ollama está presente.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [Parameter(Mandatory)][string]$ServerDir,
        [string]$Model = $script:LocalAiDefaultModel,
        [string]$OllamaHost = $script:LocalAiOllamaHost,
        [switch]$Check,
        [switch]$DryRun
    )

    if (-not (Test-Path -LiteralPath $ServerDir -PathType Container)) {
        Write-Step WARN "local-ai: server não encontrado em $ServerDir — reinstale o onboarding"
        $Summary.Warn++
        return
    }

    $claudePresent = Test-CommandExists 'claude'
    $uvPresent     = Test-CommandExists 'uv'
    $ollamaPresent = Test-CommandExists 'ollama'
    $modelPresent  = if ($ollamaPresent) { Test-LocalAiModelPresent -Model $Model } else { $false }

    $already = $false
    if ($claudePresent) {
        try {
            claude mcp get local-ai 2>&1 | Out-Null
            $already = ($LASTEXITCODE -eq 0)
        }
        catch { $already = $false }
    }

    $plan = Get-LocalAiPlan -ClaudePresent $claudePresent -UvPresent $uvPresent `
        -OllamaPresent $ollamaPresent -ModelPresent $modelPresent -AlreadyRegistered $already

    $hostNote = if ($OllamaHost -ne $script:LocalAiOllamaHost) { " · host: $OllamaHost" } else { '' }
    Write-Step INFO "local-ai: $($plan.Reason) (modelo: $Model$hostNote)"

    # --- Aviso de hardware (best-effort, NVIDIA) — só avisa, nunca bloqueia ---
    $vramWarn = Get-LocalAiVramWarning -DetectedVramGB (Get-NvidiaVramGB) `
        -MinVramGB (Get-LocalAiModelMinVramGB -Model $Model) -Model $Model
    if ($vramWarn) { Write-Step WARN "local-ai: $vramWarn"; $Summary.Warn++ }

    # --- Ollama (CLI/serviço) — só avisa; o registro não depende dele -------
    if ($plan.Ollama -eq 'missing') {
        Write-Step WARN 'local-ai: Ollama ausente — instale (winget install Ollama.Ollama) e rode `ollama serve`'
        $Summary.Warn++
    }

    # --- uv sync (instala deps do server no diretório versionado) -----------
    switch ($plan.Sync) {
        'block' {
            Write-Step WARN 'local-ai: uv ausente — não dá p/ preparar o server (instale o uv) — pulei sync e registro'
            $Summary.Warn++
            return
        }
        'sync' {
            if ($Check)      { Write-Step INFO "local-ai: uv sync em $ServerDir" }
            elseif ($DryRun) { Write-Step DRY  "uv sync --directory `"$ServerDir`"" }
            else {
                try {
                    Push-Location -LiteralPath $ServerDir
                    try { uv sync 2>&1 | Out-Null } finally { Pop-Location }
                    if ($LASTEXITCODE -eq 0) {
                        Write-Step OK 'local-ai: deps do server instaladas (uv sync)'
                    }
                    else {
                        Write-Step WARN "local-ai: 'uv sync' retornou $LASTEXITCODE — rode manualmente em $ServerDir"
                        $Summary.Warn++
                    }
                }
                catch {
                    Write-Step WARN "local-ai: falha no uv sync — $($_.Exception.Message)"
                    $Summary.Warn++
                }
            }
        }
    }

    # --- ollama pull (modelo) — pesado; só real, fora de Check/DryRun -------
    switch ($plan.Pull) {
        'defer' { } # já avisado acima (Ollama ausente)
        'skip'  { Write-Step SKIP "local-ai: modelo $Model já baixado" ; $Summary.Skipped++ }
        'pull'  {
            if ($Check)      { Write-Step INFO "local-ai: baixaria o modelo $Model (ollama pull)" }
            elseif ($DryRun) { Write-Step DRY  "ollama pull $Model" }
            else {
                Write-Step RUN "local-ai: baixando modelo $Model (pode demorar — GBs)..."
                try {
                    ollama pull $Model 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Step OK "local-ai: modelo $Model baixado"
                    }
                    else {
                        Write-Step WARN "local-ai: 'ollama pull $Model' retornou $LASTEXITCODE — baixe manualmente depois"
                        $Summary.Warn++
                    }
                }
                catch {
                    Write-Step WARN "local-ai: falha no pull do modelo — $($_.Exception.Message)"
                    $Summary.Warn++
                }
            }
        }
    }

    # --- claude mcp add (registro user-scoped) ------------------------------
    switch ($plan.Register) {
        'block' {
            Write-Step WARN 'local-ai: claude/uv ausente — pulei o registro do MCP (registre depois)'
            $Summary.Warn++
        }
        'skip' {
            Write-Step SKIP 'local-ai: MCP já registrado (user scope) — reinicie o Claude Code p/ recarregar'
            $Summary.Skipped++
        }
        'add' {
            $regArgs = Get-LocalAiRegisterArgs -ServerDir $ServerDir -Model $Model -OllamaHost $OllamaHost
            if ($Check)      { Write-Step INFO 'local-ai: registraria o MCP (user scope)'; return }
            if ($DryRun)     { Write-Step DRY  "claude $($regArgs -join ' ')"; return }
            try {
                claude @regArgs 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Step OK 'local-ai registrado (reinicie o Claude Code para carregar o MCP)'
                    $Summary.Installed++
                }
                else {
                    Write-Step WARN "local-ai: 'claude mcp add' retornou $LASTEXITCODE — registre manualmente depois"
                    $Summary.Warn++
                }
            }
            catch {
                Write-Step WARN "local-ai: falha ao registrar — $($_.Exception.Message)"
                $Summary.Warn++
            }
        }
    }
}

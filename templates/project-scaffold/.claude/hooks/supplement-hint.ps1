<#
.SYNOPSIS
    Hook supplement-hint — ESTÁGIO 2. Lembra, no prompt que toca um tema do catálogo, que existe
    suplemento curado para ele. READ-ONLY quanto ao projeto e não-bloqueante.

.DESCRIPTION
    Chamado pelo supplement-hint.sh (estágio 1) só quando o grep do prompt casou algum padrão do
    supplement-hint.triggers. Registrado em hooks.UserPromptSubmit; não existe no SessionStart.

    POR QUE (SUPLEMENTO_SEM_GATILHO_DE_RECOMENDACAO, 2026-10-03): num projeto mvp sem os opcionais,
    0 de 6 sessões com tarefa de design, relatório ou dados citaram o /supplements. A linha do
    CLAUDE.md que o lista não basta, e uma linha always-on a mais foi preterida (custo em todo
    projeto). Este hook só fala quando o prompt casa.

    Decide, por tema casado no campo `prompt`:
      - algum plugin do tema LIGADO (enabledPlugins)   -> silêncio (o recurso já está no ar)
      - instalado e desligado (installed_plugins.json) -> sugere ligar pelo /plugin
      - não instalado                                  -> sugere /supplements <tema>
      - tema já lembrado nesta sessão (session_id)     -> silêncio (dedup)
    stdin inválido / fora de projeto / tools/ inalcançável / qualquer erro -> SILÊNCIO (exit 0).
    Sem tools/, o /supplements também não roda: recomendá-lo seria prometer o que não funciona.

    Onde ler o ~/.claude: SUPPLEMENT_HINT_CLAUDE_HOME (USO EM TESTE: a bateria e2e simula "nada
    instalado" sem trocar o CLAUDE_CONFIG_DIR, que levaria a autenticação junto) -> CLAUDE_CONFIG_DIR
    -> ~/.claude.

    Único arquivo escrito: .claude/.cache/supplement-hint.json (dedup; .gitignore cobre .cache/).
    Schema do stdin MEDIDO (2026-10-03, claude 2.1.288): { session_id, cwd, prompt, prompt_id,
    hook_event_name, ... } — o campo é `prompt`, não `user_prompt`.

    Funções puras dot-sourceáveis para teste; o fluxo só roda quando NÃO dot-sourced (guard no fim).
#>

Set-StrictMode -Version Latest

$script:HintStateRelPath = '.claude/.cache/supplement-hint.json'

# --- Acesso seguro a propriedade sob StrictMode (PSCustomObject do ConvertFrom-Json) ----------
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# --- PURA: resolve a raiz de tools/ pela cascata (ver rules/tooling.md) ------------------------
function Resolve-ToolsRoot {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$StartDir,
        [AllowNull()][string]$WorkflowHome = $env:SDD_WORKFLOW_HOME
    )
    $none = [pscustomobject]@{ Path = $null; Source = 'none'; Degraded = $true }
    if ([string]::IsNullOrWhiteSpace($StartDir)) { return $none }
    $rel = Join-Path $StartDir 'tools'
    if (Test-Path -LiteralPath $rel -PathType Container) {
        return [pscustomobject]@{ Path = $rel; Source = 'relative'; Degraded = $false }
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkflowHome)) {
        $envTools = Join-Path $WorkflowHome 'tools'
        if (Test-Path -LiteralPath $envTools -PathType Container) {
            return [pscustomobject]@{ Path = $envTools; Source = 'env'; Degraded = $false }
        }
    }
    return $none
}

# --- PURA: lê o vocabulário (tema<TAB>regex; # é comentário) ------------------------------------
function Read-HintTriggers {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $out = foreach ($line in (Get-Content -LiteralPath $Path -Encoding utf8)) {
        $l = $line.TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($l) -or $l.TrimStart().StartsWith('#')) { continue }
        $parts = $l -split "`t", 2
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[1])) { continue }
        [pscustomobject]@{ Theme = $parts[0].Trim(); Pattern = $parts[1] }
    }
    return @($out)
}

# --- PURA: temas cujo padrão casa o texto do prompt (sem diferenciar maiúsculas) ----------------
function Get-PromptThemes {
    param(
        [AllowNull()][AllowEmptyString()][string]$Prompt,
        [AllowEmptyCollection()][psobject[]]$Triggers = @()
    )
    if ([string]::IsNullOrWhiteSpace($Prompt)) { return @() }
    $hits = foreach ($t in @($Triggers)) {
        try {
            if ([regex]::IsMatch($Prompt, $t.Pattern, 'IgnoreCase')) { $t.Theme }
        } catch { }   # padrão inválido não derruba o hook: só não casa
    }
    return @($hits | Select-Object -Unique)
}

# --- PURA: diretório de config do Claude Code -----------------------------------------------------
function Get-ClaudeHome {
    param(
        [AllowNull()][string]$Override = $env:SUPPLEMENT_HINT_CLAUDE_HOME,
        [AllowNull()][string]$ConfigDir = $env:CLAUDE_CONFIG_DIR,
        [AllowNull()][string]$UserHome = ([Environment]::GetFolderPath('UserProfile'))
    )
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override }
    if (-not [string]::IsNullOrWhiteSpace($ConfigDir)) { return $ConfigDir }
    return (Join-Path $UserHome '.claude')
}

function Read-JsonOrNull {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json) } catch { return $null }
}

# --- Estado dos plugins: instalados (installed_plugins.json) e ligados (enabledPlugins) ---------
#     enabledPlugins segue a precedência do harness: usuário < projeto < local (o mais específico
#     vence). Formato desconhecido -> conjunto vazio, nunca exceção.
function Get-PluginState {
    param(
        [Parameter(Mandatory)][string]$ClaudeHome,
        [AllowNull()][string]$ProjectRoot
    )
    $installed = @{}
    $inst = Read-JsonOrNull (Join-Path $ClaudeHome 'plugins/installed_plugins.json')
    $plugins = Get-PropOrNull $inst 'plugins'
    if ($plugins -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $plugins.PSObject.Properties) { $installed[$p.Name.ToLowerInvariant()] = $true }
    }

    $enabled = @{}
    $sources = @((Join-Path $ClaudeHome 'settings.json'))
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $sources += (Join-Path $ProjectRoot '.claude/settings.json')
        $sources += (Join-Path $ProjectRoot '.claude/settings.local.json')
    }
    foreach ($s in $sources) {
        $ep = Get-PropOrNull (Read-JsonOrNull $s) 'enabledPlugins'
        if ($ep -isnot [System.Management.Automation.PSCustomObject]) { continue }
        foreach ($p in $ep.PSObject.Properties) { $enabled[$p.Name.ToLowerInvariant()] = [bool]$p.Value }
    }
    return [pscustomobject]@{ Installed = $installed; Enabled = $enabled }
}

# --- PURA: estado do tema a partir do catálogo e dos plugins -------------------------------------
#     State = enabled | installed | missing ; $null quando o tema não tem plugin no catálogo.
function Get-ThemeSupplementState {
    param(
        [Parameter(Mandatory)][string]$Theme,
        [AllowEmptyCollection()][psobject[]]$Catalog = @(),
        [Parameter(Mandatory)][psobject]$PluginState
    )
    $items = @($Catalog | Where-Object { $_.Theme -eq $Theme -and $_.Type -eq 'plugin' })
    if ($items.Count -eq 0) { return $null }
    $key = { param($i) ('{0}@{1}' -f $i.Name, $i.Id).ToLowerInvariant() }

    $on = @($items | Where-Object { $PluginState.Enabled[(& $key $_)] -eq $true })
    if ($on.Count -gt 0) { return [pscustomobject]@{ Theme = $Theme; State = 'enabled'; Item = $on[0] } }
    $inst = @($items | Where-Object { $PluginState.Installed.ContainsKey((& $key $_)) })
    if ($inst.Count -gt 0) { return [pscustomobject]@{ Theme = $Theme; State = 'installed'; Item = $inst[0] } }
    return [pscustomobject]@{ Theme = $Theme; State = 'missing'; Item = $items[0] }
}

# --- PURA: o texto do aviso (uma linha por tema) -------------------------------------------------
function Format-SupplementHint {
    param([AllowEmptyCollection()][psobject[]]$States = @())
    $lines = foreach ($s in @($States)) {
        if ($null -eq $s -or $s.State -eq 'enabled') { continue }
        $acao = if ($s.State -eq 'installed') {
            "já tem o $($s.Item.Name) instalado e pode ligá-lo em /plugin"
        } else {
            "pode instalar com /supplements $($s.Theme)"
        }
        "supplement-hint: a tarefa toca o tema '$($s.Theme)' do catálogo de suplementos ($($s.Item.Name): $($s.Item.Reason)). " +
        "Diga ao usuário, numa frase, que ele $acao. Não instale nem rode o command: a escolha é dele. Siga com a tarefa."
    }
    return (@($lines) -join "`n")
}

# --- PURA: JSON de saída informativo ------------------------------------------------------------
function New-HintHookJson {
    param(
        [Parameter(Mandatory)][string]$Context,
        [string]$EventName = 'UserPromptSubmit'
    )
    $obj = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = $EventName; additionalContext = $Context } }
    return ($obj | ConvertTo-Json -Depth 6 -Compress)
}

# --- Estado do dedup: { session_id, themes } -----------------------------------------------------
function Read-HintState {
    param([Parameter(Mandatory)][string]$Path)
    $o = Read-JsonOrNull $Path
    return [pscustomobject]@{
        SessionId = [string](Get-PropOrNull $o 'session_id')
        Themes    = @(Get-PropOrNull $o 'themes' | Where-Object { $_ })
    }
}

function Write-HintState {
    param([Parameter(Mandatory)][string]$Path, [string]$SessionId, [string[]]$Themes = @())
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json = [ordered]@{ session_id = $SessionId; themes = @($Themes) } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
    } catch { }   # dedup é conveniência: falhar ao gravar não pode virar erro do hook
}

function Invoke-SupplementHint {
    # -InputJson existe para teste (Pester não alimenta [Console]::In); o hook real lê o stdin.
    param(
        [AllowNull()][string]$InputJson = $null,
        [AllowNull()][string]$CatalogPath = $null
    )
    # O texto tem acento: sem forçar UTF-8, o pwsh no Windows escreve na codepage OEM e o JSON chega
    # corrompido ao modelo (medido byte a byte no curation-nudge). Falha aqui não aborta o hook.
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

    $raw = $InputJson
    if (-not $PSBoundParameters.ContainsKey('InputJson')) { try { $raw = [Console]::In.ReadToEnd() } catch { return } }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    try { $payload = $raw | ConvertFrom-Json } catch { return }

    $root = [string](Get-PropOrNull $payload 'cwd')
    if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath (Join-Path $root '.claude') -PathType Container)) { return }

    $prompt = [string](Get-PropOrNull $payload 'prompt')
    $triggers = Read-HintTriggers -Path (Join-Path $PSScriptRoot 'supplement-hint.triggers')
    $themes = @(Get-PromptThemes -Prompt $prompt -Triggers $triggers)
    if ($themes.Count -eq 0) { return }

    $sessionId = [string](Get-PropOrNull $payload 'session_id')
    $statePath = Join-Path $root $script:HintStateRelPath
    $state = Read-HintState -Path $statePath
    # @( ) por fora do if: com um tema só, o if devolve STRING, e `$seen + $novos` concatenava texto
    # ("design" + "data" = "designdata", medido em 2026-10-03) em vez de somar listas.
    $seen = @(if ($state.SessionId -eq $sessionId) { $state.Themes })
    $novos = @($themes | Where-Object { $seen -notcontains $_ })
    if ($novos.Count -eq 0) { return }

    $catalog = @()
    try {
        if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
            $tr = Resolve-ToolsRoot -StartDir $root
            if ($tr.Degraded) { return }
            . (Join-Path $tr.Path 'supplements.ps1')
            $catalog = @(Get-SupplementCatalog -WarningAction SilentlyContinue)
        } else {
            . (Join-Path (Split-Path -Parent $CatalogPath) 'supplements.ps1')
            $catalog = @(Get-SupplementCatalog -ManifestPath $CatalogPath -WarningAction SilentlyContinue)
        }
    } catch { return }

    $pstate = Get-PluginState -ClaudeHome (Get-ClaudeHome) -ProjectRoot $root
    $states = @($novos | ForEach-Object { Get-ThemeSupplementState -Theme $_ -Catalog $catalog -PluginState $pstate } | Where-Object { $_ })
    $text = Format-SupplementHint -States $states
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        Write-Output (New-HintHookJson -Context $text)
    }
    # Grava todo tema avaliado (inclusive o "ligado", que calou): a decisão não muda na mesma sessão.
    Write-HintState -Path $statePath -SessionId $sessionId -Themes @($seen + $novos)
}

# --- Guard: roda o fluxo só quando NÃO dot-sourced (Pester faz `. supplement-hint.ps1`) ----------
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-SupplementHint
}

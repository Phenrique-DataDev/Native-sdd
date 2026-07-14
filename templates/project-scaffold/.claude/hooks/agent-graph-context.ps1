<#
.SYNOPSIS
    Hook agent-graph-context — entrega o grafo de roteamento (role + connects_to) ao subagente
    que está iniciando. READ-ONLY e não-bloqueante.

.DESCRIPTION
    Registrado no .claude/settings.json do projeto (hooks.SubagentStart, matcher "*"). Fecha uma
    lacuna real: hoje "consulte o grafo antes de rotear" (agent-routing.md/max-mode.md) é uma
    instrução de PROMPT para o líder — depende dele lembrar de abrir graph.json. Este hook torna
    a aresta connects_to do agente que está iniciando uma entrega DETERMINÍSTICA via
    additionalContext, todo disparo, sem depender de o líder consultar nada.

    Em cada disparo decide:
      - stdin inválido / fora de projeto / tools/ degradada / agent_type sem nó no grafo
                                                          -> SILÊNCIO (exit 0, sem stdout)
      - agente reconhecido no .claude/agents/**           -> emite additionalContext (role + connects_to)

    Reusa Get-AgentGraph (tools/graph-export.ps1 — mesmo parser do agent-lint/graph.json,
    ZERO parser novo). Escopo deliberadamente estreito: só role + connects_to do próprio agente
    (o "grafo de pares"), não o grafo unificado (KB/skills) — isso dispara em TODO subagente,
    então o custo por disparo tem que ficar baixo (ver kb-taxonomy.md/G8: on-demand, não always-on).
    Consulta ao grafo completo (KB/skills/domínio) continua sendo ação deliberada do líder
    (agent-routing.md §Consultar o grafo unificado / max-mode.md), não algo injetado aqui.

    NUNCA altera .claude/**. Não escreve nenhum arquivo (sem estado/cooldown — o custo por
    disparo já é baixo o bastante para não precisar de debounce).

    Schema do hook (SubagentStart) confirmado via context7 (code.claude.com/docs/en/hooks):
      stdin  = { session_id, transcript_path, cwd, hook_event_name:"SubagentStart", agent_id, agent_type }
      saída  = { hookSpecificOutput: { hookEventName, additionalContext } }  |  silêncio = exit 0 sem stdout

    Funções puras (Format-GraphContext / New-GraphContextHookJson) são dot-sourceáveis; o fluxo só
    roda quando o script NÃO é dot-sourced (guard no fim) — molde curation-nudge.ps1.
#>

Set-StrictMode -Version Latest

# --- Acesso seguro a propriedade sob StrictMode (PSCustomObject do ConvertFrom-Json) -----------
function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# --- PURA: resolve a raiz de tools/ pela cascata (ver rules/tooling.md) ------------------------
# Duplicada (não dot-sourceada) de propósito: hooks não compartilham código entre si — cada um
# resolve tools/ antes de tê-lo (mesma nota em curation-nudge.ps1).
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

# --- PURA: monta o texto injetado a partir do nó/arestas do agente que está iniciando ----------
function Format-GraphContext {
    param(
        [Parameter(Mandatory)][string]$AgentType,
        [Parameter(Mandatory)][pscustomobject]$Graph
    )
    $node = @($Graph.Nodes) | Where-Object { $_.Id -eq $AgentType } | Select-Object -First 1
    if (-not $node) { return '' }   # agente sem frontmatter no grafo (ex.: general-purpose, Explore) -> silêncio

    $targets = @(@($Graph.Edges) | Where-Object { $_.From -eq $AgentType -and $_.Type -eq 'CONNECTS_TO' } | ForEach-Object { $_.To })

    $parts = [System.Collections.Generic.List[string]]::new()
    $roleTxt = if ([string]::IsNullOrWhiteSpace($node.Role)) { '(sem role declarado)' } else { $node.Role }
    $parts.Add("Você é o subagente ``$AgentType`` (role: $roleTxt).")
    if ($targets.Count -gt 0) {
        $parts.Add("Encadeamento típico ao concluir (connects_to): $($targets -join ', ').")
    }
    $parts.Add('(agent-graph-context: aviso read-only derivado do frontmatter; grafo completo em .claude/agents/graph.json)')
    return ($parts -join ' ')
}

# --- PURA: JSON de saída informativo (sem permissionDecision) ----------------------------------
function New-GraphContextHookJson {
    param([Parameter(Mandatory)][string]$Context)
    $obj = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName     = 'SubagentStart'
            additionalContext = $Context
        }
    }
    return ($obj | ConvertTo-Json -Depth 6 -Compress)
}

# --- Fluxo principal ----------------------------------------------------------------------------
function Invoke-AgentGraphContext {
    # 0) Força stdout em UTF-8 sem BOM: o texto injetado tem acentuação (pt-BR) e o console do
    #    pwsh no Windows por padrão NÃO escreve UTF-8 em stdout redirecionado — sem isto, o JSON
    #    emitido corrompe caracteres acentuados (bug real, verificado byte a byte nesta sessão).
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { return }

    # 1) Ler payload (falha -> silêncio)
    try { $raw = [Console]::In.ReadToEnd() } catch { return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    try { $payload = $raw | ConvertFrom-Json } catch { return }

    # 2) agent_type ausente (payload malformado) -> silêncio
    $agentType = [string](Get-PropOrNull $payload 'agent_type')
    if ([string]::IsNullOrWhiteSpace($agentType)) { return }

    # 3) Raiz do projeto + .claude/agents presente
    $root = [string](Get-PropOrNull $payload 'cwd')
    if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }
    $agentsDir = Join-Path $root '.claude/agents'
    if (-not (Test-Path -LiteralPath $agentsDir -PathType Container)) { return }

    # 4) Resolve tools/ pela cascata; degradada -> silêncio (fail-safe, nunca reimplementa o parser)
    $tools = Resolve-ToolsRoot -StartDir $root
    if ($tools.Degraded) { return }

    # 5) Constrói o grafo de pares (role + connects_to) reusando graph-export.ps1 — zero parser novo
    try {
        . (Join-Path $tools.Path 'graph-export.ps1')
        $graph = Get-AgentGraph -Dir $agentsDir
    }
    catch { return }

    # 6) Agente sem nó no grafo (built-in: general-purpose/Explore/claude/…) -> silêncio total
    $text = Format-GraphContext -AgentType $agentType -Graph $graph
    if ([string]::IsNullOrWhiteSpace($text)) { return }

    Write-Output (New-GraphContextHookJson -Context $text)
}

# --- Guard: roda o fluxo só quando NÃO dot-sourced (Pester faria `. agent-graph-context.ps1`) ---
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AgentGraphContext
}

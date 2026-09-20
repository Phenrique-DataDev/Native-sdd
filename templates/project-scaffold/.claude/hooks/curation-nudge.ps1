<#
.SYNOPSIS
    Hook curation-nudge (EPIC J) — avisa staleness da curadoria. READ-ONLY e não-bloqueante.

.DESCRIPTION
    Registrado no .claude/settings.json do projeto (hooks.SessionStart matcher "*" e
    hooks.UserPromptSubmit matcher "*"). Em cada disparo decide:
      - stdin inválido / fora de projeto / cooldown / path fora de escopo / tools ausente
                                                          -> SILÊNCIO (exit 0, sem stdout)
      - curadoria com ≥1 sinal de staleness              -> emite additionalContext (nudge)
      - tudo em dia                                       -> SILÊNCIO

    Sinais (reusa inventários existentes, NÃO reimplementa varredura):
      - nao-inicializado  : Get-CurationStatus.ProjectInitialized — `status: template`. É o único
                            com texto imperativo: a rule equivalente do AGENTS.md foi medida em
                            3/9 nos dois perfis (auditoria externa da v0.10.61), porque só dispara
                            quando o gate de FASE já protegeria. Trocar prosa por mecanismo.
      - framework-version : ~/.claude/.native-sdd-version × $env:SDD_WORKFLOW_HOME/VERSION — a
                            camada 1 envelhece em silêncio (medido: 38 versões de defasagem na
                            máquina do autor), e o `-Update` do projeto não a atualiza.
      - curation          : Get-CurationStatus (init.ps1) — NextStep ≠ done
      - skills            : Get-SkillInventory+Get-SkillHealth (update-skills.ps1) — orphan/malformed
      - index             : Build-KbIndex/Build-AgentMap (sync-context.ps1) — gerado ≠ em disco
      - reflect / learn   : KB acima do budget · lições candidatas acumuladas

    NUNCA altera .claude/kb|agents|rules. O único arquivo escrito é o marcador de cooldown
    .claude/.cache/nudge-state.json (transitório; .gitignore cobre .cache/).

    Schema dos hooks verificado via context7 (/anthropics/claude-code, 2026-06-06):
      saída informativa = { hookSpecificOutput: { hookEventName, additionalContext } }
      silêncio          = exit 0 sem stdout
      stdin             = { hook_event_name, cwd, tool_input:{ file_path }, ... }

    Funções puras (Test-IsCuratedPath / Get-StalenessSignals / Test-CooldownElapsed /
    Format-Nudge / New-NudgeHookJson) são dot-sourceáveis para teste; o fluxo só roda quando
    o script NÃO é dot-sourced (guard no fim).
#>

Set-StrictMode -Version Latest

# Janela de cooldown dos gatilhos recorrentes (segundos) -- hoje UserPromptSubmit, 1x/turno.
# SessionStart não aplica (baseline 1×/sessão).
$script:CooldownSeconds = 1800

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
    <#
    .SYNOPSIS
        Cascata de resolução da camada tools/: (1) tools/ relativo a -StartDir; (2)
        $WorkflowHome/tools; (3) degradação. Read-only (Test-Path). Mesma ordem do snippet
        canônico em rules/tooling.md (não compartilham código: resolve tools/ antes de tê-lo).
    .OUTPUTS
        [pscustomobject] { Path = <dir> | $null ; Source = 'relative'|'env'|'none' ; Degraded = [bool] }
    #>
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

# --- PURA: extrai os 5 campos canonicos do payload ja parseado (contrato H5/HARNESS-CONTRACT.md).
#     Ponto unico de acesso aos campos -- usado pelo fluxo do hook e por qualquer adapter de
#     harness que ja produza o payload no formato canonico. Espelha destructive-guard.ps1.
function Read-NormalizedEvent {
    param([Parameter(Mandatory)][AllowNull()]$Payload)
    $toolInput = Get-PropOrNull $Payload 'tool_input'
    return [pscustomobject]@{
        HookEventName = [string](Get-PropOrNull $Payload 'hook_event_name')
        ToolName      = [string](Get-PropOrNull $Payload 'tool_name')
        Command       = [string](Get-PropOrNull $toolInput 'command')
        FilePath      = [string](Get-PropOrNull $toolInput 'file_path')
        Cwd           = [string](Get-PropOrNull $Payload 'cwd')
    }
}

# --- PURA: o path editado cai sob a curadoria? ------------------------------------------------
function Test-IsCuratedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.Replace('\', '/')
    return [bool]($p -match '(?i)\.claude/(kb|agents|rules)/')
}

# --- PURA: snapshot -> lista de sinais disparados ---------------------------------------------
function Get-StalenessSignals {
    param([psobject]$Snapshot)
    if ($null -eq $Snapshot) { return @() }
    $signals = @()

    $cs = Get-PropOrNull $Snapshot 'CurationStatus'
    if ($cs) {
        # SINAL 0 — projeto NAO INICIALIZADO. Vem primeiro e tem texto proprio, imperativo.
        #
        # POR QUE (auditoria externa da v0.10.61, Anexo B.3): o AGENTS.md manda "status: template ->
        # instrua o usuario a rodar /setup ANTES DE EXECUTAR TRABALHO", e em 18 sessoes medidas a
        # regra foi cumprida 3/9 nos DOIS perfis -- os mesmos 3 casos, os tres pedidos de feature.
        # Em tarefa pequena (".gitignore para Python", "extraia os endpoints") o agente escreveu o
        # arquivo e nunca mencionou o estado do projeto. O gate de "nao inicializado" nao dispara
        # sozinho: pega carona no gate de FASE, e como a maior parte do trabalho real e pequena, na
        # pratica a rule existia para o caso em que ja haveria protecao de outro jeito.
        #
        # O aviso generico de curadoria ("curadoria incompleta (proximo: setup)") ja saia aqui e nao
        # bastou: ele fala de CURADORIA, nao de "nao trabalhe ainda". A alternativa menor -- mover a
        # frase para o topo do AGENTS.md -- ja esta descartada por leitura: ela ja e a primeira
        # secao de la.
        if ($null -ne (Get-PropOrNull $cs 'ProjectInitialized') -and -not [bool](Get-PropOrNull $cs 'ProjectInitialized')) {
            $signals += [pscustomobject]@{
                Signal  = 'nao-inicializado'
                Detail  = 'PROJETO NAO INICIALIZADO (project-context.md em status: template) -- avise o usuario ANTES de executar qualquer trabalho, inclusive tarefa pequena'
                Command = '/setup'
            }
        }
        $next = [string](Get-PropOrNull $cs 'NextStep')
        # 'setup' ja foi dito acima, com texto proprio e mais forte -- repetir seria ruido.
        if ($next -and $next -ne 'done' -and $next -ne 'setup') {
            $cmd = switch ($next) {
                'setup'        { '/setup' }
                'audit-agents' { '/audit-agents' }
                'train-kb'     { '/train-kb' }
                'sync-context' { '/sync-context' }
                default        { '/init' }
            }
            $signals += [pscustomobject]@{ Signal = 'curation'; Detail = "curadoria incompleta (proximo: $next)"; Command = $cmd }
        }
    }

    $fd = Get-PropOrNull $Snapshot 'FrameworkDrift'
    if ($fd -and [bool](Get-PropOrNull $fd 'Drifted')) {
        $signals += [pscustomobject]@{
            Signal  = 'framework-version'
            Detail  = ("camada 1 desatualizada: ~/.claude tem v{0}, o framework tem v{1} -- o -Update do projeto NAO atualiza o ~/.claude" -f $fd.Installed, $fd.Current)
            Command = 'pwsh $env:SDD_WORKFLOW_HOME/onboarding/install.ps1'
        }
    }

    $stale = [int](Get-PropOrNull $Snapshot 'StaleSkills')
    if ($stale -gt 0) {
        $signals += [pscustomobject]@{ Signal = 'skills'; Detail = "$stale skill(s) com problema (orphan/malformed)"; Command = '/update-skills' }
    }

    if ([bool](Get-PropOrNull $Snapshot 'IndexDrift')) {
        $detail = [string](Get-PropOrNull $Snapshot 'IndexDetail')
        if (-not $detail) { $detail = 'indices divergem do estado real' }
        $signals += [pscustomobject]@{ Signal = 'index'; Detail = $detail; Command = '/sync-context' }
    }

    if ([bool](Get-PropOrNull $Snapshot 'KbOverBudget')) {
        $detail = [string](Get-PropOrNull $Snapshot 'KbBudgetDetail')
        if (-not $detail) { $detail = 'KB acima do budget agregado' }
        $signals += [pscustomobject]@{ Signal = 'reflect'; Detail = $detail; Command = '/reflect' }
    }

    if ([bool](Get-PropOrNull $Snapshot 'LessonsReady')) {
        $detail = [string](Get-PropOrNull $Snapshot 'LessonsDetail')
        if (-not $detail) { $detail = 'lições candidatas acumuladas no acervo' }
        $signals += [pscustomobject]@{ Signal = 'learn'; Detail = $detail; Command = '/learn' }
    }

    return @($signals)
}

# --- PURA: cooldown decorreu? -----------------------------------------------------------------
function Get-FrameworkVersionDrift {
    <#
    .SYNOPSIS
        PURA. A camada 1 (o ~/.claude instalado) está atrás do checkout do framework?
        Devolve { Drifted; Installed; Current } — Drifted só quando AS DUAS versões são conhecidas
        e diferentes.

    .DESCRIPTION
        POR QUE EXISTE (auditoria externa da v0.10.61, 2026-09-19). O produto tem DUAS camadas: o
        `~/.claude` (instalado por `install.ps1`) e o scaffold do projeto (`-Update`). Atualizar a
        segunda sem a primeira é o caso comum, e nada no dia a dia avisa: a statusline não mostra, o
        `/status` não checa, e a divergência só aparece se a pessoa rodar o instalador — que é
        justamente o que ela não faz, por achar que está em dia. Medido na máquina do AUTOR:
        `0.9.23` instalado contra `0.10.61` no checkout, 40 dias e 38 versões de defasagem, numa
        máquina que roda o framework todo dia. O melhor indício de que dói é que doeu nele.
        O README reconhece o problema em prosa e responde com documentação, não com mecanismo.

        NÃO COMPARA ORDEM, só igualdade. Dizer "você está ATRÁS" exigiria parsear SemVer e acertar
        pré-release/build; dizer "as duas não batem" é verdade com qualquer esquema de versão, e é o
        que o usuário precisa para agir. Divergência com o checkout mais VELHO (dev trocando de
        branch) também merece o aviso.

        SILÊNCIO quando qualquer um dos dois lados falta: sem `$env:SDD_WORKFLOW_HOME` ou sem
        marcador, não sabemos — e "não sei" nunca pode virar aviso, que é como um nudge read-only
        vira ruído.
    .OUTPUTS
        [pscustomobject] { Drifted; Installed; Current }
    #>
    param(
        [AllowNull()][string]$HomeDir,
        [AllowNull()][string]$FrameworkHome
    )
    $out = [pscustomobject]@{ Drifted = $false; Installed = ''; Current = '' }
    if ([string]::IsNullOrWhiteSpace($HomeDir) -or [string]::IsNullOrWhiteSpace($FrameworkHome)) { return $out }

    $marker = Join-Path $HomeDir '.native-sdd-version'
    $versionFile = Join-Path $FrameworkHome 'VERSION'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $out }
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) { return $out }

    try {
        foreach ($line in (Get-Content -LiteralPath $marker -ErrorAction Stop)) {
            if ($line -match '^\s*installed_version\s*:\s*(.+?)\s*$') { $out.Installed = $Matches[1].Trim(); break }
        }
        $out.Current = ((Get-Content -LiteralPath $versionFile -Raw -ErrorAction Stop)).Trim()
    }
    catch { return $out }

    if ($out.Installed -and $out.Current -and $out.Installed -ne $out.Current) { $out.Drifted = $true }
    return $out
}

function Test-CooldownElapsed {
    param([long]$LastEpoch, [long]$NowEpoch, [int]$WindowSeconds)
    if ($LastEpoch -le 0) { return $true }
    return [bool](($NowEpoch - $LastEpoch) -ge $WindowSeconds)
}

# --- PURA: monta o texto do nudge -------------------------------------------------------------
function Format-Nudge {
    param([pscustomobject[]]$Signals)
    $Signals = @($Signals | Where-Object { $_ })
    if ($Signals.Count -eq 0) { return '' }
    $lines = @('Curadoria deste projeto possivelmente desatualizada:')
    foreach ($s in $Signals) {
        $lines += ("- {0} -> rode {1}" -f $s.Detail, $s.Command)
    }
    $lines += '(curation-nudge: aviso read-only; nada foi alterado)'
    return ($lines -join "`n")
}

# --- PURA: JSON de saída informativo (sem permissionDecision) ---------------------------------
function New-NudgeHookJson {
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][string]$EventName
    )
    $obj = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName     = $EventName
            additionalContext = $Context
        }
    }
    return ($obj | ConvertTo-Json -Depth 6 -Compress)
}

# (ConvertTo-NormalizedText saiu em 2026-07-13: existia só para a comparação de drift feita à mão,
#  que agora delega a Invoke-Resync -Check — o qual normaliza por conta própria. Órfão = removido.)

# --- I/O: marcador de cooldown (único arquivo escrito) ----------------------------------------
function Get-NudgeStatePath {
    param([Parameter(Mandatory)][string]$Root)
    return (Join-Path $Root '.claude/.cache/nudge-state.json')
}

function Read-NudgeState {
    param([Parameter(Mandatory)][string]$Path)
    $empty = [pscustomobject]@{ LastEpoch = [long]0; LastSignals = @(); LearnWatermark = [int]0 }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $empty }
        $o = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) | ConvertFrom-Json
        $epoch = [long](Get-PropOrNull $o 'last_nudge_epoch')
        $sigs = Get-PropOrNull $o 'last_signals'
        if ($null -eq $sigs) { $sigs = @() }
        # Ausente (estado gravado por uma versão anterior) = 0 = "nunca avisado" -> 1 aviso e cala.
        $mark = [int](Get-PropOrNull $o 'learn_watermark')
        return [pscustomobject]@{ LastEpoch = $epoch; LastSignals = @($sigs); LearnWatermark = $mark }
    }
    catch { return $empty }
}

function Write-NudgeState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Epoch,
        [AllowEmptyCollection()][string[]]$Signals = @(),
        [int]$LearnWatermark = 0
    )
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $obj = [ordered]@{ last_nudge_epoch = $Epoch; last_signals = @($Signals); learn_watermark = $LearnWatermark }
        Set-Content -LiteralPath $Path -Value ($obj | ConvertTo-Json -Depth 5 -Compress) -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Falha de escrita do marcador é não-fatal: o nudge já foi emitido. Pior caso: sem cooldown.
        Write-Verbose "nudge-state não gravado: $($_.Exception.Message)"
    }
}

# --- I/O: reúne os inventários (read-only), isolando falha por sinal --------------------------
function Get-CurationSnapshot {
    <#
    .SYNOPSIS
        Reúne os 3 sinais reusando os inventários de tools/ em -Root. Cada sinal é coletado em seu
        próprio try/catch — falha de um (ex.: tools incompleto) não derruba os demais. Read-only.
    .PARAMETER LearnWatermark
        PendingCount de lições no último aviso `learn` emitido (do nudge-state). Alimenta a
        HISTERESE do sinal 5 — ver Get-LessonsNudgeDecision (tools/learn.ps1).
    .OUTPUTS
        [pscustomobject] { CurationStatus; StaleSkills; IndexDrift; IndexDetail; ...;
                           LessonsReady; LessonsDetail; LessonsWatermark }
        LessonsWatermark = marca-d'água a PERSISTIR no nudge-state (o caller grava).
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$LearnWatermark = 0
    )

    $toolsDir = (Resolve-ToolsRoot -StartDir $Root).Path
    $snap = [pscustomobject]@{ CurationStatus = $null; StaleSkills = [int]0; IndexDrift = $false; IndexDetail = ''; KbOverBudget = $false; KbBudgetDetail = ''; LessonsReady = $false; LessonsDetail = ''; LessonsWatermark = [int]$LearnWatermark; FrameworkDrift = $null }

    # 0) camada 1 x checkout do framework. Fora dos try/catch dos demais porque nao depende de
    #    tools/ nenhum: sao dois arquivos de texto. Silencioso quando qualquer lado falta.
    try {
        $homeDir = if ($IsWindows -or $null -eq $IsWindows) { $env:USERPROFILE } else { $HOME }
        if ($homeDir) {
            $snap.FrameworkDrift = Get-FrameworkVersionDrift -HomeDir (Join-Path $homeDir '.claude') -FrameworkHome $env:SDD_WORKFLOW_HOME
        }
    }
    catch { Write-Verbose "sinal framework-version indisponivel: $($_.Exception.Message)" }

    # 1) curation status (init.ps1 já dot-source agent-lint + kb-lint)
    try {
        . (Join-Path $toolsDir 'init.ps1')
        $snap.CurationStatus = Get-CurationStatus -Root $Root
    }
    catch { Write-Verbose "sinal curation indisponível: $($_.Exception.Message)" }

    # 2) skills com problema (orphan/malformed; baseline-free -> determinístico e sem dependência)
    try {
        . (Join-Path $toolsDir 'update-skills.ps1')
        $projSkills = Join-Path $Root '.claude/skills'
        $inv = @(Get-SkillInventory -GlobalRoot $null -ProjectRoot $projSkills)
        $bad = 0
        foreach ($s in $inv) {
            $h = Get-SkillHealth -Skill $s -BaselineMap @()
            if ($h.Health -in @('orphan', 'malformed')) { $bad++ }
        }
        $snap.StaleSkills = $bad
    }
    catch { Write-Verbose "sinal skills indisponível: $($_.Exception.Message)" }

    # 3) drift de índice — DELEGA à fonte única (resync.ps1 `Invoke-Resync -Check`, read-only, 0 bytes).
    #
    #    Este bloco REIMPLEMENTAVA a comparação "gerado × disco" à mão, e derivou da fonte única de um
    #    jeito que nunca falhava alto: chamava `Build-AgentMap` SEM `-Connections` (parâmetro opcional,
    #    default `@{}`), então o mapa "gerado" saía sem as arestas `connects_to` que o /sync-context de
    #    fato escreve. Gerado != disco SEMPRE — o nudge pedia /sync-context em TODA sessão, inclusive
    #    num projeto perfeitamente sincronizado, e rodar o comando não calava nada. Medido no IAIMG:
    #    o predicado caseiro dizia drift; `Invoke-Resync -Check` dizia InSync=True nos 3 artefatos.
    #    (Mesma classe do nudge eterno do /learn: um predicado que não tem como ser satisfeito.)
    #
    #    De quebra, o código à mão só olhava 2 dos 4 artefatos derivados (ignorava graph.json/.cypher).
    try {
        . (Join-Path $toolsDir 'resync.ps1')   # já dot-source agent-lint/kb-lint/sync-context/graph-export

        # 'missing-on-disk' NÃO é drift aqui de propósito: artefato ainda não criado é *curadoria
        # incompleta* (sinal 1, que já aponta /init), não índice desatualizado. Só 'content-drift'
        # significa "existe e está velho" — que é o que o /sync-context conserta.
        $stale = @(Invoke-Resync -ClaudeDir (Join-Path $Root '.claude') -Check |
                    Where-Object { $_.Reason -eq 'content-drift' })

        if ($stale.Count -gt 0) {
            $names = @($stale | ForEach-Object { @($_.Paths) | ForEach-Object { Split-Path $_ -Leaf } })
            $snap.IndexDrift = $true
            $snap.IndexDetail = "indices divergem do estado real: $($names -join ', ')"
        }
    }
    catch { Write-Verbose "sinal index indisponível: $($_.Exception.Message)" }

    # 4) KB acima do budget agregado -> sugere /reflect (G6; reusa reflect.ps1 -> kb-lint/B7)
    try {
        $kbDir = Join-Path $Root '.claude/kb'
        if (Test-Path -LiteralPath $kbDir -PathType Container) {
            . (Join-Path $toolsDir 'reflect.ps1')
            $b = Test-KbOverBudget -Dir $kbDir
            if ($b.OverBudget) {
                $snap.KbOverBudget = $true
                $snap.KbBudgetDetail = "KB grande ($($b.Reason))"
            }
        }
    }
    catch { Write-Verbose "sinal reflect indisponível: $($_.Exception.Message)" }

    # 5) Lições candidatas NOVAS desde o último aviso -> sugere /learn (G7; reusa learn.ps1 -> B7).
    #    Note o "NOVAS": o gatilho NÃO é Test-LessonsReady (estado "tem trabalho?"), que é verdadeiro
    #    para sempre porque o acervo só cresce. Quem decide o AVISO é Get-LessonsNudgeDecision, com
    #    histerese sobre a marca-d'água — senão o nudge nunca cala e o usuário aprende a ignorá-lo.
    try {
        $archiveDir = Join-Path $Root '.claude/sdd/archive'
        if (Test-Path -LiteralPath $archiveDir -PathType Container) {
            . (Join-Path $toolsDir 'learn.ps1')
            $ls = Test-LessonsReady -ArchiveDir $archiveDir -KbDir (Join-Path $Root '.claude/kb')
            $d = Get-LessonsNudgeDecision -PendingCount $ls.PendingCount -Watermark $LearnWatermark
            $snap.LessonsWatermark = $d.Watermark   # já traz o reset descendente (promoveram -> a marca desce)
            if ($d.Due) {
                $snap.LessonsReady = $true
                $snap.LessonsDetail = "$($d.NewSinceLastNudge) lição(ões) candidata(s) nova(s) desde o último aviso ($($ls.PendingCount) pendentes no total)"
            }
        }
    }
    catch { Write-Verbose "sinal learn indisponível: $($_.Exception.Message)" }

    return $snap
}

# --- Fluxo principal --------------------------------------------------------------------------
function Invoke-CurationNudge {
    # 0) Forca stdout em UTF-8 sem BOM: o texto emitido tem acentuacao (pt-BR) e o console do
    #    pwsh no Windows NAO escreve UTF-8 em stdout redirecionado -- sem isto o JSON sai na
    #    codepage OEM e chega corrompido ao modelo (medido byte a byte). Molde repetido em
    #    todos os hooks que emitem texto -- auto-suficiente de proposito, sem apontar para um
    #    arquivo vizinho: ate 2026-09-01 este comentario citava o agent-graph-context.ps1, que
    #    foi REMOVIDO do scaffold, e o ponteiro teria sobrevivido ao alvo. Falha aqui NAO aborta
    #    o hook: encoding ruim e' melhor que
    #    hook desativado (num guard, o `return` viraria passthrough silencioso).
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

    # 1) Ler payload (falha -> silêncio)
    try { $raw = [Console]::In.ReadToEnd() } catch { return }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    try { $payload = $raw | ConvertFrom-Json } catch { return }

    # 2) Contexto: evento + raiz do projeto
    $evt = Read-NormalizedEvent $payload
    $eventName = $evt.HookEventName
    if (-not $eventName) { $eventName = 'SessionStart' }
    $root = $evt.Cwd
    if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath (Join-Path $root '.claude') -PathType Container)) { return }

    $statePath = Get-NudgeStatePath -Root $root
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # O estado é lido nos DOIS eventos: o PostToolUse precisa do cooldown, e ambos precisam da
    # marca-d'água do sinal `learn` (a histerese vale também no SessionStart — é justamente lá que
    # o nudge eterno aparecia, uma vez por sessão, para sempre).
    $state = Read-NudgeState -Path $statePath

    # 3) Gatilhos recorrentes: cooldown sempre; filtro de path só onde existe FilePath.
    #    - UserPromptSubmit (gatilho atual, 1x/turno): não carrega file_path, então avalia os
    #      sinais direto -- o snapshot já lê o estado real do projeto, e o filtro de path era só
    #      um proxy barato de "vale olhar". De quebra, pega divergência de qualquer origem.
    #    - PostToolUse: mantido para projetos ainda no settings.json antigo.
    #    - SessionStart: não filtra nada -- é o baseline 1x/sessão.
    if ($eventName -in @('PostToolUse', 'UserPromptSubmit')) {
        if ($eventName -eq 'PostToolUse' -and -not (Test-IsCuratedPath $evt.FilePath)) { return }
        if (-not (Test-CooldownElapsed -LastEpoch $state.LastEpoch -NowEpoch $now -WindowSeconds $script:CooldownSeconds)) { return }
    }

    # 4) Resolve a camada tools/ pela cascata (rules/tooling.md): relativo -> SDD_WORKFLOW_HOME ->
    #    degradação. Degradada (nenhuma via) -> fail-safe silêncio. Reativa o nudge no projeto-alvo.
    if ((Resolve-ToolsRoot -StartDir $root).Degraded) { return }

    # 5) Reúne sinais (read-only) e decide
    try { $snapshot = Get-CurationSnapshot -Root $root -LearnWatermark $state.LearnWatermark } catch { return }
    $signals = @(Get-StalenessSignals -Snapshot $snapshot)
    if ($signals.Count -eq 0) { return }   # tudo em dia -> silêncio total

    $text = Format-Nudge -Signals $signals
    if ([string]::IsNullOrWhiteSpace($text)) { return }

    Write-Output (New-NudgeHookJson -Context $text -EventName $eventName)
    Write-NudgeState -Path $statePath -Epoch $now -Signals @($signals | ForEach-Object { $_.Signal }) `
                     -LearnWatermark ([int]$snapshot.LessonsWatermark)
}

# --- Guard: roda o fluxo só quando NÃO dot-sourced (Pester faz `. curation-nudge.ps1`) ---------
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-CurationNudge
}

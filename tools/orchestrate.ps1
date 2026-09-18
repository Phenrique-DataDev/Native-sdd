<#
.SYNOPSIS
    Gate + estado do H2 (/orchestrate): valida o resultado de uma task (gate determinístico) e
    deriva o estado resumível da orquestração a partir de um arquivo STATE. Sem engine — invocar/
    aguardar/paralelizar/resume é a ferramenta Agent nativa, conduzida pelo líder em runtime.

.DESCRIPTION
    Funções puras (read-only, determinísticas) usadas pela validação automática do H2 e pelo
    comando em runtime. Espelham o PADRÃO do G1 (tools/init.ps1: Get-CurationStatus /
    Test-CurationReadiness / Format-CurationReport) — molde, não dot-source.

      ConvertFrom-OrchestrationState -> [pscustomobject[]]  { Id; Title; Dod; Model; Type; Deps[]; Status }
      Get-OrchestrationStatus       -> [pscustomobject]     { Objective; Total; Passed; Failed; Pending; Awaiting; IgnoredLines; Tasks[]; ReadyTasks[]; AwaitingApproval[]; NextTask }
      Test-TaskGate                 -> [pscustomobject]     { Passed=[bool]; Failed[]; Checked[] }
      Format-OrchestrationReport    -> [string]             painel determinístico (sem timestamp)

    Checkpoint humano: uma task pode declarar `type: checkpoint` (default `agent`). Checkpoint NUNCA
    entra em ReadyTasks — ReadyTasks é "o que se pode DESPACHAR a um subagente", e despachar um ponto
    de decisão humana a um agente é justamente o erro que o tipo existe para impedir. Ele sai em
    AwaitingApproval; a aprovação é registrada no STATE como `passed` (ou `failed` = reprovado), então
    a retomada não repergunta.

    Determinismo: ordenação estável por Id; nenhuma data/timestamp na saída; quebras LF. Nada
    escreve em disco — a escrita do STATE e a invocação de Agent são runtime, conduzidas pelo líder.
#>

Set-StrictMode -Version Latest

# Critérios obrigatórios default do gate (extensível via -Required).
$script:DefaultGateCriteria = @('TestsGreen', 'LintClean', 'ArtifactConforms')

function ConvertFrom-OrchestrationState {
    <#
    .SYNOPSIS
        Mini-parser do STATE (yaml): lê os itens sob a chave de topo `tasks:` (layout fixo,
        ver orchestration.md). Item sem `id` é ignorado. `deps` inline `[a, b]`. Read-only.
        -StatePath ausente/inexistente -> @() (não lança).
        `type` ausente/desconhecido -> 'agent' (retrocompat: STATE antigo continua carregando).
        `output` ausente -> '' (idem). Ele guarda ONDE a saida bruta do subagente foi gravada; o
        parser precisa conhece-lo mesmo sem usa-lo, senao cada linha `output:` viraria uma
        "linha nao reconhecida" e o painel acusaria perda de task que nao houve.
        `method` ausente -> '' (idem). Guarda COMO atacar a task -- o campo do pacote de contexto
        que faltava (ORQUESTRA_PRESCREVE_TOPOLOGIA). Ele existe no STATE, e nao so na mensagem de
        invocacao, porque a retomada le o STATE e nao a memoria da conversa: metodo decidido no
        Passo 2 e nao gravado morre no primeiro `resume`. Mesma razao de `output`, mesma armadilha:
        ensinar o parser vem ANTES de pedir o campo na doc.
    .PARAMETER IgnoredLines
        [ref] opcional que recebe a CONTAGEM de linhas sob `tasks:` que não casaram nenhum campo
        conhecido. O parser ignora o que não entende — e uma linha malformada (indentação errada,
        YAML corrompido) faz a task inteira sumir sem erro, com o Total mentindo para menos. Contar
        é o que permite ao painel avisar em vez de silenciar. Campo fora do schema (ex.: `notes:`)
        também conta: "não reconhecido" é literalmente o que a contagem mede.
    .OUTPUTS
        [pscustomobject[]] { Id; Title; Dod; Model; Type; Output; Method; Deps[]; Status } — ordenado por Id.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$StatePath,
        [AllowNull()][ref]$IgnoredLines
    )

    if ($null -ne $IgnoredLines) { $IgnoredLines.Value = 0 }
    $ignored = 0

    if ([string]::IsNullOrWhiteSpace($StatePath) -or -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return @()
    }

    $lines = Get-Content -LiteralPath $StatePath -ErrorAction SilentlyContinue
    $inTasks = $false
    $cur = $null
    $tasks = [System.Collections.Generic.List[object]]::new()

    function New-TaskObject($t) {
        # Só 'checkpoint' é reconhecido; qualquer outro valor (ou ausência) vira 'agent' — um typo
        # em `type` NÃO pode virar um terceiro tipo silencioso.
        $type = if ("$($t.Type)".Trim().ToLowerInvariant() -eq 'checkpoint') { 'checkpoint' } else { 'agent' }
        [pscustomobject]@{
            Id     = $t.Id
            Title  = $t.Title
            Dod    = $t.Dod
            Model  = $t.Model
            Type   = $type
            Output = "$($t.Output)".Trim()
            Method = "$($t.Method)".Trim()
            Deps   = @($t.Deps)
            Status = if ($t.Status) { $t.Status } else { 'pending' }
        }
    }

    foreach ($line in $lines) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }

        # Chave de topo (sem indentação) → abre/fecha o bloco tasks.
        if ($line -match '^\S') {
            if ($cur -and $cur.Id) { $tasks.Add((New-TaskObject $cur)); $cur = $null }
            $inTasks = ($line -match '^\s*tasks\s*:')
            continue
        }

        if (-not $inTasks) { continue }

        # Linha sob `tasks:` antes do primeiro "- id:" não pertence a task nenhuma.
        if (-not $cur -and $line -notmatch '^\s*-\s*id\s*:') { $ignored++; continue }

        # Novo item da lista: "- id: <x>"
        if ($line -match '^\s*-\s*id\s*:\s*(.+?)\s*$') {
            if ($cur -and $cur.Id) { $tasks.Add((New-TaskObject $cur)) }
            $cur = @{ Id = $Matches[1].Trim().Trim('"').Trim("'"); Title = ''; Dod = ''; Model = ''; Type = ''; Output = ''; Method = ''; Deps = @(); Status = 'pending'; Seen = @{} }
        }
        elseif ($cur) {
            # Chave repetida no MESMO item é YAML inválido, e aqui tem uma causa concreta: quando um
            # "- id:" não casa (indentação errada, lixo antes do hífen), os campos da task seguinte
            # são absorvidos por esta — sobrescrevendo `status`/`deps` já lidos. A task não só some,
            # ela corrompe a anterior. Contar a repetição faz o aviso medir o estrago real.
            if ($line -match '^\s*(title|dod|model|type|output|method|status|deps)\s*:') {
                $key = $Matches[1]
                if ($cur.Seen.ContainsKey($key)) { $ignored++ } else { $cur.Seen[$key] = $true }
            }
            if ($line -match '^\s*title\s*:\s*(.+?)\s*$')      { $cur.Title  = $Matches[1].Trim().Trim('"').Trim("'") }
            elseif ($line -match '^\s*dod\s*:\s*(.+?)\s*$')    { $cur.Dod    = $Matches[1].Trim().Trim('"').Trim("'") }
            elseif ($line -match '^\s*model\s*:\s*(.+?)\s*$')  { $cur.Model  = $Matches[1].Trim().Trim('"').Trim("'") }
            elseif ($line -match '^\s*type\s*:\s*(.+?)\s*$')   { $cur.Type   = $Matches[1].Trim().Trim('"').Trim("'") }
            elseif ($line -match '^\s*output\s*:\s*(.+?)\s*$') { $cur.Output = $Matches[1].Trim().Trim('"').Trim("'") }
            elseif ($line -match '^\s*method\s*:\s*(.+?)\s*$') { $cur.Method = $Matches[1].Trim().Trim('"').Trim("'") }
            elseif ($line -match '^\s*status\s*:\s*(.+?)\s*$') { $cur.Status = $Matches[1].Trim().Trim('"').Trim("'") }
            elseif ($line -match '^\s*deps\s*:\s*\[(.*)\]\s*$') {
                $inner = $Matches[1].Trim()
                $depList = @()
                if ($inner) { $depList = @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ }) }
                $cur.Deps = $depList
            }
            else { $ignored++ }
        }
    }
    if ($cur -and $cur.Id) { $tasks.Add((New-TaskObject $cur)) }

    if ($null -ne $IgnoredLines) { $IgnoredLines.Value = $ignored }
    return @($tasks | Sort-Object Id)
}

function Get-OrchestrationStatus {
    <#
    .SYNOPSIS
        Deriva o estado resumível da orquestração a partir do STATE. Read-only, determinística.
        ReadyTasks       = tasks 'pending' do tipo 'agent' com deps TODAS 'passed' — despacháveis a
                           um subagente (em paralelo).
        AwaitingApproval = tasks 'pending' do tipo 'checkpoint' com deps TODAS 'passed' — exigem
                           decisão HUMANA; nunca são despacháveis.
        MissingOutputs   = tasks 'agent' já 'passed' cujo `output` ficou vazio — a saída do
                           subagente foi julgada e não foi para o disco. Informativo: NÃO muda
                           NextTask nem reprova nada (ver a nota abaixo).
        Idempotente (não rebaixa 'passed').

        STATE que não carregou (path ausente/inexistente, ou arquivo sem task nenhuma) -> NextTask
        'no-state', NUNCA 'done'. "Não consegui ler o STATE" e "a orquestração terminou" são fatos
        opostos, e o segundo faz o líder parar de orquestrar. É o mesmo modo de falha que a contagem
        não-terminal abaixo corrige por dentro (status desconhecido sumindo das contagens), só que
        pela porta de fora: slug errado no nome, cwd diferente, pasta ainda não criada ou path em
        formato que o PowerShell não resolve davam todos 'done' com 0/0.
    .OUTPUTS
        [pscustomobject] { Objective; Total; Passed; Failed; Pending; Awaiting; IgnoredLines; Tasks[]; ReadyTasks[]; AwaitingApproval[]; MissingOutputs[]; NextTask }
        NextTask: <id despachável> | 'awaiting-approval' | 'blocked' | 'done' | 'no-state'.
    .NOTES
        POR QUE `MissingOutputs` É AVISO E NÃO GATE (2026-08-26). O texto final de um subagente
        **não está no transcript** — ele chega pela notificação da task e morre com a sessão.
        Duas perdas medidas neste laboratório, por caminhos diferentes: rodada 8, transcript de
        subagente com 0 bytes (a métrica primária da rodada ficou sem instrumento); rodada 9, o
        relatório do revisor do braço `M9` teve de ser reconstruído à mão a partir das citações.
        O dano é **recuperável e assimétrico**: reprovar o gate por falta de `output` pararia uma
        orquestração inteira por um arquivo que talvez nem devesse existir (task trivial), enquanto
        avisar custa uma linha no painel que o líder já lê. A disciplina mora na postura
        (§Ciclo do líder, passo 2.3: persistir ANTES de julgar); isto é o backstop que a torna
        visível em vez de silenciosa.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$StatePath)

    $objective = ''
    if (-not [string]::IsNullOrWhiteSpace($StatePath) -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        foreach ($line in (Get-Content -LiteralPath $StatePath -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*objective\s*:\s*(.+?)\s*$') { $objective = $Matches[1].Trim().Trim('"').Trim("'"); break }
        }
    }

    $ignored = 0
    $tasks = @(ConvertFrom-OrchestrationState -StatePath $StatePath -IgnoredLines ([ref]$ignored))
    $passedIds = @($tasks | Where-Object { $_.Status -eq 'passed' } | ForEach-Object { $_.Id })

    $ready = [System.Collections.Generic.List[string]]::new()
    $awaiting = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $tasks) {
        if ($t.Status -ne 'pending') { continue }
        $depsMet = $true
        foreach ($d in @($t.Deps)) { if ($passedIds -notcontains $d) { $depsMet = $false; break } }
        if (-not $depsMet) { continue }
        if ($t.Type -eq 'checkpoint') { $awaiting.Add($t.Id) } else { $ready.Add($t.Id) }
    }
    $ready    = @($ready | Sort-Object)
    $awaiting = @($awaiting | Sort-Object)

    # Só tasks 'agent': um checkpoint é decisão humana, não tem saída de subagente para gravar.
    $missing = @($tasks |
            Where-Object { $_.Type -eq 'agent' -and $_.Status -eq 'passed' -and [string]::IsNullOrWhiteSpace($_.Output) } |
            ForEach-Object { $_.Id } | Sort-Object)

    $passed = @($tasks | Where-Object { $_.Status -eq 'passed' }).Count
    $failed = @($tasks | Where-Object { $_.Status -eq 'failed' }).Count
    # Não-terminal, não `-eq 'pending'`: um status desconhecido (typo, estado improvisado) precisa
    # contar como trabalho aberto. Contando só 'pending', o painel dizia `done` com task em aberto.
    $pending = @($tasks | Where-Object { $_.Status -ne 'passed' -and $_.Status -ne 'failed' }).Count

    # 'no-state' ANTES de tudo: sem task nenhuma não há o que despachar, mas também não há nada
    # concluído — 0/0 não é sucesso, é ausência de STATE.
    $next =
        if ($tasks.Count -eq 0)                   { 'no-state' }
        elseif ($ready.Count -gt 0)               { $ready[0] }
        elseif ($awaiting.Count -gt 0)            { 'awaiting-approval' }
        elseif ($pending -gt 0 -or $failed -gt 0) { 'blocked' }
        else                                      { 'done' }

    return [pscustomobject]@{
        Objective        = [string]$objective
        Total            = [int]$tasks.Count
        Passed           = [int]$passed
        Failed           = [int]$failed
        Pending          = [int]$pending
        Awaiting         = [int]$awaiting.Count
        IgnoredLines     = [int]$ignored
        Tasks            = $tasks
        ReadyTasks       = @($ready)
        AwaitingApproval = @($awaiting)
        MissingOutputs   = @($missing)
        NextTask         = [string]$next
    }
}

function Test-TaskGate {
    <#
    .SYNOPSIS
        Gate determinístico do resultado de uma task: passa só se TODOS os critérios obrigatórios
        forem $true no -Result. Critério obrigatório ausente no -Result conta como FALHA (nunca passa
        por omissão). O gate semântico entra como mais um critério booleano (ex.: ReviewApproved) ao
        ser incluído em -Required. Puro.
    .OUTPUTS
        [pscustomobject] { Passed=[bool]; Failed=[string[]]; Checked=[string[]] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Result,
        [string[]]$Required = $script:DefaultGateCriteria
    )

    function Get-CriterionValue($obj, [string]$key) {
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($key)) { return [bool]$obj[$key] }
            return $null
        }
        $prop = $obj.PSObject.Properties[$key]
        if ($prop) { return [bool]$prop.Value }
        return $null
    }

    $checked = @($Required | Sort-Object -Unique)
    $failed = foreach ($c in $checked) {
        $v = Get-CriterionValue $Result $c
        if ($v -ne $true) { $c }   # ausente ($null) ou $false -> falha
    }
    $failed = @($failed)

    return [pscustomobject]@{
        Passed  = [bool]($failed.Count -eq 0)
        Failed  = $failed
        Checked = $checked
    }
}

function Get-OrchestrationMode {
    <#
    .SYNOPSIS
        Decide o REGIME antes de decompor: 'solo' | 'minimo' (+worktree/+checkpoint) | 'completo'.
        Puro, sem I/O.

        O gatilho anterior ("objetivo que se decompõe em >=3 tasks com dependências") era
        AUTO-REFERENTE: quem julgava se decompõe era o líder que já queria decompor — qualquer
        objetivo passa. `workflow-sdd.md` §Match the Form to the Failure manda amarrar comportamento
        condicional a um PREDICADO OBSERVÁVEL; este é o observável.

        Medido (ORCHESTRATE_BASELINE, rodada 1, 2026-08-11): na carga que cabia num só contexto,
        solo / 3x-sequencial / orquestrado marcaram os MESMOS 19/20, a 1x / 2,9x / 5,1x de tokens.
        Orquestrar sem fronteira material não compra qualidade — compra custo.

    .PARAMETER Disciplines
        Disciplinas DISTINTAS que o objetivo toca (ex.: 'code','data','infra','doc','ui').
        Contagem >= 2 pede REVISÃO (modo mínimo). Não é fronteira de decomposição: contar disciplinas
        não mede se o trabalho cabe — medido e reprovado na rodada 2.
    .PARAMETER FitsSingleContext
        $true se o material necessário (arquivos a ler + a produzir) cabe no contexto de UM agente.
        $false é a ÚNICA fronteira de máquina de estado que sobrou: é a hipótese que a orquestração
        de fato afirma.

        SOZINHO ELE NÃO ABRE MAIS O 'completo' — precisa de -ReductionAttempted. Motivo em uma frase:
        este parâmetro é AUTO-RELATO, e auto-relato foi exatamente o defeito que o gatilho anterior
        tinha. Ver a nota do -ReductionAttempted.
    .PARAMETER ReductionAttempted
        $true se a REDUÇÃO já foi tentada e falhou: você escreveu (ou tentou escrever) a ferramenta
        que resolveria o material e ela não deu conta. É o que destrava o 'completo'.

        POR QUE ISTO EXISTE, e é o defeito que a correção anterior não pegou. O gatilho pré-2026-08-11
        (">=3 tasks com dependências") foi trocado por ser AUTO-REFERENTE: quem julgava se decompõe era
        o líder que já queria decompor. Mas -FitsSingleContext é auto-relato pela MESMA porta — quem
        informa $false é o mesmo líder, e nada o contradiz. Trocou-se o nome da pergunta, não a
        natureza dela; a prova é que a doc precisava pedir por escrito "antes de informar $false,
        pergunte se um script resolveria", que é regra sem mecanismo no meio do que se anunciava como
        mecanismo. Em nove rodadas do ORCHESTRATE_BASELINE o predicado nunca ganhou apoio — não havia
        o que apoiar: era uma opinião com tipo [bool].

        POR QUE A PERGUNTA É ESTA e não "quantos bytes tem o material". Rodada 3 (2026-08-11): três
        corpora construídos para NÃO caber, os três derrotados pelo mesmo mecanismo — o agente acha a
        estrutura do material e escreve ~100 linhas de parser. O pior deles (1200 funções únicas,
        186k tok, defeitos a 1%) saiu 1230/1230 no braço SOLO, a 78k tokens, parseando docstrings.
        VOLUME NÃO É A PERGUNTA; IRREDUTIBILIDADE É — e por isso a função não mede o material sozinha:
        medir daria volume, que é justamente a métrica reprovada. Irredutibilidade não é computável;
        "você tentou reduzir?" é um fato que o chamador tem ou não tem.

        Rodada 9 (2026-08-25), a única que exerceu a fronteira: mesmo corpus, mesmo juiz, Opus nos três
        braços — recall 1/14 (solo) · 0/14 (mínimo) · 1/14 (particionado), com o particionado gastando
        4,5x. Não comprou recall. É o que sustenta cobrar um fato antes de liberar o regime caro.
    .PARAMETER IsolationRequired
        $true se tasks escrevem nos MESMOS arquivos em paralelo. Exige WORKTREE — não exige máquina
        de estado, e por isso NÃO escala para 'completo'. Rodada 4 (2026-08-11), carga canônica do
        isolamento (8 tarefas independentes tocando os mesmos dois arquivos): nem o braço paralelo
        sem isolamento nem o isolado+merge usaram STATE ou gate — foi paralelismo puro, e a colisão
        real que houve foi ruidosa e recuperável. Em quatro rodadas a máquina de estado nunca foi
        necessária. Limite da evidência: n=1, e o conflito testado foi append em arquivo pequeno.
    .PARAMETER OutwardAction
        $true se o objetivo inclui ação outward (publicar, enviar, deploy, PR, push em repo público)
        — exige PARADA para o humano. Não escala para 'completo': a parada é barata, o STATE é caro.
    .OUTPUTS
        [pscustomobject] { Mode; Reason; Signals }
          solo              -> Agent direto, sem STATE, sem gate. Nenhuma fronteira observável.
          minimo            -> executor + 1 revisor fresh-context. Sem STATE de 5 tasks.
          minimo+worktree   -> idem, com cada task concorrente em worktree próprio e merge no fim.
          minimo+checkpoint -> idem, com parada obrigatória para o humano antes de cada ação outward.
          completo          -> o ciclo do protocolo (decompor/STATE/gate/checkpoint).

        Os sufixos COMPÕEM ('minimo+worktree+checkpoint' é regime legítimo): cada um nomeia um
        mecanismo ORTOGONAL e barato, e fazer um vencer o outro perderia o que o perdedor comprava.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Disciplines = @(),
        [bool]$FitsSingleContext = $true,
        [bool]$ReductionAttempted = $false,
        [bool]$IsolationRequired = $false,
        [bool]$OutwardAction = $false
    )

    $distinct = @($Disciplines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                  ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)

    $signals = [pscustomobject]@{
        DisciplineCount   = $distinct.Count
        Disciplines       = $distinct
        FitsSingleContext = $FitsSingleContext
        ReductionAttempted = $ReductionAttempted
        # Nasce SEMPRE, vazia quando nao houve negativa: propriedade que so existe as vezes LANCA
        # sob Set-StrictMode, e todo command que dot-sourceia tools/ roda com ele ligado
        # (rules/tooling.md). Consumidor nao deveria precisar de um Test-Path de propriedade.
        CompletoNegado = ''
        IsolationRequired = $IsolationRequired
        OutwardAction     = $OutwardAction
    }

    # A ÚNICA fronteira de máquina de estado: o material não cabe no contexto de um agente. É a
    # hipótese que a orquestração de fato afirma, e a única coisa que o modo mínimo não contorna.
    #
    # A contagem de disciplinas NÃO está aqui — ela sozinha foi medida e reprovou. Rodada 2 do
    # ORCHESTRATE_BASELINE (2026-08-11), carga de 3 disciplinas (code/data/doc): o ciclo completo
    # (6 agentes, 363k tok) e o modo mínimo (3 agentes, 167k tok) marcaram o MESMO 24/25 no juiz
    # cego. As 3 tasks extras não compraram um único check. Disciplina é sinal de que há revisão a
    # fazer — não de que há trabalho que não cabe.
    #
    # O ISOLAMENTO também saiu daqui, e pela mesma régua (rodada 4, 2026-08-11): na carga canônica
    # de escrita concorrente — 8 tarefas nos mesmos dois arquivos — nem o braço paralelo nem o
    # isolado usaram STATE ou gate. O que a fronteira exige é worktree, e worktree é barato; STATE
    # de N tasks é caro. Acoplar os dois repete a forma que a fronteira outward tinha antes do campo
    # 01: cara amarrada ao barato. Em quatro rodadas a máquina de estado nunca foi necessária.
    # ...mas 'não cabe' é AUTO-RELATO, e auto-relato foi o defeito do gatilho anterior. O regime caro
    # exige o fato que a rodada 3 mostrou ser o único relevante: a redução foi tentada e falhou. Sem
    # ele, cai para o que os demais sinais derem — o material continua grande, e continua sendo
    # provável que ~100 linhas de parser o resolvam.
    if (-not $FitsSingleContext -and -not $ReductionAttempted) {
        $signals.CompletoNegado = 'reducao-nao-tentada'
    }

    if (-not $FitsSingleContext -and $ReductionAttempted) {
        $motivos = @('o material não cabe no contexto de um agente E a redução foi tentada e falhou')
        # Isolamento sozinho não chega aqui, mas quando acompanha o material que não cabe ele
        # continua sendo um requisito do plano — some da Reason e o líder perde a instrução.
        if ($IsolationRequired) { $motivos += 'e tasks concorrentes exigem isolamento (worktree)' }
        return [pscustomobject]@{
            Mode    = 'completo'
            Reason  = 'fronteira de máquina de estado: ' + ($motivos -join ' · ')
            Signals = $signals
        }
    }

    # Sufixos do modo mínimo: mecanismos ORTOGONAIS e baratos. Cada um nomeia UMA coisa que o par
    # executor+revisor não faz sozinho — isolar escrita concorrente; parar para o humano — e nenhum
    # deles pede máquina de estado. Compõem em vez de disputar: fazer um vencer o outro descartaria
    # o mecanismo do perdedor, que é justamente o erro que 'outward -> completo' cometia.
    #
    # Observado em uso real (campo 01, 2026-08-11, setup-rustdesk): o trabalho terminou em push,
    # PR e merge num repositório PÚBLICO — outward inequívoco — e eram 53 linhas, nenhuma de
    # código. `completo` teria cobrado STATE e gate por task para isso. O que a ação outward de
    # fato exigiu foram dois checkpoints (escolha da licença; autorização do PR/merge), e o ciclo
    # rodou como 'minimo' com essas duas paradas.
    $sufixos = @()
    $porques = @()
    # Quando o 'completo' foi negado por falta do fato, o líder tem de saber DISSO — senão lê o
    # 'minimo' como se nenhuma fronteira tivesse sido alegada, e a instrução (tente o script) some.
    $negado = if ($signals.CompletoNegado) {
        ' · `completo` NÃO liberado: -FitsSingleContext $false é auto-relato e a redução não foi tentada — escreva a ferramenta que resolveria o material (rodada 3: três corpora feitos para não caber, os três derrotados por ~100 linhas de parser) e só volte com -ReductionAttempted $true se ela falhar'
    } else { '' }
    if ($IsolationRequired) {
        $sufixos += 'worktree'
        $porques += 'escrita concorrente: cada task em worktree próprio e merge no fim (isolamento, não máquina de estado)'
    }
    if ($OutwardAction) {
        $sufixos += 'checkpoint'
        $porques += 'ação outward: PARADA obrigatória para o humano antes de cada passo que sai da máquina'
    }

    if ($sufixos.Count -gt 0) {
        return [pscustomobject]@{
            Mode    = 'minimo+' + ($sufixos -join '+')
            Reason  = 'executor + 1 revisor fresh-context · ' + ($porques -join ' · ') + $negado
            Signals = $signals
        }
    }

    # Sem fronteira estrutural. O revisor fresh-context COM CHECKLIST se paga e é barato:
    # medido na rodada 2, o modo mínimo empatou com o ciclo completo (24/25) a 46% do custo, e o
    # checklist custou +10% no revisor. O que se paga é a revisão com repertório externo; o que
    # cobra é a decomposição em N tasks.
    if ($distinct.Count -ge 2) {
        return [pscustomobject]@{
            Mode    = 'minimo'
            Reason  = "sem fronteira estrutural, mas $($distinct.Count) disciplinas: executor + 1 revisor fresh-context com checklist" + $negado
            Signals = $signals
        }
    }

    return [pscustomobject]@{
        Mode    = 'solo'
        Reason  = 'nenhuma fronteira observável — orquestrar aqui custa sem comprar (ver ORCHESTRATE_BASELINE)' + $negado
        Signals = $signals
    }
}

function Format-OrchestrationReport {
    <#
    .SYNOPSIS
        Painel determinístico do estado da orquestração (sem timestamp). Marca por task:
        ✓ passed · ✗ failed · • ready · ⏸ awaiting-approval (checkpoint) · – pending.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Status)

    $ready = @($Status.ReadyTasks)
    # Retrocompat com um $Status montado à mão (sem o campo): trata como lista vazia.
    # O @() envolve a expressão INTEIRA: um `if` que devolve array de 1 item o desembrulha para
    # escalar, e aí `.Count` não existe sob Set-StrictMode.
    $awaiting = @(if ($Status.PSObject.Properties['AwaitingApproval']) { $Status.AwaitingApproval } else { @() })

    # Retrocompat com $Status montado à mão, igual ao AwaitingApproval acima.
    $ignoredLines = if ($Status.PSObject.Properties['IgnoredLines']) { [int]$Status.IgnoredLines } else { 0 }
    $missing = @(if ($Status.PSObject.Properties['MissingOutputs']) { $Status.MissingOutputs } else { @() })

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    $header = if ([string]::IsNullOrWhiteSpace($Status.Objective)) { '(sem objective)' } else { $Status.Objective }
    [void]$sb.Append("ORCHESTRATE — $header`n")
    if ([int]$Status.Total -eq 0) {
        [void]$sb.Append("  Nenhuma task carregada — o STATE não existe, está vazio ou não foi parseado.`n")
        [void]$sb.Append("  Confira o caminho do STATE e a indentação do bloco ``tasks:``.`n")
    }
    foreach ($t in @($Status.Tasks)) {
        $mark =
            if ($t.Status -eq 'passed')        { '✓' }
            elseif ($t.Status -eq 'failed')    { '✗' }
            elseif ($awaiting -contains $t.Id) { '⏸' }
            elseif ($ready -contains $t.Id)    { '•' }
            else                               { '–' }
        $deps = if (@($t.Deps).Count -gt 0) { ($t.Deps -join ', ') } else { '—' }
        $state =
            if ($t.Status -ne 'pending')       { $t.Status }
            elseif ($awaiting -contains $t.Id) { 'awaiting-approval' }
            elseif ($ready -contains $t.Id)    { 'ready' }
            else                               { $t.Status }
        [void]$sb.Append("  [$mark] $($t.Id)   (deps: $deps)   $state`n")
    }
    [void]$sb.Append("Progresso: $($Status.Passed)/$($Status.Total) passed · $($ready.Count) ready · $($awaiting.Count) awaiting · $($Status.Pending) pending · $($Status.Failed) failed`n")
    if ($ignoredLines -gt 0) {
        [void]$sb.Append("ATENÇÃO: $ignoredLines linha(s) do STATE não reconhecida(s) — task pode ter sido perdida. Verifique a indentação.`n")
    }
    if ($missing.Count -gt 0) {
        [void]$sb.Append("ATENÇÃO: $($missing.Count) task(s) aprovada(s) sem ``output`` no STATE ($($missing -join ', ')) — a saída do subagente foi julgada e não foi para o disco; o texto final NÃO está no transcript.`n")
    }
    [void]$sb.Append("Próximo: $($Status.NextTask)`n")
    [void]$sb.Append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n")
    return $sb.ToString()
}

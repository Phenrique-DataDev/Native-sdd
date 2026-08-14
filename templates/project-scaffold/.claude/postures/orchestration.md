# Orquestração — protocolo completo do líder (sob demanda)

> **Carregado sob demanda**, não always-on. A rule [`../rules/orchestration.md`](../rules/orchestration.md)
> guarda o **gatilho** (quando orquestrar) e os invariantes que evitam erro grave; este arquivo tem o
> protocolo de execução — ciclo, gate, checkpoint, paralelismo, schema do STATE e destino. Lido pelo
> [`/orchestrate`](../commands/orchestrate.md). Numa sessão que não orquestra: **0 token**.

## Princípio

Dado um **objetivo** ou um **plano aprovado**, o líder decompõe em tasks, dá contexto a subagentes,
**valida** cada resultado contra um gate e encadeia/paraleliza — registrando estado **resumível**.
O STATE + o DoD por task existem, entre outros motivos, para conter *goal drift* (perda de fidelidade
ao objetivo original ao longo de muitas iterações, sobretudo após compactação de contexto): cada
retomada relê o STATE em vez de reconstruir o objetivo da memória. Acionado por
**`/orchestrate <objetivo>`**. O líder roda no **nível principal** (sem subagente→subagente) — ver a
nota abaixo: é **escolha de design**, não limite da plataforma.

> **Nível único é escolha, não limitação (D).** Desde o **Claude Code v2.1.172** um subagente pode
> spawnar subagentes (basta `Agent` no `tools`); aqui **deliberadamente não usamos** isso — os agentes
> base não declaram `Agent` no frontmatter, então o encadeamento fica **só no líder**. Motivo: se um
> subagente liderasse outros, o líder ficaria cego ao encadeamento interno e o `Test-TaskGate` não
> rodaria entre os subpassos (só o resumo do topo retorna) — perderia o valor desta regra (gate
> determinístico + STATE resumível + observabilidade). `connects_to` é **dica de roteamento**, não
> poder de chamada do subagente. Fan-out read-only sem gate já tem caminho melhor: `/orchestrate` +
> Workflow sob `/max`. _(fonte: context7, verificado 2026-06-20)_

> **Gatilho `ultracode` → Workflow, não este ciclo.** Quando o pedido do usuário contém a palavra
> `ultracode` (opt-in de multiagente reconhecido pelo próprio Claude Code), o líder deve preferir emitir
> o **Workflow nativo** em vez do ciclo `Agent` síncrono descrito nesta regra — definição do gatilho em
> [`max-mode.md`](../postures/max-mode.md) §(a). Sem esse gatilho, o protocolo abaixo continua sendo o **default**.

## Antes do ciclo: qual regime? (rode o predicado)

O ciclo abaixo é o regime **`completo`**. Ele não é o default — é o caso caro, e só se paga quando
há **fronteira de máquina de estado**: o material não cabe num contexto, ou há escrita concorrente
exigindo isolamento. **Contar disciplinas não basta** — medido
na rodada 2 do `ORCHESTRATE_BASELINE`, o modo mínimo empatou com o ciclo completo (24/25) por 46% do
custo numa carga de 3 disciplinas. Rode o predicado (`rules/orchestration.md` §Gatilho) e **diga o `Mode` ao
usuário** antes de decompor:

```powershell
. "$toolsRoot/orchestrate.ps1"
$mode = Get-OrchestrationMode -Disciplines @('code','data') -FitsSingleContext $false
"$($mode.Mode) — $($mode.Reason)"
```

`solo` → não orquestre. `completo` → o ciclo abaixo. `minimo` e `minimo+checkpoint` → as duas
seções a seguir.

### Modo mínimo — executor + 1 revisor fresh-context

**Antes de gastar o primeiro token: pergunte.** O `minimo` é **opt-in** e o preço é conhecido —
`AskUserQuestion` com o número na mão, não em texto corrido:

> *"O predicado deu `minimo`: há duas disciplinas e material para revisar. A revisão fresh-context
> com checklist custa **~2,4×** o solo (**~4×** se o revisor também corrigir) e, medida em seis
> rodadas, compra qualidade de forma consistente. Pago?"* → **`solo` (default)** · **revisor só
> reporta (~2,4×)** · **revisor + correção (~4×)**.

Sem resposta, o default é `solo`. Quem paga escolhe; o framework não impõe o custo em silêncio.

Sem STATE de N tasks, sem decomposição, sem gate por etapa. **Dois agentes:**

1. **Executor** — recebe o objetivo inteiro e entrega. É o braço solo.
2. **Revisor** — `code-reviewer`, contexto novo, **carrega
   [`../checklists/review-repertoire.md`](../checklists/review-repertoire.md)** e responde item por
   item **com execução**. Achou defeito → volta ao executor com a reprodução; **não** conserta ele
   mesmo.

Termina quando o revisor não tem `[FALHA]` com reprodução. **Se o segundo ciclo de revisão não
achar nada novo, pare** — não promova para o regime `completo` por sensação de incompletude.

> **O mínimo empatou com o completo — medido.** Rodada 2 (2026-08-11), carga de 3 disciplinas:
> `completo` (6 agentes, 363k tok) e `minimo` (3 agentes, 167k tok) marcaram **ambos 24/25** no juiz
> cego, contra 23/25 do solo. O check extra veio do item *"BOM no início do arquivo"* do checklist —
> caminho auditável: item → divergência → fix → check. As três tasks extras do `completo` (design,
> CLI/doc e testes separados) não compraram nada.
>
> **Por que o mínimo é dois e não cinco.** Medido em
> `ORCHESTRATE_BASELINE` (2026-08-11): o ciclo completo de 5 tasks numa carga sem fronteira gastou
> **5,1×** os tokens do solo para marcar **o mesmo 19/20** — e ~93k desses tokens foram gastos
> achando e desfazendo um defeito que **a própria decomposição introduziu** e que o braço solo nunca
> teve. Decompor cria fronteiras onde não havia; cada fronteira é um lugar onde o contexto se perde.
>
> No mesmo experimento, um braço **sem protocolo nenhum** rodado 3× em sequência achou, na segunda
> passada, um defeito real que a suíte verde não pegava. Ou seja: **a revisão de contexto fresco é a
> parte que se paga; a decomposição em N tasks é a parte que cobra.** O modo mínimo fica com a
> primeira. O que ele acrescenta à simples repetição é **obrigatoriedade** — a 2ª passada podia não
> ter procurado nada, e a 3ª de fato não procurou.

### Modo mínimo + checkpoint — quando o trabalho sai da máquina

Idêntico ao modo mínimo, com **uma** obrigação a mais: **pare e pergunte ao humano antes de cada
ação outward** — push, PR, merge, deploy, envio, publicação, qualquer escrita fora deste disco.

A parada é a coisa toda. Ela não precisa de STATE, de task `type: checkpoint`, nem de gate: precisa
que você **não execute** o passo até haver resposta. Duas formas, nesta ordem:

1. **Decisão que é do dono, não sua** (licença, nome público, preço, texto que sai assinado):
   `AskUserQuestion` com as opções reais e o custo de cada uma. Não escolha por default.
2. **Autorização para a ação em si** (abrir o PR, mergear, publicar): peça em texto, com o que
   exatamente vai acontecer e o que já foi verificado. Aprovação de um passo **não** vale para o
   seguinte — autorizar o PR não autoriza o merge.

Entre a parada e a resposta, **faça tudo o que não depende dela**. Bloquear a entrega inteira
esperando uma decisão é o outro modo de errar aqui.

> **Por que isto não é o ciclo `completo`.** Até o campo 01 (2026-08-11), ação outward escalava para
> `completo`, com a justificativa de que *checkpoint humano só existe como estado do STATE*. É
> verdade sobre o STATE e irrelevante para a decisão: a parada é barata, a máquina de estado é cara,
> e amarrar uma na outra é a mesma forma da fronteira de disciplina que a rodada 2 derrubou.
>
> Observado em uso real: atualizar um repositório recém-tornado público terminou em push, PR e
> merge — outward inequívoco — e eram **53 linhas, nenhuma de código**. O ciclo `completo` teria
> cobrado STATE e gate por task. O que a ação outward de fato exigiu foram **duas paradas** (escolha
> da licença; autorização do PR/merge), e ambas aconteceram no modo mínimo.
>
> O STATE continua sendo a resposta certa quando **o próprio ciclo** é longo o bastante para não
> caber numa sessão — aí a aprovação precisa sobreviver à retomada, e `type: checkpoint` é como ela
> sobrevive. Isso é a fronteira de volume, não a de outward.

## Ciclo do líder

1. **Decompor** — quebrar o objetivo em tasks com **DoD** (Definition of Done), `deps` e **modelo**
   sugerido. Gravar o **STATE** em `.claude/sdd/orchestration/STATE_<slug>.yaml` (schema abaixo).
2. **Para cada task PRONTA** (deps todas `passed` — ver Paralelismo):
   1. **Contexto** — montar o *pacote*: o **artefato da fase** (regra `workflow-sdd`: passe o
      artefato anterior) + arquivos relevantes + o **DoD** como critério + o **modelo** sugerido.
   2. **Invocar** — `Agent` com `subagent_type`, `prompt` = pacote, `model`. É **síncrono** (retorna
      `result`). Para plano grande/independente, usar o **handoff externo** (ver Destino).
   3. **Validar** — montar o `Result` (testes/lint/conformidade [+ `code-reviewer`]) e rodar o
      **gate** (ver abaixo). Passou → marcar a task `passed` no STATE. Falhou → **re-invocar com
      feedback** (ver abaixo).
   4. **Encadear/paralelizar** — disparar as tasks prontas (ver Paralelismo) e seguir.
3. **Estado** — a cada task, atualizar o STATE. Retomar lê o STATE e continua de onde parou
   (idempotente: tasks `passed` não são refeitas).

## Pacote de contexto (como "dar contexto")

| Item | Conteúdo |
|------|----------|
| Artefato | o documento da fase anterior (BRAINSTORM/DEFINE/DESIGN…) — `workflow-sdd` |
| Arquivos | caminhos concretos que a task toca |
| Critério | o **DoD** da task (o que o gate vai cobrar) |
| Modelo | o modelo sugerido (ex.: Opus 4.8 para trabalho denso) |

## Gate de validação

Só avança se o gate passa (espelha `Test-CurationReadiness` do `/init`).

- **Determinístico** (`Test-TaskGate`, `tools/orchestrate.ps1`): critérios como **dados** — default
  `TestsGreen`, `LintClean`, `ArtifactConforms`. Critério obrigatório ausente conta como **falha**
  (nunca passa por omissão).
- **Semântico** (opcional): o subagente **`code-reviewer`** julga o output; o veredito entra como um
  critério booleano (ex.: `ReviewApproved`) incluído em `-Required` → combinado por **AND**. É
  **fresh-context**, não o mesmo agente que produziu o output — mitiga *self-preferential bias* (a
  tendência de um agente aprovar o próprio trabalho quando pedido para verificá-lo; ver
  [`max-mode.md`](../postures/max-mode.md) §Alavancagem).

  **Obrigatório: o revisor carrega [`../checklists/review-repertoire.md`](../checklists/review-repertoire.md)
  antes de revisar,** e responde item por item com execução (`[ok]` / `[FALHA]` + reprodução /
  `[n/v]` + razão). Revisão sem o checklist **não** vale como `ReviewApproved`.

  > **Fresh-context não é fresh-perspectiva.** Contexto novo troca a *memória*, não o *repertório*:
  > um revisor do **mesmo modelo** não vê o que aquele modelo não vê. Medido
  > (`ORCHESTRATE_BASELINE`, 2026-08-11): o mesmo **ponto cego** passou por **três topologias** —
  > solo, iteração simples e este ciclo com revisor fresh-context — em 9 invocações e ~467k tokens.
  > Era detecção de delimitador, e a função estava na biblioteca padrão.
  >
  > *Self-preferential bias* é real e o fresh-context o mitiga — mas **não foi** o modo de falha
  > observado em nenhum dos três braços. O que falhou foi **falta de repertório**, e repertório só
  > entra de fora: checklist versionado, KB do projeto, ferramenta determinística, ou revisor de
  > **modelo diferente** (não apenas de tier maior — ver `agent-routing.md` §Política de modelo,
  > que hoje só conhece potência, não lente). Mais agentes do mesmo modelo re-executam o mesmo
  > repertório e custam como se não o fizessem.

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/orchestrate.ps1"
$gate = Test-TaskGate -Result @{ TestsGreen = $true; LintClean = $true; ArtifactConforms = $true; ReviewApproved = $true } `
                      -Required @('TestsGreen','LintClean','ArtifactConforms','ReviewApproved')
# $gate.Passed -> bool ; $gate.Failed -> critérios reprovados (vira o feedback)
```

## Checkpoint humano — o gate que nenhum critério automático responde

O gate acima cobre o que a **máquina** consegue julgar. Um **ponto de decisão do humano** ("qual das
3 abordagens?", "pode publicar?", "esse texto está certo?") não é `TestsGreen` nem `ReviewApproved` —
e, se ficar só no fluxo da conversa, **some na retomada**: a sessão compacta, o líder relê o STATE, e
a aprovação que existia só no chat não está lá.

Por isso a task declara **`type`**:

| `type` | Quem executa | Entra em `ReadyTasks`? |
|--------|--------------|------------------------|
| `agent` (default; ausente = este) | subagente, via `Agent` | **sim** — é o que se despacha |
| `checkpoint` | **o humano** | **nunca** — sai em `AwaitingApproval` |

**Checkpoint nunca é despachável.** `ReadyTasks` significa *"o que posso mandar para um subagente
agora"*; mandar um ponto de decisão humana para um agente é exatamente o erro que este tipo existe
para impedir — o agente responderia, e a resposta pareceria uma aprovação.

**O ciclo do checkpoint:**

1. `Get-OrchestrationStatus` põe o checkpoint pronto (deps `passed`) em **`AwaitingApproval`**.
2. O líder **pergunta ao humano** — `AskUserQuestion` numa sessão interativa; sem interatividade,
   **pare e diga** que a cadeia está esperando (não decida no lugar dele).
3. A resposta vira **estado no STATE**: aprovado → `status: passed`; reprovado → `status: failed`
   (a cadeia a jusante fica `blocked`, que é o comportamento correto — não `passed`).
4. Retomar não repergunta: a aprovação está gravada.

**`NextTask` ganhou um quarto valor:** `awaiting-approval` — há checkpoint esperando e **nada
despachável**. Se houver task `agent` pronta em paralelo, `NextTask` continua sendo ela (o checkpoint
não trava o que não depende dele) e o checkpoint segue listado em `AwaitingApproval`.

```yaml
  - id: aprovar-abordagem
    title: escolher entre as 2 abordagens do DESIGN
    dod: humano escolheu A ou B, e a escolha está no STATE
    type: checkpoint
    deps: [design]
    status: pending        # -> passed (aprovado) | failed (reprovado)
```

O veredito humano também pode entrar no `Test-TaskGate` como mais um critério booleano — sem código
novo: `Test-TaskGate -Result @{ HumanApproved = $true } -Required @('HumanApproved')`.

> **Não transforme toda task em checkpoint.** O valor do ciclo é a máquina julgar o que a máquina
> julga; o checkpoint é para a decisão que **só o humano** pode tomar (escolha entre alternativas
> viáveis, autorização de ação outward, aceite de conteúdo). Se um critério verificável responde,
> ele é gate — não checkpoint.

## Re-invocação com feedback

Ao **falhar** o gate, re-invocar o subagente passando `$gate.Failed` como **feedback** explícito (o
que reprovou). Limite **`MaxAttempts = 2`** re-invocações; esgotado → task `failed` (o estado fica
`blocked` se isso travar a cadeia). O *loop* é condução (aqui, prompt); o que é determinístico é o
`Failed[]` do gate.

## Paralelismo

`Get-OrchestrationStatus` expõe **`ReadyTasks`** = tasks `pending` **do tipo `agent`** cujas deps
estão **todas** `passed`. Tasks independentes prontas → **várias chamadas `Agent` na mesma mensagem**
(rodam em paralelo). Checkpoints prontos saem à parte, em **`AwaitingApproval`** (ver acima).

`NextTask` é o primeiro despachável (ordem estável) ou um dos quatro sentinelas:

| `NextTask` | Significa | O que o líder faz |
|------------|-----------|-------------------|
| `<id>` | task `agent` pronta | despacha (com as demais de `ReadyTasks`, em paralelo) |
| `awaiting-approval` | nada despachável, há checkpoint pronto | **pergunta ao humano** |
| `blocked` | há trabalho, nada pronto (dep `failed`/ciclo) | investiga a cadeia |
| `done` | tudo terminal (`passed`/`failed`) | encerra |
| `no-state` | **nenhuma task carregada** — STATE inexistente, vazio ou não parseado | **confere o caminho do STATE**; não encerra |

> **`done` só sai com tudo terminal.** `Pending` conta *não-terminal*, não `status == pending` — um
> status improvisado (`aguardando-humano`, um typo) conta como trabalho aberto. Antes disso o painel
> reportava **`done`** com uma task em aberto, e improvisar um status era justamente o que se fazia na
> falta do `type: checkpoint`.

> **`no-state` nunca é `done`.** `0/0 passed` não é sucesso, é ausência de STATE — e a diferença
> importa porque o líder que lê `done` **para de orquestrar**. Caminho com slug errado, `cwd`
> diferente, pasta `orchestration/` ainda não criada ou path em formato que o PowerShell não resolve
> caem todos aqui. É o mesmo modo de falha do parágrafo acima, pela porta de fora: lá o trabalho
> aberto sumia da contagem, aqui o STATE inteiro.

> **Linha não reconhecida é avisada, não engolida.** O parser ignora o que não casa o schema, e uma
> linha malformada (indentação errada, lixo antes do `-`) faz a task **sumir e ainda sobrescrever a
> anterior** — `status: passed` já lido vira o `status` da task perdida. `IgnoredLines` conta essas
> linhas e o painel imprime `ATENÇÃO: N linha(s) ... não reconhecida(s)`. Campo fora do schema
> (ex.: `notes:`) também conta — "não reconhecido" é o que a contagem mede.

## Destino: subagente na sessão × novo chat externo

- **Padrão — subagente na mesma sessão** (`Agent`): síncrono/paralelo/resume; o líder coleta o
  `result` e valida.
- **Handoff externo** — emitir a instrução *"plano aprovado, rode em novo chat com Opus 4.8"* quando:
  (a) o objetivo é um **plano grande e independente** que estouraria o contexto atual, ou (b) o
  usuário quer **continuar noutro chat/máquina**. É instrução **ao humano** (texto), não chamada de
  ferramenta.

## Schema do STATE (`.claude/sdd/orchestration/STATE_<slug>.yaml`)

```yaml
objective: implementar a feature X
tasks:
  - id: decompor
    title: levantar subtasks
    dod: lista de tasks com DoD
    model: opus-4-8
    deps: []
    status: passed        # pending | passed | failed
  - id: impl
    title: implementar core
    dod: testes verdes + lint limpo
    model: opus-4-8
    type: agent           # agent (default, pode omitir) | checkpoint
    deps: [decompor]      # inline, separado por vírgula
    status: pending
  - id: aprovar
    title: aceite do humano antes de publicar
    dod: humano aprovou explicitamente
    type: checkpoint      # nunca despachado a subagente — sai em AwaitingApproval
    deps: [impl]
    status: pending
```

> `type` é **opcional e retrocompatível**: ausente (ou com valor desconhecido) = `agent`. STATE
> escrito antes desta seção continua carregando sem mudança. Um typo em `type` **não** cria um
> terceiro tipo silencioso — degrada para `agent`.

`Get-OrchestrationStatus -StatePath <arquivo>` lê este STATE (read-only) e deriva o progresso +
`ReadyTasks` + `NextTask`. `Format-OrchestrationReport` imprime o painel.

## O que NÃO fazer

- **Não** construir engine/daemon de orquestração — `Agent` nativo já invoca/aguarda/paraleliza/resume.
- **Não** orquestrar multi-nível (subagente liderando subagentes) — o líder fica no topo. É **escolha
  de design** (gate + STATE + observabilidade), não limite da plataforma: o Claude Code **suporta**
  aninhamento desde v2.1.172, mas aqui os agentes não recebem a ferramenta `Agent` de propósito (nota
  no **Princípio**).
- **Não** avançar com o gate reprovado — re-invocar com feedback ou marcar `failed`.
- **Não** inventar o resultado de uma task — o `Result` do gate vem de verificação real (testes/lint).
- **Não** despachar um `type: checkpoint` a um subagente, nem responder por ele — a resposta de um
  agente pareceria uma aprovação, e é o único ponto do ciclo em que a máquina não é juiz.
- **Não** deixar a aprovação só na conversa — sem `status` gravado no STATE, a retomada repergunta
  (ou, pior, segue como se tivesse aprovado). O checkpoint só vale registrado.
- **Não** marcar checkpoint reprovado como `passed` para "destravar" — reprovado é `failed`, e a
  cadeia `blocked` é a informação correta.

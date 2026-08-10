# Orquestração — protocolo do líder (sempre aplicado)

> O **líder não é um engine**: é o **agente principal** seguindo este protocolo. `invocar`,
> `aguardar`, `paralelizar` e `resume` são a ferramenta **`Agent` nativa** — não reimplemente um
> motor de orquestração. O valor desta regra é o **ciclo** (como o líder conduz) e os **gates de
> validação** (como aceita/rejeita um resultado antes de seguir).

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

```text
. tools/orchestrate.ps1
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

`NextTask` é o primeiro despachável (ordem estável) ou um dos três sentinelas:

| `NextTask` | Significa | O que o líder faz |
|------------|-----------|-------------------|
| `<id>` | task `agent` pronta | despacha (com as demais de `ReadyTasks`, em paralelo) |
| `awaiting-approval` | nada despachável, há checkpoint pronto | **pergunta ao humano** |
| `blocked` | há trabalho, nada pronto (dep `failed`/ciclo) | investiga a cadeia |
| `done` | tudo terminal (`passed`/`failed`) | encerra |

> **`done` só sai com tudo terminal.** `Pending` conta *não-terminal*, não `status == pending` — um
> status improvisado (`aguardando-humano`, um typo) conta como trabalho aberto. Antes disso o painel
> reportava **`done`** com uma task em aberto, e improvisar um status era justamente o que se fazia na
> falta do `type: checkpoint`.

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

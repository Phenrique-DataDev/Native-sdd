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
há **fronteira de máquina de estado**, que hoje é **uma só**: o material não cabe num contexto.
**Contar disciplinas não basta** — medido
na rodada 2 do `ORCHESTRATE_BASELINE`, o modo mínimo empatou com o ciclo completo (24/25) por 46% do
custo numa carga de 3 disciplinas. Rode o predicado (`rules/orchestration.md` §Gatilho) e **diga o `Mode` ao
usuário** antes de decompor:

```powershell
. "$toolsRoot/orchestrate.ps1"
$mode = Get-OrchestrationMode -Disciplines @('code','data') -FitsSingleContext $false
"$($mode.Mode) — $($mode.Reason)"
```

`solo` → não orquestre. `completo` → o ciclo abaixo. `minimo` e seus sufixos (`+worktree`,
`+checkpoint`, ou os dois) → as seções a seguir.

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

### Modo mínimo + worktree — quando as tasks escrevem nos mesmos arquivos

Idêntico ao modo mínimo, com **uma** obrigação a mais: cada task concorrente roda em seu **próprio
worktree**, e o merge acontece no fim. É isolamento de sistema de arquivos — **não** é máquina de
estado, e por isso **não** puxa STATE, gate por task nem decomposição em N tasks.

Como o líder opera: crie o worktree por task antes de despachar (`git worktree add`), passe o
caminho no pacote de contexto do subagente, e faça o merge você mesmo ao coletar — **um por vez**,
lendo o resultado de cada um. Se dois agentes tocaram a mesma região, o conflito é seu para
resolver: ele é a razão de existir do isolamento, não um imprevisto.

> **Por que isto não é o ciclo `completo`.** Até a rodada 4 (2026-08-11), escrita concorrente
> escalava para `completo`. A medição derrubou a premissa na carga **canônica** do isolamento — 8
> tarefas independentes tocando os mesmos dois arquivos:
>
> | Braço | Checks | Tokens |
> |---|---|---|
> | Sequencial (sem paralelismo nenhum) | 26/26 | **42.836** |
> | Paralelo, **sem isolamento nenhum** | 26/26 | 307.311 |
> | Paralelo, **isolado + merge** | 26/26 | 299.795 |
>
> **Nem o braço paralelo nem o isolado usaram STATE ou gate** — foi paralelismo puro. Houve colisão
> real (um agente teve o *append* sobrescrito, **detectou e reaplicou**): perda ruidosa e
> recuperável, o oposto do que a fronteira precisava provar. Paralelizar comprou **tempo**
> (66 s → 29 s) por **7× os tokens**. Em quatro rodadas a máquina de estado nunca foi necessária.
>
> **Limites da evidência, e eles são reais:** n=1, e o conflito testado foi *append* em arquivo
> pequeno. Um conflito estrutural em arquivo grande pode se comportar de outro jeito — o que a
> medição sustenta é que o isolamento não **implica** STATE, não que nunca conviva com ele.
>
> **E note o que a tabela também diz:** paralelizar custou 7× para marcar o mesmo placar. Antes de
> pedir worktree, pergunte se o sequencial não resolve — o isolamento é o mecanismo certo *quando
> você já decidiu paralelizar*, não uma razão para paralelizar.

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

> **O `completo` cobra um fato, não uma opinião (2026-08-26).** `-FitsSingleContext $false` é
> auto-relato: quem informa "não cabe" é o mesmo líder que já quer decompor. Era exatamente o defeito
> do gatilho anterior (`>=3 tasks`), que sobreviveu à própria correção com nome novo — e é por isso
> que nenhuma das nove rodadas do `ORCHESTRATE_BASELINE` sustentou o predicado: não havia o que
> sustentar. Para o regime caro sair é preciso `-ReductionAttempted $true` — você escreveu a
> ferramenta que resolveria o material e ela falhou. Sem isso a função devolve o modo barato com a
> instrução dentro da `Reason`.
>
> A pergunta é essa e não "quantos bytes", porque **volume já foi reprovado como fronteira**: na
> rodada 3 os três corpora construídos para não caber foram derrotados pelo mesmo mecanismo — ~100
> linhas de parser —, e o pior deles saiu **1230/1230 no braço solo**. Irredutibilidade não é
> computável; *"você tentou reduzir?"* é um fato que se tem ou não se tem.

## Ciclo do líder

1. **Decompor** — quebrar o objetivo em tasks com **DoD** (Definition of Done), `deps` e **modelo**
   sugerido. Gravar o **STATE** em `.claude/sdd/orchestration/STATE_<slug>.yaml` (schema abaixo).
2. **Para cada task PRONTA** (deps todas `passed` — ver Paralelismo):
   1. **Contexto** — montar o *pacote*: o **artefato da fase** (regra `workflow-sdd`: passe o
      artefato anterior) + arquivos relevantes + o **DoD** como critério + o **modelo** sugerido.
   2. **Invocar** — `Agent` com `subagent_type`, `prompt` = pacote, `model`. É **síncrono** (retorna
      `result`). Para plano grande/independente, usar o **handoff externo** (ver Destino).
   3. **Persistir** — gravar o texto que voltou em
      `.claude/sdd/orchestration/out/<task-id>.md`, **bruto e inteiro**, e apontar o caminho no
      campo `output:` da task no STATE. Isto vem **antes** de julgar, resumir ou extrair qualquer
      coisa — ver §*O dado mais caro é o que não sobrevive*.
   4. **Validar** — montar o `Result` (testes/lint/conformidade [+ `code-reviewer`]) e rodar o
      **gate** (ver abaixo). Passou → marcar a task `passed` no STATE. Falhou → **re-invocar com
      feedback** (ver abaixo).
   5. **Encadear/paralelizar** — disparar as tasks prontas (ver Paralelismo) e seguir.
3. **Estado** — a cada task, atualizar o STATE. Retomar lê o STATE e continua de onde parou
   (idempotente: tasks `passed` não são refeitas).

## O dado mais caro é o que não sobrevive

**O texto final de um subagente não está no transcript.** O transcript guarda as etapas
intermediárias — as tool calls, o raciocínio, os arquivos abertos. O **resultado** chega pela
notificação da task e vive só ali: fechada a sessão, ele não existe em lugar nenhum. É o item mais
caro que a orquestração produz (foi ele que consumiu o subagente inteiro) e o único que não fica.

Medido duas vezes neste framework, **por caminhos diferentes** — que é o motivo de a correção ser
um passo do ciclo e não um lembrete:

| Quando | O que se perdeu | Por qual caminho |
|---|---|---|
| Rodada 8 do `ORCHESTRATE_BASELINE` | a cobertura de leitura — a **métrica primária** da rodada | transcript do subagente existia no caminho informado, com **0 bytes** |
| Rodada 9 | o relatório final do revisor do braço `M9` | transcript com conteúdo, mas **sem o texto final**; foi preciso reconstruir as citações à mão |

**A regra, então:** grave a saída **no instante em que ela chega**, antes de julgar qualquer coisa.
Julgar primeiro e gravar depois é o mesmo que não gravar — se o gate reprovar e você re-invocar, o
texto original já foi embora, e com ele a única evidência do que o agente de fato respondeu.

Isto **generaliza** a regra que a §*Gate de validação* já impõe ao revisor de repertório (*"o líder
transcreve a resposta — o revisor é read-only e não pode gravá-la"*). A causa é a mesma nos dois
casos, e o remédio também: **quem grava é sempre o líder**, porque é ele que ainda tem o texto na
mão.

> **Backstop, não gate.** `Get-OrchestrationStatus` devolve `MissingOutputs` — tasks `agent` já
> `passed` com `output` vazio — e o painel avisa. Não reprova: o dano é recuperável, e travar uma
> orquestração inteira por um arquivo que talvez nem devesse existir custaria mais que a perda.
> Avisar é o que transforma um esquecimento silencioso em algo que aparece na tela que o líder já lê.

## Pacote de contexto (como "dar contexto")

| Item | Conteúdo |
|------|----------|
| Artefato | o documento da fase anterior (BRAINSTORM/DEFINE/DESIGN…) — `workflow-sdd` |
| Arquivos | caminhos concretos que a task toca |
| Critério | o **DoD** da task (o que o gate vai cobrar) |
| **Método** | **como atacar** — campo `method` do STATE. Veja abaixo: é o único item desta tabela que correlacionou com achar defeito |
| Modelo | o modelo sugerido (ex.: Opus 4.8 para trabalho denso) |

### Método — o campo que faltava, e por que ele não é a topologia

**Topologia é quantos agentes; método é como cada um ataca.** O regime já sai de um predicado
(`Get-OrchestrationMode`), e ele fica — duas medições o corrigiram e ele funciona. O que **nenhum**
campo entregava era o ataque, e era esse que se movia junto com o resultado.

| Sinal | Força da evidência |
|---|---|
| **Método** correlacionou com achar defeito | `n=2` — os dois únicos acertos de uma rodada |
| **Regime** correlacionou com achar defeito | `n=9` rodadas, **não** correlacionou (delta 0 p.p. a 4,5× o custo) |

Está escrito assim de propósito: `n=2` é pouco, e prometer certeza aqui seria o mesmo defeito que a
linha de rodadas passou nove tentativas desmontando. O que sustenta o campo não é só a correlação —
é que **entregá-lo custa uma linha** e a alternativa era não dizer nada.

**O que prescrever, quando a task é achar defeito** (o repertório já existe, e mora nos agentes —
`test-writer` §*invariantes*, `debugger` §*oráculo*; o que faltava era **entregá-lo com a task**):

- **Oráculo executável diferencial** — escreva um segundo motor que responda à mesma pergunta e
  deixe a divergência apontar. Foi o único método que achou algo.
- **Invariante + fuzz** — declare o que vale para toda entrada válida; o framework gera os casos.
- **Round-trip** — `decode(encode(x)) == x`, idempotência, comutatividade.

**E o contra-exemplo, que é o achado desconfortável:** **todo** braço que auditou **por leitura** deu
zero — inclusive o que tinha metade dos defeitos plantados no próprio escopo. Mandar *"revise com
atenção"* não é método; é a ausência dele com cara de instrução.

> **O `code-reviewer` do gate não executa este método, e isso é por desenho — não o forçe.** Ele é
> **read-only** (sem `Write`/`Edit`): construir um segundo motor exige escrever arquivo, e ele não
> pode. A consequência é prática, e ignorá-la é esperar do revisor um trabalho que o contrato dele
> proíbe: quando a task **é** caçar defeito, o oráculo é trabalho de **executor** (`test-writer`,
> `debugger`) e entra como task própria — a revisão julga o resultado dele. Revisor read-only auditando
> por leitura é exatamente a configuração que deu zero nas medições.

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
  `[n/v]` + razão), **cada linha prefixada pelo ID do item** (`IO-01`, `CT-02`…). Revisão sem o
  checklist **não** vale como `ReviewApproved`.

  **O líder transcreve a resposta** na §*Revisão de repertório* do `BUILD_REPORT` — o revisor é
  read-only e não pode gravá-la. Sem essa transcrição a atribuição *item → achado* morre com a
  sessão, e o checklist perde o único critério que o poda (§*Quando um item sai*).

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
    method: oráculo diferencial contra o parser de referência   # COMO atacar (§Pacote de contexto)
    output: .claude/sdd/orchestration/out/impl.md   # onde a saida BRUTA do subagente foi gravada
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
>
> `output` também é opcional e retrocompatível (ausente = `''`), mas a **ausência dele numa task
> `agent` já `passed` é o que o painel acusa** (`MissingOutputs`). O parser precisa conhecer o campo
> mesmo quem não o usa: sem isso, cada linha `output:` contaria como *linha não reconhecida* e o
> painel avisaria de uma task perdida que não se perdeu.
>
> `method` é opcional e retrocompatível pela mesma regra (ausente = `''`) e **mora no STATE, não só
> na mensagem de invocação** — a retomada lê o STATE e não a memória da conversa, então método
> decidido no Passo 2 e não gravado morre no primeiro `resume`. Ele **não** tem backstop no painel:
> ao contrário de `output`, ausente pode ser legítimo (nem toda task é caçada de defeito), e avisar
> sempre treinaria o líder a ignorar o aviso.

`Get-OrchestrationStatus -StatePath <arquivo>` lê este STATE (read-only) e deriva o progresso +
`ReadyTasks` + `NextTask`. `Format-OrchestrationReport` imprime o painel.

## O registro das medições — de onde vem cada número do gatilho

Isto **não** é instrução: é a prova por trás das decisões que a `rules/orchestration.md` enuncia em
uma linha cada. Mora aqui porque prova se lê quando alguém **contesta** o número, não em toda sessão.

**O preço do `minimo`, medido em seis rodadas.** A revisão fresh-context **compra qualidade de forma
consistente** — R2 +1 check, R5 +2, R6 o único 25/25 de todas as rodadas — e custa **~2,4× no piso**,
**~4×** se o revisor também corrigir. Três tentativas de chegar a 2,0× falharam (**3,2× · 3,06× ·
4,34×**): o alvo exigia que revisar custasse menos que executar, e revisão que compra check custa
aproximadamente o mesmo que executar. Na rodada 6 o revisor custou **54.624** e o *fix* **78.728** —
revisão que acha mais gera correção maior. É trabalho real, não desperdício, e por isso quem decide
vê a conta inteira antes de dizer sim.

**Por que o predicado substituiu o gatilho antigo.** Ele dizia: *objetivo que se decompõe em três ou
mais tasks com dependências*. Era **auto-referente** — quem julga se decompõe é o líder que já quer
decompor, e qualquer objetivo passa. `rules/workflow-sdd.md` §*Match the Form to the Failure* manda
amarrar comportamento condicional a um **predicado observável**; aquele gatilho era a exceção que não
seguia a regra da própria casa.

**Sem fronteira estrutural, orquestrar não compra qualidade — compra custo.** Rodada 1
(`ORCHESTRATE_BASELINE`, 2026-08-11), carga que cabia com folga num só contexto: **solo · 3×
sequencial · orquestrado** marcaram os **mesmos 19/20** num juiz cego, a **1× · 2,9× · 5,1×** de
tokens.

**Contar disciplinas não é fronteira — foi medido e reprovou.** Rodada 2, carga de 3 disciplinas
(code/data/doc): o ciclo **completo** (6 agentes, 363k tok) e o **modo mínimo** (3 agentes, 167k tok)
marcaram o **mesmo 24/25** no juiz cego, e o orquestrado ganhou do solo (23/25). As três tasks extras
não compraram um único check. O ganho medido vem da **revisão com repertório externo**, não da
decomposição em N tasks. Disciplina é sinal de que **há revisão a fazer** — não de que há trabalho
que não cabe.

**Volume não é a pergunta — irredutibilidade é.** Rodada 3 (2026-08-11): três corpora foram
construídos de propósito para **não caber** num contexto, e os três caíram pelo **mesmo** mecanismo —
o agente acha a estrutura do material e escreve ~100 linhas de parser, trocando "ler o corpus" por
"rodar a ferramenta".

| Corpus | Tamanho | Braço solo |
|---|---|---|
| v1 — 50 módulos clones | 153k tok | 600/600 · 66k tok (agrupou por AST; o defeito era o único outlier) |
| v2 — + implementações corretas equivalentes | — | ataque simulado ainda achava 10/12 (38% × acaso de 24%) |
| v3 — 1200 funções **únicas**, defeitos a 1% | 186k tok | **1230/1230 · 78k tok** (parseou as docstrings) |

A v3 era séria: 1196 formas de código distintas em 1200 funções, contrato em prosa com 3 formulações
por passo, defeitos verificados como alteradores de resultado, juiz cego reprovando exatamente os 12
plantados. Caiu porque **3 formulações é vocabulário fechado**, e fechado é parseável — o braço
confirmou isso por regex antes de confiar no próprio parser. O modo mínimo marcou o mesmo 1230/1230
a 2,4× (189k tok); o `completo` **não foi rodado**, por mérito declarado: o instrumento não media a
fronteira alvo, então 6 agentes dariam outro empate e nenhuma informação.

**O que isso diz do produto:** `FitsSingleContext` pergunta *"cabe?"*, e caber é irrelevante quando o
material é **redutível**. A pergunta que discriminaria é *"é irredutível?"*.

> **Duas coisas escritas aqui caíram, e ficam registradas em vez de reescritas.**
>
> **1. *"A fronteira de volume nunca foi exercida com sucesso"* — caiu em 2026-08-25.** A **rodada 9**
> a exerceu: mesmo corpus e mesmo juiz da R8, trocando Haiku por **Opus nos três braços**. Recall
> `A9` **1/14** · `M9` **0/14** · `C9` **1/14**, custo total **1.629.760 tok** — o regime particionado
> **não comprou recall** gastando **4,5×**. A fronteira foi exercida e **não apareceu**. O gatilho de
> reabertura continua o mesmo e continua de mérito: alguém achar uma carga que resista a um parser.
>
> **2. *"Não virou parâmetro novo, de propósito"* — revertido em 2026-08-26**, e o argumento que a
> sustentava era bom: *trocar um sinal que não sei medir por outro que também não sei medir só muda o
> nome do problema*. O que o derruba é uma distinção que o texto original não fazia:
>
> | Sinal | O que ele pergunta | Quem pode responder com certeza |
> |---|---|---|
> | `-FitsSingleContext` | uma **propriedade do material** — *cabe?* | ninguém: é estimativa sobre o mundo |
> | `-ReductionAttempted` | um **ato do líder** — *você escreveu o parser?* | o líder, sempre: ou o script existe ou não |
>
> Os dois são auto-relato. Só que o segundo relata um **ato caro e verificável**, não um palpite — e
> é por isso que ele discrimina. `-FitsSingleContext $false` sozinho deixou de abrir o `completo`.

O corolário utilizável continua o mesmo, agora **cobrado pela função** em vez de pedido em prosa: se
um script resolve, o material cabe numa ferramenta, não num contexto — e o regime caro só se abre
depois que esse script foi tentado e falhou.

**Isolamento pede worktree, não máquina de estado** (rodada 4, 2026-08-11) — a tabela e os limites
da evidência estão na §*Modo mínimo + worktree*, acima.

**Outward compra uma parada, não uma máquina de estado** (campo 01, 2026-08-11). Ação outward exige
**uma** coisa — a parada para o humano — e parada é barata; STATE de N tasks é caro. Acoplar os dois
repetia a forma da fronteira de disciplina que a rodada 2 já tinha derrubado. Observado em uso real:
um trabalho que terminou em push, PR e merge num repositório público — outward inequívoco — eram 53
linhas, nenhuma de código. Rodou como `minimo` com duas paradas humanas e entregou.

**Por que o protocolo saiu da rule.** Ele custava ~5.200 tokens em **toda** sessão — a rule mais cara
do always-on — para valer nas poucas em que alguém de fato orquestra. Nada foi removido: o
`/orchestrate` carrega este arquivo, e o gatilho da rule diz quando lê-lo sem o command.

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
- **Não** julgar a saída de um subagente antes de gravá-la. O texto final não está no transcript;
  se o gate reprovar e você re-invocar, o original foi embora — e some justamente a evidência do que
  o agente respondeu. Grave bruto, aponte em `output:`, **depois** julgue.
- **Não** gravar só o resumo ou o trecho que interessou. O que serve à sessão de hoje não é o que
  serve à auditoria de amanhã; o corte é decisão de quem lê depois, não de quem grava.
- **Não** deixar a aprovação só na conversa — sem `status` gravado no STATE, a retomada repergunta
  (ou, pior, segue como se tivesse aprovado). O checkpoint só vale registrado.
- **Não** marcar checkpoint reprovado como `passed` para "destravar" — reprovado é `failed`, e a
  cadeia `blocked` é a informação correta.

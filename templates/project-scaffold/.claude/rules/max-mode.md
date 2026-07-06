# Modo MAX — operação máxima sob demanda (postura, opt-in)

> Modo de sessão que usa a metodologia **no máximo**: lê todo o contexto, **recomenda** potência,
> aciona o **orquestrador-mestre** e **reduz a fricção do não-crítico** — **sem ir contra a espinha**.
> É **permissão-só, guardas mantidos**: nunca relaxa um guarda de segurança nem a verificação de
> qualidade. Acionado por **`/max`**; cessa em **`/max off`**. Sem engine — orquestração é `Agent`
> nativo ([`orchestration.md`](orchestration.md)); potência é a política de modelo ([`agent-routing.md`](agent-routing.md)/B9).

## Princípio

Num trabalho denso, ligar potência/contexto à mão e ser interrompido por prompts de ações **triviais**
custa fluxo. O MAX compõe o que já existe (orquestração + modelo/effort + inventários de contexto) num
**preset declarativo**: quando ligado, o agente opera no máximo **e** mantém **todas** as defesas. A
autonomia vem de *menos prompts no não-crítico + orquestração*, **não** de *desligar guardas*.

**Decisão de mecanismo (D-001, via context7):** hooks e settings carregam **no início da sessão**;
editar em runtime **não** afeta a sessão corrente. Por isso o MAX **não** escreve `permissions`/settings/
hooks. A redução de fricção do não-crítico vem do **modo de permissão `auto` da sessão** (default) + esta
postura; os guardas já estão carregados e **intocados** → seguem interceptando o crítico (`deny`>`ask`>`allow`).

## O MAX eleva × o MAX nunca toca

| Eleva (quando ligado) | Nunca toca |
|-----------------------|------------|
| **Contexto** — lê tudo (KB/memória/skills/MCPs/hooks); orçamento G8 silenciado | **Guardas** de segurança (main-push / secret / destructive / managed `deny`) |
| **Orquestração** — aciona `/orchestrate` p/ objetivo decomponível (paralelo co-dep/indep) | **Verificação de qualidade** (testes/lint/gates SDD; **fases** SDD) |
| **Potência** — **recomenda** modelo maior + `effort` alto | O **modelo** à força — segue `model: inherit` (B9); a troca é da sessão |
| **Fricção** — menos prompts no **não-crítico** (via modo `auto`) | settings / hooks / `permissions`; **`bypassPermissions`** |

## Classes não-críticas × sempre-crítico

| Não-crítico (não interromper) | Sempre crítico (respeita guarda/prompt) |
|-------------------------------|------------------------------------------|
| `Read`, `Grep`, `Glob`, `LS`, navegação | escrita/edição destrutiva; `git push`/`merge` |
| `Bash` read-only (`ls`, `cat`, `rg`, `git status`/`diff`/`log`, `gh … list`/`view`) | leitura de segredo (`.env`, `secrets/**`); `rm -rf`; `chmod -R`/`chown -R` |
| | CLIs de dados/cloud destrutivas (`DROP`/`TRUNCATE`, `aws s3 rm`, `terraform destroy`) |

> A lista é a referência da postura (e do aviso) — **não** é escrita em `permissions`. A decisão real de
> cada ação ainda passa pelo modo `auto` + os hooks, que **vencem** o auto-aprovar.

## Alavancagem (H7) — Workflow nativo + arsenal seguro

O MAX usa as **tecnologias nativas no máximo** sem virar motor. Três regras de operação:

### (a) Escolha de orquestrador — `/orchestrate` × **Workflow nativo**

| Sinal do objetivo | Use | Por quê |
|-------------------|-----|---------|
| Poucas tasks **sequenciais com gate** / encadeamento dependente | **`/orchestrate`** ([`orchestration.md`](orchestration.md), `Agent` síncrono) | gate determinístico + re-invocação com feedback; o líder coleta cada `result` |
| **Fan-out de N itens**, **pipeline** sobre uma work-list, ou **loop-until-dry/budget** | **emitir Workflow nativo** | paralelismo massivo + pipeline + `budget` + resume — ordens de grandeza mais potente |

Regra de bolso: **≥ ~5 itens independentes** ou **multi-estágio sobre lista** ou **escala incerta** →
**Workflow**; senão `/orchestrate`. O Workflow **não substitui** o `/orchestrate` — é o **degrau de cima**.

**Gatilho por palavra-chave — `ultracode` (opt-in explícito, além da heurística de escala).** O próprio
Claude Code trata a palavra **`ultracode`** no pedido do usuário (ou a sessão com ultracode ligado) como
**opt-in explícito** para orquestração multiagente via `Workflow` nativo — independente do objetivo bater
os sinais de escala da tabela acima. Ao ver `ultracode`:

- **Prefira `Workflow`** mesmo para objetivo pequeno/sequencial que caberia em `/orchestrate` — o pedido
  explícito do usuário **substitui** a regra de bolso, não a contradiz.
- **Não** interprete a ausência de `ultracode` como proibição de `Workflow` — a heurística de escala
  continua valendo por si; a palavra é **um** gatilho de opt-in a mais, não o único.
- O **reconhecimento** da palavra é do harness (fora do controle desta regra); aqui só documentamos
  **como o hub reage** quando o opt-in chega. Mesmo gatilho referenciado em
  [`orchestration.md`](orchestration.md) e [`agent-routing.md`](agent-routing.md) — esta seção é a
  **fonte única** da definição (não duplique).

**Por que multiagente ajuda — grounding, não hype.** A ferramenta `Workflow` nativa existe para
combater três falhas que a **janela única** sofre em tarefa longa/complexa (Anthropic, *"A harness
for every task"*, 2026-06):

| Falha | O que acontece | Como o fan-out mitiga |
|-------|-----------------|------------------------|
| **Agentic laziness** | o agente para antes de terminar e declara "completo" após progresso parcial | cada etapa vira **um agente com DoD próprio** — o líder audita cada retorno, não confia no "terminei" |
| **Self-preferential bias** | o agente tende a aprovar o próprio output quando pedido para verificá-lo | verificação por **subagente de fresh-context** separado — é por isso que o gate semântico do `/orchestrate` usa `code-reviewer`, não auto-avaliação (ver [`orchestration.md`](orchestration.md)) |
| **Goal drift** | o objetivo original se perde ao longo de muitas iterações (piora após compactação de contexto) | **STATE resumível** + DoD explícito por task ancoram o objetivo a cada passo, em vez de reconstruí-lo da memória |

Isso **não** é motivo para usar Workflow em tudo — o próprio artigo adverte: tarefa de codificação
**regular** não precisa de painel de 5 revisores, e Workflow **custa mais tokens**. A regra de bolso
acima (≥5 itens/pipeline/escala incerta) já filtra por isso; use-a antes de escalar.

**Vocabulário de padrões (nomeado pela própria ferramenta `Workflow` nativa — não redefina aqui).**
Ao desenhar um script, reconheça o padrão em vez de improvisar a estrutura: **classify-and-act**
(um classificador roteia por tipo de tarefa), **fan-out-and-synthesize** (decompõe → 1 agente por
parte → sintetiza), **generate-and-filter** (gera N candidatos → filtra por rubrica/dedup),
**tournament** (comparação par-a-par até vencedor — mais confiável que score absoluto p/ ranking),
**adversarial verify** (um segundo agente tenta **refutar**, não confirmar) e **loop-until-dry**
(spawna até N rodadas seguidas sem achado novo, não um número fixo de passes). Detalhe/exemplos de
cada um vêm da descrição da própria ferramenta `Workflow` ("quality patterns"/"canonical multi-stage
pattern") — esta linha só nomeia o vocabulário para reconhecimento rápido.

### (b) Fronteira de disparo do Workflow — **só não-mutador / não-outward**

Sob MAX, um Workflow **auto-emitido** (sem confirmar cada disparo) é restrito a fan-out **não-mutador e
não-outward**: **ler / analisar / gerar-em-scratch** (review amplo, auditoria, varredura, síntese de
pesquisa, mapeamento). Fica **no loop principal** (onde o humano atende o `ask`/confirma):

| Classe | Fica no loop principal (não vai p/ subagente de workflow) |
|--------|------------------------------------------------------------|
| Mutador que dispara `ask` | escrita/edição destrutiva, `rm -rf`, `chmod -R`, git destrutivo |
| Toca segredo | leitura de `.env`/`secrets` (secret-guard `ask`) |
| Outward-facing | `git push`/PR, publicar/release, **browser**, **deep-research** (web) |

> **Por construção:** sem ação `ask`/outward dentro do subagente, **não há** guarda interativo a disparar
> num fan-out paralelo/background (onde não haveria operador p/ atender). A segurança **não depende** de
> "o guarda dispara dentro do workflow" (fato não confirmado) — a fronteira a torna **inalcançável**.

### (c) Roteamento do arsenal — por **classe de risco**

| Gatilho | Ferramenta | Classe | Sob MAX |
|---------|------------|--------|---------|
| Doc de lib/framework/CLI versionável | **context7** (`resolve`→`query`) | bounded (nome de lib/tópico) | **auto-fire** |
| Buscar/ler local, mapear código | `Read`/`Grep`/`Glob`/`Bash` read-only | local | **auto-fire** |
| Diagrama/relatório/plano visual | **visual-explainer** (HTML local) | local (scratch/`docs`, não publica) | **auto-fire** |
| Trabalho de **disciplina** com suplemento no repertório (design · data · security · reporting · docs · ai · meta) | **suplemento do tema** (`/supplements`, skills opt-in, `-ExtraPlugins -Themes`) | local | **auto-fire só na disciplina do tema** |
| Pesquisa web multi-fonte | **deep-research** | **outward** (query do contexto → exfiltração) | **confirmar** |
| Navegar/agir em página | **browser/chrome** | **outward** + efeito | **confirmar** |
| Publicar/compartilhar (share-page, push, PR, release) | — | **outward** | **confirmar** |

> **Outward = confirmar a cada uso, mesmo sob MAX.** Só o **bounded/local** auto-dispara. O rótulo
> "não-crítico" do bootstrap **não** se estende a ação de escala/outward.

> **Repertório de suplementos (`/supplements`) é opt-in e por-disciplina.** Skills/plugins curados
> (`tools/supplements.psd1`) instalados user-scoped sob `-ExtraPlugins -Themes` (ou `/supplements <tema>`):
> `design` (impeccable/ui-ux-pro-max), `reporting` (visual-explainer), `data`, `security`, `docs`
> (gerador-de-manuais), `ai`, `meta`.
> **Auto-surgem pela `description` da skill** só quando a tarefa é **daquela disciplina** — num projeto sem a
> superfície (ex.: sem UI num projeto de dados) ficam **inertes**; não force tooling fora do domínio. Se não
> instalados, simplesmente não estão no arsenal. **Não instalar conector que peça credencial/MCP** sem confirmar
> (fora do repertório curado por design).

## Usar a KB (aterrar o trabalho no conhecimento curado)

Ao montar o **pacote de contexto** de uma task (do `/orchestrate` ou de um Workflow), **consulte a KB do
domínio** e injete as entradas relevantes — por default as camadas **`operations`** (runbooks) e
**`implementation`** (schemas/IDs/nomes concretos), que aterram execução; `business`/`tools` entram se a
task for desse tipo. Reusa `Build-KbIndex` ([`kb-taxonomy.md`](kb-taxonomy.md)/G4) — **sem nova varredura**. O bootstrap já
**lê** o índice; aqui o hub **usa** o conhecimento (o subagente recebe a KB do domínio, não improvisa).

## Consciência de peers (H10) — coordenar antes de orquestrar

Sob MAX o líder opera como **orquestrador-mestre** e tende a **fan-out** (Workflow/`/orchestrate`). Se houver
**outra sessão concorrente** no mesmo projeto — em especial **outro MAX** —, dois mestres podem **atropelar
um ao outro** (editar a mesma área, refazer trabalho). A postura (sem engine; o quadro é o `/peers`, H10):

| Momento | O que fazer |
|---------|-------------|
| **Ao ligar o MAX / antes de um fan-out** | **Consulte `/peers`** (`tools/peers.ps1` `Get-PeerInventory`): há outra sessão ativa? em que branch/área (summary)? |
| **Há peer ativo na mesma área** | **Não** dispare o fan-out às cegas: ajuste o escopo p/ não colidir, **avise** o peer (`/peers msg <id> "vou orquestrar X em auth/"`) e, se a sobreposição for real, **confirme com o operador** antes de seguir. |
| **Você é um MAX e há outro MAX** | Trate como **divisão de trabalho**: anuncie seu escopo no `summary` (`/peers summary "MAX: refactor auth"`) e leia o do outro — dois mestres coordenados, não competindo pelo mesmo alvo. |
| **Sem peers** | Siga normal (você está sozinho no projeto). |

> É **leitura on-demand** (igual ao grafo): consulte o `/peers` **quando** for orquestrar — não despeje o
> board no contexto always-on. O peer board é runtime/efêmero (`.claude/.cache/peers/`), **não** entra no
> `graph.json` (estrutura curada, lifecycle diferente). Coordenação é **postura**, não trava.

## Custo — freio é o `budget` nativo do Workflow, não uma quota do MAX

O único freio mecânico de custo é o **`budget` nativo do Workflow**, que **deriva da diretiva do usuário**
(ex.: "+500k") e o próprio Workflow aplica (hard ceiling). O MAX **respeita/propaga** esse budget ao emitir
um Workflow — **não declara nem inventa um número de orçamento**. Coerente com o [`kb-taxonomy.md`](kb-taxonomy.md) (orçamento
**advisory**, sem teto/quota arbitrário — G8 v2) e com o norte *token é servo da qualidade*: generoso, nunca
punitivo.

## Meta-tooling efêmero (H8) — scratch descartável, promoção só pelo ciclo SDD

Sob MAX, o líder pode **gerar um utilitário efêmero** (script/harness de uso único) para acelerar a
task — desde que **descartável** e **gitignored**. É alavancagem barata; **não** é uma máquina nova nem
um atalho para criar ferramenta permanente. **Núcleo mínimo, sem engine:** é uma **convenção/guarda**,
não um pipeline de promoção.

| Regra | Detalhe |
|-------|---------|
| **Onde** | `.claude/.cache/scratch/` (gitignored via `.claude/.gitignore`) — efêmero, nunca versionado |
| **Vida** | use e descarte; scratch é lixo de trabalho, **não acumula** (anti-proliferação) |
| **Promoção a `tools/`** | só pelo **ciclo SDD normal** (`/dev` ou fase de build) — com **Pester + lint + PR**. **Sem `/promote` atalho**, sem tool não-testada entrando em `tools/` |
| **Nunca-destrutivo** | o efêmero **lê/calcula/gera-em-scratch**; ação mutadora/outward segue a fronteira (b)/(c) |

> Por que **sem engine de promoção**: todo `tools/*.ps1` entra com Pester + lint no CI (ciclo SDD). Um
> atalho de promoção criaria o caminho de ferramenta não-revisada que o projeto evita. O efêmero
> acelera **esta** task; o que merece virar permanente passa pela régua normal.

## Hub do grafo — orquestrador-mestre, ápice permanente; MAX **ativa todas as conexões**

O **`:Hub`** (nó `max`) é o **orquestrador-mestre** e o **ápice permanente** do grafo: está **sempre** no
`graph.json`, ligado a **todos** os agentes pela relação dedicada **`:ORCHESTRATES`** (distinta do peer
`connects_to`). Qualquer agente que seja **nó válido** (`role`+`connects_to`, exigidos pelo `agent-lint`)
**auto-adere** — adicionar um agente (base ou de domínio via `/audit-agents`) faz o hub alcançá-lo **sem
editar lista**. **Ligar o MAX = operar como esse hub no máximo:** o líder amplifica o orquestrador-mestre
que já está no grafo e **ativa todas as conexões** — delega a qualquer expert via `:ORCHESTRATES`
(`/orchestrate`) e aciona o arsenal por gatilho. Detalhe em [`agent-routing.md`](agent-routing.md); o
`graph.cypher` exporta o hub p/ o neo4j **se** o volume justificar (servidor H4 adiado).

**Consumir o grafo unificado (H9):** ao montar o **pacote de contexto** de uma task, o hub **consulta o
grafo unificado** (`.claude/agents/graph.json`, gerado por `/sync-context`) — não só `agente↔agente`, mas
**`:USES_SKILL`** (que skill cada agente usa), **`:PRESUPPOSES`** (que skill um domínio exige) e
**`:KbEntry`/`:IN_DOMAIN`** (que conhecimento existe no domínio). Assim o subagente recebe **o expert + a
skill + a KB certos** do domínio, aterrado no grafo, não improvisado. **On-demand** (lido ao montar o
pacote, não despejado no always-on; ver [`agent-routing.md`](agent-routing.md) §Consultar o grafo).

## Como aplicar

1. **Ligar (`/max`):** roda o **bootstrap de contexto** (reusa `/status`/inventários; G8 silenciado),
   grava o flag de sessão e emite o **aviso obrigatório** (o que foi reduzido + potência recomendada +
   contexto carregado + **guardas ativos**).
2. **Durante:** recomende modelo/effort para tasks densas (não troque à força); aja como **hub** do grafo;
   **consulte `/peers`** antes de orquestrar (consciência de peers — outro MAX na mesma área? coordene/avise);
   monte o pacote da task **aterrado na KB** do domínio; escolha o orquestrador pela escala — `/orchestrate`
   (poucas, sequenciais) ou **emitir Workflow** (fan-out/escala, **só não-mutador/não-outward**); **auto-fire**
   só do arsenal **bounded/local** (outward confirma); registre cada auto-disparo (`Add-MaxDispatch`); **não**
   interrompa no não-crítico; respeite guardas e prompts críticos.
3. **Desligar (`/max off`):** limpa o flag; a postura cessa (novos disparos) — abortar um workflow **em voo**
   é `TaskStop` do harness, não o `max.ps1`. Volta ao fluxo normal.

## O que NÃO fazer

- **Não** usar `bypassPermissions`/`--dangerously-skip-permissions` (pula hooks; pode estar `disable`d).
- **Não** editar `hooks`/settings/`permissions` (carregam no boot — sem efeito em runtime — e mexeria nos guardas).
- **Não** relaxar **nenhum** guarda de segurança (main-push / secret / destructive / managed).
- **Não** pular gate de qualidade ou **fase SDD** — o MAX acelera, não baixa a régua.
- **Não** trocar o **modelo à força** — potência é **recomendação** (B9 `inherit`).
- **Não** persistir o modo entre sessões (flag é session-bound + TTL; fail-closed).
- **Não** construir engine/daemon — orquestração é `Agent`/`Workflow` **nativo**.
- **Não** auto-emitir Workflow **mutador/outward** em background (fica no loop principal — fronteira (b)).
- **Não** auto-fire de skill **outward** (deep-research/browser/publicar) sem confirmar (roteamento (c)).
- **Não** **declarar/inventar quota** de orçamento — o freio é o `budget` nativo do Workflow (do usuário).
- **Não** promover script efêmero a `tools/` por **atalho** — promoção é pelo ciclo SDD (Pester+lint+PR); **sem `/promote` engine**.
- **Não** deixar o **scratch acumular** nem versioná-lo — `.claude/.cache/scratch/` é gitignored e descartável (efêmero ≠ permanente).
- **Não** depender de "o guarda dispara dentro do workflow" — a fronteira (b) não pode depender disso.
- **Não** disparar fan-out às cegas havendo **peer ativo na mesma área** — consulte `/peers`, coordene/avise (H10).
- **Não** ignorar o gatilho `ultracode` quando presente no pedido — é opt-in explícito de escala do
  usuário, não sugestão a ponderar.
- **Não** pôr o peer board no `graph.json` nem no contexto always-on — é runtime/efêmero, lido on-demand.

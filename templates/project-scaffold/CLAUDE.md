# CLAUDE.md

> **Fonte principal: [`AGENTS.md`](AGENTS.md)** — o contrato canônico, válido para qualquer
> agente. Este arquivo carrega o `AGENTS.md` e adiciona só o que é específico do **Claude
> Code**. Complementa também o seu `~/.claude/CLAUDE.md` pessoal (**projeto vence global**).

@AGENTS.md

---

## Específico do Claude Code

### Slash commands

Cada fase do SDD tem um command dedicado e **auto-contido** (carrega a própria lógica):

<!-- sync-context:start:commands -->

**Ciclo SDD** — fases 0→4, na ordem; `/dev` é o atalho de tarefa pequena.

| Comando | Propósito |
|---------|-----------|
| `/brainstorm` | Fase 0 — explorar a ideia antes de definir requisitos |
| `/define` | Fase 1 — requisitos e critérios de aceite |
| `/spec` | Fase 2 — arquitetura e spec técnica |
| `/build` | Fase 3 — implementar + relatório de build |
| `/ship` | Fase 4 — encerrar, arquivar, registrar lições |
| `/dev` | Atalho: tarefa pequena, sem o ciclo completo |

**Entrada do projeto** — `/setup` só preenche o contexto; `/init` roda a cadeia inteira; `/adapt` é o `/init` de quem já tem código.

| Comando | Propósito |
|---------|-----------|
| `/setup` | Wizard que preenche `project-context.md` |
| `/init` | Cadeia de especialização do scaffold, resumável |
| `/adapt` | Adota projeto brownfield e delega ao `/init` |

**Conhecimento (`.claude/kb/`)** — `/train-kb` povoa do zero; `/learn` promove uma lição; `/reflect` compacta o que já existe.

| Comando | Propósito |
|---------|-----------|
| `/train-kb` | Povoa a KB por ondas |
| `/learn` | Promove lição recorrente do `SHIPPED` a entrada de KB |
| `/reflect` | Consolida/compacta a KB, nunca-destrutivo |
| `/skill-gap` | Gera a skill que as ondas pressupõem e falta |

**Curadoria e higiene**

| Comando | Propósito |
|---------|-----------|
| `/audit-agents` | Gera agentes de domínio nas lacunas |
| `/sync-context` | Ressincroniza índices e ponteiros com o estado curado |
| `/update-skills` | Inventaria e atualiza skills dos dois escopos |
| `/supplements` | Lista/instala suplementos por tema; `find` busca no marketplace |
| `/complementary-repos` | Registra repos de referência read-only (`add`/`list`/`remove`) |
| `/document` | Registra em `docs/` — fora da KB |

**Verificação (read-only)** — `/status` diz onde você está; `/check` julga os artefatos; `/doctor` prova que os hooks ainda disparam.

| Comando | Propósito |
|---------|-----------|
| `/status` | Painel do projeto e próxima ação |
| `/check` | Veredito de conformidade dos artefatos curados |
| `/doctor` | Health-check do runtime dos guards de segurança |
| `/telemetry` | Relatório por fase SDD |
| `/review` | Revisa um PR ou o diff atual |

**Modos sob demanda** — a postura chega junto com o command, não fica no always-on.

| Comando | Propósito |
|---------|-----------|
| `/doubt` | Dúvida adversarial sobre decisão ainda aberta |
| `/simulate` | Simula a mudança antes de aplicar |
| `/iterate` | Laço bounded até o verde, com circuit-breaker |
| `/orchestrate` | Decompõe objetivo, delega a subagentes, valida em gate |
| `/max` | Modo de operação máxima; `/max off` desliga |
| `/peers` | Sessões concorrentes: peers ativos e recados |

**Skills internas** — gatilho explícito para as skills que o scaffold entrega; o procedimento vive no `SKILL.md`.

| Comando | Propósito |
|---------|-----------|
| `/page-to-markdown` | Converte URL em Markdown limpo, sem binário externo |
| `/decision-preview` | Artifact comparando 2-4 variantes de decisão aberta |
| `/grill-me` | Entrevista em rodadas até a decisão não ter ramo aberto |
| `/handoff` | Documento de passagem do trabalho em voo para outra sessão |
<!-- sync-context:end:commands -->

> A tabela acima é regenerada por `/sync-context` (G4). Os arquivos vivem em `.claude/commands/`.

### Você PODE disparar os commands acima — via `Skill`

Os commands (`.claude/commands/*.md`) chegam à sessão **como skills**: `Skill(skill: "define")`
funciona (*"Launching skill: define"*) e injeta a lógica da fase. Nenhum command deste scaffold
declara `disable-model-invocation`, e o default é `false` — ou seja, **você pode acioná-los por conta
própria**, sem pedir que o usuário digite.

> **Se você se pegar dizendo "digite `/x`", tente `Skill` primeiro** — pedir ao usuário para
> digitar o que você mesmo pode executar faz do humano o motor do fluxo.

**Poder invocar não é pular etapa.** As regras de fase continuam valendo integralmente:

- **Não pule fases** e não funda artefatos ([`workflow-sdd.md`](.claude/rules/workflow-sdd.md)) —
  poder disparar `/build` não autoriza fazê-lo sem DESIGN.
- **Anuncie antes de disparar** um command que escreve, arquiva ou custa (`/build`, `/ship`,
  `/train-kb`, `/iterate`): diga o que vai rodar e por quê. Barato e read-only (`/status`, `/check`,
  `/doubt`) pode ir direto.
- **Pull-only continua pull-only:** as posturas que dizem *"nunca aja sozinho"* (`/simulate`,
  `/reflect`, `/learn`) seguem esperando o usuário — a permissão técnica não revoga a disciplina.
- O nome da skill é o **nome do arquivo** sem `.md` (`ship.md` → `Skill(skill: "ship")`).

### Regras auto-carregadas

Os arquivos de `.claude/rules/` são contexto sempre ativo — não precisa abri-los à mão.
O catálogo e a disciplina de cada um estão listados no [`AGENTS.md`](AGENTS.md).

### Skills

Duas origens distintas em `.claude/skills/` — não confunda a manutenção de uma com a da outra:

| Origem | Onde vive | Exemplo | Manutenção |
|--------|-----------|---------|------------|
| **Interna** (autorada por este scaffold) | `.claude/skills/<nome>/`, shipada por padrão, sem instalação | [`decision-preview`](.claude/skills/decision-preview/SKILL.md) — gera Artifact comparando variantes de uma decisão ainda aberta; [`page-to-markdown`](.claude/skills/page-to-markdown/SKILL.md) — busca URL→Markdown limpo via `WebFetch`→`claude-in-chrome`, sem binário externo | Ciclo SDD normal deste repositório (PR + revisão) |
| **Vendorizada** (de terceiro, **shipada por padrão**) | `.claude/skills/<nome>/`, com `LICENSE` e `metadata.upstream*` no `SKILL.md` | [`grill-me`](.claude/skills/grill-me/SKILL.md) — entrevista em rodadas sobre a árvore de decisões; [`handoff`](.claude/skills/handoff/SKILL.md) — documento de passagem do trabalho em voo (ambas upstream `mattpocock/skills`, MIT) | **Corpo não se reescreve aqui**: método muda no upstream, ou vira **fork declarado** em `metadata.fork` + comentário no `SKILL.md` (é o caso do `handoff`: 1 linha, o destino do arquivo). O frontmatter é nosso |
| **De terceiro** (marketplace) | instalada via `/supplements` (opt-in, `tools/supplements.psd1`) | `visual-explainer`, `impeccable`, `dataviz`, `ui-ux-pro-max` | Do próprio autor externo — o scaffold só consome |

A postura [`artifact-first.md`](.claude/rules/artifact-first.md) referencia ambas as origens ao
decidir qual ferramenta rotear para uma decisão de design.

**Skill interna tem três caminhos de disparo — não conte só com o julgamento.** Medido no
scaffold (20 queries × 3 execuções, projeto isolado), o modelo consulta espontaneamente a
`page-to-markdown` em **~3%** e a `decision-preview` em **~10%** dos casos em que deveria — e
produz falso positivo. Por isso cada skill interna tem também:

| Caminho | Mecanismo | Disparo |
|---------|-----------|---------|
| Usuário | [`/page-to-markdown`](.claude/commands/page-to-markdown.md) · [`/decision-preview`](.claude/commands/decision-preview.md) · [`/grill-me`](.claude/commands/grill-me.md) · [`/handoff`](.claude/commands/handoff.md) | explícito |
| Subagente | campo `skills:` no frontmatter do agente — injeta o **conteúdo integral** no startup | determinístico |
| Command que a consome | outro command a chama por **predicado** (ex.: `/define` chama `grill-me` com Clarity < 12/15) | determinístico |
| Julgamento | a `description` da skill | ~3–10% — bônus, não aposta |

> **`disable-model-invocation: true` fecha os dois caminhos determinísticos do meio.** Medido em
> 2026-08-28 (CLI 2.1.251, projeto isolado, com controle positivo): com o campo, o harness **recusa**
> `Skill(skill: "...")` vindo do modelo — *"não pode ser invocada via tool Skill"* — e sobra só o `/`
> digitado pelo usuário. Skill que outro command precisa chamar **não** pode declará-lo.

O campo `skills:` é do harness e só vale para skill **interna** (sempre presente); para skill
opcional de marketplace use `skills_used:`, que é metadado nosso do grafo e não gera aviso de
skill ausente em projeto que não a instalou.

### Menção `@agente`

Quando o usuário escrever `@nome-do-agente` (ex.: `@code-reviewer`), invoque esse subagent
com o resto da mensagem como tarefa. Catálogo em [`.claude/agents/`](.claude/agents/);
roteamento em [`.claude/rules/agent-routing.md`](.claude/rules/agent-routing.md).

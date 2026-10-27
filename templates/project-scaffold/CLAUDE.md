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

**Entrada do projeto** — `/setup` só preenche o contexto; `/curate` roda a cadeia inteira; `/adapt` é o `/curate` de quem já tem código.

| Comando | Propósito |
|---------|-----------|
| `/setup` | Wizard que preenche `project-context.md` |
| `/curate` | Cadeia de especialização do scaffold, resumável |
| `/adapt` | Adota projeto brownfield e delega ao `/curate` |

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

**Verificação (read-only)** — `/status` diz onde você está; `/check` julga os artefatos; `/guards-check` prova que os hooks ainda disparam.

| Comando | Propósito |
|---------|-----------|
| `/status` | Painel do projeto e próxima ação |
| `/check` | Veredito de conformidade dos artefatos curados |
| `/guards-check` | Health-check do runtime dos guards de segurança |
| `/telemetry` | Relatório por fase SDD |
| `/review-diff` | Revisa um PR ou o diff atual |

**Modos sob demanda** — a postura chega junto com o command, não fica no always-on.

| Comando | Propósito |
|---------|-----------|
| `/doubt` | Dúvida adversarial sobre decisão ainda aberta |
| `/simulate` | Simula a mudança antes de aplicar |
| `/iterate` | Laço bounded até o verde, com circuit-breaker |
| `/orchestrate` | Decompõe objetivo, delega a subagentes, valida em gate |
| `/max` | Modo de operação máxima; `/max off` desliga |
| `/peers` | Sessões concorrentes: peers ativos e recados |
<!-- sync-context:end:commands -->

> A tabela acima é regenerada por `/sync-context` (G4). Os arquivos vivem em `.claude/commands/`.

**Skills internas** — o `/nome` vem da **própria skill** (`.claude/skills/<nome>/SKILL.md`), sem
arquivo em `commands/`: skill vence command homônimo, e o command nunca rodaria.

| Comando | Propósito |
|---------|-----------|
| `/page-to-markdown` | Converte URL em Markdown limpo, sem binário externo |
| `/decision-preview` | Artifact comparando 2-4 variantes de decisão aberta |
| `/grill-me` | Entrevista em rodadas até a decisão não ter ramo aberto |
| `/handoff` | Documento de passagem do trabalho em voo para outra sessão |
| `/visual-check` | Screenshot da UI em largura calibrada, lido e conferido |

### Você PODE disparar os commands acima — via `Skill`

Os commands chegam à sessão como skills: `Skill(skill: "define")` roda a fase (o nome é o do arquivo
sem `.md`). Não peça ao usuário que digite o que você mesmo pode disparar. **Exceções**, que o harness
recusa por declararem `disable-model-invocation: true`: `/supplements` e `/update-skills` (mexem na
máquina, fora do projeto) e `/simulate`, `/reflect` e `/learn` (pull-only). Para esses, sugira que o
usuário digite.

Uma skill de usuário com o mesmo nome vence o command no `Skill` (o gstack tem `spec`, `ship` e
`learn`; o `/check` acusa a colisão). Se o conteúdo devolvido não for a fase deste projeto, não o siga:
leia `.claude/commands/<fase>.md` e siga esse arquivo.

Poder disparar não é pular fase ([`workflow-sdd.md`](.claude/rules/workflow-sdd.md)): `/build` sem
DESIGN continua fora. Antes de um command que escreve, arquiva ou custa (`/build`, `/ship`,
`/train-kb`, `/iterate`), diga o que vai rodar e por quê; os read-only (`/status`, `/check`,
`/doubt`) vão direto.

### Regras auto-carregadas

Já estão no contexto; não abra à mão. Rule de área (`paths:`) entra depois de ler, gravar ou editar um arquivo da área.

### Skills

| Origem | Exemplos | Manutenção |
|--------|----------|------------|
| **Interna** (deste scaffold, em `.claude/skills/`) | [`decision-preview`](.claude/skills/decision-preview/SKILL.md), [`page-to-markdown`](.claude/skills/page-to-markdown/SKILL.md), [`visual-check`](.claude/skills/visual-check/SKILL.md) | ciclo SDD deste repositório |
| **Vendorizada** (de terceiro, shipada, com `LICENSE` e `metadata.upstream*`) | [`grill-me`](.claude/skills/grill-me/SKILL.md), [`handoff`](.claude/skills/handoff/SKILL.md) (`mattpocock/skills`, MIT) | o corpo não se reescreve aqui: muda no upstream ou vira **fork declarado** em `metadata.fork` (caso do `handoff`) |
| **De terceiro** (marketplace, via `/supplements`) | `visual-explainer`, `impeccable`, `dataviz` | do autor externo |

Pela `description`, o modelo aciona uma skill interna em só ~3–10% dos casos em que deveria (medido).
Os caminhos confiáveis são o `/nome` digitado, o campo `skills:` de um subagente (injeta o conteúdo no
startup) e um command que a chama por predicado (ex.: `/define` chama `grill-me` com Clarity < 12/15).
`disable-model-invocation: true` fecha os dois últimos, então skill que outro command chama não pode
declará-lo. `skills:` vale só para skill interna; para skill opcional de marketplace use `skills_used:`
(metadado do nosso grafo, sem aviso de skill ausente).

### Menção `@agente`

Quando o usuário escrever `@nome-do-agente` (ex.: `@code-reviewer`), invoque esse subagent
com o resto da mensagem como tarefa. Catálogo em [`.claude/agents/`](.claude/agents/);
roteamento em [`.claude/rules/agent-routing.md`](.claude/rules/agent-routing.md).

# CLAUDE.md

> **Fonte principal: [`AGENTS.md`](AGENTS.md)** — o contrato canônico, válido para qualquer
> agente. Este arquivo carrega o `AGENTS.md` e adiciona só o que é específico do **Claude
> Code**. Complementa também o seu `~/.claude/CLAUDE.md` pessoal (**projeto vence global**).

@AGENTS.md

---

## Específico do Claude Code

### Slash commands

Cada fase do SDD tem um command dedicado e **auto-contido** (carrega a própria lógica):

| Comando | Fase | Propósito |
|---------|------|-----------|
<!-- sync-context:start:commands -->
| `/setup` | — | Inicialização: preenche `project-context.md` |
| `/brainstorm` | 0 | Explorar a ideia antes de definir requisitos |
| `/define` | 1 | Capturar requisitos e critérios de aceite |
| `/design` | 2 | Arquitetura e spec técnica |
| `/build` | 3 | Implementar + relatório de build |
| `/ship` | 4 | Encerrar feature, arquivar, lições aprendidas |
| `/audit-agents` | — | Curadoria de agentes: gera agentes de domínio nas lacunas |
| `/train-kb` | — | Povoar a KB por ondas (context7-aware na camada `tools/`) |
| `/sync-context` | — | Ressincronizar índices/ponteiros com o estado curado |
| `/skill-gap` | — | Fechar lacuna de skill: detecta capacidade pressuposta pelas ondas e gera a skill faltante |
| `/update-skills` | — | Higiene das skills: inventaria, diagnostica e atualiza os 2 escopos, com backup antes de escrever |
| `/supplements` | — | Repertório de suplementos: lista skills/plugins validados por tema e instala o escolhido (opt-in, user scope) |
| `/init` | — | Especializar o scaffold: orquestra `/setup`?→`/audit-agents`→`/train-kb`→`/sync-context` |
| `/adapt` | — | Adotar projeto existente (brownfield): detecta stack+higiene e delega ao `/init` |
| `/dev` | — | Dev Loop: tarefa pequena sem SDD completo |
| `/review` | — | Revisar PR ou diff |
| `/doubt` | — | Dúvida adversarial *in-flight* sobre decisão ainda aberta (revisor fresh-context, devolve dúvidas) |
| `/reflect` | — | Consolidar/compactar a KB quando cresce (MERGE/COMPRESS/PRUNE), preservando regras+casos; nunca-destrutivo |
| `/document` | — | Documentar/registrar em `docs/` (humano×LLM, fora da KB): doc de código, ADR, runbook, acontecimentos; nunca-destrutivo |
| `/status` | — | Painel **read-only** do projeto: curadoria + fase SDD em andamento + `inbox/` pendente |
| `/check` | — | Verifica a **conformidade** dos artefatos curados (`.claude/`): KB + agentes + `settings.json`; veredito read-only |
| `/peers` | — | Coordenação entre **sessões concorrentes**: lista peers ativos (branch/summary/heartbeat) + sua caixa de recados; file-based, sem daemon |
| `/telemetry` | — | Telemetria por fase SDD (iterações; duração quando medida) |
| `/doctor` | — | **Health-check do runtime** dos guards de segurança: prova que os hooks ainda disparam (não só a config) — fecha o R2 |
| `/simulate` | — | Simular uma mudança/fix **antes de aplicar** (isolado, nunca-destrutivo): resultado esperado vs baseline |
| `/learn` | — | Promover **lição recorrente** do acervo de `SHIPPED` a uma entrada de KB `operations` (nunca-destrutivo, com proveniência) |
| `/orchestrate` | — | Líder/orquestrador: decompõe um objetivo em tasks, delega a subagentes (`Agent`) e valida cada resultado num gate |
| `/iterate` | — | **Laço bounded "até o verde"**: martela uma meta verificável (lint/suíte/type-fix) em sandbox (`worktree`) com circuit-breakers; reusa o `Test-TaskGate`, motor é `Workflow` nativo |
| `/max` | — | **Modo de operação máxima** sob demanda: contexto total + potência recomendada + orquestrador-mestre, **permissão-só** (guardas mantidos); `/max off` desliga |
| `/complementary-repos` | — | Gerencia o registro de **repositórios complementares de referência** (`add`/`list`/`remove`) — consulta read-only sob demanda, nunca vendoriza; boundary reforçado por hook |
<!-- sync-context:end:commands -->

> A tabela acima é regenerada por `/sync-context` (G4). Os arquivos vivem em `.claude/commands/`.

### Você PODE disparar os commands acima — via `Skill`

Os commands (`.claude/commands/*.md`) chegam à sessão **como skills**: `Skill(skill: "define")`
funciona (*"Launching skill: define"*) e injeta a lógica da fase. Nenhum command deste scaffold
declara `disable-model-invocation`, e o default é `false` — ou seja, **você pode acioná-los por conta
própria**, sem pedir que o usuário digite.

> **Isto era o contrário até 2026-07-13.** Esta seção afirmava que chamar `Skill` com estes nomes
> falhava com `Unknown skill` e que *"o agente nunca os invoca"* — verdade em versões antigas do
> Claude Code, **falso** a partir da 2.1.207 (verificado em runtime, não na doc). A crença obsoleta
> tinha um custo real: o agente **pedia ao usuário para digitar** o que ele mesmo podia executar,
> e o humano virava o motor do fluxo. **Se você se pegar dizendo "digite `/x`", tente `Skill`
> primeiro.**

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
| **De terceiro** (marketplace) | instalada via `/supplements` (opt-in, `tools/supplements.psd1`) | `visual-explainer`, `impeccable`, `dataviz`, `ui-ux-pro-max` | Do próprio autor externo — o scaffold só consome |

A postura [`artifact-first.md`](.claude/rules/artifact-first.md) referencia ambas as origens ao
decidir qual ferramenta rotear para uma decisão de design.

### Menção `@agente`

Quando o usuário escrever `@nome-do-agente` (ex.: `@code-reviewer`), invoque esse subagent
com o resto da mensagem como tarefa. Catálogo em [`.claude/agents/`](.claude/agents/);
roteamento em [`.claude/rules/agent-routing.md`](.claude/rules/agent-routing.md).

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
| `/max` | — | **Modo de operação máxima** sob demanda: contexto total + potência recomendada + orquestrador-mestre, **permissão-só** (guardas mantidos); `/max off` desliga |
<!-- sync-context:end:commands -->

> A tabela acima é regenerada por `/sync-context` (G4). Os arquivos vivem em `.claude/commands/`.

### Regras auto-carregadas

Os arquivos de `.claude/rules/` são contexto sempre ativo — não precisa abri-los à mão.
O catálogo e a disciplina de cada um estão listados no [`AGENTS.md`](AGENTS.md).

### Menção `@agente`

Quando o usuário escrever `@nome-do-agente` (ex.: `@code-reviewer`), invoque esse subagent
com o resto da mensagem como tarefa. Catálogo em [`.claude/agents/`](.claude/agents/);
roteamento em [`.claude/rules/agent-routing.md`](.claude/rules/agent-routing.md).

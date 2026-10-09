# Roteamento de agentes

> Subagents **genéricos** em `.claude/agents/` (mapa: [`../agents/AGENT_MAP.md`](../agents/AGENT_MAP.md)).
> Agentes **de domínio** surgem na curadoria (`/audit-agents`).

## Princípio

Use a ferramenta `Agent` (subagents) quando uma tarefa for **independente e focada** o
suficiente para se beneficiar de um contexto próprio — investigações paralelas, geração de
testes, exploração de codebase desconhecida. Tarefas independentes podem rodar em paralelo
(várias chamadas `Agent` na mesma mensagem).

Quando **não** há subagent dedicado, o slash command da fase é **auto-contido**: carrega a
própria lógica e gera o artefato diretamente. Por isso as 5 fases SDD **não** têm um agente
por fase — evita duplicar o que o command já faz.

## Catálogo genérico (experts de papel)

Subagents de **papel/disciplina** — universais (agnósticos de stack). Stack/domínio é gerado pelo
`/audit-agents` em `.claude/agents/domain/`, **não** entra aqui. O papel `simulation` é o único
**instanciado no domínio** (simulador gerado pela curadoria); os demais são universais do base.

| Subagent | `role` | Quando usar | Modo |
|----------|--------|-------------|------|
| `explorer` | search | Codebase desconhecida: onde fica X. Alvo externo rodando → `external-observer` | read-only |
| `code-reviewer` | review | Revisão ampla de diff/PR. Profundidade em segurança → `security-reviewer` | read-only |
| `security-reviewer` | security | Eixo segurança a fundo, quando a revisão ampla não basta | read-only |
| `test-writer` | testing | Escrever/completar os testes dos Acceptance Tests do DEFINE | escreve + roda |
| `validator` | validation | O resultado cumpre a spec? Por que falhou → `debugger` | read-only |
| `debugger` | debug | Causa-raiz a partir de falha/stacktrace/flaky | roda p/ reproduzir |
| `git-workflow` | vcs | O fluxo em volta do código: commit, PR, CI vermelho, board | roda git/gh |
| `documenter` | documentation | Registrar em `docs/`. KB curada → `/train-kb` | escreve em `docs/` |
| `external-observer` | observation | Alvo externo/opaco (site/API/app): VALIDAR ou MAPEAR | read-only / **outward** (browser/web = confirmar) |
| `designer` | design | Criar/revisar UI/frontend (shape → craft → audit) | escreve UI |
| `tracker` | tracking | Tráfego/traqueamento: plano de medição, tags, consentimento, QA | escreve tags/dataLayer |

> O `description` de cada agente já está no contexto; a coluna "Quando usar" dá só a fronteira com o
> vizinho confundível.

## Seleção de executor

O líder escolhe o expert (ou a cadeia) pelo **tipo de tarefa**, reusando o `Agent` nativo (e
`/orchestrate` quando há encadeamento) — **sem motor próprio**. Os agentes declaram `connects_to` no
frontmatter — grafo consultável em `agents/graph.json` (mantido pelo `/sync-context`). Quem escolhe
o encadeamento é o **líder**, com esta tabela: o subagente não recebe o `connects_to` dele por
mecanismo nenhum. Grafo unificado, contrato de hub e `ultracode` não estão aqui: o `/max` e o
`/orchestrate` os carregam quando precisam.

### Refino de pedido (opt-in) — afiar o pedido e mapear o arsenal antes de agir

Ao receber um pedido **vago, curto ou informal**, vale **afiá-lo** antes de executar, em vez de
adivinhar. É **postura opt-in** — o usuário pede ("refina/melhora isto antes de fazer") **ou** você
julga que a ambiguidade custa retrabalho — **não** um passo obrigatório em todo turno:

1. **Devolva sua leitura técnica** do pedido (o que entendeu, em termos concretos) e exponha as premissas.
2. **Consulte o `agents/graph.json`** e liste o **arsenal aplicável** — agentes/skills/KB/MCP que encaixam.
3. **Espere o OK** do usuário antes de agir (ou ele corrige a sua leitura).

**Distinto** do [`/doubt`](../commands/doubt.md) (decisão **já formada**) e do `/brainstorm` (explorar
uma **feature**): aqui só se **clarifica o pedido** e se **mapeia o arsenal** antes de começar.

> **Não** reescreva o pedido **no lugar do** usuário, nem rode isto em todo turno — é opt-in, sob sinal
> de ambiguidade. Pedido trivial/claro → siga direto.

### Reagindo a review recebida

Distinto do [`/doubt`](../commands/doubt.md) (dúvida sobre decisão **própria ainda aberta**): aqui
a decisão **já foi tomada** e um revisor (`code-reviewer`, humano, ou terceiro) **já devolveu** um
veredito/sugestão. O ponto é como o líder **reage**, antes de implementar.

| Não faça | Faça |
|----------|------|
| Concordância performática ("Você está certo!", "Ótimo ponto!") antes de verificar | Verifique a sugestão contra o código real primeiro; só então aja |
| Implementar tudo de uma vez quando parte do feedback ficou ambígua | Esclareça os itens ambíguos **antes** de implementar qualquer um — itens podem estar relacionados |
| Aceitar "implementar isso direito" sem checar se é usado | `grep` por uso real primeiro — sem uso, é candidato a **não** implementar (YAGNI), não a "fazer certo" |

**Antes de implementar uma sugestão de revisor, responda:**
1. Isso quebra algo que já funciona?
2. O revisor tem o contexto completo (motivo do código atual, compat legada)?
3. É YAGNI — o trecho sinalizado tem uso real no projeto?

Se a resposta apontar problema, **discorde com razão técnica** (não implemente cego, não ignore
silenciosamente). Se a sugestão estava certa, só **corrija e diga o que mudou** — sem agradecimento
performático; a ação já demonstra que o feedback foi ouvido.

### Política de modelo

- **Default `model: inherit`** em todos os agentes base — cada um roda no **modelo da sessão** (você
  em Opus → o agente em Opus; em Sonnet → Sonnet). Sem hardcode.
- **Escalonar para `opus`** é **por-invocação**: ao delegar uma tarefa **pesada/crítica** ou sob
  **pedido explícito**, o líder passa `model: opus` na invocação (o override vence o frontmatter —
  ordem de resolução do Claude Code: invocação → frontmatter → `CLAUDE_CODE_SUBAGENT_MODEL` → sessão;
  `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` sobrepõe todas).
- Para **mais esforço sem trocar de modelo**, use o campo/parâmetro `effort` (`low`…`max`).

## Menção @agente

Quando o usuário escrever `@nome-do-agente` (ex.: `@code-reviewer`), invoque esse subagent
com o resto da mensagem como tarefa.

## Crescimento do catálogo

Agentes de domínio vêm do `/audit-agents`, e o roteamento deles mora em **`agent-routing-domain.md`**
(também always-on). **Nunca escreva conteúdo gerado neste arquivo:** ele vem do template, e o
`-Update` pararia de atualizá-lo. Mantenha o conjunto **enxuto** — só o que é usado.
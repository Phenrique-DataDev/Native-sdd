# Documentação — Proativo seguro

> Postura **sempre-ativa** para o que **não entra na KB e nem deveria**: doc de código, registros de
> acontecimentos, runbook/onboarding, referência/notas. O agente **age por conta** e cria/atualiza isso
> **por fora** (`docs/`) — a KB segue curada/agente-facing/enxuta; isto é o **resíduo documentável**,
> humano×LLM. **Proativo por julgamento** (disciplina aqui, não motor que regenera docs em standing —
> isso seria doc-rot). Subagent dedicado: `documenter`; gatilho explícito em lote: `/document`.

## Pré-condição (após o 1º `/train-kb`)

A postura proativa **só entra em vigor após o primeiro `/train-kb`** — ou seja, depois que a KB rodou seu
primeiro treinamento. Antes disso o foco é a **curadoria** (`/setup` → `/audit-agents` → `/train-kb` →
`/sync-context`, orquestrados por `/init`); o documenter fica em **silêncio**.

Sinal verificável de "KB treinada": `.claude/kb/_index.yaml` tem ≥1 domínio (ou há entradas reais em
`.claude/kb/`). Se a KB ainda não foi treinada, **não documente proativamente** — a sequência é **KB
primeiro, docs depois**. (O comando explícito `/document` orienta a rodar `/train-kb` antes.)

## Quando documentar

Proativamente (uma vez satisfeita a pré-condição acima), como parte do trabalho normal (sem esperar pedido):

| Gatilho | O que registrar em `docs/` |
|---------|----------------------------|
| Uma decisão de design/arquitetura foi tomada | ADR curto: contexto, decisão, consequência |
| Algo mudou em como o código funciona | atualizar a doc do módulo/parte tocada |
| Aconteceu algo relevante (incidente, mudança, marco) | entrada **datada** no registro (append-only) |
| Alguém (humano/LLM) precisará operar/retomar | runbook/onboarding do que é não-óbvio |

Quando não houver nada material a registrar, **silêncio** — não crie arquivo vazio.

## Registros (append-only)

Acontecimentos e notas são **append-only**: cada novo fato é uma **entrada nova datada**; **nunca**
reescreve nem apaga uma entrada anterior. O histórico é imutável — corrige-se com uma entrada nova que
referencia a anterior, não editando o passado. (Isto difere do README fixo do projeto, que é doc viva
sem changelog — registros de acontecimento moram em `docs/`, à parte.)

## Doc de código (pontual, nunca-destrutivo)

Ao documentar código/runbook, atualize **só o trecho** relativo ao que mudou, mostrando **diff** —
update **pontual** e **nunca-destrutivo**. **Nunca** regenere a árvore de docs inteira às cegas (isso
diverge do código e apodrece: doc-rot). Derive do código **real**; não invente comportamento.

## Diagramas — Mermaid inline × visual-explainer

Quando um diagrama clarifica (arquitetura, fluxo, máquina de estados, sequência), prefira-o à
prosa. Há duas ferramentas — **combine** as duas **ou** use só Mermaid, conforme o caso:

| Use | Quando | Forma |
|-----|--------|-------|
| **Mermaid** (bloco ` ```mermaid `) | diagrama **leve e co-localizado** no `.md` — renderiza no GitHub, versiona/difa junto com a doc | `flowchart` / `sequenceDiagram` / `stateDiagram` inline |
| **visual-explainer** (HTML) | artefato **rico/standalone** (diff visual, plano, relatório) — quando o inline não basta | página HTML em `docs/` (não publica) |

Mermaid é preferível quando um HTML seria **demais** para o caso. Ele **não** renderiza no
terminal — é para leitura no GitHub/IDE. **Não** recria o `AGENT_MAP.md`/`graph.html`
(autogerados pelo `/sync-context`): esses são o grafo de agentes, não doc humana.

## O que NÃO fazer

| Não faça | Por quê |
|----------|---------|
| Escrever na KB (`.claude/kb/`) | KB é curada/agente-facing/enxuta; isto é humano×LLM, fora dela |
| Regenerar a árvore de docs em standing | Doc-rot — a postura é pontual, por julgamento |
| Reescrever/apagar registro de acontecimento | Registros são append-only (histórico imutável) |
| Misturar com o README fixo do projeto | `docs/` é separado da doc viva fixa (sem changelog no README) |
| Inventar conteúdo não derivado do código/eventos | Documentação só descreve o que é verificável |

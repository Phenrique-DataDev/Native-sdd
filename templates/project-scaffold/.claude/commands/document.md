---
description: "Documentar/registrar em docs/ (humano×LLM, fora da KB) — fan-out p/ o documenter, nunca-destrutivo"
argument-hint: "<o que documentar: módulo, decisão, acontecimento, runbook>"
---

# /document — documentação humano×LLM (fora da KB)

Gatilho **explícito em lote** para a postura da rule `documentation.md` (sempre-ativa). Produz/atualiza
documentação em `docs/` que **não entra na KB**: doc de código/módulos, ADR, runbook/onboarding,
registro de acontecimentos, referência/notas.

> Use quando quiser documentar **sob pedido** (um lote, uma área inteira). No dia a dia, a postura
> **proativa** da rule já cobre o registro contínuo — este comando é o caminho explícito, mesma disciplina.

## Antes de começar
- **Pré-condição (sequência KB→docs):** o documenter atua **após o 1º `/train-kb`**. Se a KB ainda não foi
  treinada (`.claude/kb/_index.yaml` sem domínios / `.claude/kb/` vazia), **oriente a rodar `/train-kb`
  (ou `/init`) primeiro** — a curadoria vem antes da documentação. Sob pedido explícito, prossiga avisando.
- Leia `.claude/rules/documentation.md` (Proativo seguro) e `project-context.md`.
- Identifique o alvo em `$ARGUMENTS` (o quê documentar) e leia o **código/artefatos reais** correspondentes.

## Execução
1. **Fan-out:** invoque o subagent `documenter` via a ferramenta `Agent` (um por área/alvo quando fizer
   sentido paralelizar) — contexto próprio, lê o código real e propõe a doc.
2. **Plano/diff:** o `documenter` devolve o **plano** do que será criado/atualizado em `docs/`, com **diff**.
3. **Aprovação:** mostre o plano e **peça confirmação** (`AskUserQuestion`: aplicar tudo / escolher / cancelar).
4. **Aplica:** só após aprovação, escreve em `docs/` — **nunca-destrutivo**: registros são **append-only**
   (entrada nova datada, nunca reescreve o passado); doc de código é update **pontual** do trecho tocado,
   nunca regenera a árvore. Faça backup quando sobrescrever.
5. **Reindexar:** rode `/sync-context` para regenerar `docs/_index.md` e o ponteiro.

## Regras
- **Nunca escreve na KB** (`.claude/kb/`) — isto é documentação humano×LLM, fora dela. A KB tem seu próprio
  caminho (`/train-kb`).
- **Nunca-destrutivo:** não apaga nem sobrescreve sem diff e confirmação; registros nunca perdem histórico.
- Deriva do código/eventos **reais** — não inventa.
- `docs/` é separado do README fixo do projeto (sem changelog no README).

## O que NÃO fazer
- Escrever conhecimento curado/agente-facing — isso é KB (`/train-kb`), não `docs/`.
- Regenerar a árvore de docs inteira (doc-rot) — atualize só o trecho tocado.
- Aplicar mudança sem mostrar o plano/diff e obter aprovação.

**Próximo passo:** `/sync-context` (reindexa `docs/`).

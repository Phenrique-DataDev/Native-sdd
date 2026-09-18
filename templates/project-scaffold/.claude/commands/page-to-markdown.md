---
description: "Converte uma URL em Markdown limpo, sem instalar binário externo"
argument-hint: "<url> [caminho de saída]"
---

# /page-to-markdown — URL → Markdown

Gatilho **explícito** para a skill interna
[`page-to-markdown`](../skills/page-to-markdown/SKILL.md). Este arquivo é só o gatilho: **a fonte
única do procedimento é o `SKILL.md`** — ele não é repetido aqui, e mudança de método vai lá, não
neste command.

> **Por que o command existe.** Medido no scaffold (20 queries × 3 execuções, projeto isolado): a
> skill é consultada por julgamento do modelo em **~3%** das vezes em que deveria — porque
> `WebFetch` resolve o caso comum nativo, em uma chamada. O `/` não depende desse julgamento.

## Processo
1. Carregue a skill `page-to-markdown` (tool `Skill`) e siga o workflow dela.
2. Alvo: `$ARGUMENTS` — primeira palavra é a URL; o resto, se houver, é o caminho de saída.
3. Sem caminho de saída, devolva o Markdown na conversa; com ele, `Write` no arquivo.

## Quando NÃO usar
- Documentação de lib/framework/SDK/CLI → `context7` (ver [`docs-first.md`](../rules/docs-first.md)).
- Investigação formal de alvo externo (rede/headers/evidência) → agente `external-observer`, que já
  recebe esta skill pré-carregada.

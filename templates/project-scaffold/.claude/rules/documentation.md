# Documentação — o resíduo documentável vai para `docs/`

> A disciplina completa (registros append-only, doc de código pontual, Mermaid × visual-explainer, o
> que não fazer) vive em [`../postures/documentation.md`](../postures/documentation.md), fora do
> always-on.

## Predicado

**A KB já foi treinada?** (`.claude/kb/_index.yaml` com ≥1 domínio, ou entradas reais em
`.claude/kb/<camada>/`.)

| Resposta | O que fazer |
|----------|-------------|
| **Não** (todo projeto novo) | **Silêncio**: não documente proativamente. A sequência é KB primeiro (`/train-kb`), docs depois. **Pare aqui.** |
| **Sim** | Documente por conta própria, sem esperar pedido, quando: uma decisão de design foi tomada (ADR curto), o funcionamento do código mudou (doc do módulo), aconteceu algo relevante (entrada datada no registro) ou alguém vai precisar operar/retomar (runbook). **Leia a postura antes da primeira escrita.** |

Sempre: **nunca** escreva na KB (`.claude/kb/`) a partir daqui, e registro de acontecimento é
append-only. Subagent dedicado: `documenter`; em lote: `/document`.

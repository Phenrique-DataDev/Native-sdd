---
description: "Entrevista em rodadas até a decisão não ter ramo por visitar — antes de construir"
argument-hint: "<o plano, decisão ou ideia a ser interrogado>"
---

# /grill-me — interrogar o plano antes de executá-lo

Gatilho **explícito** para a skill interna [`grill-me`](../skills/grill-me/SKILL.md). Este arquivo é
só o gatilho: **a fonte única do procedimento é o `SKILL.md`** — ele não é repetido aqui, e mudança
de método vai lá, não neste command.

> **Por que o command existe.** Mesmo motivo das outras skills internas: medido no scaffold (20
> queries × 3 execuções, projeto isolado), o modelo consulta skill interna por julgamento próprio em
> **~3–10%** das vezes em que deveria. O `/` não depende desse julgamento. Aqui há um segundo
> motivo: o método **contraria** o reflexo do modelo — perguntar tudo o que está maduro de uma vez,
> com recomendação, em vez de uma pergunta por turno.

## Processo
1. Carregue a skill `grill-me` (tool `Skill`) e siga o workflow dela.
2. Alvo: `$ARGUMENTS`. Sem argumento, entreviste sobre **o que estiver em pauta na conversa** — se
   não houver nada em pauta, pergunte o que interrogar antes de abrir a primeira rodada.
3. **Fato não se pergunta, se descobre.** Antes de cada rodada, o que for verificável no repositório
   (arquivo, teste, config, histórico) sai de `Read`/`Grep`/`Agent`, não do usuário — a rodada só
   carrega **decisões**.

## Quem mais chama esta skill
Quatro pontos do ciclo a chamam por predicado, sem você digitar nada:
[`/setup`](setup.md) (contexto ainda `status: template`) · [`/brainstorm`](brainstorm.md) (passo de
perguntas da fase 0) · [`/define`](define.md) (**Clarity Score < 12/15**) ·
[`/train-kb`](train-kb.md) (antes de derivar as ondas).

## Quando NÃO usar
- Decisão **já tomada** que só precisa ser explicada ou revisada → `/decision-preview` (comparar
  variantes ainda abertas) ou revisão normal.
- Pergunta cuja resposta está **no repositório** — descubra em vez de interrogar o usuário.
- Tarefa pequena e reversível → `/dev`. Interrogatório cobra tempo do usuário; gaste onde errar dói.

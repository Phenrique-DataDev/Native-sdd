---
description: "Documento de passagem para outro agente/sessão continuar o trabalho em voo"
argument-hint: "<para que serve a próxima sessão>"
---

# /handoff — passar o trabalho em voo adiante

Gatilho **explícito** para a skill interna [`handoff`](../skills/handoff/SKILL.md). Este arquivo é só
o gatilho: **a fonte única do procedimento é o `SKILL.md`** — ele não é repetido aqui, e mudança de
método vai lá, não neste command.

> **O que ele cobre, e o ciclo não cobria.** Os artefatos SDD (`DEFINE`, `DESIGN`, `BUILD_REPORT`,
> `SHIPPED`, `STATE`) já viajam — mas só existem em **fronteira de fase**. O que fica sem endereço é o
> contexto **em voo**: a decisão recém-tomada, o que foi tentado e falhou, o que vem em seguida.

## Processo
1. Carregue a skill `handoff` (tool `Skill`) e siga o workflow dela.
2. Foco da próxima sessão: `$ARGUMENTS`. Sem argumento, escreva o documento para *"continuar de onde
   parei"* e diga isso no texto — não invente um objetivo que o usuário não declarou.
3. **Não duplique o que já está escrito.** Spec, plano, ADR, issue, commit e diff entram por
   **caminho ou URL**; o documento carrega só o que existe apenas na conversa.

## Quando NÃO usar
- **Nada está viajando** (mesma sessão, mesmo diretório, fim de fase) → o artefato da fase já é a
  passagem; compactar resolve o resto.
- Coordenar com outra sessão **ativa no mesmo projeto** → [`/peers`](peers.md), que é presença e
  recado, não documento.
- Encerrar uma feature → [`/ship`](ship.md): o `SHIPPED` é o registro do que fechou, não do que segue.

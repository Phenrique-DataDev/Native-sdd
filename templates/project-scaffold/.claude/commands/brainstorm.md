---
description: "Fase 0 SDD — explorar a ideia antes de definir requisitos"
argument-hint: "<ideia, pergunta ou caminho de arquivo>"
---

# /brainstorm — Fase 0 (Brainstorm)

Explorar `$ARGUMENTS` por diálogo **antes** de capturar requisitos formais.

## Antes de começar
- Leia `CLAUDE.md`, `.claude/rules/project-context.md` e o template
  `.claude/sdd/templates/BRAINSTORM_TEMPLATE.md`.
- Se o projeto não estiver inicializado (`status: template`), sugira `/setup` primeiro.

## Processo
1. **Contexto** — explore estrutura do projeto, padrões existentes e commits recentes.
2. **Interrogatório** — carregue a skill [`grill-me`](../skills/grill-me/SKILL.md) (tool `Skill`)
   e conduza as rodadas até a *frontier* esvaziar. Este **é** o passo de perguntas da fase: não o
   troque por perguntas soltas nem por uma pergunta por turno. O que o passo 1 pode descobrir sozinho
   não entra na rodada — rodada carrega **decisão**, não fato.
3. **Amostras** — colete dados/arquivos de exemplo que sirvam de *grounding* (few-shot).
4. **Abordagens** — proponha 2–3 caminhos com prós/contras e recomende um.
5. **YAGNI** — corte o que for desnecessário; registre o que foi removido.
6. **Valide** — confirme o entendimento em incrementos (mín. 2 validações).

## Saída
Gere `.claude/sdd/features/BRAINSTORM_<FEATURE>.md` seguindo o template (inclua as
abordagens, decisões, itens cortados e um rascunho dos requisitos para o DEFINE).

## Telemetria (opcional, não bloqueia)
Ao fechar a fase, registre as iterações de re-trabalho (piloto B6 — consolidado em `/telemetry`):
`. "$toolsRoot/telemetry.ps1"; Add-PhaseIteration -Path .claude/sdd/telemetry.jsonl -Phase brainstorm -Feature <FEATURE> -Iterations <n>` — resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md)

**Próximo passo:** `/define .claude/sdd/features/BRAINSTORM_<FEATURE>.md`

---
description: "Fase 4 SDD — encerrar feature, arquivar e registrar lições"
argument-hint: "<FEATURE>"
---

# /ship — Fase 4 (Ship)

Fechar a feature `$ARGUMENTS`: arquivar artefatos e capturar aprendizado.

## Pré-condição
O `BUILD_REPORT` da feature deve estar **completo e verificado** (status ✅). Se não
estiver, volte ao `/build`.

## Faça
1. Leia o template `.claude/sdd/templates/SHIPPED_TEMPLATE.md`.
2. Gere `.claude/sdd/archive/<FEATURE>/SHIPPED_<YYYY-MM-DD>.md` com:
   - Resumo, timeline e métricas
   - O que foi construído (componentes + arquivos)
   - **Verificação dos Success Criteria** do DEFINE (atingidos? evidência)
   - **Lições aprendidas** (processo, técnico, ferramentas) — **marque** cada lição `[candidata]`
     (prática reaplicável, recorrente) ou `[pontual]` (one-off). É o insumo do `/learn` (G7), que
     promove o recorrente a uma entrada de KB `operations`. Aditivo (lições sem marca seguem válidas).
   - Recomendações para trabalho futuro
3. Mova/aponte os artefatos da feature (BRAINSTORM/DEFINE/DESIGN/BUILD_REPORT) para o
   arquivo da feature.
4. **Bump de versão** (se o projeto versiona — há `VERSION`/`CHANGELOG.md`): incremente o **patch**
   (`0.6.1`→`0.6.2`) por feature shipada, ou o **minor** ao fechar um EPIC; atualize `VERSION` +
   `CHANGELOG.md` e crie a **tag** git (`vX.Y.Z`) no merge. Sem `VERSION`, pule este passo.
5. Resuma para o usuário e proponha o merge da branch (com confirmação, pois `main` é
   protegida).

## Regra
- Só escreva o SHIPPED depois de confirmar que os Success Criteria foram de fato atingidos.

## Racionalizações comuns

| Desculpa | Realidade |
|----------|-----------|
| "O BUILD_REPORT está quase ✅, já posso arquivar" | Ship só depois do ✅ verificado. Arquivar build incompleto enterra dívida. |
| "Os Success Criteria 'claramente' foram atingidos" | Só escreva o SHIPPED com evidência de cada critério — não com a sensação de que bateu. |
| "Pulo as lições aprendidas, não houve nada de novo" | A seção é barata e é o que alimenta o próximo ciclo. "Nada novo" também é uma lição — registre. |

## O que NÃO fazer

- Escrever o SHIPPED com o BUILD_REPORT em 🔄/❌.
- Afirmar Success Criteria atingidos sem evidência.
- Mergear na `main` sem confirmação explícita (`main` é protegida).

## Telemetria (opcional, não bloqueia)
Ao fechar a fase, registre as iterações de re-trabalho (piloto B6 — consolidado em `/telemetry`):
`. "$toolsRoot/telemetry.ps1"; Add-PhaseIteration -Path .claude/sdd/telemetry.jsonl -Phase ship -Feature <FEATURE> -Iterations <n>` — resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md)

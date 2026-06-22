---
description: "Fase 3 SDD — implementar conforme o design + relatório de build"
argument-hint: "<caminho do DESIGN>"
---

# /build — Fase 3 (Build)

Implementar o que o DESIGN especifica e registrar o resultado.

## Antes de começar
- Leia o DESIGN em `$ARGUMENTS` e o DEFINE referenciado.
- Leia o template `.claude/sdd/templates/BUILD_REPORT_TEMPLATE.md`.
- Trabalhe em **branch de feature** (não na `main`).

## Execução
1. Quebre o DESIGN em tarefas pequenas e verificáveis (use a lista de tarefas).
2. Implemente seguindo a stack e convenções de `project-context.md`.
3. **Verifique de verdade** a cada parte: lint, type-check e testes da stack do projeto.
   Não marque como pronto com testes falhando.
4. Cubra os **Acceptance Tests** do DEFINE.

## Saída
Gere `.claude/sdd/reports/BUILD_REPORT_<FEATURE>.md` com:
- Resumo, arquivos criados/alterados
- Resultados de verificação (lint / type-check / testes — saídas reais)
- Desvios do design e o porquê, issues e blockers
- Verificação dos Acceptance Tests
- Status final: ✅ COMPLETE / 🔄 IN PROGRESS / ❌ BLOCKED

## Regras
- Relate falhas honestamente (mostre a saída). Não fabrique resultados de teste.
- Commits seguem Conventional Commits; push livre na branch de trabalho.

## Racionalizações comuns

| Desculpa | Realidade |
|----------|-----------|
| "Os testes estão quase passando, marco como ✅" | "Quase" é ❌. O status reflete a saída real do lint/teste, não a expectativa. |
| "Escrevo os testes depois de entregar" | Sem teste, o Acceptance Test do DEFINE não foi coberto — a fase não fechou. |
| "Esse desvio do DESIGN é óbvio, não preciso registrar" | O BUILD_REPORT registra desvio + porquê para quem vier depois. Óbvio hoje ≠ óbvio em 3 meses. |

## O que NÃO fazer

- Marcar ✅ com lint/teste falhando ou sem rodar.
- Fabricar resultado de teste — mostre a saída real.
- Implementar fora do DESIGN sem registrar o desvio + porquê.

## Telemetria (opcional, não bloqueia)
Ao fechar a fase, registre as iterações de re-trabalho (piloto B6 — consolidado em `/telemetry`).
Aqui `n` é o **sinal mais forte**: nº de re-rodadas até o lint/testes/critérios passarem.
`. "$toolsRoot/telemetry.ps1"; Add-PhaseIteration -Path .claude/sdd/telemetry.jsonl -Phase build -Feature <FEATURE> -Iterations <n>` — resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md)

**Próximo passo (quando ✅):** `/ship <FEATURE>`

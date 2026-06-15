---
description: "Fase 2 SDD — arquitetura e spec técnica"
argument-hint: "<caminho do DEFINE>"
---

# /design — Fase 2 (Design)

Desenhar **como** construir o que o DEFINE pediu.

## Antes de começar
- Leia o DEFINE em `$ARGUMENTS` e o template `.claude/sdd/templates/DESIGN_TEMPLATE.md`.
- Confirme que o DEFINE atingiu Clarity Score ≥ 12/15. Se não, volte para `/define`.
- Consulte a KB (`.claude/kb/`) e padrões existentes no código.

## Produza
Gere `.claude/sdd/features/DESIGN_<FEATURE>.md` com:
- **Arquitetura** (diagrama ASCII de componentes e fluxo de dados)
- **Componentes** (responsabilidade + tecnologia)
- **Data Flow** e **Integration Points**
- **Testing Strategy** (que testes provam os Acceptance Tests do DEFINE)
- **Error Handling**, **Security**, **Observability**
- **Localização do código** (onde os arquivos vão morar) e impacto de infra/IaC

## Regras
- Respeite as Constraints do DEFINE.
- Cada Success Criterion deve ter um caminho claro de verificação no design.
- Aplique YAGNI: o design mais simples que satisfaz os requisitos.

## Telemetria (opcional, não bloqueia)
Ao fechar a fase, registre as iterações de re-trabalho (piloto B6 — consolidado em `/telemetry`):
`. "$toolsRoot/telemetry.ps1"; Add-PhaseIteration -Path .claude/sdd/telemetry.jsonl -Phase design -Feature <FEATURE> -Iterations <n>` — resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md)

**Próximo passo:** `/build .claude/sdd/features/DESIGN_<FEATURE>.md`

# DEFINE: {Nome da Feature}

> Uma frase descrevendo o que vamos construir.

## Metadados

| Atributo | Valor |
|----------|-------|
| **Feature** | <FEATURE> |
| **Data** | {AAAA-MM-DD} |
| **Status** | Rascunho / Em progresso / Precisa esclarecer / Pronto para Design |
| **Clarity Score** | {X}/15 |

---

## Problema
{1–2 frases: quem tem o problema e qual o impacto. Seja específico.}

## Usuários-alvo

| Usuário | Papel | Dor |
|---------|-------|-----|
| {…} | {…} | {…} |

## Goals (priorizados)

| Prioridade | Goal |
|------------|------|
| **MUST** | {não-negociável para o MVP} |
| **SHOULD** | {importante, mas há workaround} |
| **COULD** | {nice-to-have, primeiro a cortar} |

## Success Criteria (mensuráveis — com números)
- [ ] {ex.: processa 1000 registros/min}
- [ ] {ex.: latência < 200ms}

## Acceptance Tests

| ID | Cenário | Given | When | Then |
|----|---------|-------|------|------|
| AT-001 | {happy path} | {estado} | {ação} | {resultado esperado} |
| AT-002 | {erro} | {…} | {…} | {…} |
| AT-003 | {edge case} | {…} | {…} | {…} |

## Out of Scope
- {o que NÃO faremos agora}

## Constraints

| Tipo | Restrição | Impacto |
|------|-----------|---------|
| Técnica | {ex.: usar schema existente} | {…} |
| Prazo | {…} | {…} |

## Contexto técnico (para o Design)

| Aspecto | Valor | Notas |
|---------|-------|-------|
| **Localização do código** | {src/ \| scripts/ \| models/ \| …} | {por quê} |
| **Domínios de KB** | {ex.: sql, python, dbt, warehouse} | {padrões a consultar} |
| **Impacto de infra/IaC** | {novo \| modifica \| nenhum \| TBD} | {…} |

## Assumptions

| ID | Premissa | Se errada, impacto | Validada? |
|----|----------|--------------------|-----------|
| A-001 | {…} | {…} | [ ] |

## Clarity Score

| Elemento | Nota (0–3) | Notas |
|----------|------------|-------|
| Problema | {0-3} | |
| Usuários | {0-3} | |
| Goals | {0-3} | |
| Success | {0-3} | |
| Scope | {0-3} | |
| **Total** | **{X}/15** | |

> 0 = ausente · 1 = vago · 2 = claro mas incompleto · 3 = cristalino.
> **Mínimo para avançar: 12/15.**

## Perguntas em aberto
{liste o que falta responder antes do Design, ou "Nenhuma — pronto para Design".}

---

**Próximo passo:** `/design .claude/sdd/features/DEFINE_<FEATURE>.md`

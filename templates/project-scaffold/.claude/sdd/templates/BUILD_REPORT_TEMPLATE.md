# BUILD REPORT: {Nome da Feature}

> Relatório da implementação conforme o DESIGN.

## Metadados

| Atributo | Valor |
|----------|-------|
| **Feature** | <FEATURE> |
| **Data** | {AAAA-MM-DD} |
| **DESIGN** | [DESIGN_<FEATURE>.md](../features/DESIGN_<FEATURE>.md) |
| **Branch** | {feat/...} |

---

## Resumo
{o que foi construído, em 2–3 frases}

## Arquivos criados/alterados

| Arquivo | Mudança | Notas |
|---------|---------|-------|
| {caminho} | criado/alterado | {…} |

## Verificação (saídas reais)

### Lint
```
{saída do linter da stack — ex.: ruff, eslint}
```
### Type-check
```
{saída — ex.: mypy, tsc}
```
### Testes
```
{saída — ex.: pytest, vitest: N passed / N failed}
```

## Verificação dos Acceptance Tests

| ID | Resultado | Evidência |
|----|-----------|-----------|
| AT-001 | ✅/❌ | {teste/log que prova} |
| AT-002 | ✅/❌ | {…} |

## Desvios do design
{o que mudou em relação ao DESIGN e por quê — ou "Nenhum"}

## Issues e blockers
{problemas encontrados; bloqueios pendentes — ou "Nenhum"}

## Status final

**Geral:** {✅ COMPLETE / 🔄 IN PROGRESS / ❌ BLOCKED}

---

**Próximo passo (quando ✅):** `/ship <FEATURE>`

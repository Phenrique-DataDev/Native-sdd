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

## Verificação por mutação (obrigatória quando há comportamento executável)

> Um teste que **passa com o defeito reintroduzido** não cobre nada. Para cada correção/comportamento
> novo: desligue o fix, mostre **qual** teste reprova, restaure. Nome do teste, não "a suíte falhou".

| Comportamento | Como o defeito foi reintroduzido | Teste que reprovou | Restaurado |
|---|---|---|---|
| {o que o fix garante} | {a linha/condição desligada} | `{nome exato do teste}` | ✅ |

**Suíte após restaurar:** {N passed / 0 failed}

> **Sem comportamento executável?** (só redação, doc, template, prosa de rule/command) — escreva
> **"N/A — mudança sem comportamento executável"** e diga o que a torna verificável no lugar
> (ex.: lint que lê o arquivo, revisão humana). **Não** deixe a seção em branco nem a apague: o
> "N/A" declarado é a diferença entre *não se aplica* e *não foi feito*.

## Desvios do design
{o que mudou em relação ao DESIGN e por quê — ou "Nenhum"}

## Issues e blockers
{problemas encontrados; bloqueios pendentes — ou "Nenhum"}

## Status final

**Geral:** {✅ COMPLETE / 🔄 IN PROGRESS / ❌ BLOCKED}

---

**Próximo passo (quando ✅):** `/ship <FEATURE>`

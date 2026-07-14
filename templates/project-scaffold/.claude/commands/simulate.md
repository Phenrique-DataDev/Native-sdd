---
description: "Simular uma mudança/fix antes de aplicar (isolado, nunca-destrutivo)"
argument-hint: "<mudança ou fix a simular>"
---

# /simulate — simular antes de aplicar

Projeta o **resultado esperado** de uma mudança/fix **antes** de aplicá-la, num ambiente **isolado**,
e compara contra o baseline. **Nunca-destrutivo, nunca toca produção, nunca aplica.** A simulação real
é um **simulador de domínio** gerado pelo `/audit-agents` (G2).

> Distinto do `-DryRun` mecânico dos scripts: aqui o foco é o **resultado de domínio** (ex.: "como
> ficariam os dados pós-fix dbt"), não só "o que o script faria".
>
> **Este command é a fonte única da postura** — não há rule sempre-ativa correspondente. O protocolo
> inteiro está aqui e carrega **sob demanda**.

---

## Princípio

Validar uma mudança **só depois de aplicá-la** é caro: o estrago já aconteceu ou exige reverter. O
`/simulate` inverte a ordem — **PROPOR → SIMULAR (isolado) → COMPARAR (vs baseline) → REPORTAR →
DECIDIR** — para decidir por **resultados esperados**, não por fé.

## Pull-only — nunca age sozinho

**O `/simulate` é a ÚNICA porta de execução.** Nunca inicie uma simulação por conta própria e nunca a
rode em "todo trabalho" — simular custa (fan-out + dry-run do domínio). Mesmo com o simulador
presente, ele fica **parado** até `/simulate`.

**Nudge pontual (só aviso, não execução):** diante de uma mudança de **alto risco** você PODE sugerir,
em **uma linha**, *"considere `/simulate`"* — **sem rodar nada**:

| Pode sugerir (1 linha, sem executar) | Nunca sugerir |
|--------------------------------------|----------------|
| migração / mudança de schema | mudança **trivial** ou reversível |
| fix que pode alterar volume/qualidade de dados | refactor, rename, docs, ajuste pequeno |
| mudança com blast-radius incerto | quando não há simulador (Passo 0) |

Regra de bolso: se errar custa minutos, **siga**; se custa horas/dias e há simulador, **sugira**
`/simulate`. A decisão de rodar é sempre do usuário.

---

## Passo 0 — Capacidade

Resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md) e verifique se há um
simulador de domínio:

```powershell
. "$toolsRoot/simulate.ps1"
$cap = @(Get-SimulationCapability -Dir .claude/agents/domain)
```

**Sem capacidade** (`$cap` vazio) → **degradação consciente**: avise *"nenhum simulador para este
domínio — rode `/audit-agents` para gerar um (ex.: `dbt-simulator`)"* e **encerre**. **Não invente
números.**

---

## Passo 1 — PROPOR

Capture do usuário a **mudança/fix** concreto e o **alvo** (qual modelo/schema/recurso). Monte o
contexto: `project-context.md` + a KB do domínio (camadas `tools/`+`operations/`), se existir.

---

## Passo 2 — SIMULAR (fan-out)

**Fan-out** via ferramenta **`Agent`**: invoque o simulador de domínio (de `$cap`), passando **o
contrato abaixo** + o fix + o contexto. O simulador roda a ferramenta de **dry-run isolada** do
domínio (ex.: `dbt build --empty`/`--defer`/data-diff, `EXPLAIN`, `terraform plan`) — **nunca**
produção.

### Contrato do simulador de domínio (passe isto ao subagente)

Um agente `role: simulation` (gerado pelo `/audit-agents`) que:

- Roda **só** dry-run/sandbox — **nunca toca produção/dado real**.
- Compara contra o **baseline** e **declara as premissas** (snapshot, amostra, escopo).
- Emite o relatório em `.claude/sdd/simulations/<data>-<slug>.md` com **6 seções H2 obrigatórias**:

  | Seção | Conteúdo |
  |-------|----------|
  | `## Baseline` | estado atual / referência de comparação |
  | `## Proposta` | o fix/mudança simulado |
  | `## Resultado` | números esperados pós-mudança |
  | `## Diff` | delta baseline→resultado |
  | `## Premissas` | snapshot/amostra/escopo assumidos |
  | `## Isolamento` | **como** foi isolado (prova de que produção não foi tocada) |

---

## Passo 3 — COMPARAR + relatório

O simulador escreve o relatório com as **6 seções obrigatórias** acima. O `Diff` carrega a comparação
resultado×baseline.

---

## Passo 4 — Conformidade

```powershell
$findings = @(Test-SimulationReportConforms -Text (Get-Content -Raw .claude/sdd/simulations/<arquivo>.md))
```

Há finding (`missing-section`/`isolation-not-declared`) → o relatório está **incompleto**; **avise e
não apresente os números** (resultado sem isolamento declarado não é confiável).

---

## Passo 5 — REPORTAR + DECIDIR

Apresente o **diff + resultados esperados + premissas**. **Encerre aqui — o `/simulate` nunca aplica.**
Aplicar a mudança é decisão humana, por outro fluxo (`/build` ou manual).

---

## Regras

- **Nunca aplica** a mudança; **nunca** toca produção/dado real (só dry-run/sandbox).
- **Nunca** inicie simulação por conta própria — é **pull-only** (o nudge é só 1 linha, sem executar).
- **Não** sugira `/simulate` em mudança **trivial**/reversível — o nudge é só para alto risco (vira ruído).
- **Não** se manifeste quando **não há simulador** (Passo 0) — silêncio total.
- Sem simulador → **degrada** (`/audit-agents`); **nunca inventa números**.
- Sempre declara **premissas** e **isolamento** no relatório — toda projeção tem premissas.
- Sem engine — `Agent` nativo + conformidade determinística (`tools/simulate.ps1`).

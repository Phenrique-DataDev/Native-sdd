# Simulation — simular antes de aplicar (postura · pull-only, opt-in)

> Antes de **aplicar** uma mudança arriscada (fix de modelo de dados/dbt, migração de schema, IaC,
> qualquer mudança com blast-radius incerto), **simule** num ambiente **isolado** e **compare** contra
> o baseline — decida com números, não no escuro. Acionado por **`/simulate <mudança>`**;
> **nunca-destrutivo, nunca toca produção, nunca aplica**. Sem engine: o base define o **contrato**; a
> simulação real é um **simulador de domínio** gerado pelo `/audit-agents` (G2). Molde
> [`reflection.md`](reflection.md)/[`orchestration.md`](orchestration.md).

## Princípio

Validar uma mudança **só depois de aplicá-la** é caro: o estrago já aconteceu ou exige reverter. O
`/simulate` inverte a ordem — **PROPOR → SIMULAR (isolado) → COMPARAR (vs baseline) → REPORTAR →
DECIDIR** — para que a decisão seja informada por **resultados esperados**, não por fé. O que decide *se
o fix funciona* é julgamento (LLM/ferramenta de domínio); o que torna isso **seguro e verificável** é o
protocolo abaixo + a conformidade do relatório (`tools/simulate.ps1`).

## Pré-condição (capacidade presente)

A postura **só vale quando existe um simulador de domínio** (`role: simulation` em
`.claude/agents/domain/`, gerado pela curadoria `/audit-agents`). Sem ele → **silêncio total**: a
postura nem se manifesta e o `/simulate` degrada (orienta `/audit-agents`). A capacidade fica
**latente** no scaffold até o domínio justificar — é a curadoria/KB que a "ativa", não o base.

Sinal verificável: `tools/simulate.ps1 Get-SimulationCapability -Dir .claude/agents/domain` retorna ≥1.

## Quando aplicar — pull-only, nunca age sozinho

**O `/simulate` é a ÚNICA porta de execução.** O agente **nunca inicia** uma simulação por conta
própria e **nunca** a roda em "todo trabalho" — simular custa (fan-out + dry-run do domínio), então é
**sob demanda**, acionado por você. Mesmo com o simulador presente, ele fica **parado** até `/simulate`.

**Nudge pontual (só aviso, não execução):** diante de uma mudança de **alto risco** o agente PODE
sugerir, em **uma linha**, "considere `/simulate`" — **sem rodar nada**. Restrições do nudge:

| Pode sugerir (1 linha, sem executar) | Nunca sugerir |
|--------------------------------------|----------------|
| migração / mudança de schema | mudança **trivial** ou reversível |
| fix que pode alterar volume/qualidade de dados | refactor, rename, docs, ajuste pequeno |
| mudança com blast-radius incerto | quando não há simulador (pré-condição) |

Regra de bolso: se errar custa minutos, **siga**; se custa horas/dias e há simulador, **sugira**
`/simulate`. A decisão de rodar é sempre **sua** (igual `doubt-driven`/`reflect`: nunca age sozinho).

## O ciclo PROPOR → SIMULAR → COMPARAR → REPORTAR → DECIDIR

| Passo | O que acontece |
|-------|----------------|
| **PROPOR** | Enuncie a mudança/fix concreto + o alvo (qual modelo/schema/recurso). |
| **SIMULAR** | O simulador de domínio roda a ferramenta de **dry-run isolada** (ex.: `dbt build --empty`/`--defer`/data-diff, `EXPLAIN`, `terraform plan`) — **nunca** em produção. |
| **COMPARAR** | Resultado simulado **× baseline** (estado atual). O delta é o sinal de decisão. |
| **REPORTAR** | Relatório com as **6 seções obrigatórias** (abaixo); resultados esperados + premissas explícitas. |
| **DECIDIR** | O humano decide aplicar ou não. **O `/simulate` nunca aplica.** |

## Contrato do simulador de domínio

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

`tools/simulate.ps1 Test-SimulationReportConforms` verifica as 6 seções; `Isolamento` ausente/vazio →
`isolation-not-declared` (relatório incompleto = resultado não-confiável, **não** apresentar números).

## O que NÃO fazer

- **Não** iniciar/rodar simulação por conta própria — é **pull-only**, acionado por `/simulate`.
- **Não** sugerir `/simulate` em mudança **trivial**/reversível — o nudge é só para alto risco (vira ruído).
- **Não** se manifestar quando **não há simulador** (pré-condição) — silêncio total.
- **Não** aplicar o fix — o `/simulate` simula e reporta; aplicar é decisão humana, por outro fluxo.
- **Não** tocar produção / dado real — só dry-run/sandbox.
- **Não** inventar números sem a ferramenta de domínio — sem simulador, **degrade** (rode `/audit-agents`).
- **Não** omitir premissas ou o isolamento — toda projeção tem premissas; explicite-as.
- **Não** construir engine/scoring — `Agent` nativo + a conformidade determinística bastam.

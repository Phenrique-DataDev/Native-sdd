# Reflection — consolidação/compactação da KB (postura, opt-in)

> Quando a KB **cresce** (muitas entradas, redundância, prosa acumulada), consolide o **inchaço**
> **preservando regras implementadas + casos ocorridos**. Nunca apague sem rastro. Acionado por
> **`/reflect`**; nunca-destrutivo (plano → aprova → aplica). Sem engine: o julgamento é do LLM, o
> **gatilho** e a **verificação** são determinísticos (`tools/reflect.ps1`, reusa o `kb-lint`/B7).

## Princípio

A KB só **cresce** (`/train-kb` adiciona; nada consolida) — acumula o mesmo conceito em 2 entradas,
prosa verbosa e conhecimento superado, o que incha o contexto e dilui o sinal. O que decide *o que*
consolidar é julgamento do LLM; o que torna isso seguro é o protocolo abaixo + a verificação
`id-provenance`.

## O que preservar × o que encolher

| Preservar (sinal durável) | Encolher (inchaço) |
|---------------------------|--------------------|
| **Regra implementada** no processo | duplicação (mesmo conceito em N entradas) |
| **Caso ocorrido** (decisão, incidente, exceção) | prosa verbosa em torno da regra/caso |
| Proveniência (de onde veio) | conhecimento **superado**/contradito |

## As 3 operações

| Operação | Quando | Resultado |
|----------|--------|-----------|
| **MERGE** (fundir) | 2+ entradas capturam o **mesmo** conceito | 1 entrada; a sobrevivente lista `consolidates: [ids]` |
| **COMPRESS** (resumir) | 1 entrada verbosa | regra + caso **verbatim**, prosa cortada (mesma entrada/id) |
| **PRUNE** (podar) | entrada **superada/contradita** | removida; a entrada que a supera lista `supersedes: [ids]` |

## Como aplicar (ciclo do `/reflect`)

1. **Gatilho** — `tools/reflect.ps1 Test-KbOverBudget`: sob budget e sem redundância → **no-op**
   ("KB enxuta, nada a consolidar"). Acima → segue.
2. **Por camada×domínio** — trabalhe uma unidade da taxonomia por vez (fan-out via `Agent`); contexto
   limitado, sem misturar domínios.
3. **Plano, não ação** — proponha um **plano/diff** (`_reflections/<data>-plan.md`): por unidade, as
   operações com `targets`/`rationale`/`provenance`. Apresente e **peça aprovação**.
4. **Backup antes de aplicar** — só após aprovação; faça backup das entradas afetadas.
5. **Proveniência** — grave `consolidates`/`supersedes` nas sobreviventes (frontmatter).
6. **Verifique** — `Test-ReflectProvenance`: **0** `id` removido sem rastro. Órfão → **reverter do
   backup** e avisar (não deixe pela metade).
7. **Reindexe** — rode `/sync-context` (G4) para o índice/ponteiros refletirem o novo estado.

## O que NÃO fazer

- **Não** apague uma entrada sem registrá-la em `consolidates`/`supersedes` de uma sobrevivente.
- **Não** descarte uma **regra** ou um **caso ocorrido** — só o inchaço ao redor.
- **Não** funda entre **domínios** diferentes (MVP consolida dentro do domínio).
- **Não** aplique sem **plano aprovado** e **backup** — a postura é nunca-destrutiva.
- **Não** construa engine/scoring/auto-tuning — `Agent` nativo + a verificação determinística bastam.

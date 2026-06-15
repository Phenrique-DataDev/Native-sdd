# /train-kb — povoar a KB por ondas

Popula a base de conhecimento do projeto a partir do `project-context.md`: **infere** os
módulos de conhecimento do stack/domínio real, gera um **plano de ondas** em
`.claude/kb/_waves/` e **executa** cada onda num subagente dedicado, gravando entradas
válidas nas 4 camadas. Na camada `tools/`, usa **docs atuais via context7** (regra
[`docs-first`](../rules/docs-first.md)) para garantir comandos funcionais e atualizados.

> Feature **G3** (EPIC G — curadoria/auto-otimização). A KB nasce **vazia** de propósito; este
> comando a popula. Idempotente: reexecutar **não duplica** — só preenche lacunas.

---

## Uso

```text
/train-kb              # plano de ondas + execução interativa das ondas
/train-kb --plan-only  # só gera/atualiza o plano em _waves/, sem executar
```

---

## Passo 0 — Carregar contexto

```text
Read(".claude/rules/project-context.md")
```

Extraia: **LINGUAGEM**, **FRAMEWORK/RUNTIME**, **DADOS**, **INFRA**, **DOMÍNIO**, **CONVENÇÕES**.

**Gate:** se o arquivo contiver `status: template` (ou placeholders `<...>`), **pare** e
oriente o usuário a rodar **`/setup`** primeiro — sem contexto não há o que treinar.

---

## Passo 1 — Derivar os módulos de conhecimento (uma onda por módulo)

A partir do stack/domínio **real**, infira os módulos e **mapeie cada um a uma camada** da
taxonomia (não use lista fixa — derive do contexto):

| Sinal no contexto | Camada-alvo | Exemplo de onda |
|-------------------|-------------|-----------------|
| Tecnologia/lib/framework/CLI da stack | `tools/` | `tools-sql`, `tools-dbt`, `tools-pandas` |
| Regra de negócio / KPI / glossário do domínio | `business/` | `business-financas` |
| O que **nós** construímos (schemas, IDs, URLs internas) | `implementation/` | `implementation-warehouse` |
| Como rodar/recuperar (runbooks) | `operations/` | `operations-deploy` |

Só proponha o que o contexto **justifica** — sem sinal de uma área, não invente onda.

---

## Passo 2 — Escrever o plano de ondas

Para cada módulo, escreva um arquivo em
`.claude/kb/_waves/<NN>-<camada>-<domínio>.yaml` (numere por ordem sugerida de execução),
com `status: pending`:

```yaml
wave: 02-tools-sql           # = nome do arquivo sem extensão
target_layer: tools          # business | tools | implementation | operations
domain: sql                  # pasta de domínio
status: pending              # pending | running | done
subagent: explorer           # subagente que executa a onda
libs:                        # OBRIGATÓRIO só quando target_layer == tools
  - name: dbt
    versionable: true        # true → docs-first aplica context7
entries_expected:            # opcional: guia o subagente
  - id: window-functions
    content_type: pattern
skills_needed:               # opcional: capacidades (skills) que a onda pressupõe — alimenta o /skill-gap (I2)
  - name: sql-window-functions
    capability: escrever window functions corretas
notes: aplica docs-first (context7) nas libs versionable
```

> **Skill-gap (I2):** se a onda declara `skills_needed`, o
> [`/skill-gap`](skill-gap.md) detecta as que **faltam** (cruzando com o inventário do
> `/update-skills`) e gera o esqueleto da skill. Passo **opcional/não bloqueante** — rode-o após
> o plano se quiser fechar as lacunas de capacidade antes de executar as ondas.

---

## Passo 3 — Apresentar o plano

Mostre as ondas derivadas (camada · domínio · libs · subagente) e use `AskUserQuestion`:
*"Derivei {N} onda(s). Executar agora?"* → (a) executar todas · (b) escolher quais ·
(c) só o plano (encerra; equivale a `--plan-only`).

---

## Passo 4 — Executar cada onda escolhida

Para cada onda: marque `status: running` no `.yaml` e invoque o subagente via **`Agent`**,
passando como contexto: o `.yaml` da onda, a [`kb-taxonomy.md`](../rules/kb-taxonomy.md) e —
se `target_layer: tools` — a regra [`docs-first.md`](../rules/docs-first.md). Ondas
independentes podem rodar em paralelo (várias chamadas `Agent` na mesma mensagem).

---

## Passo 5 — (no subagente) Gerar as entradas

Para cada entrada da onda, escreva em
`.claude/kb/<camada>/<domínio>/<tipo>/<id>.md` com o frontmatter da taxonomia (use
[`_TEMPLATE.md`](../kb/_TEMPLATE.md)). Uma entrada = **um** conceito/padrão/referência/runbook.

- **Idempotência:** se `<id>.md` já existe no caminho canônico e tem frontmatter válido,
  **pule** (não sobrescreva). Só gere o que falta.
- **Camada `tools/` + lib versionável:** aplique a regra **docs-first** —
  `mcp__context7__resolve-library-id` → `mcp__context7__query-docs`; grave a proveniência no
  frontmatter (`source: context7`, `lib_id`, `checked_at: YYYY-MM-DD`). **Sem o MCP** ou se a
  lib não resolver: gere a entrada com `status: unverified` e **avise** o usuário (degradação
  graciosa — nada quebra).
- **Conceito agnóstico** (sem fornecedor/versão, ex.: "modelagem dimensional"): é `tools/` mas
  **não** aciona context7 — vem de conhecimento estável, sem `lib_id`.
- **Tamanho-alvo (advisory):** mire o orçamento sugerido por tipo (ver
  [`kb-taxonomy.md`](../rules/kb-taxonomy.md) → *Orçamento de tamanho*): ~16 000 chars para
  `concept`/`pattern`/`reference`, ~4 800 para `quick-reference`/`index`, ~32 000 para
  `runbook`/`spec` (código em fenced block não conta). Estourar **não bloqueia** — `kb-lint`
  apenas sinaliza; se a entrada for grande demais, prefira **dividir** em entradas atômicas.

---

## Passo 6 — Fechar a onda

Marque a onda como `status: done` no `.yaml` e atualize `.claude/kb/_index.yaml` (registro de
domínios da KB), se existir.

---

## Passo 7 — Relatório final

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TREINO DA KB CONCLUÍDO — {NOME_PROJETO}
Ondas: {done}/{total}   Entradas criadas: {N}   Puladas (já existiam): {N}
Não verificadas (sem context7): {N}  → revise quando o MCP estiver disponível
→ Veja em .claude/kb/  ·  valide com tools/kb-lint.ps1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Idempotência e regras

- **Idempotência:** a chave é o `id` no caminho canônico — entrada já existente e válida é
  **pulada**. Ondas com `status: done` são puladas na reexecução.
- **Nunca** sobrescreva uma entrada existente sem confirmação explícita.
- `id` **único por domínio** (o mesmo `id` pode existir em domínios diferentes).
- **Sem stack/domínio claros → não invente** — peça para rodar/atualizar o `/setup`.
- O comando **só adiciona** conhecimento; mantenha cada entrada numa **única** camada.

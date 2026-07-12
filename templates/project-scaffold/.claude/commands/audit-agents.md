---
description: "Curadoria de agentes de domínio — gera agentes especializados em .claude/agents/domain/ de forma idempotente e aprovada"
---

# /audit-agents — curadoria de agentes de domínio

Especializa o catálogo de agentes do projeto: lê o `project-context.md`, **infere** as áreas
relevantes ao stack/domínio real, detecta lacunas e **gera agentes de domínio** em
`.claude/agents/domain/` — de forma **idempotente** e com sua aprovação a cada passo.

> Esta é a feature **G2** (EPIC G — curadoria/auto-otimização). O comando **adiciona** ao
> catálogo de papéis universais do base (`explorer`, `code-reviewer`, `test-writer`,
> `git-workflow`, `security-reviewer`, `debugger`, `validator`, `documenter`, `external-observer`); nunca os substitui.
>
> **Papéis universais já cobertos pelo base — NÃO regerar:** higiene de git/PR, revisão de
> segurança, debug de causa-raiz, validação de conformidade, **documentação humano×LLM** (`documenter`)
> e **observação de caixa-preta** de runtime externo (`external-observer`, role `observation`).
> Este comando gera **apenas** experts de **stack/domínio** (ex.: `sql-reviewer`, `frontend-specialist`,
> `infra-specialist`) — o que o base, por ser agnóstico de stack, não cobre.

---

## Uso

```text
/audit-agents              # auditoria completa + geração interativa das lacunas
/audit-agents --only-map   # só o mapa de cobertura, sem gerar nada
/audit-agents --regen      # reconsidera também os agentes já gerados (generated_by)
```

---

## Passo 0 — Carregar contexto

```text
Read(".claude/rules/project-context.md")
```

Extraia: **LINGUAGEM**, **FRAMEWORK/RUNTIME**, **DADOS**, **INFRA**, **DOMÍNIO**, **CONVENÇÕES**.

**Gate:** se o arquivo contiver `status: template` (ou placeholders `<...>`), **pare** e
oriente o usuário a rodar **`/setup`** primeiro — sem contexto não há o que especializar.

---

## Passo 1 — Inventariar agentes existentes

```text
Glob(".claude/agents/**/*.md")
```

Para cada arquivo, leia só o frontmatter e registre `name`, `description` e se tem
`generated_by: audit-agents` (= foi gerado por esta curadoria). Monte uma tabela interna
`origem(núcleo/gerado) | name | descrição`. **Não** considere `AGENT_MAP.md` um agente.

---

## Passo 2 — Mapa de cobertura (derivado do contexto)

**Não use uma tabela fixa de áreas.** A partir do stack/domínio **real** do passo 0, infira
as áreas que fazem sentido para *este* projeto e proponha agentes específicos. Heurísticas
(exemplos, não checklist obrigatório):

| Sinal no contexto | Área candidata | Agente sugerido (exemplo) |
|-------------------|----------------|---------------------------|
| Dados/SQL/warehouse/dbt | Modelagem e revisão de SQL | `sql-reviewer`, `dbt-modeler` |
| **Stack simulável** (dbt, SQL, migrações, IaC) | **Simular mudança antes de aplicar** (`/simulate`) | `dbt-simulator`, `sql-simulator`, `terraform-simulator` (`role: simulation`) |
| Frontend (React/Vue/Next) | Componentes e UX | `frontend-specialist` |
| Backend/API | Serviços e contratos | `api-specialist` |
| IA/LLM/RAG | Prompt eng. e avaliação | `llm-specialist` |
| Infra/IaC (Terraform/Docker/CI) | Infra como código | `infra-specialist` |
| Domínio regulado (fintech, saúde) | Compliance | `compliance-reviewer` |
| Regras de negócio complexas | Especialista de domínio | `<dominio>-domain-expert` |

> **Simulador de domínio (`role: simulation`):** quando o stack tem uma ferramenta de **dry-run**
> (ex.: `dbt build --empty`/`--defer`/data-diff, `EXPLAIN`, `terraform plan`), gere um `*-simulator`
> que cumpre o **contrato do `/simulate`** ([`rules/simulation.md`](../rules/simulation.md)): roda só
> isolado, **nunca toca produção**, e emite o relatório das 6 seções (incl. `Isolamento`). É o que dá
> ao projeto a capacidade de "simular antes de aplicar". Sem ferramenta de dry-run no stack → não gere.

Para cada área inferida marque: ✅ coberto · ⚠️ parcial · ❌ lacuna (comparando com o
inventário do passo 1). Só proponha o que o contexto **justifica** — se não há sinal de
frontend, não invente um agente de frontend.

> **Papel × stack/domínio:** os papéis **universais** (git/PR, segurança, debug, validação,
> documentação, observação de caixa-preta) já vêm no base — trate-os como ✅ **coberto** e **não** gere
> genéricos equivalentes (incl. role `observation`).
> Gere só o que é específico de **stack/domínio** (a coluna "Agente sugerido" acima é toda de stack/domínio).

---

## Passo 3 — Relatório de cobertura

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
COBERTURA DE AGENTES — {NOME_PROJETO}
Stack: {LINGUAGEM} · {FRAMEWORK} · {DADOS} · {INFRA}   |   Domínio: {DOMÍNIO}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
COBERTO ✅        {agentes do inventário que cobrem áreas}
LACUNAS ❌        {área}: sem agente para {descrição}
A GERAR           {nome-agente} — {justificativa em 1 linha}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Se **não houver lacunas**, diga claramente que a cobertura está completa e **encerre** — não
invente agentes. Se `--only-map`, **pare aqui**.

---

## Passo 4 — Confirmar geração

Use `AskUserQuestion`: *"Encontrei {N} lacuna(s). Gerar agora?"* →
(a) gerar todas · (b) escolher quais · (c) só o relatório (encerra).

---

## Passo 5 — Gerar cada agente escolhido (padrão avançado, sempre)

Salve em `.claude/agents/domain/<nome>.md` (crie a pasta `domain/` se não existir). Use
contexto **real** — **nunca** deixe placeholders `{...}` no arquivo final. Este é o
**padrão-alvo sempre** para agente de domínio novo — a mesma densidade dos 11 agentes base do
scaffold (`designer`, `security-reviewer`, `documenter`…): "Conhecimento extra" explicando o
**mecanismo** por trás da regra (não só a regra), "Regras críticas" em pares concretos e
"Referências" citando fonte real. Não é uma opção entre "rápido" e "completo" — é o único modo.

**Pesquise antes de escrever a seção "Conhecimento extra" — nunca da memória.** `context7`
(`resolve-library-id`→`query-docs`) para a lib/framework/CLI **versionável** do domínio real
(mesma disciplina de [`docs-first.md`](../rules/docs-first.md)); `WebSearch`/`WebFetch` para
prática de mercado sem fornecedor único (ex.: padrão de revisão de PR, convenção de nomeação).
Toda afirmação técnica precisa aparecer em `## Referências` (título + URL/doc) — sem fonte
citável, não vire regra no arquivo final.

Frontmatter obrigatório, no mesmo formato dos agentes do núcleo, **mais** o marcador de origem:

```markdown
---
name: <nome-kebab-case-único>
description: <quando acionar — gatilho concreto do stack/domínio real>
tools: Read, Grep, Glob, Edit, Bash
model: inherit
role: <papel mais próximo: review|testing|search|security|debug|validation|vcs|simulation>
connects_to: [<agente do base com que encadeia, ex.: code-reviewer>]
generated_by: audit-agents
---

Você é um <especialista em X para {DOMÍNIO}>. <Responsabilidade em 1–2 linhas.>

## Antes de agir
- Leia `.claude/rules/project-context.md` (stack/convenções).
- Consulte a KB de `{domínio relevante}` se existir.

## Como trabalhar
- <processo concreto na stack real: {LINGUAGEM}/{FRAMEWORK}/{DADOS}>
- Siga as convenções: {CONVENÇÕES do contexto}.

## Conhecimento extra: <subtema do domínio que exige explicação, não só regra>
<O MECANISMO por trás da prática — por que funciona assim, não só "faça X". Derivado da pesquisa
do passo anterior (context7/WebSearch), citado em Referências. Repita esta seção (com subtítulo
diferente) para cada subtema que o domínio real justificar — não force se não houver o que explicar.>

## Regras críticas (faça / não faça)
| Faça | Não faça |
|------|----------|
| <par concreto, específico da stack/domínio real — não princípio genérico> | <o erro real que essa regra evita> |

## Saída
- <o que entrega: revisão/artefato/relatório>, específico e acionável.

## Referências
- <título da fonte — URL/doc/RFC/versão da lib citada acima via context7 ou WebSearch>
```

O `name` deve ser **único** em todo `.claude/agents/`. Alvo de tamanho: proporcional à
profundidade real do domínio (os agentes base variam de ~80 a ~180 linhas) — não encha por
encher, mas um agente sem "Conhecimento extra"/"Regras críticas"/"Referências" está abaixo do
padrão e não deve ser aceito no Passo 6.

---

## Passo 6 — Mostrar e ajustar

Para cada agente gerado, exiba o conteúdo e pergunte: (a) aceitar e salvar · (b) ajustar
(diga o quê) · (c) descartar. Em (a), `Write(".claude/agents/domain/<nome>.md")`.

---

## Passo 7 — Atualizar roteamento

Se ≥1 agente foi salvo, **`.claude/rules/agent-routing.md`** — adicione/expanda a seção:

```markdown
## Agentes de domínio (`.claude/agents/domain/`)

| Gatilho | Subagent |
|---------|----------|
| {gatilho} | `{nome}` |
```

---

## Passo 7b — Ressincronizar os artefatos derivados (fechar o ciclo na criação)

Se ≥1 agente foi salvo, **normalize e ressincronize** o mapa + o grafo + o índice-KB na hora — não
deixe os derivados stale (é o que esta curadoria existe para evitar). Use o **driver one-shot**
(feature `auto-resync`), que regenera tudo de forma determinística e idempotente:

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/resync.ps1" ; Invoke-Resync -ClaudeDir .claude -Write
```

`Invoke-Resync -Write` regenera `.claude/agents/AGENT_MAP.md`, `graph.json`/`graph.cypher` e
`.claude/kb/_index.yaml` (escreve só o que mudou). **Não** anexe nós ao `AGENT_MAP.md` à mão —
o driver é a **fonte única** (o mesmo que o `/sync-context` usa). Sem o `$toolsRoot` (degradação),
rode `/sync-context` ao final. **Sem backstop automático:** o `resync-lint` (staleness-lint) saiu
do `check.ps1`/CI na postura low-friction (2026-06-20) — rodar `/sync-context` após curar é
responsabilidade de quem cura, não uma rede de segurança do CI.

---

## Passo 8 — Relatório final

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
AUDITORIA CONCLUÍDA — {NOME_PROJETO}
Aproveitados: {N}   Gerados: {N} ({nomes})   Descartados: {N}
agent-routing.md: {atualizado|sem alteração}   AGENT_MAP.md: {atualizado|sem alteração}
→ Revise em .claude/agents/domain/  ·  /brainstorm para começar uma feature
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Idempotência e regras

- **Idempotência:** na 2ª execução, identifique os agentes com `generated_by: audit-agents`
  já presentes e **não os duplique** — só preencha lacunas novas. Com `--regen`, reconsidere
  também os já gerados (confirmando antes de sobrescrever).
- **Nunca** sobrescreva um agente existente sem confirmação explícita.
- `name` **único** em todo `.claude/agents/`.
- **Sem lacuna → não inventa** agente. Agentes devem usar contexto real, sem placeholders.
- O comando **só adiciona**; manter o catálogo **enxuto** (só o que o domínio justifica).

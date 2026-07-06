---
description: "Fechar lacunas de skill — detecta capacidades pressupostas pelas ondas e gera a skill faltante"
---

# /skill-gap — fechar lacunas de skill (skill-gap killer)

Detecta as **capacidades** (skills) que as ondas do `/train-kb` **pressupõem** mas o ambiente
**não tem**, e **gera a skill faltante**: cruza o campo `skills_needed:` das ondas com o
inventário do `/update-skills` (I1), propõe os gaps e — sob confirmação — grava o **esqueleto**
da skill em `.claude/skills/`, que o LLM então **preenche**.

> Feature **I2** (EPIC I — skills). Depende do **I1** (inventário) e do **G3** (ondas). O
> `/skill-gap` só cuida do **gap-específico** (detectar + gerar esqueleto). É **referenciado** pelo
> `/train-kb` quando uma onda traz `skills_needed`, mas também roda avulso.

---

## Uso

```text
/skill-gap              # detectar gaps → gerar esqueletos (confirmação) → preencher conteúdo
/skill-gap --plan-only  # só o relatório de gaps (declarados + sugeridos), read-only
```

---

## Passo 1 — Detectar (read-only)

Carregue as funções e cruze as ondas com o inventário de skills:

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/skill-gap.ps1"     # (já dot-source o update-skills.ps1 do I1 via $PSScriptRoot)
$gaps = Get-SkillGap -WavesRoot ".claude/kb/_waves" `
                     -GlobalRoot "$HOME/.claude/skills" -ProjectRoot ".claude/skills"
```

- `Get-DeclaredSkills` lê o `skills_needed:` das ondas (`_waves/*.yaml`); `Get-SkillGap` marca cada
  skill declarada como **`missing`** (ausente do inventário → gerar) ou **`exists`** (já instalada).
- Além das declaradas, **sugira** (LLM) capacidades faltantes lendo o `project-context.md` e as
  ondas — apresente-as como `suggested` (revisar). Para não estreitar a busca, use as **9 categorias
  recorrentes** observadas em skills reais como checklist de amplitude (Anthropic, *"How we use
  Skills"*, 2026-06) — nem todo projeto precisa das 9, é ponto de partida, não requisito:

  | Categoria | Pergunta que provoca a sugestão |
  |-----------|----------------------------------|
  | Referência de lib/API | tem lib interna/externa com uso não-óbvio que se repete? |
  | Verificação de produto | como confirmar que o código funciona (não só compila)? |
  | Fetch/análise de dados | há stack de dados/monitoramento com credencial/consulta recorrente? |
  | Automação de processo | algum workflow manual se repete em vários turnos? |
  | Scaffolding de código | boilerplate com requisito além do puramente sintático? |
  | Qualidade/review | padrão interno de revisão que vale automatizar? |
  | CI/CD e deploy | fetch/push/deploy/rollback com passos fixos? |
  | Runbook | sintoma → investigação estruturada entre ferramentas? |
  | Operação de infra | manutenção rotineira com guarda contra ação destrutiva? |
- As funções são **read-only**.

Se `--plan-only`, **pare aqui** (mostre o relatório).

---

## Passo 2 — Gerar esqueleto (sob confirmação)

Para cada gap **`missing`** (declarado ou sugerido aceito):

1. **Peça confirmação** (`AskUserQuestion`): *"{N} skill(s) faltando. Gerar os esqueletos?"* →
   (a) gerar todas · (b) escolher quais · (c) cancelar.
2. Ao aceitar, para cada skill gere o esqueleto e grave em `.claude/skills/<name>/SKILL.md`:
   ```text
   $md = Format-SkillScaffold -Name $g.Skill -Description $g.Capability -Capability $g.Capability
   # gravar só se .claude/skills/<name>/SKILL.md NÃO existir (não sobrescreve)
   ```
3. **Nunca** sobrescreva uma skill existente — se já houver, **pule** e avise (atualizar é o
   `/update-skills`, I1). Gaps `exists` ficam fora da geração.

---

## Passo 3 — Preencher o conteúdo (padrão avançado, sempre)

Para cada skill recém-criada, **autore** (LLM) as seções `TODO` (Quando usar · Passos · Casos reais ·
Regras críticas · Gotchas · Referências · Se crescer) a partir da capacidade e do contexto do
projeto. Mantenha `status: scaffolded` até revisão humana — o conteúdo gerado é **proposta**, não
verdade final. Este é o **padrão-alvo sempre** para skill nova (mesma densidade dos 11 agentes base
do scaffold) — não uma opção entre "rápido" e "completo".

**Pesquise antes de escrever — nunca da memória.** `Casos reais`, `Regras críticas` e `Gotchas`
exigem fonte real: `WebSearch`/`WebFetch` para prática de mercado, `context7` quando a skill envolve
lib/framework/CLI **versionável** (mesma disciplina de [`docs-first.md`](../rules/docs-first.md)).
Toda afirmação nessas três seções precisa aparecer em `## Referências` (título + URL) — sem fonte
citável, não escreva a afirmação como se fosse regra.

**Boas práticas de autoria** (Anthropic, *"How we use Skills"*, 2026-06 — já moldam o esqueleto do
`Format-SkillScaffold`; reforce ao preencher o `TODO`):

| Princípio | Aplique assim |
|-----------|----------------|
| `description` é gatilho do **modelo**, não resumo humano | escreva a frase/palavra que apareceria no pedido real (verbo, sintoma, nome de ferramenta) — não um resumo de o-que-a-skill-faz |
| **Casos reais** são a prova de que a skill blinda algo de verdade | 2–3 cenários concretos e **ancorados em fonte** de como a tarefa falha sem a disciplina — sintoma → causa-raiz → antídoto, não hipótese |
| **Regras críticas** em pares concretos | tabela `Faça \| Não faça` específica o bastante pra aplicar sem interpretar — não princípio solto ("seja claro") |
| **Gotchas é a seção mais valiosa** | 1 edge case real vale mais que 3 parágrafos de teoria — nunca deixe vazia; comece com o gotcha que motivou a skill |
| Não reafirme o óbvio | Claude já sabe programar/ler código — só documente o que ele **não** saberia sozinho |
| Evite railroading | dê o necessário (contexto, snippet pronto), não um script rígido passo-a-passo — deixe o julgamento de adaptar a ele |
| Skill é **pasta**, não só markdown | template/snippet reusável vai em `assets/`/`scripts/` (o Claude copia/compõe) em vez de inline no `SKILL.md` |
| Composição por nome | se esta skill depende de outra já instalada, referencie-a pelo nome no texto — o modelo invoca sozinho se ela existir, sem manifesto de dependência |
| **Alvo ~100 linhas no `SKILL.md`** | passou disso, é sinal de mover detalhe pra `assets/`/`references/<tema>.md` (progressive disclosure) — o índice fica enxuto, o aprofundamento mora no anexo |

A skill gerada nasce como **`custom`** para o `/update-skills` (sem contraparte no baseline) → é
**preservada** na próxima higiene.

---

## Passo 4 — Ressincronizar os artefatos derivados (fechar o ciclo na criação)

Se ≥1 skill foi criada, **normalize e ressincronize** o grafo + mapa + índice-KB na hora — uma skill
nova entra no grafo unificado (nós `:Skill`, elos `:PRESUPPOSES`/`:USES_SKILL`) e deixaria os derivados
stale. Use o **driver one-shot** (feature `auto-resync`), determinístico e idempotente:

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/resync.ps1" ; Invoke-Resync -ClaudeDir .claude -Write
```

`Invoke-Resync -Write` regenera `graph.json`/`graph.cypher`, `AGENT_MAP.md` e `.claude/kb/_index.yaml`
(escreve só o que mudou) — fonte única, a mesma do `/sync-context`. Sem o `$toolsRoot` (degradação),
rode `/sync-context` ao final. **Sem backstop automático:** o `resync-lint` (staleness-lint) saiu
do `check.ps1`/CI na postura low-friction (2026-06-20) — rodar `/sync-context` após curar é
responsabilidade de quem cura, não uma rede de segurança do CI.

---

## Regras

- **Detecção read-only:** `Get-DeclaredSkills`/`Get-SkillGap` nunca escrevem.
- **Não sobrescrever:** skill já existente → pular (não regerar); `exists` fora do plano.
- **Gerar sob confirmação:** nada é gravado em `.claude/skills/` sem o usuário aceitar.
- **Escopo projeto:** a skill gerada vai para `.claude/skills/` (gap é do domínio).
- **Conteúdo do LLM é proposta:** `status: scaffolded` sinaliza revisar.
- **`--plan-only` é read-only:** só o relatório, sem gerar nada.
- **Duas rotas de distribuição, não confundir:** `/skill-gap` cobre a rota **repo-based**
  (`.claude/skills/`, gap específico do domínio deste projeto); a rota **repertório curado**
  (skills/plugins de terceiros validados) é o [`/supplements`](supplements.md) — opt-in,
  user-scoped. Gap do domínio → `/skill-gap`; capacidade genérica já validada → `/supplements`.

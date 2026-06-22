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
  ondas — apresente-as como `suggested` (revisar).
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

## Passo 3 — Preencher o conteúdo

Para cada skill recém-criada, **autore** (LLM) as seções `TODO` (Quando usar · Passos · Notas) a
partir da capacidade e do contexto do projeto. Mantenha `status: scaffolded` até revisão humana —
o conteúdo gerado é **proposta**, não verdade final.

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
rode `/sync-context` ao final. O guard `resync-lint` (CI) pega quem esquecer.

---

## Regras

- **Detecção read-only:** `Get-DeclaredSkills`/`Get-SkillGap` nunca escrevem.
- **Não sobrescrever:** skill já existente → pular (não regerar); `exists` fora do plano.
- **Gerar sob confirmação:** nada é gravado em `.claude/skills/` sem o usuário aceitar.
- **Escopo projeto:** a skill gerada vai para `.claude/skills/` (gap é do domínio).
- **Conteúdo do LLM é proposta:** `status: scaffolded` sinaliza revisar.
- **`--plan-only` é read-only:** só o relatório, sem gerar nada.

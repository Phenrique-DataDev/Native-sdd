---
description: "Higiene das skills — inventaria, diagnostica e atualiza as skills dos dois escopos, com backup antes de escrever"
---

# /update-skills — higiene das skills (inventário + update)

Mantém as **skills** em ordem: **inventaria** os dois escopos (global `~/.claude/skills/` +
projeto `.claude/skills/`), **diagnostica** a saúde de cada uma (válida · desatualizada · órfã ·
malformada) e, sob confirmação, **aplica o update** re-espelhando do baseline — **preservando** as
skills customizadas/geradas e com **backup** antes de qualquer escrita.

> Feature **I1** (EPIC I — skills). O `/update-skills` só cuida do que **já existe** (ou do que o
> baseline traz). **Gerar** skills novas a partir de lacunas de capacidade é o **I2** (skill-gap
> killer) — não é feito aqui.

---

## Uso

```text
/update-skills           # inventário → diagnóstico → update sob confirmação (com backup)
/update-skills --check   # só o diagnóstico (inventário + saúde), read-only
```

---

## Passo 1 — Inventariar (read-only)

Carregue as funções e mapeie os dois escopos:

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/update-skills.ps1"     # (já dot-source o onboarding/windows/lib.ps1 via $PSScriptRoot)
$inv = Get-SkillInventory -GlobalRoot "$HOME/.claude/skills" -ProjectRoot ".claude/skills"
```

- `Get-SkillInventory` lê cada `<escopo>/<skill>/SKILL.md` e resolve a **precedência**: uma skill
  de mesmo nome nos dois escopos → a **do projeto vence** (a global fica `ShadowedBy='project'`).
- É **read-only** — não toca em nada.

---

## Passo 2 — Diagnosticar e relatar

Anote a saúde de cada skill e gere o relatório:

```text
foreach ($s in $inv) {
    $base = Get-BaselineMap -SourceRoot <baseline-do-escopo> -DestRoot <raiz-do-escopo>
    $h = Get-SkillHealth -Skill $s -BaselineMap $base
    $s.Health = $h.Health; $s.IsCustom = $h.IsCustom; $s.Evidence = $h.Evidence
}
Format-SkillReport -Inventory $inv
```

- Estados (por precedência): **`orphan`** (pasta sem `SKILL.md`) → **`malformed`** (sem
  `name`/`description`) → **`stale`** (difere do baseline por hash) → **`valid`**.
- **`custom`** = skill válida **sem** contraparte no baseline → marcada e **nunca** atualizada.

Se `--check`, **pare aqui**.

---

## Passo 3 — Aplicar o update (sob confirmação)

```text
$plan = Get-SkillUpdatePlan -BaselineRoot <baseline-do-escopo> -LocalRoot <raiz-do-escopo>
```

1. Se o plano estiver **vazio**, informe *"skills em dia"* e termine.
2. Senão, **peça confirmação** (`AskUserQuestion`): *"{N} skill(s) desatualizada(s). Atualizar do
   baseline?"* → (a) aplicar · (b) ver diff · (c) cancelar.
3. Ao aceitar, aplique item a item reusando a infra do instalador (faz **backup** automático):
   ```text
   $summary = New-InstallSummary
   foreach ($item in $plan) { Install-BaselineItem -Item $item -Summary $summary }
   Write-Summary -Summary $summary
   ```

---

## Regras

- **Inventário/diagnóstico read-only:** `Get-SkillInventory`/`Get-SkillHealth`/`Get-SkillUpdatePlan`
  nunca escrevem.
- **Nunca sobrescrever skill `custom`:** sem contraparte no baseline → fora do plano por construção.
- **Backup antes de escrever:** `Install-BaselineItem` faz backup do destino existente.
- **Não gerar skills novas:** lacunas de capacidade são do **I2** (skill-gap killer).
- **`--check` é read-only:** só o diagnóstico, sem aplicar nada.

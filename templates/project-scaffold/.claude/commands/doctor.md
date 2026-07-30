---
description: "Health-check do runtime instalado dos guards de segurança — prova que os hooks ainda disparam (não só que a config existe)"
---

# /doctor — saúde do runtime dos guards (R2)

Verifica se os **2 guards de segurança** (`secret` / `destructive`) **realmente
disparam** na sua instalação — não só se o template está correto. Fecha o buraco do **R2**: quando
o `pwsh` sai do PATH ou um hook é movido/quebrado, o spawn falha (exit 9009/127 ≠ 2) e o Claude Code
**prossegue**; os guards "ask" desligam **em silêncio** e você acredita estar protegido sem estar.

> **Read-only.** Não escreve em `~/.claude` nem toca produção. Roda no `pwsh` (que funciona quando
> você o invoca) e **prova o comportamento** dos guards instalados.

---

## Uso

```text
/doctor     # imprime o painel de saúde dos guards instalados
```

---

## Passo 1 — Resolver a camada `tools/` e rodar o health-check

```powershell
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
if ($toolsRoot) {
    . "$toolsRoot/doctor.ps1"
    Format-DoctorReport (Invoke-SddDoctor).Findings
}
```

`Invoke-SddDoctor` checa, em ordem: **(1)** `pwsh` (bare) resolve no PATH — o que o spawn nativo do
hook precisa; **(2)** `~/.claude/settings.json` existe e registra os guards, e cada command-path
aponta para um `.ps1` que **existe em disco**; **(3)** invoca cada guard via `pwsh -NoProfile -File
<ps1>` com um **payload sintético** que deve disparar `ask` (`secret` → `cat .env`; `destructive` →
`rm -rf /`) e confere a `permissionDecision`. Cada achado é `ok` · `fail` (gate reprova) · `skip`
(não-aplicável).

**Como ler:** todo `[ OK ]` → os guards disparam no runtime. Qualquer `[FAIL]` → **aja**: `pwsh-no-path`
→ reinstale/conserte o PATH do PowerShell; `guard:<nome>` → reinstale o onboarding (`install.ps1`)
para reescrever o `settings.json` e recopiar os hooks.

---

## Passo 2 — Degradação consciente

Se `$toolsRoot` **não resolver** (sem `tools/` relativo nem `$env:SDD_WORKFLOW_HOME`), **avise** que a
camada determinística está indisponível e faça a checagem **à mão**, sem inventar:

- **pwsh:** `Get-Command pwsh` resolve? Sem ele, os hooks nativos não spawnam.
- **settings:** `~/.claude/settings.json` tem `hooks.PreToolUse` com os 2 guards, e os paths
  (`~/.claude/hooks/*-guard.ps1`) existem em disco?
- **comportamento:** rode `echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | pwsh
  -NoProfile -File ~/.claude/hooks/destructive-guard.ps1` — esperado: JSON com
  `permissionDecision: "ask"`. Sem saída → o guard **não** está disparando.

---

## Regras

- **Read-only:** `/doctor` nunca escreve em `~/.claude` nem aplica correção — só diagnostica e
  **orienta** a próxima ação (reinstalar o onboarding / consertar o PATH).
- **Prova o runtime, não o template:** o `check.ps1` valida a fonte; o `/doctor` valida o **instalado**.
- **`skip` não é `fail`:** um guard não-aplicável é pulado, não reprovado.
- **Não inventa estado:** se não houver `settings.json` instalado, diz para rodar o onboarding — não
  finge que está saudável.

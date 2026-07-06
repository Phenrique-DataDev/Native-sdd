---
description: "Verifica a conformidade dos artefatos curados (.claude/) do projeto — KB, agentes, settings — e dá um veredito. Read-only."
---

# /check — conformidade da curadoria (lint o que você curou)

Roda, **read-only** e sob demanda, os lints aplicáveis ao **projeto-alvo** sobre os artefatos `.claude/`
que a curadoria gera/instala, e devolve um **veredito** de conformidade. Três seções: **kb** (frontmatter
+ grafo `related`), **agentes** (frontmatter + colisão + corpo + grafo `connects_to`), **config**
(`settings.json`/`settings.local.json`: forma / `permissions.allow` amplo / hook arriscado).

> Diferente dos vizinhos: `/status` mostra **estado** (o que existe, em que fase); o `curation-nudge`
> **avisa staleness** reativo; o `/check` **valida** a conformidade a pedido. Não altera nada. Reusa os
> lints `kb-lint`/`agent-lint`/`config-lint` (não reimplementa parsing). Seção sem alvo (ex.: KB vazia)
> → **n/a** (não falha). Veredito: `error` → **issues**; só `warn` → **conforme com avisos**; nada →
> **conforme**.

---

## Uso

```text
/check     # imprime o painel de conformidade
```

---

## Passo 1 — Resolver a camada `tools/` e gerar o report

```powershell
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
if ($toolsRoot) {
    . "$toolsRoot/project-check.ps1"
    Format-ProjectCheckReport (Get-ProjectCheckReport -Root .)
}
```

`Get-ProjectCheckReport` monta as 3 seções (cada uma **fail-safe**): **kb** (`Get-KbInventory` +
`Invoke-KbLint` sobre `.claude/kb`), **agent** (`Invoke-AgentLint` sobre `.claude/agents`), **config**
(`Invoke-ConfigLint` sobre `.claude/settings*.json`). `Get-CheckVerdict` (pura) agrega as severidades e
`Format-ProjectCheckReport` imprime o painel determinístico (seção · status · contagem error/warn ·
detalhe · veredito).

**Próximo passo do veredito:** `issues` → corrija os `error` antes de confiar na curadoria (KB malformada
→ revisar/`/reflect`; agente com dangling → ajustar `connects_to`; config malformada → corrigir o JSON).
`warnings` → revisão opcional (advisory). `ok` → seguir.

---

## Passo 2 — Degradação consciente

Se `$toolsRoot` **não resolver** (sem `tools/` relativo nem `$env:SDD_WORKFLOW_HOME`), **avise** que a
camada determinística está indisponível e monte um quadro **à mão** a partir do que dá para ler — **sem
inventar** e sem reimplementar a varredura em silêncio:

- **KB:** liste `.claude/kb/**/*.md` e confira a olho o frontmatter (`id`/`layer`/`domain`/`content_type`/
  `status`); aponte ausências óbvias.
- **Agentes:** liste `.claude/agents/*.md`; confira `name`/`role`/`connects_to` e a seção "Regras
  críticas (faça / não faça)".
- **Config:** abra `.claude/settings.json` e confira se é JSON válido e se não há `allow` amplo (`*`).

---

## Regras

- **Read-only:** `/check` nunca escreve nem normaliza estado — só lê, valida e apresenta.
- **Reuso, não reimplementação:** os achados vêm de `Get-KbInventory`/`Invoke-KbLint`/`Invoke-AgentLint`/
  `Invoke-ConfigLint`; não reparseie frontmatter/JSON à mão (exceto na degradação consciente do Passo 2).
- **Seção sem alvo → n/a**, nunca falha — projeto recém-criado (KB vazia) não "reprova".
- **Não corrige** — `/check` é diagnóstico; corrigir vai por `/reflect`/`/train-kb`/edição manual.
- Mostra **caminhos e regras** dos achados, nunca o **conteúdo** de `settings.json`.

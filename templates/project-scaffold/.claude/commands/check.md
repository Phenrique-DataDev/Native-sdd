---
description: "Verifica a conformidade dos artefatos curados (.claude/) do projeto — KB, agentes, settings, ciclo SDD — e dá um veredito. Read-only."
allowed-tools: Read Grep Glob
disallowed-tools: Edit Write NotebookEdit
metadata:
  contract: read-only
---

# /check — conformidade da curadoria (lint o que você curou)

Roda, **read-only** e sob demanda, os lints aplicáveis ao **projeto-alvo** sobre os artefatos `.claude/`
que a curadoria gera/instala, e devolve um **veredito** de conformidade. Seis seções: **kb** (frontmatter
+ grafo `related`), **agentes** (frontmatter + colisão + corpo + grafo `connects_to`), **config**
(`settings.json`/`settings.local.json`: forma / `permissions.allow` amplo / regra de caminho que o
harness ignora — `Write(caminho)` no lugar de `Edit(caminho)`, que num `deny` não protege nada / hook
arriscado) e **sdd**
(`orphan-build-report`: relatório de feature **já arquivada** que ficou em `.claude/sdd/reports/` —
o passo 3 do [`/ship`](ship.md) não rodou, e é isso que faz o `/status` anunciar como aberta uma
feature encerrada; `build-report-sem-mapa` / `build-report-mapa-vazio`: BUILD_REPORT **vivo** sem a
seção `## Não exercitado` preenchida — o mapa de cobertura de onde saíram **todos** os defeitos que
a revisão comprou nas rodadas 5 e 6 do baseline), **link** (`broken-link`: link markdown **relativo** apontando para arquivo que
não existe — varre o projeto inteiro, não só `.claude/`) e **encoding** (`no-bom-utf8`: `.ps1`/`.psd1`/`.psm1`
com acento **sem** BOM UTF-8, que o Windows PowerShell 5.1 lê como ANSI e falha no parse do arquivo
inteiro; `bom-antes-do-frontmatter`: `.md` que **começa** com BOM antes do `---`, que faz o parser do
harness ignorar o frontmatter **inteiro** — a `description` vira `"---"` e campos como
`disable-model-invocation` ficam inertes, sem erro nenhum).

> Diferente dos vizinhos: `/status` mostra **estado** (o que existe, em que fase); o `curation-nudge`
> **avisa staleness** reativo; o `/check` **valida** a conformidade a pedido. Não altera nada. Reusa os
> lints `kb-lint`/`agent-lint`/`config-lint`/`sdd-lint`/`link-lint` (não reimplementa parsing). Seção sem alvo (ex.: KB vazia)
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

`Get-ProjectCheckReport` monta as 6 seções (cada uma **fail-safe**): **kb** (`Get-KbInventory` +
`Invoke-KbLint` sobre `.claude/kb`), **agent** (`Invoke-AgentLint` sobre `.claude/agents`), **config**
(`Invoke-ConfigLint` sobre `.claude/settings*.json`), **sdd** (`Invoke-SddLint` sobre
`.claude/sdd/{reports,archive}`), **link** (`Get-LinkLintTarget` + `Get-LinkLintFindings` sobre todo
`.md` do projeto — sem o gitignored e sem `.claude/sdd/archive/`) e **encoding**
(`Get-EncodingLintTarget` + `Get-EncodingFindings` sobre os `.ps1`/`.psd1`/`.psm1`/`.md` que o git
reconhece como seus). `Get-CheckVerdict` (pura) agrega as severidades e
`Format-ProjectCheckReport` imprime o painel determinístico (seção · status · contagem error/warn ·
detalhe · veredito).

**Próximo passo do veredito:** `issues` → corrija os `error` antes de confiar na curadoria (KB malformada
→ revisar/`/reflect`; agente com dangling → ajustar `connects_to`; config malformada → corrigir o JSON;
`orphan-build-report` → mova o relatório para `.claude/sdd/archive/<FEATURE>/`, como manda o passo 3 do
`/ship`; `build-report-sem-mapa`/`-mapa-vazio` → declare no BUILD_REPORT o que o código aceita e você
não executou (ou `Nenhuma — <o que sustenta>`); é dela que a revisão parte; `broken-link` → conserte o caminho relativo ou o arquivo que sumiu, no arquivo e linha
apontados; `no-bom-utf8`/`bom-antes-do-frontmatter` → **este é o único que tem correção automática**:
`pwsh <tools>/encoding-lint.ps1 -Fix` conserta os `no-bom-utf8` prefixando os 3 bytes do BOM, sem
decodificar nem normalizar EOL, e **recusa** arquivo cujos bytes não sejam UTF-8 válido. Rode você
mesmo — o `/check` é **read-only por contrato** e não escreve em arquivo. O
`bom-antes-do-frontmatter` é o caso inverso e não é coberto pelo `-Fix`: **remova** o BOM regravando
o `.md` como UTF-8 **sem** BOM).
`warnings` → revisão opcional (advisory). `ok` → seguir.

> **`encoding : n/a` quer dizer "não olhei", não "está limpo".** A seção enumera por `git ls-files`,
> então num projeto **sem git** ela não tem como saber o que é seu e devolve `n/a` de propósito — em
> vez de imprimir `ok` sobre um conjunto vazio. Se você quer o gate, rode `git init` (ou
> `New-SddProject … -Git`); enquanto não rodar, esses dois defeitos passam sem ninguém olhando.

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
- **SDD:** para cada `.claude/sdd/reports/BUILD_REPORT_<F>*.md`, veja se existe
  `.claude/sdd/archive/<F>/SHIPPED_*.md` — se existir, o relatório é **órfão** (devia ter sido movido
  pelo passo 3 do `/ship`).
- **Links:** nos `.md` que você editou, confira os links **relativos** — texto entre colchetes
  seguido de um caminho `.md` entre parênteses. Resolva o caminho a partir do arquivo de origem e
  veja se o alvo existe. Ignore `http(s)`, âncoras puras (`#secao`) e placeholders (`<FEATURE>`).
  *(A sintaxe não é escrita aqui de propósito: o `link-lint` lê o texto cru e um exemplo literal
  viraria um link quebrado de verdade — ele me pegou fazendo exatamente isso.)*
- **Encoding:** só os **3 primeiros bytes** de cada arquivo, e a resposta certa é oposta por formato.
  Em `.ps1`/`.psd1`/`.psm1` **com acento**, o BOM (`EF BB BF`) é **obrigatório** — sem ele o Windows
  PowerShell 5.1 lê o arquivo como ANSI e o parse falha inteiro. Em `.md` **com frontmatter**, o BOM
  é **fatal** — o parser exige `---` no byte 0 e o BOM ocupa os três primeiros, então o frontmatter
  é ignorado em silêncio. Sem `pwsh`, o teste manual é ler os bytes, não o texto: um editor que
  mostra o arquivo "normal" não distingue os dois casos.

---

## Regras

- **Read-only:** `/check` nunca escreve nem normaliza estado — só lê, valida e apresenta.
- **Reuso, não reimplementação:** os achados vêm de `Get-KbInventory`/`Invoke-KbLint`/`Invoke-AgentLint`/
  `Invoke-ConfigLint`/`Invoke-SddLint`/`Get-EncodingFindings`; não reparseie frontmatter/JSON à mão
  (exceto na degradação consciente do Passo 2).
- **Seção sem alvo → n/a**, nunca falha — projeto recém-criado (KB vazia) não "reprova". E **`n/a`
  não é aprovação**: em `encoding`, `n/a` significa que a seção não teve como enumerar (sem git), e
  o painel prefere dizer isso a imprimir `ok` sobre um conjunto vazio.
- **Detecção sim, correção não:** o `encoding-lint` tem um `-Fix` que **escreve em arquivo**, e por
  isso ele fica **fora** do `/check` — o command é read-only por contrato. O `-Fix` aparece só como
  próximo passo do veredito, para você rodar.
- **Não corrige** — `/check` é diagnóstico; corrigir vai por `/reflect`/`/train-kb`/edição manual.
- Mostra **caminhos e regras** dos achados, nunca o **conteúdo** de `settings.json`.

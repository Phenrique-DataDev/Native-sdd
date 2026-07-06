---
description: "Painel read-only do projeto — estado atual e próxima ação recomendada (ritual de início de sessão)"
---

# /status — painel do projeto (começar o dia / onde estamos)

Mostra, **read-only**, um quadro do estado atual do projeto e **recomenda a próxima ação** — serve como
ritual de início de sessão. Seções: **git** (branch/sujidade/sync/último commit), **curadoria**,
**fase SDD em andamento**, **`inbox/` pendente**, **peers** (outras sessões ativas no projeto — H10),
**memória** (coerência da KB + auto-memória do Claude), **staleness da curadoria** e **▶ próximo passo
recomendado**. Pull on-demand — diferente do `curation-nudge` (reativo, só staleness).

> Não altera nada. Reusa `Get-CurationStatus` (curadoria) e o `curation-nudge` (staleness); adiciona
> leituras read-only de git, fase SDD, inbox e memória, e deriva o próximo passo do estado agregado.

---

## Uso

```text
/status     # imprime o painel
```

---

## Passo 1 — Resolver a camada `tools/` e gerar o report

```powershell
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
if ($toolsRoot) {
    . "$toolsRoot/status.ps1"
    # -SelfId = id desta sessão (do anúncio do peer-heartbeat no SessionStart, "sua sessão é '<id>'");
    # omita se não o tiver → a seção de peers lista todos os ativos sem marcar a própria.
    Format-StatusReport (Get-StatusReport -Root . -SelfId '<session_id desta sessão, se conhecido>')
}
```

`Get-StatusReport` agrega as seções (cada uma fail-safe): **git** (`Get-GitContext`), **curadoria**
(`Get-CurationStatus`, reuso), **fase SDD** (`Get-SddFeatureStatus` — in-flight = sem `SHIPPED`),
**inbox** (`Get-InboxItems`), **peers** (`Get-PeerInventory` — sessões ativas no board, **só leitura**:
não poda stale), **memória** (`Get-MemoryStatus` — KB via `Get-KbInventory` + ponteiros do
`MEMORY.md`) e **staleness** (`Get-CurationStaleness`, reusa o hook `curation-nudge`). Por fim
`Get-NextStep` (pura) deriva o **próximo passo** do estado agregado. `Format-StatusReport` imprime o
painel determinístico.

**Próximo passo — prioridade:** projeto não inicializado → `/setup` · curadoria incompleta → comando da
etapa · feature aberta → próxima fase da mais adiantada (`/define`→`/design`→`/build`→`/ship`) · `inbox/`
com itens → `/brainstorm` (ou `/dev`) · staleness → comando do sinal · tudo em dia → `/brainstorm`.

---

## Passo 2 — Degradação consciente

Se `$toolsRoot` **não resolver** (sem `tools/` relativo nem `$env:SDD_WORKFLOW_HOME`), **avise** que a
camada determinística está indisponível e monte um quadro **à mão** a partir do que dá para ler
direto — **sem inventar** e sem reimplementar a varredura em silêncio:

- **Curadoria:** `.claude/rules/project-context.md` (`status: active`?), `.claude/kb/_index.yaml`
  (domínios/entradas), `.claude/agents/` (agentes de domínio).
- **Fase SDD:** `.claude/sdd/features/` (`BRAINSTORM_`/`DEFINE_`/`DESIGN_`), `reports/BUILD_REPORT_`,
  `archive/<feature>/SHIPPED_` — in-flight = sem `SHIPPED`.
- **Inbox:** arquivos em `inbox/` (exceto `_ABOUT.md`).
- **Git:** `git status --porcelain` / `git log -1` à mão (read-only) — pule a seção se não houver git.
- **Memória:** existência dos arquivos `.claude/kb/` e dos ponteiros do `MEMORY.md` (se houver um repo-local).

---

## Regras

- **Read-only:** `/status` nunca escreve nem normaliza estado — só lê e apresenta (git incluso: só consulta).
- **Reuso, não reimplementação:** curadoria vem de `Get-CurationStatus`, staleness do `curation-nudge`,
  KB de `Get-KbInventory`; não reparseie frontmatter nem reimplemente os sinais.
- **Projeto não inicializado** (`project-context` template) → o painel já indica "rode `/setup`".
- **Memória é portável e fail-safe:** valida só o que existe no projeto (KB e `MEMORY.md` repo-local);
  some em silêncio quando ausente — não inventa estado.
- Mostra **nomes** dos itens de `inbox/`, nunca o conteúdo (evita vazar dado que chegou).

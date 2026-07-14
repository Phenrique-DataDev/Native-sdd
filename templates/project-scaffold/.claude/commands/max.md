---
description: "Modo de operação máxima — usa a metodologia no máximo (Workflow de escala, arsenal, contexto/KB, potência, orquestrador-hub) mantendo todos os guardas"
---

# /max — modo de operação máxima (H6 · v2/H7)

> Liga um modo de sessão que usa a metodologia **no máximo**: lê todo o contexto, **recomenda**
> potência, aciona o **orquestrador-mestre** e **reduz a fricção do não-crítico** — **mantendo todos os
> guardas** e a verificação de qualidade. **v2 (H7):** usa o **Workflow nativo** p/ fan-out de escala
> (só não-mutador/não-outward), **aciona o arsenal seguro** (auto-fire só bounded/local; outward confirma),
> **aterra o trabalho na KB** e opera como **hub** do grafo. Aplica a regra [`max-mode.md`](../postures/max-mode.md).
> Estado + aviso + ledger em `tools/max.ps1`. **Permissão-só, guardas mantidos**; sem engine (orquestração =
> `Agent`/`Workflow` nativo). Freio de custo = `budget` **nativo** do Workflow (do usuário); o MAX **não inventa quota**.

## Quando usar

- Manualmente, antes de um bloco de trabalho **denso/autônomo** (refactor amplo, feature inteira,
  investigação cruzando muitos arquivos) em que você quer potência total e poucos prompts no trivial.
- Como base do **orquestrador-mestre / hub**: o MAX é o nó central que delega a experts via `/orchestrate`.

## `/max` — ligar

**Passo 0 — carregar a postura (OBRIGATÓRIO, antes de tudo).**

A postura do MAX **não está no contexto** desta sessão: ela vive em
[`.claude/postures/max-mode.md`](../postures/max-mode.md), **fora** de `.claude/rules/`, justamente
para não cobrar ~8k tokens de **toda** sessão que nunca liga o MAX. Ela só entra no contexto **agora**,
porque você a está pedindo.

1. **Leia** `.claude/postures/max-mode.md` (ferramenta `Read`) — **antes** do bootstrap, antes de ligar
   o flag, antes de qualquer outra coisa. É a fronteira (b)/(c), o contrato de hub e as classes de
   risco: sem ela você não sabe o que o MAX pode e o que não pode.
2. **Leia** `.claude/postures/agent-routing-advanced.md` — o grafo unificado, o contrato de hub e o
   gatilho `ultracode`, que o MAX usa para orquestrar.

> **Se qualquer um dos dois arquivos não existir ou não puder ser lido: ABORTE.** Diga qual arquivo
> faltou e **não ligue o modo** — nem "parcialmente", nem "com o que dá". Um MAX sem a postura é um MAX
> sem a fronteira mutador/outward: ele acha que pode auto-emitir Workflow, auto-fire de skill e operar
> como hub, **sem** as regras que dizem onde isso para. Degradar em silêncio aqui é pior do que não
> ligar o MAX. **Falhe alto.**

**Passo 1 — bootstrap de contexto ("ler tudo").** Resolva `$toolsRoot` pela cascata
([`tooling.md`](../rules/tooling.md): relativo → `$env:SDD_WORKFLOW_HOME` → degradação) e reúse os
**inventários existentes** — não reimplemente varredura. O orçamento G8 fica **silenciado** (não exiba o painel):
```powershell
# $toolsRoot resolvido pela cascata (rules/tooling.md)
. "$toolsRoot/status.ps1"
$ctx = Get-StatusReport -Root (Get-Location).Path   # reusa Get-CurationStatus + KB/skills/inbox/memória
Format-StatusReport -Report $ctx                     # panorama do "arsenal" do projeto
```
Complemente lendo o que orienta o trabalho: `.claude/kb/_index.yaml` (domínios da KB), skills
disponíveis, MCPs ativos e hooks instalados. Sem `$toolsRoot` → **degradação consciente**: avise e siga
só com a postura (sem o bootstrap determinístico).

**Passo 2 — ligar o flag e avisar.**
```powershell
. "$toolsRoot/max.ps1"
Enable-MaxMode -StateDir '.claude/.cache' -SessionId <id da sessão, se disponível> | Out-Null
Format-MaxNotice -State (Get-MaxState -StateDir '.claude/.cache') `
                 -Classes (Get-NonCriticalClasses) -ContextSummary '<resumo do Passo 1>' `
                 -NativeBudget '<diretiva de budget do usuário, ex.: 500k, ou vazio>'
```
**Emita o aviso** (obrigatório): o que foi reduzido (prompts do **não-crítico** via modo `auto`),
**potência recomendada**, contexto carregado, **GUARDAS ATIVOS** (main/secret/destructive/managed), e o
v2 — **workflows de escala autorizados**, **outward confirma a cada uso**, **budget nativo vigente** e
**como abortar**.

**Passo 3 — operar no máximo (postura `max-mode.md`).**
- **Potência:** para tasks densas, **recomende** modelo maior + `effort` alto — **não troque o modelo à
  força** (segue `model: inherit`/B9; a troca é da sessão/por-invocação).
- **Hub + KB:** aja como **hub** do grafo — consulte `role`/`connects_to` ([`agent-routing.md`](../rules/agent-routing.md))
  p/ escolher/encadear experts; ao montar o pacote de uma task, **puxe a KB do domínio**
  (`operations`+`implementation`, reusa `Build-KbIndex`) — aterra o subagente, não improvisa.
- **Escala (Workflow × `/orchestrate`):** poucas tasks sequenciais-com-gate → **`/orchestrate`**; **fan-out
  de N itens / pipeline / escala** → **emitir Workflow nativo** (passe um `budget` nativo se o usuário o
  declarou). O Workflow auto-emitido é **só não-mutador/não-outward** (mutador/`ask`/outward fica no loop
  principal — ver `max-mode.md` (b)).
- **Arsenal:** **auto-fire** só do bounded/local (`context7`, leitura local, `visual-explainer`); **outward**
  (deep-research/browser/publicar) **confirma a cada uso**.
- **Ledger:** registre cada auto-disparo p/ auditabilidade:
  ```powershell
  Add-MaxDispatch -StateDir '.claude/.cache' -Kind 'workflow' -Label '<objetivo>'   # ou -Kind 'skill'
  ```
- **Fricção:** não interrompa o usuário no **não-crítico** (leitura/busca/navegação) — o modo `auto` da
  sessão já auto-aprova; **respeite** os guardas e os prompts do **crítico**.

## `/max off` — desligar

```powershell
. "$toolsRoot/max.ps1"
Disable-MaxMode -StateDir '.claude/.cache' | Out-Null
```
Confirme "modo MAX desligado"; a postura cessa e o fluxo volta ao normal.

## `/max status` — consultar (opcional)

```powershell
. "$toolsRoot/max.ps1"
Get-MaxState -StateDir '.claude/.cache'        # Enabled/StartedAt/ExpiresAt/Reason (fail-closed)
Get-MaxDispatches -StateDir '.claude/.cache'   # o que o MAX disparou na sessão (ledger; @() se nada)
```

## Regras

- **Nunca** use `bypassPermissions`/`--dangerously-skip-permissions`, nem edite `hooks`/settings/
  `permissions` — carregam no boot (sem efeito em runtime) e mexeriam nos guardas.
- **Nunca** relaxe um guarda de segurança nem pule um gate de qualidade ou **fase SDD** — o MAX acelera,
  não baixa a régua.
- **Nunca** auto-emita Workflow **mutador/outward** em background (fica no loop principal); **nunca**
  auto-fire skill **outward** (deep-research/browser/publicar) sem confirmar; **nunca** declare/invente
  **quota** de orçamento (o freio é o `budget` nativo do Workflow, do usuário).
- O flag é **session-bound + TTL + fail-closed**: não persiste entre sessões; corrupção/staleness ⇒
  desligado. O enforcement da postura é **conversacional** — o flag é auxiliar (`/max status`/telemetria).

---
description: "Modo de operação máxima — usa a metodologia no máximo (contexto, potência, orquestrador) mantendo todos os guardas"
---

# /max — modo de operação máxima (H6)

> Liga um modo de sessão que usa a metodologia **no máximo**: lê todo o contexto, **recomenda**
> potência, aciona o **orquestrador-mestre** e **reduz a fricção do não-crítico** — **mantendo todos os
> guardas** e a verificação de qualidade. Aplica a regra [`max-mode.md`](../rules/max-mode.md). Estado +
> aviso em `tools/max.ps1`. **Permissão-só, guardas mantidos**; sem engine (orquestração = `Agent` nativo).

## Quando usar

- Manualmente, antes de um bloco de trabalho **denso/autônomo** (refactor amplo, feature inteira,
  investigação cruzando muitos arquivos) em que você quer potência total e poucos prompts no trivial.
- Como base do **orquestrador-mestre / hub**: o MAX é o nó central que delega a experts via `/orchestrate`.

## `/max` — ligar

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
                 -Classes (Get-NonCriticalClasses) -ContextSummary '<resumo do Passo 1>'
```
**Emita o aviso** (obrigatório): o que foi reduzido (prompts do **não-crítico** via modo `auto`),
**potência recomendada**, contexto carregado e **GUARDAS ATIVOS** (main/secret/destructive/managed).

**Passo 3 — operar no máximo (postura `max-mode.md`).**
- **Potência:** para tasks densas, **recomende** modelo maior + `effort` alto — **não troque o modelo à
  força** (segue `model: inherit`/B9; a troca é da sessão/por-invocação).
- **Orquestração:** para objetivo **decomponível**, delegue via **`/orchestrate`** (decompõe em tasks com
  `deps`, paraleliza independentes, valida cada uma num gate). Aja como **hub**: consulte `role`/
  `connects_to` ([`agent-routing.md`](../rules/agent-routing.md)) para escolher/encadear os experts.
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
Get-MaxState -StateDir '.claude/.cache'   # Enabled/StartedAt/ExpiresAt/Reason (fail-closed)
```

## Regras

- **Nunca** use `bypassPermissions`/`--dangerously-skip-permissions`, nem edite `hooks`/settings/
  `permissions` — carregam no boot (sem efeito em runtime) e mexeriam nos guardas.
- **Nunca** relaxe um guarda de segurança nem pule um gate de qualidade ou **fase SDD** — o MAX acelera,
  não baixa a régua.
- O flag é **session-bound + TTL + fail-closed**: não persiste entre sessões; corrupção/staleness ⇒
  desligado. O enforcement da postura é **conversacional** — o flag é auxiliar (`/max status`/telemetria).

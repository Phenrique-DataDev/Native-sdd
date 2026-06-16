# Modo MAX — operação máxima sob demanda (postura, opt-in)

> Modo de sessão que usa a metodologia **no máximo**: lê todo o contexto, **recomenda** potência,
> aciona o **orquestrador-mestre** e **reduz a fricção do não-crítico** — **sem ir contra a espinha**.
> É **permissão-só, guardas mantidos**: nunca relaxa um guarda de segurança nem a verificação de
> qualidade. Acionado por **`/max`**; cessa em **`/max off`**. Sem engine — orquestração é `Agent`
> nativo (`[[orchestration]]`); potência é a política de modelo (`[[agent-routing]]`/B9).

## Princípio

Num trabalho denso, ligar potência/contexto à mão e ser interrompido por prompts de ações **triviais**
custa fluxo. O MAX compõe o que já existe (orquestração + modelo/effort + inventários de contexto) num
**preset declarativo**: quando ligado, o agente opera no máximo **e** mantém **todas** as defesas. A
autonomia vem de *menos prompts no não-crítico + orquestração*, **não** de *desligar guardas*.

**Decisão de mecanismo (D-001, via context7):** hooks e settings carregam **no início da sessão**;
editar em runtime **não** afeta a sessão corrente. Por isso o MAX **não** escreve `permissions`/settings/
hooks. A redução de fricção do não-crítico vem do **modo de permissão `auto` da sessão** (default) + esta
postura; os guardas já estão carregados e **intocados** → seguem interceptando o crítico (`deny`>`ask`>`allow`).

## O MAX eleva × o MAX nunca toca

| Eleva (quando ligado) | Nunca toca |
|-----------------------|------------|
| **Contexto** — lê tudo (KB/memória/skills/MCPs/hooks); orçamento G8 silenciado | **Guardas** de segurança (main-push / secret / destructive / managed `deny`) |
| **Orquestração** — aciona `/orchestrate` p/ objetivo decomponível (paralelo co-dep/indep) | **Verificação de qualidade** (testes/lint/gates SDD; **fases** SDD) |
| **Potência** — **recomenda** modelo maior + `effort` alto | O **modelo** à força — segue `model: inherit` (B9); a troca é da sessão |
| **Fricção** — menos prompts no **não-crítico** (via modo `auto`) | settings / hooks / `permissions`; **`bypassPermissions`** |

## Classes não-críticas × sempre-crítico

| Não-crítico (não interromper) | Sempre crítico (respeita guarda/prompt) |
|-------------------------------|------------------------------------------|
| `Read`, `Grep`, `Glob`, `LS`, navegação | escrita/edição destrutiva; `git push`/`merge` |
| `Bash` read-only (`ls`, `cat`, `rg`, `git status`/`diff`/`log`, `gh … list`/`view`) | leitura de segredo (`.env`, `secrets/**`); `rm -rf`; `chmod -R`/`chown -R` |
| | CLIs de dados/cloud destrutivas (`DROP`/`TRUNCATE`, `aws s3 rm`, `terraform destroy`) |

> A lista é a referência da postura (e do aviso) — **não** é escrita em `permissions`. A decisão real de
> cada ação ainda passa pelo modo `auto` + os hooks, que **vencem** o auto-aprovar.

## Como aplicar

1. **Ligar (`/max`):** roda o **bootstrap de contexto** (reusa `/status`/inventários; G8 silenciado),
   grava o flag de sessão e emite o **aviso obrigatório** (o que foi reduzido + potência recomendada +
   contexto carregado + **guardas ativos**).
2. **Durante:** recomende modelo/effort para tasks densas (não troque à força); delegue objetivo
   decomponível via **`/orchestrate`**; aja como **hub** (consulte `role`/`connects_to` para escolher/
   encadear experts); **não** interrompa no não-crítico; respeite guardas e prompts críticos.
3. **Desligar (`/max off`):** limpa o flag; a postura cessa, volta ao fluxo normal.

## O que NÃO fazer

- **Não** usar `bypassPermissions`/`--dangerously-skip-permissions` (pula hooks; pode estar `disable`d).
- **Não** editar `hooks`/settings/`permissions` (carregam no boot — sem efeito em runtime — e mexeria nos guardas).
- **Não** relaxar **nenhum** guarda de segurança (main-push / secret / destructive / managed).
- **Não** pular gate de qualidade ou **fase SDD** — o MAX acelera, não baixa a régua.
- **Não** trocar o **modelo à força** — potência é **recomendação** (B9 `inherit`).
- **Não** persistir o modo entre sessões (flag é session-bound + TTL; fail-closed).
- **Não** construir engine/daemon — orquestração é `Agent` nativo.

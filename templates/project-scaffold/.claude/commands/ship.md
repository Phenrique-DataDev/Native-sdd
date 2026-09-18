---
description: "Fase 4 SDD — encerrar feature, arquivar e registrar lições"
argument-hint: "<FEATURE>"
---

# /ship — Fase 4 (Ship)

Fechar a feature `$ARGUMENTS`: arquivar artefatos e capturar aprendizado.

## Pré-condição
O `BUILD_REPORT` da feature deve estar **completo e verificado** (status ✅). Se não
estiver, volte ao `/build`.

## Faça
1. Leia o template `.claude/sdd/templates/SHIPPED_TEMPLATE.md`.
2. Gere `.claude/sdd/archive/<FEATURE>/SHIPPED_<YYYY-MM-DD>.md` com:
   - Resumo, timeline e métricas
   - O que foi construído (componentes + arquivos)
   - **Verificação dos Success Criteria** do DEFINE (atingidos? evidência)
   - **Lições aprendidas** (processo, técnico, ferramentas) — **marque** cada lição `[candidata]`
     (prática reaplicável, recorrente) ou `[pontual]` (one-off). É o insumo do `/learn` (G7), que
     promove o recorrente a uma entrada de KB `operations`. Aditivo (lições sem marca seguem válidas).
   - Recomendações para trabalho futuro
3. **MOVA os artefatos para `.claude/sdd/archive/<FEATURE>/`** — todos, sem exceção:
   `features/{BRAINSTORM,DEFINE,DESIGN}_<FEATURE>.md` e **todos** os
   `reports/BUILD_REPORT_<FEATURE>*.md`. Mover, não "apontar": o que fica em `reports/` é lido
   como **build em andamento**, e o `/status` passa a listar como aberta uma feature encerrada.
   - **Entrega em levas?** Uma feature com N relatórios (`BUILD_REPORT_<FEATURE>.md`,
     `BUILD_REPORT_<FEATURE>_LEVA2.md`, …) mantém **todos** lado a lado no **mesmo**
     `archive/<FEATURE>/` — o **diretório** é a identidade da feature, os nomes de arquivo são
     livres. Não invente sufixo, não renomeie para caber, não crie frontmatter novo.
   - **Verifique depois de mover:** `reports/` não pode ter nenhum `BUILD_REPORT_<FEATURE>*`
     sobrando. O `sdd-lint` (`orphan-build-report`, roda no `/check`) reprova se sobrar.
4. **Bump de versão** (se o projeto versiona — há `VERSION`/`CHANGELOG.md`): incremente o **patch**
   (`0.6.1`→`0.6.2`) por feature shipada, ou o **minor** ao fechar um EPIC; atualize `VERSION` +
   `CHANGELOG.md` e crie a **tag** git (`vX.Y.Z`) no merge. Sem `VERSION`, pule este passo.
5. **Catálogo do archive:** `archive/` acabou de ganhar o `SHIPPED_*.md` novo, então o
   `.claude/sdd/archive/_index.md` ficou stale. O passo 6 pega isso no `Invoke-Resync -Check` e o
   regenera junto com os demais. O que cabe aqui é **escrever bem o Resumo do SHIPPED**, a frase que
   responde *"o que esta feature resolveu?"*: é ela que vira a linha do catálogo que a busca por
   significado lê (ver [`semantic-search.md`](../rules/semantic-search.md)).
6. **Reindexar o que a feature mexeu — o gancho de curadoria.** Uma feature costuma adicionar
   command, rule ou agente, e é aí que os índices derivados (`AGENT_MAP.md`, `graph.json`, a lista de
   rules do `AGENTS.md`, a tabela de commands do `CLAUDE.md`) ficam **stale**. Cheque **antes** de
   agir — resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md):

   ```powershell
   . "$toolsRoot/resync.ps1"
   $sync = Invoke-Resync -Check    # a FONTE ÚNICA de "gerado × disco"; não reimplemente a comparação
   ```

   - **Tudo `InSync`** → **silêncio**, siga para o passo 7. Não anuncie o que não fez.
   - **Há drift** → **anuncie o que vai rodar e por quê**, e dispare você mesmo:
     `Skill(skill: "sync-context")`. Não peça ao usuário para digitar — você pode invocá-lo (ver
     [`CLAUDE.md`](../../CLAUDE.md) §*Você PODE disparar os commands*).

   > **Por que aqui é ponto seguro, e por que isso não vale para tudo.** O `/sync-context` só
   > **regenera derivados** (idempotente, não-destrutivo): rodar duas vezes dá o mesmo resultado e
   > nada de curado se perde. Já `/learn`, `/reflect` e `/simulate` **continuam pull-only** — eles
   > decidem o que entra ou sai da KB, e essa decisão é do humano. *Poder invocar não é pular etapa;
   > o que muda aqui é só quem digita o comando que já era para rodar.*
7. Resuma para o usuário e proponha o merge da branch (com confirmação, pois `main` é
   protegida).

## Regra
- Só escreva o SHIPPED depois de confirmar que os Success Criteria foram de fato atingidos.

## Racionalizações comuns

| Desculpa | Realidade |
|----------|-----------|
| "O BUILD_REPORT está quase ✅, já posso arquivar" | Ship só depois do ✅ verificado. Arquivar build incompleto enterra dívida. |
| "Os Success Criteria 'claramente' foram atingidos" | Só escreva o SHIPPED com evidência de cada critério — não com a sensação de que bateu. |
| "Pulo as lições aprendidas, não houve nada de novo" | A seção é barata e é o que alimenta o próximo ciclo. "Nada novo" também é uma lição — registre. |
| "O BUILD_REPORT pode ficar em `reports/`, eu aponto para ele no SHIPPED" | Não pode. `reports/` significa **build em andamento** — deixar o arquivo lá faz o `/status` anunciar como aberta uma feature encerrada e sugerir `/ship` de novo. Mover é o passo, não uma preferência de organização. |
| "São 2 relatórios (entrega em levas), não cabe um por feature no archive" | Cabe: `archive/<FEATURE>/` aceita **N** relatórios lado a lado. O diretório é a identidade — não renomeie nem invente sufixo para "caber". |
| "Peço ao usuário para rodar `/sync-context` depois" | Você **pode** disparar (`Skill`) e o comando é idempotente/não-destrutivo. Pedir ao humano o que você mesmo executa é como o índice fica stale — e como o agente vira um formulário. |

## O que NÃO fazer

- Escrever o SHIPPED com o BUILD_REPORT em 🔄/❌.
- Deixar qualquer `BUILD_REPORT_<FEATURE>*` em `reports/` depois de arquivar (passo 3) — é o que
  faz o `/status` mentir; o `sdd-lint` acusa `orphan-build-report`.
- Afirmar Success Criteria atingidos sem evidência.
- Mergear na `main` sem confirmação explícita (`main` é protegida).
- Disparar `/sync-context` **sem checar** o drift antes (vira ruído) ou **sem anunciar** (o usuário
  tem de saber o que rodou no repositório dele).
- Estender este gancho a `/learn`, `/reflect` ou `/simulate` — **eles seguem pull-only**: decidem o
  que entra/sai da KB, e essa decisão é humana.

## Telemetria (opcional, não bloqueia)
Ao fechar a fase, registre as iterações de re-trabalho (piloto B6 — consolidado em `/telemetry`):
`. "$toolsRoot/telemetry.ps1"; Add-PhaseIteration -Path .claude/sdd/telemetry.jsonl -Phase ship -Feature <FEATURE> -Iterations <n>` — resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md)

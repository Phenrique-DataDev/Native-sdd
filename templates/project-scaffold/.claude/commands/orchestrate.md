---
description: "Líder/orquestrador — decompõe um objetivo em tasks, delega a subagentes via Agent nativo e valida cada resultado"
---

# /orchestrate — líder/orquestrador (handoff a subagentes com validação)

Dado um **objetivo** (ou um **plano aprovado**), o líder o decompõe em tasks, dá contexto a
subagentes via **`Agent` nativo**, **valida** cada resultado contra um gate e encadeia/paraleliza —
com estado **resumível**. Sem engine: `invocar/aguardar/paralelizar/resume` é o nativo.

> Feature **H2** (EPIC H — multi-agente & orquestração). O protocolo do líder vive na regra
> sempre-ativa [`orchestration.md`](../rules/orchestration.md); este comando o **aciona**. O gate e o
> estado são funções puras em `tools/orchestrate.ps1` (molde do `/init`, G1).

---


## Passo 0 — Carregar o protocolo

**Leia** `.claude/postures/orchestration.md` (ferramenta `Read`) **antes** de decompor ou delegar
qualquer coisa. É onde vivem o ciclo do líder, o gate de validação, o checkpoint humano, o
paralelismo, o schema do STATE e o destino (subagente × chat externo). A rule
[`rules/orchestration.md`](../rules/orchestration.md) guarda só o **gatilho** e os invariantes — o
protocolo saiu do always-on para não custar ~5 200 tokens em toda sessão que não orquestra.

**Se a postura não existir, aborte** e diga isso: sem ela você estaria improvisando um protocolo que
já está escrito (molde do `/max`, Passo 0).

## Uso

```text
/orchestrate <objetivo>              # decompor → conduzir (invocar+validar+encadear) → estado resumível
/orchestrate --plan-only <objetivo>  # só decompor + relatório do estado (NÃO invoca Agent), read-only
```

---

## Passo 0 — Carregar o roteamento avançado (sob demanda)

O **grafo unificado** (`:USES_SKILL`/`:PRESUPPOSES`/`:IN_DOMAIN`) e o **contrato de hub** não estão no
contexto: vivem em [`.claude/postures/agent-routing-advanced.md`](../postures/agent-routing-advanced.md),
**fora** do always-on (custam 0 token em sessões que nunca orquestram). **Leia esse arquivo agora** —
é o que permite montar o pacote de contexto com o **expert + skill + KB certos** do domínio, em vez de
improvisar.

> Ausente/ilegível? **Avise** e siga com o núcleo (`rules/agent-routing.md` — catálogo de experts e
> política de modelo, sempre no ar): o roteamento **básico** não depende do avançado. Degradação
> **consciente e anunciada**, nunca silenciosa.

## Passo 1 — Medir o regime ANTES de decompor

O ciclo completo é o caso caro. Rode o predicado observável e **diga o `Mode` ao usuário**:

```powershell
# $toolsRoot pela cascata (rules/tooling.md)
. "$toolsRoot/orchestrate.ps1"
$mode = Get-OrchestrationMode -Disciplines @('code','data') -FitsSingleContext $false
"$($mode.Mode) — $($mode.Reason)"
```

- **`solo`** → **pare aqui.** Diga que não há fronteira material, mostre a `Reason` e faça/delegue
  direto (`agent-routing.md`). Orquestrar aqui custa sem comprar — medido em `ORCHESTRATE_BASELINE`.
- **`minimo`** (e os sufixos `+worktree`/`+checkpoint`) → siga a §*Modo mínimo* da postura (executor
  + 1 revisor). **Não** decomponha em N tasks — os sufixos adicionam um **mecanismo**, não um STATE.
- **`completo`** → siga para o Passo 2.

Os sinais são seus de observar, não de supor: `-Disciplines` sobre domínios distintos,
`-IsolationRequired` sobre escrita concorrente, `-OutwardAction` sobre publicar/enviar/deploy.
**Se você não consegue afirmar um sinal, não o invente — pergunte.**

> **`-FitsSingleContext` não é sobre volume — é sobre irredutibilidade.** Antes de informar `$false`,
> pergunte: **um script resolveria?** Material com estrutura (mesmo formato, vocabulário fechado,
> campo parseável) é **redutível**, e redutível cabe numa **ferramenta**, não num contexto — foi
> medido três vezes e as três vezes o braço solo venceu escrevendo um parser. Marcar `$false` por
> tamanho é o jeito mais caro de errar aqui: é o único sinal que ainda leva ao ciclo `completo`.
>
> **E ele sozinho não basta mais.** `-FitsSingleContext $false` é auto-relato; o `completo` exige
> `-ReductionAttempted $true` — a ferramenta que resolveria o material foi escrita e falhou. Se você
> alegar a fronteira sem o fato, a função devolve o modo barato e a `Reason` diz o que fazer. Não
> reinforme `$false` com mais convicção: escreva o parser.

## Passo 2 — Decompor

Quebre o objetivo/plano aprovado em **tasks** (`id`, `title`, `dod`, `deps`, `model` sugerido,
`method`) e grave o **STATE** em `.claude/sdd/orchestration/STATE_<slug>.yaml` (schema na
`orchestration.md`).

**`method` é o campo que este command não tinha, e ele não é sobre topologia.** Decidir quantos
agentes você já fez no Passo 1, por predicado. `method` diz **como atacar** — e quando a task é
**achar defeito**, prescreva um ataque **executável** (oráculo diferencial, invariante + fuzz,
round-trip), não *"revise com atenção"*: nas medições, todo braço que auditou **por leitura** achou
zero, e os dois únicos acertos vieram de quem construiu um segundo motor. Derivação, limites da
evidência (`n=2`) e o que fazer quando o método exige escrever arquivo: §*Pacote de contexto* da
postura. Task cujo ataque é óbvio pode omitir o campo — ele não tem gate.

**Marque como `type: checkpoint`** todo ponto em que a decisão é do **humano** (escolher entre
abordagens viáveis, autorizar ação outward, aceitar conteúdo) — não o cubra com um critério
automático que não existe. Todo o resto fica `agent` (default, pode omitir). Mostre o painel:

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/orchestrate.ps1"
$status = Get-OrchestrationStatus -StatePath ".claude/sdd/orchestration/STATE_<slug>.yaml"
Format-OrchestrationReport -Status $status
```

Se **`--plan-only`**, **pare aqui** (só o relatório — nada é invocado).

---

## Passo 3 — Conduzir (loop)

Enquanto `NextTask` não for `done`/`blocked`, para cada **`ReadyTask`** (task `agent` com deps todas
`passed`):

> **`NextTask = no-state` → pare e confira o caminho, não o objetivo.** Significa que **nenhuma task
> foi carregada** — STATE inexistente, vazio ou não parseado. Não é fim de orquestração e não se
> resolve decompondo de novo: confira o path (slug, `cwd`, a pasta `orchestration/` existe?) e a
> indentação do bloco `tasks:`. Se o painel também acusar `ATENÇÃO: N linha(s) ... não reconhecida(s)`,
> o STATE carregou parcialmente — há task perdida, e a anterior pode estar com campo sobrescrito.

1. **Pacote de contexto** — artefato da fase (passe o artefato anterior, `workflow-sdd`) + arquivos +
   o **DoD** como critério + o **modelo** sugerido.
2. **Invocar** — `Agent` com `subagent_type`, `prompt` = pacote, `model`. Tasks independentes prontas
   → **várias chamadas `Agent` na mesma mensagem** (paralelo). Para plano grande/independente, emita o
   **handoff externo**: *"plano aprovado, rode em novo chat com Opus 4.8"* (instrução ao humano, não
   chamada de ferramenta).
3. **Persistir — antes de julgar.** Grave o texto que voltou em
   `.claude/sdd/orchestration/out/<task-id>.md`, **bruto e inteiro**, e aponte o caminho no campo
   `output:` da task no STATE. O texto final de um subagente **não está no transcript**: ele chega
   pela notificação da task e morre com a sessão. Se você julgar primeiro e o gate reprovar, a
   re-invocação apaga a única evidência do que o agente respondeu. O painel acusa
   `ATENÇÃO: N task(s) aprovada(s) sem ``output``` — é aviso, não trava a cadeia.

---

## Passo 3b — Checkpoint humano (`AwaitingApproval`)

Cada item de **`$status.AwaitingApproval`** é uma task `type: checkpoint` pronta: **não despache** —
a decisão é do humano.

1. **Pergunte** com `AskUserQuestion`, mostrando o `title`/`dod` do checkpoint e o artefato que ele
   deve julgar. Sessão **não-interativa** → **pare** e informe que a cadeia aguarda aprovação; nunca
   decida no lugar do usuário nem peça a um subagente que "revise e aprove".
2. **Grave a resposta no STATE**, na mesma task: aprovado → `status: passed`; reprovado →
   `status: failed` (a jusante fica `blocked`, e é isso mesmo). Sem gravar, a retomada repergunta.
3. As `ReadyTasks` **que não dependem** do checkpoint continuam sendo despachadas em paralelo — o
   checkpoint só trava a própria subárvore.

`NextTask = awaiting-approval` significa: **nada despachável e há checkpoint esperando** — o loop só
avança pela sua resposta.

---

## Passo 4 — Validar (gate)

Monte o `Result` da task a partir de verificação **real** (testes/lint/conformidade) e, se quiser o
gate semântico, do veredito do **`code-reviewer`** (`ReviewApproved`). A saída bruta já está no disco
(passo 3.3) — julgue a partir dela, não da memória da conversa:

```text
$gate = Test-TaskGate -Result @{ TestsGreen = $true; LintClean = $true; ArtifactConforms = $true; ReviewApproved = $true } `
                      -Required @('TestsGreen','LintClean','ArtifactConforms','ReviewApproved')
```

- **Passou** (`$gate.Passed`) → marque a task `passed` no STATE.
- **Falhou** → **re-invoque** o subagente com `$gate.Failed` como feedback, até `MaxAttempts = 2`;
  esgotado → marque `failed`.

---

## Passo 5 — Encadear / estado

Atualize o STATE e repita do Passo 3. Recalcule `Get-OrchestrationStatus`: dispare as novas
`ReadyTasks` (paralelo), até `NextTask = done` (ou `blocked`, se a cadeia travar). Retomar é
idempotente — tasks `passed` não são refeitas.

---

## Regras

- **Sem engine:** `invocar/aguardar/paralelizar/resume` é o `Agent` nativo — não construa motor.
- **Líder no nível principal:** sem subagente→subagente.
- **Gate read-only e conservador:** critério obrigatório ausente conta como falha; só avança se passa.
- **Checkpoint é do humano:** nunca despache um `type: checkpoint` a subagente, nunca responda por
  ele, e **grave a decisão no STATE** — aprovação que só existiu na conversa some na retomada.
- **`--plan-only` não invoca `Agent`:** read-only, só o relatório.
- **Não inventar resultados:** o `Result` do gate vem de verificação real.
- **Destino:** subagente na sessão por padrão; handoff externo p/ plano grande/independente ou troca de chat.

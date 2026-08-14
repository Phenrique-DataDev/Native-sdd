# Orquestração — quando o líder assume o protocolo

> O **líder não é um engine**: é o **agente principal** seguindo um protocolo. `invocar`, `aguardar`,
> `paralelizar` e `resume` são a ferramenta **`Agent` nativa** — não reimplemente um motor de
> orquestração. O **protocolo completo** (ciclo, gate, checkpoint, paralelismo, schema do STATE) vive
> em [`../postures/orchestration.md`](../postures/orchestration.md), **fora** do always-on.

## Gatilho — o regime vem do predicado, não da vontade de decompor

**Meça antes de decidir.** O regime é saída de uma função pura, não julgamento:

```powershell
# $toolsRoot pela cascata (rules/tooling.md)
. "$toolsRoot/orchestrate.ps1"
Get-OrchestrationMode -Disciplines @('code','data') -FitsSingleContext $false
# -> Mode = solo | minimo | completo   (+ Reason e Signals, auditáveis)
```

| `Mode` | O que fazer | Quando sai |
|--------|-------------|------------|
| **`solo`** | **Não orquestre.** `Agent` direto (ver [`agent-routing.md`](agent-routing.md)) ou faça você. Sem STATE, sem gate. | Nenhuma fronteira observável |
| **`minimo`** | **Executor + 1 revisor fresh-context com checklist** — **~2,4×, opt-in**: diga o preço e **pergunte** antes de pagá-lo. Sem STATE de N tasks. Leia a §Modo mínimo da postura. | ≥2 disciplinas, e o material cabe num contexto |
| **`minimo+checkpoint`** | Idem, **mais** uma parada obrigatória para o humano antes de cada passo que sai da máquina (push, PR, deploy, envio). | Há ação **outward** |
| **`completo`** | **Leia** `.claude/postures/orchestration.md` e rode o ciclo inteiro. | Fronteira de máquina de estado (abaixo) |

**As duas fronteiras de máquina de estado** — cada uma verificável **antes** de decompor, e cada uma
nomeia algo que o modo mínimo **não consegue fazer**: (1) o material **não cabe** no contexto de um
agente; (2) escrita concorrente exige **isolamento** (worktree). Só elas chegam a `completo`.

> **O preço do `minimo` é conhecido, e por isso ele é opt-in.** Medido em seis rodadas: a revisão
> fresh-context **compra qualidade de forma consistente** (R2 +1 check, R5 +2, R6 o único 25/25 de
> todas as rodadas) e custa **~2,4× no piso** — dois agentes, o segundo só reportando — e **~4×** se
> ele também corrigir. Não há como baixar disso: todo agente que faz trabalho real custa 40k–55k
> tokens só para ler o contrato, entender o artefato e validar. Três tentativas de chegar a 2,0×
> falharam (3,2× · 3,06× · 4,34×); o alvo exigia que revisar custasse menos que executar, e revisão
> que compra check custa aproximadamente o mesmo que executar.
>
> Então o predicado devolver `minimo` significa **"há revisão a fazer"**, não "pague por ela agora".
> **Diga o número e deixe a escolha com quem paga.** O default sem resposta é `solo`.
>
> **E o custo da revisão não é o custo do revisor.** Na rodada 6 o revisor custou 54.624 e o *fix*
> 78.728 — revisão que acha mais gera correção maior. É trabalho real, não desperdício, mas quem
> decide precisa ver a conta inteira antes de dizer sim.

> **Ação outward saiu daqui** (campo 01, 2026-08-11). Ela exige **uma** coisa — a parada para o
> humano — e parada é barata; STATE de N tasks é caro. Acoplar os dois repetia a forma da fronteira
> de disciplina que a rodada 2 já tinha derrubado. Observado em uso real: um trabalho que terminou
> em push, PR e merge num repositório público — outward inequívoco — eram 53 linhas, nenhuma de
> código. Rodou como `minimo` com duas paradas humanas e entregou.

> **Contar disciplinas não é fronteira** — foi medido e reprovou. Rodada 2 do `ORCHESTRATE_BASELINE`
> (2026-08-11), carga de 3 disciplinas (code/data/doc): o ciclo **completo** (6 agentes, 363k tok) e o
> **modo mínimo** (3 agentes, 167k tok) marcaram o **mesmo 24/25** no juiz cego. As três tasks extras
> não compraram um único check. Disciplina é sinal de que **há revisão a fazer** — não de que há
> trabalho que não cabe.

| Outros sinais | O que fazer |
|-------|-------------|
| **`/orchestrate <objetivo>`** | O command já carrega a postura. Siga-o — mas **rode o predicado no Passo 1** e diga o `Mode` ao usuário antes de decompor. |
| Existe `.claude/sdd/orchestration/STATE_*.yaml` e a sessão vai **retomar** o trabalho | **Leia** a postura — retomada lê o STATE, não a memória da conversa. O predicado não se aplica: o regime já foi decidido. |
| Pedido contém a palavra **`ultracode`** | Prefira o **`Workflow` nativo** ao ciclo `Agent` síncrono — definição em [`../postures/max-mode.md`](../postures/max-mode.md) §(a). |

> **Por que o predicado substituiu o gatilho antigo.** Ele dizia: *objetivo que se decompõe em três
> ou mais tasks com dependências*. Era **auto-referente** — quem julga se decompõe é o líder que já
> quer decompor, e qualquer objetivo passa. `workflow-sdd.md` §*Match the Form to the Failure* manda
> amarrar comportamento condicional a um **predicado observável**; este gatilho era a exceção que não
> seguia a regra da própria casa.
>
> **Medido** (`ORCHESTRATE_BASELINE`, 2026-08-11): numa carga que cabia com folga num só contexto,
> **solo · 3× sequencial · orquestrado** marcaram os **mesmos 19/20** num juiz cego, a **1× · 2,9× ·
> 5,1×** de tokens. Sem fronteira estrutural, orquestrar não compra qualidade — compra custo.
>
> Na rodada 2, com fronteira e com o revisor usando o checklist de repertório, o orquestrado **ganhou**
> — 24/25 contra 23/25 do solo. E o **modo mínimo empatou com ele por 46% do custo**. O ganho medido
> vem da **revisão com repertório externo**, não da decomposição em N tasks.

## Invariantes — valem antes mesmo de ler o protocolo

Estes três não podem esperar a carga da postura: violá-los corrompe o trabalho de forma silenciosa.

- **Checkpoint humano nunca é despachável.** Uma task `type: checkpoint` é decisão do **humano** e
  **nunca** entra em `ReadyTasks`. Mandá-la a um subagente é o erro exato que o tipo existe para
  impedir — o agente responderia, e a resposta pareceria uma aprovação.
- **`NextTask = no-state` não é `done`.** STATE ausente, vazio ou não-parseado significa *nada
  carregado* — jamais "orquestração concluída". Se o painel disser `no-state`, o problema é o path/
  slug/`cwd`, não o fim do trabalho.
- **Nível único, por escolha.** O líder roda no **nível principal**; os agentes base não declaram
  `Agent`, então subagente não lidera subagente. É design (mantém o gate entre subpassos), não
  limite da plataforma.

> **Por que o protocolo saiu daqui:** ele custava ~5 200 tokens em **toda** sessão — a rule mais cara
> do always-on — para valer nas poucas em que alguém de fato orquestra. Nada foi removido: o
> `/orchestrate` carrega tudo, e o gatilho acima diz quando lê-lo sem o command.

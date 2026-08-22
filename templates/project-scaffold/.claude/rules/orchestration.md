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
| **`minimo+worktree`** | Idem, **mais** isolamento: cada task concorrente no seu **worktree**, merge no fim. **Sem STATE.** | Escrita **concorrente** nos mesmos arquivos |
| **`minimo+checkpoint`** | Idem, **mais** uma parada obrigatória para o humano antes de cada passo que sai da máquina (push, PR, deploy, envio). | Há ação **outward** |
| **`completo`** | **Leia** `.claude/postures/orchestration.md` e rode o ciclo inteiro. | Fronteira de máquina de estado (abaixo) |

> Os sufixos **compõem** (`minimo+worktree+checkpoint`): fazer um vencer o outro descarta o
> mecanismo do perdedor.

**A fronteira de máquina de estado é UMA só** — o material **não cabe** no contexto de um agente. Só
ela chega a `completo`. **Contar disciplinas não é fronteira**, e **isolamento também não**: ele pede
worktree, não máquina de estado. Ambos medidos; derivação na postura.

> **Antes de informar `-FitsSingleContext $false`, pergunte: um script resolveria?** Material com
> estrutura (formato fixo, vocabulário fechado, campo parseável) é **redutível**, e redutível cabe
> numa **ferramenta**, não num contexto. **Volume não é a pergunta; irredutibilidade é** — marcar
> `$false` por tamanho cobra o ciclo mais caro por uma fronteira que não existe.

> **O preço do `minimo` é conhecido, e por isso ele é opt-in.** Custa **~2,4× no piso** — dois
> agentes, o segundo só reportando — e **~4×** se ele também corrigir; o revisor que acha mais gera
> correção maior, e quem decide precisa ver a conta inteira. Não há como baixar disso: todo agente
> que faz trabalho real gasta 40k–55k tokens só para ler o contrato, entender o artefato e validar.
>
> Então o predicado devolver `minimo` significa **"há revisão a fazer"**, não "pague por ela agora".
> **Diga o número e deixe a escolha com quem paga.** O default sem resposta é `solo`.

| Outros sinais | O que fazer |
|-------|-------------|
| **`/orchestrate <objetivo>`** | O command já carrega a postura. Siga-o — mas **rode o predicado no Passo 1** e diga o `Mode` ao usuário antes de decompor. |
| Existe `.claude/sdd/orchestration/STATE_*.yaml` e a sessão vai **retomar** o trabalho | **Leia** a postura — retomada lê o STATE, não a memória da conversa. O predicado não se aplica: o regime já foi decidido. |
| Pedido contém a palavra **`ultracode`** | Prefira o **`Workflow` nativo** ao ciclo `Agent` síncrono — definição em [`../postures/max-mode.md`](../postures/max-mode.md) §(a). |

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

> **De onde vem cada número acima** — as seis rodadas do `ORCHESTRATE_BASELINE`, por que o gatilho
> antigo (`≥3 tasks`) era auto-referente e foi substituído, e por que outward compra uma parada e não
> uma máquina de estado: veja o **registro das medições** em
> [`../postures/orchestration.md`](../postures/orchestration.md). Fica **fora do always-on** de
> propósito — a instrução acima já é a decisão; aquilo é a prova, e prova se lê quando alguém
> contesta, não em toda sessão.

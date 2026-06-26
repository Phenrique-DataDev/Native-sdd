# Orquestração — protocolo do líder (sempre aplicado)

> O **líder não é um engine**: é o **agente principal** seguindo este protocolo. `invocar`,
> `aguardar`, `paralelizar` e `resume` são a ferramenta **`Agent` nativa** — não reimplemente um
> motor de orquestração. O valor desta regra é o **ciclo** (como o líder conduz) e os **gates de
> validação** (como aceita/rejeita um resultado antes de seguir).

## Princípio

Dado um **objetivo** ou um **plano aprovado**, o líder decompõe em tasks, dá contexto a subagentes,
**valida** cada resultado contra um gate e encadeia/paraleliza — registrando estado **resumível**.
Acionado por **`/orchestrate <objetivo>`**. O líder roda no **nível principal** (sem
subagente→subagente) — ver a nota abaixo: é **escolha de design**, não limite da plataforma.

> **Nível único é escolha, não limitação (D).** Desde o **Claude Code v2.1.172** um subagente
> **pode** spawnar subagentes (foreground em qualquer profundidade; background até 5 níveis) — basta
> ter `Agent` no `tools`. Aqui **deliberadamente não usamos** isso: os agentes base não declaram
> `Agent` no frontmatter (ex.: `debugger` → `Read, Grep, Glob, Bash`), então o encadeamento fica **só
> no líder**. O motivo é o valor desta regra — **gate determinístico entre passos + STATE resumível +
> observabilidade**: se um subagente liderasse outros, o líder ficaria cego ao encadeamento interno e
> o `Test-TaskGate` não rodaria entre os subpassos (só o resumo do topo retorna). O `connects_to`
> continua sendo **dica de roteamento para o líder**, não poder de chamada do subagente. Fan-out
> read-only sem gate (ex.: exploração paralela) já tem caminho melhor: `/orchestrate` + Workflow
> nativo sob `/max`. _(fonte: context7 — code.claude.com/docs, verificado 2026-06-20)_

## Ciclo do líder

1. **Decompor** — quebrar o objetivo em tasks com **DoD** (Definition of Done), `deps` e **modelo**
   sugerido. Gravar o **STATE** em `.claude/sdd/orchestration/STATE_<slug>.yaml` (schema abaixo).
2. **Para cada task PRONTA** (deps todas `passed` — ver Paralelismo):
   1. **Contexto** — montar o *pacote*: o **artefato da fase** (regra `workflow-sdd`: passe o
      artefato anterior) + arquivos relevantes + o **DoD** como critério + o **modelo** sugerido.
   2. **Invocar** — `Agent` com `subagent_type`, `prompt` = pacote, `model`. É **síncrono** (retorna
      `result`). Para plano grande/independente, usar o **handoff externo** (ver Destino).
   3. **Validar** — montar o `Result` (testes/lint/conformidade [+ `code-reviewer`]) e rodar o
      **gate** (ver abaixo). Passou → marcar a task `passed` no STATE. Falhou → **re-invocar com
      feedback** (ver abaixo).
   4. **Encadear/paralelizar** — disparar as tasks prontas (ver Paralelismo) e seguir.
3. **Estado** — a cada task, atualizar o STATE. Retomar lê o STATE e continua de onde parou
   (idempotente: tasks `passed` não são refeitas).

## Pacote de contexto (como "dar contexto")

| Item | Conteúdo |
|------|----------|
| Artefato | o documento da fase anterior (BRAINSTORM/DEFINE/DESIGN…) — `workflow-sdd` |
| Arquivos | caminhos concretos que a task toca |
| Critério | o **DoD** da task (o que o gate vai cobrar) |
| Modelo | o modelo sugerido (ex.: Opus 4.8 para trabalho denso) |

## Gate de validação

Só avança se o gate passa (espelha `Test-CurationReadiness` do `/init`).

- **Determinístico** (`Test-TaskGate`, `tools/orchestrate.ps1`): critérios como **dados** — default
  `TestsGreen`, `LintClean`, `ArtifactConforms`. Critério obrigatório ausente conta como **falha**
  (nunca passa por omissão).
- **Semântico** (opcional): o subagente **`code-reviewer`** julga o output; o veredito entra como um
  critério booleano (ex.: `ReviewApproved`) incluído em `-Required` → combinado por **AND**.

```text
. tools/orchestrate.ps1
$gate = Test-TaskGate -Result @{ TestsGreen = $true; LintClean = $true; ArtifactConforms = $true; ReviewApproved = $true } `
                      -Required @('TestsGreen','LintClean','ArtifactConforms','ReviewApproved')
# $gate.Passed -> bool ; $gate.Failed -> critérios reprovados (vira o feedback)
```

## Re-invocação com feedback

Ao **falhar** o gate, re-invocar o subagente passando `$gate.Failed` como **feedback** explícito (o
que reprovou). Limite **`MaxAttempts = 2`** re-invocações; esgotado → task `failed` (o estado fica
`blocked` se isso travar a cadeia). O *loop* é condução (aqui, prompt); o que é determinístico é o
`Failed[]` do gate.

## Paralelismo

`Get-OrchestrationStatus` expõe **`ReadyTasks`** = tasks `pending` cujas deps estão **todas**
`passed`. Tasks independentes prontas → **várias chamadas `Agent` na mesma mensagem** (rodam em
paralelo). `NextTask` é o primeiro pronto (ordem estável), `done` (tudo `passed`) ou `blocked`
(há trabalho mas nada pronto — dep `failed`/ciclo).

## Destino: subagente na sessão × novo chat externo

- **Padrão — subagente na mesma sessão** (`Agent`): síncrono/paralelo/resume; o líder coleta o
  `result` e valida.
- **Handoff externo** — emitir a instrução *"plano aprovado, rode em novo chat com Opus 4.8"* quando:
  (a) o objetivo é um **plano grande e independente** que estouraria o contexto atual, ou (b) o
  usuário quer **continuar noutro chat/máquina**. É instrução **ao humano** (texto), não chamada de
  ferramenta.

## Schema do STATE (`.claude/sdd/orchestration/STATE_<slug>.yaml`)

```yaml
objective: implementar a feature X
tasks:
  - id: decompor
    title: levantar subtasks
    dod: lista de tasks com DoD
    model: opus-4-8
    deps: []
    status: passed        # pending | passed | failed
  - id: impl
    title: implementar core
    dod: testes verdes + lint limpo
    model: opus-4-8
    deps: [decompor]      # inline, separado por vírgula
    status: pending
```

`Get-OrchestrationStatus -StatePath <arquivo>` lê este STATE (read-only) e deriva o progresso +
`ReadyTasks` + `NextTask`. `Format-OrchestrationReport` imprime o painel.

## O que NÃO fazer

- **Não** construir engine/daemon de orquestração — `Agent` nativo já invoca/aguarda/paraleliza/resume.
- **Não** orquestrar multi-nível (subagente liderando subagentes) — o líder fica no topo. É **escolha
  de design** (gate + STATE + observabilidade), não limite da plataforma: o Claude Code **suporta**
  aninhamento desde v2.1.172, mas aqui os agentes não recebem a ferramenta `Agent` de propósito (nota
  no **Princípio**).
- **Não** avançar com o gate reprovado — re-invocar com feedback ou marcar `failed`.
- **Não** inventar o resultado de uma task — o `Result` do gate vem de verificação real (testes/lint).

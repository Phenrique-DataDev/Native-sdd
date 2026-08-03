# Harness Contract — contrato de I/O dos hooks (base multi-harness)

> **Base do H5** (adapter multi-harness). Define a **forma canônica** de evento que os
> *scripts compartilhados* (hooks) deste projeto consomem e produzem **hoje** (dialeto nativo do
> Claude Code), para que um **adapter** possa traduzir o JSON de outro harness
> (Cursor/Codex/OpenCode) ↔ esta forma **sem reescrever a lógica** dos scripts.
>
> Estende o contrato canônico de agentes do [`AGENTS.md`](../templates/project-scaffold/AGENTS.md)
> (H1) descendo até a camada de **hooks**.
>
> **Status (atualizado 2026-07-06):** a coluna **canônica** é real (extraída do código dos hooks).
> As colunas **por-harness** foram **verificadas via doc oficial** (WebFetch, não inventadas — ver
> §Procedência): **Cursor** (`cursor.com/docs/hooks`), **Codex** (`developers.openai.com/codex/hooks`)
> e **OpenCode** (`opencode.ai/docs/plugins`). **Decisão explícita de escopo (2026-07-06):** reabrir
> o H5 **sem** esperar uso real recorrente — preparar a base para os **3 harnesses do mercado já**,
> não só 1. Isso desvia do gatilho original do brainstorm (que condicionava a uso real); ver
> `DEFINE_ADAPTER.md` (camada dev/meta) para o registro explícito dessa decisão.
>
> **H5 shipado em 2026-07-06:** os 3 adapters (Cursor/Codex/OpenCode) existem e estão testados —
> `templates/global-claude/hooks/adapters/` (`cursor/`, `codex/`, `opencode/`), cobrindo
> `destructive-guard`. Não instalados por padrão (referência opt-in). Verificação via doc oficial +
> fixtures sintéticas, **não** e2e ao vivo (nenhum dos 3 harnesses está instalado). Detalhe completo
> em [`archive/adapter/SHIPPED_2026-07-06.md`](../.claude/sdd/archive/adapter/SHIPPED_2026-07-06.md).

## Por que este documento existe

A lógica de decisão dos hooks já é **pura e agnóstica** de harness (`Test-IsGitPush`,
`Get-PushDecision`, `Get-StalenessSignals`, `Format-Nudge`…). O **único** acoplamento ao Claude Code
está na **borda de I/O**: o *shape* do JSON lido do `stdin` e o *shape* do JSON escrito no `stdout`.
Documentar essa borda é o pré-requisito barato de qualquer adapter — e é tudo que falta para o H5
ficar destravável por uma fatia fina.

```
        ┌──────────────┐     stdin JSON nativo      ┌───────────────┐
        │   Harness    │ ─────────────────────────▶ │    ADAPTER    │  (futuro; H5)
        │ (CC/Cursor/…)│ ◀───────────────────────── │  traduz borda │
        └──────────────┘     stdout JSON nativo      └───────┬───────┘
                                                             │ contrato canônico (este doc)
                                                             ▼
                                              ┌───────────────────────────┐
                                              │  script compartilhado      │
                                              │  (destructive-guard /      │
                                              │   curation-nudge) — lógica │
                                              │  PURA, agnóstica           │
                                              └───────────────────────────┘
```

Hoje o Claude Code já fala o contrato canônico nativamente → **não há adapter**: o harness liga
direto no script. Para outro harness, o adapter mapeia `harness ↔ canônico` nas duas pontas.

---

## Scripts compartilhados cobertos

| Script | Evento(s) | Lê do payload | Escreve | Feature |
|--------|-----------|---------------|---------|---------|
| `templates/global-claude/hooks/secret-guard.{ps1,sh}` | `PreToolUse` (matcher `Bash`) | `tool_name`, `tool_input.command` | `permissionDecision` (`ask`) ou **silêncio** | par `.sh` por J4 |
| `templates/global-claude/hooks/destructive-guard.{ps1,sh}` | `PreToolUse` (matcher `Bash`) | `tool_name`, `tool_input.command` | `permissionDecision` (`ask`) ou **silêncio** | J5 · destrutivo não-git sob `auto`; par `.sh` por J4 |
| `templates/project-scaffold/.claude/hooks/curation-nudge.ps1` (`.sh` degradado) | `SessionStart` (`*`), `PostToolUse` (matcher `Write\|Edit`) | `hook_event_name`, `cwd`, `tool_input.file_path` | `additionalContext` ou **silêncio** | J3 · `.sh` = degradação consciente (J4) |

> **J4 (hooks-portable):** os guards de segurança ganharam um **par `.sh`** (espelho fiel da lógica
> pura), registrado por uma **dispatch-line** que escolhe `pwsh` (→`.ps1`, zero regressão) ou `bash`
> (→`.sh`). A paridade de decisão `.ps1`↔`.sh` é travada por `tools/tests/hooks-portable.Tests.ps1`.
> Confirma na prática o que este contrato previu: a borda de I/O é o único acoplamento — a lógica
> reusa a forma canônica. O `curation-nudge.sh` é **degradação consciente** (não porta os sinais, que
> dependem da camada `tools/`).

---

## Contrato de ENTRADA (stdin → script)

Campos canônicos consumidos pelos scripts (união real dos dois hooks). Acesso defensivo: campo
ausente ⇒ tratado como nulo (`Get-PropOrNull`) e o script cai no seu fail-safe.

| Campo canônico | Tipo | Usado por | Significado |
|----------------|------|-----------|-------------|
| `hook_event_name` | string | curation-nudge | Evento: `PreToolUse` \| `PostToolUse` \| `SessionStart` |
| `tool_name` | string | destructive-guard | Ferramenta interceptada: `Bash` \| `Write` \| `Edit` \| … |
| `tool_input.command` | string | destructive-guard | Linha de comando (quando `tool_name = Bash`) |
| `tool_input.file_path` | string | curation-nudge | Caminho do arquivo escrito/editado (`Write`/`Edit`) |
| `cwd` | string | curation-nudge | Raiz do projeto/working dir do harness |

Exemplo canônico (`PreToolUse`/Bash):

```json
{ "hook_event_name": "PreToolUse", "tool_name": "Bash",
  "tool_input": { "command": "git push origin main" }, "cwd": "/repo" }
```

Exemplo canônico (`PostToolUse`/Edit):

```json
{ "hook_event_name": "PostToolUse", "tool_name": "Edit",
  "tool_input": { "file_path": ".claude/kb/business/x.md" }, "cwd": "/repo" }
```

---

## Contrato de SAÍDA (script → harness)

Três formas de saída, todas via `stdout` + exit 0:

| Forma | JSON | Quem usa |
|-------|------|----------|
| **Decisão de permissão** | `{ "hookSpecificOutput": { "hookEventName": "PreToolUse", "permissionDecision": "allow\|ask\|deny", "permissionDecisionReason": "<txt>" }, "systemMessage": "<txt>" }` | destructive-guard |
| **Contexto informativo** | `{ "hookSpecificOutput": { "hookEventName": "<evt>", "additionalContext": "<txt>" } }` | curation-nudge |
| **Silêncio / passthrough** | *(sem stdout)* — `exit 0` | ambos (fail-safe, nada a dizer) |

**Invariante de fail-safe (deve ser preservado por qualquer adapter):**
- destructive-guard: erro/indeterminação **antes** de confirmar que o comando é destrutivo → silêncio;
  **depois** → nunca `allow` por engano (degrada para `ask`).
- curation-nudge: qualquer erro/fora-de-escopo/cooldown → silêncio total (read-only, não-bloqueante).

---

## Mapa por-harness (verificado via doc oficial — 2026-07-06)

Para cada harness-alvo, o adapter precisa de duas traduções. Preenchido a partir da doc oficial de
cada harness (ver §Procedência); nada aqui foi inventado — onde a doc não deixa claro, a célula diz
**"a verificar"** em vez de assumir.

### Entrada — `campo nativo do harness → campo canônico`

| Campo canônico | Claude Code (nativo) | Cursor | Codex | OpenCode |
|----------------|----------------------|--------|-------|----------|
| `hook_event_name` | `hook_event_name` | `hook_event_name` (campo comum a todo hook) + o **nome do evento em si** já seleciona a rota (`beforeShellExecution`/`preToolUse`/…) | `hook_event_name` (**idêntico** ao canônico) | **não existe como campo** — a rota é o **nome do hook registrado** (`tool.execute.before`/`tool.execute.after`); estrutural, não um valor de campo |
| `tool_name` | `tool_name` | `preToolUse.tool_name` (`Shell`/`Read`/`Write`/`Task`…); em `beforeShellExecution` não há campo — o próprio evento já é "é um Shell" | `tool_name` (evento `PreToolUse`/`PostToolUse`; nome citado na doc, não detalhado por tool) | `input.tool` (ex.: `"bash"`) |
| `tool_input.command` | `tool_input.command` | `beforeShellExecution.command` (evento dedicado a shell) OU `preToolUse.tool_input` (objeto, quando `tool_name="Shell"`) | `tool_input` (objeto; campo `.command` não citado literalmente na doc, mas o shape geral é `tool_name`+`tool_input` igual ao canônico) | `input.args.command` (quando `input.tool === "bash"`) |
| `tool_input.file_path` | `tool_input.file_path` | `afterFileEdit.file_path` (evento dedicado; sem `permission`, é pós-fato) | _a verificar_ — doc não lista `file_path` explicitamente para `apply_patch` | `input.args.filePath` |
| `cwd` | `cwd` | `beforeShellExecution.cwd` / `preToolUse.cwd` | `cwd` (campo comum a todo hook, **idêntico** ao canônico) | **não é campo do evento** — disponível só no **contexto do plugin** (`directory`/`worktree`, passado 1x ao registrar, não por-chamada) |

### Saída — `forma canônica → forma nativa do harness`

| Forma canônica | Claude Code (nativo) | Cursor | Codex | OpenCode |
|----------------|----------------------|--------|-------|----------|
| Decisão de permissão | `hookSpecificOutput.permissionDecision` (`allow\|ask\|deny`) | `permission` **top-level** (`"allow"\|"deny"\|"ask"` em `beforeShellExecution`; mas **`preToolUse` só aceita `allow\|deny`, sem `ask`** — diferença real de capacidade) | `hookSpecificOutput.permissionDecision` (`allow\|deny`) — **nome de campo idêntico** ao canônico; doc não mostra `ask` explícito para `PreToolUse` (usa `PermissionRequest` à parte para isso) | **não é campo de retorno** — o hook **lança exceção** (`throw`) para bloquear; ausência de exceção = allow implícito. Não há "ask" (binário allow/deny por design) |
| Contexto informativo | `hookSpecificOutput.additionalContext` | `postToolUse.additional_context` (snake_case, campo próprio — não aninhado em `hookSpecificOutput`) | `hookSpecificOutput.additionalContext` (**idêntico**) | _a verificar_ — não encontrado equivalente direto nos hooks `tool.execute.*`; pode exigir hook de `session`/`chat.message` separado |
| Silêncio | `exit 0` sem stdout | stdout vazio + exit 0 = segue; exit code 2 = bloqueia (`deny` equivalente); outro código = **fail-open** (segue mesmo assim — diverge do fail-safe do Claude Code) | exit 0 com stdout vazio = sucesso (igual canônico) | não lançar erro = segue (é o "silêncio" do modelo imperativo) |

> **Achado relevante (não assumir paridade):**
> - **Codex converge quase campo-a-campo** com o canônico (`hook_event_name`, `cwd`,
>   `hookSpecificOutput.permissionDecision`/`additionalContext`) — o adapter para Codex tende a ser
>   uma tradução **quase idêntica** (poucos campos a ajustar).
> - **Cursor tem exit-code fail-open** (código de saída ≠ 0/2 deixa a ação seguir) — **oposto** ao
>   fail-safe assimétrico dos guards deste projeto (erro → nunca `allow` por engano). O adapter para
>   Cursor **precisa** garantir que erro do script tradutor produza `permission: "ask"` explícito no
>   JSON de saída, nunca depender do exit code para o lado seguro.
> - **OpenCode não é stdin/stdout de processo** — é uma função JS/TS **in-process** (plugin), que
>   bloqueia lançando uma exceção. Isso **não é** um harness incompatível com o contrato — só muda
>   **onde** a tradução acontece: o plugin JS chama o script pwsh/bash existente como **subprocesso**
>   (com o JSON canônico no stdin dele) e traduz o stdout/exit-code do script de volta para
>   `throw`/retorno normal. Ver §Como um adapter usaria este contrato.
> - Nenhum dos 3 harnesses tem, documentado, um equivalente direto e completo de
>   `additionalContext` fora do fluxo de `PostToolUse`/eventos de sessão — quando ausente, o adapter
>   degrada para **passthrough silencioso** (perde o nudge informativo, mas não quebra nem bloqueia).

---

## Como um adapter usaria este contrato

Dois formatos de adapter, conforme o harness invoca hooks como **processo** (stdin/stdout) ou
**in-process** (função JS/TS):

### Cursor e Codex — processo externo (mesmo modelo do Claude Code)

`stdin (harness) → [adapter: mapeia entrada] → contrato canônico → script puro (destructive-guard /
curation-nudge) → contrato de saída → [adapter: mapeia saída] → stdout (harness)`.

O adapter é um script (`.ps1`/`.sh`) registrado no `hooks.json`/`config.toml` do harness, que:
1. Lê o stdin nativo do harness.
2. Monta o JSON canônico (campos da tabela de entrada acima).
3. Invoca o script existente **dot-sourced** (reusa `Get-DestructiveDecision`/`Get-StalenessSignals`
   direto — sem reprocessar stdin, já que o seam `Read-NormalizedEvent` aceita o objeto já montado).
4. Traduz a decisão canônica (`allow`/`ask`/`deny` + texto) para o shape nativo do harness.
5. Para o **Cursor**, nunca depender do exit code p/ o lado seguro (fail-open documentado) — sempre
   emitir `permission` explícito no JSON, mesmo em erro (`"ask"`).

### OpenCode — plugin in-process (subprocesso)

`plugin JS (tool.execute.before) → monta contrato canônico → spawna o script pwsh/bash como
subprocesso (stdin = contrato canônico) → lê stdout/exit-code do script → traduz p/ throw (deny) ou
retorno normal (allow)`.

Como o OpenCode não expõe um evento de processo, o plugin **é** o adapter: ele reimplementa em poucas
linhas de JS a ponte que os outros dois harnesses fazem via `hooks.json` + script tradutor, mas o
**script de decisão em si continua sendo o mesmo `.ps1`/`.sh`** — só muda quem o invoca.

### Seam `Read-NormalizedEvent`

A primeira tarefa do `/build` (Abordagem B do brainstorm) foi extrair, em cada script, uma
`Read-NormalizedEvent` pura — ponto único onde o adapter injeta o payload já no formato canônico —
sem mexer nas funções de decisão. Ver `DESIGN_ADAPTER.md` para o detalhe da extração.

---

## Procedência

- Coluna canônica: extraída do código de `destructive-guard.ps1` (J5) e `curation-nudge.ps1`
  (J3); schema de hook do Claude Code verificado via context7 (`/anthropics/claude-code`) nos
  ships dessas features.
- Coluna **Cursor**: [`cursor.com/docs/hooks`](https://cursor.com/docs/hooks) (WebFetch, 2026-07-06)
  — eventos `beforeShellExecution`/`afterShellExecution`/`beforeMCPExecution`/`afterFileEdit`/
  `preToolUse`/`postToolUse`/`sessionStart`/`stop`/etc., formato `hooks.json`, exit-code fail-open.
- Coluna **Codex**: [`developers.openai.com/codex/hooks`](https://developers.openai.com/codex/hooks)
  (WebFetch, 2026-07-06) — eventos `PreToolUse`/`PostToolUse`/`PermissionRequest`/`SessionStart`/…,
  `hookSpecificOutput.permissionDecision`/`additionalContext` **quase idênticos** ao Claude Code.
- Coluna **OpenCode**: [`opencode.ai/docs/plugins`](https://opencode.ai/docs/plugins) (WebFetch,
  2026-07-06) + gist de referência da comunidade (`tool.execute.before`/`.after`, `input.tool`/
  `input.args.command`/`input.args.filePath`/`input.sessionID`) — modelo **in-process** (plugin
  JS/TS), não stdin/stdout de processo; bloqueio via `throw`, não via campo de decisão.
- Origem da ideia de adapter: padrão externo de operador *harness-native* (projeto MIT) —
  aproveitada só a **lógica** (`stdin JSON → adapter → script`), não o runtime.
- Brainstorm: [`.claude/sdd/archive/adapter/BRAINSTORM_ADAPTER.md`](../.claude/sdd/archive/adapter/BRAINSTORM_ADAPTER.md).
- Define/Design/Build/Ship: [`.claude/sdd/archive/adapter/`](../.claude/sdd/archive/adapter/)
  (`DEFINE_ADAPTER.md`/`DESIGN_ADAPTER.md`/`BUILD_REPORT_ADAPTER.md`/`SHIPPED_2026-07-06.md`).

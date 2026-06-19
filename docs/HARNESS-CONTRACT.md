# Harness Contract — contrato de I/O dos hooks (base multi-harness)

> **Base do `[[H5]]`** (adapter multi-harness). Define a **forma canônica** de evento que os
> *scripts compartilhados* (hooks) deste projeto consomem e produzem **hoje** (dialeto nativo do
> Claude Code), para que um futuro **adapter** possa traduzir o JSON de outro harness
> (Cursor/Codex/OpenCode) ↔ esta forma **sem reescrever a lógica** dos scripts.
>
> Estende o contrato canônico de agentes do [`AGENTS.md`](../templates/project-scaffold/AGENTS.md)
> (`[[H1]]`) descendo até a camada de **hooks**.
>
> **Status:** a coluna **canônica** é real (extraída do código dos hooks). As colunas **por-harness**
> (Cursor/Codex/OpenCode) estão **a verificar** — a forma do JSON de cada harness **não é conhecida**
> e **não foi inventada** (regra "não inventar dados"). Preenchem-se no `/define`/`/build` do adapter,
> via doc oficial/context7, quando um harness real entrar em uso.

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
                                              │  (main-push-guard /        │
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
| `templates/global-claude/hooks/main-push-guard.{ps1,sh}` | `PreToolUse` (matcher `Bash`) | `tool_name`, `tool_input.command` | `permissionDecision` (`allow`/`ask`) ou **silêncio** | `[[C6]]` · par `.sh` por `[[J4]]` |
| `templates/global-claude/hooks/secret-guard.{ps1,sh}` | `PreToolUse` (matcher `Bash`) | `tool_name`, `tool_input.command` | `permissionDecision` (`ask`) ou **silêncio** | par `.sh` por `[[J4]]` |
| `templates/global-claude/hooks/destructive-guard.{ps1,sh}` | `PreToolUse` (matcher `Bash`) | `tool_name`, `tool_input.command` | `permissionDecision` (`ask`) ou **silêncio** | `[[J5]]` · destrutivo não-git sob `auto`; par `.sh` por `[[J4]]` |
| `templates/project-scaffold/.claude/hooks/curation-nudge.ps1` (`.sh` degradado) | `SessionStart` (`*`), `PostToolUse` (matcher `Write\|Edit`) | `hook_event_name`, `cwd`, `tool_input.file_path` | `additionalContext` ou **silêncio** | `[[J3]]` · `.sh` = degradação consciente (`[[J4]]`) |

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
| `tool_name` | string | main-push-guard | Ferramenta interceptada: `Bash` \| `Write` \| `Edit` \| … |
| `tool_input.command` | string | main-push-guard | Linha de comando (quando `tool_name = Bash`) |
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
| **Decisão de permissão** | `{ "hookSpecificOutput": { "hookEventName": "PreToolUse", "permissionDecision": "allow\|ask\|deny", "permissionDecisionReason": "<txt>" }, "systemMessage": "<txt>" }` | main-push-guard |
| **Contexto informativo** | `{ "hookSpecificOutput": { "hookEventName": "<evt>", "additionalContext": "<txt>" } }` | curation-nudge |
| **Silêncio / passthrough** | *(sem stdout)* — `exit 0` | ambos (fail-safe, nada a dizer) |

**Invariante de fail-safe (deve ser preservado por qualquer adapter):**
- main-push-guard: erro/indeterminação **antes** de confirmar "push na default" → silêncio; **depois**
  → nunca `allow` por engano (degrada para `ask`).
- curation-nudge: qualquer erro/fora-de-escopo/cooldown → silêncio total (read-only, não-bloqueante).

---

## Mapa por-harness (a verificar — NÃO inventar)

Para cada harness-alvo, o adapter precisa de duas traduções. As células estão **vazias de
propósito**: preenchê-las exige a doc oficial/context7 do harness (feito no `/define`/`/build`,
quando o harness entrar em uso real). **Não preencher de memória.**

### Entrada — `campo nativo do harness → campo canônico`

| Campo canônico | Claude Code (nativo) | Cursor | Codex | OpenCode |
|----------------|----------------------|--------|-------|----------|
| `hook_event_name` | `hook_event_name` | _a verificar_ | _a verificar_ | _a verificar_ |
| `tool_name` | `tool_name` | _a verificar_ | _a verificar_ | _a verificar_ |
| `tool_input.command` | `tool_input.command` | _a verificar_ | _a verificar_ | _a verificar_ |
| `tool_input.file_path` | `tool_input.file_path` | _a verificar_ | _a verificar_ | _a verificar_ |
| `cwd` | `cwd` | _a verificar_ | _a verificar_ | _a verificar_ |

### Saída — `forma canônica → forma nativa do harness`

| Forma canônica | Claude Code (nativo) | Cursor | Codex | OpenCode |
|----------------|----------------------|--------|-------|----------|
| Decisão de permissão | `hookSpecificOutput.permissionDecision` | _a verificar (suporta? como?)_ | _a verificar_ | _a verificar_ |
| Contexto informativo | `hookSpecificOutput.additionalContext` | _a verificar_ | _a verificar_ | _a verificar_ |
| Silêncio | `exit 0` sem stdout | _a verificar_ | _a verificar_ | _a verificar_ |

> **Atenção (a decidir no `/define`):** se um harness **não** suportar uma forma de saída (ex.: não
> tem conceito de `permissionDecision`), o adapter define a degradação — provável **passthrough**
> (deixa o harness seguir) preservando o fail-safe assimétrico. Não assumir paridade.

---

## Como um adapter usaria este contrato (esboço, não-normativo)

`stdin (harness) → [adapter: mapeia entrada] → contrato canônico → script puro → contrato de saída →
[adapter: mapeia saída] → stdout (harness)`.

A primeira tarefa do `/build` (Abordagem B do brainstorm) é extrair nos hooks um
`Read-NormalizedEvent` — ponto único onde o adapter injeta o payload já no formato canônico — sem
mexer nas funções puras de decisão.

---

## Procedência

- Coluna canônica: extraída do código de `main-push-guard.ps1` (`[[C6]]`) e `curation-nudge.ps1`
  (`[[J3]]`); schema de hook do Claude Code verificado via context7 (`/anthropics/claude-code`) nos
  ships dessas features.
- Origem da ideia de adapter: padrão externo de operador *harness-native* (projeto MIT) —
  aproveitada só a **lógica** (`stdin JSON → adapter → script`), não o runtime.
- Brainstorm: [`.claude/sdd/features/BRAINSTORM_ADAPTER.md`](../.claude/sdd/features/BRAINSTORM_ADAPTER.md).

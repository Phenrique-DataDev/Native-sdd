// Adapter OpenCode (H5) -- plugin in-process que traduz tool.execute.before/after para o
// contrato canonico (docs/HARNESS-CONTRACT.md) e invoca, SEM MODIFICAR, o script real
// (destructive-guard.ps1/.sh).
//
// Diferenca estrutural dos adapters Cursor/Codex: o OpenCode nao roda hooks como processo externo
// (stdin/stdout) -- eh uma funcao JS/TS chamada IN-PROCESS pelo runtime Bun do harness. Por isso
// este plugin usa o `$` (shell API do Bun, injetado no contexto do plugin -- ver
// opencode.ai/docs/plugins, fetch 2026-07-06) para SPAWNAR o script existente como subprocesso,
// alimentando-o com o JSON canonico via stdin e traduzindo o stdout de volta para `throw`
// (bloqueia) ou retorno normal (permite). O script de decisao em si NUNCA e' reescrito em JS.
//
// Bloqueio no OpenCode e' IMPERATIVO (throw), nao um campo de retorno -- por isso nao ha
// equivalente a "ask": qualquer coisa que nao seja "allow" vira throw (o lado mais restritivo).
//
// Instalacao (opt-in, nao automatica): copie este arquivo para .opencode/plugins/ (projeto) ou
// ~/.config/opencode/plugins/ (global). Requer pwsh OU bash disponivel no PATH -- se nenhum
// existir, o plugin degrada em silencio (nao bloqueia; ver resolveRunner()).
//
// Verificacao: nao ha OpenCode/Bun instalados neste ambiente -- a logica foi testada com um `$`
// MOCKADO em Node puro (tools/tests/opencode-plugin.test.js), nao com o runtime Bun real. Ver
// DESIGN_ADAPTER.md (Testing Strategy) para a limitacao declarada.

import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const __dirname = dirname(fileURLToPath(import.meta.url))

// --- PURA: acha o script-alvo (mesma cascata do Resolve-GuardScript em harness-translate.ps1) --
export function resolveGuardScript(scriptBaseName, adapterDir, env) {
  const globalRel = join(adapterDir, "..", "..", `${scriptBaseName}.ps1`)
  if (existsSync(globalRel)) return { path: globalRel, kind: "ps1" }
  const globalRelSh = join(adapterDir, "..", "..", `${scriptBaseName}.sh`)
  if (existsSync(globalRelSh)) return { path: globalRelSh, kind: "sh" }

  if (scriptBaseName === "curation-nudge") {
    const projRel = join(adapterDir, "..", "..", "..", "..", "project-scaffold", ".claude", "hooks", "curation-nudge.ps1")
    if (existsSync(projRel)) return { path: projRel, kind: "ps1" }
  }

  const home = env.SDD_WORKFLOW_HOME
  if (home) {
    const viaGlobal = join(home, "templates", "global-claude", "hooks", `${scriptBaseName}.ps1`)
    if (existsSync(viaGlobal)) return { path: viaGlobal, kind: "ps1" }
    if (scriptBaseName === "curation-nudge") {
      const viaProj = join(home, "templates", "project-scaffold", ".claude", "hooks", "curation-nudge.ps1")
      if (existsSync(viaProj)) return { path: viaProj, kind: "ps1" }
    }
  }
  return null
}

// --- PURA: monta o JSON canonico a partir do input.tool.execute.before ------------------------
export function toCanonical(input, output, directory) {
  if (input.tool !== "bash") return null   // so cobre o caminho Bash->destructive-guard nesta rodada
  const command = output?.args?.command ?? ""
  if (!command) return null
  return {
    hook_event_name: "PreToolUse",
    tool_name: "Bash",
    tool_input: { command },
    cwd: directory ?? "",
  }
}

// --- PURA: decide bloquear (throw) ou permitir a partir do stdout canonico do script-alvo ------
export function decideFromCanonicalStdout(stdout) {
  const trimmed = (stdout ?? "").trim()
  if (!trimmed) return { block: false }   // silencio do script-alvo = allow implicito

  let decision
  try {
    decision = JSON.parse(trimmed)
  } catch {
    // stdout ilegivel -> fail-safe: bloqueia (nunca "allow" silencioso por engano)
    return { block: true, reason: "destructive-guard: saida ilegivel do adapter — comando bloqueado por seguranca" }
  }

  const perm = decision?.hookSpecificOutput?.permissionDecision
  if (perm === "ask" || perm === "deny") {
    const reason = decision?.hookSpecificOutput?.permissionDecisionReason || decision?.systemMessage || "comando bloqueado pelo destructive-guard"
    return { block: true, reason }
  }
  return { block: false }
}

export const DestructiveGuardPlugin = async ({ directory, $ }) => {
  return {
    "tool.execute.before": async (input, output) => {
      const canonical = toCanonical(input, output, directory)
      if (!canonical) return   // evento fora do escopo deste adapter (so Bash/destructive-guard)

      const target = resolveGuardScript("destructive-guard", __dirname, process.env)
      if (!target) {
        // Sem o script-alvo: nao ha como decidir. Fail-safe = bloquear (nao silenciar o guard).
        throw new Error("destructive-guard: script nao encontrado (configure SDD_WORKFLOW_HOME) — comando bloqueado por seguranca")
      }

      const canonicalJson = JSON.stringify(canonical)
      let stdout = ""
      try {
        if (target.kind === "ps1") {
          const result = await $`echo ${canonicalJson} | pwsh -NoProfile -File ${target.path}`.quiet()
          stdout = result.stdout.toString()
        } else {
          const result = await $`echo ${canonicalJson} | bash ${target.path}`.quiet()
          stdout = result.stdout.toString()
        }
      } catch (err) {
        // Subprocesso falhou (exit != 0 sem stdout util) -> fail-safe: bloqueia.
        throw new Error(`destructive-guard: adapter falhou ao rodar o guard (${err?.message ?? "erro desconhecido"}) — comando bloqueado por seguranca`)
      }

      const { block, reason } = decideFromCanonicalStdout(stdout)
      if (block) throw new Error(reason)
    },
  }
}

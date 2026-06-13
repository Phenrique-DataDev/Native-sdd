# 01 · Onboarding de IA

> Como **contextualizar a IA** num projeto: que camadas de contexto existem, o que cada
> artefato carrega e como elas se compõem. Aqui está o *porquê/o quê*; o *como* (comandos)
> está em [`../../docs/USO.md`](../../docs/USO.md).

## Princípio

A IA só executa bem o que **entende**. Onboarding é estruturar o contexto em camadas, da
mais geral (a pessoa) à mais específica (a tarefa), de modo que cada agente saiba **quem é
o usuário, qual o projeto e como trabalhar** — sem precisar adivinhar.

## As camadas de contexto

Da mais geral para a mais específica (**a mais específica vence** em conflito):

| Camada | Onde | O que carrega |
|--------|------|---------------|
| **Pessoal (global)** | `~/.claude/CLAUDE.md` | Identidade, stack preferida, convenções e autonomia git — vale para todos os projetos |
| **Contrato do projeto** | `AGENTS.md` (raiz) | Regras canônicas de operação para **qualquer** agente (Claude, Codex…) |
| **Camada Claude Code** | `CLAUDE.md` (raiz) | Aponta para o `AGENTS.md` (`@AGENTS.md`) e adiciona só o específico do Claude Code |
| **Regras sempre ativas** | `.claude/rules/` | workflow-sdd · cli-first · agent-routing · kb-taxonomy · project-context |
| **Contexto do projeto** | `.claude/rules/project-context.md` | Stack, domínio e convenções concretas — preenchido no `/setup` |
| **Conhecimento** | `.claude/kb/` | Base reutilizável em 4 camadas (negócio/ferramenta/implementação/operação) |

```text
~/.claude/CLAUDE.md  →  AGENTS.md  →  CLAUDE.md  →  .claude/rules/  →  project-context.md  →  .claude/kb/
   (pessoal)            (canônico)    (Claude)       (sempre ativas)     (stack/domínio)        (conhecimento)
```

## Hierarquia de loading (precedência)

As camadas acima descrevem **o que cada artefato carrega**. Esta seção responde a outra
pergunta: quando duas camadas **discordam**, qual vence? Separe os dois conceitos:

- **Loading (composição):** todos os níveis disponíveis são **carregados e somados** — o
  contexto final é a união deles. Nada é "ignorado"; eles se complementam.
- **Precedência (conflito):** quando dois níveis afirmam coisas **incompatíveis**, vale o
  **mais específico** — com uma exceção no topo (a *managed policy*, que é inegociável).

Ordem, do que **menos** vence ao que **mais** vence:

| # | Nível | Onde | Papel | Sobreponível? |
|---|-------|------|-------|---------------|
| 1 | **Pessoal (global)** | `~/.claude/CLAUDE.md` | Identidade, stack, convenções e autonomia git — base para todo projeto | Sim (projeto vence) |
| 2 | **Projeto** | `<projeto>/.claude/CLAUDE.md` + `AGENTS.md` + `.claude/rules/` | Regras do projeto atual — vencem o global em conflito | Sim (local vence) |
| 3 | **Local** | `<projeto>/CLAUDE.local.md` | Overrides da sua máquina, **gitignored** (não versionado) — ajustes pessoais sem afetar o time | Sim (managed vence) |
| 0 | **Managed policy** | política gerenciada (opcional) | Trava de segurança/governança — **inviolável**, vence todos | **Não** |

```text
managed policy  >  CLAUDE.local.md  >  <projeto>/.claude/CLAUDE.md  >  ~/.claude/CLAUDE.md
  (inegociável)      (local, gitignored)     (projeto)                    (global pessoal)
```

> **Regra-mãe:** *o mais específico vence* — **exceto** a managed policy, que fica acima de
> tudo. Por isso uma regra de projeto pode endurecer (nunca afrouxar) o global, e a managed
> policy pode vetar ambos. A managed policy é **opcional** (ver `templates/managed-policy/`).

**Exemplos de conflito:**

- Global diz "PowerShell por default"; o projeto é Python-first → **vale o projeto** (nível 2).
- Projeto permite push livre em feature; você quer travar na sua máquina → ponha no
  `CLAUDE.local.md` (nível 3), sem mexer no repo do time.
- Qualquer nível "permite" um comando que a managed policy **nega** → **fica negado** (nível 0).

## `AGENTS.md` como fonte canônica

O contrato de operação fica no **`AGENTS.md`** — tool-neutral, lido por qualquer agente. O
`CLAUDE.md` é uma camada fina que o importa e só acrescenta o que é específico do Claude
Code (slash commands, etc.). Assim a metodologia **não fica presa a uma ferramenta**:
portar para Codex/Cursor é apontar a outra ferramenta para o mesmo `AGENTS.md`.

## Onboarding automático vs. por projeto

- **Máquina (global):** `onboarding/install.ps1` instala deps e monta o `~/.claude`
  pessoal. Feito **uma vez por máquina**.
- **Projeto:** `onboarding/new-project.ps1` copia o scaffold; `/setup` captura o contexto
  específico. Feito **uma vez por projeto**.

## O `/setup` e o estado do projeto

Enquanto `project-context.md` estiver com `status: template`, o projeto é **não
inicializado** — os agentes pedem o `/setup` antes de executar trabalho. Depois de
preenchido (`status: active`), esse arquivo vira a **fonte de verdade** de stack, domínio e
convenções, e todo o resto se ancora nele.

## Especialização sob demanda (curadoria)

O scaffold é **genérico e context-free** de propósito. A especialização (agentes de
domínio, KB populada) acontece na **curadoria** pós-`/setup` — feature em construção (EPIC
G): `/audit-agents` cura/gera agentes, `/train-kb` popula a base. Ver
[`../../features/BACKLOG.md`](../../features/BACKLOG.md).

## Veja também

- Execução do trabalho: [`../02-execution/`](../02-execution/)
- Padrões e convenções: [`../03-standards/`](../03-standards/)
- Passo-a-passo prático: [`../../docs/USO.md`](../../docs/USO.md)

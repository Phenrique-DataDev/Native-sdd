# Guia de uso · da máquina ao SDD

> Como usar a metodologia de ponta a ponta: **preparar a máquina → config pessoal → criar
> o projeto → inicializar → executar com SDD**. Visão e princípios em
> [`VISAO.md`](VISAO.md); este guia é o passo-a-passo prático do que já está implementado.

## O fluxo em 1 minuto

```text
1. INSTALAR   onboarding/install.ps1      → máquina pronta (deps + ~/.claude pessoal)
2. CRIAR      onboarding/new-project.ps1  → projeto novo já com o scaffold SDD
3. SETUP      /setup                      → captura o contexto do projeto (stack, domínio)
4. CURADORIA  /init                       → especializa agentes/KB ao domínio
5. EXECUTAR   SDD                         → /brainstorm → /define → /design → /build → /ship
```

> Todos os passos estão prontos. A curadoria (passo 4) é orquestrada pelo `/init`, que
> encadeia `/setup → /audit-agents → /train-kb → /sync-context` com aprovação entre etapas.

---

## 1. Preparar a máquina — `install.ps1` (Windows) · `install.sh` (Linux)

Deixa o PC pronto para dev/dados com Claude Code: instala dependências e monta o
`~/.claude` pessoal. **Windows e Linux** implementados (macOS é stub). O runtime é o
**PowerShell 7+** em todo SO — no Linux, o `install.sh` o instala e delega o miolo ao mesmo
código testado do Windows.

Um PC Windows recém-formatado costuma ter só o **Windows PowerShell 5.1** com `ExecutionPolicy`
restrita. O instalador é compatível com 5.1 e **instala o PowerShell 7** entre as deps:

```powershell
# Windows
powershell -ExecutionPolicy Bypass -NoProfile -File .\onboarding\install.ps1
```

```bash
# Linux (apt/dnf/pacman, auto-detectado)
bash ./onboarding/install.sh            # --check / --dry-run / --skip-clis também valem
```

| Comando | O que faz |
|---------|-----------|
| `.\onboarding\install.ps1` | Instalação completa (deps + Claude Code + VS Code + `~/.claude`) |
| `.\onboarding\install.ps1 -Check` | Só relata o que falta (não altera nada) |
| `.\onboarding\install.ps1 -DryRun` | Simula: mostra as ações sem executar |
| `.\onboarding\install.ps1 -SkipClis` | Só configura `~/.claude` (sem instalar CLIs) |
| `.\onboarding\install.ps1 -Help` | Ajuda |

**Pré-requisito real:** `winget` (App Installer). Se faltar, o script aponta
`https://aka.ms/getwinget`.

**Deps instaladas (via winget):** PowerShell 7, git, gh, Python 3.12, uv, Node 22 LTS,
ripgrep, jq, yq, VS Code + Claude Code. É **idempotente** (pula o que já existe) e faz
**backup** antes de sobrescrever em `~/.claude`.

Detalhes e garantias: [`../onboarding/README.md`](../onboarding/README.md).

---

## 2. Config pessoal — `~/.claude`

O instalador espelha [`templates/global-claude/`](../templates/global-claude/) para
`~/.claude/` (vale para **todos** os projetos):

| Arquivo | O que é |
|---------|---------|
| `~/.claude/CLAUDE.md` | Identidade, stack preferida, convenções e autonomia git pessoais |
| `~/.claude/statusline.ps1` | HUD do Claude Code (modelo, contexto, git, tempo, tokens, custo) |
| `~/.claude/settings.json` | Liga a `statusLine` ao script — instalado por **merge** (não apaga sua config) |
| `~/.claude/statusline.theme.example` | Exemplo comentado p/ personalizar as cores da statusline |

> **`.json` = merge:** arquivos JSON são mesclados na config existente (com backup); os
> demais espelham 1:1. Para adicionar um artefato ao baseline (hook, skill, mcp), basta
> colocá-lo na posição-espelho dentro de `templates/global-claude/` — é captado sozinho.

**Personalizar a statusline.** Vem com 3 temas embutidos (`dracula` default, `onedark`,
`catppuccin`). Pra trocar ou ajustar cores/thresholds, copie o exemplo:

```powershell
Copy-Item ~/.claude/statusline.theme.example ~/.claude/statusline.theme
```

Edite o arquivo copiado — os comentários dentro dele mostram como escolher um tema
(`theme = onedark`), sobrescrever cores por role (`primary = R,G,B`) e ajustar os
limiares coloridos (`th_low`/`th_mid`/`th_high`).

### Hierarquia de contexto (quem vence)

```text
managed policy → ~/.claude/CLAUDE.md (global) → <projeto>/.claude/CLAUDE.md → <projeto>/CLAUDE.local.md
```

O **mais específico vence** (regra de projeto > regra global), **exceto** a managed policy,
que é inviolável e fica acima de tudo. Tratamento completo (loading × precedência, exemplos
de conflito) em
[`methodology/01-onboarding`](../methodology/01-onboarding/README.md#hierarquia-de-loading-precedência).

---

## 3. Criar o projeto — `new-project.ps1`

Cria um projeto novo já equipado — ou equipa um diretório existente. Espelha
[`templates/project-scaffold/`](../templates/project-scaffold/) para o destino
(`AGENTS.md`/`CLAUDE.md` na raiz, resto em `.claude/`), com a mesma idempotência, backup e
merge de `.json` do instalador.

```powershell
# Cria e equipa um projeto
.\onboarding\new-project.ps1 -Path C:\dev\meu-projeto

# No diretório atual, inicializa o git e já abre o VS Code
.\onboarding\new-project.ps1 -Path . -Git -Open

# Só verificar / simular
.\onboarding\new-project.ps1 -Path C:\dev\x -Check
.\onboarding\new-project.ps1 -Path C:\dev\x -DryRun
```

> **Pre-commit anti-segredo precisa de um repo git.** Com `-Git`, o script já aponta
> `core.hooksPath` para `.githooks/` (o pre-commit que bloqueia segredos no commit). **Sem
> `-Git`**, o projeto nasce sem repo e esse hook fica **inativo** — o script agora **avisa** e,
> depois que você rodar `git init`, basta ativar com:
> `git config core.hooksPath .githooks` (ou recriar/equipar com `-Git`).

> **Atalho global:** o `install.ps1` registra a função `New-SddProject` (alias `nsp`) no
> seu `$PROFILE` do PowerShell 7. Depois de reabrir o terminal, basta
> `nsp C:\dev\meu-projeto -Git -Open` de qualquer lugar — sem digitar o caminho do script.
> O flag `-Open` abre o VS Code no projeto ao terminar; cada projeto gerado grava
> `.claude/.scaffold-version` (commit do framework) para rastrear upgrades futuros.

O que chega no projeto:

```text
AGENTS.md            contrato canônico p/ qualquer agente (Claude, Codex…)
CLAUDE.md            aponta p/ AGENTS.md + específico do Claude Code
.claude/
├── rules/           workflow-sdd · cli-first · agent-routing · kb-taxonomy · project-context
├── commands/        /setup /brainstorm /define /design /build /ship /dev /review
├── agents/          code-reviewer · explorer · test-writer + AGENT_MAP.md (Mermaid)
├── kb/              base de conhecimento (4 camadas, começa vazia)
└── sdd/             templates das fases + features/ reports/ archive/
```

---

## 4. Inicializar o projeto — `/setup`

Abra o Claude Code na pasta do projeto e rode:

```text
/setup
```

O wizard preenche [`.claude/rules/project-context.md`](../templates/project-scaffold/.claude/rules/project-context.md)
com **stack, domínio e convenções**. Enquanto esse arquivo estiver com `status: template`,
o projeto é tratado como **não inicializado** e os agentes pedem o `/setup` antes de
executar trabalho. Depois de preenchido (`status: active`), ele vira a **fonte de verdade**
do contexto.

> **Curadoria (passo 4 do fluxo, EPIC G):** depois do `/setup`, rode **`/init`** — ele
> orquestra a especialização ponta a ponta: `/audit-agents` (gera os agentes de domínio),
> `/train-kb` (popula a KB por ondas) e `/sync-context` (ressincroniza os índices). É guiado
> (aprovação entre etapas) e resumável (pula o que já foi feito).

---

## 5. Executar com SDD

Features maiores passam por **5 fases sequenciais** (nunca pule fases sem motivo); cada fase
consome o artefato da anterior. Tarefas pequenas usam o **Dev Loop**.

| Fase | Command | Artefato gerado |
|------|---------|-----------------|
| 0. Brainstorm | `/brainstorm` | `.claude/sdd/features/BRAINSTORM_<FEATURE>.md` |
| 1. Define | `/define` | `.claude/sdd/features/DEFINE_<FEATURE>.md` (gate: Clarity Score ≥ 12/15) |
| 2. Design | `/design` | `.claude/sdd/features/DESIGN_<FEATURE>.md` |
| 3. Build | `/build` | código + `.claude/sdd/reports/BUILD_REPORT_<FEATURE>.md` |
| 4. Ship | `/ship` | `.claude/sdd/archive/<FEATURE>/SHIPPED_<DATE>.md` |

Atalhos fora do ciclo completo:

| Command | Quando |
|---------|--------|
| `/dev` | Tarefa pequena, script de um arquivo ou protótipo (sem as 5 fases) |
| `/review` | Revisar um PR (`/review <n>`) ou o diff atual da branch |

### Subagents

Para trabalho focado e independente, as fases delegam a subagents (`Agent`):

- `@explorer` — localizar código / entender arquitetura antes de implementar (read-only)
- `@test-writer` — gerar/completar testes cobrindo os Acceptance Tests do DEFINE
- `@code-reviewer` — revisar diff/PR (bugs, segurança, aderência, simplicidade)

Agentes **de domínio** não vêm no scaffold — surgem na curadoria (`/audit-agents`). O mapa
de relações fica em `.claude/agents/AGENT_MAP.md`.

### KB (base de conhecimento)

Conhecimento reutilizável em 4 camadas, em `.claude/kb/`:
`business/` (regra de negócio) · `tools/` (tecnologia em geral) · `implementation/` (o que
nós construímos) · `operations/` (runbooks). Disciplina em
[`kb-taxonomy.md`](../templates/project-scaffold/.claude/rules/kb-taxonomy.md). Começa
vazia e se enche na curadoria.

---

## Referência rápida

| Preciso de… | Onde |
|-------------|------|
| Preparar a máquina | `onboarding/install.ps1` · [README](../onboarding/README.md) |
| Criar/equipar projeto | `onboarding/new-project.ps1` |
| Contrato dos agentes | `AGENTS.md` (raiz do projeto) |
| Convenções e regras | `.claude/rules/` (workflow-sdd, cli-first, agent-routing, kb-taxonomy) |
| Visão e princípios | [`VISAO.md`](VISAO.md) |
| Especializar ao domínio | `/init` (curadoria: `/audit-agents` · `/train-kb` · `/sync-context`) |

## Convenções (resumo)

- **Conventional Commits** (`feat:`, `fix:`, `chore:`, `docs:`…), mensagens em pt-BR.
- `main` protegida: trabalho em branch de feature; merge só com confirmação explícita.
- **CLI-first:** antes de implementar na mão, verifique se uma CLI resolve (`gh`, `jq`,
  `yq`, `rg`, `uv`) — ver `.claude/rules/cli-first.md`.
- **Qualidade verificável:** nada é "pronto" sem verificação real; **não inventar dados**;
  **não versionar segredos**.

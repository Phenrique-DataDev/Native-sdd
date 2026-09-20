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
5. EXECUTAR   SDD                         → /brainstorm → /define → /spec → /build → /ship
```

> Todos os passos estão prontos. A curadoria (passo 4) é orquestrada pelo `/init`, que
> encadeia `/setup → /audit-agents → /train-kb → /sync-context` com aprovação entre etapas.

---

## 1. Preparar a máquina — `install.ps1` (Windows) · `install.sh` (Linux/macOS)

Deixa o PC pronto para dev/dados com Claude Code: instala dependências e monta o
`~/.claude` pessoal. **Windows, Linux e macOS** implementados. O runtime é o
**PowerShell 7+** em todo SO — no Linux e no macOS, o `install.sh` o instala (no macOS, deps via
Homebrew + tarball oficial do `pwsh`) e delega o miolo ao mesmo código testado do Windows. O macOS é
validado no CI, não num Mac físico: no runner arm64 `macos-26` a cada mudança e no `macos-15` sob
demanda.

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
| `.\onboarding\install.ps1 -SetDefaultShell` | **Opt-in:** torna o PowerShell 7 o shell **padrão** do Windows Terminal e dos panes do herdr |
| `.\onboarding\install.ps1 -Help` | Ajuda |

> **`-SetDefaultShell` — instalar o pwsh não faz ninguém usá-lo.** O instalador já traz o
> PowerShell 7 entre as deps, mas o Windows Terminal continua abrindo o **Windows PowerShell 5.1**
> por padrão — e é lá que você digita `nsp`, justo o runtime **não** suportado (o `new-project`
> detecta o 5.1 e se relança em pwsh). Esta flag opt-in troca o `defaultProfile` no `settings.json`
> do Windows Terminal (com **backup**, substituição cirúrgica que preserva seus comentários). Se o
> **herdr** estiver instalado, grava também `[terminal] default_shell = "pwsh.exe"` no config dele: os
> panes do herdr não herdam o shell do terminal e, no Windows, abrem no 5.1 mesmo quando você chama o
> `herdr` a partir do pwsh. Um shell que você já escolheu ali é mantido. Não
> bloqueante: qualquer falha vira aviso, nunca aborta a instalação. **Não** mexe na associação de
> arquivos `.ps1` — decisão de segurança, ver a nota em `features/BACKLOG.md` (repositório de desenvolvimento).

### Bootstrap remoto — instalar sem clonar (1 comando)

Alternativa ao fluxo clonado acima (**não** o substitui — é camada nova em cima):
`bootstrap.ps1`/`bootstrap.sh` baixam o conteúdo de `main` do espelho público via
`codeload.github.com` (zip/tar.gz, sem exigir `git`/`gh`), extraem num diretório temporário e
delegam ao `install.ps1`/`install.sh` — mesmo estado final, mesma idempotência versionada
(rodar 2× não duplica nada).

```powershell
# Windows (PowerShell 5.1+) — sem flags
irm https://raw.githubusercontent.com/Phenrique-DataDev/Native-sdd/main/onboarding/bootstrap.ps1 | iex

# com flags do install.ps1: baixa o texto, embrulha num scriptblock e aplica os parâmetros
iex "& { $(irm https://raw.githubusercontent.com/Phenrique-DataDev/Native-sdd/main/onboarding/bootstrap.ps1) } -Check"
```

```bash
# Linux — sem flags
curl -fsSL https://raw.githubusercontent.com/Phenrique-DataDev/Native-sdd/main/onboarding/bootstrap.sh | bash

# com flags do install.sh: `bash -s --` repassa os args ao script vindo do pipe
curl -fsSL https://raw.githubusercontent.com/Phenrique-DataDev/Native-sdd/main/onboarding/bootstrap.sh | bash -s -- --check
```

> **Duas URLs, papéis distintos:** as URLs acima (`raw.githubusercontent.com/...`) servem o
> **texto do script** de bootstrap — é o que você cola no terminal. Por dentro, o script baixa o
> **conteúdo do repositório** por outra URL (`codeload.github.com/Phenrique-DataDev/Native-sdd/...`).
> HTTPS em toda a cadeia; sem `sudo` oculto; o temporário é removido ao final, mesmo em falha.

> **Limitação conhecida:** não há verificação de checksum/assinatura do conteúdo baixado — a
> confiança é a mesma de qualquer instalador `curl\|bash`/`irm\|iex` (HTTPS + a URL ser realmente do
> GitHub). Se preferir, dá pra abrir o `bootstrap.ps1`/`bootstrap.sh` pela URL acima e ler antes de
> colar no terminal.

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

# Projeto que vai viver anos sob SDD: o scaffold completo (opt-in)
.\onboarding\new-project.ps1 -Path C:\dev\x -Profile full
```

> **`-Profile mvp` (default desde 2026-09-19) · `full`.** O `mvp` entrega o **núcleo**
> (`workflow-sdd`, `project-context`, `cli-first`, `tooling`), dos hooks de processo instala só o
> `curation-nudge`, e não entrega `/orchestrate`, `/max` nem as posturas que eles carregam. O `full`
> entrega tudo — **35.130 tokens** de rules always-on contra **20.843** do `mvp`, medidos com
> `tools/rules-budget.ps1`: economia de **~33k chars (~14k tokens)** por sessão.
>
> **Por que o default trocou.** Três medições independentes, e juntas elas dissolvem o trade-off que
> sustentava o `full`: em 9 tarefas pareadas ele custou **+32,9%** com obediência **idêntica** às três
> regras do núcleo (e com *menos* turnos — 26 contra 32); em fan-out de subagentes, **+40% por
> subagente**, porque 73% do bloco always-on se propaga a cada um; numa tarefa pequena, **3,6×** o
> custo para entregável equivalente. Não é "mais barato, porém menos disciplina": a disciplina medida
> é a mesma.
>
> **E o escopo do número, porque ele não vale para tudo.** O imposto é fixo e o denominador cresce —
> o overhead do `full` cai conforme a sessão fica grande:
>
> | Contexto por turno | Overhead do `full` | Leitura |
> |---|---|---|
> | 19k tok | **64%** | tarefa pequena — o regime medido |
> | 50k tok | 33% | feature pequena num repo pequeno |
> | 120k tok | 16% | feature média, vários arquivos lidos |
> | 300k tok | 6,9% | refactor amplo, sessão longa |
> | 600k tok | **3,5%** | trabalho de escala empresarial |
>
> A coluna da direita é projeção aritmética a partir das sessões medidas, não medição — e ela **não**
> cobre fan-out, onde o imposto volta como multiplicador. Em sessão grande sem fan-out, este eixo
> deixa de decidir: escolha `full` pela disciplina que você quer, não pelo custo.
>
> **O que o `mvp` NÃO corta, de propósito:** o **pre-commit anti-segredo** (`.githooks/`) continua —
> é a única peça de segurança do scaffold, e MVP é justo onde se commita segredo com pressa. O perfil
> é **gravado** em `.claude/.scaffold-version` e o `-Update` o **herda**: um `nsp <path> -Update` num
> projeto mvp não traz de volta o que foi cortado. Para migrar depois: `nsp <path> -Update -Profile full`.

> **Pre-commit anti-segredo precisa de um repo git.** Com `-Git`, o script já aponta
> `core.hooksPath` para `.githooks/` (o pre-commit que bloqueia segredos no commit). **Sem
> `-Git`**, o projeto nasce sem repo e esse hook fica **inativo** — o script agora **avisa** e,
> depois que você rodar `git init`, basta ativar com:
> `git config core.hooksPath .githooks` (ou recriar/equipar com `-Git`).

> **Atalho global:** o `install.ps1` registra a função `New-SddProject` (alias `nsp`) no
> seu `$PROFILE` do PowerShell 7. Depois de reabrir o terminal, basta
> `nsp C:\dev\meu-projeto -Git -Open` de qualquer lugar — sem digitar o caminho do script.
> O flag `-Open` abre o VS Code no projeto ao terminar; cada projeto gerado grava
> `.claude/.scaffold-version` (**versão** do template + commit do framework) — é o baseline que
> permite responder "meu projeto está quantas versões atrás?" e o que `-Update` usa para comparar.

O que chega no projeto:

```text
AGENTS.md            contrato canônico p/ qualquer agente (Claude, Codex…)
CLAUDE.md            aponta p/ AGENTS.md + específico do Claude Code
.claude/
├── rules/           workflow-sdd · cli-first · agent-routing · kb-taxonomy · project-context
├── commands/        /setup /brainstorm /define /spec /build /ship /dev /review
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
| 2. Design | `/spec` | `.claude/sdd/features/DESIGN_<FEATURE>.md` |
| 3. Build | `/build` | código + `.claude/sdd/reports/BUILD_REPORT_<FEATURE>.md` |
| 4. Ship | `/ship` | `.claude/sdd/archive/<FEATURE>/SHIPPED_<DATE>.md` |

Atalhos fora do ciclo completo:

| Command | Quando |
|---------|--------|
| `/dev` | Tarefa pequena, script de um arquivo ou protótipo (sem as 5 fases) |
| `/review` | Revisar um PR (`/review <n>`) ou o diff atual da branch |

> ### As fases SDD exigem sessão INTERATIVA — e isto é do harness, não nosso
>
> Todo artefato de fase mora em `.claude/`, e o Claude Code trata esse caminho como **arquivo
> sensível**: fora de uma sessão interativa a escrita ali é **negada**. Na prática, `claude -p
> "/define ..."` roda, produz o conteúdo certo e **não consegue gravar** — o mesmo vale para
> `/setup` e para o STATE do `/orchestrate`. Só `/dev` completa, porque escreve código normal.
>
> **Medido em 2026-09-19, quatro sessões, e as duas saídas óbvias não funcionam:**
>
> | O que se tenta | Resultado |
> |---|---|
> | `--permission-mode acceptEdits` (ou `dontAsk`) | negado |
> | `permissions.allow` no `settings.json` do projeto | **ignorado**: *"this workspace has not been trusted"* — e projeto recém-criado nunca passou pelo trust dialog |
> | idem, com o trust aceito | `Write(...)` **não é regra válida** para arquivo (*"only `Edit(path)` rules are"*); com `Edit(.claude/**)` válido, a escrita **continua negada** |
> | `--dangerously-skip-permissions` | **grava** — é o caminho documentado pelo próprio Claude Code para escrever em `.claude/` |
>
> **O que isso significa para você:** rode as fases SDD numa sessão interativa (o caminho normal).
> Se precisar de automação — agendar uma fase, rodar em lote, CI —, a flag é a saída, e a decisão de
> usá-la é **sua**: ela desliga as confirmações de tudo, não só de `.claude/`. O `/orchestrate` tem
> uma saída própria e mais barata: quando o `Write` do STATE é negado, ele **cai para
> `.sdd-orchestration/`** na raiz e anuncia o desvio, em vez de morrer no meio.
>
> **Não entregamos uma allowlist no scaffold de propósito** — seria inerte (as duas linhas do meio
> da tabela), e afrouxar escrita em `.claude/` por padrão é decisão de segurança que não cabe a um
> template tomar pelo usuário.

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

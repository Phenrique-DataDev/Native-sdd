# onboarding · Instalador automático

Deixa um PC pronto para trabalhos de dev/dados com Claude Code: instala dependências e
monta o `~/.claude` pessoal. **Windows, Linux e macOS** implementados (Linux: apt/dnf/pacman;
macOS: Homebrew + tarball oficial do `pwsh`, validado nos runners arm64 `macos-15` e `macos-26` do CI).

Entrypoints:
- **`install.ps1`** (Windows) / **`install.sh`** (Linux/macOS) — prepara a **máquina**
  (deps + `~/.claude`). O runtime do framework é o **PowerShell 7** em todo SO; no Linux o
  `install.sh` instala o `pwsh` e delega o miolo (montagem do `~/.claude`) ao mesmo código
  testado do Windows.
- **`new-project.ps1`** — cria/equipa um **projeto** com o scaffold SDD (ponte para
  `templates/project-scaffold`). Ver seção abaixo.

## Bootstrap (máquina recém-formatada)

Um PC novo costuma ter só o **Windows PowerShell 5.1** e `ExecutionPolicy` restrita. O
instalador é compatível com 5.1 e **instala o PowerShell 7** entre as deps. Rode assim
(ignora a policy só para este script, sem alterar a máquina):

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File .\onboarding\install.ps1
```

> Pré-requisito real: **winget** (App Installer). Se faltar, o script avisa e aponta
> `https://aka.ms/getwinget`.

## Uso (Windows)

```powershell
# Instalação completa (deps + Claude Code + VS Code + ~/.claude)
.\onboarding\install.ps1

# Só verificar o que falta (não altera nada)
.\onboarding\install.ps1 -Check

# Simular (mostra as ações, sem executar)
.\onboarding\install.ps1 -DryRun

# Só configurar ~/.claude (sem instalar CLIs)
.\onboarding\install.ps1 -SkipClis

# + MCP semantic-kb (busca semântica local via Ollama; opt-in)
.\onboarding\install.ps1 -WithSemanticKb
.\onboarding\install.ps1 -Check -WithSemanticKb                        # "doctor" do semantic-kb

# Ajuda
.\onboarding\install.ps1 -Help
```

## Uso (Linux)

Entrypoint POSIX `install.sh` — detecta a distro (apt/dnf/pacman), instala as deps e o
PowerShell 7, e então monta o `~/.claude` pelo mesmo miolo do Windows. Requer o repo clonado.

```bash
# Instalação completa (deps + Claude Code + ~/.claude)
bash ./onboarding/install.sh

# Só verificar / simular (não altera nada)
bash ./onboarding/install.sh --check
bash ./onboarding/install.sh --dry-run

# Só configurar ~/.claude (assume deps já instaladas)
bash ./onboarding/install.sh --skip-clis

# + suplementos por tema
bash ./onboarding/install.sh --extra-plugins --themes "design data"

# Ajuda
bash ./onboarding/linux/apply.sh --help
```

> **PowerShell 7** é dependência obrigatória (roda os tools/hooks/statusline do framework).
> Em apt/dnf vem do repositório da Microsoft; no Arch (e distros sem build oficial) cai no
> **tarball oficial do GitHub** (última versão estável, com fallback fixo se a API falhar).
> Arquiteturas: `x64`/`arm64` (arm32 não é suportado — sem build oficial do PowerShell).
> A managed policy (opt-in) escreve em `/etc/claude-code/` via `sudo`. Validado em Docker:
> `ubuntu:24.04`, `fedora:41`, `archlinux`.

## O que faz

- **A1 — dependências (via winget):** PowerShell 7, git, gh, Python 3.12, uv, Node 22 LTS,
  ripgrep, jq, yq, VS Code + Claude Code (instalador oficial). Lista fixa em
  `windows/install-clis.ps1`.
- **A2 — baseline `~/.claude` (descoberta dinâmica):** espelha `templates/global-claude/`
  para `~/.claude/`. Para adicionar um artefato ao baseline (settings, hook, skill, mcp),
  basta colocá-lo em `templates/global-claude/` na posição-espelho — é captado sozinho.
  Arquivos **`.json`** são instalados por **merge** (preservam a config existente do
  usuário); os demais são espelhados com backup.
- **A2b — shim de conveniência:** registra `New-SddProject`/`nsp` (e `sddcheck`) como atalho
  para o `new-project.ps1`/`check.ps1` — no **Windows** no `$PROFILE` do PowerShell 7; no
  **Linux** em `~/.bashrc`, `~/.zshrc` e `~/.config/fish/config.fish` (cada um só se o shell
  estiver presente; funções que chamam `pwsh`). Bloco delimitado, idempotente, com backup.
- **A2c — context7 (MCP, opcional):** registra o **context7** como MCP *user-scoped* via
  `claude mcp add --scope user` (transporte **local npx** — usa o Node já instalado), para o
  `/train-kb` puxar doc atualizada (`docs-first`). **Não bloqueante:** se faltar `claude`/`npx`
  ou o registro falhar, emite **WARN** e segue (A1/A2 intactos); idempotente (pula se já
  registrado). **API key opcional e sem segredo no repo:** se a variável de ambiente
  **`CONTEXT7_API_KEY`** existir, ela é repassada ao registro (e mascarada nos logs/`-DryRun`);
  senão registra sem key (funciona, com rate limit menor).
- **A2g — semantic-kb (MCP, opt-in via `-WithSemanticKb`):** provisiona o MCP **`semantic-kb`**
  *user-scoped* — **busca semântica local** (linguagem natural) sobre a KB, `docs/` e o histórico
  de features de um projeto, via **[Ollama](https://ollama.com) + `sqlite-vec`**. Complementa
  `Grep`/`Glob`, nunca substitui. Prepara o server versionado (`onboarding/semantic-kb/`), baixa o
  modelo de embedding (`ollama pull`, default `nomic-embed-text`, ~274MB) e registra via
  `claude mcp add`. **Opt-in de propósito** (exige Ollama + `uv`); **não bloqueante** (falha = WARN)
  e idempotente. `-SemanticKbModel` escolhe o modelo; `-SemanticKbOllamaHost` aponta a um **Ollama
  remoto**; `-Check`/`-DryRun` viram um "doctor". macOS/Linux: instalador autônomo
  [`semantic-kb/install-semantic-kb.sh`](semantic-kb/install-semantic-kb.sh). Detalhes em
  [`semantic-kb/README.md`](semantic-kb/README.md).
- **A2d — managed policy (opt-in, exige admin):** **pergunta** *"Aplicar managed policy?
  (exige admin) (altamente recomendado)"* (default: não). Aceitando, copia o
  `templates/managed-policy/managed-settings.json` para o caminho de sistema — direto se a
  sessão já está elevada, senão **eleva via UAC** só para esse passo. Idempotente (pula se
  idêntica; backup se diferir); em `-Check`/`-DryRun` só relata. Recusar/cancelar o UAC não
  quebra o install. Detalhes em [`../templates/managed-policy/`](../templates/managed-policy/).

## Garantias

- **Compatível com PowerShell 5.1+** (roda no PS padrão de um PC novo) e instala o PS 7.
- **Idempotente:** pula o que já está instalado/configurado (checa comando no PATH e winget).
- **Progresso em tempo real:** mostra `Instalando <pkg>...` e o tempo de cada etapa + total.
- **Verificação pós-install:** confirma que o comando resolve; avisa se exigir reabrir o terminal.
- **Menos UAC:** tenta `--scope user` (fallback p/ escopo padrão).
- **Backup:** salva `nome.bak-<DATA>` antes de sobrescrever em `~/.claude`.
- **Seguro:** `-Check`/`-DryRun` não alteram nada; não instala segredos.

## Novo projeto (`new-project.ps1`)

Cria um projeto novo já com o scaffold SDD — ou equipa um diretório existente. Espelha
`templates/project-scaffold/` para o destino (`CLAUDE.md` na raiz, resto em `.claude/`),
reusando as funções puras do instalador: mesma **idempotência**, **backup** e **merge de
`.json`**. O `README.md` do template (que descreve o scaffold) **não** é copiado.

```powershell
# Cria e equipa um projeto
.\onboarding\new-project.ps1 -Path C:\dev\meu-projeto

# No diretório atual, inicializa o git e já abre o VS Code
.\onboarding\new-project.ps1 -Path . -Git -Open

# Só verificar / simular (não altera nada)
.\onboarding\new-project.ps1 -Path C:\dev\x -Check
.\onboarding\new-project.ps1 -Path C:\dev\x -DryRun
```

Flags úteis: **`-Open`** (abre o VS Code no projeto ao terminar) e **`-Git`** (init +
commit inicial). Cada projeto gerado recebe **`.claude/.scaffold-version`** — versão do template
(`template_version`, ex.: `0.8.17`) + commit do framework + timestamp. A **versão** é o que serve
de baseline comparável: o commit vira `unknown` quando o framework veio por zip (sem git), e o
espelho publicado tem histórico git próprio. `-Update` lê esse marcador para dizer de onde o
projeto veio e para onde vai.

> ⚠️ **O `-Path` é relativo ao diretório atual.** Para equipar a pasta em que você **já está**, use
> **`-Path .`** — não o nome dela. Rodar `nsp meu-projeto` de **dentro** de `meu-projeto\` criaria
> `meu-projeto\meu-projeto` (projeto aninhado, raiz no lugar errado). Esse caso agora **pede
> confirmação** (e é **recusado** em modo não-interativo); use **`-AllowNested`** se a subpasta for
> mesmo o que você quer.

> **Atalho global:** o `install.ps1` registra a função **`New-SddProject`** (alias **`nsp`**)
> no `$PROFILE` do PowerShell 7 (bloco delimitado por marcadores, idempotente, com backup).
> Após reabrir o terminal: `nsp C:\dev\x -Git -Open` de qualquer diretório. A função resolve
> o framework via `$env:SDD_WORKFLOW_HOME` — reinstale se mover o clone.

Depois, abra o Claude Code no projeto e rode **`/setup`** para preencher o contexto.

## Estrutura

```
onboarding/
├── install.ps1                 (dispatcher Windows: flags + detecção de OS)
├── install.sh                  (entrypoint POSIX: uname → linux/macos)
├── new-project.ps1             (cria/equipa projeto com o scaffold SDD — A5)
├── windows/
│   ├── apply.ps1               (orquestra A1 + A2 + A2c + A2e + A2g + A2d; SO-agnóstico no miolo)
│   ├── install-clis.ps1        (deps fixas via winget + Claude Code)
│   ├── install-mcp.ps1         (context7 MCP, opcional/não bloqueante — A8)
│   ├── install-plugins.ps1     (suplementos opt-in por tema — A2e)
│   ├── install-semantic-kb.ps1 (MCP semantic-kb via Ollama, opt-in/não bloqueante — A2g)
│   └── lib.ps1                 (helpers puros, testáveis; agnósticos de SO)
├── posix/
│   ├── apply-common.sh         (orquestrador comum: flags -> A1 -> delega A2+ ao apply.ps1)
│   └── lib.sh                  (helpers comuns + tarball oficial do pwsh, linux|osx)
├── linux/
│   ├── apply.sh                (fino: chama o orquestrador comum)
│   └── install-clis.sh         (deps via apt/dnf/pacman + métodos oficiais)
├── macos/
│   ├── apply.sh                (fino: orquestrador comum + brew no PATH após o A1)
│   └── install-clis.sh         (deps via Homebrew + tarball oficial do pwsh + Claude Code)
├── semantic-kb/                (server MCP versionado + installer .sh + README)
├── tests/                      (Pester: secret-guard, secret-patterns, lib-os)
└── PSScriptAnalyzerSettings.psd1
```

## Testes / lint

```powershell
Invoke-Pester onboarding/tests
Invoke-ScriptAnalyzer -Path onboarding -Recurse -Settings onboarding/PSScriptAnalyzerSettings.psd1
```

## Pré-requisitos

- **Windows:** PowerShell 7+, winget (App Installer) e internet. Alguns installs pedem UAC.
- **Linux:** `bash`, um gerenciador suportado (apt/dnf/pacman), `sudo` (ou root) + internet.
  O onboarding garante sozinho os pré-requisitos de base (`curl`, `ca-certificates`, `tar`) e
  instala o `pwsh`. A managed policy (opt-in) pede `sudo`.

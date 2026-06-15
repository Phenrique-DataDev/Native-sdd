# onboarding · Instalador automático

Deixa um PC pronto para trabalhos de dev/dados com Claude Code: instala dependências e
monta o `~/.claude` pessoal. **Windows** implementado; macOS/Linux são stubs (D6).

Dois entrypoints:
- **`install.ps1`** — prepara a **máquina** (deps + `~/.claude`).
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

# Ajuda
.\onboarding\install.ps1 -Help
```

## O que faz

- **A1 — dependências (via winget):** PowerShell 7, git, gh, Python 3.12, uv, Node 22 LTS,
  ripgrep, jq, yq, VS Code + Claude Code (instalador oficial). Lista fixa em
  `windows/install-clis.ps1`.
- **A2 — baseline `~/.claude` (descoberta dinâmica):** espelha `templates/global-claude/`
  para `~/.claude/`. Para adicionar um artefato ao baseline (settings, hook, skill, mcp),
  basta colocá-lo em `templates/global-claude/` na posição-espelho — é captado sozinho.
  Arquivos **`.json`** são instalados por **merge** (preservam a config existente do
  usuário); os demais são espelhados com backup.
- **A2b — shim no `$PROFILE`:** registra a função `New-SddProject`/`nsp` no profile do
  PowerShell 7 (bloco delimitado, idempotente, com backup). Atalho para o `new-project.ps1`.
- **A2c — context7 (MCP, opcional):** registra o **context7** como MCP *user-scoped* via
  `claude mcp add --scope user` (transporte **local npx** — usa o Node já instalado), para o
  `/train-kb` puxar doc atualizada (`docs-first`). **Não bloqueante:** se faltar `claude`/`npx`
  ou o registro falhar, emite **WARN** e segue (A1/A2 intactos); idempotente (pula se já
  registrado). **API key opcional e sem segredo no repo:** se a variável de ambiente
  **`CONTEXT7_API_KEY`** existir, ela é repassada ao registro (e mascarada nos logs/`-DryRun`);
  senão registra sem key (funciona, com rate limit menor).
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
commit inicial). Cada projeto gerado recebe **`.claude/.scaffold-version`** (commit do
framework + timestamp), para rastrear de qual versão veio.

> **Atalho global:** o `install.ps1` registra a função **`New-SddProject`** (alias **`nsp`**)
> no `$PROFILE` do PowerShell 7 (bloco delimitado por marcadores, idempotente, com backup).
> Após reabrir o terminal: `nsp C:\dev\x -Git -Open` de qualquer diretório. A função resolve
> o framework via `$env:SDD_WORKFLOW_HOME` — reinstale se mover o clone.

Depois, abra o Claude Code no projeto e rode **`/setup`** para preencher o contexto.

## Estrutura

```
onboarding/
├── install.ps1                 (dispatcher: flags + detecção de OS)
├── new-project.ps1             (cria/equipa projeto com o scaffold SDD — A5)
├── windows/
│   ├── apply.ps1               (orquestra A1 + A2 + A2c + A2d)
│   ├── install-clis.ps1        (deps fixas + Claude Code)
│   ├── install-mcp.ps1         (context7 MCP, opcional/não bloqueante — A8)
│   └── lib.ps1                 (helpers puros, testáveis)
├── macos/apply.sh, linux/apply.sh   (stubs — D6)
├── tests/lib.Tests.ps1         (Pester)
└── PSScriptAnalyzerSettings.psd1
```

## Testes / lint

```powershell
Invoke-Pester onboarding/tests
Invoke-ScriptAnalyzer -Path onboarding -Recurse -Settings onboarding/PSScriptAnalyzerSettings.psd1
```

## Pré-requisitos

PowerShell 7+, winget (App Installer) e internet. Alguns installs podem pedir elevação (UAC).

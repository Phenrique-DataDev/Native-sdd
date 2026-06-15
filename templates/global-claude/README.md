# global-claude · Config pessoal de nível usuário

Conteúdo que vai para `~/.claude/` (aplica-se a **todos** os projetos).

| Arquivo | Destino | O que é |
|---------|---------|---------|
| `CLAUDE.md` | `~/.claude/CLAUDE.md` | Identidade, stack, convenções e autonomia git pessoais |
| `statusline.ps1` | `~/.claude/statusline.ps1` | HUD do Claude Code (2 linhas: modelo, contexto, git, dir, tempo, tokens, custo) |
| `hooks/main-push-guard.ps1` | `~/.claude/hooks/main-push-guard.ps1` | Hook `PreToolUse` (C6): guard determinístico de push na branch default |
| `hooks/secret-guard.ps1` | `~/.claude/hooks/secret-guard.ps1` | Hook `PreToolUse`: `ask` em commit/push com segredo e ao ler `.env`/chave via Bash |
| `hooks/lib/secret-patterns.ps1` | `~/.claude/hooks/lib/secret-patterns.ps1` | **Fonte única** de detecção de segredos (regex + paths), compartilhada por hooks e pre-commit |
| `settings.json` | `~/.claude/settings.json` | Liga `statusLine` + `permissions.defaultMode` + `hooks.PreToolUse` aos scripts (instalado por **merge**, sem apagar sua config) |

> **`.json` = merge:** o instalador mescla `settings.json` na sua config existente (com
> backup), em vez de sobrescrever. Os demais arquivos espelham 1:1.

## Statusline

Mostra no rodapé do Claude Code: modelo · git (branch +staged ~modified ?untracked) · dir ·
versão (linha 1); barra de contexto + % · tokens do contexto/limite · tempo de sessão ·
tokens totais · custo (linha 2). Cores Dracula. Roda via `pwsh` (instalado no A1).

## Docs-push guard (hook PreToolUse · C6)

`hooks/main-push-guard.ps1` é um hook **`PreToolUse`** (matcher `Bash`) que torna a proteção da
branch default **determinística** — em vez de só regra textual no `CLAUDE.md`:

| Situação (comando `git push`) | Decisão |
|-------------------------------|---------|
| Branch ≠ default, **ou** comando não é `git push` | **passthrough** (zero interferência) |
| Na default, push **somente-docs** (`*.md` ou `docs/`/`methodology/`/`features/`) | **`allow`** (sem confirmar) |
| Na default, push com **≥1 arquivo não-doc** | **`ask`** (cai na confirmação, com a lista) |

**Fail-safe assimétrico:** antes de confirmar "push na default", qualquer erro vira passthrough;
depois, vira `ask` — nunca `allow` por engano. Só inspeciona o comando (regex) e roda git
**read-only** (`rev-parse`/`symbolic-ref`/`diff --name-only`); nunca executa o comando nem lê
conteúdo de arquivos.

> **Limitação do merge (`settings.json`):** o instalador mescla objetos, mas **arrays substituem**.
> Se você já tiver um `hooks.PreToolUse` próprio em `~/.claude/settings.json`, o merge do baseline
> o **sobrescreve** (com backup). Reaplique seus hooks manualmente após o merge, se for o caso.

## Secret guard (hook PreToolUse) — segredo em modo `ask`

`hooks/secret-guard.ps1` é o irmão do push-guard: não bloqueia, só **pede confirmação** quando
detecta possível segredo. Filosofia *educar, não barrar*.

| Situação (comando Bash) | Decisão |
|-------------------------|---------|
| Lê/exfiltra arquivo de segredo (`cat .env`, `*.pem`, `secrets/…`) | **`ask`** — fecha o bypass do `Read(.env)` da managed policy |
| `git commit` cujo **diff staged** contém segredo de **alta confiança** | **`ask`** |
| `git push` cujo **diff a enviar** contém segredo de **alta confiança** | **`ask`** |
| Qualquer outro caso | **passthrough** |

> Commit/push usam confiança **`High`** (mesmo nível do pre-commit): só formatos específicos
> de credencial (`AKIA…`, `gh?_…`, `BEGIN PRIVATE KEY`, JWT). Assignments genéricos (`token = "…"`)
> **não** viram prompt aqui — evita falso-positivo em config/docs/testes. A leitura de `.env`/chave
> pede confirmação independente de confiança.

Mesmo **fail-safe assimétrico** do push-guard. A detecção vem da **lib única**
`hooks/lib/secret-patterns.ps1` — a mesma consumida pelo git **pre-commit** do scaffold
(`.githooks/secret-scan.ps1`), que aí sim **bloqueia** o commit (rede determinística). Não há
dupla fonte de verdade: regex e paths de segredo vivem num só lugar.

## Modo de permissão (`permissions.defaultMode`)

`settings.json` define `defaultMode: "auto"` — **menos prompts** no Bash geral, priorizando o
fluxo. As redes de segurança que importam **não** são o prompt: os **hooks `PreToolUse`**
(`main-push-guard`, `secret-guard`) **disparam em qualquer modo** e seu `ask`/`deny` **sobrepõe**
a auto-aprovação, e a *managed policy* nega o catastrófico/segredos de forma inviolável. Assim o
`auto` reduz o atrito sem desligar a proteção de push/segredo.

> **Risco residual:** o comportamento exato de `auto` **não está documentado** (adotado com risco
> assumido) e o **destrutivo não-git** (`rm -rf` arbitrário, `curl|sh`) fica sem rede determinística
> — fechamento robusto = um `destructive-guard` hook (candidato a feature). Para travar mais, use
> `acceptEdits` (pergunta no sensível) ou `dontAsk` (default-deny); para afrouxar tudo,
> `bypassPermissions` (nunca pergunta — **sem** rede).

## Como instalar (manual)

```powershell
Copy-Item .\CLAUDE.md "$env:USERPROFILE\.claude\CLAUDE.md"
```

> O instalador automático (`onboarding/`, feature A2) fará isso — com backup do arquivo
> existente antes de sobrescrever.

## Hierarquia de loading

`managed policy → este arquivo (global) → projeto/.claude/CLAUDE.md → projeto/CLAUDE.local.md`

O mais específico vence: regras de projeto têm precedência sobre as globais.

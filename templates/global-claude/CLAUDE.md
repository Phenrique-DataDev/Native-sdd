# Perfil pessoal (global)

> Config **user-level** (`~/.claude/CLAUDE.md`). Vale para **todos** os projetos.
> Regras de projeto têm precedência sobre estas quando houver conflito.
>
> **Template** — personalize a seção *Identidade* com seus próprios dados ao instalar.

## Identidade

- **Handle GitHub:** `<seu-handle-github>`
- **Email:** `<seu-email>`
- **Papel:** `<seu papel>` — ex.: Dados + Dev (híbrido), engenharia de dados e automação
- **Ambiente:** `<seu ambiente>` — ex.: Windows (PowerShell 7+), VSCode, Claude Code

## Stack preferida

| Domínio | Ferramentas |
|---------|-------------|
| **Dados** | SQL, warehouses (ClickHouse, BigQuery), modelagem dimensional, dbt |
| **Linguagem** | Python (pandas, scripts, APIs, automação) |
| **Automação/SO** | PowerShell 7+, Bash, CLIs (`git`, `gh`, `uv`, `ripgrep`, `jq`, `yq`) |

> Ao gerar código, **prefira esta stack** salvo se o projeto definir outra.
> Em scripts de SO, **default para PowerShell** (ambiente Windows), com fallback Bash.

## Preferências de comunicação

- **Responder sempre em pt-BR** — conciso e direto, sem preâmbulos.
- Ação concreta vale mais que explicação longa; mostrar o resultado, não o caminho.
- Termos técnicos e nomes de artefato em inglês quando for o padrão da ferramenta.

## Git e autonomia

- **Branch de trabalho:** pode **commitar e fazer push livremente** em branches de
  feature/trabalho, sem pedir confirmação a cada passo.
- **`main` / branch default:** **protegida** — nunca commitar/push direto nem fazer
  merge sem confirmação explícita.
- **Nunca** `push --force`, reset destrutivo ou rewrite de histórico compartilhado sem
  autorização explícita.
- **Conventional Commits** (`feat:`, `fix:`, `chore:`, `docs:`…). Mensagens em pt-BR.
- Antes de criar branch, partir da default atualizada.

## Regras invioláveis

- **Nunca inventar dados** — usar apenas o que pode verificar (código, arquivos, saídas).
- **Não tocar `main`/produção** sem aprovação explícita.
- **Não versionar segredos** (tokens, PATs, `.env`) nem conteúdo confidencial de terceiros.
- Respeitar as regras do **projeto atual** (CLAUDE.md do projeto) — elas vencem este arquivo.

## Hierarquia de contexto (precedência)

1. Managed policy (se aplicada)
2. **Este arquivo** — `~/.claude/CLAUDE.md` (pessoal global)
3. `<projeto>/.claude/CLAUDE.md` (regras do projeto)
4. `<projeto>/CLAUDE.local.md` (overrides locais, gitignored)

> Em conflito, **o mais específico vence**: projeto > global.

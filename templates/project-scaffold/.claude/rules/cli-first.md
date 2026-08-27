# CLI-first — verificar CLIs antes de agir

> **Otimização.** Antes de implementar algo na mão (script ad-hoc, parsing manual, chamada
> HTTP custom), verifique se uma **CLI já disponível** resolve. Menos código, mais rápido,
> já testado e mantido por terceiros.

## Princípio

Antes de qualquer ação não-trivial, pergunte: *"existe uma CLI para isto?"*. Se existir e
estiver instalada, **prefira-a** a reimplementar a lógica.

## CLIs esperadas no ambiente

Instaladas pelo onboarding (`onboarding/install.ps1`):

| Tarefa | CLI preferida | Em vez de |
|--------|---------------|-----------|
| GitHub (PRs, issues, releases, API) | `gh` | chamadas HTTP manuais |
| Manipular JSON | `jq` | parsing por regex / string |
| Manipular YAML | `yq` | parsing manual |
| Buscar em código | `rg` (ripgrep) | loops de leitura de arquivo |
| Git | `git` | reimplementar plumbing |
| Python: deps / venv / runner | `uv` | `pip`/`venv` na mão |
| Node | `node` / `npm` | — |

## Como aplicar

1. **Verifique disponibilidade** antes de usar:
   - PowerShell: `Get-Command <cli> -ErrorAction SilentlyContinue`
   - Bash: `command -v <cli>`
2. **Use a CLI** no lugar de reimplementar (ex.: `gh` para GitHub, `jq`/`yq` para JSON/YAML,
   `rg` para busca em código).
3. **Não invente flags.** Em dúvida, confirme com `--help` antes de rodar.
4. **Se a CLI não existir**, registre a lacuna (candidata a virar dependência do onboarding)
   **antes** de cair no fallback manual — não silenciosamente reimplemente.

## O que NÃO fazer

- Não parsear JSON/YAML com regex quando há `jq`/`yq`.
- Não montar requisições à API do GitHub quando `gh` resolve.
- Não escrever loops de busca quando `rg` faz em uma linha.

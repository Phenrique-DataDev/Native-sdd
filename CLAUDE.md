# CLAUDE.md

> **Fonte principal: [`AGENTS.md`](AGENTS.md)** — o contrato canônico para quem abre este
> repositório (onboarding/framework). Este arquivo carrega o `AGENTS.md` e só acrescenta o que é
> específico do **Claude Code**. Complementa também o seu `~/.claude/CLAUDE.md` pessoal (**este
> arquivo, mais específico, vence** em caso de conflito).

@AGENTS.md

---

## Específico do Claude Code

- **Ofereça os opcionais via `AskUserQuestion`** (não em texto corrido) — é a forma que deixa o
  usuário escolher "todos"/"nenhum"/um subconjunto dos temas do catálogo sem precisar digitar
  flag nenhuma.
- **CLI-first:** antes de rodar algo na mão, confira se o próprio `install.ps1`/`new-project.ps1`
  já resolve com uma flag (`-Check`, `-DryRun`, `-Themes`) em vez de improvisar um script novo.
- Sempre confira a **Guarda de escopo** do `AGENTS.md` primeiro — se a sessão está de fato dentro
  de um projeto scaffolded (aninhado ou não), este arquivo não rege, o do projeto rege.
- Se o pedido for sobre **desenvolver o próprio framework** (não onboarding, e a Guarda de escopo
  confirma que você está na raiz certa): veja `features/BACKLOG.md` e `.claude/sdd/` (só existem no
  repositório de desenvolvimento, não no template distribuído).

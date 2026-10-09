# templates · Reutilizáveis

Biblioteca de artefatos prontos para reusar em novos projetos. O instalador
(`../onboarding/`) copia estes templates para o destino certo.

| Pasta | O que é | Destino |
|-------|---------|---------|
| `global-claude/` | Config pessoal de nível usuário (CLAUDE.md global) | `~/.claude/` — espelhada por INTEIRO em todo `install.ps1` |
| `project-scaffold/` | Scaffold SDD por projeto (CLAUDE.md + `.claude/` com rules, commands, templates de fase) | raiz de cada projeto |
| `supplements/skills/` | Skills autorais do repertório de suplementos (`Type: skill` em `tools/supplements.psd1`) | `~/.claude/skills/<nome>` — **opt-in**, só via `/supplements`/`-ExtraPlugins` (nunca espelhada no `install.ps1` comum) |

> `supplements/skills/` é **separada** de `global-claude/` de propósito: tudo em `global-claude/` vai
> pra `~/.claude/` em qualquer instalação; uma skill de suplemento só instala sob demanda (tema
> escolhido), então não pode estar dentro da árvore sempre-espelhada.

## project-scaffold (SDD)

Entrega um `.claude/` pronto para rodar **Spec-Driven Development**:

- `rules/` — 12 regras: 10 sempre-ativas e 2 de área (`paths:`, entram ao ler arquivo da área). O perfil `mvp` (default) entrega as 5 do núcleo e as 2 de área
- `postures/` — 8 disciplinas carregadas **sob demanda** (0 token até um command ou rule mandar lê-las)
- `commands/` — 30 slash commands auto-contidos (5 fases SDD + curadoria, execução, KB, observabilidade…)
- `skills/` — 5 skills (`decision-preview`, `grill-me`, `handoff`, `page-to-markdown`, `visual-check`)
- `agents/` — 11 experts de papel genéricos
- `sdd/templates/` — templates das 5 fases (BRAINSTORM → DEFINE → DESIGN → BUILD_REPORT → SHIPPED)

Ver `project-scaffold/README.md` para detalhes de uso.

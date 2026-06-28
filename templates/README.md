# templates · Reutilizáveis

Biblioteca de artefatos prontos para reusar em novos projetos. O instalador
(`../onboarding/`) copia estes templates para o destino certo.

| Pasta | O que é | Destino |
|-------|---------|---------|
| `global-claude/` | Config pessoal de nível usuário (CLAUDE.md global) | `~/.claude/` |
| `project-scaffold/` | Scaffold SDD por projeto (CLAUDE.md + `.claude/` com rules, commands, templates de fase) | raiz de cada projeto |

## project-scaffold (SDD)

Entrega um `.claude/` pronto para rodar **Spec-Driven Development**:

- `rules/` — 15 regras sempre-ativas (workflow SDD, roteamento de subagents, orquestração, posturas opt-in, taxonomia da KB…)
- `commands/` — 29 slash commands auto-contidos (5 fases SDD + curadoria, execução, KB, observabilidade…)
- `sdd/templates/` — templates das 5 fases (BRAINSTORM → DEFINE → DESIGN → BUILD_REPORT → SHIPPED)

Ver `project-scaffold/README.md` para detalhes de uso.

# templates · Reutilizáveis

Biblioteca de artefatos prontos para reusar em novos projetos. O instalador
(`../onboarding/`) copia estes templates para o destino certo.

| Pasta | O que é | Destino |
|-------|---------|---------|
| `global-claude/` | Config pessoal de nível usuário (CLAUDE.md global) | `~/.claude/` |
| `project-scaffold/` | Scaffold SDD por projeto (CLAUDE.md + `.claude/` com rules, commands, templates de fase) | raiz de cada projeto |

## project-scaffold (SDD)

Entrega um `.claude/` pronto para rodar **Spec-Driven Development**:

- `rules/` — workflow-sdd, agent-routing (catálogo de subagents: B4), kb-taxonomy, project-context
- `commands/` — `/setup`, `/brainstorm`, `/define`, `/design`, `/build`, `/ship`, `/dev`, `/review`
- `sdd/templates/` — templates das 5 fases (BRAINSTORM → DEFINE → DESIGN → BUILD_REPORT → SHIPPED)

Ver `project-scaffold/README.md` para detalhes de uso.

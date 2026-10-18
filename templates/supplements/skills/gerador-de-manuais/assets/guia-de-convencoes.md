# Guia de convenções / contribuição — <nome do projeto>

> Estrutura: CONTRIBUTING.md best practices + The Good Docs Project (contributing-guide). Toda
> convenção de código precisa do par certo/errado lado a lado — descrição em prosa sozinha não é
> seguida.

## Escopo
<O que este guia cobre (código? commits? PRs? os três?) e para quem é (contribuidor externo?
time interno?).>

## Antes de contribuir
- [ ] <setup do ambiente — link para instruções, não repita aqui>
- [ ] <como rodar os testes>
- [ ] <Code of Conduct, se houver — link>

## Convenções de código
> Cada convenção = regra + **1 exemplo certo e 1 errado**, lado a lado.

### <Categoria — ex.: nomenclatura>
**✅ Faça:**
```
<snippet real que segue a convenção>
```
**❌ Não faça:**
```
<snippet real que a viola>
```
**Por quê:** <motivo — não é gosto, é razão concreta>

<!-- repita por categoria: estrutura de arquivo, formatação, comentários, tratamento de erro... -->

## Enforcement automatizado (o que faz o guia ser seguido)
> Regra que depende de disciplina humana é ignorada — *"human willpower is scarce; automation is
> reliable"*. Cada convenção acima deve ter, sempre que expressável por padrão, uma **checagem que a
> cobre sozinha**. O `.md` documenta o *porquê*; a máquina cobra o *o quê*.

| Regra | Ferramenta que a cobra | Onde roda | Motivo + link |
|-------|------------------------|-----------|----------------|
| <ex.: formatação> | <ex.: Prettier/Black> | IDE (on-save) + CI | <link para a doc da regra> |
| <ex.: lint de estilo> | <ex.: ESLint/Ruff> | IDE + CI (bloqueante) | <link> |
| <ex.: mensagem de commit> | <ex.: commitlint> | pre-commit hook + CI | <link> |

- **IDE antes do CI:** avisar no editor (on-save) é menos disruptivo que falhar no CI — o dev corrige no
  fluxo, não depois de bloqueado. Falha só no CI empurra o dev a contornar (`eslint-disable` espalhado).
- **Motivo + link por regra:** sem o *porquê*, a regra é vista como punitiva e é contornada; comunique o
  valor e aponte a doc.
- **CODEOWNERS** (`.github/CODEOWNERS`): distribui review e evita silo de conhecimento — dono automático
  por área do código.
- **Template de PR** (`.github/pull_request_template.md`): torna a convenção visível **no envio** (checklist
  do que o PR precisa cumprir), não só neste guia.
- **Buy-in do time:** regra decidida sem quem a segue ter voz gera atrito — acorde a convenção com o time,
  não a imponha de cima.
- **Limite da automação:** o linter só pega o que vira **padrão**; regra que exige julgamento (design,
  nomes semânticos) fica com o **review humano** — não finja que o linter cobre tudo.

## Fluxo de contribuição
1. <branch a partir de onde — ex.: sempre da main atualizada>
2. <convenção de commit — ex.: Conventional Commits, mensagem em que idioma>
3. <como abrir o PR — template, descrição mínima exigida>
4. <critério de review — quem aprova, o que é bloqueante>

## Padrão de commit
| Tipo | Quando usar | Exemplo |
|------|-------------|---------|
| `feat:` | funcionalidade nova | `feat: adiciona export CSV` |
| `fix:` | correção de bug | `fix: corrige timezone no relatório` |
| `docs:` | só documentação | `docs: atualiza README de setup` |

## Faça / não faça (resumo)
| Faça | Não faça |
|------|----------|
| <regra concreta> | <anti-padrão concreto> |

## Como propor mudança a este guia
<Processo — PR neste arquivo, discussão em issue, etc. Guia de convenções também evolui; registre
quem decide.>

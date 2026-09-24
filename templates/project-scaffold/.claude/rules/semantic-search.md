# Semantic-search — achar prosa por significado (catálogo primeiro)

> **Regra condicional.** Vale quando a pergunta é em **linguagem natural** sobre a prosa acumulada
> do projeto (KB, `docs/`, `archive/`) e você **não sabe o termo exato**. A disciplina completa não é
> always-on: vive em [`../postures/semantic-search.md`](../postures/semantic-search.md) e é lida
> quando o predicado abaixo é verdadeiro.

## Predicado observável

**A pergunta é sobre uma decisão ou contexto registrado em prosa, e você não tem o nome exato
(arquivo, símbolo, `id`)?**

| Resposta | O que fazer |
|----------|-------------|
| **Não**: você sabe o nome exato, busca **código-fonte** ou filtra campo estruturado (`layer`/`domain`) | `Grep`/`Glob`/filtro exato, que são mais precisos aqui. **Pare aqui.** |
| **Sim** | **Leia** `.claude/postures/semantic-search.md` antes da primeira busca da sessão. |

## O mínimo que vale mesmo sem ler a postura

- **Catálogo primeiro, `Grep` depois.** Leia os catálogos gerados (`.claude/sdd/archive/_index.md`,
  uma linha por feature; `docs/_index.md`; `.claude/kb/_index.yaml`) e escolha pelo **significado**:
  a pergunta é paráfrase e raramente usa as palavras do texto.
- **A resposta é o caminho, não a linha do catálogo.** Confirme lendo o começo do arquivo antes de
  citar.

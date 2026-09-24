# Taxonomia da KB — 4 camadas

> Base de conhecimento opcional do projeto, em `.claude/kb/`. Cada arquivo pertence a
> **exatamente uma** camada — a camada responde a um *tipo* de pergunta. (Templates de KB
> e bootstrap entram na feature **B5**; esta regra define a disciplina.)

## As 4 camadas

| Camada | Pergunta principal | O que vive aqui |
|--------|-------------------|-----------------|
| **business/** | *Qual é a regra de negócio / métrica?* | KPIs, glossário, políticas de produto |
| **tools/** | *Como funciona esta tecnologia em geral?* | Docs agnósticas de fornecedor (ex.: SQL, Python, dbt, warehouse) |
| **implementation/** | *O que **nós** construímos/configuramos?* | Schemas, URLs internas, IDs, nomes concretos da nossa instância |
| **operations/** | *Como rodo, reinicio ou recupero?* | Runbooks, playbooks de incidente |

## Disciplina

1. **Identifique a camada primeiro.** Diga a camada explicitamente quando não for óbvia.
2. **Respostas multi-camada:** use cabeçalhos `### Negócio`, `### Ferramenta`,
   `### Implementação`, `### Operação` em vez de misturar tudo num bloco.
3. **Não misture** regra de negócio com detalhe de implementação no mesmo parágrafo.
4. **Pare e cite esta regra** se estiver prestes a pôr conteúdo na camada errada.

## Caminho canônico

`.claude/kb/<camada>/<domínio>/<tipo>/<arquivo>.md` — ex.:
`.claude/kb/tools/sql/patterns/window-functions.md`. Não use layouts planos sem camada.

## Antes de ESCREVER na KB — leia o contrato

Tudo acima serve para **ler** a KB e **rotear** conhecimento. Para **criar ou editar** uma entrada há
um contrato adicional (frontmatter obrigatório, proveniência, orçamento de tamanho, povoamento por
ondas) que **não é always-on**: **leia** `.claude/postures/kb-writing.md` (ferramenta `Read`) antes de
escrever. Os commands que escrevem na KB (`/train-kb`, `/learn`, `/reflect`) já o carregam.

**Predicado:** a KB deste projeto tem entradas? (`.claude/kb/_index.yaml` com ≥1 domínio, ou arquivos
reais sob `.claude/kb/<camada>/`.) Se **não** — o estado de todo projeto novo — não há o que consultar
nem consolidar; a KB se povoa por `/train-kb`, e só então a disciplina de leitura acima passa a ter
objeto.

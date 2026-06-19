# inbox/ — Entrada do projeto

> Pasta de **entrada** para o que **chega de fora**: specs, planilhas, solicitações,
> rascunhos, exports, qualquer insumo que ainda não virou trabalho. É o ponto de pouso —
> dali o conteúdo é triado para virar feature (SDD) ou tarefa (Dev Loop).

## Para que serve

- Specs/PRDs/solicitações que chegam de terceiros, planilhas, dumps, anexos.
- Material bruto que você vai processar, mover ou descartar — **não** é onde o projeto mora.

## O que NÃO é

| Não confundir com | Onde isso vive |
|-------------------|----------------|
| Artefatos SDD gerados (BRAINSTORM/DEFINE/DESIGN/BUILD/SHIPPED) | `.claude/sdd/` |
| Conhecimento curado e reutilizável do domínio | `.claude/kb/` |
| O código/dados do projeto em si | a **raiz** é o seu workspace — organize conforme a sua stack |

## Convenção

A **raiz do projeto é o workspace**: ponha código, dados e docs na estrutura que a sua
stack pedir (ex.: `src/`, `tests/`, `models/`, `data/`). O `inbox/` é só a antessala do
que ainda vai ser triado — esvazie-o conforme processa. A meta-camada (`.claude/`,
`AGENTS.md`, `CLAUDE.md`) é separada e cuida do *como trabalhar*, não do *trabalho*.

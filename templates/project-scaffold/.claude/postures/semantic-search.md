# Busca por significado — disciplina completa (sob demanda)

> **Carregada sob demanda**, não always-on. A rule [`../rules/semantic-search.md`](../rules/semantic-search.md)
> guarda o **predicado** (pergunta em linguagem natural sobre prosa, sem o termo exato?) e manda ler
> este arquivo antes da primeira busca da sessão. Custo numa sessão que não faz nenhuma: **0 token**.

## Princípio

`Grep`/`Glob` são ótimos quando você sabe o termo exato. Prosa acumulada ao longo de muitos ciclos SDD
cresce em volume e vocabulário, e uma pergunta como *"onde decidimos usar X em vez de Y?"* pode não
bater em nenhuma palavra-chave previsível. O que resolve não é um índice de vetores: é o **catálogo**
(uma linha por feature ou doc, gerado pelo `/sync-context`), lido inteiro pelo próprio modelo, que
casa significado melhor do que um embedding do documento inteiro.

## Corpus

`.claude/kb/`, `docs/` e `.claude/sdd/archive/`. Fora disso esta postura não se aplica: código-fonte,
commands e rules se buscam com `Grep`/`Glob`.

## Os catálogos (gerados — não editar à mão)

| Catálogo | Uma linha por | Quem regenera |
|----------|---------------|---------------|
| `.claude/sdd/archive/_index.md` | feature arquivada: link + título + resumo do `SHIPPED_*` (senão do `DEFINE_*`) | `/sync-context` (`Invoke-Resync`). O `/ship` o deixa stale e o passo 6 dele regenera |
| `docs/_index.md` | doc de `docs/`: link + título | idem |
| `.claude/kb/_index.yaml` | domínio da KB: camada, entradas | idem |

## Como aplicar

1. **Leia os catálogos inteiros.** São curtos: cerca de uma linha por item.
2. **Escolha de 3 a 8 candidatos pelo significado** da pergunta, não por palavras iguais.
3. **Confirme lendo o começo** de cada candidato (~40 linhas: `DEFINE`/`SHIPPED`, ou o topo do doc).
4. **Só se nenhum servir:** `Grep` com variantes (sinônimos, português e inglês, nomes prováveis de
   comando ou arquivo), dentro do corpus.
5. **Responda com caminhos**, do mais para o menos relevante. Trecho, só depois de ler o arquivo.

**Catálogo desatualizado** (uma feature nova não aparece)? `Invoke-Resync -Check` diz se há drift, e
`/sync-context` regenera.

## Quando NÃO aplica (siga com `Grep`/`Glob`)

| Sinal | Exemplo |
|-------|---------|
| Você sabe o **nome exato** do arquivo, símbolo ou função | `Get-KbInventory`, `adapt.md`, um `id` de KB |
| Busca em **código-fonte** (`tools/*.ps1`, `.claude/commands/`) | fora do corpus |
| Consulta por **campo estruturado** da KB (`layer`/`domain`) | o filtro exato (`Get-KbInventory`) é mais preciso |

## O que NÃO fazer

- **Não pule o catálogo** indo direto ao `Grep`: medido, sem ele o documento certo apareceu no top-5
  em 4/9 perguntas; com ele, em 9/9.
- **Não devolva caminho fora do corpus** (`AGENTS.md`, `README.md`, `tools/`) como resposta a uma
  pergunta sobre decisão registrada. Foi o erro que sobrou na medição.
- **Não cite a linha do catálogo como se fosse o conteúdo.** Ela é ponteiro: leia o arquivo.
- **Não edite o catálogo à mão.** É gerado, e a próxima regeneração desfaria a edição.

## Registro da medição (2026-09-11)

A busca por significado dependia do MCP `semantic-kb` (Ollama + `nomic-embed-text` + `sqlite-vec`),
opt-in do onboarding. Antes de removê-lo, o archive e o `docs/` do próprio framework (329 arquivos)
viraram banco de teste: 9 perguntas **parafraseadas**, sem as palavras-chave das features-alvo.
Conta como acerto qualquer arquivo da pasta da feature certa.

| Método | top-1 | top-5 |
|--------|-------|-------|
| MCP `semantic-kb` (um vetor por arquivo) | 1/9 | 2/9 |
| `Grep` com variantes, sem catálogo | 3/9 | 4/9 |
| **Catálogo + leitura + `Grep` de fallback** | **5/9** | **9/9** |

- **Por que o MCP perdia:** 225 dos 329 arquivos passavam do limite de contexto do modelo de
  embedding e ficavam **fora do índice**, entre eles quase todos os `DEFINE`. E onde o alvo foi
  indexado, o vetor do documento inteiro diluía o assunto: as distâncias ficavam todas entre 13 e 15.
- **Como os braços sem MCP rodaram:** sessões `claude -p` isoladas, com Haiku e só `Read`/`Grep`/`Glob`.
  Com o catálogo, cada pergunta levou de 5 a 20 turnos (contra 13 a 42 sem ele), por ~US$ 0,09.
- **O catálogo não foi escrito para passar no teste:** as linhas vêm do título e do resumo do
  `SHIPPED`, não da seção "Problema" de onde as perguntas foram parafraseadas.
- **Limites:** n=9, um corpus, um modelo (Haiku) e um gabarito escrito por quem desenhou o método.

# Sistemas com LLM — o porquê dos padrões (sob demanda)

> **Carregada sob demanda**, não always-on. O [`/spec`](../commands/spec.md) manda ler este arquivo
> quando o DEFINE da feature diz `Componente LLM` = sim; o [`/audit-agents`](../commands/audit-agents.md)
> o usa como lente ao gerar um agente de IA/LLM/RAG. Custo numa sessão sem componente LLM: **0 token**.
> Detalhe de provedor (API, parâmetros, structured output, cache, preço) **não** mora aqui: consulte a
> doc atual pelo `context7` ([`docs-first`](../rules/docs-first.md)), seja qual for o provedor.

## A escada: suba um degrau só quando o de baixo reprovar no Eval Set

1. **Chamada única aumentada** — um prompt, com retrieval/tools/exemplos se precisar.
2. **Workflow fixo** — *chain* (passo a passo com portão entre eles), *routing* (classificar e
   despachar) ou *parallel* (seções independentes). O caminho é do código, não do modelo.
3. **Evaluator-optimizer** — gerar, avaliar contra critério explícito, refinar, com teto de rodadas.
4. **Agente** — o modelo escolhe o próximo passo e a tool, num laço com limite de passos.
5. **Multiagente** — vários agentes com contexto próprio e um coordenador.

Cada degrau custa mais tokens, mais latência e mais modos de falha que o anterior. **A justificativa
de subir é um número do `## Eval Set` do DEFINE** (o degrau de baixo ficou abaixo do limiar), não a
impressão de que o problema "é complexo". O baseline do Eval Set é, por construção, o degrau mais
simples que alguém consideraria. **Um roteador também é um componente LLM:** a classificação dele
entra no Eval Set com casos próprios, porque rota errada derruba tudo o que vem depois.

## O que este framework mediu em si mesmo

Medições no desenvolvimento do próprio framework, com o modelo como executor de código. **n=1 por
carga, um juiz, um modelo:** servem de ordem de grandeza para desconfiar de mais agentes, não de
número para o seu sistema.

| Data | Comparação | Resultado |
|------|-----------|-----------|
| 2026-08-11 | solo · 3 rodadas em sequência · orquestrado, carga que cabia num contexto | mesmo 19/20 num juiz cego, a **1× · 2,9× · 5,1×** os tokens |
| 2026-08-11 | sequencial × paralelo, 8 tarefas nos mesmos 2 arquivos | mesmo 26/26; o paralelo levou metade do tempo por **~7×** os tokens |
| 2026-08 (seis rodadas) | executor sozinho × executor + 1 revisor de contexto limpo | o revisor **comprou** checks, a **~2,4×** (~4× se ele também corrigir) |

O que sobrevive das três: mais agentes não compraram qualidade; um **avaliador separado** comprou.

## Padrões e as armadilhas de cada um

- **Voting (N amostras e agregação)** só funciona com votantes **heterogêneos** (prompt, modelo ou
  temperatura diferentes) e uma regra de agregação **explícita** (maioria, unanimidade, limiar). N
  cópias do mesmo prompt erram juntas: o placar acima repetiu igual com N vezes o custo.
- **Avaliador separado ou determinístico em vez de autocrítica.** Pedir ao mesmo modelo, no mesmo
  contexto, que revise a própria saída tende a confirmá-la. Prefira, nesta ordem: checagem
  determinística (parser, schema, regra, execução) → rubrica → outro modelo como juiz. É a mesma
  preferência do juiz do Eval Set.
- **Validação de schema é pós-hoc.** Pydantic (ou equivalente) diz que a saída veio errada, não
  impede que venha: o design precisa do que acontece depois (retry com o erro no prompt, com teto;
  fallback; erro tipado). Structured output do provedor reduz a taxa, não a zera: confira na doc.
- **Schema não mitiga injeção.** Um JSON válido pode carregar uma instrução maliciosa num campo de
  texto. Saída do modelo, documento recuperado e resultado de tool são **input não confiável** em
  qualquer sink (SQL, shell, HTML, outra chamada de modelo, ação com efeito).
- **Tool com efeito colateral pede portão.** Leitura pode ser automática; escrita reversível,
  confirmação; irreversível (envio, pagamento, exclusão), humano no laço. Allowlist mínima de tools.
- **Limites explícitos no laço:** passos máximos, timeout, detecção de "parado" (mesma ação repetida),
  backoff no erro do provedor. Sem eles, agente que não converge só termina pela fatura.
- **Modelo pinado e prompt versionado.** Alias que muda de modelo por baixo muda a taxa do Eval Set
  sem nenhum commit seu. O Eval Set roda de novo a cada troca de um ou de outro.

## Retrieval: a unidade indexada precisa caber no modelo de embedding

Medido aqui em 2026-09-11: um índice de **um vetor por arquivo** deixou **225 de 329** arquivos fora,
por passarem do limite de contexto do modelo de embedding, e onde indexou, o vetor do arquivo inteiro
diluiu o assunto (todas as distâncias entre 13 e 15). Acertou 1/9 no top-1, contra 5/9 de um catálogo
lido pelo próprio modelo. A lição para quem constrói RAG: **confira o limite do modelo de embedding e
quebre o documento em pedaços que caibam nele**, meça o recall no Eval Set antes de confiar no índice e
compare com o baseline sem vetor (busca textual ou catálogo).

## O que NÃO fazer

- Não suba de degrau sem número do Eval Set que justifique.
- Não trate voting com votantes idênticos como redundância: é o mesmo erro N vezes.
- Não deixe a saída do modelo chegar a um sink sem validação, mesmo com schema.
- Não copie parâmetro de API daqui ou da memória: a doc do provedor muda.

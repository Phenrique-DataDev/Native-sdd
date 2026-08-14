# Checklist de repertório do revisor

> **Para que este arquivo existe.** Um revisor `fresh-context` do **mesmo modelo** não vê o que
> aquele modelo não vê. Contexto novo troca a *memória*, não o *repertório*. Este arquivo é
> repertório que **não veio do modelo** — versionado, lido antes de revisar, e é a única peça do
> ciclo que pode cobrir um ponto cego compartilhado.
>
> **Medido** (`ORCHESTRATE_BASELINE`, 2026-08-11): o mesmo defeito passou por **três topologias** —
> solo, iteração simples e orquestração com revisor fresh-context — em **9 invocações de agente e
> ~467k tokens**. Era detecção de delimitador; `csv.Sniffer` está na biblioteca padrão. Nenhuma
> topologia viu, porque todas re-executavam o mesmo repertório.

## A regra de elevação — leia antes dos itens

**Falha silenciosa é divergência, mesmo quando o contrato não menciona a entrada.** Silenciosa =
dado descartado, truncado ou ignorado **sem erro e sem mensagem**, com código de saída de sucesso.

A pergunta não é *"o contrato pede isso?"* — é **"se isso acontecer em produção, alguém descobre?"**
Se a resposta é não, é `[FALHA]`, e o mínimo aceitável é falhar alto (erro claro), não acertar.

**E o escopo da mudança não é o escopo da revisão.** Defeito que você observou e que *preexiste* à
mudança sob revisão é `[FALHA]` com a nota "preexiste a esta mudança" — não `[n/v]`. Adiar é decisão
legítima de quem decide; `[n/v]` a toma sozinho e em silêncio, e o defeito sai da revisão sem que
ninguém tenha escolhido nada.

> Medido no campo 01 (2026-08-11, `setup-rustdesk`): o revisor dispensou `actions/checkout@v4` com
> *"prática comum, ação oficial da GitHub; não é regressão introduzida por esta mudança"* — enquanto
> o run do CI imprimia `Node.js 20 is deprecated` **naquele momento**. Mesma forma do achado da
> rodada 2, com outra desculpa: lá foi *"o contrato não pede"*, aqui *"não é meu"*.

> **Por que esta regra existe.** Medido (`ORCHESTRATE_BASELINE` rodada 2, 2026-08-11): dois
> revisores independentes, já com este checklist, **testaram** a entrada com delimitador `;`,
> **observaram** que ela carregava zero registros em silêncio com exit 0 — um deles escreveu
> *"mesma classe de falha do BOM"* — e **ambos marcaram `[n/v]`**, porque o contrato literal só
> definia vírgula. O juiz cego reprovou os dois.
>
> O checklist tinha feito seu trabalho: o item entrou no campo de visão. O que faltava era
> **critério de elevação**. Sem esta regra, um checklist ensina a *documentar* o defeito em vez de
> *reportá-lo* — e o ponto cego vira ponto dispensado, que dá o mesmo resultado.

## Como usar

O revisor **lê este arquivo antes de revisar** e responde item por item **com execução**, não com
leitura de código. Item que você não conseguiu executar é `NÃO VERIFICADO` — nunca `ok`.

Formato da resposta:

```text
[ok]   entrada com delimitador ';'    -> testado, 3 colunas detectadas
[FALHA] arquivo em latin-1            -> UnicodeDecodeError sem tratamento (repro: ...)
[n/v]  concorrência                   -> não há caminho concorrente neste código
```

### Como executar: bateria única — não um caso por vez

Levante **todas** as hipóteses antes de executar qualquer uma. Depois escreva **um único
script** que exercita todas de uma vez — cada caso no seu próprio `try/except`, imprimindo
`NOME | VEREDITO | evidência`, para que um caso que exploda não aborte os outros. Rode **uma
vez** e leia a saída inteira.

**Não há teto de quantas hipóteses levantar.** A instrução é sobre a *forma*, não sobre o
volume: teto numérico corta hipótese, e hipótese é o que compra check.

> **Medido** (rodada 6, 2026-08-11). Mesma carga, mesmo juiz, mesmo checklist da rodada 5; mudou
> só a forma de executar. O revisor caiu de **77.355 para 54.624 tokens (−29%)** processando **o
> dobro** do material, e levantou **14 divergências contra 4**. A razão entre o custo e o material
> que ele lê caiu de **17× para 5,3×**.
>
> O custo de uma revisão não está no que ela lê — está nas **idas e voltas**, cada chamada de
> ferramenta reenviando o contexto acumulado. Investigar um caso por execução é o que este
> parágrafo existe para evitar.
>
> **E saiba o que isso compra rio abaixo:** a mesma rodada levou o placar a **25/25** (o único
> perfeito em seis rodadas) e o *fix* custou **78.728** — mais que o revisor. Revisão que acha
> mais gera correção maior. É trabalho real, não desperdício, mas quem decide precisa saber que
> o custo total da revisão **não é o custo do revisor**.

**Este checklist é do projeto, não do framework.** Ele nasce genérico; quem o mantém é quem
descobre um ponto cego novo. Achou um defeito que passou por uma revisão? **A correção não termina
no código — termina com uma linha nova aqui.** É o único mecanismo do ciclo que acumula repertório
entre features.

---

## I/O de dados (arquivos, parsing, serialização)

- [ ] **Delimitador** não-padrão (`;`, `\t`, `|`) — detectado ou documentado como não-suportado?
- [ ] **Encoding** fora de UTF-8 (latin-1, cp1252) — erro legível, nunca traceback?
- [ ] **BOM** no início do arquivo — vaza para o nome do primeiro campo?
- [ ] **Quoting**: separador dentro de aspas, aspas escapadas, quebra de linha dentro do campo.
- [ ] **Linha vazia** (no meio e antes do EOF) — conta como registro?
- [ ] **Registro irregular**: menos/mais campos que o cabeçalho.
- [ ] **Arquivo degenerado**: 0 bytes, só cabeçalho, só uma linha.
- [ ] **Fim de linha** CRLF × LF.
- [ ] **Ordenação**: numérica vs lexicográfica (`"10" < "9"`) e data vs string.
- [ ] **Nulo × vazio × zero × `"NA"`** — o contrato distingue? O código distingue igual?

## Fronteira do sistema (CLI, API, entrada externa)

- [ ] **Exit code** ≠ 0 em erro; **stdout** limpo quando a saída é consumida por outro programa.
- [ ] **Traceback cru** nunca chega ao usuário.
- [ ] **Encoding do console** (Windows `cp1252`) — acento/emoji na saída derruba o processo?
- [ ] Caminho **inexistente**, caminho que é **diretório**, caminho **sem permissão**.
- [ ] Entrada vinda de **stdin/pipe** quando o contrato a menciona.

## Estado e concorrência

- [ ] **CWD**: o código escreve relativo ao diretório do processo? Quem garante qual é?
- [ ] Escrita **parcial** interrompida deixa arquivo válido ou corrompido?
- [ ] Duas execuções simultâneas sobre o mesmo destino.
- [ ] Operação **idempotente**: rodar duas vezes muda o resultado?

## Distribuição e consumo externo

> Só quando o artefato é **consumido de fora** — repositório público, pacote, template, imagem. As
> outras seções assumem "código que roda"; esta assume "coisa que um estranho clona e usa".

- [ ] **Licença**: existe arquivo? A API do host a **reconhece** (`gh api repos/<o>/<r>/license`)?
      Sem licença, o default legal é *todos os direitos reservados* — ninguém pode usar nem forkar.
- [ ] **O que o artefato NÃO licencia** está dito? (binário de terceiro que ele baixa, dado, marca)
- [ ] **Placeholder que virou mentira**: `<url-do-repo>`, `TODO`, `example.com`, caminho de exemplo.
      Algum deles um estranho copia, cola e falha?
- [ ] **Promessa cumprível por quem não é o autor**: servidor interno, branch privada, credencial,
      arquivo não versionado, variável de ambiente que só existe na sua máquina.
- [ ] **Histórico, não só a árvore de trabalho**: `git log --all -p` por segredo, token, IP e
      caminho de máquina pessoal. O `.gitignore` de hoje não fala sobre o commit de ontem.
- [ ] **Permissões e pinagem do CI**: `permissions:` mínimo, actions em versão suportada, nenhum
      secret exposto em log.
- [ ] **EOL e encoding dos arquivos novos** batem com as regras declaradas (`.gitattributes`)?
      Arquivo sem extensão costuma escapar de toda regra.

> **Por que esta seção existe.** Campo 01 (2026-08-11): revisão de um repositório recém-tornado
> público. Os três achados principais — licença ausente, `git clone <url-do-repo>` e CI sem sinal
> no README — **não caíam em nenhuma das quatro seções originais**, e quem os encontrou foi o
> executor na auditoria, não o revisor com o checklist na mão.

## O que a suíte verde não prova

- [ ] Existe cláusula do contrato **sem nenhum teste** que a cubra? (liste-as)
- [ ] Algum teste afirma apenas **o que o código faz** em vez do que o contrato pede?
- [ ] O teste **reprova** se você quebrar a linha que ele deveria proteger? (mute e confirme)
- [ ] Contagem de testes cresceu sem cobrir cláusula nova? (volume ≠ cobertura)
- [ ] **Algum comando saiu com 0 mas imprimiu `warning` / `deprecated` / `note`?** Exit code não é
      a saída — leia a saída. Verde com aviso é dívida com data de vencimento.

## Antes de aprovar

- [ ] Cada `[FALHA]` acima tem **reprodução executável** anexada.
- [ ] Cada `[n/v]` tem uma razão de **uma linha** — não é "não olhei".
- [ ] Se você não encontrou nada: diga **o que procurou**. "Aprovado" sem superfície declarada é
      indistinguível de não ter revisado.

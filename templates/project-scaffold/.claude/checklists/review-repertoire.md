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

Formato da resposta — **o ID do item vem antes da descrição**, sempre:

```text
[ok]    IO-01  entrada com delimitador ';'  -> testado, 3 colunas detectadas
[FALHA] IO-02  arquivo em latin-1           -> UnicodeDecodeError sem tratamento (repro: ...)
[n/v]   EC-03  duas execuções simultâneas   -> não há caminho concorrente neste código
```

O ID não é enfeite: é o que permite perguntar, depois de N revisões, **qual item comprou achado e
qual não comprou** — ver §*Quando um item sai* no fim do arquivo. Achado que não cai em item nenhum
sai como `[FALHA] —` (travessão no lugar do ID); ele é o candidato natural a **virar** item novo.

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

**E a manutenção tem os dois sentidos.** Item entra por achado; **sai** por não comprar mais achado
nenhum — ver §*Quando um item sai*. Sem a saída, todo achado do projeto vira imposto permanente
cobrado de toda revisão futura.

---

## I/O de dados (arquivos, parsing, serialização)

- [ ] `IO-01` **Delimitador** não-padrão (`;`, `\t`, `|`) — detectado ou documentado como não-suportado?
- [ ] `IO-02` **Encoding** fora de UTF-8 (latin-1, cp1252) — erro legível, nunca traceback?
- [ ] `IO-03` **BOM** no início do arquivo — vaza para o nome do primeiro campo?
- [ ] `IO-04` **Quoting**: separador dentro de aspas, aspas escapadas, quebra de linha dentro do campo.
- [ ] `IO-05` **Linha vazia** (no meio e antes do EOF) — conta como registro?
- [ ] `IO-06` **Registro irregular**: menos/mais campos que o cabeçalho.
- [ ] `IO-07` **Arquivo degenerado**: 0 bytes, só cabeçalho, só uma linha.
- [ ] `IO-08` **Fim de linha** CRLF × LF.
- [ ] `IO-09` **Ordenação**: numérica vs lexicográfica (`"10" < "9"`) e data vs string.
- [ ] `IO-10` **Nulo × vazio × zero × `"NA"`** — o contrato distingue? O código distingue igual?

## Fronteira do sistema (CLI, API, entrada externa)

- [ ] `FR-01` **Exit code** ≠ 0 em erro; **stdout** limpo quando a saída é consumida por outro programa.
- [ ] `FR-02` **Traceback cru** nunca chega ao usuário.
- [ ] `FR-03` **Encoding do console** (Windows `cp1252`) — acento/emoji na saída derruba o processo?
- [ ] `FR-04` Caminho **inexistente**, caminho que é **diretório**, caminho **sem permissão**.
- [ ] `FR-05` Entrada vinda de **stdin/pipe** quando o contrato a menciona.

## Estado e concorrência

- [ ] `EC-01` **CWD**: o código escreve relativo ao diretório do processo? Quem garante qual é?
- [ ] `EC-02` Escrita **parcial** interrompida deixa arquivo válido ou corrompido?
- [ ] `EC-03` Duas execuções simultâneas sobre o mesmo destino.
- [ ] `EC-04` Operação **idempotente**: rodar duas vezes muda o resultado?

## Distribuição e consumo externo

> Só quando o artefato é **consumido de fora** — repositório público, pacote, template, imagem. As
> outras seções assumem "código que roda"; esta assume "coisa que um estranho clona e usa".

- [ ] `DI-01` **Licença**: existe arquivo? A API do host a **reconhece** (`gh api repos/<o>/<r>/license`)?
      Sem licença, o default legal é *todos os direitos reservados* — ninguém pode usar nem forkar.
- [ ] `DI-02` **O que o artefato NÃO licencia** está dito? (binário de terceiro que ele baixa, dado, marca)
- [ ] `DI-03` **Placeholder que virou mentira**: `<url-do-repo>`, `TODO`, `example.com`, caminho de exemplo.
      Algum deles um estranho copia, cola e falha?
- [ ] `DI-04` **Promessa cumprível por quem não é o autor**: servidor interno, branch privada, credencial,
      arquivo não versionado, variável de ambiente que só existe na sua máquina.
- [ ] `DI-05` **Histórico, não só a árvore de trabalho**: `git log --all -p` por segredo, token, IP e
      caminho de máquina pessoal. O `.gitignore` de hoje não fala sobre o commit de ontem.
- [ ] `DI-06` **Permissões e pinagem do CI**: `permissions:` mínimo, actions em versão suportada, nenhum
      secret exposto em log.
- [ ] `DI-07` **EOL e encoding dos arquivos novos** batem com as regras declaradas (`.gitattributes`)?
      Arquivo sem extensão costuma escapar de toda regra.

> **Por que esta seção existe.** Campo 01 (2026-08-11): revisão de um repositório recém-tornado
> público. Os três achados principais — licença ausente, `git clone <url-do-repo>` e CI sem sinal
> no README — **não caíam em nenhuma das quatro seções originais**, e quem os encontrou foi o
> executor na auditoria, não o revisor com o checklist na mão.

## O que o contrato não disse

> Onde a especificação cala, **alguém** decide — e quem decide é quem escreve o código, sem que
> ninguém tenha autorizado. Ausência de especificação vira restrição, e a restrição rejeita entrada
> que o contrato jamais proibiu.

- [ ] `CT-01` **Liste as decisões que o contrato deixou em aberto** — tipo de campo, ordem, limite, formato,
      *default*, o que fazer com o caso duplicado. Para cada uma: o código a fechou? Com que autoridade?
- [ ] `CT-02` Alguma dessas escolhas **rejeita entrada válida** segundo o contrato? Tipo mais estreito que o
      especificado (`int` num campo que o contrato só usa como chave) é a forma mais comum.
- [ ] `CT-03` O contrato **usa** um campo sem **tipar** — o código inferiu o tipo dos dados de exemplo?
      **Um exemplo não é uma especificação.**

> **Por que esta seção existe.** Medido (`ORCHESTRATE_BASELINE` rodada 7, 2026-08-21): o juiz cego
> reprovou **17 de 25** checks, e **12 dos 17 eram cascata de uma causa só**. O executor fixou
> `produto_id INTEGER PRIMARY KEY` e `int(row['produto_id'])`; o contrato **nunca disse** que
> `produto_id` é inteiro — só o usou como chave. Com SKU alfanumérico a carga inteira é rejeitada
> em silêncio, com exit 0.
>
> **Dos três revisores independentes, um viu** — e o que o distinguiu não foi item de lista nenhum:
> foi ler o contrato de forma adversarial e escrever *"o contrato nunca disse que `produto_id` é
> inteiro"*. Esta seção existe para que isso deixe de depender de quem é o revisor.
>
> Repare na fronteira com a **regra de elevação** lá em cima: aquela olha para o que **entra** e o
> contrato não previu; esta olha para o que o **implementador escolheu** quando a spec calou.

## O que a suíte verde não prova

- [ ] `SV-01` Existe cláusula do contrato **sem nenhum teste** que a cubra? (liste-as)
- [ ] `SV-02` Algum teste afirma apenas **o que o código faz** em vez do que o contrato pede?
- [ ] `SV-03` O teste **reprova** se você quebrar a linha que ele deveria proteger? (mute e confirme)
- [ ] `SV-04` Contagem de testes cresceu sem cobrir cláusula nova? (volume ≠ cobertura)
- [ ] `SV-05` **Algum comando saiu com 0 mas imprimiu `warning` / `deprecated` / `note`?** Exit code não é
      a saída — leia a saída. Verde com aviso é dívida com data de vencimento.

## Antes de aprovar

- [ ] Cada `[FALHA]` acima tem **reprodução executável** anexada.
- [ ] Cada `[n/v]` tem uma razão de **uma linha** — não é "não olhei".
- [ ] Se você não encontrou nada: diga **o que procurou**. "Aprovado" sem superfície declarada é
      indistinguível de não ter revisado.
- [ ] **A suíte não é a superfície.** "Rodei os testes e passaram" não responde à linha acima — é o
      trabalho de quem escreveu os testes, não o seu. Diga o que **você** leu e o que **você**
      executou além dela; se a suíte é mesmo o seu argumento, diga qual cláusula do contrato ela
      cobre. Suíte verde é **ausência de sinal, não sinal de ausência**.

> **Medido** (`ORCHESTRATE_BASELINE`, rodada 8, 2026-08-24): o mandato dos braços **já pedia** *"se
> você achar que não há defeito algum, diga o que fez para concluir"* — a linha acima, com outras
> palavras. **Três de sete** braços concluíram que não havia defeito porque a suíte passou, um deles
> com **2 defeitos no próprio lote**; o corpus tinha sido construído para ficar verde com os 14
> dentro (gate `G2`). **Declarar a superfície não discrimina:** *"rodei a suíte"* **é** uma superfície
> declarada. Por isso a exclusão precisa ser dita, e não fica por conta da boa vontade do revisor —
> o auditor do mesmo braço fez a inferência correta a partir do mesmo fato (*"rodei a suíte, logo os
> defeitos são sutis"*), o que mostra que a distinção é alcançável, não exótica.

> **Isto não duplica a seção `SV-`.** Aqueles cinco itens olham **para os testes** (cláusula sem
> teste, teste que afirma o código, mutação que não reprova). Este olha para a **conclusão**: o que
> o revisor tem direito de inferir do verde. São o mesmo assunto em dois momentos diferentes da
> revisão, e o defeito medido aconteceu no segundo.

> Esta seção **não tem ID** de propósito: ela não é repertório, é a forma da resposta. Nunca compra
> achado, então nunca é candidata a sair pela regra abaixo.

---

## Quando um item sai

Este arquivo **só cresce** — e crescer é o modo de falha dele. Cada item novo é lido por todo revisor
antes de toda revisão; um item que não compra achado é imposto cobrado em todas.

**O critério de saída não é o tamanho do arquivo.** A rodada 5 tinha um teto de "8 verificações"; a
rodada 6 o removeu e as divergências subiram de **4 para 14** — *teto numérico corta hipótese, e
hipótese é o que compra check*. Cortar por volume corta o que funciona junto com o que não funciona.

### O predicado (observável, e por isso é o ID que o torna possível)

Um item é **candidato a aposentadoria** quando, nas últimas **5 revisões em que foi aplicável**
(ou seja, ignorando os `[n/v]`), ele produziu **zero `[FALHA]`**.

Como contar — a resposta do revisor é transcrita na §*Revisão de repertório* do `BUILD_REPORT`, então
o histórico está no repositório e a agregação é um `grep`:

```powershell
# quantos [FALHA] cada item comprou, no histórico inteiro do projeto
Select-String -Path .claude/sdd/reports/*.md, .claude/sdd/archive/*/*.md -Pattern '^\[FALHA\]\s+(\S+)' |
  ForEach-Object { $_.Matches[0].Groups[1].Value } | Group-Object | Sort-Object Count -Descending
```

Item que não aparece na saída **e** já foi aplicável 5 vezes: candidato. Item que nunca foi aplicável
(só `[n/v]`) não é candidato por desuso — ele simplesmente **não é deste projeto**, e sai na hora, com
a razão "não há esse caminho aqui".

### O que fazer com o candidato

**Mova para §Aposentados, não apague.** Uma linha, com a contagem que o aposentou e a data. Aposentar
é hipótese sobre o futuro; apagar joga fora o motivo de tê-lo escrito.

**O que o traz de volta:** um achado real que ele teria pego. Aí ele volta para a seção de origem com
o ID **original** — IDs não são reciclados, nunca. Um `IO-04` aposentado deixa o `IO-04` reservado
para sempre; item novo pega o próximo número livre da seção.

### O que este instrumento NÃO mede — leia antes de confiar nele

Ele mede **item morto** (não acha nada). Ele **não** mede **item redundante** — o que acha só o que o
revisor acharia sem ele. Os dois se parecem no `grep` e são opostos: o redundante aparece com contagem
**alta**.

> **O caso que forçou a distinção.** `IO-01` (delimitador `;`) entrou em 2026-08-11 depois de passar
> por três topologias sem ser visto. Na rodada 7 (2026-08-21) **os três braços independentes o
> acharam** — e o protocolo daquela rodada já previa a leitura: *"todos acham → o checklist da R6 já
> resolveu"*. Pela contagem, `IO-01` é o melhor item do arquivo. Pelo que ele discrimina hoje, pode
> ser o mais dispensável. **A contagem não separa os dois.**

Separar exige um braço **sem** o checklist na mesma carga — isso é rodada de experimento, não revisão
de rotina, e custa como experimento. **Não aposente item por contagem alta**; a regra acima só
autoriza aposentar por contagem **zero**.

**E ele mede só o caminho que ESCREVE `BUILD_REPORT`.** O `grep` acima agrega a §*Revisão de
repertório*, que existe no artefato do ciclo SDD — e só ali. Uma revisão feita pelo `/review` (que
devolve achados no chat) ou pelo `/doubt` (que devolve dúvidas) **não deixa rastro nenhum na
contagem**, por mais `[FALHA]` que tenha comprado. Consequência prática, e é a que morde: um item que
compra achado **só** nesses caminhos aparece com **zero** e seria aposentado por morto.

> **Enquanto não houver onde transcrever fora do `BUILD_REPORT`, a regra de aposentadoria vale sobre
> uma amostra parcial — e isso é para ser lido antes de aposentar qualquer coisa, não depois.** A
> amostra cresceu em 2026-08-26, quando o repertório passou a ser carregado pelos seis caminhos de
> revisão em vez de um; o instrumento que a mede, não.

## Aposentados

_(vazio — o primeiro item aposentado entra aqui com a contagem e a data que o aposentaram)_

| ID | Item | Aposentado em | Por quê |
|----|------|---------------|---------|

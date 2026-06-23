# Doubt-driven — dúvida adversarial *in-flight* (postura, opt-in)

> **Postura por-decisão**, não um gate obrigatório. Antes de **firmar** uma decisão arriscada ou
> irreversível, submeta-a a um ceticismo estruturado: um revisor de **contexto novo** a quem se
> **omite a sua conclusão**, que devolve **dúvidas** — não um veredito. Distinta do
> [`/review`](../commands/review.md) (post-hoc, dá veredito sobre artefato pronto): aqui a decisão
> ainda está **aberta**. Acionada por **`/doubt <decisão>`**.

## Princípio

Quem decide tende a **confirmar** a própria escolha. Pedir "confirme que isto está certo" — com o seu
raciocínio anexado — convida o viés de confirmação, inclusive num subagente. O `doubt-driven` inverte
a pergunta: monta o caso **sem** a conclusão e instrui um revisor de **fresh-context** a *"achar o que
está errado"*. O valor não é mais uma revisão; é a **postura adversarial in-flight** + a **omissão da
conclusão**. Sem engine: o fresh-context é a ferramenta **`Agent` nativa** (igual `orchestration.md`).

## Quando aplicar (opt-in)

Acione o ciclo **antes de firmar** quando a decisão é:

| Sinal | Exemplo |
|-------|---------|
| **Irreversível / caro de reverter** | esquema de dados, contrato público, escolha de dependência |
| **Arquitetural** | fronteira de módulo, modelo de orquestração, formato de estado persistido |
| **Corte de escopo com risco** | "isto é YAGNI" sobre algo que outros vão depender |
| **Onde você está confiante demais** | a decisão "óbvia" que ninguém questionou |

**Não** acione para tarefa trivial/reversível — duvidar de tudo é a fricção que esta postura evita.
Em dúvida sobre dúvida: se errar custa minutos, siga; se custa horas/dias, `/doubt`.

## O ciclo CLAIM → EXTRACT → DOUBT → RECONCILE → STOP

| Passo | O que o autor faz |
|-------|-------------------|
| **CLAIM** | Enuncie a decisão e a conclusão atual em 1–2 frases (para você; **não** vai ao revisor). |
| **EXTRACT** | Destile o **problema + opções consideradas**, removendo a sua escolha e o "porquê". |
| **DOUBT** | Invoque o revisor adversarial (ver contrato) sobre o material extraído. |
| **RECONCILE** | Confronte cada dúvida: ela revela um furo real? Ajuste a decisão ou registre por que não procede. |
| **STOP** | Encerre a rodada. Uma rodada basta — não há placar nem loop. Decisão firma **depois** do RECONCILE. |

## Contrato do revisor adversarial

O revisor é um **subagente de fresh-context** (`Agent` nativo; tipicamente `code-reviewer`, ou
genérico). O contrato:

- **Recebe:** o problema + as opções **sem** a sua conclusão/recomendação.
- **Instrução:** *"Ache o que está errado nestas opções. Não confirme nada; não escolha por mim.
  Liste riscos, premissas frágeis e casos não cobertos."* (prompt **adversarial**, não "valide").
- **Devolve:** **dúvidas/perguntas** — nunca um veredito de severidade (🔴/🟡/🟢) nem "aprovado".
- **Degradação:** sem `Agent` disponível (ou recusado), aplique o ciclo você mesmo via o **checklist
  de auto-dúvida** do `/doubt` — a postura não depende do subagente para existir.

## Red flags

Sinais de que a postura saiu do trilho:

| Red flag | O que indica |
|----------|--------------|
| O revisor recebeu a sua conclusão | Virou "confirme isto" — viés de confirmação; **omita a conclusão**. |
| A saída veio como veredito (🔴/🟡/🟢, "aprovado") | Isso é `/review`, não `doubt`. A saída são **dúvidas** para reconciliar. |
| Você duvidou de uma decisão trivial/reversível | Fricção desnecessária — `doubt` é opt-in para o que é caro de reverter. |
| Pulou o RECONCILE ("as dúvidas não importam") | Sem reconciliar, o ciclo não fez nada — confronte ou registre o porquê. |
| Abriu uma 2ª, 3ª rodada atrás de aprovação | Uma rodada basta; rodadas extras viram a confirmação que se queria evitar (STOP). |

## O que NÃO fazer

- **Não** passe a sua conclusão ao revisor — o valor inteiro está em omiti-la.
- **Não** trate a saída como veredito final (isso é o `/review`); são dúvidas a reconciliar.
- **Não** torne o `doubt` obrigatório em toda fase — é opt-in por-decisão.
- **Não** construa engine/loop de rodadas — `Agent` nativo basta; uma rodada e STOP.

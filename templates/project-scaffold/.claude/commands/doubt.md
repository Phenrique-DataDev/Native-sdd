---
description: "Dúvida adversarial in-flight sobre uma decisão ainda aberta (não post-hoc)"
argument-hint: "<a decisão + sua conclusão atual>"
---

# /doubt — review adversarial *in-flight*

Submeter uma **decisão ainda aberta** a um revisor de **fresh-context** que **não recebe a sua
conclusão** e devolve **dúvidas** (não veredito). Distinto do [`/review`](review.md), que dá veredito
sobre um diff **já pronto**. Sem engine: o fresh-context é a ferramenta **`Agent` nativa**.

> **Este command é a fonte única da postura** — não há rule sempre-ativa correspondente. O protocolo
> inteiro está aqui e carrega **sob demanda**, quando você aciona `/doubt`.

---

## Princípio

Quem decide tende a **confirmar** a própria escolha — pedir *"confirme que isto está certo"*, com o
raciocínio anexado, convida o viés de confirmação mesmo num subagente. O `/doubt` **inverte a
pergunta**: monta o caso **sem** a conclusão e instrui um revisor **fresh-context** a *"achar o que
está errado"*. O valor inteiro está na postura adversarial *in-flight* + na **omissão da conclusão**.

## Quando aplicar (opt-in)

Acione **antes de firmar** quando a decisão é:

| Sinal | Exemplo |
|-------|---------|
| **Irreversível / caro de reverter** | esquema de dados, contrato público, escolha de dependência |
| **Arquitetural** | fronteira de módulo, modelo de orquestração, formato de estado persistido |
| **Corte de escopo com risco** | "isto é YAGNI" sobre algo que outros vão depender |
| **Onde você está confiante demais** | a decisão "óbvia" que ninguém questionou |

**Não** acione para tarefa trivial/reversível — duvidar de tudo é a fricção que esta postura evita.
Em dúvida sobre dúvida: se errar custa minutos, **siga**; se custa horas/dias, **`/doubt`**.

---

## Processo

1. **CLAIM** — registre (para você) a decisão e a sua conclusão atual em 1–2 frases.
2. **EXTRACT** — monte o **pacote do revisor**: o **problema + as opções consideradas**, **sem a
   conclusão** e sem o "porquê" da sua escolha. (Omitir a conclusão é o passo que dá valor.)
3. **DOUBT** — invoque o `Agent` nativo (fresh-context; tipicamente `code-reviewer`) com o pacote e o
   **prompt adversarial**:
   > "Ache o que está errado nestas opções. Não confirme nada nem escolha por mim. Liste riscos,
   > premissas frágeis e casos não cobertos."
4. **RECONCILE** — para cada dúvida devolvida, decida: revela um furo real (ajuste a decisão) ou não
   procede (registre o porquê).
5. **STOP** — encerre a rodada. **Uma rodada basta** — sem placar, sem loop. A decisão firma **depois**
   do RECONCILE.

## Saída

A saída é uma lista de **dúvidas/perguntas** a reconciliar — **nunca** um veredito de severidade nem
um juízo de aprovação/reprovação (isso é o `/review`). Formate como:

```text
Dúvidas levantadas (fresh-context, adversarial):
- [dúvida 1] → reconciliação: …
- [dúvida 2] → reconciliação: …
Decisão após reconciliar: …
```

## Degradação (sem `Agent`)

Se o `Agent` não estiver disponível (ou você preferir não usá-lo), **não quebre**: aplique o
**checklist de auto-dúvida** você mesmo, assumindo a postura adversarial contra a própria decisão:

- Qual premissa, se falsa, derruba a decisão? Ela foi verificada?
- Que caso/entrada esta opção **não** cobre?
- Que alternativa eu descartei rápido demais — e por quê, de fato?
- O que eu gostaria que **não** fosse perguntado sobre esta decisão?

## Racionalizações comuns

| Desculpa | Realidade |
|----------|-----------|
| "Passo minha conclusão junto pra agilizar" | É exatamente o que anula o método — o revisor passa a confirmar. **Omita a conclusão.** |
| "A decisão é óbvia, não preciso duvidar" | "Óbvia" é onde o viés mais esconde furo. Se é cara de reverter, uma rodada custa minutos. |
| "Vou rodar de novo até as dúvidas sumirem" | Rodada extra atrás de aprovação vira a confirmação que se queria evitar. Uma rodada e **STOP**. |
| "As dúvidas não procedem, sigo com a decisão" | Sem **RECONCILE**, o ciclo não fez nada. Confronte cada dúvida ou **registre por que não procede** — pular é rodar o método para nada. |

## O que NÃO fazer

- Passar a sua conclusão/recomendação ao revisor — o valor inteiro está em omiti-la.
- Emitir veredito de severidade (a escala que o `/review` usa) — a saída são **dúvidas**, não juízo final.
- Acionar `/doubt` em decisão trivial/reversível (fricção desnecessária).
- Pular o **RECONCILE** — dúvida não reconciliada é dúvida não usada.
- Construir loop de múltiplas rodadas — uma rodada basta.

**Próximo passo:** reconcilie as dúvidas e firme a decisão; se for virar artefato SDD, siga a fase.

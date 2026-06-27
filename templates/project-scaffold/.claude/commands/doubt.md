---
description: "Dúvida adversarial in-flight sobre uma decisão ainda aberta (não post-hoc)"
argument-hint: "<a decisão + sua conclusão atual>"
---

# /doubt — review adversarial *in-flight*

Submeter uma **decisão ainda aberta** a um revisor de **fresh-context** que **não recebe a sua
conclusão** e devolve **dúvidas** (não veredito). Aplica a postura da rule sempre-ativa
[`doubt-driven.md`](../rules/doubt-driven.md). Distinto do [`/review`](review.md), que dá veredito
sobre um diff **já pronto**. Sem engine: o fresh-context é a ferramenta **`Agent` nativa**.

> Use quando a decisão é **cara de reverter** (arquitetura, esquema, dependência, corte de escopo
> arriscado). Para o que é trivial/reversível, não acione — `doubt` é **opt-in**.

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

## O que NÃO fazer

- Passar a sua conclusão/recomendação ao revisor.
- Emitir veredito de severidade (a escala que o `/review` usa) — a saída são **dúvidas**, não juízo final.
- Acionar `/doubt` em decisão trivial/reversível (fricção desnecessária).
- Construir loop de múltiplas rodadas — uma rodada basta.

**Próximo passo:** reconcilie as dúvidas e firme a decisão; se for virar artefato SDD, siga a fase.

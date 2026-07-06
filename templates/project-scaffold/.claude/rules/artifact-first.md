# Artifact-first — comparar variantes antes de construir (postura, opt-in)

> **Postura por-decisão**, não um gate obrigatório. Antes de **implementar** algo que tem **≥ 2
> opções viáveis** e custo real de refazer se a escolha for errada, gere um **Artifact** com as
> variantes lado a lado e uma **escolha explícita** — em vez de decidir sozinho ou só descrever em
> prosa. Não é motor novo: reusa a ferramenta `Artifact` + a skill `artifact-design` (sempre
> nativas) e, para o padrão específico de **comparar variantes + escolher antes de construir**, a
> skill [`decision-preview`](../skills/decision-preview/SKILL.md).

## Princípio

Decisões de design (visual, de copy, de arquitetura, de layout de dado) descritas só em prosa
escondem a diferença real entre as opções — o humano só descobre que preferia outra depois de
implementada, quando já é caro trocar. Um Artifact com as variantes lado a lado, **grounded** nos
dados reais do projeto (nunca lorem ipsum), torna a escolha visível **antes** de custar
implementação. A postura existe para lembrar **quando** vale a pena pagar esse custo pequeno — não
para virar gate obrigatório em toda decisão.

## Quando aplicar (opt-in)

Ofereça gerar o Artifact quando a decisão tem:

| Sinal | Exemplo |
|-------|---------|
| **≥ 2 opções viáveis**, nenhuma obviamente certa | 2 wordings de mensagem de erro, 2 layouts de tabela, 3 paletas de tema |
| **Custo real de refazer** se a escolha for errada | trocar depois de implementado exige retrabalho visível (não só um `git revert`) |
| **Melhor mostrado que descrito** | a diferença entre as opções se perde em prosa/ASCII, mas fica óbvia lado a lado |

**Não** acione para decisão trivial/reversível (nomear uma variável, ajustar 1 cor isolada) —
fricção desnecessária. Regra de bolso: se a diferença cabe numa frase e reverter é barato, siga
direto; se a diferença só aparece **olhando**, ofereça o Artifact.

## Roteamento — qual ferramenta usar

Nem toda decisão visual precisa da skill nova — esta postura também existe para **evitar
redundância** com o que já está instalado:

| Situação | Use | Por quê |
|----------|-----|---------|
| Comparar **N variantes ainda não decididas** + fazer o usuário escolher | **`decision-preview`** | é o gap real: nenhuma skill existente cobre "comparar + escolher antes de construir" |
| Explicar/revisar algo **já decidido** (diff, plano, arquitetura pronta) | `visual-explainer` (se instalada) | já resolve — não duplique |
| **1 mockup só**, sem comparação entre opções | `artifact-design` direto | é guidance de design de Artifact; não precisa da camada de "variantes + escolha" |
| Gráfico/tabela de dados | `dataviz` (se instalada) | domínio próprio, fora do escopo desta postura |

## Ciclo

| Passo | O que acontece |
|-------|-----------------|
| **Detectar** | Ao encarar uma decisão com os sinais acima, pare antes de implementar direto. |
| **Rotear** | Confirme pela tabela acima se `decision-preview` é mesmo a ferramenta certa (ou se `visual-explainer`/`artifact-design` já bastam). |
| **Gerar** | Invoque a skill escolhida; para `decision-preview`, ela já carrega `artifact-design` e usa grounding real (nunca placeholder inventado). |
| **Escolher** | Apresente o Artifact e obtenha a escolha explícita (`AskUserQuestion` se a sessão for interativa; a própria seção "Escolha" do HTML se não). |
| **Construir** | A variante escolhida vira a spec — só então implemente. |

## Red flags

| Red flag | O que indica |
|----------|---------------|
| Ofereceu Artifact para renomear uma variável ou corrigir um typo | Fricção desnecessária — a decisão era trivial, não precisava do ciclo |
| Gerou `decision-preview` para revisar um diff já pronto | Devia ter roteado para `visual-explainer` — redundância |
| Implementou a variante "óbvia" sem mostrar as outras quando havia ≥ 2 viáveis | Perdeu o valor da postura: a diferença só aparece olhando, não decidindo sozinho |
| Preencheu variante com dado inventado/placeholder | Viola a regra global "nunca inventar dados" — peça o grounding real antes de gerar |

## O que NÃO fazer

- **Não** transforme isto em gate obrigatório — é opt-in, por-decisão (igual `doubt-driven.md`).
- **Não** invoque `decision-preview` quando `visual-explainer`/`artifact-design` já resolvem — isso é redundância, não "mais uso de Artifact".
- **Não** fabrique conteúdo de variante (placeholder/lorem ipsum) — grounding é sempre real; sem ele, pergunte antes de gerar.
- **Não** dependa só de `AskUserQuestion` para a escolha — sessões não-interativas precisam da seção "Escolha" já embutida no HTML.
- **Não** construa engine/gatilho determinístico — julgamento é do LLM; a postura só ensina o predicado.

# Artifact-first — comparar variantes antes de construir (postura, opt-in)

> **Porta.** O protocolo (roteamento entre ferramentas, ciclo, red flags e o caminho quando a sessão
> não tem a ferramenta `Artifact`) vive na skill interna
> [`decision-preview`](../skills/decision-preview/SKILL.md), carregada quando acionada. Aqui fica só o
> predicado, que precisa estar no ar **antes** de você decidir sozinho.

## Predicado observável

**Antes de implementar uma escolha de design: há ≥ 2 opções viáveis, nenhuma obviamente certa,
refazer depois custa retrabalho visível, e a diferença aparece melhor olhando do que descrita?**

| Resposta | O que fazer |
|----------|-------------|
| **Não** — a diferença cabe numa frase e reverter é barato (nomear variável, ajustar 1 cor) | Siga direto. **Pare aqui.** |
| **Sim** | **Ofereça** comparar as variantes antes de construir: acione a skill `decision-preview` (`Skill`, ou o usuário digita `/decision-preview`). A variante escolhida vira a spec. |

## O que NÃO fazer

- **Não** transforme isto em gate de toda decisão — é opt-in, por decisão (igual ao `/doubt`).
- **Não** use para revisar algo **já decidido** nem para **um** mockup só: a skill diz para onde rotear.
- **Não** fabrique conteúdo de variante (placeholder/lorem ipsum) — sem grounding real, pergunte antes.
- **Não** conte com a ferramenta `Artifact`: em `claude -p` ela não existe, e a skill diz o que fazer.

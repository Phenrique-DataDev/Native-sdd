# Anti-slop — sinais de interface gerada no automático

Cada item abaixo é um **sinal**, não uma proibição. Ele pede **justificativa**: se o projeto usa o
padrão de propósito (está no design system, na marca, na fonte do Figma), não é slop. É slop quando
apareceu porque é o default de quem gerou.

## Pontuação

Conte os sinais **sem justificativa** na tela:

| Sinais | Leitura |
|--------|---------|
| 0–1 | ok |
| 2–3 | revise: troque os que não têm motivo |
| 4+ | a tela foi montada no automático: refaça as decisões, não os detalhes |

## Tipografia
- **Uma família só, sem hierarquia** — tudo no mesmo tamanho e peso. Justificado: interface densa
  de dados que usa peso/cor para hierarquia.
- **Rótulo pequeno em caixa alta acima de todo título** — repetido em cada seção sem informar nada.
  Justificado: quando o rótulo carrega informação (categoria, passo 2 de 4).
- **Fonte de código decorando texto que não é código.** Justificado: identidade da marca.
- **Escala sem contraste** — 24/20/16 em vez de degraus que se distinguem de longe.

## Cor
- **Gradiente roxo→azul/ciano** como fundo ou texto. Justificado: é a cor da marca.
- **Fundo escuro + um acento neon** sem papel definido para o acento.
- **Acento usado em tudo** — se tudo é destaque, nada é.
- **Cor sem papel** — não dá para dizer por que ela está ali. Todo valor deve vir de um token.

## Layout
- **Três cartões idênticos lado a lado** (ícone + título + duas linhas), repetidos na página.
  Justificado: o conteúdo é de fato paralelo e comparável.
- **Tudo centralizado e simétrico**, seção após seção, sem variação de ritmo.
- **Sequência de manual:** herói genérico → 3 cartões → depoimentos → CTA → rodapé, sem relação com o
  que o produto precisa contar.
- **Borda colorida só à esquerda** em cartões e avisos, usada como enfeite.
- **Mesmo espaçamento entre todas as seções** — relação entre conteúdos não aparece no espaço.

## Componentes
- **Vidro fosco (glassmorphism) como estilo padrão** de cartão.
- **O mesmo raio em tudo** — botão, cartão, imagem e modal igualmente arredondados.
- **Emoji no lugar de ícone.** Justificado: tom do produto, usado com consistência.
- **O mesmo CTA ("Comece agora") em toda seção**, sem relação com o que a seção oferece.
- **Métrica de destaque sem dado real** ("10x mais rápido") — número inventado é defeito, não estilo.

## Movimento
- **O mesmo fade-in em todo elemento**, com a mesma duração e curva.
- **Tudo anima ao entrar na tela** — movimento sem papel de sinal.
- **Conteúdo que depende de JS para aparecer** (opacidade 0 até o script rodar): sem JS, a página
  fica em branco. Isto não é sinal a justificar — é defeito.

## Texto
- **Título que serve para qualquer empresa** ("Construa o futuro de…", "Soluções que transformam…").
- **Estrutura de frase em série** — toda seção com "[Adjetivo] [coisa] que ajuda você a [verbo]".
- **Lorem ipsum ou placeholder** esquecido.

## O que fazer com um sinal
Não troque um clichê por outro. Volte à pergunta que ele pulou: *o que este conteúdo precisa
mostrar, para quem, nesta largura?* A resposta costuma pedir outra estrutura, não outro enfeite.

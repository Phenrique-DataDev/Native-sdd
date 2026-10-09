# Fidelidade — conferir o construído contra a fonte

Use quando existe uma **fonte visual** (frame do Figma, print, mockup aprovado). Compare a fonte e o
PNG **na mesma largura**, lado a lado. Valor medido vence impressão: se a fonte diz `#12151C`, "está
escuro" não é conferência.

Marque cada item como **ok**, **delta** (diga quanto: "título 18 px, fonte pede 16") ou **n/a**.

## Tipografia
- família e peso (substituição de fonte é delta declarado, não ok)
- tamanho e altura de linha na largura do artboard
- espaçamento entre letras e caixa (maiúsculas, capitalizado)
- alinhamento e quebra: nenhuma palavra órfã ou texto cortado que a fonte não tem

## Cor
- fundo, texto, borda e ícone: valor, não "parecido"
- opacidade e sobreposição (camada translúcida muda a cor percebida)
- gradiente: direção, paradas e cores
- variável/token da fonte mapeado para o token do projeto (não para um hex solto)

## Espaço
- padding e margem de cada bloco
- gap entre itens de lista/grade
- largura máxima do contêiner e centralização
- distância entre seções

## Layout
- ordem dos elementos
- direção e alinhamento (linha/coluna, início/centro/fim, distribuição)
- o que quebra de linha ou empilha abaixo de cada breakpoint
- nenhuma rolagem horizontal em nenhuma largura

## Imagem e ícone
- o asset certo, não um placeholder
- proporção preservada; recorte (`object-fit`) igual ao da fonte
- raio da imagem
- tamanho de ícone consistente

## Efeitos
- sombra: deslocamento, desfoque, espalhamento, cor
- raio de cada canto que difere
- desfoque de fundo, se houver
- estados que a fonte desenha (hover, foco, ativo, desabilitado)

## Responsivo
- mobile igual ao frame mobile, desktop igual ao frame desktop, nas larguras exatas
- entre os dois, nada quebra (é aqui que a fonte não diz nada — use as larguras da varredura)
- alvo de toque ≥ 44 px no mobile
- navegação se adapta como a fonte mostra

## Quando a fonte e o projeto discordam
Token do projeto vence valor solto da fonte **se a diferença for de arredondamento** (15,99 px na
fonte, escala de 16 no projeto). Diferença de intenção (outra cor, outra hierarquia) é pergunta ao
usuário, não decisão sua.

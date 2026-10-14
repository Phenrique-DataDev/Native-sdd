---
name: visual-check
description: Renderiza uma UI em larguras comprovadas, lê o screenshot e confere contra a intenção ou uma fonte (Figma/print). Use antes de afirmar que um layout está certo — responsivo, fidelidade, anti-slop. Sem rota de captura calibrada, declara que não rodou.
argument-hint: "<URL ou arquivo HTML> [larguras] [fonte: link do Figma ou print]"
metadata:
  maintained_by: native-sdd (internal — not a third-party marketplace skill)
  version: "1.0.0"
---

# Visual check

Ver o que foi construído antes de dizer que está pronto. O resultado é **evidência**: um PNG por
largura, com a largura **comprovada**, lido por você com `Read`. Check sem PNG é "não verificado",
nunca "passou".

Só precisa de `Bash` + `Read`. Nada aqui instala coisa alguma.

**Chamada direta:** `/visual-check <URL ou arquivo HTML> [larguras] [fonte]` roda esta skill (skill
vence command homônimo — por isso não há `commands/visual-check.md`); alvo, larguras e fonte vêm
dos argumentos. Na sessão principal, sem URL/arquivo renderizável, **pergunte** antes de seguir;
só o subagente (ex.: `designer`), que não pode perguntar, devolve "não rodou (sem URL)".

## Pré-condições — sem elas, o resultado é "não rodou"

- **Uma URL renderizável:** a que o chamador passou, um servidor que já está rodando, ou `file://`
  de um HTML estático. **Não suba dev server por conta própria** — processo em background dentro de
  subagente fica órfão, e o comando depende da stack. Sem URL: "não rodou (sem URL)", com o comando
  que o usuário rodaria para subir o servidor.
- **Uma rota de captura que calibre** (seção **Calibração**). Sem nenhuma: "não rodou (sem rota calibrada)".
- **Nunca instale** navegador, Playwright ou pacote para conseguir rodar. Se faltar, sugira ao
  usuário o comando (ex.: `npm i -D playwright`, ou baixar o `chrome-headless-shell` do Chrome for
  Testing) e deixe a decisão com ele.

## Calibração — a rota só vale se provar a largura

A rota errada **não dá erro**: o PNG sai do tamanho pedido e a página foi montada com outra largura.
Medido no Windows: `msedge`/`chrome --headless --window-size=375,…` montam a página com 492/500 px,
e com 1440 montam 1416/1424. Por isso nenhuma rota é confiável pelo nome — só pela calibração abaixo.

Para **cada largura** que for usar, antes da captura real:

1. Capture `assets/calibrar.html` (nesta skill) pela mesma rota, na mesma largura.
2. Abra o PNG com `Read`: a página escreve `W=<innerWidth>`.
3. `W` igual ao pedido → a rota vale para essa largura. Diferente → rota reprovada para ela; tente a
   próxima. Registre o `W` observado no relatório.

Rotas, na ordem em que vale tentar (todas passam pela calibração):

- **Playwright CLI** já resolvível (dependência do projeto ou cache): `npx --no-install playwright
  screenshot --channel msedge --viewport-size=375,800 <url> <png>` (ou `--channel chrome`). Sem
  `--channel` ele só pede para baixar navegadores e **não gera PNG com exit sem erro** — confira o
  arquivo, não o código de saída.
- **`chrome-headless-shell`** já presente na máquina: `chrome-headless-shell --screenshot=<png>
  --window-size=375,800 --hide-scrollbars <url>` (no Linux pode precisar de `--no-sandbox`).
- **Navegador instalado por CLI** (`--headless --screenshot --window-size`): só se a calibração der
  exato na largura — no Windows não dá.

## Onde gravar

Tudo o que a verificação cria — PNG, script de medição, JSON de relatório — vai para o diretório
temporário do SO (`$TMPDIR`, `/tmp` ou `%TEMP%`), numa subpasta `visual-check-<data>`. **Nunca dentro
do projeto** — nada garante que ele ignore esses arquivos no git. Se uma
ferramenta só consegue gravar relativo ao projeto (ex.: download de imagem de um MCP do Figma), use
`.visual-check/` na raiz, apague ao terminar e diga no relatório que a pasta existiu.

## Larguras

| Modo | Larguras |
|------|----------|
| Refinar / Greenfield | 375 · 768 · 1280 |
| Fidelidade | as larguras dos artboards da fonte (+375 se a fonte não tiver versão mobile) |
| Varredura (só se pedida) | 320 · 375 · 480 · 600 · 768 · 900 · 1024 · 1280 · 1440 · 1920 |

Altura: a da primeira dobra (~800) para layout; página inteira (`--full-page` no Playwright) quando o
que importa é o ritmo entre seções.

## Ler e comparar

Abra cada PNG com `Read` e confira o que a tarefa pediu. Leia sob demanda, não de cabeça:

- [`references/fidelidade.md`](references/fidelidade.md) — quando existe uma fonte (Figma/print):
  item a item, com a fonte e o PNG lado a lado.
- [`references/anti-slop.md`](references/anti-slop.md) — em qualquer modo, antes de devolver.

Em qualquer largura, sempre: rolagem horizontal, texto cortado ou sobreposto, alvo de toque < 44 px
no mobile, imagem distorcida ou vazando o contêiner, foco invisível.

**Fonte do Figma:** se houver ferramenta do Figma na sua lista, extraia o spec do nó (tipografia,
cores, espaçamentos, raios) e, se ela oferecer, a imagem de referência do nó. Sem a ferramenta, peça
um print do frame. API do Figma devolvendo 404 costuma ser falta de acesso da conta ao arquivo, não
arquivo inexistente — diga isso e peça outra fonte.

## Desvio ou decisão?

Nem todo desvio de padrão é defeito. Antes de marcar como falha um alinhamento, espaço, cor ou
hierarquia que foge do resto da página, procure a **intenção**: comentário ou nome no código, token
do projeto, fonte visual (Figma/print) ou pedido do usuário.

- Evidência a favor do desvio → **ok**, citando onde ela está.
- Evidência contra → **falha**.
- Nenhuma evidência → **pergunta**: descreva o desvio medido e pergunte se é proposital.

Isso não vale para os defeitos de *Ler e comparar* ("em qualquer largura, sempre") nem para
contraste abaixo de AA em texto legível: esses são falha com qualquer intenção.

## Voltas

Achou defeito → corrija → recapture **só a largura afetada** (a calibração dela já vale). No máximo
**3 voltas por seção**; sem convergir, pare e devolva o delta restante em vez de iterar sem fim.

## Relatório

| Check | Largura (W calibrado) | Evidência | Resultado |
|-------|------------------------|-----------|-----------|
| sem rolagem horizontal | 375 (W=375) | `<tmp>/visual-check-…/375.png` | ok |
| hierarquia do título | 1280 (W=1280) | `…/1280.png` | ajustado na volta 2 |
| contraste do botão | — | — | não verificado (medir pelos tokens) |
| alinhamento da seção 3 | 1280 (W=1280) | `…/1280.png`: título em x=56, as outras em 116 | pergunta: é proposital? |

- Um check só é "ok" com PNG e `W` calibrado ao lado.
- **Pergunta** não reprova: o veredito conta só falhas, e as perguntas vão listadas à parte para o
  usuário responder.
- **Não rodou** é resultado legítimo: diga o motivo (sem URL, sem rota calibrada, página exige
  login), o que ficou sem ver e o que o usuário faria para habilitar.
- Contraste, APG e Core Web Vitals não se provam por screenshot: meça pelos tokens/ferramentas e
  diga como mediu.
- Mockup para avaliar **antes** de existir código não é caso desta skill → rota canvas do `designer`.

/*!
 * audit-regras.js — as regras de auditoria visual da landing, em fonte única.
 *
 * Este arquivo é o ÚNICO lugar onde uma regra é escrita. Ele é consumido por três caminhos:
 *   1. o overlay (`?audit` na URL) — desenha as marcações sobre a página;
 *   2. a suíte de testes — `page.addScriptTag({ path })` e chama `rodar()`;
 *   3. o CLI `auditar.mjs` — mesma coisa, e depois resolve `arquivo:linha` de cada achado.
 *
 * Duplicar uma regra entre esses três caminhos seria a forma mais rápida de fazer o teste e o
 * overlay discordarem sobre o que é um erro. Por isso nada aqui depende de Playwright, de Node
 * ou do overlay: é DOM puro, e devolve dados.
 *
 * Cada achado carrega `trecho` — um pedaço curto e literal do HTML de origem. É o que permite
 * casar o elemento medido no navegador com a linha do `index.html`, do lado do Node. Sem ele o
 * relatório diria "existe um alvo pequeno" sem dizer onde consertar.
 */
(function () {
  "use strict";

  var MIN_TOQUE = 44;        // WCAG 2.5.8 / iOS HIG
  var CONTRASTE_CORPO = 4.5; // WCAG AA
  var CONTRASTE_GRANDE = 3;  // AA para >=24px, ou >=18.66px em negrito

  // Tamanho mínimo por PAPEL, não um número só para tudo.
  //
  // Um limiar único de 12px acusava 42 dos 50 achados da landing — todos labels mono em caixa
  // alta com tracking, que são o vocabulário visual do projeto (`SEC_01 // A PROVOCAÇÃO`,
  // `PHASE_02 · ATIVA`). Um auditor que grita 42 vezes sobre uma decisão deliberada enterra os
  // achados de verdade, e a pessoa aprende a ignorar a lista inteira.
  //
  // A distinção que importa é entre texto que se LÊ e rótulo que se RECONHECE: prosa em 11px
  // cansa; uma etiqueta mono de 4 palavras com +0.2em de tracking, não. Abaixo de 10px, porém,
  // nem rótulo escapa — e é lá que estão os labels do grafo, em 9px.
  var MIN_FONTE_CORPO = 12;
  var MIN_FONTE_ROTULO = 10;

  var INTERATIVOS = 'a[href], button, input, select, textarea, summary, [role="button"], [role="link"], [tabindex]:not([tabindex="-1"])';

  // ---------------------------------------------------------------------
  // Cor: luminância relativa e contraste (WCAG 2.x)
  // ---------------------------------------------------------------------

  function parseCor(css) {
    if (!css) return null;
    var m = css.match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    var p = m[1].split(/[,\s/]+/).filter(Boolean).map(parseFloat);
    if (p.length < 3 || p.some(isNaN)) return null;
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  }

  // Compõe uma cor translúcida sobre a de trás. Sem isto, um texto em rgba(...,0.7) seria
  // medido como se fosse opaco e o contraste sairia melhor do que o olho recebe.
  function compor(frente, fundo) {
    var a = frente.a;
    return {
      r: frente.r * a + fundo.r * (1 - a),
      g: frente.g * a + fundo.g * (1 - a),
      b: frente.b * a + fundo.b * (1 - a),
      a: 1
    };
  }

  function luminancia(c) {
    var canal = function (v) {
      v = v / 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * canal(c.r) + 0.7152 * canal(c.g) + 0.0722 * canal(c.b);
  }

  function contraste(a, b) {
    var la = luminancia(a);
    var lb = luminancia(b);
    var claro = Math.max(la, lb);
    var escuro = Math.min(la, lb);
    return (claro + 0.05) / (escuro + 0.05);
  }

  // Sobe a árvore até achar um fundo opaco de verdade. Um elemento com background transparente
  // não é "sem cor": ele mostra a cor de quem está atrás, e é essa que o olho compara.
  function fundoEfetivo(el) {
    var atual = el;
    var pilha = [];
    while (atual && atual !== document.documentElement.parentNode) {
      var cor = parseCor(getComputedStyle(atual).backgroundColor);
      if (cor && cor.a > 0) {
        pilha.push(cor);
        if (cor.a === 1) break;
      }
      atual = atual.parentElement;
    }
    if (!pilha.length) return { r: 255, g: 255, b: 255, a: 1 };
    var resultado = pilha[pilha.length - 1];
    if (resultado.a < 1) resultado = compor(resultado, { r: 255, g: 255, b: 255, a: 1 });
    for (var i = pilha.length - 2; i >= 0; i--) resultado = compor(pilha[i], resultado);
    return resultado;
  }

  // ---------------------------------------------------------------------
  // Identificação: seletor legível e o trecho que casa com o arquivo-fonte
  // ---------------------------------------------------------------------

  function seletor(el) {
    if (!el || !el.tagName) return "?";
    var s = el.tagName.toLowerCase();
    if (el.id) return s + "#" + el.id;
    var cls = typeof el.className === "string" ? el.className.trim().split(/\s+/).filter(Boolean) : [];
    if (cls.length) s += "." + cls.slice(0, 3).join(".");
    var pai = el.parentElement;
    if (pai) {
      var irmaos = Array.prototype.filter.call(pai.children, function (c) { return c.tagName === el.tagName; });
      if (irmaos.length > 1) s += ":nth-of-type(" + (Array.prototype.indexOf.call(irmaos, el) + 1) + ")";
    }
    return s;
  }

  // A abertura literal da tag, como está escrita no HTML. É o que o lado Node procura no arquivo.
  // Atributos gerados em runtime (o graph.js monta nós) não existem no arquivo — nesse caso o
  // trecho simplesmente não casa, e o achado sai sem linha em vez de sair com uma linha errada.
  function trechoDeOrigem(el) {
    var html = el.outerHTML || "";
    var fim = html.indexOf(">");
    if (fim < 0) return null;
    var abertura = html.slice(0, fim + 1);
    return abertura.length > 240 ? abertura.slice(0, 240) : abertura;
  }

  /**
   * O elemento EXISTE no documento, mesmo que o movimento ainda não o tenha revelado.
   *
   * Diferente de `visivel()`, que também reprova `opacity: 0` e `visibility: hidden` — juntos, o
   * estado de repouso de todo bloco `.reveal`. Para uma regra que mede POSIÇÃO, esse critério é
   * o errado: ela sairia verde por não olhar, que é o pior defeito que um instrumento pode ter.
   * Aconteceu com a régua de voz (media 107 de ~700 palavras) e de novo com `svg-texto-cortado`,
   * que na primeira versão não viu um único dos três cortes que existiam.
   */
  function noDocumento(el) {
    if (getComputedStyle(el).display === "none") return false;
    return !el.closest("[hidden], [aria-hidden='true']");
  }

  /**
   * O elemento chega à tela — critério para as regras que medem PIXEL, não semântica.
   *
   * Difere de `visivel()` em duas coisas, e as duas são defeitos medidos nesta base:
   *   • não reprova `opacity: 0` / `visibility: hidden`, que juntos são o estado de repouso de
   *     todo bloco `.reveal`. Regra que os reprova sai verde por NÃO OLHAR — aconteceu três
   *     vezes aqui (régua de voz, `svg-texto-cortado`, `texto-minusculo`);
   *   • não reprova `aria-hidden`, que esconde do leitor de tela e não do olho. Texto minúsculo
   *     num ícone decorativo continua minúsculo.
   */
  function pintado(el) {
    if (getComputedStyle(el).display === "none") return false;
    if (el.closest("[hidden]")) return false;
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  /**
   * Quanto o desenho de um SVG é esticado ou encolhido até a tela.
   *
   * Dentro de um `<svg viewBox>`, `font-size` está em unidades do sistema de coordenadas do
   * desenho, não em pixels de tela. Uma fonte de 10 num viewBox de 1280 renderizado em 720
   * chega ao olho com 5,6px — e `getComputedStyle` continua dizendo "10px". Medir o valor
   * declarado é medir a intenção, não o resultado.
   */
  function escalaDoSvg(el) {
    var svg = el.closest ? el.closest("svg") : null;
    if (!svg || !svg.viewBox || !svg.viewBox.baseVal || !svg.viewBox.baseVal.width) return 1;
    var largura = svg.getBoundingClientRect().width;
    if (!largura) return 1;
    var e = largura / svg.viewBox.baseVal.width;
    // Um SVG que cabe exatamente na caixa mede 0.998 por arredondamento de layout, e isso
    // rebaixava um rótulo de 10px para 9,98 — 20 falsos positivos na primeira medição.
    // Escala praticamente 1 é escala 1.
    return e > 0.99 && e < 1.01 ? 1 : e;
  }

  function visivel(el) {
    var cs = getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden" || parseFloat(cs.opacity) === 0) return false;
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  function caixa(el) {
    var r = el.getBoundingClientRect();
    return {
      x: Math.round(r.left + window.scrollX),
      y: Math.round(r.top + window.scrollY),
      w: Math.round(r.width),
      h: Math.round(r.height)
    };
  }

  function achado(regra, severidade, el, mensagem, extra) {
    var a = {
      regra: regra,
      severidade: severidade,
      seletor: seletor(el),
      mensagem: mensagem,
      trecho: trechoDeOrigem(el),
      caixa: caixa(el),
      texto: (el.textContent || "").trim().slice(0, 60)
    };
    if (extra) for (var k in extra) if (Object.prototype.hasOwnProperty.call(extra, k)) a[k] = extra[k];
    return a;
  }

  // ---------------------------------------------------------------------
  // As regras
  // ---------------------------------------------------------------------

  function alvosDeToque() {
    var out = [];
    // Só faz sentido cobrar 44px onde se toca com o dedo. Num mouse de 1px o critério é outro,
    // e reportar isso no desktop enterraria os achados reais em ruído.
    if (!matchMedia("(pointer: coarse)").matches && window.innerWidth > 768) return out;
    Array.prototype.forEach.call(document.querySelectorAll(INTERATIVOS), function (el) {
      if (!visivel(el)) return;
      var r = el.getBoundingClientRect();
      var l = Math.round(r.width);
      var a = Math.round(r.height);
      if (l >= MIN_TOQUE && a >= MIN_TOQUE) return;
      out.push(achado("alvo-toque", l < 24 || a < 24 ? "alto" : "medio", el,
        "alvo de " + l + "x" + a + "px, abaixo do mínimo de " + MIN_TOQUE + "x" + MIN_TOQUE,
        { largura: l, altura: a }));
    });
    return out;
  }

  function contrasteDeTexto() {
    var out = [];
    var vistos = [];
    Array.prototype.forEach.call(document.querySelectorAll("body *"), function (el) {
      if (!visivel(el)) return;
      // Só o elemento que de fato carrega o texto — senão o mesmo texto é cobrado em cada
      // ancestral e um único parágrafo vira dez achados.
      var temTextoProprio = Array.prototype.some.call(el.childNodes, function (n) {
        return n.nodeType === 3 && n.textContent.trim().length > 1;
      });
      if (!temTextoProprio) return;

      var cs = getComputedStyle(el);
      var frente = parseCor(cs.color);
      if (!frente) return;
      var fundo = fundoEfetivo(el);
      if (frente.a < 1) frente = compor(frente, fundo);

      var tamanho = parseFloat(cs.fontSize);
      var peso = parseInt(cs.fontWeight, 10) || 400;
      var grande = tamanho >= 24 || (tamanho >= 18.66 && peso >= 700);
      var minimo = grande ? CONTRASTE_GRANDE : CONTRASTE_CORPO;
      var razao = contraste(frente, fundo);
      if (razao >= minimo) return;

      var chave = seletor(el) + "|" + Math.round(razao * 100);
      if (vistos.indexOf(chave) >= 0) return;
      vistos.push(chave);

      out.push(achado("contraste", razao < minimo * 0.75 ? "alto" : "medio", el,
        "contraste " + razao.toFixed(2) + ":1, abaixo de " + minimo + ":1 (" +
        Math.round(tamanho) + "px" + (peso >= 700 ? " bold" : "") + ")",
        { razao: Number(razao.toFixed(2)), minimo: minimo }));
    });
    return out;
  }

  // Rótulo: mono, ou caixa alta, ou tracking largo — os três sinais de "etiqueta", não de prosa.
  function ehRotulo(el, cs) {
    var fonte = (cs.fontFamily || "").toLowerCase();
    if (fonte.indexOf("mono") >= 0) return true;
    if (cs.textTransform === "uppercase") return true;
    var tracking = parseFloat(cs.letterSpacing);
    var tamanho = parseFloat(cs.fontSize);
    if (!isNaN(tracking) && tamanho && tracking / tamanho >= 0.08) return true;
    // Texto curto todo em maiúsculas no próprio conteúdo conta como etiqueta.
    var texto = (el.textContent || "").trim();
    return texto.length <= 32 && texto.length > 1 && texto === texto.toUpperCase() && /[A-ZÀ-Ú]/.test(texto);
  }

  function textoMinusculo() {
    var out = [];
    var vistos = [];
    Array.prototype.forEach.call(document.querySelectorAll("body *"), function (el) {
      if (!pintado(el)) return;
      var temTextoProprio = Array.prototype.some.call(el.childNodes, function (n) {
        return n.nodeType === 3 && n.textContent.trim().length > 1;
      });
      if (!temTextoProprio) return;
      var cs = getComputedStyle(el);
      var declarado = parseFloat(cs.fontSize);
      var escala = escalaDoSvg(el);
      // O que o olho recebe, não o que a folha de estilo pediu.
      var tamanho = declarado * escala;
      var rotulo = ehRotulo(el, cs);
      var minimo = rotulo ? MIN_FONTE_ROTULO : MIN_FONTE_CORPO;
      if (tamanho >= minimo) return;
      var chave = seletor(el) + "|" + tamanho;
      if (vistos.indexOf(chave) >= 0) return;
      vistos.push(chave);
      var comoEscala = escala < 0.995 || escala > 1.005
        ? " (declarada " + declarado.toFixed(1) + "px, o SVG desenha a " +
          Math.round(escala * 100) + "% do viewBox)"
        : "";
      out.push(achado("texto-minusculo", tamanho < MIN_FONTE_ROTULO ? "alto" : "medio", el,
        "fonte de " + tamanho.toFixed(1) + "px na tela, abaixo de " + minimo + "px para " +
        (rotulo ? "rótulo" : "texto de leitura") + comoEscala,
        { tamanho: Number(tamanho.toFixed(1)), declarado: Number(declarado.toFixed(1)),
          escala: Number(escala.toFixed(3)), papel: rotulo ? "rotulo" : "corpo", minimo: minimo }));
    });
    return out;
  }

  // Acha ONDE o estouro nasce: o elemento que ficou mais largo que a caixa que deveria contê-lo.
  //
  // A primeira versão desta regra perguntava outra coisa — "esconder este elemento reduz o
  // scrollWidth do documento?" — e tinha um furo que uma mutação expôs: com DOIS culpados
  // independentes estourando para a mesma largura, esconder um não muda o total, o outro
  // sustenta o número, e a regra devolvia zero achados diante de um overflow real de 404px
  // contra 340. Um detector que fica mudo quando o problema é maior é o pior tipo de detector.
  //
  // A pergunta certa é local: este elemento cabe no pai? O ponto onde a resposta vira "não" é
  // a origem do estouro, e não depende de quantos outros também estourem.
  function overflowLateral() {
    var doc = document.documentElement;
    if (doc.scrollWidth <= doc.clientWidth) return [];
    var out = [];
    var limite = doc.clientWidth;
    var origens = [];

    function contidoPorAncestral(el) {
      // Rolagem contida é decisão de layout, não vazamento: se algum ancestral assume o scroll,
      // o excesso não chega à página. Quem cobra a falta de aviso ali é `scroll-sem-aviso`.
      for (var anc = el.parentElement; anc && anc !== document.body; anc = anc.parentElement) {
        var ox = getComputedStyle(anc).overflowX;
        if (ox === "auto" || ox === "scroll" || ox === "hidden") return true;
      }
      return false;
    }

    Array.prototype.forEach.call(document.querySelectorAll("body *"), function (el) {
      if (!visivel(el)) return;
      var cs = getComputedStyle(el);

      // Camada fixa que cobre a tela (o grão, um overlay) se estica junto com o documento: ela
      // MEDE o estouro, não o causa. Reportá-la manda a pessoa corrigir o termômetro.
      if (cs.position === "fixed") return;
      if (contidoPorAncestral(el)) return;

      var pai = el.parentElement;
      if (!pai) return;
      var largura = el.getBoundingClientRect().width;
      var cabe = pai.clientWidth || limite;

      // Dois jeitos de um elemento originar estouro, e o segundo é o que a mutação expôs:
      //   A) ele próprio é mais largo que a caixa do pai (o caso de `min-width: auto`);
      //   B) ele CABE, mas o conteúdo dele não cabe nele e vaza — flex `nowrap` cujos itens
      //      somados passam da largura, que é exatamente o `.topo-panel-head` sem `flex-wrap`.
      var largoDemais = largura > cabe + 1;
      var vazaConteudo = cs.overflowX === "visible" && el.scrollWidth > el.clientWidth + 1;
      if (!largoDemais && !vazaConteudo) return;

      origens.push({ el: el, cs: cs, largura: largura, cabe: cabe, largoDemais: largoDemais });
    });

    // Só as FOLHAS. Um estouro se propaga para cima — o `<main>` também "não cabe" quando um
    // painel lá dentro não cabe — e reportar a cadeia inteira aponta para o ancestral mais raso,
    // que é justamente onde não está o defeito. Quem interessa é o elemento mais fundo que ainda
    // é origem: abaixo dele, tudo cabe.
    var folhas = origens.filter(function (o) {
      return !origens.some(function (outro) {
        return outro.el !== o.el && o.el.contains(outro.el);
      });
    });

    folhas.forEach(function (o) {
      var motivo = o.largoDemais
        ? "ocupa " + Math.round(o.largura) + "px numa caixa de " + o.cabe + "px"
        : "o conteúdo mede " + o.el.scrollWidth + "px numa caixa de " + o.el.clientWidth + "px e vaza";

      out.push(achado("overflow-lateral", "alto", o.el,
        motivo + " (viewport " + limite + ", documento " + doc.scrollWidth + "). min-width=" +
        o.cs.minWidth + " overflow-x=" + o.cs.overflowX + " flex-wrap=" + o.cs.flexWrap,
        { largura: Math.round(o.largura), cabe: o.cabe, limite: limite, conteudo: o.el.scrollWidth }));
    });
    return out;
  }

  function nomeAcessivel() {
    var out = [];
    Array.prototype.forEach.call(document.querySelectorAll('a[href], button, [role="button"]'), function (el) {
      if (!visivel(el)) return;
      var nome = (el.getAttribute("aria-label") || "").trim() ||
                 (el.textContent || "").trim() ||
                 (el.querySelector("img[alt]") ? el.querySelector("img[alt]").getAttribute("alt").trim() : "") ||
                 (el.getAttribute("title") || "").trim();
      if (nome) return;
      out.push(achado("sem-nome", "alto", el, "controle sem nome acessível: leitor de tela anuncia vazio"));
    });
    Array.prototype.forEach.call(document.querySelectorAll("img"), function (el) {
      if (el.getAttribute("alt") === null) {
        out.push(achado("sem-nome", "medio", el, "img sem atributo alt (use alt=\"\" se for decorativa)"));
      }
    });
    return out;
  }

  // Rolagem horizontal legítima (uma tabela larga) não é bug — não avisar que ela rola, é.
  function scrollSemAffordance() {
    var out = [];
    Array.prototype.forEach.call(document.querySelectorAll("body *"), function (el) {
      // `pintado`, não `visivel`: os dois contêineres que rolam na página (o quadro do esquema
      // e o painel do grafo) moram em blocos `.reveal`, e com `visivel()` esta regra nunca os
      // examinou. Quarto lugar onde o mesmo predicado escondia a medição de quem o usa.
      if (!pintado(el)) return;
      var cs = getComputedStyle(el);
      if (cs.overflowX !== "auto" && cs.overflowX !== "scroll") return;
      if (el.scrollWidth <= el.clientWidth + 1) return;
      var rotulado = el.hasAttribute("aria-label") || el.hasAttribute("data-scroll-hint") ||
                     el.getAttribute("role") === "region" || el.hasAttribute("tabindex");
      if (rotulado) return;
      out.push(achado("scroll-sem-aviso", "medio", el,
        "rola " + (el.scrollWidth - el.clientWidth) + "px na horizontal sem affordance nem foco por teclado",
        { conteudo: el.scrollWidth, visivel: el.clientWidth }));
    });
    return out;
  }

  function hierarquiaDeTitulos() {
    var out = [];
    var anterior = 0;
    Array.prototype.forEach.call(document.querySelectorAll("h1,h2,h3,h4,h5,h6"), function (el) {
      if (!visivel(el)) return;
      var nivel = parseInt(el.tagName.slice(1), 10);
      if (anterior && nivel > anterior + 1) {
        out.push(achado("titulo-pulado", "baixo", el,
          "h" + nivel + " logo depois de h" + anterior + ": o nível h" + (anterior + 1) + " foi pulado"));
      }
      anterior = nivel;
    });
    return out;
  }

  /**
   * Texto de SVG que passa do viewBox some SEM ERRO NENHUM: o navegador recorta na borda, a
   * página não ganha scroll, o console fica limpo e o teste de overflow lateral não vê nada,
   * porque o `<svg>` contém o estouro dentro do próprio sistema de coordenadas.
   *
   * Foi assim que três das quatro linhas da legenda do esquema mestre ficaram cortadas no meio
   * de uma palavra — "retorno de lições a", "barramento acima do", "memória abaixo, per" — e
   * atravessaram a suíte inteira verde. Medido em 2026-09-06: estouros de 40, 48 e 64px.
   */
  function textoForaDoViewBox() {
    var out = [];
    Array.prototype.forEach.call(document.querySelectorAll("svg"), function (svg) {
      if (!pintado(svg)) return;
      if (getComputedStyle(svg).overflow === "visible") return;

      var caixaSvg = svg.getBoundingClientRect();
      if (!caixaSvg.width || !caixaSvg.height) return;

      Array.prototype.forEach.call(svg.querySelectorAll("text"), function (t) {
        // Coordenada de TELA nos dois lados, de propósito. A primeira versão comparava
        // `getBBox()` com o viewBox da raiz e acusou 150 cortes que não existem: `getBBox`
        // devolve o espaço do próprio elemento, ANTES do `transform` dos ancestrais, e a
        // topologia dos agentes posiciona cada rótulo com rotação. O instrumento estava
        // errado, não o desenho.
        var b = t.getBoundingClientRect();
        if (!b.width) return;
        var pior = Math.max(
          b.right - caixaSvg.right,
          caixaSvg.left - b.left,
          b.bottom - caixaSvg.bottom,
          caixaSvg.top - b.top
        );
        // 1px de folga: arredondamento de métrica de fonte não é defeito de desenho.
        if (pior <= 1) return;
        out.push(achado("svg-texto-cortado", "alto", t,
          '"' + (t.textContent || "").trim() + '" passa ' + Math.round(pior) +
          "px da caixa do <svg> — o navegador recorta e a palavra some no meio",
          { estouro: Math.round(pior) }));
      });
    });
    return out;
  }

  /**
   * O rótulo cabe na CAIXA DO SVG e mesmo assim vaza da FORMA que deveria contê-lo.
   *
   * `svg-texto-cortado` mede a borda do `<svg>` — e por isso ficou verde enquanto o
   * `ORQUESTRADOR` do hub, subindo de 8 para 11 unidades, passava por cima do retângulo laranja
   * e caía sobre o fundo do desenho. Não há recorte, não há scroll, não há erro: só um rótulo
   * pousado meio dentro, meio fora, que só o olho pegou.
   *
   * O que conta como "a forma que deveria contê-lo": uma forma PREENCHIDA (fill opaco) que
   * divide o mesmo nó pai com o rótulo e cujo retângulo cobre o centro dele. Preenchida importa: o `g-hit` (`fill: transparent`,
   * r=24) e o `g-ring` (`fill: none`) cercam o centro de vários rótulos e não contêm nada. Sem
   * esse filtro, a primeira medição elegeu o anel decorativo como contêiner de onze rótulos de
   * agente e acusou todos.
   *
   * Rótulo SEM forma preenchida sob si é rótulo solto no desenho — os nomes dos agentes ficam
   * abaixo do próprio nó de propósito, e as cotas do monólito flutuam na margem. A regra não
   * opina sobre eles; colisão entre rótulos vizinhos é do `svg-rotulo-encoberto`, abaixo.
   *
   * Limite declarado: um `<circle>` é medido pelo retângulo que o circunscreve, então um texto
   * que sai do disco mas fica no quadrado passa. Nenhum rótulo desta página está nesse caso —
   * todos os contêineres preenchidos daqui são `<rect>`.
   *
   * Calibragem (2026-09-06, todos os 6 viewports): 33 rótulos têm contêiner preenchido e nenhum
   * vaza; a folga mais apertada da página é de 2px, no `ORQUESTRADOR` sob o `g-hub-box`. A
   * tolerância de 1px cabe entre as duas — a mesma folga de arredondamento de `svg-texto-cortado`.
   */
  function rotuloForaDaForma() {
    var FORMAS = { rect: 1, circle: 1, ellipse: 1, polygon: 1 };
    var out = [];

    function preenchida(el) {
      var f = getComputedStyle(el).fill;
      if (!f || f === "none") return false;
      var m = f.match(/rgba?\(([^)]+)\)/);
      if (!m) return true;
      var p = m[1].split(",").map(Number);
      return p.length < 4 || p[3] > 0.05;
    }

    Array.prototype.forEach.call(document.querySelectorAll("svg"), function (svg) {
      if (!pintado(svg)) return;

      Array.prototype.forEach.call(svg.querySelectorAll("text"), function (t) {
        var b = t.getBoundingClientRect();
        if (!b.width || !b.height) return;
        var cx = b.left + b.width / 2;
        var cy = b.top + b.height / 2;

        // Só as formas IRMÃS do rótulo. A primeira versão subia a cadeia até o `<svg>`, e com
        // isso qualquer caixa preenchida do desenho que ficasse sob o centro de um rótulo virava
        // "a forma que deveria contê-lo": na medição, um rótulo solto pousado sobre a caixa da
        // memória do esquema foi acusado por ela. Vizinhança geométrica não é intenção de
        // conter — quem declara a intenção é a estrutura, e a estrutura aqui é ser irmão.
        //
        // O limite disso, declarado: um `<text>` embrulhado sozinho num `<g>` fica sem candidata
        // e a regra não opina sobre ele. Julgar rótulo contra forma distante é outro instrumento
        // — e desde 2026-09-07 ele existe: `svg-rotulo-encoberto`, que não olha parentesco
        // nenhum e sim a ordem de pintura.
        var melhor = null;
        Array.prototype.forEach.call(t.parentNode.children, function (f) {
          if (f === t) return;
          if (!FORMAS[f.tagName.toLowerCase()] || !preenchida(f)) return;
          var r = f.getBoundingClientRect();
          if (!r.width || !r.height) return;
          if (cx < r.left || cx > r.right || cy < r.top || cy > r.bottom) return;
          var area = r.width * r.height;
          if (!melhor || area < melhor.area) melhor = { area: area, r: r, el: f };
        });
        if (!melhor) return;

        var r = melhor.r;
        var pior = Math.max(r.left - b.left, b.right - r.right, r.top - b.top, b.bottom - r.bottom);
        if (pior <= 1) return;

        out.push(achado("svg-rotulo-vazado", "alto", t,
          '"' + (t.textContent || "").trim() + '" passa ' + Math.round(pior) +
          "px da forma que deveria contê-lo — o rótulo pousa meio fora, sem recorte que avise",
          { estouro: Math.round(pior), forma: seletor(melhor.el) }));
      });
    });
    return out;
  }


  /**
   * O rótulo que alguém pinta POR CIMA — a colisão que o `svg-rotulo-vazado` não julga.
   *
   * Aquela regra pergunta se o rótulo cabe na forma IRMÃ que deveria contê-lo, e declara o
   * próprio limite: um `<text>` sozinho num `<g>` fica sem candidata, e rótulo que cai sobre o
   * desenho de outro nó não é assunto dela. Esta é a outra metade, e ela não olha para parentesco
   * nenhum: olha para a ORDEM DE PINTURA.
   *
   * A definição que sobreviveu à medição. No SVG não há `z-index`: quem vem depois no documento
   * é pintado por cima. Então "encoberto" é o que se pode afirmar sem adivinhar intenção — um
   * elemento com tinta, POSTERIOR ao rótulo, cobrindo parte relevante da caixa dele. Vale para
   * outro `<text>` (dois rótulos no mesmo lugar), para uma forma de qualquer profundidade da
   * árvore, e para uma aresta que passe por cima.
   *
   * O que ficou DE FORA, e por que — as duas medições que definiram a regra (2026-09-07, todos
   * os 6 viewports):
   *
   *   1. **O que é pintado ANTES do rótulo não é encobrimento.** Medindo colisão geométrica pura,
   *      63 arestas do grafo cruzam a caixa de algum rótulo em cada viewport. Nenhuma delas é
   *      visível ali: o rótulo tem `rect` de fundo opaco, pintado depois da aresta e antes do
   *      texto. Acusar por geometria seria acusar 63 vezes um desenho correto. Rótulo sobre
   *      desenho anterior é problema de CONTRASTE, não de colisão — e continua não medido, porque
   *      `fundoEfetivo` sobe a cadeia de ancestrais CSS e não enxerga forma SVG atrás.
   *
   *   2. **Caixa de `<text>` não é a tinta do texto.** Ela inclui a entrelinha, então dois
   *      rótulos empilhados se sobrepõem por construção: `max` e `ORQUESTRADOR`, no hub do grafo,
   *      partilham 2px verticais — 11% da caixa menor — e estão visivelmente separados. Foi essa
   *      medida que fixou a tolerância em 25%: acima do pior caso legítimo da página, e bem abaixo
   *      de um encobrimento de verdade (o mesmo par, 8px mais perto, dá 55%).
   *
   * Uma `line` é medida pela geometria REAL do segmento (Liang-Barsky contra a caixa do rótulo,
   * vezes a espessura do traço), nunca pela caixa: a caixa de uma diagonal cobre todo o retângulo
   * que ela atravessa, e as arestas deste grafo são todas diagonais. Um `<path>` continua medido
   * pela caixa — limite declarado, e o motivo de a página não ter nenhum path pintado sobre
   * rótulo hoje ser uma sorte, não uma garantia.
   */
  function rotuloEncoberto() {
    var COBERTURA = 0.25;      // fração da caixa do rótulo que precisa estar coberta
    var ESCONDIDOS = "defs, clipPath, mask, symbol, marker, pattern";
    var GRAFICOS = "rect, circle, ellipse, polygon, polyline, path, line, text";
    var out = [];

    function comTinta(cs) {
      if (parseFloat(cs.opacity) <= 0.05) return false;
      var f = cs.fill;
      if (f && f !== "none") {
        var m = f.match(/rgba?\(([^)]+)\)/);
        if (!m) return true;
        var p = m[1].split(",").map(Number);
        if (p.length < 4 || p[3] > 0.05) return true;
      }
      return !!(cs.stroke && cs.stroke !== "none" && parseFloat(cs.strokeWidth) > 0);
    }

    // Quanto do segmento cai dentro do retângulo, em px de tela. Liang-Barsky: recorta o
    // parâmetro t do segmento pelas quatro bordas e devolve o comprimento do que sobrou.
    function segmentoDentro(x1, y1, x2, y2, r) {
      var t0 = 0, t1 = 1, dx = x2 - x1, dy = y2 - y1;
      var p = [-dx, dx, -dy, dy];
      var q = [x1 - r.left, r.right - x1, y1 - r.top, r.bottom - y1];
      for (var i = 0; i < 4; i++) {
        if (p[i] === 0) { if (q[i] < 0) return 0; continue; }
        var t = q[i] / p[i];
        if (p[i] < 0) { if (t > t1) return 0; if (t > t0) t0 = t; }
        else { if (t < t0) return 0; if (t < t1) t1 = t; }
      }
      return Math.hypot(dx, dy) * (t1 - t0);
    }

    function pontoNaTela(el, x, y) {
      var svg = el.ownerSVGElement;
      var m = el.getScreenCTM();
      if (!svg || !m) return null;
      var p = svg.createSVGPoint();
      p.x = parseFloat(x) || 0;
      p.y = parseFloat(y) || 0;
      return p.matrixTransform(m);
    }

    function areaCoberta(el, cs, b) {
      if (el.tagName.toLowerCase() === "line") {
        var a = pontoNaTela(el, el.getAttribute("x1"), el.getAttribute("y1"));
        var z = pontoNaTela(el, el.getAttribute("x2"), el.getAttribute("y2"));
        if (!a || !z) return 0;
        var dentro = segmentoDentro(a.x, a.y, z.x, z.y, b);
        if (!dentro) return 0;
        var espessura = (parseFloat(cs.strokeWidth) || 1) * escalaDoSvg(el);
        return dentro * espessura;
      }
      var r = el.getBoundingClientRect();
      if (!r.width || !r.height) return 0;
      var w = Math.min(b.right, r.right) - Math.max(b.left, r.left);
      var h = Math.min(b.bottom, r.bottom) - Math.max(b.top, r.top);
      return w > 0 && h > 0 ? w * h : 0;
    }

    Array.prototype.forEach.call(document.querySelectorAll("svg"), function (svg) {
      if (!pintado(svg)) return;
      var graficos = Array.prototype.filter.call(svg.querySelectorAll(GRAFICOS), function (el) {
        return !el.closest(ESCONDIDOS);
      });

      Array.prototype.forEach.call(svg.querySelectorAll("text"), function (t) {
        if (t.closest(ESCONDIDOS)) return;
        var b = t.getBoundingClientRect();
        if (!b.width || !b.height) return;
        var areaRotulo = b.width * b.height;

        var pior = null;
        graficos.forEach(function (el) {
          if (el === t || el.contains(t) || t.contains(el)) return;
          // Só o que é pintado DEPOIS: no SVG a ordem do documento É a ordem de pintura.
          if (!(t.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING)) return;
          var cs = getComputedStyle(el);
          if (cs.display === "none" || !comTinta(cs)) return;
          var area = areaCoberta(el, cs, b);
          if (!area) return;
          if (!pior || area > pior.area) pior = { area: area, el: el };
        });

        if (!pior || pior.area / areaRotulo < COBERTURA) return;

        var pct = Math.round((pior.area / areaRotulo) * 100);
        out.push(achado("svg-rotulo-encoberto", "alto", t,
          '"' + (t.textContent || "").trim() + '" tem ' + pct +
          "% da própria caixa coberta por <" + pior.el.tagName.toLowerCase() +
          "> pintado depois dele — o rótulo fica embaixo do desenho",
          { cobertura: pct, porCima: seletor(pior.el) }));
      });
    });
    return out;
  }
  var REGRAS = [
    { id: "overflow-lateral", fn: overflowLateral },
    { id: "svg-texto-cortado", fn: textoForaDoViewBox },
    { id: "svg-rotulo-vazado", fn: rotuloForaDaForma },
    { id: "svg-rotulo-encoberto", fn: rotuloEncoberto },
    { id: "alvo-toque", fn: alvosDeToque },
    { id: "contraste", fn: contrasteDeTexto },
    { id: "sem-nome", fn: nomeAcessivel },
    { id: "scroll-sem-aviso", fn: scrollSemAffordance },
    { id: "texto-minusculo", fn: textoMinusculo },
    { id: "titulo-pulado", fn: hierarquiaDeTitulos }
  ];

  function rodar(apenas) {
    var achados = [];
    REGRAS.forEach(function (r) {
      if (apenas && apenas.indexOf(r.id) < 0) return;
      try {
        achados = achados.concat(r.fn() || []);
      } catch (e) {
        // Uma regra que explode não pode levar as outras junto — e o silêncio dela seria pior
        // que o erro, então ela vira um achado sobre si mesma.
        achados.push({
          regra: r.id, severidade: "alto", seletor: "(instrumento)",
          mensagem: "a regra lançou: " + (e && e.message ? e.message : String(e)),
          trecho: null, caixa: null, texto: ""
        });
      }
    });
    var ordem = { alto: 0, medio: 1, baixo: 2 };
    achados.sort(function (a, b) { return (ordem[a.severidade] - ordem[b.severidade]) || a.regra.localeCompare(b.regra); });
    return achados;
  }

  // Todo o texto visível, com o trecho que permite achar a linha. Serve à revisão de copy em
  // lista — varrer a página inteira sem caçar no HTML.
  function indiceDeTexto() {
    var itens = [];
    var caminhador = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        var t = n.textContent.replace(/\s+/g, " ").trim();
        if (t.length < 2) return NodeFilter.FILTER_REJECT;
        var pai = n.parentElement;
        if (!pai) return NodeFilter.FILTER_REJECT;
        if (pai.closest("script, style, template")) return NodeFilter.FILTER_REJECT;
        if (!visivel(pai)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var no;
    while ((no = caminhador.nextNode())) {
      var pai = no.parentElement;
      var secao = pai.closest("section[id], header, footer");
      itens.push({
        texto: no.textContent.replace(/\s+/g, " ").trim(),
        seletor: seletor(pai),
        secao: secao ? (secao.id || secao.tagName.toLowerCase()) : "",
        trecho: trechoDeOrigem(pai),
        caixa: caixa(pai)
      });
    }
    return itens;
  }

  /**
   * A PROSA da página — só o que é lido como frase, sem rótulo, código nem terminal.
   *
   * Existe para a régua de voz (`tools/site-tests/lib/voz.mjs`), e a separação é o ponto: a
   * primeira versão daquela régua lia a seção inteira achatada e contava `Lint · testes · AT`
   * como tríade de prosa e `pwsh — native-sdd branch: main` como frase com cauda pendurada. O
   * instrumento acusava tique onde havia vocabulário. Rótulo mono, `code` e o bloco do terminal
   * são a linguagem visual do projeto e não respondem por voz.
   *
   * A exclusão é por ANCESTRAL, não por classe própria: os itens da legenda do hero não têm
   * classe nenhuma, quem é mono é o `<ol>` acima deles. Só o DOM sabe disso, e é por isso que
   * esta função mora aqui e não do lado do Node.
   */
  function proseVisivel() {
    var NAO_PROSA = ".mono, code, pre, kbd, samp, .term, .eyebrow, [data-hero-phases]";
    var out = [];

    // `visivel()` NÃO serve aqui, e a diferença foi medida duas vezes.
    //
    // Ele reprova `opacity: 0` E `visibility: hidden`, que são JUNTOS o estado de repouso de todo
    // bloco `.reveal` antes do scroll — 31 dos 48 blocos da página. Usá-lo devolvia 107 das ~1500
    // palavras: a régua de voz mediria o hero e mais nada, e passaria verde por ignorância, que é
    // o pior defeito que um instrumento pode ter.
    //
    // O critério certo aqui não é "está pintado agora", é "existe para o leitor". Texto que ainda
    // não animou vai ser lido; texto com `display: none` ou `aria-hidden` não. É só isso que sai.
    Array.prototype.forEach.call(document.querySelectorAll("h1, h2, h3, p, li"), function (el) {
      if (!noDocumento(el)) return;
      if (el.closest(NAO_PROSA)) return;
      // Um `<span class="mono">` no meio da frase É parte da frase (".claude/", "arquivo:linha")
      // e fica. O que sai é o bloco inteiro cuja natureza é rótulo.
      var t = (el.textContent || "").replace(/\s+/g, " ").trim();
      if (t.length < 12) return;
      var secao = el.closest("section[id], header, footer");
      out.push({
        secao: secao ? (secao.id || secao.tagName.toLowerCase()) : "",
        tag: el.tagName.toLowerCase(),
        texto: t,
        trecho: trechoDeOrigem(el)
      });
    });
    return out;
  }

  window.__AUDIT_REGRAS__ = {
    rodar: rodar,
    indiceDeTexto: indiceDeTexto,
    proseVisivel: proseVisivel,
    regras: REGRAS.map(function (r) { return r.id; }),
    limites: { toque: MIN_TOQUE, fonteCorpo: MIN_FONTE_CORPO, fonteRotulo: MIN_FONTE_ROTULO, contrasteCorpo: CONTRASTE_CORPO, contrasteGrande: CONTRASTE_GRANDE }
  };
})();

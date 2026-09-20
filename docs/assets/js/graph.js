/**
 * Grafo de agentes interativo — #topologia.
 *
 * Substitui o SVG estático escrito à mão por um grafo radial construído a partir de
 * `window.__AGENT_GRAPH__` (ver graph-data.js — gerado das fontes reais do scaffold).
 *
 * CONTRATO COM O RESTO DA LANDING (a razão da ordem dos <script defer> no index.html):
 *   - Este arquivo roda ANTES do motion.js e precisa deixar o DOM no formato que a seção 4
 *     do motion.js espera: um `[data-motion="graph"]` cujas arestas sejam `<line>` (todo
 *     `line`/`path` ali dentro vira alvo do draw por stroke-dashoffset + do pulso infinito).
 *     Por isso NADA além de aresta usa `<line>`/`<path>` aqui — nó, halo e anel são
 *     `<circle>`/`<rect>`/`<text>`, que o motion.js ignora.
 *   - O pulso do GSAP anima `opacity` das arestas. O realce/atenuação daqui usa
 *     `stroke-opacity` (propriedade distinta, multiplicativa) justamente para não brigar
 *     com aquele tween nem precisar de !important.
 *   - Ao re-posicionar uma aresta já desenhada, o `stroke-dasharray` que o GSAP escreveu
 *     vale para o comprimento ANTIGO. `syncDash()` recalcula — sem isso a linha volta a
 *     aparecer tracejada depois de um drill-down.
 *
 * Degradação: sem GSAP o layout é aplicado direto (sem transição); sem JS o markup traz um
 * fallback estático no HTML. `prefers-reduced-motion` desliga a transição via CSS.
 */
(function () {
  'use strict';

  var data = window.__AGENT_GRAPH__;
  var host = document.querySelector('[data-graph-host]');
  if (!data || !host || !data.nodes || !data.nodes.length) return;

  var SVG_NS = 'http://www.w3.org/2000/svg';
  var W = 880, H = 620, CX = 440, CY = 300;
  var R_AGENT = 172, R_SKILL = 268, R_EXILE = 306, R_FOCUS = 190;

  // Modo compacto (D-26): com menos de 560px de trilho, no celular, o desenho troca para um
  // viewBox de 320×370, sem as skills no anel e com o foco em elipse. Ver `medirModo()`.
  var LARGURA_COMPACTA = 560;
  var CW = 320, CH = 370, CCX = 160, CCY = 180;
  var CR_AGENT = 118, CRX_FOCUS = 100, CRY_FOCUS = 125;

  // Ordem do anel = ordem da tabela do roster logo abaixo do grafo (mesma leitura, mesma
  // sequência). Quem não estiver aqui entra depois, na ordem do dataset.
  var RING_ORDER = [
    'explorer', 'code-reviewer', 'test-writer', 'git-workflow', 'security-reviewer',
    'debugger', 'validator', 'documenter', 'external-observer', 'designer', 'tracker'
  ];

  /* ------------------------------------------------------------------ modelo */

  var byId = {};
  data.nodes.forEach(function (n) { byId[n.id] = n; });

  var hub = data.nodes.filter(function (n) { return n.type === 'Hub'; })[0] || byId.max;
  var agents = data.nodes.filter(function (n) { return n.type === 'Agent'; });
  var skills = data.nodes.filter(function (n) { return n.type === 'Skill'; });

  agents.sort(function (a, b) {
    var ia = RING_ORDER.indexOf(a.id), ib = RING_ORDER.indexOf(b.id);
    if (ia === -1) ia = 99; if (ib === -1) ib = 99;
    return ia - ib || (a.id < b.id ? -1 : 1);
  });

  // Vizinhança não-direcionada — o drill-down mostra tudo que toca o nó, venha a aresta
  // dele ou para ele.
  var neighbors = {};
  data.nodes.forEach(function (n) { neighbors[n.id] = []; });
  var edges = data.edges.filter(function (e) { return byId[e.from] && byId[e.to]; });
  edges.forEach(function (e) {
    if (neighbors[e.from].indexOf(e.to) === -1) neighbors[e.from].push(e.to);
    if (neighbors[e.to].indexOf(e.from) === -1) neighbors[e.to].push(e.from);
  });

  function outgoing(id, type) {
    return edges.filter(function (e) { return e.from === id && e.type === type; })
                .map(function (e) { return e.to; });
  }

  /* ------------------------------------------------- posições (determinísticas) */

  var angle = {};   // id -> radianos
  var home = {};    // id -> {x, y} no estado "overview"

  function polar(cx, cy, r, a) { return { x: cx + r * Math.cos(a), y: cy + r * Math.sin(a) }; }

  agents.forEach(function (n, i) {
    angle[n.id] = -Math.PI / 2 + (i * 2 * Math.PI) / agents.length;
    home[n.id] = polar(CX, CY, R_AGENT, angle[n.id]);
  });

  // Cada skill quer ficar perto de quem a usa (média circular dos ângulos dos agentes que a
  // declaram). Duas skills do mesmo agente cairiam sobrepostas — por isso o ângulo-alvo só
  // ORDENA, e o espaçamento final do anel externo é uniforme.
  skills.forEach(function (n) {
    var users = edges.filter(function (e) { return e.to === n.id && angle[e.from] != null; });
    if (!users.length) { n._aim = Math.PI; return; }
    var sx = 0, sy = 0;
    users.forEach(function (e) { sx += Math.cos(angle[e.from]); sy += Math.sin(angle[e.from]); });
    n._aim = Math.atan2(sy, sx);
  });
  skills.sort(function (a, b) { return a._aim - b._aim || (a.id < b.id ? -1 : 1); });
  skills.forEach(function (n, i) {
    angle[n.id] = -Math.PI / 2 + (i * 2 * Math.PI) / skills.length;
    home[n.id] = polar(CX, CY, R_SKILL, angle[n.id]);
  });

  if (hub) { angle[hub.id] = 0; home[hub.id] = { x: CX, y: CY }; }

  // Sigla de cada nó, para o anel compacto, onde 11 nomes por extenso não cabem: iniciais das
  // duas primeiras partes (`code-reviewer` → cr) ou, numa palavra só, a primeira letra com a
  // seguinte que ainda não foi usada (`debugger` → de, `designer` → ds). Agentes escolhem antes,
  // na ordem do anel, e nenhuma sigla se repete.
  var sigla = {};
  (function () {
    var usadas = {};
    agents.concat(skills).forEach(function (n) {
      var partes = n.id.split('-');
      var corrido = partes.join('');
      var candidatas = partes.length > 1 ? [partes[0][0] + partes[1][0]] : [];
      for (var i = 1; i < corrido.length; i++) candidatas.push(corrido[0] + corrido[i]);
      var escolhida = candidatas.filter(function (c) { return !usadas[c]; })[0] || corrido.slice(0, 3);
      usadas[escolhida] = true;
      sigla[n.id] = escolhida;
    });
  })();

  // No foco compacto o nome por extenso quebra no primeiro hífen quando passa de 10 letras:
  // `gerador-de-manuais` vira `gerador-` / `de-manuais`, e a linha mais longa cabe no viewBox.
  function linhasDoNome(id) {
    var h = id.indexOf('-');
    return id.length > 10 && h > 0 ? [id.slice(0, h + 1), id.slice(h + 1)] : [id];
  }

  /* ---------------------------------------------------------------- construção */

  function el(name, attrs, cls) {
    var e = document.createElementNS(SVG_NS, name);
    if (cls) e.setAttribute('class', cls);
    for (var k in attrs) if (Object.prototype.hasOwnProperty.call(attrs, k)) e.setAttribute(k, attrs[k]);
    return e;
  }

  var svg = el('svg', {
    viewBox: '0 0 ' + W + ' ' + H,
    width: '100%',
    role: 'group',
    'data-motion': 'graph',
    'aria-label': 'Grafo do orquestrador max, dos ' + agents.length + ' agentes e das ' +
                  skills.length + ' skills que eles usam. Cada nó abre a própria ficha.'
  }, 'topo-graph-svg');

  var title = document.createElementNS(SVG_NS, 'title');
  title.textContent = 'Grafo de agentes do scaffold — max no centro, agentes no anel interno, skills no externo';
  svg.appendChild(title);

  // Anéis-guia: decorativos e <circle>, então o motion.js não os confunde com aresta.
  var gRings = el('g', { 'aria-hidden': 'true' }, 'g-rings');
  var aneis = [R_AGENT, R_SKILL].map(function (r, i) {
    var c = el('circle', { cx: CX, cy: CY, r: r, fill: 'none' }, 'g-ring ' + (i ? 'g-ring--skill' : 'g-ring--agent'));
    gRings.appendChild(c);
    return c;
  });
  svg.appendChild(gRings);

  var gEdges = el('g', { 'aria-hidden': 'true' }, 'g-edges');
  var gNodes = el('g', {}, 'g-nodes');
  svg.appendChild(gEdges);
  svg.appendChild(gNodes);

  var edgeEls = edges.map(function (e) {
    var a = home[e.from], b = home[e.to];
    var line = el('line', { x1: a.x, y1: a.y, x2: b.x, y2: b.y },
                  'g-edge g-edge--' + e.type.toLowerCase());
    line._edge = e;
    gEdges.appendChild(line);
    return line;
  });

  var nodeEls = {};
  var nomeEls = {};
  data.nodes.forEach(function (n) {
    var isHub = n.type === 'Hub';
    var g = el('g', {
      tabindex: '0',
      role: 'button',
      'aria-label': n.id + ' — ' + (isHub ? 'orquestrador' : (n.role || n.type.toLowerCase()))
    }, 'g-node g-node--' + n.type.toLowerCase() + (n.status === 'referenced' ? ' is-referenced' : ''));
    g.dataset.id = n.id;

    if (isHub) {
      // A caixa acompanha o rotulo, nao o contrario: `ORQUESTRADOR` subiu de 8px para 11px
      // (a 8 ele chegava a tela com 7,6px) e passou a medir ~112 unidades. Nos 96 antigos ele
      // vazava para fora do retangulo laranja — medido em 2026-09-06.
      g.appendChild(el('rect', { x: -72, y: -24, width: 144, height: 48, fill: 'none' }, 'g-hub-frame'));
      g.appendChild(el('rect', { x: -64, y: -18, width: 128, height: 36 }, 'g-hub-box'));
      var hn = el('text', { y: 1, 'text-anchor': 'middle' }, 'g-hub-name');
      hn.textContent = n.id;
      var hr = el('text', { y: 13, 'text-anchor': 'middle' }, 'g-hub-role');
      hr.textContent = 'ORQUESTRADOR';
      g.appendChild(hn);
      g.appendChild(hr);
    } else {
      // Alvo de clique/toque generoso (WCAG 2.2 target size): o halo tem fill:none e o dot
      // tem 5-8px de raio — sem este circulo transparente o no e praticamente inclicavel.
      g.appendChild(el('circle', { r: 24, fill: 'transparent' }, 'g-hit'));
      g.appendChild(el('circle', { r: n.type === 'Agent' ? 17 : 13 }, 'g-halo'));
      g.appendChild(el('circle', { r: n.type === 'Agent' ? 8 : 5 }, 'g-dot'));
      var lb = el('text', { y: n.type === 'Agent' ? 33 : 27, 'text-anchor': 'middle' }, 'g-label');
      lb.textContent = n.id;
      g.appendChild(lb);
      // Só no modo compacto (o CSS esconde fora dele): a sigla dentro do círculo e o nome em até
      // duas linhas, que aparece para quem está no foco.
      var sg = el('text', { y: 4.5, 'text-anchor': 'middle' }, 'g-sigla');
      sg.textContent = sigla[n.id];
      g.appendChild(sg);
      var nm = el('text', { 'text-anchor': 'middle' }, 'g-nome');
      linhasDoNome(n.id).forEach(function (linha, i) {
        var ts = el('tspan', { x: 0, y: (n.type === 'Agent' ? 36 : 32) + i * 15 });
        ts.textContent = linha;
        nm.appendChild(ts);
      });
      g.appendChild(nm);
      nomeEls[n.id] = nm;
    }

    gNodes.appendChild(g);
    nodeEls[n.id] = g;
  });

  host.innerHTML = '';
  host.appendChild(svg);

  /**
   * Quem rola começa no meio do desenho, não na margem dele.
   *
   * O painel rola na horizontal porque o grafo nunca desenha abaixo de 1:1 (ver o CSS de
   * `.topo-graph-svg`): a 390px sobra pouco mais de um terço do desenho na tela. Ancorado em
   * `scrollLeft: 0`, esse terço é o CANTO ESQUERDO — margem, rótulos cortados ao meio e nenhum
   * hub. Medido em 2026-09-06, com o painel ancorado à esquerda:
   *
   *     340px   hub 246px fora da área visível   5 rótulos na tela, 4 deles cortados
   *     390px   hub 196px fora                   7 rótulos na tela, 4 deles cortados
   *     768px   hub visível                      20 rótulos, 2 cortados
   *
   * Ou seja: nos dois viewports mais estreitos a seção abria com o orquestrador fora da tela e
   * a maioria do que sobrava cortado ao meio.
   *
   * Centralizar não esconde que há mais coisa para os lados — as arestas seguem saindo dos dois
   * lados da tela, que é o convite a rolar. O que muda é o que a pessoa vê primeiro: o
   * orquestrador e o anel de agentes em volta, que é justamente o que a seção afirma.
   */
  function centralizarNoHub() {
    // O trilho é o próprio host desde 2026-09-15 (D-24). Quando era o painel inteiro, centralizar
    // levava junto o cabeçalho e a legenda, que ficavam cortados à esquerda da tela.
    var trilho = host;
    var sobra = trilho.scrollWidth - trilho.clientWidth;
    // Sem sobra o desenho cabe inteiro e não há o que centralizar; mexer no scroll de um
    // contêiner que não rola é o tipo de linha que fica anos sem fazer nada.
    if (sobra <= 0) return;
    trilho.scrollLeft = Math.round(sobra / 2);
  }
  /**
   * Compacto quando o trilho tem menos de 560px, no celular (D-26, 2026-09-15). O critério é a
   * largura do trilho, não a da tela. Devolve se o modo mudou, para quem chama refazer o layout.
   */
  var compacto = false;
  function medirModo() {
    var agora = host.clientWidth > 0 && host.clientWidth < LARGURA_COMPACTA;
    if (agora === compacto) return false;
    compacto = agora;
    host.classList.toggle('is-compact', compacto);
    svg.setAttribute('viewBox', compacto ? '0 0 ' + CW + ' ' + CH : '0 0 ' + W + ' ' + H);
    aneis[0].setAttribute('cx', compacto ? CCX : CX);
    aneis[0].setAttribute('cy', compacto ? CCY : CY);
    aneis[0].setAttribute('r', compacto ? CR_AGENT : R_AGENT);
    return true;
  }
  medirModo();
  centralizarNoHub();
  // A largura do painel muda com a rotação do aparelho e com o teclado virtual: o modo pode
  // mudar, e quem vira o telefone não pode voltar para a margem.
  addEventListener('resize', function () {
    if (medirModo()) { applyLayout(false); applyEmphasis(); }
    centralizarNoHub();
  });

  /* ----------------------------------------------------------------- interação */

  var breadcrumb = document.querySelector('[data-graph-crumb]');
  var crumbLabel = breadcrumb ? breadcrumb.querySelector('[data-graph-crumb-label]') : null;
  var crumbBack = breadcrumb ? breadcrumb.querySelector('[data-graph-back]') : null;
  var inspector = document.querySelector('[data-graph-inspector]');
  var memory = document.querySelector('[data-graph-memory]');
  var hint = document.querySelector('[data-graph-hint]');

  var focused = null;   // drill-down
  var hovered = null;

  var gsapOk = !!window.gsap;
  var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;

  // O GSAP escreve stroke-dasharray com o comprimento antigo da linha; sem recalcular, uma
  // aresta movida no drill-down volta a aparecer tracejada/cortada.
  function syncDash(line) {
    if (!line.style.strokeDasharray) return;
    var len = line.getTotalLength();
    line.style.strokeDasharray = len;
    if (parseFloat(line.style.strokeDashoffset || '0') !== 0) line.style.strokeDashoffset = len;
  }

  function positionsFor(focusId) {
    if (compacto) return posicoesCompactas(focusId);
    var pos = {};
    if (!focusId) {
      data.nodes.forEach(function (n) { pos[n.id] = home[n.id]; });
      return pos;
    }
    var ring = neighbors[focusId].slice();
    data.nodes.forEach(function (n) {
      if (n.id === focusId) { pos[n.id] = { x: CX, y: CY }; return; }
      var i = ring.indexOf(n.id);
      if (i !== -1) {
        pos[n.id] = polar(CX, CY, R_FOCUS, -Math.PI / 2 + (i * 2 * Math.PI) / ring.length);
      } else {
        // Fora do foco: mandado para uma órbita distante, mantendo o ângulo de origem — a
        // leitura de "quem estava onde" sobrevive ao drill-down.
        pos[n.id] = polar(CX, CY, R_EXILE, angle[n.id] || 0);
      }
    });
    return pos;
  }

  function focoGeral(id) { return !id || (!!hub && id === hub.id); }

  function noAnelDoFoco(a) { return { x: CCX + CRX_FOCUS * Math.cos(a), y: CCY + CRY_FOCUS * Math.sin(a) }; }

  // Compacto: na visão geral, max no centro e os 11 agentes no anel; as skills esperam no centro,
  // escondidas. No foco, o nó tocado vai ao centro e os vizinhos formam uma elipse em volta, mais
  // alta que larga para os nomes de duas linhas não se encostarem; o max, quando é vizinho, fica
  // sempre no topo, que é onde a caixa larga dele cabe.
  function posicoesCompactas(focusId) {
    var pos = {};
    data.nodes.forEach(function (n) {
      pos[n.id] = n.type === 'Agent' ? polar(CCX, CCY, CR_AGENT, angle[n.id]) : { x: CCX, y: CCY };
    });
    if (focoGeral(focusId)) return pos;
    pos[focusId] = { x: CCX, y: CCY };
    var ring = neighbors[focusId];
    var temHub = !!hub && ring.indexOf(hub.id) !== -1;
    var outros = ring.filter(function (id) { return !hub || id !== hub.id; });
    var vagas = outros.length + (temHub ? 1 : 0);
    if (temHub) pos[hub.id] = noAnelDoFoco(-Math.PI / 2);
    outros.forEach(function (id, i) {
      pos[id] = noAnelDoFoco(-Math.PI / 2 + ((temHub ? i + 1 : i) * 2 * Math.PI) / vagas);
    });
    return pos;
  }

  // Dois vizinhos perto do pé da elipse ficam a ~86 unidades um do outro, e um nome de duas
  // linhas tem até ~106: centralizados, eles se encostavam (`security-reviewer` e
  // `page-to-markdown` no foco do external-observer, visto em 2026-09-15). Só nesses dois o
  // nome se alinha para fora; nos das laterais isso o jogaria para fora do viewBox.
  function ajustarNome(id, p, ativo) {
    var nm = nomeEls[id];
    var ancora = 'middle', dx = 0;
    if (ativo && p.y > CCY + 40) {
      var d = p.x - CCX;
      if (d < -10 && d > -60) { ancora = 'end'; dx = 16; }
      else if (d > 10 && d < 60) { ancora = 'start'; dx = -16; }
    }
    nm.setAttribute('text-anchor', ancora);
    Array.prototype.forEach.call(nm.childNodes, function (ts) { ts.setAttribute('x', dx); });
  }

  // Quem fica à vista. Fora do compacto, o drill-down de sempre; no compacto, a visão geral só
  // tem o max e os agentes, e o foco só o nó e os vizinhos.
  function visiveis() {
    if (!compacto) return focused ? [focused].concat(neighbors[focused]) : null;
    if (focoGeral(focused)) return (hub ? [hub.id] : []).concat(agents.map(function (n) { return n.id; }));
    return [focused].concat(neighbors[focused]);
  }

  // GSAP posiciona por x/y (que ele escreve como CSS transform). Animar o ATRIBUTO
  // `transform` com o AttrPlugin briga com o transform que o proprio GSAP gerencia e o
  // tween congela no meio do caminho — medido. Sem GSAP, cai no atributo mesmo.
  function place(g, x, y, animate) {
    if (!gsapOk) { g.setAttribute('transform', 'translate(' + x + ',' + y + ')'); return; }
    if (animate && !reduce) gsap.to(g, { x: x, y: y, duration: 0.55, ease: 'power2.out' });
    else gsap.set(g, { x: x, y: y });
  }

  function applyLayout(animate) {
    var pos = positionsFor(focused);
    var inFocus = visiveis();
    // Nome por extenso só no foco compacto; na visão geral compacta ficam as siglas.
    var nomeado = compacto && !focoGeral(focused);

    data.nodes.forEach(function (n) {
      var g = nodeEls[n.id], p = pos[n.id];
      var off = inFocus && inFocus.indexOf(n.id) === -1;
      g.classList.toggle('is-out', !!off);
      g.classList.toggle('is-named', nomeado && !off);
      if (nomeEls[n.id]) ajustarNome(n.id, p, nomeado && !off && n.id !== focused);
      g.setAttribute('tabindex', off ? '-1' : '0');
      place(g, p.x, p.y, animate);
    });

    edgeEls.forEach(function (line) {
      var e = line._edge;
      var a = pos[e.from], b = pos[e.to];
      var off = inFocus && (inFocus.indexOf(e.from) === -1 || inFocus.indexOf(e.to) === -1);
      // No foco compacto, só as arestas do nó tocado: as que ligam dois vizinhos cruzariam a
      // elipse por cima dos nomes.
      if (nomeado && e.from !== focused && e.to !== focused) off = true;
      line.classList.toggle('is-out', !!off);
      if (gsapOk && animate && !reduce) {
        gsap.to(line, {
          attr: { x1: a.x, y1: a.y, x2: b.x, y2: b.y },
          duration: 0.55, ease: 'power2.out',
          onUpdate: function () { syncDash(line); },
          onComplete: function () { syncDash(line); }
        });
      } else {
        line.setAttribute('x1', a.x); line.setAttribute('y1', a.y);
        line.setAttribute('x2', b.x); line.setAttribute('y2', b.y);
        syncDash(line);
      }
    });
  }

  function applyEmphasis() {
    var key = hovered || focused;
    svg.classList.toggle('has-emphasis', !!key);
    if (!key) {
      data.nodes.forEach(function (n) { nodeEls[n.id].classList.remove('is-lit', 'is-dim'); });
      edgeEls.forEach(function (l) { l.classList.remove('is-lit', 'is-dim'); });
      return;
    }
    var lit = [key].concat(neighbors[key]);
    data.nodes.forEach(function (n) {
      var on = lit.indexOf(n.id) !== -1;
      nodeEls[n.id].classList.toggle('is-lit', n.id === key);
      nodeEls[n.id].classList.toggle('is-dim', !on);
    });
    edgeEls.forEach(function (l) {
      var on = l._edge.from === key || l._edge.to === key;
      l.classList.toggle('is-lit', on);
      l.classList.toggle('is-dim', !on);
    });
  }

  /* ----------------------------------------------------------------- inspector */

  function chip(id) {
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'insp-chip';
    b.dataset.goto = id;
    b.textContent = '[[' + id + ']]';
    return b;
  }

  function block(label, build) {
    var wrap = document.createElement('div');
    wrap.className = 'insp-block';
    var h = document.createElement('div');
    h.className = 'insp-block-head mono';
    h.textContent = label;
    wrap.appendChild(h);
    var body = document.createElement('div');
    body.className = 'insp-block-body';
    build(body);
    wrap.appendChild(body);
    return wrap;
  }

  function renderInspector(id) {
    if (!inspector) return;
    var n = byId[id];
    if (!n) return;

    var kind = n.type === 'Hub' ? 'hub orquestrador'
             : n.type === 'Agent' ? 'subagente'
             : (n.status === 'referenced' ? 'skill referenciada' : 'skill vendorizada');

    var body = inspector.querySelector('[data-graph-inspector-body]');
    body.innerHTML = '';

    var head = document.createElement('div');
    head.className = 'insp-head';
    head.innerHTML = '<div class="insp-name mono"></div><div class="insp-kind mono"></div>';
    head.querySelector('.insp-name').textContent = n.id;
    head.querySelector('.insp-kind').textContent = (n.role ? n.role + ' · ' : '') + kind;
    body.appendChild(head);

    if (n.description) {
      var p = document.createElement('p');
      p.className = 'insp-desc';
      p.textContent = n.description;
      body.appendChild(p);
    }

    if (n.tools && n.tools.length) {
      body.appendChild(block('TOOLS (' + n.tools.length + ')', function (b) {
        b.className += ' insp-chips';
        n.tools.forEach(function (t) {
          var s = document.createElement('span');
          s.className = 'insp-tag mono';
          s.textContent = t;
          b.appendChild(s);
        });
      }));
    }

    if (n.model) {
      body.appendChild(block('HARNESS', function (b) {
        var s = document.createElement('p');
        s.className = 'insp-line mono';
        s.textContent = 'model: ' + n.model;
        b.appendChild(s);
      }));
    }

    var conn = outgoing(id, 'CONNECTS_TO');
    if (conn.length) {
      body.appendChild(block('CONNECTS_TO (' + conn.length + ')', function (b) {
        b.className += ' insp-chips';
        conn.forEach(function (t) { b.appendChild(chip(t)); });
      }));
    }

    var uses = outgoing(id, 'USES_SKILL');
    if (uses.length) {
      body.appendChild(block('USES_SKILL (' + uses.length + ')', function (b) {
        b.className += ' insp-chips';
        uses.forEach(function (t) { b.appendChild(chip(t)); });
      }));
    }

    var orch = outgoing(id, 'ORCHESTRATES');
    if (orch.length) {
      body.appendChild(block('ORCHESTRATES (' + orch.length + ')', function (b) {
        b.className += ' insp-chips';
        orch.forEach(function (t) { b.appendChild(chip(t)); });
      }));
    }

    // Quem aponta para cá — a leitura inversa é o que responde "quem me chama?".
    var incoming = edges.filter(function (e) { return e.to === id; });
    if (incoming.length) {
      body.appendChild(block('INVOCADO POR (' + incoming.length + ')', function (b) {
        b.className += ' insp-chips';
        incoming.forEach(function (e) { b.appendChild(chip(e.from)); });
      }));
    }

    if (n.source || n.reason) {
      body.appendChild(block('ORIGEM', function (b) {
        if (n.source) {
          var s = document.createElement('p');
          s.className = 'insp-line mono';
          s.textContent = n.source + (n.supplementType ? ' · ' + n.supplementType : '');
          b.appendChild(s);
        }
        if (n.reason) {
          var r = document.createElement('p');
          r.className = 'insp-note';
          r.textContent = n.reason;
          b.appendChild(r);
        }
        if (n.status === 'referenced') {
          var w = document.createElement('p');
          w.className = 'insp-note';
          w.textContent = 'Não vem no scaffold: instala-se via /supplements' + (n.theme ? ' ' + n.theme : '') + '.';
          b.appendChild(w);
        }
      }));
    }

    inspector.hidden = false;
    if (memory) memory.hidden = true;
  }

  function closeInspector() {
    if (inspector) inspector.hidden = true;
    if (memory) memory.hidden = false;
  }

  /* -------------------------------------------------------------------- estado */

  function setFocus(id) {
    focused = id;
    if (breadcrumb) {
      breadcrumb.hidden = !id;
      if (crumbLabel && id) crumbLabel.textContent = id;
    }
    if (hint) hint.hidden = !!id;
    applyLayout(true);
    applyEmphasis();
  }

  function open(id) {
    if (!byId[id]) return;
    setFocus(id);
    renderInspector(id);
    var g = nodeEls[id];
    if (g && document.activeElement !== g) g.focus({ preventScroll: true });
  }

  function reset() {
    setFocus(null);
    closeInspector();
  }

  data.nodes.forEach(function (n) {
    var g = nodeEls[n.id];
    g.addEventListener('click', function () { open(n.id); });
    g.addEventListener('keydown', function (ev) {
      if (ev.key === 'Enter' || ev.key === ' ' || ev.key === 'Spacebar') {
        ev.preventDefault();
        open(n.id);
      }
    });
    g.addEventListener('mouseenter', function () { hovered = n.id; applyEmphasis(); });
    g.addEventListener('mouseleave', function () { hovered = null; applyEmphasis(); });
    g.addEventListener('focus', function () { hovered = n.id; applyEmphasis(); });
    g.addEventListener('blur', function () { hovered = null; applyEmphasis(); });
  });

  if (crumbBack) crumbBack.addEventListener('click', reset);
  if (inspector) {
    inspector.addEventListener('click', function (ev) {
      var close = ev.target.closest('[data-graph-inspector-close]');
      if (close) { reset(); return; }
      var go = ev.target.closest('[data-goto]');
      if (go) open(go.dataset.goto);
    });
  }

  document.addEventListener('keydown', function (ev) {
    if (ev.key !== 'Escape') return;
    if (focused || (inspector && !inspector.hidden)) reset();
  });

  applyLayout(false);
  host.classList.add('is-live');
})();

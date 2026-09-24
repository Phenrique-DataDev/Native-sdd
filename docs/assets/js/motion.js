/*!
 * motion.js — Frente B (motion/GSAP) · landing docs/
 *
 * Contrato: .claude/sdd/design-canvas/compiler/CONTRATO.md §2 (ganchos de motion).
 * Postura: docs/DESIGN.md §Motion — reveal realça, nunca gateia; sem bounce/elastic;
 * alternativa estática obrigatória em reduced-motion.
 *
 * REGRA DURA: o site tem de ficar íntegro com JS desligado ou com GSAP ausente. O CSS já
 * entrega o estado FINAL de cada elemento; este arquivo só regride para o estado inicial
 * da animação, e só quando pode de fato animar (gsap presente + prefers-reduced-motion
 * não for "reduce" onde aplicável). Por isso quase tudo aqui usa gsap.from()/tweens que
 * partem do estado final visível — nunca gsap.to() que dependa de um estado inicial que
 * só o JS criaria.
 */
(function () {
  'use strict';

  // ---------------------------------------------------------------------
  // Guarda-mestre — sem isto, nada abaixo executa.
  // ---------------------------------------------------------------------
  if (typeof window === 'undefined' || !window.gsap) return;

  var gsap = window.gsap;
  var ScrollTrigger = window.ScrollTrigger || null;
  var hasST = !!ScrollTrigger;
  if (hasST) gsap.registerPlugin(ScrollTrigger);

  var toArray = gsap.utils.toArray;
  var mm = gsap.matchMedia();

  // ---------------------------------------------------------------------
  // Tokens de movimento — lidos do CSS, não redeclarados aqui.
  //
  // As durações e a amplitude vivem no `:root` de site.css. Este arquivo as LÊ em vez de
  // trazer números próprios: com duas fontes de verdade, ajustar o caráter do movimento
  // exigiria mudar o CSS e depois caçar as constantes equivalentes espalhadas por aqui — e
  // uma das duas ficaria para trás. Assim, girar `--motion-intensidade` ou uma duração no
  // CSS muda o site inteiro, GSAP incluído.
  //
  // Ler acontece uma vez, no setup: `getComputedStyle` força reflow, e chamá-lo por tween
  // seria layout thrashing pelo preço de um valor que não muda durante a sessão.
  // ---------------------------------------------------------------------
  var raiz = document.documentElement;
  function token(nome, padrao) {
    try {
      var bruto = getComputedStyle(raiz).getPropertyValue(nome).trim();
      if (!bruto) return padrao;
      if (bruto.slice(-2) === 'ms') return parseFloat(bruto) / 1000;
      if (bruto.slice(-1) === 's') return parseFloat(bruto);
      var n = parseFloat(bruto);
      return isNaN(n) ? padrao : n;
    } catch (e) {
      return padrao;
    }
  }

  // Os padrões são os valores que estavam cravados aqui antes dos tokens existirem: se o CSS
  // não carregar, o movimento continua o mesmo em vez de virar zero.
  var DUR = {
    instantaneo: token('--dur-instantaneo', 0.09),
    rapido: token('--dur-rapido', 0.18),
    medio: token('--dur-medio', 0.7),
    lento: token('--dur-lento', 1.6)
  };
  var INTENSIDADE = token('--motion-intensidade', 1);

  // Toda amplitude de deslocamento passa por aqui. Com intensidade 0 o movimento vira só
  // opacidade — que é o mesmo destino que `prefers-reduced-motion` já produz por outro caminho.
  function amp(valor) {
    return valor * INTENSIDADE;
  }

  // Exposto de propósito, e só isto: sem uma janela para os valores efetivamente lidos, a
  // promessa de que "girar o token muda o site" não teria como ser verificada de fora — seria
  // uma afirmação no comentário, não um fato testável. Ver `tokens governam o movimento` em
  // tools/site-tests/specs/motion.spec.mjs.
  window.__MOTION_TOKENS__ = { dur: DUR, intensidade: INTENSIDADE };

  // ---------------------------------------------------------------------
  // Helpers compartilhados
  // ---------------------------------------------------------------------

  // Loops contínuos (pulsos, feixe, sinal do grafo) precisam pausar quando a aba some —
  // regra dura: "nada de animação decorativa em loop infinito que rode fora da viewport".
  // ScrollTrigger já cuida do "fora da viewport" (toggleActions); isto cobre o outro eixo,
  // a aba oculta, que o ScrollTrigger não enxerga.
  var liveLoops = [];
  function registerLoop(anim) {
    if (anim) liveLoops.push(anim);
    return anim;
  }
  document.addEventListener('visibilitychange', function () {
    liveLoops.forEach(function (anim) {
      if (!anim) return;
      if (document.hidden) anim.pause();
      else anim.resume();
    });
  });

  // will-change: aplicado só durante a janela em que o elemento realmente anima, e
  // removido depois — nunca cravado em dezenas de elementos (regra dura de performance).
  function willChangeDuring(el, onEnter, onLeave) {
    return {
      onEnter: function () { gsap.set(el, { willChange: 'transform' }); if (onEnter) onEnter(); },
      onLeave: function () { gsap.set(el, { willChange: 'auto' }); if (onLeave) onLeave(); },
      onEnterBack: function () { gsap.set(el, { willChange: 'transform' }); },
      onLeaveBack: function () { gsap.set(el, { willChange: 'auto' }); }
    };
  }

  // -----------------------------------------------------------------------
  // Rede de segurança contra "reveal preso" — BUGFIX pós-integração real.
  //
  // Causa confirmada em Chrome real: o pin do `#motor` tem `end` calculado por
  // FUNÇÃO (depende da largura medida do ribbon), e o `ScrollTrigger.refresh()`
  // que disparamos em `document.fonts.ready` reavalia essa função. Se a fonte
  // trocar a largura renderizada das cassetes, o comprimento total do pin muda,
  // o que desloca a posição de TUDO que vem depois no documento (topologia,
  // instrumentação, execução) — inclusive depois que o usuário já passou por
  // essas seções e o reveal/contador/desenho já tinha disparado. Um trigger
  // "once" ou um reveal cujo `start` recém-recalculado ficou abaixo do scroll
  // atual pode nunca mais disparar (ou, com toggleActions "reverse", regride
  // e fica preso em opacity 0 para sempre) — violação direta da regra dura de
  // que nenhum gancho pode gatear visibilidade.
  //
  // Duas camadas de correção:
  //   1) nenhum reveal "de uma vez só" usa mais toggleActions com "reverse"
  //      (abaixo, nas seções 5/8) — uma vez revelado, nunca regride sozinho;
  //   2) esta rede: registra cada grupo que precisa terminar num estado final
  //      determinado, e varre periodicamente — se o elemento já deveria estar
  //      visível (já passamos por ele, ou ele já está na viewport) mas ainda
  //      não chegou ao estado final, força o estado final na marra. Roda após
  //      todo `refresh()` do ScrollTrigger (a nossa e qualquer outra, ex.:
  //      resize) e também num timeout fixo, independente de qualquer evento —
  //      por isso "de segurança": não depende de adivinhar a causa exata.
  var finalizers = [];
  // Declarado aqui (e não só na linha do setInterval) porque sweepFinalizers pode
  // rodar antes dela — via evento de refresh do ScrollTrigger durante o setup.
  var sweepTimer = null;
  /**
   * `esperarAte` (opcional, timestamp de `performance.now()`) é a janela em que a animação tem
   * direito de estar rodando. Sem ela a rede vira guilhotina, e isso não é hipótese: a entrada
   * do hero cabia em 940ms e a varredura de abertura passou a durar ~1,6s — o `setInterval` de
   * 1s pegava as peças no meio do caminho, via "não terminou" + "está visível", concluía que
   * estavam presas e as estalava para o estado final. A abertura sumia inteira, e o pior é que
   * sumia em silêncio: a página ficava certa, só sem animação nenhuma.
   *
   * O default 0 preserva o comportamento de todos os chamadores anteriores — os reveals por
   * scroll continuam podendo ser resgatados no primeiro varrimento.
   */
  function registerFinalizer(els, isDone, finalize, esperarAte) {
    var list = toArray(els);
    if (!list.length) return;
    finalizers.push({ els: list, isDone: isDone, finalize: finalize, esperarAte: esperarAte || 0 });
  }
  // Forçar o estado final não basta com gsap.set() quando a tween original ainda
  // está "viva" (ex.: o ticker do GSAP atrasou — aba em segundo plano, tab throttling
  // do navegador): a tween continua rendendo por cima no próximo tick e desfaz o
  // set. killTweensOf() primeiro garante que o valor forçado realmente pega.
  function forceFinalState(els, vars, onlyProps) {
    // onlyProps restringe o kill às propriedades daquela animação específica —
    // importante quando o mesmo elemento também carrega OUTRA tween legítima
    // (ex.: as arestas do grafo têm o traçado E o pulso contínuo; forçar o
    // traçado não pode matar o pulso que já esteja rodando).
    gsap.killTweensOf(els, onlyProps);
    gsap.set(els, vars);
  }
  function alreadyPassedOrVisible(el) {
    var rect = el.getBoundingClientRect();
    // top < innerHeight cobre dois casos: já rolamos para além do elemento
    // (rect.top negativo) OU ele já está, ao menos em parte, na viewport.
    return rect.top < window.innerHeight;
  }
  function sweepFinalizers() {
    var pendentes = 0;
    finalizers.forEach(function (group) {
      if (group.isDone()) return;
      // Ainda dentro da própria janela: está RODANDO, não presa. Conta como pendente para a
      // rede não se desligar antes de a animação chegar ao fim, mas não é tocada.
      if (group.esperarAte && performance.now() < group.esperarAte) {
        pendentes++;
        return;
      }
      if (group.els.some(alreadyPassedOrVisible)) group.finalize();
      // recontado DEPOIS do finalize: o que acabou de ser forçado já não conta
      if (!group.isDone()) pendentes++;
    });
    // A rede é um seguro, não um serviço: quando não há mais nada pendente ela
    // se desliga. Sem isso o setInterval abaixo varreria de segundo em segundo
    // pelo resto da vida da página, muito depois de ter deixado de ter função.
    if (!pendentes && sweepTimer !== null) {
      clearInterval(sweepTimer);
      sweepTimer = null;
    }
  }
  if (hasST) {
    // cobre qualquer refresh futuro (resize, conteúdo dinâmico), não só o do load.
    ScrollTrigger.addEventListener('refresh', sweepFinalizers);
  }
  // Varredura no próprio evento de scroll — direto, SEM requestAnimationFrame.
  // rAF pode ficar preso indefinidamente com a aba em segundo plano/sem foco (é
  // exatamente o que também trava o ticker interno do GSAP nesse cenário — medido
  // durante o desenvolvimento: 0 frames de rAF em 2s reais com a aba sem foco). A
  // checagem em si é barata (a maioria dos grupos já sai no primeiro `if`), então
  // não precisa de throttle: correr a cada evento de scroll é seguro.
  window.addEventListener('scroll', sweepFinalizers, { passive: true });
  window.addEventListener('resize', sweepFinalizers, { passive: true });
  // Rede de segurança de verdade: um `setInterval` roda independente de rAF, de
  // scroll e do ScrollTrigger — pega tanto o que já devia estar visível ANTES de
  // qualquer scroll (ex.: hero) quanto qualquer coisa que emperre bem depois do
  // load. Um `setTimeout` único falharia se disparasse antes do usuário chegar
  // à seção afetada; o intervalo garante uma nova chance a cada segundo.
  // Guardado para que sweepFinalizers() possa se desligar quando não sobrar
  // nenhum grupo pendente (ver clearInterval lá em cima).
  sweepTimer = setInterval(sweepFinalizers, 1000);

  // Split-por-linha sem SplitText (Club GreenSock, não vendorizado). O design já força
  // quebras de linha semânticas com <br> dentro do h1/h2 (ver Main.dc.html/ProblemSpace.dc.html),
  // então dividir por <br> é suficiente para a máscara por linha pedida no contrato — não
  // precisamos medir glifo a glifo. Só roda quando vamos de fato animar (chamado a partir
  // do branch não-reduced de matchMedia); em reduced-motion o texto fica como está no HTML.
  function splitByLine(el) {
    if (el.__motionLines) return el.__motionLines;
    var parts = el.innerHTML.split(/<br\s*\/?>/i);
    el.innerHTML = '';
    var inners = [];
    parts.forEach(function (part) {
      var mask = document.createElement('span');
      mask.style.display = 'block';
      mask.style.overflow = 'hidden';
      var inner = document.createElement('span');
      inner.style.display = 'block';
      inner.innerHTML = part;
      mask.appendChild(inner);
      el.appendChild(mask);
      inners.push(inner);
    });
    el.__motionLines = inners;
    return inners;
  }

  // ---------------------------------------------------------------------
  // A VARREDURA DE ABERTURA — a geometria que decide QUANDO cada peça entra.
  //
  // Uma cabeça de leitura atravessa o hero da esquerda para a direita, uma vez, em
  // velocidade constante. Cada peça entra quando a cabeça alcança a borda esquerda dela:
  // o atraso sai da POSIÇÃO MEDIDA, nunca de um stagger fixo. É o que separa "o compilador
  // lendo a primeira dobra" de um brilho decorativo passando por cima, e a diferença não é
  // retórica — os três CTAs e os três números das estatísticas ficam lado a lado, então sob
  // a régua da posição eles cascateiam, e sob um stagger fixo entrariam na ordem do DOM
  // mesmo que o desenho os pusesse ao contrário. A mutação `varredura-sem-posicao` apaga
  // exatamente esta linha.
  //
  // Onde várias peças partilham a mesma borda esquerda — a coluna de texto inteira —, o
  // empate é desfeito pela ordem de leitura, com um passo curto. Sem isso a coluna entraria
  // num instante só e a varredura não teria o que afirmar na metade esquerda do hero.
  //
  // POR QUE ISTO NÃO CUSTA LCP (medido em 2026-09-07, `tools/site-tests/medir-lcp.mjs`):
  // o padrão do arquivo é o CSS entregar o estado FINAL e o JS regredir a partir dele. O
  // primeiro quadro pinta com o `h1` visível, o LCP é carimbado ali, e só depois o GSAP
  // regride para animar. Medido: 208ms no desktop, com e sem varredura, o mesmo alvo
  // (`h1.hero-title`). Inverter isso — pôr o estado inicial no CSS — empurraria o LCP pela
  // duração inteira da passagem; é o que a mutação `varredura-esconde-no-css` demonstra.
  // ---------------------------------------------------------------------
  var VARREDURA = {
    // A passagem dura menos que `--dur-lento` inteiro: 1600ms é a régua da coreografia de
    // abertura, e a cabeça tem de chegar ao fim antes de a última peça terminar de entrar.
    dur: DUR.lento * 0.75,
    // O viés vertical, somado ao horizontal. Curto de propósito: quem manda é a cabeça que
    // atravessa; isto só desempata quem ela alcança no mesmo instante.
    vies: 0.25
  };

  /**
   * Quando esta peça termina de entrar, em `performance.now()`. É o que a rede de finalizadores
   * usa para distinguir "ainda rodando" de "presa" — ver `registerFinalizer`. A margem cobre o
   * atraso entre o instante em que o GSAP fecha a tween e o quadro em que o navegador o pinta.
   */
  function fimDaEntrada(atrasoSeg, duracaoSeg) {
    return performance.now() + (atrasoSeg + duracaoSeg) * 1000 + 250;
  }

  /** O campo que a cabeça percorre. Medido uma vez por rodada — `getBoundingClientRect` em laço é thrashing. */
  function campoDaVarredura(hero) {
    var r = hero.getBoundingClientRect();
    return { esquerda: r.left, largura: r.width || 1, topo: r.top, altura: r.height || 1 };
  }

  /**
   * O atraso de cada peça, em segundos, e a ordem em que a cabeça as encontra.
   *
   * Devolve um `Map` em vez de anotar os elementos: heroMotion (que anima o `h1` por linha) e
   * a varredura (que anima o resto) precisam da MESMA régua, e duas cópias da fórmula
   * divergiriam no primeiro ajuste — o mesmo motivo pelo qual as durações vivem no CSS.
   */
  function atrasosDaVarredura(hero, pecas) {
    var campo = campoDaVarredura(hero);
    var mapa = new Map();

    // Uma FRENTE DE ONDA contínua, não um agrupamento em colunas.
    //
    // A primeira versão classificava as peças em colunas por proximidade da borda esquerda e
    // desempatava dentro de cada uma. Deu errado de duas maneiras, as duas medidas em
    // 2026-09-07: o comparador (`|Δx| > tol ? Δx : Δy`) não é uma ordem total — não é
    // transitivo, e `Array.sort` fica livre para devolver qualquer permutação; e a tolerância
    // de 24px engolia o botão do GitHub, a 98px, dentro da coluna de texto, a 116px, jogando-o
    // para o FIM da cascata mesmo sendo o mais à esquerda da tela.
    //
    // Isto aqui não tem ordenação, nem clusters, nem tolerância: cada peça recebe o instante
    // em que a frente a alcança, e ponto. O termo horizontal manda (é a cabeça atravessando);
    // o vertical só inclina a frente o bastante para que uma coluna alinhada à esquerda entre
    // de cima para baixo, em vez de num piscar só.
    pecas.forEach(function (el) {
      var r = el.getBoundingClientRect();
      var fx = Math.min(Math.max((r.left - campo.esquerda) / campo.largura, 0), 1);
      var fy = Math.min(Math.max((r.top - campo.topo) / campo.altura, 0), 1);
      mapa.set(el, fx * VARREDURA.dur + fy * VARREDURA.vies);
    });

    return { campo: campo, atrasos: mapa };
  }

  // ---------------------------------------------------------------------
  // 1. HERO — parallax das 5 camadas do monólito, pulso do feixe, reveal por linha
  // ---------------------------------------------------------------------
  (function heroMotion() {
    var hero = document.getElementById('hero');
    if (!hero) return;
    var monolith = hero.querySelector('[data-motion="hero-monolith"]');
    var beam = hero.querySelector('[data-motion="beam"]');
    var splitTargets = toArray('[data-motion="split"]', hero);

    // CORRIGIDO em 2026-09-07, e o defeito era grande: este bloco NUNCA rodou.
    //
    // Estava escrito `mm.add({ reduceMotion: '(prefers-reduced-motion: reduce)' }, fn)`, uma
    // condição só, e o `gsap.matchMedia()` invoca a função quando ALGUMA condição casa. Sob
    // `no-preference` — o caso de quase todo visitante — nenhuma casava, então o pulso do feixe,
    // o parallax das cinco camadas e o reveal por linha do título nunca existiram. O `motorMotion`
    // usa a mesma forma de objeto e funciona porque tem DUAS condições (`isDesktop` casa); os
    // outros seis blocos deste arquivo usam a forma de string, que é a que sempre funcionou.
    //
    // Como passou despercebido: o defeito não deixa buraco. A regra dura do arquivo é o CSS
    // entregar o estado final, então uma animação que não roda produz exatamente a página
    // correta, parada. Nenhum caso de "nada ficou invisível" percebe a diferença — e é por isso
    // que o caso novo `o hero anima de fato sob no-preference` afirma o contrário: que existe
    // tween viva. Achado pelo instrumento de LCP, que mediu o título entrando em 208ms sem
    // reveal nenhum. Mutação: `hero-sem-condicao`.
    mm.add(
      '(prefers-reduced-motion: no-preference)',
      function () {

        // O reveal por linha do h1 saiu daqui: quem o comanda agora é a varredura de abertura
        // (bloco 1b), para que o título e o resto da dobra obedeçam à MESMA régua de posição.
        // Deixá-lo aqui com um `delay` próprio faria o título entrar num tempo que a cabeça de
        // leitura não justifica — e a varredura passaria a ser enfeite por cima de outra coisa.

        // Pulso contínuo do feixe — vertical, linear (é um "sinal" percorrendo, não uma
        // mola: sem elastic/bounce, conforme a postura de motion do projeto).
        if (beam) {
          var beamTween = gsap.fromTo(
            beam,
            { y: '-=170' },
            { y: '+=590', duration: 3.2, ease: 'none', repeat: -1 }
          );
          registerLoop(beamTween);

          // O hero3d.js avisa quando o monólito WebGL assume o palco. A partir daí o SVG está
          // com `visibility: hidden`, e este tween seguiria rodando para sempre num elemento
          // que ninguém vê — junto com o parallax das camadas. `kill()` e não `pause()`: não
          // há caminho de volta ao SVG enquanto o canvas estiver de pé, e um tween pausado
          // ainda ocupa a lista de loops que o visibilitychange percorre a cada troca de aba.
          window.addEventListener('hero3d:ready', function () {
            beamTween.kill();
            if (hasST) {
              ScrollTrigger.getAll().forEach(function (st) {
                if (st.trigger === hero && st.vars.scrub) st.kill();
              });
            }
          }, { once: true });

          if (hasST) {
            ScrollTrigger.create({
              trigger: hero,
              start: 'top bottom',
              end: 'bottom top',
              onToggle: function (self) {
                if (self.isActive) beamTween.resume();
                else beamTween.pause();
              }
            });
          }
        }

        // Parallax escalonado das camadas — cada `data-layer` desloca em velocidade
        // diferente ao longo do próprio scroll do hero (scrub: liga direto ao progresso,
        // sem inércia extra, para não competir com o scroll do usuário).
        if (monolith && hasST) {
          var layers = toArray('[data-layer]', monolith);
          layers.forEach(function (layer) {
            var depth = parseInt(layer.getAttribute('data-layer'), 10);
            if (isNaN(depth)) return;
            // Camada central (2) quase parada; extremos (0 e 4) com mais curso — dá
            // profundidade sem que nenhuma camada "descole" demais da composição.
            var travel = amp((depth - 2) * 22);
            gsap.to(layer, {
              y: travel,
              ease: 'none',
              scrollTrigger: {
                trigger: hero,
                start: 'top top',
                end: 'bottom top',
                scrub: true
              }
            });
          });
        }
      }
    );
  })();

  // ---------------------------------------------------------------------
  // 1b. A VARREDURA DE ABERTURA — a cabeça de leitura atravessa a primeira dobra
  //
  // O que ela afirma: a página é lida antes de existir. A cabeça entra pela esquerda, cruza
  // a coluna de texto, os três CTAs e os três números, e sai pela direita depois do monólito;
  // cada peça assume o estado final no instante em que é alcançada. Uma passagem, uma direção,
  // velocidade constante — sem ida e volta, sem repetição, sem brilho que persiste.
  //
  // Regras duras herdadas do cabeçalho deste arquivo, todas com caso na suíte:
  //   · sem GSAP nada disto roda e o hero já está inteiro (guarda-mestre, topo do arquivo);
  //   · sob `prefers-reduced-motion: reduce` não há cabeça nem regressão de estado;
  //   · o CSS entrega o estado final, o JS só regride — por isso o LCP não se move.
  // ---------------------------------------------------------------------
  (function varreduraDeAbertura() {
    var hero = document.getElementById('hero');
    if (!hero) return;

    var cabeca = hero.querySelector('[data-motion="cabeca"]');
    var titulos = toArray('[data-motion="split"]', hero);
    // As peças que a cabeça revela. Os CTAs e as estatísticas entram individualmente, e não
    // como bloco, porque é justamente ali que existe espalhamento horizontal para a régua da
    // posição significar alguma coisa — três botões lado a lado e três números lado a lado.
    var pecas = toArray('.eyebrow, .hero-sub, .hero-author, .hero-ctas > *, .hero-stat, .hero-art', hero);

    if (!titulos.length && !pecas.length) return;

    // Forma de STRING, não de objeto — ver a nota no bloco 1. Uma condição só, em objeto, nunca
    // casa sob `no-preference` e o bloco inteiro vira letra morta sem deixar rastro.
    mm.add(
      '(prefers-reduced-motion: no-preference)',
      function () {

        // A régua é calculada sobre TODAS as peças de uma vez, títulos incluídos: a ordem em
        // que a cabeça as encontra depende de onde elas estão umas em relação às outras.
        var medida = atrasosDaVarredura(hero, titulos.concat(pecas));
        var atrasos = medida.atrasos;

        titulos.forEach(function (el) {
          var lines = splitByLine(el);
          gsap.from(lines, {
            yPercent: amp(112),
            autoAlpha: 0,
            duration: DUR.medio * 1.2,
            ease: 'power3.out',
            // O stagger por linha continua, mas agora pendurado no instante em que a cabeça
            // alcança o título — não num `delay` fixo que ignorava onde ele está.
            stagger: 0.09,
            delay: atrasos.get(el) || 0
          });
          registerFinalizer(
            lines,
            function () { return lines.every(function (l) { return parseFloat(getComputedStyle(l).opacity) > 0.95; }); },
            function () { forceFinalState(lines, { autoAlpha: 1, yPercent: 0 }); },
            // O stagger por linha empurra o fim para depois da última linha, não da primeira.
            fimDaEntrada((atrasos.get(el) || 0) + 0.09 * (lines.length - 1), DUR.medio * 1.2)
          );
        });

        pecas.forEach(function (el) {
          gsap.from(el, {
            // Deslocamento no eixo X, e pequeno: a peça é empurrada pela cabeça que passa, não
            // sobe do chão. `amp()` mantém a amplitude sob o controle de `--motion-intensidade`,
            // que em 0 reduz tudo a opacidade — o mesmo destino do reduced-motion, por outra via.
            x: amp(-18),
            autoAlpha: 0,
            duration: DUR.medio * 0.6,
            ease: 'power2.out',
            delay: atrasos.get(el) || 0
          });
          registerFinalizer(
            [el],
            function () { return parseFloat(getComputedStyle(el).opacity) > 0.95; },
            function () { forceFinalState([el], { autoAlpha: 1, x: 0 }); },
            fimDaEntrada(atrasos.get(el) || 0, DUR.medio * 0.6)
          );
        });

        // A cabeça. Existe só durante a passagem: entra acesa na borda esquerda, atravessa em
        // velocidade constante (`ease: 'none'` — um cursor de leitura não acelera) e apaga ao
        // chegar. Fora desta janela ela é `opacity: 0` pelo CSS, e sem JS nunca acende.
        if (cabeca) {
          var tl = gsap.timeline();
          tl.set(cabeca, { x: 0, autoAlpha: 1 })
            .to(cabeca, { x: medida.campo.largura, duration: VARREDURA.dur, ease: 'none' })
            .to(cabeca, { autoAlpha: 0, duration: DUR.rapido, ease: 'none' }, '-=' + DUR.rapido);

          // Se a rodada morrer no meio (troca de aba durante a carga, refresh do ScrollTrigger),
          // o que não pode sobrar é uma barra laranja parada no meio do hero.
          registerFinalizer(
            [cabeca],
            function () { return parseFloat(getComputedStyle(cabeca).opacity) < 0.05; },
            function () { forceFinalState([cabeca], { autoAlpha: 0 }); },
            fimDaEntrada(0, VARREDURA.dur)
          );
        }
      }
    );
  })();

  // ---------------------------------------------------------------------
  // 2. #paradoxo — entropia derivando para fora × lâminas comprimindo (scrub)
  // ---------------------------------------------------------------------
  (function paradoxoMotion() {
    if (!hasST) return;
    var section = document.getElementById('paradoxo');
    if (!section) return;

    mm.add('(prefers-reduced-motion: no-preference)', function () {
      toArray('[data-motion="entropy"]', section).forEach(function (group) {
        var vectors = toArray('path, rect, circle', group);
        if (!vectors.length) return;
        var entropyWc = willChangeDuring(group);
        var tl = gsap.timeline({
          scrollTrigger: {
            trigger: section,
            start: 'top 75%',
            end: 'bottom 35%',
            scrub: 0.6,
            onEnter: entropyWc.onEnter,
            onLeave: entropyWc.onLeave,
            onEnterBack: entropyWc.onEnterBack,
            onLeaveBack: entropyWc.onLeaveBack
          }
        });
        // Cada vetor deriva numa direção própria (ângulo distribuído no círculo) — é o
        // "colapso de contexto": nada convergente, tudo se afastando do desenho original.
        vectors.forEach(function (vector, i) {
          var angle = (i / vectors.length) * Math.PI * 2;
          tl.to(
            vector,
            {
              x: '+=' + amp(Math.cos(angle) * 34).toFixed(1),
              y: '+=' + amp(Math.sin(angle) * 26).toFixed(1),
              opacity: 0.12,
              ease: 'none'
            },
            0
          );
        });
      });

      toArray('[data-motion="contained"]', section).forEach(function (group) {
        var blades = toArray('line, rect', group);
        if (!blades.length) return;
        var mid = (blades.length - 1) / 2;
        var containedWc = willChangeDuring(group);
        var tl2 = gsap.timeline({
          scrollTrigger: {
            trigger: section,
            start: 'top 75%',
            end: 'bottom 35%',
            scrub: 0.6,
            onEnter: containedWc.onEnter,
            onLeave: containedWc.onLeave,
            onEnterBack: containedWc.onEnterBack,
            onLeaveBack: containedWc.onLeaveBack
          }
        });
        // Compressão: cada lâmina anda em direção ao centro da pilha — o mesmo vetor,
        // agora contido, "encaixando" em vez de se dispersar.
        blades.forEach(function (blade, i) {
          var approach = amp((mid - i) * 5);
          tl2.to(blade, { y: '+=' + approach.toFixed(1), ease: 'none' }, 0);
        });
      });
    });
  })();

  // ---------------------------------------------------------------------
  // 3. #motor — ribbon com pin + scrub horizontal, fases ativas na linha de 50vw
  // ---------------------------------------------------------------------
  (function motorMotion() {
    var section = document.getElementById('motor');
    if (!section) return;
    var ribbon = section.querySelector('[data-motion="ribbon"]');
    var phases = toArray('[data-phase]', section);
    if (!phases.length) return;

    mm.add(
      {
        isDesktop: '(min-width: 900px)',
        reduceMotion: '(prefers-reduced-motion: reduce)'
      },
      function (ctx) {
        var isDesktop = ctx.conditions.isDesktop;
        var reduceMotion = ctx.conditions.reduceMotion;

        // Reduced-motion OU tela estreita: as fases empilham (layout já resolvido pelo
        // CSS da frente A) — sem pin, sem scroll horizontal. Só um reveal simples e
        // não-scrubado por fase, se motion for permitido.
        if (!ribbon || !isDesktop || reduceMotion) {
          if (!reduceMotion && hasST) {
            phases.forEach(function (phase) {
              gsap.from(phase, {
                autoAlpha: 0,
                y: amp(22),
                duration: DUR.medio * 0.85,
                ease: 'power2.out',
                // sem "reverse": uma vez revelada, a fase nunca regride sozinha.
                scrollTrigger: { trigger: phase, start: 'top 88%', toggleActions: 'play none none none' }
              });
              registerFinalizer(
                phase,
                function () { return parseFloat(getComputedStyle(phase).opacity) > 0.95; },
                function () { forceFinalState(phase, { autoAlpha: 1, y: 0 }); }
              );
            });
          }
          return;
        }

        if (!hasST) return; // sem ScrollTrigger não há como fazer pin/scrub — fica estático.

        // Medições cacheadas fora do onUpdate: ler layout a cada frame de scroll é o
        // exato "layout thrashing" que a skill de performance pede para evitar. Só
        // recalculamos em resize/refresh, nunca durante o scrub.
        var phaseMeta = [];
        var railLeft = 0;
        function measure() {
          gsap.set(ribbon, { x: 0 });
          railLeft = ribbon.getBoundingClientRect().left + window.scrollX;
          phaseMeta = phases.map(function (phase) {
            return { el: phase, left: phase.offsetLeft, width: phase.offsetWidth };
          });
        }
        measure();

        function travelDistance() {
          return Math.max(0, ribbon.scrollWidth - ribbon.parentElement.clientWidth);
        }

        var ribbonWc = willChangeDuring(ribbon);
        var st = ScrollTrigger.create({
          trigger: section,
          start: 'top top',
          end: function () { return '+=' + (travelDistance() + window.innerHeight * 0.4); },
          pin: true,
          scrub: 0.8,
          // Sem `anticipatePin` (D-25): na rolagem rápida ele engatava o pin até 400px antes do
          // início (medido a 1024px, 400px por passo da roda), e a seção saltava 420px para o topo
          // antes de chegar lá. Sem ele o pin engata no quadro em que a rolagem cruza o início.
          invalidateOnRefresh: true,
          onRefresh: measure,
          onEnter: ribbonWc.onEnter,
          onLeave: ribbonWc.onLeave,
          onEnterBack: ribbonWc.onEnterBack,
          onLeaveBack: ribbonWc.onLeaveBack,
          onUpdate: function (self) {
            var x = -travelDistance() * self.progress;
            gsap.set(ribbon, { x: x });
            // linha de corte fixa em 50vw — a fase cujo retângulo cruza esse ponto vira ativa
            var viewportCut = window.innerWidth / 2;
            phaseMeta.forEach(function (meta) {
              var screenLeft = railLeft - window.scrollX + meta.left + x;
              var active = screenLeft <= viewportCut && screenLeft + meta.width >= viewportCut;
              meta.el.classList.toggle('is-active', active);
            });
          }
        });

        // Sem viagem, sem pin (D-25, 2026-09-15). De ~1100px para cima as cinco cassetes cabem na
        // tela e a viagem é zero. Mantido, o pin fazia duas coisas ruins no mesmo trecho:
        //   - segurava a página por 40% da janela com nada se mexendo (300 de 360px a 1280, 1440
        //     e 1920 — a "agarrada" do primeiro relato);
        //   - reduzido a comprimento zero (a primeira correção), o `anticipatePin` ainda o engatava
        //     cedo na rolagem rápida: a seção virava `fixed` 400px antes, o título saltava 420px
        //     para cima e voltava 400px — a "engasgada" do segundo relato.
        // Desligado, o ScrollTrigger desfaz o pin e o espaçador, e a seção rola como as outras.
        // Reavaliado a cada refresh, porque fonte, resize e o crescimento tardio do hero mudam a
        // largura do ribbon.
        var pinLigado = true;
        function sincronizarPin() {
          var precisa = travelDistance() > 0;
          if (precisa === pinLigado) return;
          pinLigado = precisa;
          if (precisa) st.enable(); else st.disable();
        }
        sincronizarPin();
        ScrollTrigger.addEventListener('refresh', sincronizarPin);

        window.addEventListener('resize', function () {
          measure();
          ScrollTrigger.refresh();
        });

        return function () {
          // cleanup automático do matchMedia ao sair do breakpoint desktop
          ScrollTrigger.removeEventListener('refresh', sincronizarPin);
          st.kill();
        };
      }
    );
  })();

  // ---------------------------------------------------------------------
  // 4. #topologia — desenho das arestas (stroke-dashoffset) + pulsos contínuos
  // ---------------------------------------------------------------------
  (function topologiaMotion() {
    var section = document.getElementById('topologia');
    if (!section) return;
    var graph = section.querySelector('[data-motion="graph"]');
    if (!graph) return;

    mm.add('(prefers-reduced-motion: no-preference)', function () {
      var edges = toArray('path, line', graph).filter(function (edge) {
        return typeof edge.getTotalLength === 'function';
      });
      if (!edges.length) return;

      edges.forEach(function (edge) {
        var len = edge.getTotalLength ? edge.getTotalLength() : 400;
        gsap.set(edge, { strokeDasharray: len, strokeDashoffset: len });
      });

      var pulseStarted = false;

      var drawTl = gsap.timeline({
        scrollTrigger: hasST
          ? { trigger: section, start: 'top 65%', once: true }
          : undefined,
        onComplete: startPulse
      });
      drawTl.to(edges, {
        strokeDashoffset: 0,
        duration: DUR.lento,
        ease: 'power2.out',
        stagger: 0.06
      });

      // Sem ScrollTrigger, o `once` acima não existe — dispara direto (degrada para
      // "anima ao carregar" em vez de "anima ao entrar na viewport", mas não quebra nada).
      if (!hasST) drawTl.play();

      // Rede de segurança: se o trigger "once" nunca chegar a disparar (ex.: um
      // refresh tardio recalculou a posição da seção depois que o usuário já
      // passou por ela — ver comentário na definição de `registerFinalizer`),
      // força o traçado completo assim que o grafo já deveria estar visível.
      registerFinalizer(
        graph,
        function () {
          return edges.every(function (edge) { return parseFloat(edge.style.strokeDashoffset || '0') === 0; });
        },
        function () {
          forceFinalState(edges, { strokeDashoffset: 0 }, 'strokeDashoffset');
          if (!pulseStarted) startPulse();
        }
      );

      function startPulse() {
        pulseStarted = true;
        // Pulso de sinal contínuo nas arestas — sutil (opacidade), nunca some de vez
        // (autoAlpha chegaria a visibility:hidden, o que não queremos aqui).
        var pulseTween = gsap.to(edges, {
          opacity: 0.4,
          duration: 1.4,
          ease: 'sine.inOut',
          repeat: -1,
          yoyo: true,
          stagger: { each: 0.35, from: 'random' }
        });
        registerLoop(pulseTween);
        if (hasST) {
          ScrollTrigger.create({
            trigger: section,
            start: 'top bottom',
            end: 'bottom top',
            onToggle: function (self) {
              if (self.isActive) pulseTween.resume();
              else pulseTween.pause();
            }
          });
        }
      }
    });
  })();

  // ---------------------------------------------------------------------
  // 5. #instrumentacao — terminal em cascata (typewriter sem digitar caractere a caractere)
  // ---------------------------------------------------------------------
  (function instrumentacaoMotion() {
    var section = document.getElementById('instrumentacao');
    if (!section) return;

    mm.add('(prefers-reduced-motion: no-preference)', function () {
      toArray('[data-motion="typewriter"]', section).forEach(function (block) {
        var lines = toArray('.tl', block);
        if (!lines.length) lines = toArray(':scope > *', block);
        if (!lines.length) return;
        gsap.from(lines, {
          autoAlpha: 0,
          y: amp(6),
          duration: DUR.rapido * 1.45,
          ease: 'power1.out',
          // cascata rápida — cada linha "aparece digitada" sem custo de animar glifo a
          // glifo (isso exigiria SplitText/Club GreenSock, fora do vendorizado).
          stagger: 0.05,
          // sem "reverse": o terminal já "rodou" uma vez, não deve sumir se o
          // usuário rolar para cima — regra dura de nunca gatear visibilidade.
          scrollTrigger: hasST
            ? { trigger: block, start: 'top 75%', toggleActions: 'play none none none' }
            : undefined
        });
        registerFinalizer(
          lines,
          function () { return lines.every(function (l) { return parseFloat(getComputedStyle(l).opacity) > 0.95; }); },
          function () { forceFinalState(lines, { autoAlpha: 1, y: 0 }); }
        );
      });
    });
  })();

  // ---------------------------------------------------------------------
  // 6. #execucao — traçado vetorial da matriz (blueprint) no scrub final
  // ---------------------------------------------------------------------
  (function execucaoMotion() {
    if (!hasST) return;
    var section = document.getElementById('execucao');
    if (!section) return;

    mm.add('(prefers-reduced-motion: no-preference)', function () {
      toArray('[data-motion="blueprint"]', section).forEach(function (svg) {
        var paths = toArray('path', svg).filter(function (p) {
          return typeof p.getTotalLength === 'function';
        });
        if (!paths.length) return;
        paths.forEach(function (path) {
          var len = path.getTotalLength();
          gsap.set(path, { strokeDasharray: len, strokeDashoffset: len });
        });
        gsap.to(paths, {
          strokeDashoffset: 0,
          ease: 'none',
          stagger: 0.03,
          scrollTrigger: {
            trigger: svg,
            start: 'top 70%',
            end: 'bottom 60%',
            scrub: 0.5
          }
        });
      });
    });
  })();

  // ---------------------------------------------------------------------
  // 7. Contadores numéricos (data-motion="counter" data-to="<n>")
  // ---------------------------------------------------------------------
  (function counters() {
    toArray('[data-motion="counter"]').forEach(function (el) {
      var raw = el.getAttribute('data-to');
      var to = parseFloat(raw);
      if (!raw || isNaN(to)) return;
      var decimals = (raw.split('.')[1] || '').length;

      // O padding vem do CONTEÚDO inicial do elemento ("05"), nunca de `data-to`
      // ("5") — é o texto que carrega a intenção de formato do design, o atributo
      // só carrega o valor-alvo. Ex.: "05" → largura mínima 2, preserva o zero.
      var originalText = (el.textContent || '').trim();
      var padWidth = /^\d+$/.test(originalText) ? originalText.length : 0;
      function format(n) {
        var text = decimals ? n.toFixed(decimals) : String(Math.round(n));
        while (padWidth && text.length < padWidth) text = '0' + text;
        return text;
      }

      mm.add('(prefers-reduced-motion: no-preference)', function () {
        var obj = { val: 0 };
        var counterTween = gsap.to(obj, {
          val: to,
          duration: DUR.lento * 0.7,
          ease: 'power2.out',
          onUpdate: function () {
            el.textContent = format(obj.val);
          },
          scrollTrigger: hasST
            ? { trigger: el, start: 'top 85%', once: true }
            : undefined
        });
        // Rede de segurança: se a tween ficar presa (ex.: o ticker do GSAP atrasou
        // com a aba em segundo plano, ou o trigger nunca disparou), força o valor
        // final assim que o contador já deveria estar visível. `obj` é o alvo real
        // da tween (o texto só é espelhado via onUpdate) — matar a tween nele evita
        // que ela sobrescreva o valor forçado no próximo tick.
        registerFinalizer(
          el,
          function () { return el.textContent === format(to); },
          function () {
            counterTween.kill();
            el.textContent = format(to);
          }
        );
      });
    });
  })();

  // ---------------------------------------------------------------------
  // 8. .reveal — fade+translate padrão, stagger variado por seção
  // ---------------------------------------------------------------------
  (function reveals() {
    // Stagger deliberadamente diferente por seção — o contrato pede para evitar "o mesmo
    // reflexo uniforme em toda a página". Seções com grades mais densas (topologia,
    // motor) recebem stagger maior; a banda de tese (poucos elementos) fica mais justa.
    var STAGGER_BY_SECTION = {
      hero: 0.06,
      paradoxo: 0.09,
      tese: 0.05,
      motor: 0.08,
      topologia: 0.11,
      instrumentacao: 0.07,
      execucao: 0.09
    };
    var DEFAULT_STAGGER = 0.08;

    /**
     * Alvo de âncora não se desloca — revela só com fade.
     *
     * O `#author` aterrissava 20px acima de todos os outros alvos da nav (57px contra 77px), e
     * o `scroll-padding-top` não tinha culpa nenhuma: medido em 2026-09-06, o salto entrega o
     * card EXATAMENTE em 77px, e o `scrollY` não se move mais depois disso. Os 20px são o
     * `y: amp(20)` deste próprio reveal — o `#author` é o único alvo da nav que é ele mesmo um
     * `.reveal`, então o navegador rola para a posição transformada e a animação, ao zerar o
     * translate, sobe o card por baixo do leitor que acabou de chegar nele.
     *
     * Compensar com `scroll-margin` amarraria a âncora à amplitude da animação; mover o `id`
     * para um envoltório tiraria o card da grade que ele divide com o quickstart. A regra que
     * sobra é esta, e ela vale para qualquer alvo futuro sem ninguém precisar lembrar.
     */
    function ehAlvoDeAncora(el) {
      return !!(el.id && document.querySelector('.site-nav a[href="#' + el.id + '"]'));
    }
    function deslocamento(i, el) {
      return ehAlvoDeAncora(el) ? 0 : amp(20);
    }

    mm.add('(prefers-reduced-motion: no-preference)', function () {
      toArray('[data-track-section]').forEach(function (section) {
        var items = toArray('.reveal', section);
        if (!items.length) return;
        var amount = STAGGER_BY_SECTION[section.id] || DEFAULT_STAGGER;
        gsap.from(items, {
          autoAlpha: 0,
          y: deslocamento,
          duration: DUR.medio,
          ease: 'power2.out',
          stagger: amount,
          // sem "reverse": regra dura do contrato — reveal realça, nunca gateia.
          // Uma vez visível, o conteúdo não pode voltar a sumir sozinho (nem se
          // o usuário rolar de volta, nem se um refresh recalcular a posição).
          scrollTrigger: hasST
            ? { trigger: section, start: 'top 82%', toggleActions: 'play none none none' }
            : undefined
        });
        registerFinalizer(
          items,
          function () { return items.every(function (it) { return parseFloat(getComputedStyle(it).opacity) > 0.95; }); },
          function () { forceFinalState(items, { autoAlpha: 1, y: 0 }); }
        );
      });

      // Reveal solto fora de qualquer [data-track-section] (ex.: bloco do autor dentro
      // de #execucao) — stagger padrão, mesmo tratamento.
      var orphanReveals = toArray('.reveal').filter(function (el) {
        return !el.closest('[data-track-section]');
      });
      if (orphanReveals.length) {
        gsap.from(orphanReveals, {
          autoAlpha: 0,
          y: deslocamento,
          duration: DUR.medio,
          ease: 'power2.out',
          stagger: DEFAULT_STAGGER,
          scrollTrigger: hasST
            ? { trigger: orphanReveals[0], start: 'top 82%', toggleActions: 'play none none none' }
            : undefined
        });
        registerFinalizer(
          orphanReveals,
          function () { return orphanReveals.every(function (it) { return parseFloat(getComputedStyle(it).opacity) > 0.95; }); },
          function () { forceFinalState(orphanReveals, { autoAlpha: 1, y: 0 }); }
        );
      }
    });
  })();

  // ---------------------------------------------------------------------
  // 9. Recalibração pós-fontes — pin e scrub dependem de métricas de layout que só
  // ficam corretas depois que JetBrains Mono / Archivo terminam de carregar.
  // ---------------------------------------------------------------------
  if (hasST && document.fonts && document.fonts.ready) {
    document.fonts.ready.then(function () {
      ScrollTrigger.refresh();
    });
  }

  // ---------------------------------------------------------------------
  // 10. Recalibração quando uma seção muda de altura depois do último refresh.
  //
  // As fontes não são o único que mexe no layout depois do setup. Medido em 2026-09-15 (D-25):
  // o `#hero` cresce DEPOIS dos dois refresh iniciais, 137px a 1024px e 20px a 1440px, perto
  // dos 300–380ms. Todo gatilho abaixo dele ficava defasado até alguém redimensionar a janela: a
  // 1024 o pin do `#motor` engatava 137px antes da seção chegar ao topo (a seção pulava para
  // cima), e o link da nav parava dentro do pin, com a seção colada no topo em vez de abaixo do
  // cabeçalho. Em vez de caçar cada causa, as seções avisam quando mudam de altura.
  // A primeira leitura de cada uma só registra a altura: `observe()` sempre dispara uma vez, e
  // sem isso toda carga pagaria um refresh a mais sem motivo.
  // ---------------------------------------------------------------------
  if (hasST && typeof ResizeObserver === 'function') {
    var alturasVistas = new Map();
    var refreshPendente = null;
    var observador = new ResizeObserver(function (entradas) {
      var mudou = false;
      entradas.forEach(function (e) {
        var h = Math.round(e.contentRect.height);
        var antes = alturasVistas.get(e.target);
        alturasVistas.set(e.target, h);
        if (antes !== undefined && Math.abs(h - antes) >= 2) mudou = true;
      });
      if (!mudou) return;
      clearTimeout(refreshPendente);
      refreshPendente = setTimeout(function () { ScrollTrigger.refresh(); }, 120);
    });
    toArray('section[id]').forEach(function (secao) { observador.observe(secao); });
  }
})();

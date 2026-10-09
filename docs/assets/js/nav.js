/**
 * Menu mobile do header — o hambúrguer do HeroMobile.dc.html.
 *
 * O artboard só desenha o estado fechado (marca + duas barras de 20×1px); o painel aberto
 * segue o resto do sistema: links empilhados com hairline, o INICIALIZAR em largura total.
 *
 * Postura:
 *   - A aparência inteira vive no CSS, sob `html.has-js .site-header.is-open`. Este arquivo
 *     só alterna a classe e o `aria-expanded` — nada de style inline, nada de medir layout.
 *   - Acima de 768px o menu não existe: o `matchMedia` fecha o painel ao sair do mobile, senão
 *     um giro de tela deixaria o header presilhado no estado aberto.
 *   - Tudo dentro de try/catch pela mesma razão do track.js: navegação nunca pode quebrar a
 *     página. Se algo aqui falhar, o CSS sem `.is-open` deixa o header legível do mesmo jeito.
 */
(function () {
  "use strict";

  try {
    var header = document.querySelector(".site-header");
    var toggle = document.getElementById("navToggle");
    var painel = document.getElementById("navPanel");
    if (!header || !toggle || !painel) return;

    var mobile = window.matchMedia("(max-width: 768px)");

    function aberto() {
      return header.classList.contains("is-open");
    }

    function definir(estado) {
      header.classList.toggle("is-open", estado);
      toggle.setAttribute("aria-expanded", estado ? "true" : "false");
      toggle.setAttribute("aria-label", estado ? "Fechar o menu" : "Abrir o menu");
    }

    toggle.addEventListener("click", function () {
      definir(!aberto());
    });

    // Tocar um link navega para a âncora — o painel precisa sair da frente do destino.
    painel.addEventListener("click", function (ev) {
      if (ev.target.closest("a")) definir(false);
    });

    document.addEventListener("keydown", function (ev) {
      if (ev.key !== "Escape" || !aberto()) return;
      definir(false);
      toggle.focus();
    });

    // Toque fora do header fecha; o clique dentro já é tratado acima.
    document.addEventListener("click", function (ev) {
      if (aberto() && !header.contains(ev.target)) definir(false);
    });

    function acompanharViewport() {
      if (!mobile.matches) definir(false);
    }
    if (typeof mobile.addEventListener === "function") {
      mobile.addEventListener("change", acompanharViewport);
    } else if (typeof mobile.addListener === "function") {
      mobile.addListener(acompanharViewport); // Safari < 14
    }
  } catch (e) {
    /* silêncio proposital: ver postura no topo do arquivo */
  }
})();

/**
 * Link interno desliza até o alvo em vez de saltar.
 *
 * O salto instantâneo tirava do leitor a noção de onde a seção fica na página; a descida mostra
 * o caminho. Fica restrito ao CLIQUE de propósito: `scroll-behavior: smooth` no `html` valeria
 * também para toda rolagem programática, e o ScrollTrigger rola a página ao recalcular os pins
 * (a própria documentação do GSAP desaconselha a combinação).
 *
 * O que continua nativo:
 *   - o skip-link, porque quem tabula até ele quer chegar, não assistir à viagem;
 *   - quem pediu menos movimento, que recebe o salto de sempre;
 *   - clique com modificador (nova aba) e link cujo alvo não existe.
 *
 * O destino é o `scroll-padding-top` do `html`, igual ao salto, porque `scrollIntoView`
 * respeita a mesma regra. Se o alvo estiver pinado pelo ScrollTrigger, rola-se até o
 * `.pin-spacer` que o envolve, porque o elemento pinado está `fixed` e não tem posição no
 * fluxo. O foco acompanha o leitor, como no salto nativo: o próximo Tab parte da seção
 * onde ele chegou.
 */
(function () {
  "use strict";

  try {
    var menosMovimento = window.matchMedia("(prefers-reduced-motion: reduce)");

    document.addEventListener("click", function (ev) {
      if (ev.defaultPrevented || ev.button !== 0 || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
      var link = ev.target.closest && ev.target.closest('a[href^="#"]');
      if (!link || link.classList.contains("skip-link")) return;

      var hash = link.getAttribute("href");
      var alvo = hash.length > 1 && document.getElementById(decodeURIComponent(hash.slice(1)));
      if (!alvo || menosMovimento.matches) return;

      ev.preventDefault();
      if (location.hash !== hash) history.pushState(null, "", hash);

      var pai = alvo.parentElement;
      var caixa = pai && pai.classList.contains("pin-spacer") ? pai : alvo;
      caixa.scrollIntoView({ behavior: "smooth", block: "start" });

      if (!alvo.hasAttribute("tabindex")) alvo.setAttribute("tabindex", "-1");
      alvo.focus({ preventScroll: true });
    });
  } catch (e) {
    /* silêncio proposital: sem este bloco o link salta, como sempre saltou */
  }
})();

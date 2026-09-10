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

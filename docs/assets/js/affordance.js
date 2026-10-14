/*!
 * affordance.js — avisa quando um bloco rola para o lado, e para de avisar no fim.
 *
 * O caso concreto: a tabela dos 11 agentes rola 654px na horizontal a 390px de largura. O
 * conteúdo simplesmente era cortado na borda, sem nada dizendo que havia mais. Quem não
 * arrasta por acaso nunca descobre as outras colunas.
 *
 * Postura: o CSS é quem desenha (`.roster[data-rola]` em site.css); este arquivo só decide
 * QUANDO o atributo vale "1" (há mais conteúdo à direita) ou "fim" (chegou ao fim). Sem JS o
 * atributo nunca aparece, a máscara não é desenhada e a tabela continua rolando normalmente —
 * o `tabindex` do HTML já garante o alcance por teclado, que é a parte que não pode depender
 * de script.
 */
(function () {
  "use strict";

  try {
    var alvos = document.querySelectorAll(".roster, .rola-lateral");
    if (!alvos.length) return;

    function avaliar(el) {
      var sobra = el.scrollWidth - el.clientWidth;
      if (sobra <= 1) {
        el.removeAttribute("data-rola");
        return;
      }
      // 2px de folga: em zoom fracionário o scrollLeft nunca bate exatamente no máximo.
      var noFim = el.scrollLeft >= sobra - 2;
      el.setAttribute("data-rola", noFim ? "fim" : "1");
    }

    Array.prototype.forEach.call(alvos, function (el) {
      avaliar(el);
      el.addEventListener("scroll", function () { avaliar(el); }, { passive: true });
    });

    // A largura do conteúdo muda com a fonte e com o giro da tela; sem reavaliar, a máscara
    // fica prometendo conteúdo que já não existe (ou escondendo o que passou a existir).
    var pendente = null;
    function reavaliarTudo() {
      clearTimeout(pendente);
      pendente = setTimeout(function () {
        Array.prototype.forEach.call(alvos, avaliar);
      }, 150);
    }
    window.addEventListener("resize", reavaliarTudo, { passive: true });
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(reavaliarTudo);
  } catch (e) {
    /* silêncio proposital: sem este arquivo a tabela ainda rola e ainda é alcançável por teclado */
  }
})();

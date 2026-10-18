/*!
 * audit-overlay.js — a camada visual do auditor. Só existe quando a URL traz `?audit`.
 *
 * Não decide nada: todas as regras vivem em `audit-regras.js`, que é a mesma fonte que a suíte
 * de testes e o CLI consomem. Aqui só se desenha o que aquele arquivo achou.
 *
 * Isolamento: o painel inteiro mora num shadow root. O CSS da landing não o alcança, e o dele
 * não vaza para a landing — auditar uma página mudando o layout dela seria medir outra coisa.
 * As marcações ficam num container `position:absolute` com `pointer-events:none`, então a
 * página continua clicável por baixo.
 */
(function () {
  "use strict";

  if (!window.__AUDIT_REGRAS__) {
    console.error("[audit] audit-regras.js não carregou — o overlay não tem o que desenhar.");
    return;
  }

  var COR = { alto: "#F43F5E", medio: "#FF5500", baixo: "#7E8B9B" };

  var host = document.createElement("div");
  host.id = "audit-overlay-host";
  host.setAttribute("data-audit-ui", "");
  document.body.appendChild(host);
  var raiz = host.attachShadow({ mode: "open" });

  raiz.innerHTML = [
    "<style>",
    "  :host { all: initial; }",
    "  * { box-sizing: border-box; font-family: ui-monospace, 'JetBrains Mono', Menlo, Consolas, monospace; }",
    "  .marcas { position: absolute; inset: 0; pointer-events: none; z-index: 2147483646; }",
    "  .marca { position: absolute; border: 1.5px dashed currentColor; }",
    "  .marca > b { position: absolute; top: -1.5px; left: -1.5px; display: block; min-width: 18px;",
    "    padding: 1px 4px; font-size: 10px; font-weight: 700; line-height: 1.5; color: #000;",
    "    background: currentColor; text-align: center; }",
    "  .marca.foco { border-style: solid; border-width: 2.5px; box-shadow: 0 0 0 3px rgba(255,255,255,.25); }",
    "  .painel { position: fixed; top: 0; right: 0; width: 380px; max-width: 92vw; height: 100vh;",
    "    display: flex; flex-direction: column; background: #0B0D11; color: #F0F3F6;",
    "    border-left: 1px solid rgba(240,243,246,.14); z-index: 2147483647; font-size: 12px; }",
    "  .painel.recolhido { transform: translateX(calc(100% - 42px)); }",
    "  .cabeca { display: flex; align-items: center; gap: 10px; padding: 12px 14px;",
    "    border-bottom: 1px solid rgba(240,243,246,.14); }",
    "  .cabeca h1 { flex: 1; margin: 0; font-size: 11px; font-weight: 700; letter-spacing: .18em; }",
    "  button { font: inherit; color: inherit; background: transparent; cursor: pointer;",
    "    border: 1px solid rgba(240,243,246,.2); padding: 4px 8px; font-size: 10px; letter-spacing: .1em; }",
    "  button:hover { border-color: #FF5500; color: #FF5500; }",
    "  button:focus-visible { outline: 2px solid #FF5500; outline-offset: 2px; }",
    "  .resumo { display: flex; gap: 6px; padding: 10px 14px; flex-wrap: wrap;",
    "    border-bottom: 1px solid rgba(240,243,246,.14); }",
    "  .chip { padding: 3px 8px; font-size: 10px; letter-spacing: .08em; border: 1px solid currentColor; }",
    "  .lista { flex: 1; overflow-y: auto; margin: 0; padding: 0; list-style: none; }",
    "  .item { padding: 11px 14px; border-bottom: 1px solid rgba(240,243,246,.08); cursor: pointer; }",
    "  .item:hover, .item.ativo { background: #14171D; }",
    "  .item-topo { display: flex; gap: 8px; align-items: baseline; }",
    "  .item-n { font-weight: 700; font-size: 10px; min-width: 22px; }",
    "  .item-regra { font-size: 10px; letter-spacing: .1em; text-transform: uppercase; }",
    "  .item-msg { margin: 5px 0 0 30px; color: #C3CBD4; line-height: 1.5; }",
    "  .item-onde { margin: 4px 0 0 30px; color: #7E8B9B; font-size: 10.5px; word-break: break-all; }",
    "  .vazio { padding: 28px 14px; color: #10B981; line-height: 1.6; }",
    "  .rodape { padding: 9px 14px; border-top: 1px solid rgba(240,243,246,.14); color: #7E8B9B; font-size: 10px; }",
    // Num viewport de 390px o painel lateral de 380px cobre a página inteira — some justamente
    // com aquilo que ele deveria estar marcando. No estreito ele vira folha inferior, ocupando
    // menos da metade da altura, e a página fica visível acima com as marcações à mostra.
    "  @media (max-width: 720px) {",
    "    .painel { top: auto; bottom: 0; width: 100%; max-width: 100%; height: 46vh; border-left: 0;",
    "      border-top: 1px solid rgba(240,243,246,.22); }",
    "    .painel.recolhido { transform: translateY(calc(100% - 44px)); }",
    "    .item-msg, .item-onde { margin-left: 0; }",
    "  }",
    "</style>",
    '<div class="marcas" id="marcas"></div>',
    '<div class="painel" id="painel">',
    '  <div class="cabeca">',
    '    <h1>AUDITORIA</h1>',
    '    <button id="reexec" title="Remedir a página no estado atual">REMEDIR</button>',
    '    <button id="recolher" title="Recolher o painel">—</button>',
    "  </div>",
    '  <div class="resumo" id="resumo"></div>',
    '  <ul class="lista" id="lista"></ul>',
    '  <div class="rodape" id="rodape"></div>',
    "</div>"
  ].join("\n");

  var elMarcas = raiz.getElementById("marcas");
  var elLista = raiz.getElementById("lista");
  var elResumo = raiz.getElementById("resumo");
  var elRodape = raiz.getElementById("rodape");
  var elPainel = raiz.getElementById("painel");

  var achados = [];
  var alvos = [];

  function medir() {
    // O overlay não pode se auditar: ele é UI de diagnóstico, não conteúdo da página.
    host.style.display = "none";
    achados = window.__AUDIT_REGRAS__.rodar();
    host.style.display = "";

    // Reencontra cada elemento pelo seletor devolvido, para poder destacá-lo e rolar até ele.
    alvos = achados.map(function (a) {
      try { return a.seletor ? document.querySelector(a.seletor) : null; } catch (e) { return null; }
    });
    desenhar();
  }

  function desenhar() {
    elMarcas.textContent = "";
    achados.forEach(function (a, i) {
      if (!a.caixa || !a.caixa.w) return;
      var m = document.createElement("div");
      m.className = "marca";
      m.style.color = COR[a.severidade] || COR.baixo;
      m.style.left = a.caixa.x + "px";
      m.style.top = a.caixa.y + "px";
      m.style.width = a.caixa.w + "px";
      m.style.height = a.caixa.h + "px";
      m.dataset.i = String(i);
      var b = document.createElement("b");
      b.textContent = String(i + 1);
      m.appendChild(b);
      elMarcas.appendChild(m);
    });

    var contagem = {};
    achados.forEach(function (a) { contagem[a.severidade] = (contagem[a.severidade] || 0) + 1; });
    elResumo.textContent = "";
    ["alto", "medio", "baixo"].forEach(function (sev) {
      if (!contagem[sev]) return;
      var c = document.createElement("span");
      c.className = "chip";
      c.style.color = COR[sev];
      c.textContent = contagem[sev] + " " + sev.toUpperCase();
      elResumo.appendChild(c);
    });

    elLista.textContent = "";
    if (!achados.length) {
      var ok = document.createElement("li");
      ok.className = "vazio";
      ok.textContent = "Nenhum achado neste viewport. As regras deste tamanho de tela passaram — outros viewports podem ter achados próprios.";
      elLista.appendChild(ok);
    }
    achados.forEach(function (a, i) {
      var li = document.createElement("li");
      li.className = "item";
      li.dataset.i = String(i);

      var topo = document.createElement("div");
      topo.className = "item-topo";
      var n = document.createElement("span");
      n.className = "item-n";
      n.style.color = COR[a.severidade] || COR.baixo;
      n.textContent = String(i + 1);
      var regra = document.createElement("span");
      regra.className = "item-regra";
      regra.style.color = COR[a.severidade] || COR.baixo;
      regra.textContent = a.regra;
      topo.appendChild(n);
      topo.appendChild(regra);

      var msg = document.createElement("div");
      msg.className = "item-msg";
      msg.textContent = a.mensagem;

      var onde = document.createElement("div");
      onde.className = "item-onde";
      onde.textContent = a.seletor + (a.texto ? '  ·  "' + a.texto + '"' : "");

      li.appendChild(topo);
      li.appendChild(msg);
      li.appendChild(onde);
      elLista.appendChild(li);
    });

    elRodape.textContent = achados.length + " achado(s)  ·  " + window.innerWidth + "×" + window.innerHeight +
      "  ·  regras: " + window.__AUDIT_REGRAS__.regras.length;
  }

  function focar(i) {
    Array.prototype.forEach.call(elMarcas.children, function (m) {
      m.classList.toggle("foco", m.dataset.i === String(i));
    });
    Array.prototype.forEach.call(elLista.children, function (li) {
      li.classList.toggle("ativo", li.dataset.i === String(i));
    });
    var alvo = alvos[i];
    if (alvo && alvo.scrollIntoView) alvo.scrollIntoView({ block: "center", behavior: "smooth" });
  }

  elLista.addEventListener("click", function (ev) {
    var li = ev.target.closest(".item");
    if (li) focar(Number(li.dataset.i));
  });
  raiz.getElementById("reexec").addEventListener("click", medir);
  raiz.getElementById("recolher").addEventListener("click", function () {
    elPainel.classList.toggle("recolhido");
    this.textContent = elPainel.classList.contains("recolhido") ? "+" : "—";
  });

  // As caixas são absolutas no documento; mudou o layout, as marcas saem do lugar.
  var pendente = null;
  function remedirDepois() {
    clearTimeout(pendente);
    pendente = setTimeout(medir, 250);
  }
  window.addEventListener("resize", remedirDepois);

  if (document.fonts && document.fonts.ready) document.fonts.ready.then(medir);
  else medir();

  console.info("[audit] overlay ativo. window.__AUDIT_REGRAS__.rodar() devolve os achados crus.");
})();

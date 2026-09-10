/**
 * Tracking first-party da landing "compiler" — mesma base do v2 (docs/index.html, bloco
 * ANALYTICS), com fila/flush, dedup e os campos/eventos novos do CONTRATO §3-§5.
 *
 * Postura preservada verbatim do v2 (não mexer nisso):
 *   - fetch keepalive, NÃO sendBeacon: o Apps Script sempre responde com um 302 antes do 200
 *     final, e o sendBeacon do Chrome não segue esse redirect (falha silenciosa — só aparece
 *     como 503 no painel de rede). fetch+keepalive segue o redirect normalmente.
 *   - navigator.webdriver → não coleta (ignora headless/crawlers, ex.: Googlebot).
 *   - sid gerado só em memória (crypto.randomUUID com fallback), nunca em cookie/localStorage/
 *     sessionStorage. Não há PII em nenhum campo.
 *   - tudo fire-and-forget dentro de try/catch: tracking nunca pode quebrar a página.
 *   - hooks de markup são lidos defensivamente (frente A pode não ter criado um id/attr ainda;
 *     um querySelector que não acha nada nunca deve lançar).
 *
 * Zero dependência externa (sem web-vitals.js nem qualquer CDN) — Web Vitals via
 * PerformanceObserver nativo, degradando em silêncio onde a API não existe (ex.: INP no Safari).
 */
(function () {
  "use strict";

  // Mesma URL do v2 (docs/index.html) — um único Apps Script coletor para o site inteiro.
  var COLLECTOR_URL = "https://script.google.com/macros/s/AKfycbwBfZHcSowNVeMUGfDFXafy7jSRzuHChcgrDmtkczD4WO0dv7l2qpMQDGcZoRd74p4ekw/exec";
  if (!COLLECTOR_URL) return;                      // no-op se não configurado (cópia do template)
  if (navigator.webdriver) return;                  // ignora crawlers/headless

  var SID = (window.crypto && crypto.randomUUID)
    ? crypto.randomUUID()
    : (Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2));

  var PAGE_START = performance.now();
  var seq = 0;                                      // nº sequencial do evento nesta carga
  var sentOnce = {};                                 // dedup: chave "evento:label" já disparada
  var currentSection = "";                           // seção mais visível no momento (heurística)
  var reducedMotion = (window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches) ? 1 : 0;

  /* ---------- CLOCK ENGAJADO — só corre com a aba visível ---------- */
  var engagedMs = 0;
  var visibleSince = (document.visibilityState === "visible") ? performance.now() : null;
  function foldEngaged() {
    if (visibleSince != null) {
      engagedMs += performance.now() - visibleSince;
      visibleSince = null;
    }
  }
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "visible") {
      visibleSince = performance.now();
    } else {
      foldEngaged();
    }
  });
  function engagedNow() {
    if (visibleSince != null) return Math.round(engagedMs + (performance.now() - visibleSince));
    return Math.round(engagedMs);
  }

  /* ---------- FILA + FLUSH ----------
   * Decisão de formato (documentada aqui porque é a peça que o doPost precisa espelhar):
   * eventos disparados numa janela curta (<300ms, ex.: pageview + motion_mode + section_view
   * do hero quase juntos) são agrupados e enviados como UM POST cujo corpo é um ARRAY JSON de
   * payloads — em vez de 1 request por evento. Quando só há 1 evento na janela, o corpo continua
   * sendo o objeto solto (idêntico ao formato do v2), então o payload legado do v2 nunca muda de
   * forma. O collector.gs (doPost/buildRowsOrEmpty) aceita os dois formatos: objeto único OU
   * array de objetos. Optamos por array (em vez de "1 request por evento, fila só evita rajada")
   * porque reduz a contagem de requests em janelas de interação densa (ex.: abrir o QR do Pix
   * logo após copiar o quickstart) sem exigir nenhuma mudança de transporte (mesmo endpoint,
   * mesmo fetch keepalive, mesmo Content-Type text/plain).
   */
  var queue = [];
  var flushTimer = null;
  function scheduleFlush() {
    if (flushTimer) return;
    flushTimer = setTimeout(function () { flushTimer = null; flush(); }, 300);
  }
  function flush() {
    if (!queue.length) return;
    var batch = queue;
    queue = [];
    try {
      var body = JSON.stringify(batch.length === 1 ? batch[0] : batch);
      fetch(COLLECTOR_URL, {
        method: "POST", body: body, keepalive: true,
        headers: { "Content-Type": "text/plain" }
      }).catch(function () {});
    } catch (e) {}
  }
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "hidden") flush();
  });
  window.addEventListener("pagehide", flush);

  /* ---------- NAV TYPE (campo `nav`) ---------- */
  function navType() {
    try {
      var nav = performance.getEntriesByType && performance.getEntriesByType("navigation")[0];
      if (nav && nav.type) return nav.type;           // "navigate" | "reload" | "back_forward" | "prerender"
    } catch (e) {}
    return "";
  }

  /* ---------- MONTAGEM DO PAYLOAD (18 campos do v2 + 8 novos do CONTRATO §5) ---------- */
  function buildPayload(name, extra) {
    seq++;
    var u = new URLSearchParams(location.search);
    var conn = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
    var scheme = (window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches) ? "dark"
      : (window.matchMedia && matchMedia("(prefers-color-scheme: light)").matches) ? "light" : "";
    return {
      v: 1, host: location.host, path: location.pathname, event: name,
      sid: SID,
      ref: document.referrer || "",
      utm: {
        source: u.get("utm_source") || "", medium: u.get("utm_medium") || "",
        campaign: u.get("utm_campaign") || "", content: u.get("utm_content") || "", term: u.get("utm_term") || ""
      },
      lang: navigator.language || "",
      tz: (Intl.DateTimeFormat().resolvedOptions().timeZone) || "",
      vp: window.innerWidth + "x" + window.innerHeight,
      ua: (window.matchMedia && matchMedia("(pointer: coarse)").matches) ? "mobile" : "desktop",
      conn: (conn && conn.effectiveType) || "",
      scheme: scheme,
      label: (extra && extra.label) || "",
      value: (extra && extra.value != null) ? extra.value : "",
      // --- campos novos (CONTRATO §5) ---
      sv: "compiler",
      seq: seq,
      t: Math.round(performance.now() - PAGE_START),
      sec: currentSection,
      eng: engagedNow(),
      rm: reducedMotion,
      dpr: window.devicePixelRatio || 1,
      nav: navType()
    };
  }

  // Eventos declarados 1x-por-carga no CONTRATO (§4) — dedup por "evento:label".
  var ONCE_EVENTS = {
    pageview: true, dwell: true, engaged: true, motion_mode: true,
    section_view: true, phase_step: true, web_vital: true
  };

  function collect(name, extra) {
    try {
      if (ONCE_EVENTS[name]) {
        var key = name + ":" + ((extra && extra.label) || "");
        if (sentOnce[key]) return;
        sentOnce[key] = true;
      }
      queue.push(buildPayload(name, extra));
      scheduleFlush();
    } catch (e) {}                                    // nunca quebra a página (fire-and-forget)
  }

  function track(name, extra) { collect(name, extra); }

  /* ---------- SCROLL DEPTH — 1 evento por limiar (25/50/75/100%) por carga ---------- */
  (function () {
    var fired = {};
    var thresholds = [25, 50, 75, 100];
    var ticking = false;
    function check() {
      ticking = false;
      var scrollable = document.documentElement.scrollHeight - window.innerHeight;
      var pct = scrollable > 0 ? Math.min(100, Math.round((window.scrollY / scrollable) * 100)) : 100;
      thresholds.forEach(function (t) {
        if (pct >= t && !fired[t]) { fired[t] = true; track("scroll", { value: t }); }
      });
    }
    window.addEventListener("scroll", function () {
      if (!ticking) { ticking = true; requestAnimationFrame(check); }
    }, { passive: true });
  })();

  /* ---------- DWELL + ENGAGED — saída/troca de aba (1x por carga cada) ---------- */
  (function () {
    var start = performance.now();
    var sent = false;
    function sendFinal() {
      if (sent) return;
      sent = true;
      foldEngaged();
      track("dwell", { value: Math.round(performance.now() - start) });
      track("engaged", { value: engagedNow() });
    }
    document.addEventListener("visibilitychange", function () {
      if (document.visibilityState === "hidden") sendFinal();
    });
    window.addEventListener("pagehide", sendFinal);
  })();

  /* ---------- ERROS JS — window.onerror / unhandledrejection (sem stack de usuário) ---------- */
  window.addEventListener("error", function (e) {
    track("js_error", { label: (e.message || "erro") + " @" + (e.filename || "").split("/").pop() + ":" + (e.lineno || 0) });
  });
  window.addEventListener("unhandledrejection", function (e) {
    track("js_error", { label: "promise: " + String(e.reason).slice(0, 200) });
  });

  /* ---------- COPIAR (defensivo: só liga se o gancho existir) ---------- */
  function bindCopy(btn, getText, doneLabel, eventName) {
    if (!btn) return;
    var orig = btn.textContent;
    btn.addEventListener("click", function () {
      try {
        var text = getText();
        navigator.clipboard.writeText(text).then(function () {
          btn.textContent = doneLabel;
          if (eventName) track(eventName);
          setTimeout(function () { btn.textContent = orig; }, 1600);
        }).catch(function () {
          btn.textContent = "copie manualmente";
          setTimeout(function () { btn.textContent = orig; }, 1600);
        });
      } catch (e) {}
    });
  }
  var copyQsBtn = document.getElementById("copyQs");
  bindCopy(copyQsBtn, function () { return copyQsBtn.getAttribute("data-copy") || ""; }, "✓ copiado", "copy_quickstart");

  var copyPixBtn = document.getElementById("copyPix");
  var pixKeyEl = document.getElementById("pixKey");
  bindCopy(copyPixBtn, function () { return pixKeyEl ? pixKeyEl.textContent : ""; }, "✓ copiado", "copy_pix");

  /* ---------- QUICKSTART OS TOGGLE — data-os-toggle="windows"|"linux" ---------- */
  document.addEventListener("click", function (e) {
    var toggle = e.target.closest && e.target.closest("[data-os-toggle]");
    if (toggle) track("quickstart_os", { label: toggle.getAttribute("data-os-toggle") || "" });
  });

  /* ---------- CLIQUES — CTA/GitHub mantêm nome próprio; demais caem em "click" genérico ---------- */
  document.addEventListener("click", function (e) {
    var el = e.target.closest && e.target.closest("a, .btn, [data-track-cta]");
    if (!el) return;
    if (el.id === "copyQs" || el.id === "copyPix") return;   // já rastreados via bindCopy acima
    if (el.getAttribute && el.getAttribute("data-track-cta") === "primary") { track("cta_comecar"); return; }
    if (el.matches && el.matches('a[href*="github.com"]')) { track("click_github"); return; }
    var label = (el.getAttribute && el.getAttribute("href") || el.textContent || "").trim().slice(0, 80);
    track("click", { label: label });
  });

  /* ---------- DIALOG QR DO PIX ---------- */
  var pixQrDialog = document.getElementById("pixQrDialog");
  var showPixQr = document.getElementById("showPixQr");
  var closePixQr = document.getElementById("closePixQr");
  if (pixQrDialog && showPixQr) {
    showPixQr.addEventListener("click", function () {
      try { pixQrDialog.showModal(); } catch (e) {}
      track("pix_qr_open");
    });
  }
  if (pixQrDialog && closePixQr) {
    closePixQr.addEventListener("click", function () { try { pixQrDialog.close(); } catch (e) {} });
  }

  /* ---------- SECTION_VIEW — IntersectionObserver com histerese ----------
   * Regra: só dispara depois de 1000ms CONTÍNUOS com >=50% da seção visível — um scroll rápido
   * atravessando as 7 seções não pode disparar 7 eventos. `currentSection` (usado no campo `sec`
   * de todo payload) é atualizado a cada callback, independente da histerese, para refletir a
   * seção mais visível no instante do evento.
   */
  (function () {
    if (typeof IntersectionObserver === "undefined") return;
    var sections = document.querySelectorAll("[data-track-section]");
    if (!sections.length) return;
    var timers = {};
    var HYSTERESIS_MS = 1000;
    var ratios = {};

    function refreshCurrentSection() {
      var best = "", bestRatio = 0;
      Object.keys(ratios).forEach(function (id) {
        if (ratios[id] > bestRatio) { bestRatio = ratios[id]; best = id; }
      });
      if (best) currentSection = best;
    }

    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        var id = entry.target.getAttribute("data-track-section") || "";
        if (!id) return;
        ratios[id] = entry.intersectionRatio;
        refreshCurrentSection();

        if (entry.intersectionRatio >= 0.5) {
          if (!timers[id]) {
            var enteredAt = performance.now();
            timers[id] = setTimeout(function () {
              timers[id] = null;
              track("section_view", { label: id, value: Math.round(performance.now() - enteredAt) });
            }, HYSTERESIS_MS);
          }
        } else if (timers[id]) {
          clearTimeout(timers[id]);
          timers[id] = null;
        }
      });
    }, { threshold: [0, 0.5, 1] });

    sections.forEach(function (el) { io.observe(el); });
  })();

  /* ---------- PHASE_STEP — cassetes data-phase="0".."4" no #motor ---------- */
  (function () {
    if (typeof IntersectionObserver === "undefined") return;
    var cassettes = document.querySelectorAll("[data-phase]");
    if (!cassettes.length) return;
    var PHASES = ["brainstorm", "define", "design", "build", "ship"];
    var timers = {};
    var HYSTERESIS_MS = 1000;

    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        var idxAttr = entry.target.getAttribute("data-phase");
        var idx = parseInt(idxAttr, 10);
        if (isNaN(idx) || idx < 0 || idx > 4) return;

        if (entry.intersectionRatio >= 0.5) {
          if (!timers[idx]) {
            timers[idx] = setTimeout(function () {
              timers[idx] = null;
              track("phase_step", { label: PHASES[idx], value: idx });
            }, HYSTERESIS_MS);
          }
        } else if (timers[idx]) {
          clearTimeout(timers[idx]);
          timers[idx] = null;
        }
      });
    }, { threshold: [0, 0.5, 1] });

    cassettes.forEach(function (el) { io.observe(el); });
  })();

  /* ---------- WEB VITALS — PerformanceObserver NATIVO (sem lib externa) ----------
   * LCP e CLS via PerformanceObserver com buffered:true (captura entradas anteriores ao attach).
   * INP é aproximado pelo maior `duration` entre as entradas type="event" (API "Event Timing");
   * Safari não implementa isso — degrada em silêncio (o evento simplesmente nunca é enviado).
   * Tudo reportado 1x cada, no pagehide/visibilitychange-hidden (valor final, não parcial).
   */
  (function () {
    if (typeof PerformanceObserver === "undefined") return;

    var lcpValue = null;
    try {
      var lcpObserver = new PerformanceObserver(function (list) {
        var entries = list.getEntries();
        var last = entries[entries.length - 1];
        if (last) lcpValue = last.renderTime || last.loadTime || last.startTime;
      });
      lcpObserver.observe({ type: "largest-contentful-paint", buffered: true });
    } catch (e) {}

    var clsValue = 0;
    try {
      var clsObserver = new PerformanceObserver(function (list) {
        list.getEntries().forEach(function (entry) {
          if (!entry.hadRecentInput) clsValue += entry.value;
        });
      });
      clsObserver.observe({ type: "layout-shift", buffered: true });
    } catch (e) {}

    var inpValue = null;
    try {
      var inpObserver = new PerformanceObserver(function (list) {
        list.getEntries().forEach(function (entry) {
          if (inpValue === null || entry.duration > inpValue) inpValue = entry.duration;
        });
      });
      inpObserver.observe({ type: "event", buffered: true, durationThreshold: 40 });
    } catch (e) {}                                    // API ausente (ex.: Safari) → INP nunca enviado

    var reported = false;
    function reportVitals() {
      if (reported) return;
      reported = true;
      if (lcpValue != null) track("web_vital", { label: "LCP", value: Math.round(lcpValue) });
      track("web_vital", { label: "CLS", value: Math.round(clsValue * 1000) });
      if (inpValue != null) track("web_vital", { label: "INP", value: Math.round(inpValue) });
    }
    document.addEventListener("visibilitychange", function () {
      if (document.visibilityState === "hidden") reportVitals();
    });
    window.addEventListener("pagehide", reportVitals);
  })();

  /* ---------- MOTION_MODE — 1x, no pageview ----------
   * "nojs" nunca acontece de fato (este script só roda com JS ligado), mas o valor existe no
   * contrato para simetria com a leitura server-side de páginas sem JS; aqui só distinguimos
   * full (gsap presente e sem prefers-reduced-motion) de reduced.
   */
  track("motion_mode", { label: reducedMotion ? "reduced" : (window.gsap ? "full" : "nojs") });

  collect("pageview");                                // 1 pageview first-party por carga (anônimo)
})();

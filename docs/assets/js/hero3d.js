/*!
 * hero3d.js — carregador do monólito WebGL do hero · landing docs/
 *
 * Decisão em .claude/sdd/design-canvas/compiler/EVOLUCAO.md (D-02, D-03), doutrina em
 * docs/DESIGN.md §Motion "Exceção WebGL" e no Princípio #5 do docs/PRODUCT.md — os dois
 * reescritos ANTES deste arquivo existir, não depois para justificá-lo.
 *
 * Este arquivo é só o porteiro; a cena mora em `hero3d-cena.js`. A separação não é
 * organização: é a regra 1 acontecendo. Guardas e cena no mesmo módulo fariam o visitante
 * que pediu `prefers-reduced-motion: reduce` baixar a cena inteira para o primeiro `if`
 * mandá-la embora. Aqui ele baixa 2KB de porteiro e nada mais.
 *
 * REGRAS DURAS (a suíte em tools/site-tests/specs/hero3d.spec.mjs mede as quatro):
 *   1. Só carrega sob `prefers-reduced-motion: no-preference` — quem pediu menos movimento
 *      não baixa os ~180KB gzip do Three.js.
 *   2. Degrada sem buraco visual: sem WebGL, sem módulo ESM ou sob reduced-motion, o hero
 *      fica no SVG plano, que é o estado final e não um placeholder.
 *   3. O laço para fora da viewport e com a aba oculta.
 *   4. Nada de CDN — o Three.js é vendorizado em docs/assets/js/, como o GSAP.
 *
 * É um módulo ESM de propósito: `import()` dentro de um módulo resolve relativo AO MÓDULO,
 * enquanto num script clássico resolveria relativo ao documento — a diferença deixaria o
 * caminho refém de onde a página está montada, e a landing já mudou de lugar uma vez
 * (`docs/compiler/` → `docs/`, 2026-09-07) sem que estes módulos precisassem saber. Browser sem `type="module"` simplesmente ignora a tag — que é a
 * regra 2 acontecendo de graça.
 */

// Ordem importa: a preferência é checada ANTES de qualquer outra coisa, para que nem a
// detecção de WebGL (que aloca um contexto) aconteça em quem pediu menos movimento.
if (matchMedia('(prefers-reduced-motion: no-preference)').matches && podeRenderizar()) {
  depoisDoCritico(() => {
    // Falha silenciosa de propósito: um `import()` recusado (rede, CSP, arquivo ausente) não é
    // um erro que o visitante possa resolver, e o hero já está inteiro na tela sem ele. O que
    // NÃO pode acontecer é o console gritar numa página cujo argumento é ser bem construída.
    import('./hero3d-cena.js').catch(() => {});
  });
}

/**
 * Adia até a página estar carregada e a linha do tempo ociosa.
 *
 * Não é otimização de gosto: medido nesta landing, disparar o `import()` no momento em que o
 * módulo executa atrasava o LCP em ~330ms — o elemento LCP é o `h1` do hero, e o download da
 * biblioteca competia com as fontes e o CSS que o pintam. Adiado, o número volta ao da página
 * sem WebGL, e o custo é o monólito entrar algumas centenas de milissegundos depois numa área
 * que já está preenchida pelo SVG. Ninguém vê um buraco esperando.
 *
 * `requestIdleCallback` com teto de 2s: em aba de fundo ou máquina ocupada o ocioso pode nunca
 * chegar, e um hero que só aparece quando a máquina descansa não é uma degradação aceitável.
 */
function depoisDoCritico(fn) {
  const agendar = () =>
    (window.requestIdleCallback || ((cb) => setTimeout(cb, 200)))(fn, { timeout: 2000 });
  if (document.readyState === 'complete') agendar();
  else addEventListener('load', agendar, { once: true });
}

function podeRenderizar() {
  // Data Saver é um pedido explícito de economia. Baixar o Three.js aqui seria ignorá-lo.
  const conn = navigator.connection;
  if (conn && conn.saveData) return false;

  const stage = document.querySelector('[data-hero-stage]');
  if (!stage || !stage.querySelector('[data-hero3d]')) return false;

  // Detecção de WebGL com contexto descartável: `getContext` devolve null quando o driver
  // recusa (GPU bloqueada, aceleração desligada, VM sem 3D). Perguntar pela existência de
  // `window.WebGLRenderingContext` não bastaria — a classe existe mesmo quando nenhum
  // contexto pode ser criado. O contexto de teste é liberado na hora: browsers limitam
  // quantos existem ao mesmo tempo, e vazar este custaria o da cena.
  const probe = document.createElement('canvas');
  const gl = probe.getContext('webgl2') || probe.getContext('webgl');
  if (!gl) return false;
  const lose = gl.getExtension('WEBGL_lose_context');
  if (lose) lose.loseContext();
  return true;
}

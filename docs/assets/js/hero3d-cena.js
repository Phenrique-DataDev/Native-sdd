/*!
 * hero3d-cena.js — a cena do monólito · landing docs/
 *
 * Carregado por `hero3d.js` e SÓ por ele, depois que as guardas passam: preferência de
 * movimento, Data Saver, WebGL disponível, palco presente. Nada aqui re-checa isso.
 *
 * O que ele desenha, e por quê: cinco placas empilhadas atravessadas por um pulso que passa
 * por todas na ordem, sem pular nenhuma. Isso é a tese do produto — o método não deixa a
 * intenção virar artefato sem passar pelas cinco fases. Um campo de partículas não afirmaria
 * nada, e por isso continua vetado no docs/DESIGN.md.
 *
 * O Three.js é vendorizado em docs/assets/js/, como o GSAP: nada de CDN em runtime. O caminho
 * é relativo AO MÓDULO, não ao documento — é assim que `import()` resolve dentro de um ESM, e
 * é o que mantém a referência válida se a página que carrega este módulo mudar de lugar (foi o
 * que aconteceu em 2026-09-07, quando a landing saiu de `docs/compiler/` para `docs/`).
 */

const THREE_URL = './three.module.min.js';

// ---------------------------------------------------------------------------
// Tokens. Lidos do CSS, como o motion.js faz — com duas fontes de verdade, girar o accent no
// site.css deixaria o monólito para trás, ainda laranja de uma paleta que mudou.
// ---------------------------------------------------------------------------
// Os três já foram validados pelo carregador — se não existissem, este módulo não teria
// sido importado. Consultar de novo só produziria uma checagem que nunca falha.
const stage = document.querySelector('[data-hero-stage]');
const canvas = stage.querySelector('[data-hero3d]');
// A legenda é IRMÃ do palco, não filha — ela ficaria sobre o desenho por dentro. E o
// atributo é `data-hero-phase`, não `data-phase`: este último já era usado pelos cassettes
// da seção #motor, e um seletor solto no documento pegaria os dez elementos.
const rotulos = [...document.querySelectorAll('[data-hero-phases] [data-hero-phase]')];

const css = getComputedStyle(document.documentElement);
function token(nome, padrao) {
  const v = css.getPropertyValue(nome).trim();
  return v || padrao;
}
const COR = {
  accent: token('--accent', '#FF5500'),
  muted: token('--muted', '#7E8B9B'),
  ink: token('--ink', '#F0F3F6')
};

// A mesma chave que o resto do site usa para desligar movimento sem desligar layout.
const INTENSIDADE = parseFloat(token('--motion-intensidade', '1')) || 0;

// ---------------------------------------------------------------------------
// Geometria da cena, em unidades de mundo.
//
// As placas são horizontais e empilhadas no eixo Y, não no Z como o D-02 descreveu. A
// semântica é a mesma — cinco camadas em profundidade, atravessadas na ordem — mas o
// hero-art é um retrato de 520×700: com o empilhamento em Z e a câmera de frente, as cinco
// camadas se sobrepõem num alvo concêntrico e a ordem some. Empilhadas em Y e vistas de
// ~20° acima, elas lêem como as camadas que são, e a leitura casa com o SVG que fica no
// lugar delas quando não há WebGL.
// ---------------------------------------------------------------------------
const N = 5;
const PASSO = 0.94;               // distância entre placas
const TOPO = ((N - 1) / 2) * PASSO;
const LARG = 2.5;                 // x
const PROF = 1.5;                 // z
const CICLO = 4.6;                // segundos que o pulso leva de cima a baixo
const MARGEM = 0.9;               // sobra do curso do pulso além das placas extremas

// A caixa que precisa caber na tela, com folga. É daqui que sai a distância da câmera —
// ver `dimensionar()`. Fixar a posição da câmera em números escolhidos a olho funcionava no
// palco de 1440px e cortava o monólito em qualquer outro: num palco retrato o campo de visão
// HORIZONTAL é menor que o vertical, e o objeto vazava pelos lados sem aviso.
const ENQ_LARG = LARG * 1.28;     // folga para o giro, que aumenta a largura projetada
const ENQ_ALT = (TOPO + MARGEM) * 2 * 1.06;

const alturaDaPlaca = (i) => TOPO - i * PASSO;

const three = await import(THREE_URL);
const {
  Scene, PerspectiveCamera, WebGLRenderer, Group, Color,
  BufferGeometry, BufferAttribute, LineSegments, LineBasicMaterial
} = three;

// ---------------------------------------------------------------------------
// Helpers de geometria — tudo é LineSegments (pares de vértices). Nada de malha sólida: o
// site inteiro é desenho técnico de uma linha, e uma superfície sombreada aqui seria a única
// coisa na página com volume.
// ---------------------------------------------------------------------------
function segmentos(pontos, cor, opacidade, corPorVertice) {
  const g = new BufferGeometry();
  g.setAttribute('position', new BufferAttribute(new Float32Array(pontos), 3));
  if (corPorVertice) g.setAttribute('color', new BufferAttribute(corPorVertice, 3));
  const m = new LineBasicMaterial({
    color: new Color(cor),
    transparent: true,
    opacity: opacidade,
    vertexColors: !!corPorVertice
  });
  return new LineSegments(g, m);
}

// Retângulo no plano XZ, na altura y, com marcas de registro nos cantos — as mesmas do SVG.
function placa(y) {
  const x = LARG / 2, z = PROF / 2, t = 0.22; // t = comprimento da marca de canto
  const p = [];
  const linha = (ax, az, bx, bz) => p.push(ax, y, az, bx, y, bz);

  linha(-x, -z, x, -z); linha(x, -z, x, z); linha(x, z, -x, z); linha(-x, z, -x, -z);
  for (const sx of [-1, 1]) for (const sz of [-1, 1]) {
    linha(sx * x, sz * z, sx * (x - t), sz * z);
    linha(sx * x, sz * z, sx * x, sz * (z - t));
  }
  return p;
}

// ---------------------------------------------------------------------------
// Cena
// ---------------------------------------------------------------------------
const scene = new Scene();

// FOV estreito e câmera longe, de propósito: quanto menor o ângulo, mais a projeção se
// aproxima da axonométrica: as cinco placas ficam com o mesmo tamanho aparente e lêem como
// camadas de uma elevação técnica. Com o fov largo da primeira versão, a placa de baixo
// aparecia com o dobro da de cima e o objeto virava um funil.
const FOV = 19;
// Direção do olhar, normalizada. A distância é calculada em `dimensionar()`; aqui só fica
// o ângulo — cerca de 19° acima do plano das placas, o bastante para elas terem espessura
// aparente sem virar uma vista de cima.
const DIR = { x: 0, y: 0.345, z: 1 };
{
  const n = Math.hypot(DIR.x, DIR.y, DIR.z);
  DIR.x /= n; DIR.y /= n; DIR.z /= n;
}
const camera = new PerspectiveCamera(FOV, 1, 0.1, 200);

const renderer = new WebGLRenderer({
  canvas,
  antialias: true,
  alpha: true,               // o fundo é o do CSS; o canvas não pinta ground próprio
  powerPreference: 'low-power'
});
renderer.setClearAlpha(0);

const monolito = new Group();
scene.add(monolito);

// Uma placa = um LineSegments com material próprio, porque cada uma acende sozinha quando o
// pulso passa. Compartilhar material entre as cinco faria as cinco acenderem juntas — que é
// exatamente o oposto do que o objeto afirma.
const placas = [];
for (let i = 0; i < N; i++) {
  const obj = segmentos(placa(alturaDaPlaca(i)), COR.muted, 0.5);
  placas.push(obj);
  monolito.add(obj);
}

// As quatro colunas de canto — sem elas, cinco retângulos soltos não lêem como um sólido.
{
  const x = LARG / 2, z = PROF / 2, base = -TOPO, topo = TOPO;
  const p = [];
  for (const sx of [-1, 1]) for (const sz of [-1, 1]) p.push(sx * x, base, sz * z, sx * x, topo, sz * z);
  monolito.add(segmentos(p, COR.muted, 0.3));
}

// A régua lateral. O SVG que este objeto substitui trazia uma escala com tiques e cotas à
// esquerda, e é ela que faz o desenho ler como datasheet em vez de "gráfico 3D". Sem cota
// numérica — texto em WebGL exigiria atlas de fonte, e o número não é o ponto: o que importa
// é o desenho declarar que está medindo alguma coisa.
{
  const x = -LARG / 2 - 0.28, z = PROF / 2, p = [];
  p.push(x, -TOPO - MARGEM * 0.6, z, x, TOPO + MARGEM * 0.6, z);   // haste
  for (let i = 0; i < N; i++) {
    const y = alturaDaPlaca(i);
    p.push(x, y, z, x + 0.13, y, z);                                // tique da camada
    p.push(x, y - PASSO / 2, z, x + 0.07, y - PASSO / 2, z);        // subdivisão
  }
  monolito.add(segmentos(p, COR.muted, 0.34));
}

// O eixo do feixe: uma linha vertical no centro, de ponta a ponta do curso do pulso. É a
// mesma linha do SVG (`x1=276`), aqui em três dimensões.
monolito.add(segmentos([0, -TOPO - MARGEM, 0, 0, TOPO + MARGEM, 0], COR.accent, 0.26));

// O pulso: um quadrado pequeno no eixo, que desce cruzando as placas. Não é um brilho solto —
// é um objeto atravessando, e é a passagem dele que acende cada camada.
const pulso = (() => {
  const r = 0.17, p = [];
  const linha = (ax, az, bx, bz) => p.push(ax, 0, az, bx, 0, bz);
  linha(-r, -r, r, -r); linha(r, -r, r, r); linha(r, r, -r, r); linha(-r, r, -r, -r);
  const obj = segmentos(p, COR.accent, 1);
  monolito.add(obj);
  return obj;
})();

// ---------------------------------------------------------------------------
// A grade de fundo.
//
// D-02 registrou que a primeira versão dela "lê como ruído espalhado, não como onda", e a
// causa era a soma de senos com fases independentes: várias cristas nascendo em lugares sem
// relação nenhuma entre si. Aqui a deformação é UMA onda radial só, saindo de onde o ponteiro
// está e amortecendo com a distância — a leitura de onda vem da origem única, não da
// amplitude. Sem ponteiro (toque, teclado), a origem faz uma órbita lenta, e o efeito é o
// mesmo de uma gota caindo devagar.
// ---------------------------------------------------------------------------
const GRADE = { meio: 5.2, div: 20, y: -TOPO - MARGEM * 1.3, amp: 0.3, k: 2.6, vel: 2.3, alcance: 3.0 };
const grade = (() => {
  const { meio, div } = GRADE;
  const passo = (meio * 2) / div;
  const p = [];
  for (let i = 0; i <= div; i++) {
    const c = -meio + i * passo;
    for (let j = 0; j < div; j++) {
      const a = -meio + j * passo, b = a + passo;
      p.push(c, GRADE.y, a, c, GRADE.y, b);   // linhas ao longo de Z
      p.push(a, GRADE.y, c, b, GRADE.y, c);   // linhas ao longo de X
    }
  }
  // Atenuação radial gravada na cor de cada vértice. Sem ela a grade termina numa aresta
  // reta no meio do hero — o olho lê a borda do plano, não um campo. Vai por vertexColors e
  // não por um shader próprio porque é multiplicação simples e o LineBasicMaterial já a faz.
  const cores = new Float32Array(p.length);
  for (let i = 0; i < p.length; i += 3) {
    const d = Math.hypot(p[i], p[i + 2]) / GRADE.meio;
    const f = Math.max(0, 1 - d * d);
    cores[i] = cores[i + 1] = cores[i + 2] = f;
  }
  const obj = segmentos(p, COR.muted, 0.26, cores);
  scene.add(obj);
  return obj;
})();
const gradePos = grade.geometry.getAttribute('position');
const gradeBase = Float32Array.from(gradePos.array);

// ---------------------------------------------------------------------------
// Ponteiro. Guardado em coordenadas normalizadas do palco e convertido para mundo no tick —
// converter no listener faria a conta a cada pointermove, que dispara dezenas de vezes por
// segundo mesmo quando o laço está parado.
// ---------------------------------------------------------------------------
const alvo = { x: 0, z: 0, ativo: false };
const atual = { x: 0, z: 0, giro: 0 };

stage.addEventListener('pointermove', (e) => {
  const r = stage.getBoundingClientRect();
  if (!r.width || !r.height) return;
  alvo.x = ((e.clientX - r.left) / r.width) * 2 - 1;
  alvo.z = ((e.clientY - r.top) / r.height) * 2 - 1;
  alvo.ativo = true;
}, { passive: true });

stage.addEventListener('pointerleave', () => { alvo.ativo = false; }, { passive: true });

// ---------------------------------------------------------------------------
// Dimensionamento. O DPR é limitado a 2: acima disso o custo cresce com o quadrado e a
// diferença numa malha de linhas de 1px é invisível.
// ---------------------------------------------------------------------------
function dimensionar() {
  const r = stage.getBoundingClientRect();
  const w = Math.max(1, Math.round(r.width));
  const h = Math.max(1, Math.round(r.height));
  renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 2));
  renderer.setSize(w, h, false);

  const aspect = w / h;
  camera.aspect = aspect;

  // A distância sai do enquadramento, não de um número escolhido a olho. O fov do
  // PerspectiveCamera é VERTICAL; o horizontal é derivado do aspect, e num palco retrato ele
  // é o menor dos dois. Calcular os dois e ficar com a distância maior é o que garante que o
  // monólito caiba tanto num hero de 1440px quanto na coluna estreita de 340px.
  const metadeV = Math.tan((FOV * Math.PI) / 180 / 2);
  const metadeH = metadeV * aspect;
  const dist = Math.max((ENQ_ALT / 2) / metadeV, (ENQ_LARG / 2) / metadeH);

  camera.position.set(DIR.x * dist, DIR.y * dist, DIR.z * dist);
  camera.lookAt(0, 0, 0);
  camera.updateProjectionMatrix();
}
dimensionar();
new ResizeObserver(dimensionar).observe(stage);

// ---------------------------------------------------------------------------
// O laço
// ---------------------------------------------------------------------------
const corFria = new Color(COR.muted);
const corQuente = new Color(COR.accent);
const scratch = new Color();

let t = 0;
let ultimo = 0;
let faseVisivel = -1;

function tick(agora) {
  // Delta próprio em vez do relógio absoluto: ao retomar depois de minutos com a aba oculta,
  // um relógio absoluto teleportaria o pulso para o meio do curso. Clampado em 50ms para que
  // um engasgo do main thread também não produza salto.
  const dt = ultimo ? Math.min((agora - ultimo) / 1000, 0.05) : 0;
  ultimo = agora;
  t += dt;

  // --- pulso e placas ---
  const curso = TOPO + MARGEM;
  const fase = (t % CICLO) / CICLO;
  const y = curso - fase * (curso * 2);
  pulso.position.y = y;

  let acesa = 0;
  let maiorCalor = 0;
  for (let i = 0; i < N; i++) {
    const d = Math.abs(alturaDaPlaca(i) - y);
    // Gaussiana estreita: a placa acende quando o pulso está sobre ela e apaga logo depois.
    // Larga demais, as cinco ficariam acesas ao mesmo tempo e a ordem desapareceria.
    const calor = Math.exp(-(d * d) / 0.10);
    const m = placas[i].material;
    m.color.copy(scratch.copy(corFria).lerp(corQuente, calor));
    m.opacity = 0.48 + calor * 0.52;
    if (calor > maiorCalor) { maiorCalor = calor; acesa = i; }
  }

  // A legenda segue a mesma placa. Só se toca no DOM quando a fase muda de fato: escrever
  // classe a 60fps em cinco elementos custaria mais que a cena inteira.
  if (acesa !== faseVisivel) {
    if (rotulos[faseVisivel]) rotulos[faseVisivel].classList.remove('is-active');
    if (rotulos[acesa]) rotulos[acesa].classList.add('is-active');
    faseVisivel = acesa;
  }

  // --- giro do conjunto ---
  // Segue o ponteiro; sem ele, oscila sozinho. `INTENSIDADE` é o mesmo token que zera o
  // movimento no resto do site — com ele em 0, o monólito fica parado de frente.
  const giroAlvo = (alvo.ativo ? alvo.x * 0.26 : Math.sin(t * 0.28) * 0.14) * INTENSIDADE;
  atual.giro += (giroAlvo - atual.giro) * Math.min(1, dt * 2.4);
  monolito.rotation.y = atual.giro;

  // --- onda da grade ---
  const ox = alvo.ativo ? alvo.x * GRADE.meio * 0.8 : Math.cos(t * 0.21) * GRADE.meio * 0.42;
  const oz = alvo.ativo ? alvo.z * GRADE.meio * 0.8 : Math.sin(t * 0.17) * GRADE.meio * 0.42;
  atual.x += (ox - atual.x) * Math.min(1, dt * 1.8);
  atual.z += (oz - atual.z) * Math.min(1, dt * 1.8);

  const arr = gradePos.array;
  const amp = GRADE.amp * INTENSIDADE;
  for (let i = 0; i < arr.length; i += 3) {
    const dx = gradeBase[i] - atual.x;
    const dz = gradeBase[i + 2] - atual.z;
    const r = Math.sqrt(dx * dx + dz * dz);
    arr[i + 1] = gradeBase[i + 1] + Math.sin(r * GRADE.k - t * GRADE.vel) * amp * Math.exp(-r / GRADE.alcance);
  }
  gradePos.needsUpdate = true;

  renderer.render(scene, camera);
}

// ---------------------------------------------------------------------------
// Pausa nos dois eixos: fora da viewport (IntersectionObserver) e aba oculta
// (visibilitychange). O `motion.js` cobre os dois para os tweens dele; um laço de WebGL
// rodando atrás de uma aba escondida é o caso mais caro dos dois, e o mais fácil de esquecer.
// ---------------------------------------------------------------------------
let naTela = true;
let rodando = false;

function sincronizar() {
  const deveRodar = naTela && !document.hidden;
  if (deveRodar === rodando) return;
  rodando = deveRodar;
  if (deveRodar) {
    ultimo = 0;                              // zera o delta: nada de salto ao retomar
    renderer.setAnimationLoop(tick);
  } else {
    renderer.setAnimationLoop(null);
  }
}

new IntersectionObserver((entradas) => {
  naTela = entradas.some((e) => e.isIntersecting);
  sincronizar();
}).observe(stage);

document.addEventListener('visibilitychange', sincronizar);

// ---------------------------------------------------------------------------
// A troca de palco. Só acontece aqui, na última linha do caminho feliz: até este ponto
// qualquer falha (import recusado, contexto perdido, `stage` ausente) deixa o SVG intacto —
// nunca um buraco onde o hero deveria estar.
// ---------------------------------------------------------------------------
renderer.render(scene, camera);   // primeiro frame antes do fade, para não piscar vazio
stage.classList.add('is-3d');
sincronizar();

// Aviso para o motion.js parar de animar o feixe do SVG, que a partir de agora está invisível.
// Sem isto o GSAP seguiria tweenando um elemento que ninguém vê, para sempre.
window.dispatchEvent(new CustomEvent('hero3d:ready'));

// Contexto perdido acontece de verdade (troca de GPU, suspensão do laptop, aba reciclada pelo
// browser). Sem este handler o hero congelaria no último frame, que é pior que não ter WebGL.
canvas.addEventListener('webglcontextlost', (e) => {
  e.preventDefault();
  renderer.setAnimationLoop(null);
  rodando = false;
  stage.classList.remove('is-3d');
});

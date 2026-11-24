export const meta = {
  name: 'review-paralela',
  description: 'Revisa o diff atual em paralelo (correção, segurança, testes) e confirma cada achado com um refutador independente antes de reportar',
  whenToUse: 'Diff pronto para revisão em que um revisor só pode deixar passar algo: mudança que cruza várias áreas, PR grande, ou antes de pedir merge. Somente leitura. Para decompor e CONSTRUIR um objetivo, use /orchestrate.',
  phases: [
    { title: 'Revisar', detail: 'um revisor por eixo, em paralelo, sobre o mesmo diff' },
    { title: 'Confirmar', detail: 'um refutador independente por achado (com teto)' },
  ],
}

// Receita do Native-SDD (ORQ_RECEITA_WORKFLOW). Somente leitura: nenhum agente edita, commita ou
// faz push. Rode pelo nome ("roda o workflow review-paralela"), opcionalmente com
// args: { base: 'main', maxConfirm: 8 }.
//
// Quando usar isto e quando usar o /orchestrate: esta receita REVISA um diff que já existe, com
// forma fixa (eixos -> confirmação). O /orchestrate DECOMPÕE um objetivo em tasks com deps, STATE
// resumível e checkpoint humano. Se a pergunta é "este diff tem problema?", é aqui; se é "faça X",
// é lá.

const BASE = (args && typeof args.base === 'string' && args.base) || 'main'
const MAX_CONFIRM = (args && Number.isInteger(args.maxConfirm) && args.maxConfirm >= 0) ? args.maxConfirm : 8

const COMMON = `Revise o diff de \`git diff ${BASE}...HEAD\` (mais o que estiver em \`git diff\` e \`git diff --cached\`, se houver), no repositório da sessão.
SOMENTE LEITURA: não edite, não crie, não apague arquivo; não rode git commit, push, reset, checkout nem nada que mude o repositório.
Leia os chamadores e os testes do código alterado, não só as linhas do diff. Todo achado cita caminho:linha que você abriu.
Não invente: o que não conferiu no código fica de fora. Prefira poucos achados reais a muitos plausíveis; estilo é do linter.
As regras do projeto (AGENTS.md, .claude/rules/project-context.md) valem: use os comandos de verificação declarados lá, não deduza outros.`

const FINDINGS = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          severity: { type: 'string', enum: ['alta', 'media', 'baixa'] },
          claim: { type: 'string', description: 'o defeito, em uma frase' },
          scenario: { type: 'string', description: 'entrada/estado concreto -> resultado errado' },
        },
        required: ['file', 'line', 'severity', 'claim', 'scenario'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT = {
  type: 'object',
  properties: {
    refuted: { type: 'boolean' },
    reason: { type: 'string', description: 'o que você leu ou rodou que sustenta o veredito' },
  },
  required: ['refuted', 'reason'],
}

const EIXOS = [
  {
    key: 'correcao',
    agentType: 'code-reviewer',
    prompt: 'Eixo: CORREÇÃO. Bugs que o diff introduz ou piora: lógica, borda, concorrência, contrato com quem chama, erro engolido.',
  },
  {
    key: 'seguranca',
    agentType: 'security-reviewer',
    prompt: 'Eixo: SEGURANÇA. Entrada não confiável, injeção, segredo exposto, autorização, dado pessoal em log.',
  },
  {
    key: 'testes',
    agentType: 'code-reviewer',
    prompt: 'Eixo: TESTES. O diff enfraquece algum teste (skip, assert removido, valor esperado trocado para bater com o código)? O comportamento novo tem teste que reprovaria sem ele? Rode a suíte declarada em project-context.md se ela existir e diga o resultado.',
  },
]

// Usa o agente do catálogo do projeto quando existe; sem ele (projeto que o removeu), cai no
// agente padrão em vez de derrubar o eixo inteiro.
async function revisar(eixo) {
  const prompt = `${COMMON}\n\n${eixo.prompt}`
  try {
    return await agent(prompt, { label: `revisar:${eixo.key}`, phase: 'Revisar', schema: FINDINGS, agentType: eixo.agentType })
  } catch (e) {
    log(`eixo ${eixo.key}: agente ${eixo.agentType} indisponível (${String(e && e.message || e)}); usando o padrão`)
    return await agent(prompt, { label: `revisar:${eixo.key}`, phase: 'Revisar', schema: FINDINGS })
  }
}

const ORDEM = { alta: 0, media: 1, baixa: 2 }
const naoConfirmados = []

// Barreira de propósito: o teto de confirmação é GLOBAL e vai para os achados mais graves de todos
// os eixos. Com pipeline, o eixo que terminasse primeiro gastaria o teto com os achados baixos dele,
// e um alto de um eixo mais lento ficaria sem refutador (medido na comparação com o /orchestrate).
const revisoes = await parallel(EIXOS.map(eixo => () => revisar(eixo)))
// Eixo cujo revisor não respondeu (pulado ou morto) é lacuna de cobertura, não "0 achados".
const semResposta = EIXOS.filter((e, i) => !revisoes[i]).map(e => e.key)
for (const k of semResposta) log(`eixo ${k}: o revisor não respondeu; o eixo NÃO foi coberto`)

const todos = EIXOS.flatMap((eixo, i) => ((revisoes[i] && revisoes[i].findings) || []).map(f => ({ eixo: eixo.key, ...f })))
  .sort((a, b) => ORDEM[a.severity] - ORDEM[b.severity])
// Teto de confirmação: o excedente NÃO some, volta marcado como não confirmado.
for (const f of todos.slice(MAX_CONFIRM)) naoConfirmados.push({ ...f, motivo: 'acima do teto' })

const julgados = (await parallel(todos.slice(0, MAX_CONFIRM).map(f => () => agent(
  `${COMMON}\n\nTente REFUTAR este achado do eixo ${f.eixo}. Abra o arquivo, leia os chamadores, rode o que precisar (sem mudar o repositório). Na dúvida, refuted=true.\n\nAchado: ${f.file}:${f.line} [${f.severity}] ${f.claim}\nCenário: ${f.scenario}`,
  { label: `confirmar:${f.eixo}:${f.file}:${f.line}`, phase: 'Confirmar', schema: VERDICT },
).then(v => {
  if (v) return { ...f, refuted: v.refuted, reason: v.reason }
  // Refutador pulado ou morto: o achado não tem veredito, mas também não some.
  naoConfirmados.push({ ...f, motivo: 'refutador sem resposta' })
  log(`confirmar ${f.file}:${f.line}: o refutador não respondeu; o achado volta como não confirmado`)
  return null
})))).filter(Boolean)
const confirmados = julgados.filter(f => !f.refuted)
const refutados = julgados.filter(f => f.refuted)

const acimaDoTeto = naoConfirmados.filter(f => f.motivo === 'acima do teto').length
if (acimaDoTeto) log(`${acimaDoTeto} achado(s) acima do teto de ${MAX_CONFIRM} confirmações voltam como não confirmados`)
log(`${confirmados.length} confirmado(s), ${refutados.length} refutado(s)`)

return {
  base: BASE,
  confirmados,
  refutados: refutados.map(f => ({ eixo: f.eixo, file: f.file, line: f.line, claim: f.claim, reason: f.reason })),
  naoConfirmados,
  eixosSemResposta: semResposta,
}

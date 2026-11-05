import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { RepoState } from '../types'

const FETCH_EVERY_MS = 5 * 60 * 1000

// Troque a tag quando o formato do RepoState mudar: ela recusa o que uma versão anterior guardou.
const repo = atom({ plugin: 'repo-sync-band', key: 'repo' } as const, null, { shape: 'repo-1' })
const isHidden = atom({ plugin: 'repo-sync-band', key: 'isHidden' } as const, false)

type Segment = { text: string; tone?: 'warning' | 'error' | 'dim' }
type Pending = 'none' | 'local' | 'fetch'

// Estado do módulo: some num reload, e o primeiro check refaz tudo.
let baselineSha: string | undefined
let lastFetchAt = 0
let isChecking = false
// Os hooks só marcam o pedido; quem roda o git é o timer aberto no session.start,
// para nada passar do orçamento de um hook nem segurar o fim do turno.
let pending: Pending = 'none'

function ask(kind: 'local' | 'fetch') {
  if (pending !== 'fetch') pending = kind
}

async function git($: EngineInterface, cwd: string, args: string[], timeoutMs = 10_000) {
  const ran = await $.process.run(['git', '-C', cwd, ...args], { timeoutMs }).catch(() => undefined)

  return ran && ran.exitCode === 0 ? ran.stdout.trim() : undefined
}

function lines(text: string | undefined) {
  return text ? text.split(/\r?\n/).filter(Boolean) : []
}

// ~/.claude a partir de onde o mod mora (~/.claude/skills/repo-sync-band); undefined se mora fora.
function claudeHome(pluginRoot: string): string | undefined {
  return /^(.*[\\/]\.claude)[\\/]skills[\\/]/.exec(pluginRoot)?.[1]
}

async function readVersions($: EngineInterface, top: string) {
  const isNativeSdd = await $.fs.exists(`${top}/onboarding/install.ps1`)
  if (!isNativeSdd) return {}
  const repoVersion = (await $.fs.read(`${top}/VERSION`).catch(() => undefined))?.trim()
  const home = claudeHome($.plugin.root)
  const marker = home ? await $.fs.read(`${home}/.native-sdd-version`).catch(() => undefined) : undefined
  const installedVersion = marker ? /installed_version:\s*(\S+)/.exec(marker)?.[1] : undefined

  return { repoVersion, installedVersion }
}

async function check($: EngineInterface, mayFetch: boolean): Promise<RepoState | null> {
  const cwd = await $.session.cwd()
  if ((await git($, cwd, ['rev-parse', '--is-inside-work-tree'])) !== 'true') {
    await update($, repo, () => null)

    return null
  }

  const hasOrigin = lines(await git($, cwd, ['remote'])).includes('origin')
  const now = await $.clock.now()
  if (hasOrigin && mayFetch && now - lastFetchAt > FETCH_EVERY_MS) {
    lastFetchAt = now
    await git($, cwd, ['fetch', '--quiet', 'origin'], 30_000)
  }

  const originHead = await git($, cwd, ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'])
  const hasMain = (await git($, cwd, ['rev-parse', '--verify', '--quiet', 'refs/heads/main'])) !== undefined
  const defaultBranch = originHead?.replace(/^origin\//, '') ?? (hasMain ? 'main' : 'master')
  const base = hasOrigin ? `origin/${defaultBranch}` : defaultBranch

  const [status, defaultCounts, mergedLocalRaw, mergedRemoteRaw, worktreeList, tag, remoteSha, top] =
    await Promise.all([
      git($, cwd, ['status', '--porcelain=v2', '--branch']),
      hasOrigin ? git($, cwd, ['rev-list', '--left-right', '--count', `${defaultBranch}...${base}`]) : undefined,
      git($, cwd, ['branch', '--merged', base, '--format=%(refname:short)']),
      hasOrigin ? git($, cwd, ['branch', '-r', '--merged', base, '--format=%(refname:short)']) : undefined,
      git($, cwd, ['worktree', 'list', '--porcelain']),
      git($, cwd, ['describe', '--tags', '--abbrev=0']),
      hasOrigin ? git($, cwd, ['rev-parse', base]) : undefined,
      git($, cwd, ['rev-parse', '--show-toplevel']),
    ])

  let branch = '?'
  let ahead: number | undefined
  let behind: number | undefined
  let dirty = 0
  for (const line of lines(status)) {
    if (line.startsWith('# branch.head ')) branch = line.slice('# branch.head '.length)
    else if (line.startsWith('# branch.ab ')) {
      const [a = '0', b = '0'] = line.slice('# branch.ab '.length).split(' ')
      ahead = Number(a.replace('+', ''))
      behind = Number(b.replace('-', ''))
    } else if (!line.startsWith('#')) dirty += 1
  }

  const [defaultAhead = 0, defaultBehind = 0] = (defaultCounts ?? '0\t0').split(/\s+/).map(Number)

  // origin/<default> andou e nenhuma branch local tem o commit: foi outra sessão ou outra máquina.
  let isRemoteMovedElsewhere = false
  if (remoteSha) {
    if (baselineSha === undefined) baselineSha = remoteSha
    if (remoteSha !== baselineSha) {
      const holders = lines(await git($, cwd, ['branch', '--contains', remoteSha, '--format=%(refname:short)']))
      isRemoteMovedElsewhere = holders.length === 0
      if (!isRemoteMovedElsewhere) baselineSha = remoteSha
    }
  }

  const next: RepoState = {
    branch,
    defaultBranch,
    ahead,
    behind,
    dirty,
    defaultAhead,
    defaultBehind,
    mergedLocal: lines(mergedLocalRaw).filter(name => name !== defaultBranch && name !== branch),
    mergedRemote: lines(mergedRemoteRaw).filter(
      name => name !== 'origin' && name !== 'origin/HEAD' && name !== base,
    ),
    worktrees: lines(worktreeList).filter(line => line.startsWith('worktree ')).length,
    tag,
    ...(top ? await readVersions($, top) : {}),
    isRemoteMovedElsewhere,
    checkedAt: now,
  }
  await update($, repo, () => next)

  return next
}

async function refresh($: EngineInterface, mayFetch: boolean) {
  if (isChecking) return
  isChecking = true
  try {
    await check($, mayFetch)
  } catch (error) {
    $.ui.log(`repo-sync-band: ${String(error)}`, { to: 'debug' })
  } finally {
    isChecking = false
  }
}

function segments(state: RepoState): Segment[] {
  const out: Segment[] = []
  const sync =
    state.ahead === undefined
      ? 'sem upstream'
      : state.ahead === 0 && state.behind === 0
        ? '= remoto'
        : `↑${state.ahead} ↓${state.behind}`
  out.push({ text: `⎇ ${state.branch} ${sync}`, tone: state.ahead || state.behind ? 'warning' : undefined })
  if (state.dirty > 0) out.push({ text: `±${state.dirty} não commitados`, tone: 'warning' })
  if (state.branch !== state.defaultBranch && (state.defaultAhead || state.defaultBehind)) {
    out.push({ text: `${state.defaultBranch} ↑${state.defaultAhead} ↓${state.defaultBehind}`, tone: 'warning' })
  }
  const merged = state.mergedLocal.length + state.mergedRemote.length
  if (merged > 0) out.push({ text: `${merged} branches mergeadas sobrando`, tone: 'warning' })
  if (state.worktrees > 1) out.push({ text: `${state.worktrees - 1} worktree(s) extra`, tone: 'warning' })
  if (state.tag) out.push({ text: `tag ${state.tag}`, tone: 'dim' })
  if (state.repoVersion && state.installedVersion && state.repoVersion !== state.installedVersion) {
    out.push({ text: `~/.claude ${state.installedVersion} ≠ repo ${state.repoVersion}`, tone: 'warning' })
  }
  if (state.isRemoteMovedElsewhere) {
    out.push({ text: `origin/${state.defaultBranch} mudou por fora (outra sessão?)`, tone: 'error' })
  }

  return out
}

function detail(state: RepoState): string {
  const text = segments(state).map(one => `- ${one.text}`)
  if (state.mergedLocal.length > 0) text.push(`  locais mergeadas: ${state.mergedLocal.join(', ')}`)
  if (state.mergedRemote.length > 0) text.push(`  remotas mergeadas: ${state.mergedRemote.join(', ')}`)

  return text.join('\n')
}

function tick($: EngineInterface) {
  if (pending === 'none' || isChecking) return
  const mayFetch = pending === 'fetch'
  pending = 'none'
  void refresh($, mayFetch)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({
      name: 'repo-sync',
      description: 'Estado do repo contra o remoto (on/off mostra ou esconde a faixa)',
    })
    ask('fetch')
    $.clock.every(2000, () => tick($))

    return started
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    ask('fetch')

    return done
  })

  // Depois de um comando git (merge, push, branch -d), atualiza sem esperar o fim do turno.
  on('tool.call', { tool: ['Bash', 'PowerShell'] }, async ($, e, next) => {
    const ran = await next(e)
    if (/\bgit\b|\bgh\b/.test(e.command)) ask('local')

    return ran
  }).catch(($, e, next) => next(e))

  on('command.run', { command: 'repo-sync' }, async ($, e) => {
    const arg = e.args.trim()
    if (arg === 'off' || arg === 'on') {
      await update($, isHidden, () => arg === 'off')

      return { text: arg === 'off' ? 'Faixa do repo escondida.' : 'Faixa do repo visível.' }
    }
    lastFetchAt = 0
    const state = await check($, true).catch(() => null)

    return { text: state ? detail(state) : 'Fora de um repositório git.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const state = await read($, repo)
    if (e.props.hasSurvey || state === null || (await read($, isHidden))) return next(e)

    const { Box, Text } = $.ui.resolve(e)
    const parts = segments(state)

    return (
      <Box>
        {parts.map((part, index) => (
          <Text
            key={`s${index}`}
            color={part.tone === 'warning' || part.tone === 'error' ? part.tone : undefined}
            dimColor={part.tone === 'dim' || part.tone === undefined}
          >
            {index > 0 ? ' · ' : ''}
            {part.text}
          </Text>
        ))}
      </Box>
    )
  })
}

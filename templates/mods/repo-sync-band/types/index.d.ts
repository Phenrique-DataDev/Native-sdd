export type RepoState = {
  branch: string
  defaultBranch: string
  // Branch atual contra o upstream dela; undefined sem upstream.
  ahead?: number
  behind?: number
  dirty: number
  // Default local contra origin/<default>.
  defaultAhead: number
  defaultBehind: number
  mergedLocal: string[]
  mergedRemote: string[]
  worktrees: number
  tag?: string
  // Só no repositório do Native-SDD: VERSION do repo × instalada em ~/.claude.
  repoVersion?: string
  installedVersion?: string
  // origin/<default> andou para um commit que nenhuma branch local contém.
  isRemoteMovedElsewhere: boolean
  checkedAt: number
}

declare module 'claude-code' {
  interface PluginState {
    'repo-sync-band': {
      repo: Shaped<RepoState | null>
      isHidden: boolean
    }
  }
}

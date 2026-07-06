---
description: "Gerencia o registro de repositórios complementares de referência (add/list/remove) — .claude/complementary-repos.psd1"
---

# /complementary-repos — repositórios complementares de referência

Gerencia o registro de **outros repositórios do próprio usuário** (locais e/ou remotos) que o
agente pode consultar **read-only** como referência de padrão/convenção — nunca vendorizar, só
adaptar (ver [`rules/complementary-repos.md`](../rules/complementary-repos.md)). O registro vive
em `.claude/complementary-repos.psd1`, versionado no **projeto-alvo** (não no scaffold).

---

## Uso

```text
/complementary-repos                              # lista o registro (default)
/complementary-repos list
/complementary-repos add <path|url> --reason "..." [--name <slug>]
/complementary-repos remove <name>
```

---

## Passo 1 — Resolver a camada `tools/` e agir

```powershell
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
if ($toolsRoot) {
    . "$toolsRoot/complementary-repos.ps1"

    # LISTAR (default): painel read-only com status de cada entrada
    Format-ComplementaryRepoList

    # ADICIONAR: path local OU url — Reason é sempre obrigatório
    #   Add-ComplementaryRepoEntry -Path '<caminho local>' -Reason '<por que é relevante>' [-Name '<slug>']
    #   Add-ComplementaryRepoEntry -Url '<git url>' -Reason '<por que é relevante>' [-Name '<slug>']

    # REMOVER:
    #   Remove-ComplementaryRepoEntry -Name '<slug>'
}
```

`Add-ComplementaryRepoEntry` exige `Reason` + (`Path` ou `Url`) — lança se nenhum dos dois for
dado (`Test-ComplementaryRepoEntryValid`). O slug é derivado automaticamente
(`Get-ComplementaryRepoSlug`: `Name` > basename da `Url` sem `.git` > basename do `Path`) quando
`-Name` não é passado — informe ao usuário qual slug foi usado, para ele referenciar no `remove`.

Ao adicionar uma entrada só com `Url`, **não** clone imediatamente — o clone lazy acontece na
**primeira consulta real** feita pela regra (`Resolve-ComplementaryRepoLocation`), não no momento
do `add`. `list` mostra o status (`path OK` / `clonado em cache` / `pendente` / `órfão`) sem forçar
o clone.

---

## Passo 2 — Degradação consciente

Se `$toolsRoot` **não resolver**, avise que o registro está indisponível (camada determinística
ausente) e **não** reimplemente a leitura/escrita do `.psd1` à mão — o schema (`Import-
PowerShellDataFile`) e a serialização de volta (`ConvertTo-ComplementaryRepoPsd1Text`) vivem só em
`tools/complementary-repos.ps1`.

---

## Regras

- **Registro é do projeto-alvo, não do scaffold** — cada projeto tem o seu; o mecanismo
  (regra/comando/hook) é o que vem no scaffold.
- **`Reason` é sempre obrigatório** — sem ele, a entrada não é válida (força documentar por que
  aquele repo complementar importa, não só onde ele está).
- **`add` nunca clona na hora** — o clone lazy só acontece quando a regra realmente precisa ler
  (consulta sob demanda, sem indexação prévia).
- **`remove` não apaga o cache de clone** — só a entrada do registro; o cache em
  `.claude/.cache/complementary-repos/<slug>/` fica órfão (gitignored, descartável; pode ser
  apagado à mão se quiser liberar espaço).
- **Nunca escreve dentro de um repo complementar** — este comando só lê/escreve o **registro**
  (`.psd1`), nunca o conteúdo do repo referenciado.

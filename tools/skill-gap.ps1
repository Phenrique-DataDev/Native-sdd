<#
.SYNOPSIS
    Detecção do I2 (/skill-gap): identifica a brecha de skill que as ondas do /train-kb (G3)
    pressupõem (campo skills_needed:) e que falta no inventário do I1, e emite o esqueleto da
    skill a gerar — sem escrever (read-only).

.DESCRIPTION
    Funções puras (read-only, determinísticas) usadas pela validação automática do I2 e pelo
    comando em runtime:

      Get-DeclaredSkills   -> [pscustomobject[]]  { Skill; Capability; Wave }   (das ondas _waves/*.yaml)
      Get-SkillGap         -> [pscustomobject[]]  { Skill; Capability; Source; Status; Wave }
      Format-SkillScaffold -> [string]            SKILL.md esqueleto (status: scaffolded)

    Reusa o inventário do I1 (tools/update-skills.ps1: Get-SkillInventory) — não duplica. A
    SUGESTÃO de skills extras e a AUTORIA do conteúdo são runtime do LLM, fora deste módulo.
    Gerar/gravar a skill é ação separada (sob confirmação). Determinismo: ordenação estável;
    sem datas no conteúdo.
#>

Set-StrictMode -Version Latest

# Reuso do inventário de skills do I1 (Get-SkillInventory / ConvertFrom-SkillFrontmatter / Get-SkillHealth).
. (Join-Path $PSScriptRoot 'update-skills.ps1')

function Get-DeclaredSkills {
    <#
    .SYNOPSIS
        Extrai os itens de `skills_needed:` das ondas (_waves/*.yaml). Cada item = { name; capability }.
        Itens sem `name` são ignorados. Read-only. Vazio se nada for declarado.
    .OUTPUTS
        [pscustomobject[]] { Skill; Capability; Wave }
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$WavesRoot)

    if ([string]::IsNullOrWhiteSpace($WavesRoot) -or -not (Test-Path -LiteralPath $WavesRoot -PathType Container)) {
        return @()
    }

    $declared = foreach ($file in (Get-ChildItem -LiteralPath $WavesRoot -Filter '*.yaml' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $waveName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $lines = Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue
        $inBlock = $false
        $curName = $null
        $curCap = $null

        # Mini-parser da lista indentada sob a chave de topo `skills_needed:`.
        foreach ($line in $lines) {
            if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }

            if ($line -match '^\S') {
                # nova chave de topo → fecha o bloco (emitindo o item pendente)
                if ($inBlock -and $curName) {
                    [pscustomobject]@{ Skill = $curName; Capability = $curCap; Wave = $waveName }
                }
                $curName = $null; $curCap = $null
                $inBlock = ($line -match '^\s*skills_needed\s*:')
                continue
            }

            if (-not $inBlock) { continue }

            if ($line -match '^\s*-\s*name\s*:\s*(.+?)\s*$') {
                # novo item da lista → emite o anterior, se houver
                if ($curName) {
                    [pscustomobject]@{ Skill = $curName; Capability = $curCap; Wave = $waveName }
                }
                $curName = $Matches[1].Trim().Trim('"').Trim("'")
                $curCap = $null
            }
            elseif ($line -match '^\s*capability\s*:\s*(.+?)\s*$') {
                $curCap = $Matches[1].Trim().Trim('"').Trim("'")
            }
        }
        # item pendente ao fim do arquivo
        if ($inBlock -and $curName) {
            [pscustomobject]@{ Skill = $curName; Capability = $curCap; Wave = $waveName }
        }
    }

    return @($declared | Sort-Object Skill, Wave)
}

function Get-SkillGap {
    <#
    .SYNOPSIS
        Cruza as skills declaradas nas ondas com o inventário do I1: marca `missing` (declarada e
        ausente → gerar) ou `exists` (já instalada → pular). Read-only.
    .OUTPUTS
        [pscustomobject[]] { Skill; Capability; Source; Status; Wave }
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$WavesRoot,
        [AllowNull()][string]$GlobalRoot,
        [AllowNull()][string]$ProjectRoot
    )

    $declared = Get-DeclaredSkills -WavesRoot $WavesRoot
    if (@($declared).Count -eq 0) { return @() }

    $inv = Get-SkillInventory -GlobalRoot $GlobalRoot -ProjectRoot $ProjectRoot
    $have = @($inv | ForEach-Object { $_.Name })

    $gaps = foreach ($d in $declared) {
        $status = if ($have -contains $d.Skill) { 'exists' } else { 'missing' }
        [pscustomobject]@{
            Skill      = $d.Skill
            Capability = $d.Capability
            Source     = 'wave'
            Status     = $status
            Wave       = $d.Wave
        }
    }
    return @($gaps | Sort-Object Skill, Wave)
}

function Format-SkillScaffold {
    <#
    .SYNOPSIS
        Esqueleto determinístico de um SKILL.md (status: scaffolded): frontmatter name/description
        + seções TODO no PADRÃO AVANÇADO (mesma densidade dos 11 agentes base do scaffold) —
        Casos reais + Regras críticas faça/não-faça + Referências, todos exigindo pesquisa real
        (WebSearch/context7, nunca memória) antes de preencher. Alvo ~100 linhas no SKILL.md;
        detalhe extra vai para `assets/`/`references/` (progressive disclosure), nunca infla o
        índice. Compatível com o I1 (ConvertFrom-SkillFrontmatter/Get-SkillHealth → valid +
        custom). Sem timestamp. Quebras de linha LF.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [string]$Capability = ''
    )

    $cap = if ([string]::IsNullOrWhiteSpace($Capability)) { $Description } else { $Capability }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("---`n")
    [void]$sb.Append("name: $Name`n")
    [void]$sb.Append("description: $Description`n")
    [void]$sb.Append("status: scaffolded`n")
    [void]$sb.Append("---`n`n")
    [void]$sb.Append("# $Name`n`n")
    [void]$sb.Append("> $Description`n`n")
    [void]$sb.Append("> **Antes de preencher qualquer seção abaixo: pesquise de verdade** (WebSearch/WebFetch;`n")
    [void]$sb.Append("> `context7` se for lib/framework/CLI versionável — ver `docs-first.md`). Gotchas, Casos`n")
    [void]$sb.Append("> reais e Regras críticas **não podem vir da memória** — cite a fonte em Referências.`n`n")
    [void]$sb.Append("## Quando usar`n")
    [void]$sb.Append("TODO: o gatilho concreto que aciona esta skill — é o que o MODELO lê para decidir`n")
    [void]$sb.Append("invocar, não um resumo para humano. Prefira frase/palavra que apareça no pedido real`n")
    [void]$sb.Append("(ex.: nomes de ferramenta, verbo de ação, sintoma) a uma descrição genérica.`n`n")
    [void]$sb.Append("## Capacidade`n")
    [void]$sb.Append("$cap`n`n")
    [void]$sb.Append("## Passos`n")
    [void]$sb.Append("TODO: o necessário para executar — dê contexto/código pronto (função, snippet), não`n")
    [void]$sb.Append("um script rígido passo-a-passo. Deixe o julgamento de COMO adaptar ao Claude; não`n")
    [void]$sb.Append("reafirme o óbvio (ele já sabe programar/ler código) — só o que ele não saberia sozinho.`n`n")
    [void]$sb.Append("## Casos reais (onde a falta desta skill quebra na prática)`n")
    [void]$sb.Append("TODO: 2-3 casos concretos e ANCORADOS EM FONTE (não hipotéticos) de como a tarefa dá`n")
    [void]$sb.Append("errado sem esta disciplina — o sintoma, a causa-raiz, o antídoto. É o que torna a`n")
    [void]$sb.Append("skill preparada pro caso real, não só pro caminho feliz.`n`n")
    [void]$sb.Append("## Regras críticas (faça / não faça)`n")
    [void]$sb.Append("TODO: tabela 'Faça | Não faça' com PARES CONCRETOS (não princípios soltos) — cada`n")
    [void]$sb.Append("linha deve ser específica o bastante pra alguém aplicar sem interpretar.`n`n")
    [void]$sb.Append("## Gotchas`n")
    [void]$sb.Append("TODO: a seção mais valiosa. Edge case real, comportamento enganoso ou regra`n")
    [void]$sb.Append("não-óbvia só aprendida no uso (ex.: 'tabela X é append-only, use a linha de maior`n")
    [void]$sb.Append("versao, não created_at'). Cresce por iteração — comece com 1 gotcha real, não vazio.`n`n")
    [void]$sb.Append("## Referências`n")
    [void]$sb.Append("TODO: título + URL de cada fonte usada nos Casos reais/Gotchas/Regras críticas —`n")
    [void]$sb.Append("sem fonte citável, a afirmação não entra (ver docs-first.md).`n`n")
    [void]$sb.Append("## Se crescer`n")
    [void]$sb.Append("Alvo: ~100 linhas neste SKILL.md. Passou disso? Mova detalhe para 'references/<tema>.md'`n")
    [void]$sb.Append("e templates que o Claude deva copiar para 'assets/' — mantenha este arquivo como índice`n")
    [void]$sb.Append("enxuto que aponta pra lá (progressive disclosure), não um documento monolítico.`n")
    return $sb.ToString()
}

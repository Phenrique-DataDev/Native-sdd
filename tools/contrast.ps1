<#
.SYNOPSIS
    Razão de contraste WCAG 2.x entre duas cores CSS, com o veredito AA/AAA. Funções PURAS (só
    números e texto, sem disco), para o `designer` e o `visual-check` MEDIREM em vez de estimar.

.DESCRIPTION
    O `designer` manda "meça, não estime", e até 2026-10-17 não havia com o que medir: no redesign
    de teste do youtube-downloader, a combinação nova do seletor (borda #a1a1a1 sobre #1f1f1f) foi
    dada como ok porque os TOKENS tinham sido medidos, não a combinação.

    Cores aceitas: #rgb, #rrggbb, #rrggbbaa, rgb()/rgba() nas sintaxes com vírgula e com espaço
    (`rgb(255 255 255 / 14%)`). Cor de frente com alfa é composta sobre o fundo antes de medir, que
    é o que o navegador pinta. O FUNDO precisa ser opaco: um fundo translúcido depende do que está
    atrás dele, e esse é o caso em que a função lança em vez de chutar.

    Limiares (WCAG 2.2, 1.4.3 e 1.4.11): texto normal 4.5 (AA) e 7 (AAA); texto grande 3 (AA) e
    4.5 (AAA); componente de interface e objeto gráfico 3. A comparação usa a razão SEM arredondar:
    4.499 não passa no 4.5, mesmo que apareça como 4.50.

    Uso: `pwsh tools/contrast.ps1 -Foreground '#8a8a8a' -Background '#000'`
         `. "$toolsRoot/contrast.ps1"; Test-WcagContrast -Foreground '#fff' -Background '#1f1f1f'`
#>

[CmdletBinding()]
param(
    [string]$Foreground,
    [string]$Background
)

Set-StrictMode -Version Latest

function ConvertFrom-CssColor {
    <#
    .SYNOPSIS  Cor CSS -> objeto R,G,B (0-255) e A (0-1). Lança em formato não reconhecido.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Color)

    $c = $Color.Trim().ToLowerInvariant()
    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    if ($c -match '^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$') {
        $h = $Matches[1]
        if ($h.Length -eq 3) { $h = -join ($h.ToCharArray() | ForEach-Object { "$_$_" }) }
        $a = 1.0
        if ($h.Length -eq 8) { $a = [Convert]::ToInt32($h.Substring(6, 2), 16) / 255.0 }
        return [pscustomobject]@{
            R = [Convert]::ToInt32($h.Substring(0, 2), 16)
            G = [Convert]::ToInt32($h.Substring(2, 2), 16)
            B = [Convert]::ToInt32($h.Substring(4, 2), 16)
            A = $a
        }
    }

    # rgb(1, 2, 3) · rgba(1, 2, 3, 0.5) · rgb(1 2 3) · rgb(1 2 3 / 50%) · rgb(1 2 3 / 0.5)
    if ($c -match '^rgba?\(\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*(?:[,/]\s*([\d.]+)(%?)\s*)?\)$') {
        $a = 1.0
        if ($Matches[4]) {
            $a = [double]::Parse($Matches[4], $inv)
            if ($Matches[5] -eq '%') { $a = $a / 100.0 }
        }
        $rgb = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
        if (@($rgb | Where-Object { $_ -gt 255 }).Count -gt 0 -or $a -gt 1) {
            throw "cor fora da faixa: '$Color'"
        }
        return [pscustomobject]@{ R = $rgb[0]; G = $rgb[1]; B = $rgb[2]; A = $a }
    }

    throw "cor não reconhecida: '$Color' (use #rgb, #rrggbb, #rrggbbaa ou rgb()/rgba())"
}

function Get-RelativeLuminance {
    <# .SYNOPSIS  Luminância relativa WCAG de uma cor opaca (objeto de ConvertFrom-CssColor). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rgb)

    $canal = foreach ($v in @($Rgb.R, $Rgb.G, $Rgb.B)) {
        $s = $v / 255.0
        if ($s -le 0.04045) { $s / 12.92 } else { [Math]::Pow(($s + 0.055) / 1.055, 2.4) }
    }
    return 0.2126 * $canal[0] + 0.7152 * $canal[1] + 0.0722 * $canal[2]
}

function Get-ContrastRatio {
    <#
    .SYNOPSIS  Razão de contraste (1 a 21), sem arredondar. Frente com alfa é composta sobre o fundo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Foreground,
        [Parameter(Mandatory)][string]$Background
    )

    $bg = ConvertFrom-CssColor $Background
    if ($bg.A -lt 1) {
        throw "fundo translúcido ('$Background'): o contraste depende do que está atrás dele — meça contra a cor composta"
    }
    $fg = ConvertFrom-CssColor $Foreground
    if ($fg.A -lt 1) {
        $fg = [pscustomobject]@{
            R = [Math]::Round($fg.R * $fg.A + $bg.R * (1 - $fg.A))
            G = [Math]::Round($fg.G * $fg.A + $bg.G * (1 - $fg.A))
            B = [Math]::Round($fg.B * $fg.A + $bg.B * (1 - $fg.A))
            A = 1.0
        }
    }

    $l1 = Get-RelativeLuminance $fg
    $l2 = Get-RelativeLuminance $bg
    $claro = [Math]::Max($l1, $l2)
    $escuro = [Math]::Min($l1, $l2)
    return ($claro + 0.05) / ($escuro + 0.05)
}

function Test-WcagContrast {
    <#
    .SYNOPSIS  Razão + veredito por categoria. `Ratio` sai arredondado a 2 casas só para exibição;
               os vereditos usam o valor exato.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Foreground,
        [Parameter(Mandatory)][string]$Background
    )

    $r = Get-ContrastRatio -Foreground $Foreground -Background $Background
    [pscustomobject]@{
        Foreground = $Foreground
        Background = $Background
        Ratio      = [Math]::Round($r, 2)
        TextoAA    = $r -ge 4.5
        TextoAAA   = $r -ge 7
        GrandeAA   = $r -ge 3
        GrandeAAA  = $r -ge 4.5
        NaoTextoAA = $r -ge 3
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Foreground -or -not $Background) {
        Write-Output "uso: pwsh tools/contrast.ps1 -Foreground '<cor>' -Background '<cor>'"
        exit 2
    }
    $t = Test-WcagContrast -Foreground $Foreground -Background $Background
    $ok = { param($b) if ($b) { 'ok' } else { 'FALHA' } }
    Write-Output ("{0} sobre {1}: {2}:1 · texto AA {3} · AAA {4} · texto grande AA {5} · não-texto (borda, ícone) {6}" -f `
            $t.Foreground, $t.Background, $t.Ratio.ToString([System.Globalization.CultureInfo]::InvariantCulture),
            (& $ok $t.TextoAA), (& $ok $t.TextoAAA), (& $ok $t.GrandeAA), (& $ok $t.NaoTextoAA))
}

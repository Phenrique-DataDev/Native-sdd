# Pester 5 — testes das funções puras do instalador.
# Rodar:  Invoke-Pester onboarding/tests

BeforeAll {
    . (Join-Path (Join-Path $PSScriptRoot '..') 'windows\lib.ps1')
}

Describe 'Format-Duration' {
    It 'formata segundos abaixo de 1 minuto' {
        Format-Duration ([TimeSpan]::FromSeconds(12.34)) | Should -Be '12.3s'
    }
    It 'formata minutos e segundos a partir de 1 minuto' {
        Format-Duration ([TimeSpan]::FromSeconds(142)) | Should -Be '2m22s'
    }
    It 'zero-pad nos segundos' {
        Format-Duration ([TimeSpan]::FromSeconds(65)) | Should -Be '1m05s'
    }
}

Describe 'ConvertTo-NativeHookCommand (J4: dispatch -> pwsh nativo)' {
    It 'reescreve a dispatch-line para pwsh -File nativo (sem sh)' {
        $disp = 'sh -c ''if command -v pwsh >/dev/null 2>&1; then exec pwsh -NoProfile -File "$1"; else exec bash "$2"; fi'' _ "C:\Users\x/.claude/hooks/main-push-guard.ps1" "C:\Users\x/.claude/hooks/main-push-guard.sh"'
        ConvertTo-NativeHookCommand $disp | Should -Be 'pwsh -NoProfile -File "C:\Users\x/.claude/hooks/main-push-guard.ps1"'
    }
    It 'preserva ${CLAUDE_PROJECT_DIR} no caminho' {
        $disp = 'sh -c ''if command -v pwsh >/dev/null 2>&1; then exec pwsh -NoProfile -File "$1"; else exec bash "$2"; fi'' _ "${CLAUDE_PROJECT_DIR}/.claude/hooks/curation-nudge.ps1" "${CLAUDE_PROJECT_DIR}/.claude/hooks/curation-nudge.sh"'
        ConvertTo-NativeHookCommand $disp | Should -Be 'pwsh -NoProfile -File "${CLAUDE_PROJECT_DIR}/.claude/hooks/curation-nudge.ps1"'
    }
    It 'não toca um command que já é pwsh nativo' {
        $native = 'pwsh -NoProfile -File "{{HOME}}/.claude/statusline.ps1"'
        ConvertTo-NativeHookCommand $native | Should -Be $native
    }
    It 'string vazia/nula passa intacta' {
        ConvertTo-NativeHookCommand '' | Should -Be ''
    }
}

Describe 'ConvertTo-NativeHooks (objeto settings)' {
    It 'reescreve todos os commands de hook e ignora settings sem hooks' {
        $json = @'
{ "permissions": { "defaultMode": "auto" },
  "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
    { "type": "command", "command": "sh -c 'X' _ \"/h/a.ps1\" \"/h/a.sh\"" },
    { "type": "command", "command": "sh -c 'X' _ \"/h/b.ps1\" \"/h/b.sh\"" }
  ] } ] } }
'@
        $obj = $json | ConvertFrom-Json
        $out = ConvertTo-NativeHooks $obj
        $cmds = $out.hooks.PreToolUse[0].hooks.command
        $cmds[0] | Should -Be 'pwsh -NoProfile -File "/h/a.ps1"'
        $cmds[1] | Should -Be 'pwsh -NoProfile -File "/h/b.ps1"'
        # settings sem hooks -> intacto
        $noHooks = [pscustomobject]@{ permissions = [pscustomobject]@{ defaultMode = 'auto' } }
        (ConvertTo-NativeHooks $noHooks).permissions.defaultMode | Should -Be 'auto'
    }
}

Describe 'Get-BaselineMap (descoberta dinâmica)' {
    BeforeAll {
        $script:src = Join-Path $TestDrive 'src'
        $script:dst = Join-Path $TestDrive 'dst'
        New-Item -ItemType Directory -Path (Join-Path $src 'hooks') -Force | Out-Null
        Set-Content -Path (Join-Path $src 'CLAUDE.md')        -Value 'a'
        Set-Content -Path (Join-Path $src 'README.md')        -Value 'ignore-me'
        Set-Content -Path (Join-Path $src 'hooks\onstop.ps1') -Value 'b'
    }

    It 'mapeia arquivos do baseline preservando a estrutura' {
        $map = Get-BaselineMap -SourceRoot $src -DestRoot $dst
        $map.Count | Should -Be 2
    }

    It 'exclui README.md do espelho' {
        $map = Get-BaselineMap -SourceRoot $src -DestRoot $dst
        ($map.Rel) | Should -Not -Contain 'README.md'
    }

    It 'aponta o destino correto (espelho src→dst)' {
        $map = Get-BaselineMap -SourceRoot $src -DestRoot $dst
        $claude = $map | Where-Object { $_.Rel -eq 'CLAUDE.md' }
        $claude.Dst | Should -Be (Join-Path $dst 'CLAUDE.md')
        ($map.Rel) | Should -Contain 'hooks\onstop.ps1'
    }

    It 'retorna vazio quando a origem não existe' {
        @(Get-BaselineMap -SourceRoot (Join-Path $TestDrive 'nope') -DestRoot $dst).Count | Should -Be 0
    }
}

Describe 'Get-BaselineMap sobre o scaffold real (contrato A5)' {
    BeforeAll {
        $script:scaffold = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '..') 'templates\project-scaffold'
        $script:proj     = Join-Path $TestDrive 'proj'
    }

    It 'mapeia CLAUDE.md para a RAIZ do projeto (não dentro de .claude)' {
        $map = Get-BaselineMap -SourceRoot $scaffold -DestRoot $proj
        $claude = $map | Where-Object { $_.Rel -eq 'CLAUDE.md' }
        $claude | Should -Not -BeNullOrEmpty
        $claude.Dst | Should -Be (Join-Path $proj 'CLAUDE.md')
    }

    It 'exclui o README.md do scaffold (descreve o template, não o projeto)' {
        $map = Get-BaselineMap -SourceRoot $scaffold -DestRoot $proj
        ($map.Rel) | Should -Not -Contain 'README.md'
    }

    It 'inclui as rules dentro de .claude/' {
        $map = Get-BaselineMap -SourceRoot $scaffold -DestRoot $proj
        ($map.Rel) | Should -Contain '.claude\rules\workflow-sdd.md'
    }

    It 'propaga docs/_ABOUT.md ao projeto (B10 — destino docs/)' {
        $map = Get-BaselineMap -SourceRoot $scaffold -DestRoot $proj
        ($map.Rel) | Should -Contain 'docs\_ABOUT.md'
    }
}

Describe 'Backup-File' {
    It 'cria .bak e retorna o caminho quando o arquivo existe' {
        $f = Join-Path $TestDrive 'x.txt'
        Set-Content -Path $f -Value 'conteudo'
        $bak = Backup-File -Path $f
        $bak | Should -Not -BeNullOrEmpty
        Test-Path $bak | Should -BeTrue
        (Get-Content $bak -Raw).Trim() | Should -Be 'conteudo'
    }

    It 'retorna $null quando o arquivo não existe' {
        Backup-File -Path (Join-Path $TestDrive 'inexistente.txt') | Should -BeNullOrEmpty
    }
}

Describe 'Test-FilesDiffer' {
    It 'falso para arquivos idênticos' {
        $a = Join-Path $TestDrive 'a1'; $b = Join-Path $TestDrive 'b1'
        Set-Content $a -Value 'igual'; Set-Content $b -Value 'igual'
        Test-FilesDiffer -A $a -B $b | Should -BeFalse
    }
    It 'verdadeiro para conteúdos diferentes' {
        $a = Join-Path $TestDrive 'a2'; $b = Join-Path $TestDrive 'b2'
        Set-Content $a -Value 'um'; Set-Content $b -Value 'dois'
        Test-FilesDiffer -A $a -B $b | Should -BeTrue
    }
    It 'verdadeiro quando o destino não existe' {
        $a = Join-Path $TestDrive 'a3'; Set-Content $a -Value 'x'
        Test-FilesDiffer -A $a -B (Join-Path $TestDrive 'nope3') | Should -BeTrue
    }
}

Describe 'Install-BaselineItem' {
    BeforeEach {
        $script:s = New-InstallSummary
        $script:srcf = Join-Path $TestDrive 'item-src.md'
        $script:dstf = Join-Path $TestDrive 'out\item-dst.md'
        Set-Content -Path $srcf -Value 'novo'
        $script:item = [pscustomobject]@{ Src = $srcf; Dst = $dstf; Rel = 'item-dst.md' }
    }

    It '-Check não escreve o destino (AT-005)' {
        Install-BaselineItem -Item $item -Summary $s -Check
        Test-Path $dstf | Should -BeFalse
        $s.Installed | Should -Be 0
    }

    It '-DryRun não escreve o destino' {
        Install-BaselineItem -Item $item -Summary $s -DryRun
        Test-Path $dstf | Should -BeFalse
    }

    It 'instala de fato quando não existe' {
        Install-BaselineItem -Item $item -Summary $s
        (Get-Content $dstf -Raw).Trim() | Should -Be 'novo'
        $s.Installed | Should -Be 1
    }

    It 'é idempotente: 2ª execução pula (AT-002)' {
        Install-BaselineItem -Item $item -Summary $s              # instala
        $s2 = New-InstallSummary
        Install-BaselineItem -Item $item -Summary $s2             # de novo
        $s2.Installed | Should -Be 0
        $s2.Skipped   | Should -Be 1
    }

    It 'faz backup quando o destino existe e difere (AT-004)' {
        New-Item -ItemType Directory -Path (Split-Path $dstf) -Force | Out-Null
        Set-Content -Path $dstf -Value 'antigo'
        Install-BaselineItem -Item $item -Summary $s
        $s.Backup | Should -Be 1
        @(Get-ChildItem (Split-Path $dstf) -Filter 'item-dst.md.bak-*').Count | Should -Be 1
        (Get-Content $dstf -Raw).Trim() | Should -Be 'novo'
    }
}

Describe 'Merge-JsonObject' {
    It 'adiciona chave nova sem remover as existentes' {
        $base = '{"a":1,"b":2}' | ConvertFrom-Json
        $over = '{"c":3}' | ConvertFrom-Json
        $m = Merge-JsonObject $base $over
        $m.a | Should -Be 1; $m.b | Should -Be 2; $m.c | Should -Be 3
    }
    It 'overlay vence em conflito de folha' {
        $base = '{"x":"antigo"}' | ConvertFrom-Json
        $over = '{"x":"novo"}'   | ConvertFrom-Json
        (Merge-JsonObject $base $over).x | Should -Be 'novo'
    }
    It 'mescla objetos aninhados recursivamente' {
        $base = '{"env":{"A":"1"}}' | ConvertFrom-Json
        $over = '{"env":{"B":"2"}}' | ConvertFrom-Json
        $m = Merge-JsonObject $base $over
        $m.env.A | Should -Be '1'; $m.env.B | Should -Be '2'
    }
}

Describe 'Expand-BaselinePlaceholder' {
    It 'substitui {{HOME}} pelo perfil com backslash escapado (JSON válido)' {
        $out = Expand-BaselinePlaceholder '{"c":"{{HOME}}\\.claude\\x.ps1"}'
        # Deve ser JSON parseável e apontar para o caminho real.
        $obj = $out | ConvertFrom-Json
        $obj.c | Should -Be (Join-Path $env:USERPROFILE '.claude\x.ps1')
    }
    It 'não altera texto sem placeholder' {
        Expand-BaselinePlaceholder '{"a":1}' | Should -Be '{"a":1}'
    }
}

Describe 'Get-ProfileShimBlock (shim do profile)' {
    It 'inclui os marcadores e a função/alias' {
        $b = Get-ProfileShimBlock -RepoRoot 'C:\fw'
        $b | Should -Match '# >>> sdd-workflow >>>'
        $b | Should -Match '# <<< sdd-workflow <<<'
        $b | Should -Match 'function New-SddProject'
        $b | Should -Match 'Set-Alias -Name nsp -Value New-SddProject'
    }
    It 'inclui o runner sddcheck (Invoke-SddCheck → tools\check.ps1)' {
        $b = Get-ProfileShimBlock -RepoRoot 'C:\fw'
        $b | Should -Match 'function Invoke-SddCheck'
        $b | Should -Match 'tools\\check\.ps1'
        $b | Should -Match 'Set-Alias -Name sddcheck -Value Invoke-SddCheck'
    }
    It 'embute o RepoRoot em SDD_WORKFLOW_HOME' {
        Get-ProfileShimBlock -RepoRoot 'C:\meu fw' | Should -Match "SDD_WORKFLOW_HOME = 'C:\\meu fw'"
    }
    It "escapa aspas simples no caminho ('' literal)" {
        Get-ProfileShimBlock -RepoRoot "C:\a'b" | Should -Match "C:\\a''b"
    }
}

Describe 'Install-ProfileShim (idempotente)' {
    BeforeEach {
        $script:s = New-InstallSummary
        $script:profile = Join-Path $TestDrive 'profile\profile.ps1'
    }

    It '-Check não cria o profile (AT)' {
        Install-ProfileShim -ProfilePath $profile -RepoRoot 'C:\fw' -Summary $s -Check
        Test-Path $profile | Should -BeFalse
        $s.Installed | Should -Be 0
    }

    It '-DryRun não escreve' {
        Install-ProfileShim -ProfilePath $profile -RepoRoot 'C:\fw' -Summary $s -DryRun
        Test-Path $profile | Should -BeFalse
    }

    It 'cria o profile e injeta o bloco quando ausente' {
        Install-ProfileShim -ProfilePath $profile -RepoRoot 'C:\fw' -Summary $s
        Test-Path $profile | Should -BeTrue
        (Get-Content $profile -Raw) | Should -Match 'function New-SddProject'
        $s.Installed | Should -Be 1
    }

    It 'preserva o conteúdo existente do usuário ao anexar' {
        New-Item -ItemType Directory -Path (Split-Path $profile) -Force | Out-Null
        Set-Content -Path $profile -Value 'Write-Host "meu profile"'
        Install-ProfileShim -ProfilePath $profile -RepoRoot 'C:\fw' -Summary $s
        $c = Get-Content $profile -Raw
        $c | Should -Match 'meu profile'
        $c | Should -Match 'New-SddProject'
    }

    It 'é idempotente: 2ª execução com mesmo RepoRoot pula' {
        Install-ProfileShim -ProfilePath $profile -RepoRoot 'C:\fw' -Summary $s
        $s2 = New-InstallSummary
        Install-ProfileShim -ProfilePath $profile -RepoRoot 'C:\fw' -Summary $s2
        $s2.Skipped | Should -Be 1
        $s2.Installed | Should -Be 0
    }

    It 'substitui o bloco (sem duplicar) quando o RepoRoot muda' {
        Install-ProfileShim -ProfilePath $profile -RepoRoot 'C:\fw-antigo' -Summary $s
        $s2 = New-InstallSummary
        Install-ProfileShim -ProfilePath $profile -RepoRoot 'C:\fw-novo' -Summary $s2
        $c = Get-Content $profile -Raw
        ([regex]::Matches($c, '# >>> sdd-workflow >>>')).Count | Should -Be 1
        $c | Should -Match 'fw-novo'
        $c | Should -Not -Match 'fw-antigo'
        $s2.Backup | Should -Be 1
    }
}

Describe 'Install-ManagedPolicy (opt-in, exige admin) — C3' {
    BeforeEach {
        $script:s    = New-InstallSummary
        $script:src  = Join-Path $TestDrive 'mp-src.json'
        $script:dir  = Join-Path $TestDrive 'ClaudeCode'
        $script:dst  = Join-Path $dir 'managed-settings.json'
        '{"permissions":{"deny":["Bash(git push --force *)"]}}' | Set-Content -Path $src
    }

    It '-Check não escreve e não pergunta' {
        Install-ManagedPolicy -SourcePath $src -Summary $s -DestDir $dir -Check
        Test-Path $dst | Should -BeFalse
        $s.Installed | Should -Be 0
    }

    It '-DryRun não escreve' {
        Install-ManagedPolicy -SourcePath $src -Summary $s -DestDir $dir -DryRun
        Test-Path $dst | Should -BeFalse
    }

    It 'Decision=No não aplica (opt-in recusado)' {
        Install-ManagedPolicy -SourcePath $src -Summary $s -DestDir $dir -Decision No
        Test-Path $dst | Should -BeFalse
        $s.Skipped | Should -Be 1
    }

    It 'Decision=Yes + IsAdmin aplica de fato' {
        Install-ManagedPolicy -SourcePath $src -Summary $s -DestDir $dir -Decision Yes -IsAdmin
        Test-Path $dst | Should -BeTrue
        (Get-Content $dst -Raw) | Should -Match 'git push --force'
        $s.Installed | Should -Be 1
    }

    It 'idempotente: 2ª execução com destino idêntico pula (sem perguntar)' {
        Install-ManagedPolicy -SourcePath $src -Summary $s -DestDir $dir -Decision Yes -IsAdmin
        $s2 = New-InstallSummary
        Install-ManagedPolicy -SourcePath $src -Summary $s2 -DestDir $dir -Decision Ask -IsAdmin
        $s2.Skipped   | Should -Be 1
        $s2.Installed | Should -Be 0
    }

    It 'faz backup quando o destino existe e difere' {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path $dst -Value '{"permissions":{"deny":["antigo"]}}'
        Install-ManagedPolicy -SourcePath $src -Summary $s -DestDir $dir -Decision Yes -IsAdmin
        $s.Backup | Should -Be 1
        @(Get-ChildItem $dir -Filter 'managed-settings.json.bak-*').Count | Should -Be 1
    }

    It 'template ausente -> WARN, não falha' {
        Install-ManagedPolicy -SourcePath (Join-Path $TestDrive 'nope.json') -Summary $s -DestDir $dir -Decision Yes -IsAdmin
        $s.Warn   | Should -Be 1
        $s.Failed | Should -Be 0
    }
}

Describe 'Copy-ManagedPolicyFile (cópia pura)' {
    BeforeEach {
        $script:s   = New-InstallSummary
        $script:src = Join-Path $TestDrive 'cp-src.json'
        $script:dst = Join-Path $TestDrive 'sys\managed-settings.json'
        Set-Content -Path $src -Value '{"ok":true}'
    }
    It 'cria o diretório de destino e copia' {
        Copy-ManagedPolicyFile -SourcePath $src -DestPath $dst -Summary $s | Should -BeTrue
        (Get-Content $dst -Raw) | Should -Match '"ok":true'
    }
}

Describe 'Get-ScaffoldVersionContent (.scaffold-version)' {
    It 'inclui commit e root informados' {
        $c = Get-ScaffoldVersionContent -RepoRoot 'C:\fw' -Commit 'abc1234' -Stamp '2026-06-01T00:00:00'
        $c | Should -Match 'framework_commit: abc1234'
        $c | Should -Match 'framework_root: C:/fw'
        $c | Should -Match 'generated_at: 2026-06-01T00:00:00'
    }
    It 'usa unknown como commit padrão' {
        Get-ScaffoldVersionContent -RepoRoot 'C:\fw' | Should -Match 'framework_commit: unknown'
    }
}

Describe 'Read-ScaffoldVersion (A7 — leitura do marcador)' {
    BeforeEach {
        $script:proj = Join-Path $TestDrive ("proj-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $proj '.claude') -Force | Out-Null
    }

    It 'lê commit/generated_at/root de um marcador válido' {
        $c = Get-ScaffoldVersionContent -RepoRoot 'C:\fw' -Commit 'abc1234' -Stamp '2026-06-01T00:00:00'
        Set-Content -LiteralPath (Join-Path $proj '.claude\.scaffold-version') -Value $c -NoNewline
        $v = Read-ScaffoldVersion -Path $proj
        $v.FrameworkCommit | Should -Be 'abc1234'
        $v.GeneratedAt     | Should -Be '2026-06-01T00:00:00'
        $v.FrameworkRoot   | Should -Be 'C:/fw'
    }

    It 'marcador ausente -> $null' {
        Read-ScaffoldVersion -Path $proj | Should -BeNullOrEmpty
    }

    It 'marcador sem framework_commit -> $null (não reconhecível)' {
        Set-Content -LiteralPath (Join-Path $proj '.claude\.scaffold-version') -Value "generated_at: x`r`nframework_root: y" -NoNewline
        Read-ScaffoldVersion -Path $proj | Should -BeNullOrEmpty
    }
}

Describe 'Get-ScaffoldUpdatePlan (A7 — diff dirigido)' {
    BeforeEach {
        $script:src = Join-Path $TestDrive ("src-" + [guid]::NewGuid().ToString('N'))
        $script:dst = Join-Path $TestDrive ("dst-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'a.md') -Value 'conteudo A' -NoNewline
        Set-Content -LiteralPath (Join-Path $src 'b.md') -Value 'conteudo B' -NoNewline
    }

    It 'arquivo ausente no destino -> status new' {
        $plan = Get-ScaffoldUpdatePlan -SourceRoot $src -DestRoot $dst
        ($plan | Where-Object Rel -eq 'a.md').Status | Should -Be 'new'
        ($plan | Where-Object Rel -eq 'b.md').Status | Should -Be 'new'
    }

    It 'arquivo idêntico fica fora do plano; diferente -> changed' {
        Set-Content -LiteralPath (Join-Path $dst 'a.md') -Value 'conteudo A' -NoNewline   # idêntico
        Set-Content -LiteralPath (Join-Path $dst 'b.md') -Value 'OUTRO' -NoNewline        # difere
        $plan = Get-ScaffoldUpdatePlan -SourceRoot $src -DestRoot $dst
        ($plan | Where-Object Rel -eq 'a.md') | Should -BeNullOrEmpty
        ($plan | Where-Object Rel -eq 'b.md').Status | Should -Be 'changed'
    }

    It 'tudo idêntico -> plano vazio' {
        Set-Content -LiteralPath (Join-Path $dst 'a.md') -Value 'conteudo A' -NoNewline
        Set-Content -LiteralPath (Join-Path $dst 'b.md') -Value 'conteudo B' -NoNewline
        @(Get-ScaffoldUpdatePlan -SourceRoot $src -DestRoot $dst).Count | Should -Be 0
    }

    It 'determinístico: ordenado por Rel' {
        $plan = Get-ScaffoldUpdatePlan -SourceRoot $src -DestRoot $dst
        $rels = @($plan | ForEach-Object Rel)
        $rels | Should -Be (@($rels) | Sort-Object)
    }
}

Describe 'Install-JsonBaselineItem (merge de settings)' {
    BeforeEach {
        $script:s = New-InstallSummary
        $script:src = Join-Path $TestDrive 'src.json'
        $script:dst = Join-Path $TestDrive 'dst.json'
        '{"statusLine":{"type":"command"}}' | Set-Content -Path $src
        '{"model":"opus","permissions":{"allow":["a"]}}' | Set-Content -Path $dst
        $script:item = [pscustomobject]@{ Src = $src; Dst = $dst; Rel = 'settings.json' }
    }
    It 'mescla preservando a config existente (não sobrescreve)' {
        Install-BaselineItem -Item $item -Summary $s
        $r = Get-Content $dst -Raw | ConvertFrom-Json
        $r.model | Should -Be 'opus'
        $r.statusLine.type | Should -Be 'command'
        $s.Backup | Should -Be 1
    }
    It 'é idempotente: 2ª execução pula (json idêntico)' {
        Install-BaselineItem -Item $item -Summary $s
        $s2 = New-InstallSummary
        Install-BaselineItem -Item $item -Summary $s2
        $s2.Skipped | Should -Be 1
        $s2.Installed | Should -Be 0
    }
    It 'grava o JSON sem BOM (compatível com parser estrito)' {
        Install-BaselineItem -Item $item -Summary $s
        $bytes = [System.IO.File]::ReadAllBytes($dst)
        # Não pode começar com o BOM UTF-8 (EF BB BF).
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }
    It 'cria o diretório-pai inexistente ao gerar o JSON (projeto novo: .claude/settings.json é o 1º item)' {
        # Regressão: num projeto novo o .claude/ ainda não existe quando o settings.json é processado.
        $missingDst = Join-Path $TestDrive 'novo\.claude\settings.json'
        $item2 = [pscustomobject]@{ Src = $src; Dst = $missingDst; Rel = '.claude\settings.json' }
        Install-BaselineItem -Item $item2 -Summary $s
        Test-Path -LiteralPath $missingDst | Should -BeTrue
        $s.Installed | Should -Be 1
        $s.Failed | Should -Be 0
    }
}

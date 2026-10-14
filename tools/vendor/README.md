# `tools/vendor/` — dependências de terceiros, vendorizadas

Arquivos baixados uma vez e versionados aqui de propósito: o que este repositório gera precisa
funcionar **offline**. Nada aqui se edita à mão — para atualizar, baixe de novo do upstream e
atualize a tabela.

| Arquivo | Versão | Upstream | Licença | SHA-256 | Baixado em |
|---|---|---|---|---|---|
| `vis-network.min.js` | 9.1.13 | `https://unpkg.com/vis-network@9.1.13/standalone/umd/vis-network.min.js` | Apache-2.0 **ou** MIT (dual, à escolha) | `beb41e4d2f0a4119fb3b96112c57fab570002a8cdb5c9eb5993202d28d4ae736` | 2026-08-31 |

## Por que o vis-network está aqui

`ConvertTo-GraphHtml` (`tools/graph-export.ps1`) gera o `graph.html` — a view "ver o cérebro" do
grafo do projeto. Até 2026-08-31 essa página carregava a lib de `unpkg.com`, o que contradizia o
próprio `.SYNOPSIS` ("self-contained") e quebrava exatamente no cenário offline em que a página
precisa abrir. Agora o bundle é **embutido inline** na página gerada.

Se o arquivo sumir, o export não falha: cai de volta na tag do CDN e emite `Write-Warning`.
O cabeçalho de licença do upstream está preservado no topo do `.min.js` — não o remova.

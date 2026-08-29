"""
Testes das funções PURAS de `server.py` (sem Ollama, sem rede) — provam os Acceptance Tests
AT-001/AT-002 do DEFINE_RAG_HIBRIDO.md: a reindexação só reprocessa o que mudou. Também cobre
a camada de storage sqlite-vec (upsert/delete) com um vetor fake, e a degradação (AT-005) via
mock do embed. AT-003/AT-004/AT-006 são provados por inspeção de código/instalador — ver
BUILD_REPORT_RAG_HIBRIDO.md.

Rodar: uv run pytest onboarding/semantic-kb/test_server.py -v
"""

import asyncio
from pathlib import Path

import httpx
import pytest

import server as srv
from server import (
    compute_file_manifest,
    corpus_of,
    diff_manifest,
    _connect,
    _delete_entry,
    _load_manifest,
    _upsert_entry,
)


def _write(root: Path, relpath: str, content: str) -> None:
    p = root / relpath
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")


class TestComputeFileManifest:
    def test_raiz_ausente_nao_lanca_e_devolve_vazio(self, tmp_path):
        # projeto sem .claude/kb/, docs/ nem .claude/sdd/archive/ -> manifest vazio, sem erro
        assert compute_file_manifest(str(tmp_path)) == {}

    def test_ignora_extensao_nao_indexavel(self, tmp_path):
        _write(tmp_path, "docs/nota.md", "conteudo")
        _write(tmp_path, "docs/imagem.png", "binario-fake")
        manifest = compute_file_manifest(str(tmp_path))
        assert list(manifest.keys()) == ["docs/nota.md"]

    def test_indexa_as_3_raizes_do_corpus(self, tmp_path):
        _write(tmp_path, ".claude/kb/tools/sql/patterns/x.md", "kb")
        _write(tmp_path, "docs/uso.md", "docs")
        _write(tmp_path, ".claude/sdd/archive/feature/SHIPPED_2026-01-01.md", "archive")
        manifest = compute_file_manifest(str(tmp_path))
        assert set(manifest.keys()) == {
            ".claude/kb/tools/sql/patterns/x.md",
            "docs/uso.md",
            ".claude/sdd/archive/feature/SHIPPED_2026-01-01.md",
        }

    def test_hash_e_deterministico(self, tmp_path):
        _write(tmp_path, "docs/a.md", "mesmo conteudo")
        m1 = compute_file_manifest(str(tmp_path))
        m2 = compute_file_manifest(str(tmp_path))
        assert m1 == m2


class TestDiffManifest:
    def test_AT001_arquivo_novo_vira_added_resto_unchanged(self):
        # AT-001 do DEFINE: reindexar com 1 arquivo novo -> só ele é `added`, os N existentes
        # ficam em `unchanged` (nao reprocessados).
        old = {"a.md": "h1", "b.md": "h2"}
        new = {"a.md": "h1", "b.md": "h2", "c.md": "h3"}
        diff = diff_manifest(old, new)
        assert diff["added"] == ["c.md"]
        assert diff["changed"] == []
        assert diff["removed"] == []
        assert diff["unchanged"] == ["a.md", "b.md"]

    def test_AT002_arquivo_alterado_vira_changed_nao_duplica(self):
        # AT-002 do DEFINE: conteúdo mudou (hash diferente) -> `changed`, nunca aparece
        # simultaneamente em `unchanged`/`added`.
        old = {"a.md": "h1", "b.md": "h2"}
        new = {"a.md": "h1-mudou", "b.md": "h2"}
        diff = diff_manifest(old, new)
        assert diff["changed"] == ["a.md"]
        assert diff["unchanged"] == ["b.md"]
        assert diff["added"] == []
        assert diff["removed"] == []

    def test_arquivo_removido(self):
        old = {"a.md": "h1", "b.md": "h2"}
        new = {"a.md": "h1"}
        diff = diff_manifest(old, new)
        assert diff["removed"] == ["b.md"]

    def test_nada_mudou_tudo_unchanged(self):
        m = {"a.md": "h1", "b.md": "h2"}
        diff = diff_manifest(m, dict(m))
        assert diff["added"] == diff["changed"] == diff["removed"] == []
        assert diff["unchanged"] == ["a.md", "b.md"]

    def test_manifests_vazios(self):
        assert diff_manifest({}, {}) == {
            "added": [], "changed": [], "removed": [], "unchanged": [],
        }


class TestCorpusOf:
    @pytest.mark.parametrize("path,expected", [
        (".claude/kb/tools/x.md", ".claude/kb"),
        ("docs/uso.md", "docs"),
        (".claude/sdd/archive/f/SHIPPED_1.md", ".claude/sdd/archive"),
        ("tools/adapt.ps1", "?"),
    ])
    def test_rotula_a_raiz_certa(self, path, expected):
        assert corpus_of(path) == expected


class TestStorageSqliteVec:
    """Cobre a camada de storage com um vetor FAKE (sem Ollama) — prova que upsert/delete e a
    query KNN funcionam de verdade contra o sqlite-vec instalado (sintaxe verificada: `k = ?`
    é obrigatório; upsert é DELETE+INSERT, `INSERT OR REPLACE` falha na tabela vec0)."""

    def test_upsert_e_busca_por_similaridade(self, tmp_path):
        db = _connect(str(tmp_path))
        _upsert_entry(db, "a.md", "hash-a", "conteudo a", [0.1, 0.2, 0.3, 0.4] + [0.0] * 764)
        _upsert_entry(db, "b.md", "hash-b", "conteudo b", [0.9, 0.9, 0.9, 0.9] + [0.0] * 764)
        db.commit()

        manifest = _load_manifest(db)
        assert manifest == {"a.md": "hash-a", "b.md": "hash-b"}

        from sqlite_vec import serialize_float32
        query = serialize_float32([0.1, 0.2, 0.3, 0.4] + [0.0] * 764)
        rows = db.execute(
            "SELECT f.path, v.distance FROM vec_entries v JOIN files f ON f.rowid = v.rowid "
            "WHERE v.embedding MATCH ? AND k = ? ORDER BY v.distance",
            [query, 2],
        ).fetchall()
        assert rows[0][0] == "a.md"  # mais próximo do vetor de a.md

    def test_upsert_de_arquivo_existente_atualiza_sem_duplicar(self, tmp_path):
        db = _connect(str(tmp_path))
        _upsert_entry(db, "a.md", "hash-1", "v1", [0.1] * 768)
        db.commit()
        _upsert_entry(db, "a.md", "hash-2", "v2", [0.2] * 768)
        db.commit()

        count = db.execute("SELECT count(*) FROM vec_entries").fetchone()[0]
        assert count == 1  # AT-002: não duplica, só atualiza
        manifest = _load_manifest(db)
        assert manifest == {"a.md": "hash-2"}

    def test_delete_remove_das_duas_tabelas(self, tmp_path):
        db = _connect(str(tmp_path))
        _upsert_entry(db, "a.md", "hash-1", "v1", [0.1] * 768)
        db.commit()
        _delete_entry(db, "a.md")
        db.commit()

        assert _load_manifest(db) == {}
        count = db.execute("SELECT count(*) FROM vec_entries").fetchone()[0]
        assert count == 0


class TestReindexFailFast:
    """SEMANTIC_KB_FAILFAST — reindex sem Ollama: fail-fast (achado 1), commit de deleção
    (achado 2, bug independente) e mensagem honesta (achado 3). Sem Ollama, mockando o probe/embed:
    provas negativas que REPROVAM sem o fix."""

    @staticmethod
    def _fake_probe(reason):
        async def probe():
            probe.calls += 1
            return reason
        probe.calls = 0
        return probe

    @staticmethod
    def _fake_embed(result):
        async def embed(text, client=None):
            embed.calls += 1
            embed.clients.append(client)  # V5 de HTTP_CLIENT_POR_REQUISICAO: quem foi reusado
            return result
        embed.calls = 0
        embed.clients = []
        return embed

    def test_achado1_ollama_offline_faz_1_requisicao_nao_N(self, tmp_path, monkeypatch):
        # V5 (1): host inalcançável -> probe UMA vez, ZERO tentativas de embed, retorno rápido.
        _write(tmp_path, "docs/a.md", "conteudo a")
        _write(tmp_path, "docs/b.md", "conteudo b")
        _write(tmp_path, "docs/c.md", "conteudo c")
        probe = self._fake_probe(srv.EMBED_OFFLINE)
        embed = self._fake_embed((None, srv.EMBED_OFFLINE))
        monkeypatch.setattr(srv, "_probe_ollama", probe)
        monkeypatch.setattr(srv, "_embed", embed)

        out = asyncio.run(srv._reindex(str(tmp_path)))

        assert probe.calls == 1          # o probe roda 1x
        assert embed.calls == 0          # e NÃO paga N tentativas de embed (o custo dos ~35s)
        assert "3 pulados" in out
        assert "Ollama nao esta no ar" in out  # mensagem honesta (achado 3), não a ambígua antiga

    def test_achado1_circuit_breaker_aborta_apos_N_falhas(self, tmp_path, monkeypatch):
        # Ollama no ar (probe passa) mas modelo não baixado (embed 404) -> aborta após N, não tenta todos.
        for i in range(10):
            _write(tmp_path, f"docs/f{i}.md", f"conteudo {i}")
        probe = self._fake_probe(None)   # Ollama responde ao /api/tags
        embed = self._fake_embed((None, srv.EMBED_NO_MODEL))
        monkeypatch.setattr(srv, "_probe_ollama", probe)
        monkeypatch.setattr(srv, "_embed", embed)

        out = asyncio.run(srv._reindex(str(tmp_path)))

        assert embed.calls == srv.CIRCUIT_BREAKER_THRESHOLD  # 3, não 10
        assert "10 pulados" in out
        assert "ollama pull" in out                          # causa distinta -> mensagem distinta
        assert "abortado" in out

    def test_achado2_deletion_persiste_apos_reabrir_o_banco(self, tmp_path, monkeypatch):
        # V5 (2): reindex cujo diff SÓ tem `removed` persiste a deleção após reabrir o banco.
        # É o teste que REPROVA sem o fix — antes o único commit vivia no loop de add/changed.
        db = _connect(str(tmp_path))
        _upsert_entry(db, "docs/velho.md", "hash-velho", "trecho", [0.1] * 768)
        db.commit()
        db.close()
        # arquivo não existe em disco -> diff = só removed; Ollama offline de propósito (remoção
        # não pode depender de embed).
        monkeypatch.setattr(srv, "_probe_ollama", self._fake_probe(srv.EMBED_OFFLINE))

        out = asyncio.run(srv._reindex(str(tmp_path)))
        assert "1 removidos" in out

        db2 = _connect(str(tmp_path))  # reabre: a deleção tem de ter sido COMMITADA
        assert _load_manifest(db2) == {}
        assert db2.execute("SELECT count(*) FROM vec_entries").fetchone()[0] == 0

    def test_sucesso_indexa_persiste_e_nao_reporta_pulados(self, tmp_path, monkeypatch):
        # Caminho feliz: probe passa, embed devolve vetor -> arquivo indexado e persistido, sem "pulados".
        _write(tmp_path, "docs/a.md", "conteudo a")
        monkeypatch.setattr(srv, "_probe_ollama", self._fake_probe(None))
        monkeypatch.setattr(srv, "_embed", self._fake_embed(([0.1] * 768, None)))

        out = asyncio.run(srv._reindex(str(tmp_path)))
        assert "1 adicionados" in out
        assert "pulados" not in out

        db = _connect(str(tmp_path))
        assert "docs/a.md" in _load_manifest(db)

    def test_diff_vazio_nem_chama_o_probe(self, tmp_path, monkeypatch):
        # Nada a embedar -> nem paga o probe de rede (só remoções/inalterados). Corpus vazio.
        probe = self._fake_probe(srv.EMBED_OFFLINE)
        monkeypatch.setattr(srv, "_probe_ollama", probe)

        out = asyncio.run(srv._reindex(str(tmp_path)))
        assert probe.calls == 0
        assert "pulados" not in out


class TestEmbedClientReuse:
    """HTTP_CLIENT_POR_REQUISICAO — o loop do `_reindex` criava um `httpx.AsyncClient` por
    arquivo. Medido em loopback (200 POSTs, sem TLS, então NÃO é handshake): 19,210 ms/req
    por-requisição x 2,768 ms/req reusado = ~16,4 ms/req de setup de transport/pool. Provas
    negativas: cada teste daqui REPROVA na versão que criava um client por chamada."""

    @staticmethod
    def _client_capturando():
        """Fake de `_embed` que registra a IDENTIDADE do client recebido em cada chamada."""
        async def embed(text, client=None):
            embed.clients.append(client)
            return [0.1] * 768, None
        embed.clients = []
        return embed

    @staticmethod
    async def _probe_ok():
        return None

    def test_reindex_usa_UM_client_para_todos_os_arquivos(self, tmp_path, monkeypatch):
        # A prova central: N arquivos -> N embeds, mas UMA só instância de client, e nunca None.
        # Sem o fix, `_embed` era chamado sem client (todos None) e cada um criava o seu.
        for i in range(5):
            _write(tmp_path, f"docs/f{i}.md", f"conteudo {i}")
        embed = self._client_capturando()
        monkeypatch.setattr(srv, "_probe_ollama", self._probe_ok)
        monkeypatch.setattr(srv, "_embed", embed)

        out = asyncio.run(srv._reindex(str(tmp_path)))

        assert len(embed.clients) == 5                    # os 5 arquivos foram embedados
        assert all(c is not None for c in embed.clients)  # nenhum caiu no caminho "cria o seu"
        assert len({id(c) for c in embed.clients}) == 1   # e foi SEMPRE o mesmo objeto
        assert "5 adicionados" in out
        assert "pulados" not in out

    def test_ollama_offline_nao_chega_a_criar_client(self, tmp_path, monkeypatch):
        # O client nasce DENTRO do else do fail-fast: probe reprovando, nem client se cria.
        _write(tmp_path, "docs/a.md", "conteudo a")
        embed = self._client_capturando()

        async def probe_offline():
            return srv.EMBED_OFFLINE
        monkeypatch.setattr(srv, "_probe_ollama", probe_offline)
        monkeypatch.setattr(srv, "_embed", embed)

        out = asyncio.run(srv._reindex(str(tmp_path)))
        assert embed.clients == []
        assert "1 pulados" in out

    def test_embed_NAO_fecha_o_client_que_recebeu(self, tmp_path):
        # A invariante que o reuso depende: `_embed` não tem posse do client emprestado. Se
        # fechasse (`async with client:`), o 2o arquivo do lote morreria com client fechado.
        def handler(request):
            return httpx.Response(200, json={"embedding": [0.5] * 768})

        async def cenario():
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                primeiro = await srv._embed("texto 1", client)
                assert client.is_closed is False   # sobreviveu à 1a chamada
                segundo = await srv._embed("texto 2", client)
                return primeiro, segundo, client.is_closed

        primeiro, segundo, fechado_no_fim = asyncio.run(cenario())
        assert primeiro == ([0.5] * 768, None)
        assert segundo == ([0.5] * 768, None)
        assert fechado_no_fim is False  # quem fecha é quem criou (o `async with` do chamador)

    def test_embed_client_sem_argumento_cria_e_FECHA_o_seu(self):
        # Caminho do `semantic_search` (chamada única): sem client emprestado, `_embed_client`
        # cria um e o fecha ao sair — senão vazaria um pool por busca.
        async def cenario():
            async with srv._embed_client() as c:
                assert isinstance(c, httpx.AsyncClient)
                assert c.is_closed is False
                return c

        criado = asyncio.run(cenario())
        assert criado.is_closed is True

    def test_embed_client_com_argumento_cede_o_MESMO_objeto(self):
        # Identidade, não equivalência: um client novo por chamada passaria em qualquer
        # asserção de tipo — só `is` reprova a versão sem reuso.
        async def cenario():
            emprestado = httpx.AsyncClient(transport=httpx.MockTransport(lambda r: httpx.Response(200)))
            async with srv._embed_client(emprestado) as c:
                mesmo = c is emprestado
            return mesmo, emprestado.is_closed

        mesmo, fechado = asyncio.run(cenario())
        assert mesmo is True
        assert fechado is False  # cedido != cedido-e-consumido

class TestEmbedTooLarge:
    """RAG_EMBED_FAILFAST — o 500 de TAMANHO tem modo de falha próprio. Medido nesta máquina
    (2026-08-17, `nomic-embed-text`): acima do context length o Ollama NÃO trunca, devolve
    `HTTP 500 {"error":"the input length exceeds the context length"}`. Antes do fix isso caía em
    EMBED_OTHER e o usuário lia "nao foi possivel contatar o Ollama" — para um Ollama que
    respondeu — e três arquivos grandes seguidos abortavam o lote inteiro pelo circuit breaker.
    Cada teste daqui REPROVA na versão sem o fix."""

    RESP_TOO_LARGE = {"error": "the input length exceeds the context length"}

    @staticmethod
    def _embed_por_tamanho(limite):
        """Fake de `_embed` que replica o Ollama real: rejeita acima de `limite` chars com o motivo
        de tamanho, embeda o resto. É o que prova que o lote SEGUE depois de um arquivo grande."""
        async def embed(text, client=None):
            embed.calls += 1
            if len(text) > limite:
                embed.rejeitados.append(len(text))
                return None, srv.EMBED_TOO_LARGE
            return [0.1] * 768, None
        embed.calls = 0
        embed.rejeitados = []
        return embed

    @staticmethod
    async def _probe_ok():
        return None

    def test_500_de_tamanho_vira_too_large_e_nao_other(self):
        # (a) modo de falha PRÓPRIO. Sem o fix, todo 500 virava EMBED_OTHER.
        def handler(request):
            return httpx.Response(500, json=self.RESP_TOO_LARGE)

        async def cenario():
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                return await srv._embed("texto enorme", client)

        vec, err = asyncio.run(cenario())
        assert vec is None
        assert err == srv.EMBED_TOO_LARGE
        assert err != srv.EMBED_OTHER

    def test_500_generico_continua_other(self):
        # Não-regressão: o fix distingue pelo CORPO, não por "todo 500 é tamanho".
        def handler(request):
            return httpx.Response(500, json={"error": "something else broke"})

        async def cenario():
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                return await srv._embed("texto", client)

        vec, err = asyncio.run(cenario())
        assert vec is None
        assert err == srv.EMBED_OTHER

    def test_404_continua_no_model(self):
        # Não-regressão: a ordem de classificação não engoliu o caso do modelo não baixado.
        def handler(request):
            return httpx.Response(404, json={"error": "model not found"})

        async def cenario():
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                return await srv._embed("texto", client)

        assert asyncio.run(cenario())[1] == srv.EMBED_NO_MODEL

    def test_hint_de_tamanho_nao_mente_dizendo_que_nao_contatou_o_ollama(self):
        # A frase falsa é o defeito relatado: o Ollama FOI contatado e respondeu 500.
        hint = srv._embed_hint(srv.EMBED_TOO_LARGE)
        assert "contatar o Ollama" not in hint
        assert "limite de contexto" in hint
        assert srv.EMBED_MODEL in hint

    def test_tres_grandes_seguidos_NAO_abortam_o_lote(self, tmp_path, monkeypatch):
        # (b) não conta no circuit breaker. Sem o fix: 3 falhas seguidas -> aborted, e os 7
        # arquivos restantes nunca eram tentados.
        for i in range(3):
            _write(tmp_path, f"docs/grande{i}.md", "x" * 500)
        for i in range(7):
            _write(tmp_path, f"docs/pequeno{i}.md", "curto")
        embed = self._embed_por_tamanho(limite=100)
        monkeypatch.setattr(srv, "_probe_ollama", self._probe_ok)
        monkeypatch.setattr(srv, "_embed", embed)

        out = asyncio.run(srv._reindex(str(tmp_path)))

        assert embed.calls == 10          # os 10 foram tentados, não 3 (o breaker não disparou)
        assert len(embed.rejeitados) == 3
        assert "abortado" not in out

    def test_resto_do_lote_indexa_e_persiste_apos_arquivo_grande(self, tmp_path, monkeypatch):
        # (c) o resto do lote indexa. Os grandes vêm PRIMEIRO na ordem alfabética
        # (grande* < pequeno*), que é exatamente o caso que o breaker matava.
        for i in range(3):
            _write(tmp_path, f"docs/grande{i}.md", "x" * 500)
        for i in range(7):
            _write(tmp_path, f"docs/pequeno{i}.md", "curto")
        monkeypatch.setattr(srv, "_probe_ollama", self._probe_ok)
        monkeypatch.setattr(srv, "_embed", self._embed_por_tamanho(limite=100))

        asyncio.run(srv._reindex(str(tmp_path)))

        indexados = set(_load_manifest(_connect(str(tmp_path))))
        assert indexados == {f"docs/pequeno{i}.md" for i in range(7)}  # os 7 sobreviveram
        assert not any(p.startswith("docs/grande") for p in indexados)

    def test_relato_NOMEIA_o_arquivo_que_ficou_de_fora(self, tmp_path, monkeypatch):
        # (a) mensagem que nomeia o arquivo. Sem o fix o relato era "1 pulados (nao foi possivel
        # contatar o Ollama...)" — nem QUAL arquivo, nem a causa certa.
        _write(tmp_path, "docs/enorme.md", "x" * 500)
        _write(tmp_path, "docs/ok.md", "curto")
        monkeypatch.setattr(srv, "_probe_ollama", self._probe_ok)
        monkeypatch.setattr(srv, "_embed", self._embed_por_tamanho(limite=100))

        out = asyncio.run(srv._reindex(str(tmp_path)))

        assert "1 pulados" in out
        assert "docs/enorme.md" in out            # o arquivo é NOMEADO
        assert "docs/ok.md" not in out            # e o que passou não aparece como problema
        assert "contatar o Ollama" not in out     # a frase falsa não sobrevive
        assert "limite de contexto" in out

    def test_lista_longa_e_truncada_mas_o_corte_e_CONTADO(self, tmp_path, monkeypatch):
        # Truncar sem contar seria omissão em silêncio: o relato diria "5 arquivos" para 12.
        for i in range(12):
            _write(tmp_path, f"docs/g{i:02d}.md", "x" * 500)
        monkeypatch.setattr(srv, "_probe_ollama", self._probe_ok)
        monkeypatch.setattr(srv, "_embed", self._embed_por_tamanho(limite=100))

        out = asyncio.run(srv._reindex(str(tmp_path)))

        assert "12 pulados" in out
        assert f"+{12 - srv.OVERSIZED_REPORT_LIMIT} outros" in out
        assert out.count("docs/g") == srv.OVERSIZED_REPORT_LIMIT

    def test_tamanho_e_infra_no_mesmo_lote_geram_relatos_SEPARADOS(self, tmp_path, monkeypatch):
        # As duas causas coexistem sem se apagar: o breaker ainda aborta pelo 404, e o arquivo
        # grande não some do relato nem é confundido com falha de infra.
        _write(tmp_path, "docs/a_grande.md", "x" * 500)
        for i in range(5):
            _write(tmp_path, f"docs/b_ruim{i}.md", "curto")

        async def embed(text, client=None):
            embed.calls += 1
            if len(text) > 100:
                return None, srv.EMBED_TOO_LARGE
            return None, srv.EMBED_NO_MODEL
        embed.calls = 0
        monkeypatch.setattr(srv, "_probe_ollama", self._probe_ok)
        monkeypatch.setattr(srv, "_embed", embed)

        out = asyncio.run(srv._reindex(str(tmp_path)))

        # o grande foi tentado + 3 do breaker: o too-large não consumiu cota do breaker
        assert embed.calls == 1 + srv.CIRCUIT_BREAKER_THRESHOLD
        assert "docs/a_grande.md" in out   # segmento de tamanho
        assert "ollama pull" in out        # segmento de infra
        assert "abortado" in out

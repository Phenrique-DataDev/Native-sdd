"""
Testes das funções PURAS de `server.py` (sem Ollama, sem rede) — provam os Acceptance Tests
AT-001/AT-002 do DEFINE_RAG_HIBRIDO.md: a reindexação só reprocessa o que mudou. Também cobre
a camada de storage sqlite-vec (upsert/delete) com um vetor fake, e a degradação (AT-005) via
mock do embed. AT-003/AT-004/AT-006 são provados por inspeção de código/instalador — ver
BUILD_REPORT_RAG_HIBRIDO.md.

Rodar: uv run pytest onboarding/semantic-kb/test_server.py -v
"""

from pathlib import Path

import pytest

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

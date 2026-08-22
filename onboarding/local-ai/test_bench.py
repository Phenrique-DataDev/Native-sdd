import sys
import unittest.mock

import pytest

import bench

def test_score_quality():
    # Empty string should yield 0 hits
    assert bench.score_quality("") == 0

    # Text with all 5 issues should yield 5 hits
    text_all_5 = (
        "Há uma vulnerabilidade de SQL injection aqui. "
        "Também há command injection no uso de os.system. "
        "Foi encontrado um segredo hardcoded (API_KEY). "
        "Cuidado com path traversal neste diretório. "
        "Pode ocorrer um erro de division by zero."
    )
    assert bench.score_quality(text_all_5) == 5

    # Text with partial issues (3 out of 5)
    text_partial = (
        "Notei um sql injection. "
        "Evite command injection! "
        "O sistema falhou com erro genérico."
        "Problema de zero division na divisão."
    )
    assert bench.score_quality(text_partial) == 3

@unittest.mock.patch("bench.httpx.Client")
def test_run(mock_client_class):
    mock_instance = mock_client_class.return_value.__enter__.return_value
    mock_response = unittest.mock.Mock()
    mock_response.json.return_value = {
        "message": {"content": "teste de resposta"},
        "prompt_eval_count": 10,
        "eval_count": 20,
        "load_duration": 1_000_000_000, # 1 second in nanoseconds
        "eval_duration": 2_000_000_000, # 2 seconds in nanoseconds
    }
    mock_instance.post.return_value = mock_response

    result = bench.run("test-model", "test-system", "test-prompt")

    assert result["model"] == "test-model"
    assert result["content"] == "teste de resposta"
    assert result["prompt_tokens"] == 10
    assert result["gen_tokens"] == 20
    assert result["load_s"] == 1.0
    assert result["gen_s"] == 2.0
    assert result["tok_per_s"] == 10.0 # 20 / (2_000_000_000 / 1e9)
    assert "wall_s" in result

    # Check payload structure
    mock_instance.post.assert_called_once()
    args, kwargs = mock_instance.post.call_args
    assert args[0] == "http://localhost:11434/api/chat"
    payload = kwargs.get("json")
    assert payload is not None
    assert payload["model"] == "test-model"
    assert len(payload["messages"]) == 2
    assert payload["messages"][0]["role"] == "system"
    assert payload["messages"][0]["content"] == "test-system"
    assert payload["messages"][1]["role"] == "user"
    assert payload["messages"][1]["content"] == "test-prompt"
    assert payload["stream"] is False

@unittest.mock.patch("bench.httpx.Client")
def test_run_division_by_zero(mock_client_class):
    # Test fallback case when eval_duration is 0 to avoid division by zero error
    mock_instance = mock_client_class.return_value.__enter__.return_value
    mock_response = unittest.mock.Mock()
    mock_response.json.return_value = {
        "eval_count": 15,
        "eval_duration": 0,
    }
    mock_instance.post.return_value = mock_response

    result = bench.run("test-model", "sys", "usr")
    assert result["tok_per_s"] == 15000000000.0  # 15 / (1 / 1e9)

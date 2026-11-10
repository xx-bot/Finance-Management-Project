import contextlib
from decimal import Decimal
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from receipt_extraction import ExtractionResult, GeminiReceiptExtractor
from receipt_extraction.cli import main
from receipt_extraction.config import load_api_key
from receipt_extraction.providers.gemini import ExtractionError
from receipt_extraction.validation import ReceiptValidationError, parse_amount, parse_receipt, valid_schema


def receipt():
    return {"items": [{"description": "Milk", "quantity": "2", "unit_price": "3.50",
                       "line_total": "7.00", "sub_items": []}], "total": "7.00"}


class ReceiptContractTests(unittest.TestCase):
    def test_nested_receipt_preserves_printed_strings(self):
        expected = receipt()
        expected["items"][0]["sub_items"] = [dict(expected["items"][0], description="Extra", quantity=None)]
        self.assertEqual(parse_receipt(json.dumps(expected)), expected)
        self.assertTrue(valid_schema(expected))

    def test_invalid_or_partial_structures_are_rejected(self):
        for value in ('{}', '[]', '{"items":', json.dumps(dict(receipt(), total=7)), json.dumps(receipt()) + '{}'):
            with self.subTest(value=value), self.assertRaises(ReceiptValidationError):
                parse_receipt(value)

    def test_explicit_locale_decimal_parsing(self):
        self.assertEqual(parse_amount("436.20", decimal_separator=".", thousands_separator=","), Decimal("436.20"))
        self.assertEqual(parse_amount("20.000", decimal_separator=",", thousands_separator="."), Decimal("20000"))
        self.assertEqual(parse_amount("-1,000.005", decimal_separator=".", thousands_separator=","), Decimal("-1000.005"))
        for value in ("3,26000.00", "1,00.00", "NaN", "RM 7.00"):
            with self.subTest(value=value), self.assertRaises(ReceiptValidationError):
                parse_amount(value, decimal_separator=".", thousands_separator=",")
        with self.assertRaises(ValueError):
            parse_amount("1", decimal_separator=".", thousands_separator=".")

    def test_package_import_and_help_do_not_load_gpu_or_sdk_modules(self):
        code = "import sys, receipt_extraction; assert 'torch' not in sys.modules; assert 'transformers' not in sys.modules; assert 'google.genai' not in sys.modules"
        subprocess.run([sys.executable, "-c", code], check=True, capture_output=True, text=True)
        result = subprocess.run([sys.executable, "-m", "receipt_extraction", "--help"], check=True, capture_output=True, text=True)
        self.assertIn("--output", result.stdout)


class GeminiProviderTests(unittest.TestCase):
    def setUp(self):
        from PIL import Image
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.image = Path(self.directory.name) / "receipt.png"
        Image.new("RGB", (50, 80), "white").save(self.image)
        self.client = Mock()
        self.client.models.generate_content.return_value = SimpleNamespace(
            candidates=[SimpleNamespace(finish_reason="STOP")], text=json.dumps(receipt()), model_version="test-version",
            usage_metadata=SimpleNamespace(prompt_token_count=100, candidates_token_count=50,
                                           thoughts_token_count=2, total_token_count=152),
        )

    def test_provider_uses_item_schema_and_returns_common_result(self):
        result = GeminiReceiptExtractor(self.client).extract(self.image)
        self.assertIsInstance(result, ExtractionResult)
        self.assertEqual(result.receipt, receipt())
        self.assertEqual(result.to_dict()["provider"], "gemini")
        self.assertEqual(result.usage["total_tokens"], 152)
        self.assertEqual(result.model_version, "test-version")
        settings = self.client.models.generate_content.call_args.kwargs["config"].model_dump(exclude_none=True, mode="json")
        self.assertEqual(settings["response_json_schema"]["required"], ["items", "total"])
        self.assertNotIn("temperature", settings)
        self.assertNotIn("thinking_budget", settings["thinking_config"])
        self.client.models.generate_content.assert_called_once()

    def test_incomplete_model_response_is_not_accepted(self):
        self.client.models.generate_content.return_value.candidates[0].finish_reason = "MAX_TOKENS"
        with self.assertRaisesRegex(ExtractionError, "MAX_TOKENS"):
            GeminiReceiptExtractor(self.client).extract(self.image)

    def test_quota_error_is_clear_and_not_retried(self):
        from google.genai import errors
        self.client.models.generate_content.side_effect = errors.ClientError(429, {"error": {"message": "Quota"}})
        with self.assertRaisesRegex(ExtractionError, "quota/rate limit") as raised:
            GeminiReceiptExtractor(self.client).extract(self.image)
        self.assertEqual(raised.exception.code, 429)
        self.client.models.generate_content.assert_called_once()

    def test_owned_client_closes_once_and_borrowed_client_stays_open(self):
        with GeminiReceiptExtractor(self.client):
            pass
        self.client.close.assert_not_called()
        extractor = GeminiReceiptExtractor(self.client, owns_client=True)
        extractor.close()
        extractor.close()
        self.client.close.assert_called_once()

    def test_from_env_validates_before_allocating_a_client(self):
        with patch("google.genai.Client") as client:
            with self.assertRaises(ValueError):
                GeminiReceiptExtractor.from_env(max_image_edge=0)
        client.assert_not_called()

    def test_environment_key_precedes_env_file(self):
        env = Path(self.directory.name) / "api.env"
        env.write_text("GEMINI_API_KEY=file-key\n")
        with patch.dict(os.environ, {"GEMINI_API_KEY": "environment-key"}, clear=True):
            self.assertEqual(load_api_key(env), "environment-key")
        env.write_text("GEMINI_API_KEY=your_gemini_api_key_here\n")
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(ValueError):
            load_api_key(env)

    def test_cli_prints_receipt_json_and_saves_nested_output(self):
        output = Path(self.directory.name) / "results/receipt.json"
        context = Mock()
        context.__enter__ = Mock(return_value=GeminiReceiptExtractor(self.client))
        context.__exit__ = Mock(return_value=False)
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch("receipt_extraction.cli.GeminiReceiptExtractor.from_env", return_value=context), \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            main([str(self.image), "--output", str(output)])
        self.assertEqual(json.loads(stdout.getvalue()), receipt())
        self.assertEqual(json.loads(output.read_text()), receipt())
        self.assertIn("Token usage", stderr.getvalue())



if __name__ == "__main__":
    unittest.main()

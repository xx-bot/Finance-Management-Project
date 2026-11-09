import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

from google.genai import errors, types
from PIL import Image

from gemini_inference import DEFAULT_MODEL, parse_receipt, predict_receipt


class GeminiRequestTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.image = Path(self.temp_dir.name) / "receipt.jpg"
        Image.new("RGB", (80, 100), "white").save(self.image)

    def test_flash_lite_request_omits_unsupported_settings(self):
        expected = {"company": "Shop", "date": "01/01/2026", "address": "Main St", "total": "10.00"}
        client = Mock()
        client.models.generate_content.return_value = SimpleNamespace(
            candidates=[SimpleNamespace(finish_reason=types.FinishReason.STOP)],
            text=json.dumps(expected),
            usage_metadata=SimpleNamespace(prompt_token_count=100, candidates_token_count=40,
                                           thoughts_token_count=5, total_token_count=145),
        )
        receipt, usage = predict_receipt(client, self.image, with_confidence=False)
        request = client.models.generate_content.call_args.kwargs
        config = request["config"].model_dump(exclude_none=True, mode="json")
        self.assertEqual(DEFAULT_MODEL, "gemini-3.5-flash-lite")
        self.assertEqual(request["model"], DEFAULT_MODEL)
        self.assertNotIn("temperature", config)
        self.assertNotIn("top_p", config)
        self.assertNotIn("top_k", config)
        self.assertEqual(config["thinking_config"], {"thinking_level": "MINIMAL"})
        self.assertEqual(config["response_mime_type"], "application/json")
        self.assertEqual(receipt, expected)
        self.assertEqual(usage["total_tokens"], 145)
        client.models.generate_content.assert_called_once()

    def test_default_request_returns_labeled_model_reported_scores(self):
        expected = {field: {"value": value, "score": 0.8} for field, value in
                    {"company": "Shop", "date": "01/01/2026", "address": "Main St", "total": "10.00"}.items()}
        client = Mock()
        client.models.generate_content.return_value = SimpleNamespace(
            candidates=[SimpleNamespace(finish_reason=types.FinishReason.STOP)],
            text=json.dumps(expected), usage_metadata=None,
        )
        receipt, _ = predict_receipt(client, self.image)
        request = client.models.generate_content.call_args.kwargs
        config = request["config"].model_dump(exclude_none=True, mode="json")
        self.assertNotIn("response_logprobs", config)
        self.assertNotIn("logprobs", config)
        self.assertIn("self-assessed", request["contents"][1])
        self.assertEqual(receipt["fields"], expected)
        self.assertEqual(receipt["score_method"], "model_self_report")
        self.assertFalse(receipt["calibrated"])
        client.models.generate_content.assert_called_once()

    def test_score_validation_and_empty_fields(self):
        fields = {field: {"value": "readable", "score": 0.8} for field in ("company", "date", "address", "total")}
        for invalid in (-0.1, 1.1, True, "0.9", None):
            fields["total"]["score"] = invalid
            with self.subTest(score=invalid), self.assertRaises(RuntimeError):
                parse_receipt(json.dumps(fields), with_confidence=True)
        fields["total"] = {"value": "", "score": 0.9}
        receipt = parse_receipt(json.dumps(fields), with_confidence=True)
        self.assertIsNone(receipt["fields"]["total"]["score"])

    def test_bad_request_includes_api_message(self):
        client = Mock()
        client.models.generate_content.side_effect = errors.ClientError(
            400, {"error": {"message": "Request contains an invalid argument."}},
        )
        with self.assertRaisesRegex(RuntimeError, "Request contains an invalid argument"):
            predict_receipt(client, self.image)


if __name__ == "__main__":
    unittest.main()

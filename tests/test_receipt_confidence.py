import contextlib
import json
import math
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import torch
from PIL import Image

from receipt_confidence import score_generated_fields, token_spans, value_spans
from smolvlm_inference import ReceiptExtractor


class CharacterTokenizer:
    all_special_ids = [0]
    eos_token_id = 0

    def get_vocab(self):
        return {}

    def decode(self, tokens, **kwargs):
        return "".join(chr(int(token)) for token in tokens if int(token) != 0)


class ConfidenceTests(unittest.TestCase):
    def test_scores_use_value_tokens_and_exclude_syntax_and_trailing_objects(self):
        receipt = {"company": "total", "date": "total", "address": 'A "B" {C}', "total": "77.83"}
        text = " \n" + json.dumps(receipt) + '\n{"total": "incorrect"}'
        probabilities = [0.99] * len(text)
        expected = {"company": 0.8, "date": 0.6, "address": 0.4, "total": 0.2}
        spans = value_spans(text)
        for field, (start, end) in spans.items():
            probabilities[start:end] = [expected[field]] * (end - start)
        result = score_generated_fields(receipt, text, CharacterTokenizer(), list(map(ord, text)),
                                        [math.log(p) for p in probabilities])
        for field, score in expected.items():
            self.assertEqual(result["fields"][field], {"value": receipt[field], "score": score})
        self.assertFalse(result["calibrated"])

    def test_empty_field_has_no_score(self):
        text = '{"company": ""}'
        result = score_generated_fields({"company": ""}, text, CharacterTokenizer(), list(map(ord, text)), [-0.1] * len(text))
        self.assertIsNone(result["fields"]["company"]["score"])

    def test_split_unicode_tokens_are_grouped(self):
        class ByteTokenizer:
            all_special_ids = []

            def decode(self, tokens, **kwargs):
                return bytes(tokens).decode("utf-8", errors="replace")

        self.assertEqual(token_spans(ByteTokenizer(), [195, 169], "é"), [(0, 1), (0, 1)])

    def test_smolvlm_predict_wires_raw_logits_to_field_scores(self):
        expected = {"company": "Shop", "date": "Today", "address": "Main", "total": "10"}
        text = json.dumps(expected)
        extractor = ReceiptExtractor.__new__(ReceiptExtractor)
        extractor.device, extractor.dtype = torch.device("cpu"), torch.float32
        extractor.prompt, extractor.max_new_tokens = "Prompt", 200
        processor = Mock(return_value={"input_ids": torch.tensor([[1, 2]]), "pixel_values": torch.ones(1)})
        processor.tokenizer = CharacterTokenizer()
        extractor.processor = processor
        extractor.model = Mock(generation_config=SimpleNamespace(eos_token_id=0))
        extractor.model.generate.return_value = SimpleNamespace(
            sequences=torch.tensor([[1, 2] + list(map(ord, text))]),
            logits=tuple(torch.zeros(1, 128) for _ in text),
        )
        with tempfile.TemporaryDirectory() as directory:
            image_path = Path(directory) / "receipt.jpg"
            Image.new("RGB", (10, 10)).save(image_path)
            with patch.object(torch, "autocast", return_value=contextlib.nullcontext()):
                result = extractor.predict(image_path)
        self.assertTrue(extractor.model.generate.call_args.kwargs["output_logits"])
        self.assertEqual(result["score_method"], "geometric_mean_token_probability")
        for field in expected:
            self.assertEqual(result["fields"][field]["value"], expected[field])
            self.assertAlmostEqual(result["fields"][field]["score"], 1 / 128, places=6)


if __name__ == "__main__":
    unittest.main()

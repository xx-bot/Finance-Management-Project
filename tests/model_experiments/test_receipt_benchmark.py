import ast
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from PIL import Image

from experiments.benchmarks.receipt_benchmark import (
    SCORABLE, digest_json, gemini_request, item_counts, load_results,
    prepare_examples, run_benchmark, score_example, select_test_examples,
    summarize_records, valid_schema, wilson_interval, write_json,
)


def item(name="MILK", price="10,000"):
    return {"description": name, "quantity": "1", "unit_price": None, "line_total": price, "sub_items": []}


def receipt(items=None, total="10,000"):
    return {"items": [item()] if items is None else items, "total": total}


class BenchmarkMetricsTests(unittest.TestCase):
    def test_duplicate_aware_item_matching_is_order_independent(self):
        gold = receipt([item(), item(), item("BREAD", "5,000")], "25,000")
        prediction = receipt([item("bread", "5,000"), item(" milk ")], "25,000")
        scores = score_example({"prediction": prediction}, gold)
        self.assertEqual(scores["item_matched"], 2)
        self.assertEqual(scores["item_reference"], 3)
        self.assertEqual(scores["item_predicted"], 2)
        self.assertTrue(scores["total_correct"])
        self.assertFalse(scores["full_receipt_exact"])

    def test_old_field_schema_can_still_score_total(self):
        prediction = {"company": "Shop", "date": "Today", "address": "Main St", "total": "10,000"}
        scores = score_example({"prediction": prediction}, receipt())
        self.assertTrue(scores["total_correct"])
        self.assertFalse(scores["schema_valid"])
        self.assertEqual(scores["item_predicted"], 0)

    def test_common_subset_excludes_operational_failures_but_keeps_invalid_outputs(self):
        examples = [{"id": key, "reference": receipt()} for key in ["a", "b", "c"]]
        data = {
            "cord_smolvlm": [{"example_id": key, "status": "ok", "prediction": receipt()} for key in ["a", "b", "c"]],
            "sroie_smolvlm": [{"example_id": "a", "status": "invalid_output", "prediction": None},
                               {"example_id": "b", "status": "ok", "prediction": receipt()}],
            "gemini": [{"example_id": "a", "status": "ok", "prediction": receipt()},
                       {"example_id": "b", "status": "operational_error", "prediction": None}],
        }
        summary = summarize_records(data, examples)
        self.assertEqual(summary["paired_example_ids"], ["a"])
        rows = {row["model"]: row for row in summary["summary"]}
        self.assertEqual(rows["cord_smolvlm"]["total_accuracy"], 1)
        self.assertEqual(rows["sroie_smolvlm"]["total_accuracy"], 0)
        self.assertEqual(rows["sroie_smolvlm"]["item_f1"], 0)
        self.assertEqual(rows["gemini"]["operational_errors"], 1)
        self.assertEqual(rows["gemini"]["pending_receipts"], 1)

    def test_missing_models_are_not_plotted_as_zero_accuracy(self):
        summary = summarize_records({"cord_smolvlm": [{"example_id": "a", "status": "ok", "prediction": receipt()}]},
                                    [{"id": "a", "reference": receipt()}])
        self.assertEqual(summary["paired_example_ids"], [])
        for row in summary["summary"]:
            self.assertIsNone(row["total_accuracy"])
            self.assertIsNone(row["item_f1"])

    def test_schema_checks_subitems_and_preserves_money_separators(self):
        good = receipt()
        good["items"][0]["sub_items"] = [item("NO ICE", None)]
        self.assertTrue(valid_schema(good))
        good["items"][0]["sub_items"][0]["quantity"] = 1
        self.assertFalse(valid_schema(good))
        self.assertFalse(score_example({"prediction": receipt(total="10.000")}, receipt())["total_correct"])
        self.assertEqual(wilson_interval(0, 0), (None, None))
        low, high = wilson_interval(10, 10)
        self.assertLess(low, 1)
        self.assertEqual(high, 1)

    def test_sample_uses_test_records_and_rejects_overlap(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            rows = [{"split": split, "image_sha256": key, "dataset_id": "cord", "source_split": split,
                     "index": index, "target": receipt()} for index, (key, split) in
                    enumerate([("train", "train"), ("a", "test"), ("b", "test"), ("c", "test")])]
            manifest = {"datasets": {"cord": "commit"}, "records": rows}
            write_json(path / "dataset_manifest.json", manifest)
            _, first = select_test_examples(path, 2, 42)
            _, second = select_test_examples(path, 2, 42)
            self.assertEqual(first, second)
            self.assertEqual(len(first), 2)
            self.assertTrue(all(row["source_split"] == "test" for row in first))
            rows.append(dict(rows[1], split="train"))
            write_json(path / "dataset_manifest.json", manifest)
            with self.assertRaises(ValueError):
                select_test_examples(path)

    def test_gpu_results_are_readable_on_another_machine_but_wrong_weights_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            write_json(path / "examples.json", {"question": "Items", "examples": [{"id": "a", "reference": receipt()}]})
            cpu_settings = {"model": "cord_smolvlm", "adapter_sha256": "correct-weights",
                            "cuda_device": None, "torch_version": "cpu", "adapter": "/local/model"}
            gpu_settings = dict(cpu_settings, cuda_device="A100", torch_version="gpu", adapter="/remote/model")
            write_json(path / "predictions/cord_smolvlm/gpu.json", {"configuration": gpu_settings, "records": [
                {"example_id": "a", "reference_sha256": digest_json(receipt()), "status": "ok", "prediction": receipt()}]})
            with patch("experiments.benchmarks.receipt_benchmark.run_configuration", return_value=cpu_settings):
                _, records = load_results(path, ["cord_smolvlm"])
            self.assertEqual(len(records["cord_smolvlm"]), 1)
            with patch("experiments.benchmarks.receipt_benchmark.run_configuration", return_value=dict(cpu_settings, adapter_sha256="other-weights")):
                _, records = load_results(path, ["cord_smolvlm"])
            self.assertFalse(records["cord_smolvlm"])

    def test_notebook_code_compiles(self):
        path = Path(__file__).resolve().parents[2] / "experiments/benchmarks/notebooks/model_comparison.ipynb"
        notebook = json.loads(path.read_text())
        for cell in notebook["cells"]:
            if cell["cell_type"] == "code":
                compile("".join(cell["source"]), cell["id"], "exec")


class BenchmarkApiTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.image = self.path / "receipt.png"
        Image.new("RGB", (30, 40), "white").save(self.image)

    def test_gemini_uses_items_schema_without_confidence_or_invalid_sampling_settings(self):
        from google.genai import types
        client = Mock()
        client.models.generate_content.return_value = SimpleNamespace(
            text=json.dumps(receipt()), candidates=[SimpleNamespace(finish_reason=types.FinishReason.STOP)],
            usage_metadata=SimpleNamespace(prompt_token_count=40, candidates_token_count=20,
                                           thoughts_token_count=5, total_token_count=65), model_version="version")
        result = gemini_request(client, self.image, "Extract items", "gemini-3.5-flash-lite", 768, 2048)
        config = client.models.generate_content.call_args.kwargs["config"].model_dump(exclude_none=True, mode="json")
        self.assertNotIn("temperature", config)
        self.assertNotIn("thinking_budget", config["thinking_config"])
        self.assertNotIn("response_logprobs", config)
        self.assertEqual(config["response_json_schema"]["required"], ["items", "total"])
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["usage"]["total_tokens"], 65)
        client.models.generate_content.assert_called_once()

    def test_resuming_does_not_repeat_cached_requests(self):
        config = {"question": "Extract items", "examples": [
            {"id": key, "image_path": str(self.image), "reference": receipt()} for key in ["a", "b"]]}
        write_json(self.path / "examples.json", config)
        response = {"prediction": receipt(), "status": "ok", "usage": {}, "raw_text": json.dumps(receipt())}
        with patch.dict("os.environ", {"GEMINI_API_KEY": "test-key"}), \
             patch("google.genai.Client") as client, \
             patch("experiments.benchmarks.receipt_benchmark.gemini_request", return_value=response) as request, \
             contextlib.redirect_stdout(io.StringIO()):
            run_benchmark(self.path, models=["gemini"], gemini_delay=0)
            run_benchmark(self.path, models=["gemini"], gemini_delay=0)
        self.assertEqual(request.call_count, 2)
        self.assertEqual(client.call_count, 1)

    def test_quota_failure_stops_remaining_calls(self):
        from google.genai import errors
        write_json(self.path / "examples.json", {"question": "Extract items", "examples": [
            {"id": key, "image_path": str(self.image), "reference": receipt()} for key in ["a", "b", "c"]]})
        with patch.dict("os.environ", {"GEMINI_API_KEY": "test-key"}), \
             patch("google.genai.Client"), \
             patch("experiments.benchmarks.receipt_benchmark.gemini_request", side_effect=errors.ClientError(429, {"error": {"message": "quota"}})) as request, \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            summary = run_benchmark(self.path, models=["gemini"], gemini_delay=0)
        request.assert_called_once()
        self.assertEqual(summary["summary"][0]["pending_receipts"], 2)
        self.assertEqual(summary["summary"][0]["operational_errors"], 1)
        self.assertIsNone(summary["summary"][0]["total_accuracy"])


if __name__ == "__main__":
    unittest.main()

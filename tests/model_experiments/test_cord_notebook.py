"""Exercise portable notebook helpers without downloading CORD or loading GPU weights."""

import ast
import contextlib
import hashlib
import io
import json
import math
import random
import tempfile
import unittest
from collections import Counter, defaultdict
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import torch
from PIL import Image, ImageOps
from torch.utils.data import DataLoader
from transformers import get_linear_schedule_with_warmup

NOTEBOOK = Path(__file__).resolve().parents[2] / "experiments/smolvlm/notebooks/cord_training.ipynb"
SOURCES = {cell["id"]: "".join(cell["source"]) for cell in json.loads(NOTEBOOK.read_text())["cells"]}
DATASET_IDS = ("naver-clova-ix/cord-v2", "naver-clova-ix/cord-v1")


def helpers():
    scope = dict(globals())
    exec(compile(SOURCES["target-helpers"], "target-helpers", "exec"), scope)
    return scope


class CordNotebookTests(unittest.TestCase):
    def test_code_cells_compile_and_have_no_saved_outputs(self):
        notebook = json.loads(NOTEBOOK.read_text())
        for cell in notebook["cells"]:
            if cell["cell_type"] == "code":
                self.assertIsNone(cell["execution_count"])
                self.assertEqual(cell["outputs"], [])
                if cell["id"] != "install":
                    compile("".join(cell["source"]), cell["id"], "exec")

    def test_annotation_versions_map_to_same_hierarchy(self):
        convert = helpers()["cord_target"]
        v1 = {"gt_parse": {"menu": {"nm": "STEAK", "cnt": "1 x", "price": "58,000", "sub_nm": "WELL DONE"},
                           "total": {"total_price": "60,000", "cashprice": "100,000"}}}
        v2 = {"gt_parse": {"menu": [{"nm": "STEAK", "cnt": "1 x", "price": "58,000", "sub": {"nm": "WELL DONE"}}],
                           "total": {"total_price": "60,000", "cashprice": "100,000"}}}
        self.assertEqual(convert(json.dumps(v1)), convert(v2))
        target = convert(v2)
        self.assertEqual(target["total"], "60,000")
        self.assertEqual(target["items"][0]["quantity"], "1 x")
        self.assertIsNone(target["items"][0]["unit_price"])
        self.assertEqual(target["items"][0]["sub_items"][0]["description"], "WELL DONE")

    def test_ambiguous_numeric_fields_are_not_guessed(self):
        convert = helpers()["cord_target"]
        with self.assertRaises(ValueError):
            convert({"gt_parse": {"menu": {"nm": "item", "price": ["10", "20"]}}})
        with self.assertRaises(ValueError):
            convert({"gt_parse": {"menu": {"nm": "item", "sub_nm": ["A", "B"], "sub_price": "10"}}})

    def test_duplicate_protection_and_v2_label_preference(self):
        choose = helpers()["select_records"]
        def row(version, split, fingerprint, index):
            return {"dataset_id": DATASET_IDS[version], "split": split, "source_split": split,
                    "image_sha256": fingerprint, "index": index, "ground_truth": {"gt_parse": {"version": version}}}
        rows, report = choose([row(1, "test", "same", 0), row(0, "train", "same", 0),
                               row(1, "train", "unique-v1", 1), row(0, "validation", "validation", 1)])
        by_hash = {row["image_sha256"]: row for row in rows}
        self.assertEqual(by_hash["same"]["split"], "test")
        self.assertEqual(by_hash["same"]["dataset_id"], DATASET_IDS[0])
        self.assertEqual(by_hash["same"]["source_split"], "train")
        self.assertEqual(by_hash["unique-v1"]["dataset_id"], DATASET_IDS[1])
        self.assertTrue(report[0]["raw_parse_disagreement"])

    def test_reported_cord_ambiguities_are_quarantined_without_changing_source(self):
        helper = helpers()
        def row(index, target, split="train"):
            return {"dataset_id": DATASET_IDS[0], "split": split, "source_split": split,
                    "image_sha256": str(index), "index": index, "ground_truth": {"gt_parse": target}}
        total_case = row(135, {"menu": {"nm": "Lunch", "cnt": "1", "price": "55,834"},
                               "total": {"total_price": ["55,834", "55,800"]}})
        quantity_case = row(525, {"menu": {"nm": "Burger", "cnt": ["TRIPPLE CHEESE", "1"], "price": "10,000"},
                                  "total": {"total_price": "10,000"}})
        good = row(1, {"menu": {"nm": "Item", "cnt": "1", "price": "9,000"},
                       "total": {"total_price": "9,000"}})
        before = json.dumps([total_case, quantity_case, good], sort_keys=True)
        accepted, quarantined, errors = helper["prepare_records"]([total_case, quantity_case, good], 5)
        self.assertEqual([record["index"] for record in accepted], [1])
        self.assertEqual([record["index"] for record in quarantined], [135, 525])
        self.assertTrue(all(record["action"] == "quarantined" for record in errors))
        self.assertEqual(quarantined[0]["gt_parse"]["total"]["total_price"], ["55,834", "55,800"])
        self.assertEqual(before, json.dumps([total_case, quantity_case, good], sort_keys=True))

        # Hold-outs are never silently filtered; cap=0 is strict mode.
        total_case["split"] = "validation"
        _, quarantine, errors = helper["prepare_records"]([total_case], 5)
        self.assertFalse(quarantine)
        self.assertEqual(errors[0]["action"], "fatal")
        _, quarantine, errors = helper["prepare_records"]([quantity_case], 0)
        self.assertFalse(quarantine)
        self.assertEqual(errors[0]["action"], "fatal")

    def test_ambiguity_cap_and_structural_errors_remain_fatal(self):
        helper = helpers()
        def row(index, menu):
            return {"dataset_id": DATASET_IDS[0], "split": "train", "source_split": "train",
                    "image_sha256": str(index), "index": index, "ground_truth": {"gt_parse": {"menu": menu}}}
        _, quarantine, errors = helper["prepare_records"](
            [row(0, {"nm": "a", "price": ["10", "20"]}),
             row(1, {"nm": "b", "price": ["30", "40"]}),
             row(2, "not an object")], 1)
        self.assertEqual(len(quarantine), 1)
        self.assertEqual([record["action"] for record in errors], ["quarantined", "fatal", "fatal"])

    def test_quarantined_v2_image_does_not_fall_back_to_v1(self):
        helper = helpers()
        rows = [{"dataset_id": dataset, "split": "train", "source_split": "train", "index": 135,
                 "image_sha256": "same", "ground_truth": {"gt_parse": {"total": {"total_price": prices}}}}
                for dataset, prices in [(DATASET_IDS[0], ["55,834", "55,800"]), (DATASET_IDS[1], "55,800")]]
        unique, _ = helper["select_records"](rows)
        accepted, quarantined, _ = helper["prepare_records"](unique, 5)
        self.assertFalse(accepted)
        self.assertEqual(len(quarantined[0]["aliases"]), 2)

    def test_rgb_hash_does_not_depend_on_file_container(self):
        fingerprint = helpers()["image_fingerprint"]
        image = Image.new("RGB", (20, 30), "white")
        buffer = io.BytesIO()
        image.save(buffer, format="PNG")
        self.assertEqual(fingerprint(image), fingerprint({"bytes": buffer.getvalue()}))
        self.assertNotEqual(fingerprint(image), fingerprint(Image.new("RGB", (20, 30), "black")))

    def test_variable_length_gradient_accumulation_matches_effective_batch(self):
        class TokenModel(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.weight = torch.nn.Parameter(torch.tensor(0.7))
            def forward(self, input_ids, labels):
                mask = labels[:, 1:] != -100
                per_token = (self.weight * input_ids[:, 1:].float() / 100 - 0.2).square()
                return SimpleNamespace(loss=per_token[mask].mean())

        def collate(rows):
            labels = torch.full((len(rows), 6), -100)
            for index, row in enumerate(rows):
                labels[index, 1:2 + row % 4] = 1
            return {"input_ids": torch.tensor([[row] * 6 for row in rows]), "labels": labels}

        rows, seed, epochs, accum, lr, limit = list(range(1, 10)), 42, 2, 2, 0.001, 4
        def loader():
            return DataLoader(rows, batch_size=2, shuffle=True, collate_fn=collate,
                              generator=torch.Generator().manual_seed(seed))

        model = TokenModel()
        with tempfile.TemporaryDirectory() as directory:
            scope = dict(globals(), model=model, train_loader=loader(), BATCH_SIZE=2, GRAD_ACCUM=accum,
                         EPOCHS=epochs, LR=lr, MAX_STEPS=limit, TRAIN_DTYPE=torch.bfloat16,
                         OUTPUT_DIR=Path(directory), to_device=lambda value: value,
                         export_adapter=lambda *args: None, validation_loss=lambda: 0.1)
            with patch.object(torch, "autocast", return_value=contextlib.nullcontext()), \
                 patch.object(torch.cuda, "reset_peak_memory_stats"), \
                 patch.object(torch.cuda, "max_memory_allocated", return_value=0), \
                 patch.object(torch.cuda, "empty_cache"):
                exec(compile(SOURCES["training-loop"], "training-loop", "exec"), scope)

        reference = TokenModel()
        optimizer = torch.optim.AdamW(reference.parameters(), lr=lr, weight_decay=0.0)
        scheduler = get_linear_schedule_with_warmup(optimizer, 1, limit)
        step = 0
        batches = loader()
        for _ in range(epochs):
            group = []
            for index, batch in enumerate(batches):
                group.append(batch)
                if len(group) == accum or index + 1 == len(batches):
                    combined = {key: torch.cat([value[key] for value in group]) for key in batch}
                    reference(**combined).loss.backward()
                    torch.nn.utils.clip_grad_norm_(reference.parameters(), 1.0)
                    optimizer.step()
                    scheduler.step()
                    optimizer.zero_grad(set_to_none=True)
                    group = []
                    step += 1
                    if step == limit:
                        break
            if step == limit:
                break
        self.assertEqual(scope["step"], limit)
        torch.testing.assert_close(model.weight, reference.weight, atol=1e-7, rtol=0)


if __name__ == "__main__":
    unittest.main()

"""Compare receipt extractors on the exact held-out CORD images in the training manifest.

python -m experiments.benchmarks.receipt_benchmark --prepare --models cord_smolvlm sroie_smolvlm gemini --limit 10
Predictions are cached per image, model weights and request settings. No training occurs.
"""

import argparse
import gc
import hashlib
import json
import math
import os
import random
import statistics
import sys
import time
import unicodedata
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from receipt_extraction.config import project_root

ROOT = project_root()
DEFAULT_CORD = ROOT / "model/smolvlm-cord-items-lora"
DEFAULT_OLD = ROOT / "model/smolvlm-receipt-lora"
DEFAULT_OUTPUT = ROOT / "results/model_comparison"
MODEL_LABELS = {
    "cord_smolvlm": "CORD SmolVLM",
    "sroie_smolvlm": "Earlier SROIE SmolVLM (item prompt)",
    "gemini": "Gemini 3.5 Flash-Lite",
}
from receipt_extraction.schemas import ITEM_FIELDS, item_schema
from receipt_extraction.validation import valid_schema
from receipt_extraction.providers.gemini import generate_items_response, token_usage
SCORABLE = {"ok", "invalid_output"}


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def digest_json(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def file_digest(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def image_digest(image):
    from PIL import ImageOps
    rgb = ImageOps.exif_transpose(image).convert("RGB")
    digest = hashlib.sha256()
    digest.update(str(rgb.size).encode())
    digest.update(rgb.tobytes())
    return digest.hexdigest()


def training_audit(adapter=DEFAULT_CORD):
    adapter = Path(adapter)
    summary = read_json(adapter / "training_summary.json")
    log = read_json(adapter / "training_log.json")
    manifest = read_json(adapter / "dataset_manifest.json")
    validation = [row for row in log if "validation_loss" in row]
    splits = dict(Counter(row["split"] for row in manifest["records"]))
    first, last = validation[0]["validation_loss"], validation[-1]["validation_loss"]
    return {
        "adapter": str(adapter), "optimizer_steps": summary["optimizer_step"],
        "smoke_test": summary["smoke_test"], "effective_split_counts": splits,
        "validation_by_epoch": validation,
        "selected_validation_loss": summary["validation_loss"],
        "validation_loss_reduction_percent": (1 - last / first) * 100,
        "adapter_bytes": (adapter / "adapter_model.safetensors").stat().st_size,
        "saved_test_metrics": read_json(adapter / "test_metrics.json") if (adapter / "test_metrics.json").exists() else None,
        "interpretation": "Teacher-forced answer-token loss; it is not extraction accuracy. No test result is inferred from loss.",
    }


def select_test_examples(adapter=DEFAULT_CORD, limit=10, seed=42):
    adapter = Path(adapter)
    manifest = read_json(adapter / "dataset_manifest.json")
    rows = sorted((row for row in manifest["records"] if row["split"] == "test"), key=lambda row: row["image_sha256"])
    train_hashes = {row["image_sha256"] for row in manifest["records"] if row["split"] != "test"}
    hashes = [row["image_sha256"] for row in rows]
    if len(set(hashes)) != len(hashes) or set(hashes) & train_hashes:
        raise ValueError("Manifest contains duplicate test images or overlap with training/validation")
    if not rows:
        raise ValueError("Manifest has no held-out test records")
    if limit < 0:
        raise ValueError("limit must be nonnegative; 0 selects the whole test split")
    if limit and limit < len(rows):
        rows = random.Random(seed).sample(rows, limit)
    return manifest, [{
        "id": row["image_sha256"], "dataset_id": row["dataset_id"],
        "source_split": row["source_split"], "source_index": row["index"], "reference": row["target"],
        "dataset_revision": manifest["datasets"][row["dataset_id"]],
    } for row in rows]


def prepare_examples(adapter=DEFAULT_CORD, output=DEFAULT_OUTPUT, limit=10, seed=42):
    """Download only needed source splits; verify images against the training manifest."""
    from PIL import Image, ImageOps
    manifest, examples = select_test_examples(adapter, limit, seed)
    output = Path(output)
    datasets = {}
    for number, example in enumerate(examples, 1):
        path = output / "test_images" / f"{example['id']}.png"
        if path.exists():
            with Image.open(path) as image:
                if image_digest(image) != example["id"]:
                    raise ValueError(f"Cached image does not match manifest: {path}")
        else:
            from datasets import load_dataset
            key = (example["dataset_id"], example["dataset_revision"], example["source_split"])
            if key not in datasets:
                datasets[key] = load_dataset(key[0], revision=key[1], split=key[2])
            image = datasets[key][example["source_index"]]["image"]
            rgb = ImageOps.exif_transpose(image).convert("RGB")
            if image_digest(rgb) != example["id"]:
                raise ValueError(f"Source image mismatch: {key}/{example['source_index']}")
            path.parent.mkdir(parents=True, exist_ok=True)
            rgb.save(path)
        example["image_path"] = str(path.resolve())
        print(f"Prepared held-out receipt {number}/{len(examples)}", flush=True)
    deployment = read_json(Path(adapter) / "deployment_config.json")
    config = {"examples": examples, "question": deployment["question"], "seed": seed,
              "source_manifest_sha256": file_digest(Path(adapter) / "dataset_manifest.json"),
              "dataset_revisions": manifest["datasets"], "target_schema": "items_and_total_with_nested_sub_items"}
    write_json(output / "examples.json", config)
    return config


def normalized(value):
    return " ".join(unicodedata.normalize("NFKC", value).casefold().split()) if isinstance(value, str) else value


def item_counts(prediction, descriptions_only=False):
    items = prediction.get("items", []) if isinstance(prediction, dict) else []
    if not isinstance(items, list):
        return Counter()
    result = Counter()
    for item in items:
        if not isinstance(item, dict):
            # A malformed extra entry still counts as an unmatched prediction.
            result[("__invalid_item__", repr(item))] += 1
            continue
        fields = ("description",) if descriptions_only else ("description", "quantity", "unit_price", "line_total")
        signature = tuple(normalized(item.get(key)) if item.get(key) is None or isinstance(item.get(key), str)
                          else ("__invalid_value__", repr(item.get(key))) for key in fields)
        result[signature] += 1
    return result


def score_example(record, reference):
    prediction = record.get("prediction")
    total_labeled = reference.get("total") is not None
    total_correct = (total_labeled and isinstance(prediction, dict)
                     and isinstance(prediction.get("total"), str)
                     and prediction["total"].strip() == reference["total"].strip())
    scores = {"schema_valid": valid_schema(prediction), "full_receipt_exact": prediction == reference,
              "total_labeled": total_labeled, "total_correct": bool(total_correct)}
    for prefix, descriptions_only in (("item", False), ("description", True)):
        gold, predicted = item_counts(reference, descriptions_only), item_counts(prediction, descriptions_only)
        scores.update({f"{prefix}_matched": sum((gold & predicted).values()),
                       f"{prefix}_reference": sum(gold.values()), f"{prefix}_predicted": sum(predicted.values())})
    return scores


def wilson_interval(hits, count):
    if not count:
        return None, None
    z = 1.959963984540054
    p = hits / count
    denominator = 1 + z * z / count
    center = (p + z * z / (2 * count)) / denominator
    half = z * math.sqrt(p * (1 - p) / count + z * z / (4 * count * count)) / denominator
    return (0.0 if hits == 0 else max(0.0, center - half),
            1.0 if hits == count else min(1.0, center + half))


def summarize_records(records_by_model, examples, models=None):
    """Use the same receipts for every accuracy comparison; operational failures stay visible."""
    models = list(models or MODEL_LABELS)
    ids = {example["id"] for example in examples}
    by_model = {model: {row["example_id"]: row for row in records_by_model.get(model, [])
                        if row["example_id"] in ids} for model in models}
    common = set(ids)
    for model in models:
        common &= {key for key, row in by_model[model].items() if row["status"] in SCORABLE}
    references = {example["id"]: example["reference"] for example in examples}
    summary, details = [], []
    for model in models:
        rows = list(by_model[model].values())
        scores = []
        for key in sorted(common):
            row = by_model[model][key]
            score = score_example(row, references[key])
            scores.append(score)
            details.append({"model": model, "example_id": key, **score,
                            "latency_seconds": row.get("latency_seconds"), "status": row["status"]})
        count = len(scores)
        totals = sum(row["total_labeled"] for row in scores)
        hits = sum(row["total_correct"] for row in scores)
        lo, hi = wilson_interval(hits, totals)
        result = {"model": model, "label": MODEL_LABELS.get(model, model), "selected_receipts": len(ids),
                  "attempted_receipts": len(rows), "pending_receipts": len(ids) - len(rows),
                  "execution_devices": ", ".join(sorted({row.get("execution_device", "unknown") for row in rows})),
                  "operational_errors": sum(row["status"] not in SCORABLE for row in rows),
                  "paired_receipts": count, "total_labeled": totals,
                  "total_accuracy": hits / totals if totals else None, "total_ci_low": lo, "total_ci_high": hi,
                  "schema_valid_rate": sum(row["schema_valid"] for row in scores) / count if count else None,
                  "full_receipt_exact_match": sum(row["full_receipt_exact"] for row in scores) / count if count else None}
        for prefix in ("item", "description"):
            matched = sum(row[f"{prefix}_matched"] for row in scores)
            gold = sum(row[f"{prefix}_reference"] for row in scores)
            predicted = sum(row[f"{prefix}_predicted"] for row in scores)
            result[f"{prefix}_precision"] = matched / predicted if predicted else (0.0 if gold else None)
            result[f"{prefix}_recall"] = matched / gold if gold else None
            result[f"{prefix}_f1"] = 2 * matched / (gold + predicted) if gold + predicted else None
        paired = [by_model[model][key] for key in common]
        times = [row["latency_seconds"] for row in paired if row.get("latency_seconds") is not None]
        memory = [row["peak_gpu_gib"] for row in paired if row.get("peak_gpu_gib") is not None]
        result["median_latency_seconds"] = statistics.median(times) if times else None
        result["max_peak_gpu_gib"] = max(memory) if memory else None
        for field in ("input_tokens", "output_tokens", "thinking_tokens", "total_tokens"):
            counts = [row.get("usage", {}).get(field) for row in rows]
            counts = [value for value in counts if isinstance(value, (int, float))]
            result[f"api_{field}"] = sum(counts) if counts else None
        summary.append(result)
    return {"paired_example_ids": sorted(common), "summary": summary, "per_receipt": details,
            "notes": ["Accuracy uses the intersection of receipts with returned outputs for all requested models.",
                      "Invalid outputs count as errors. Network, quota, OOM and other operational failures are excluded from paired accuracy and reported separately.",
                      "The earlier adapter was trained on SROIE receipt fields; its item-prompt result is a task-transfer baseline.",
                      "Totals use exact printed strings after trimming outer whitespace; no locale-specific money conversion is guessed.",
                      "Item F1 is a duplicate-aware multiset of main descriptions, quantities, unit prices and line amounts. Nested items affect full-receipt exact match.",
                      "Latency excludes model loading, includes API network time, has no warm-up call, and is hardware/service dependent."]}


def run_configuration(model, examples_config, cord_adapter, old_adapter, image_edge, max_tokens, gemini_model):
    settings = {"model": model, "question": examples_config["question"], "image_longest_edge": image_edge,
                "max_new_tokens": max_tokens, "confidence": False, "schema": "items_and_total_v1",
                "runner_version": 1, "decoding": "greedy" if model != "gemini" else "provider_default_minimal_thinking"}
    if model == "gemini":
        import importlib.metadata
        settings.update(api_model=gemini_model, sdk_version=importlib.metadata.version("google-genai"), schema_depth=3)
    else:
        import torch
        adapter = Path(cord_adapter if model == "cord_smolvlm" else old_adapter)
        settings.update(adapter=str(adapter.resolve()), adapter_sha256=file_digest(adapter / "adapter_model.safetensors"),
                        deployment=read_json(adapter / "deployment_config.json"),
                        cuda_device=torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
                        torch_version=torch.__version__, quantization="nf4")
    return settings


def gemini_request(client, image_path, question, model, image_edge, max_tokens):
    from google.genai import types
    response = generate_items_response(client, image_path, question=question, model=model,
                                       max_image_edge=image_edge, max_output_tokens=max_tokens)
    text = response.text or ""
    try:
        prediction = json.loads(text)
    except json.JSONDecodeError:
        prediction = None
    usage = token_usage(response)
    candidate = response.candidates[0] if response.candidates else None
    finished = getattr(candidate, "finish_reason", None) == types.FinishReason.STOP
    return {"prediction": prediction, "raw_text": text, "usage": usage,
            "status": "ok" if finished and valid_schema(prediction) else "invalid_output",
            "finish_reason": str(getattr(candidate, "finish_reason", None)),
            "provider_model_version": getattr(response, "model_version", None)}


def load_results(output=DEFAULT_OUTPUT, models=None, cord_adapter=DEFAULT_CORD, old_adapter=DEFAULT_OLD,
                 image_edge=768, max_tokens=2048, gemini_model="gemini-3.5-flash-lite"):
    output = Path(output)
    config = read_json(output / "examples.json")
    records = {}
    for model in models or MODEL_LABELS:
        settings = run_configuration(model, config, cord_adapter, old_adapter, image_edge, max_tokens, gemini_model)
        path = output / "predictions" / model / f"{digest_json(settings)}.json"
        payload = read_json(path) if path.exists() else {"records": []}
        if not path.exists():
            # Results generated on the A100/local GPU must remain viewable on a CPU machine.
            # Reusing predictions during execution still requires an exact hardware-specific key.
            portable_settings = {key: value for key, value in settings.items() if key not in {"cuda_device", "torch_version", "adapter"}}
            for candidate in sorted((output / "predictions" / model).glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True):
                saved = read_json(candidate)
                saved_settings = {key: value for key, value in saved["configuration"].items() if key not in {"cuda_device", "torch_version", "adapter"}}
                if portable_settings == saved_settings:
                    payload = saved
                    break
        expected = {example["id"]: digest_json(example["reference"]) for example in config["examples"]}
        records[model] = [row for row in payload["records"] if expected.get(row["example_id"]) == row.get("reference_sha256")]
    return config, records


def run_benchmark(output=DEFAULT_OUTPUT, models=None, cord_adapter=DEFAULT_CORD, old_adapter=DEFAULT_OLD,
                  image_edge=768, max_tokens=2048, gemini_model="gemini-3.5-flash-lite", gemini_delay=13,
                  retry_errors=False):
    """Load local models sequentially; cache every response; stop Gemini on quota failure."""
    output = Path(output)
    config = read_json(output / "examples.json")
    if image_edge < 1 or max_tokens < 1 or gemini_delay < 0:
        raise ValueError("Image/token limits must be positive and delay must be nonnegative")
    for model_name in models or MODEL_LABELS:
        settings = run_configuration(model_name, config, cord_adapter, old_adapter, image_edge, max_tokens, gemini_model)
        cache_path = output / "predictions" / model_name / f"{digest_json(settings)}.json"
        payload = read_json(cache_path) if cache_path.exists() else {"configuration": settings, "records": []}
        cache = {row["example_id"]: row for row in payload["records"]}
        pending = [example for example in config["examples"] if example["id"] not in cache
                   or cache[example["id"]].get("reference_sha256") != digest_json(example["reference"])
                   or retry_errors and cache[example["id"]]["status"] not in SCORABLE]
        if not pending:
            print(f"{model_name}: all selected receipts cached", flush=True)
            continue
        extractor, client = None, None
        try:
            if model_name == "gemini":
                from dotenv import load_dotenv
                from google import genai
                from google.genai import types
                load_dotenv(ROOT / ".env", override=False)
                api_key = os.environ.get("GEMINI_API_KEY", "").strip()
                if not api_key or api_key == "your_gemini_api_key_here":
                    raise RuntimeError("Set GEMINI_API_KEY in .env to run Gemini")
                client = genai.Client(api_key=api_key, vertexai=False,
                                      http_options=types.HttpOptions(timeout=120000, retry_options=types.HttpRetryOptions(attempts=1)))
            else:
                import torch
                if not torch.cuda.is_available():
                    print(f"{model_name}: skipped, no CUDA GPU is accessible. Run this benchmark on the local GPU or A100.", file=sys.stderr)
                    continue
                from experiments.smolvlm.inference import ReceiptExtractor
                adapter = cord_adapter if model_name == "cord_smolvlm" else old_adapter
                started = time.perf_counter()
                extractor = ReceiptExtractor(adapter, image_longest_edge=image_edge, max_new_tokens=max_tokens)
                load_seconds = time.perf_counter() - started
                # Same task prompt for both adapters; does not change their exported files.
                extractor.prompt = extractor.processor.apply_chat_template([
                    {"role": "user", "content": [{"type": "image"}, {"type": "text", "text": config["question"]}]}
                ], add_generation_prompt=True)
            for number, example in enumerate(pending, 1):
                if not Path(example["image_path"]).is_file():
                    raise FileNotFoundError(f"Missing cached image: {example['image_path']}. Prepare examples first.")
                row = {"example_id": example["id"], "reference_sha256": digest_json(example["reference"]),
                       "created_at_utc": datetime.now(timezone.utc).isoformat(),
                       "execution_device": settings.get("cuda_device", "Google hosted API"),
                       "prediction": None, "usage": {}, "peak_gpu_gib": None}
                started = time.perf_counter()
                stop = False
                try:
                    if model_name == "gemini":
                        row.update(gemini_request(client, example["image_path"], config["question"], gemini_model, image_edge, max_tokens))
                    else:
                        torch.cuda.synchronize()
                        torch.cuda.reset_peak_memory_stats()
                        started = time.perf_counter()
                        prediction = extractor.predict(example["image_path"], with_confidence=False)
                        torch.cuda.synchronize()
                        row.update(prediction=prediction, status="ok" if valid_schema(prediction) else "invalid_output",
                                   peak_gpu_gib=torch.cuda.max_memory_allocated() / 2**30, model_load_seconds=load_seconds)
                except Exception as exc:
                    is_model_output = model_name != "gemini" and isinstance(exc, RuntimeError) and str(exc).startswith(("Model returned invalid", "Expected a receipt JSON"))
                    row.update(status="invalid_output" if is_model_output else "operational_error", error=str(exc))
                    stop = model_name == "gemini" or not is_model_output
                    if model_name != "gemini":
                        torch.cuda.empty_cache()
                row["latency_seconds"] = time.perf_counter() - started
                cache[example["id"]] = row
                payload["records"] = list(cache.values())
                write_json(cache_path, payload)
                print(f"{model_name}: {number}/{len(pending)} {row['status']} ({row['latency_seconds']:.2f}s)", flush=True)
                if stop:
                    print(f"Stopped {model_name} after an operational error; remaining receipts were not processed: {row.get('error')}", file=sys.stderr)
                    break
                if model_name == "gemini" and number < len(pending):
                    time.sleep(gemini_delay)
        except Exception as exc:
            print(f"{model_name}: could not start: {exc}", file=sys.stderr)
        finally:
            if client is not None:
                client.close()
            del extractor
            gc.collect()
            if model_name != "gemini":
                import torch
                if torch.cuda.is_available():
                    torch.cuda.empty_cache()
    config, records = load_results(output, models, cord_adapter, old_adapter, image_edge, max_tokens, gemini_model)
    summary = summarize_records(records, config["examples"], models)
    write_json(output / "comparison_metrics.json", summary)
    return summary


def plot_training(adapter=DEFAULT_CORD, output=DEFAULT_OUTPUT):
    import matplotlib.pyplot as plt
    adapter, output = Path(adapter), Path(output)
    log = read_json(adapter / "training_log.json")
    train = [row for row in log if "train_loss" in row]
    validation = [row for row in log if "validation_loss" in row]
    fig, axes = plt.subplots(1, 2, figsize=(12, 4))
    axes[0].plot([row["step"] for row in train], [row["train_loss"] for row in train], color="#207b98", alpha=0.7)
    axes[0].set(title="Training answer-token loss", xlabel="Optimizer step", ylabel="Loss")
    axes[1].plot([row["epoch"] for row in validation], [row["validation_loss"] for row in validation], marker="o", color="#c05c23")
    axes[1].set(title="Validation answer-token loss", xlabel="Epoch", ylabel="Loss", xticks=[row["epoch"] for row in validation])
    axes[1].margins(y=0.2)
    for row in validation:
        axes[1].annotate(f"{row['validation_loss']:.4f}", (row["epoch"], row["validation_loss"]), xytext=(0, 8), textcoords="offset points", ha="center")
    for axis in axes:
        axis.grid(alpha=0.2)
    fig.suptitle("CORD adapter: saved training measurements (not extraction accuracy)")
    fig.tight_layout()
    output.mkdir(parents=True, exist_ok=True)
    fig.savefig(output / "training_curves.png", dpi=180, bbox_inches="tight")
    return fig


def plot_comparison(summary, output=DEFAULT_OUTPUT):
    import matplotlib.pyplot as plt
    rows = summary["summary"]
    if not summary["paired_example_ids"]:
        raise ValueError("No common completed receipts across the requested models; do not plot missing scores as zero.")
    labels = [row["label"].replace(" (item prompt)", "\n(item prompt)") for row in rows]
    fig, axes = plt.subplots(1, 3, figsize=(16, 5))
    for axis, key, title in zip(axes, ("total_accuracy", "item_f1", "schema_valid_rate"),
                                ("Printed total accuracy", "Main item micro F1", "Valid target schema")):
        values = [row[key] for row in rows]
        positions = [index for index, value in enumerate(values) if value is not None]
        axis.bar(positions, [values[index] for index in positions], color=["#207b98", "#8b9296", "#c05c23"][:len(positions)])
        if key == "total_accuracy":
            for index in positions:
                value, low, high = values[index], rows[index]["total_ci_low"], rows[index]["total_ci_high"]
                axis.errorbar(index, value, yerr=[[value - low], [high - value]], color="black", capsize=4)
        axis.set(title=title, ylim=(0, 1.15), xticks=range(len(rows)), xticklabels=labels)
        axis.tick_params(axis="x", labelrotation=25)
        axis.grid(axis="y", alpha=0.2)
    fig.suptitle(f"Same {len(summary['paired_example_ids'])} held-out receipts; total bars show 95% Wilson intervals")
    fig.tight_layout()
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    fig.savefig(output / "comparison_accuracy.png", dpi=180, bbox_inches="tight")
    return fig


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cord-adapter", type=Path, default=DEFAULT_CORD)
    parser.add_argument("--old-adapter", type=Path, default=DEFAULT_OLD)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--prepare", action="store_true", help="Download/cache the chosen held-out images.")
    parser.add_argument("--models", nargs="*", choices=list(MODEL_LABELS), default=[])
    parser.add_argument("--limit", type=int, default=10, help="Receipt count for preparation; 0 selects the full test split.")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--image-edge", type=int, default=768)
    parser.add_argument("--max-new-tokens", type=int, default=2048)
    parser.add_argument("--gemini-model", default="gemini-3.5-flash-lite")
    parser.add_argument("--gemini-delay", type=float, default=13)
    parser.add_argument("--retry-errors", action="store_true", help="Retry cached operational errors; may consume more API quota.")
    args = parser.parse_args()
    audit = training_audit(args.cord_adapter)
    write_json(args.output / "training_audit.json", audit)
    print(json.dumps(audit, indent=2))
    if args.prepare:
        prepare_examples(args.cord_adapter, args.output, args.limit, args.seed)
    if args.models:
        summary = run_benchmark(args.output, args.models, args.cord_adapter, args.old_adapter,
                                args.image_edge, args.max_new_tokens, args.gemini_model, args.gemini_delay, args.retry_errors)
        print(json.dumps(summary["summary"], indent=2))


if __name__ == "__main__":
    main()

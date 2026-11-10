# Finance Management

Receipt extraction for a finance management application, with **Gemini as the current provider** and local model research kept in a separate experiment area.

The main workflow reads a receipt image and returns **purchased items and the final total**. It is available as a command-line tool and a reusable Python package. The backend, frontend, category classifier, and expense database are planned; their application folders are placeholders.

## Quick start: Gemini extraction

Use Python 3.11 or newer. Run installation commands from the repository root.

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements/application.txt
cp .env.example .env
```

Edit `.env`:

```dotenv
GEMINI_API_KEY=your_gemini_api_key_here
GEMINI_MODEL=gemini-3.5-flash-lite
```

The API key is read from the root `.env` file when you create the extractor. Existing environment variables take precedence. Run one extraction:

```bash
receipt-extract path/to/receipt.jpg --output results/receipt.json
```

The equivalent module command is:

```bash
python -m receipt_extraction path/to/receipt.jpg --output results/receipt.json
```

Receipt JSON is printed to stdout, and token usage to stderr. An API request sends the image to Google. Model access, free-tier quotas, pricing, and data handling depend on your project and Google's current terms. The application does not enforce a billing limit.

Useful options:

```bash
receipt-extract --help
receipt-extract receipt.jpg --env-file /path/to/.env
receipt-extract receipt.jpg --max-image-edge 1600 --max-output-tokens 2048
```

## Output contract

All future extraction providers should return this structure:

```json
{
  "items": [
    {
      "description": "Example item",
      "quantity": "2",
      "unit_price": "3.50",
      "line_total": "7.00",
      "sub_items": []
    }
  ],
  "total": "7.00"
}
```

Missing values are `null`. Modifiers or subitems use the same item structure inside `sub_items`. Amounts retain their printed separators and precision as strings. Item amounts do not necessarily sum to the final total when taxes, discounts, service charges, or rounding apply.

The package validates the required fields, types, nesting, and JSON completeness. **A valid structure does not prove that the numbers were read correctly.** User review and amount reconciliation are still needed before saving financial records. Categories are not assigned by the current extractor.

The new application entry point focuses on items and totals. The previous company/date/address/total workflow and its model-reported scores are preserved under `experiments/legacy_headers/`.

## Repository layout

```text
apps/
  backend/                        Future API, expense storage, application logic
  frontend/                       Future receipt review and finance interface
packages/
  receipt_extraction/
    providers/gemini.py           Current hosted extraction provider
    interfaces.py                 Provider interface and extraction result
    schemas.py                    Common receipt/item definitions and API schema
    validation.py                 Structural checks and explicit decimal parsing
    config.py                     Root .env loading and project paths
    cli.py                        receipt-extract command
experiments/
  smolvlm/
    inference.py                  Optional local 4-bit inference
    notebooks/
      sroie_training.ipynb        Original four-field A100 training
      cord_training.ipynb         CORD-only item/total A100 training
  benchmarks/
    receipt_benchmark.py          Cached, held-out comparison runner
    notebooks/
      model_comparison.ipynb      Training curves and comparison visualizations
  legacy_headers/
    gemini_inference.py           Previous four-field Gemini CLI
  shared/
    receipt_confidence.py         Experimental confidence utilities
requirements/
  application.txt                 Editable package install; no GPU stack
  experiments.txt                 Optional model/benchmark environment
  requirements-gemini.txt         Legacy standalone Gemini dependencies
  requirements-benchmark.txt      Optional benchmark dependencies
  requirements.txt               Historical model-development package snapshot
tests/                           Unit tests and optional model experiment tests
```

Local `dataset/`, `model/`, `outputs/`, and `results/` directories hold data and generated artifacts and are ignored by Git. Keep API keys and receipt images outside version control as configured in `.gitignore`.

## Reuse from the future backend

Install the package in the backend environment, then call the provider through its extraction interface:

```python
from receipt_extraction import GeminiReceiptExtractor, ReceiptExtractor


def read_receipt(extractor: ReceiptExtractor, image_path):
    result = extractor.extract(image_path)
    return result.to_dict()


with GeminiReceiptExtractor.from_env() as extractor:
    result = read_receipt(extractor, "receipt.jpg")

print(result["receipt"])
print(result["usage"])
```

`ExtractionResult` separates the common receipt payload from provider/model metadata and token usage. A future local provider can implement `extract(image_path)` and return the same result type. The application should depend on that contract; experiments should not be imported into backend startup.

The API key belongs in the backend environment. The future frontend should submit images to the backend and display values for review. API routes, authentication, storage, category classification, and the interface have not been implemented yet; no frontend or backend framework is assumed by this repository.

For known currency conventions, the validation module provides exact decimal parsing:

```python
from receipt_extraction.validation import parse_amount

amount = parse_amount("436.20", decimal_separator=".", thousands_separator=",")
```

It rejects malformed grouping such as `3,26000.00` under that convention. It does not guess whether `20.000` means twenty or twenty thousand, correct an OCR reading, or reconcile a receipt automatically. Supply the convention explicitly and keep the original printed values.

## Optional model experiments

The Gemini application does not require PyTorch, transformers, PEFT, or a CUDA GPU. Install a separate environment with a compatible PyTorch build for model work, then:

```bash
python -m pip install -r requirements/experiments.txt
```

`requirements/requirements.txt` is the historical environment snapshot, including CUDA-specific packages. Use it as a reproducibility reference when needed.

Run experiment modules from the repository root. Notebooks locate the root when opened from their own subdirectories; the training notebooks can also run standalone on an A100.

### SmolVLM inference

Keep the complete trained exports in `model/`. The earlier SROIE adapter remains the experimental inference default:

```bash
python -m experiments.smolvlm.inference receipt.jpg --no-confidence
```

Select the CORD item adapter explicitly:

```bash
python -m experiments.smolvlm.inference receipt.jpg \
  --adapter model/smolvlm-cord-items-lora --no-confidence
```

The confidence utilities were designed for flat receipt fields, so use `--no-confidence` with nested item output. Local inference uses a 4-bit base and requires compatible CUDA/bitsandbytes support. Resolution and output length affect memory and accuracy; A100 training does not establish performance on a local 4 GB GPU.

### Training notebooks

- [SROIE training](experiments/smolvlm/notebooks/sroie_training.ipynb): company, date, address, and total. Uses local `dataset/SROIE2019`.
- [CORD training](experiments/smolvlm/notebooks/cord_training.ipynb): items, subitems, prices, and total. Downloads only CORD v1/v2, deduplicates matching images, and prefers v2 labels. Ambiguous training labels are quarantined with a report; structural or hold-out conversion errors stop the run.

Both create separate adapters under `outputs/` and preserve a 768-pixel image setting. Start with `MAX_STEPS = 5` before a full A100 training run. No model is promoted into the application automatically.

The downloaded CORD export records three epochs and 300 optimizer updates. Validation token loss decreased from 0.2024 to 0.1730. This is not extraction accuracy; observed failures on real receipts are why Gemini is the current application provider.

### Benchmark and visualizations

Open [the model comparison notebook](experiments/benchmarks/notebooks/model_comparison.ipynb) to view saved training curves and inspect cached comparison results. Its execution flags default to `False`; enable them when you intend to download images or run inference/API requests.

Run a fresh ten-receipt comparison with:

```bash
python -m experiments.benchmarks.receipt_benchmark --prepare --limit 10 \
  --models cord_smolvlm sroie_smolvlm gemini
```

This uses the same held-out CORD receipts and item prompt across the three models. The older SROIE adapter is a task-transfer baseline. Outputs are cached, quota failures stop further Gemini requests, and operational failures remain visible. A completed fresh ten-receipt run sends ten Gemini requests.

The complete `results/model_comparison/` folder contains cached predictions, image/reference provenance, metrics, token usage, and charts. Copy this folder back from the A100 to visualize results locally. A100 latency and memory measurements describe the A100, not the deployment GPU. Evaluate on representative labeled user receipts before selecting a model or acceptance threshold.

### Previous four-field Gemini workflow

The original API workflow remains available for comparison:

```bash
python -m experiments.legacy_headers.gemini_inference receipt.jpg --no-confidence
```

Omit `--no-confidence` for the preserved model-reported scores. These scores are uncalibrated and do not establish correctness.

## Tests

Application tests need only the lightweight application environment. They use mocks and do not send API requests:

```bash
python -m unittest discover -s tests/unit -v
```

With the optional experiment dependencies installed, run the complete suite:

```bash
python -m unittest discover -s tests -v
```

Model tests do not train a model or require a GPU. They test conversion, parsing, stopping, score alignment, request configuration, cache behavior, and evaluation calculations. Actual extraction accuracy requires labeled receipts and live inference.

## Local documentation and Git

`README.md` contains the public setup and usage instructions. Additional `docs/` notes are local working material. Exclude them in each checkout through `.git/info/exclude`:

```bash
printf '\n/docs/\n' >> .git/info/exclude
```

This local rule is not pushed to GitHub. README remains trackable, and the shared `.gitignore` contains no docs rule. Local excludes do not remove files that were already tracked.

## Next application work

Implement receipt review/correction, currency-aware reconciliation, item category classification, and expense storage behind the extraction contract. Add the backend and frontend after choosing their frameworks. Keep the Gemini provider as the working baseline while experimenting with other models independently.

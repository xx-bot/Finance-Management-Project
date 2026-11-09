# Finance Management Project

A project in the model development stage, exploring receipt extraction as a foundation for future finance management software.

The current implementation extracts **company, date, address, and total** from receipt images. It provides a fine-tuned SmolVLM inference pipeline for a local GPU and a Gemini API alternative. The application itself has not been implemented yet.

## Current progress

| Component | Status |
| --- | --- |
| SmolVLM LoRA training notebook | Implemented; configured for a single A100 |
| Local trained adapter | Available locally; excluded from Git |
| SmolVLM inference | Implemented with 4-bit loading for a local CUDA GPU |
| Gemini inference | Implemented using an API key from `.env` |
| Field scores | Implemented, with the scoring method included in the output |
| Regression tests | Implemented for parsing, scoring, stopping, and API request configuration |
| Software integration | Planned |

The next stage is to integrate receipt extraction into software, including a way to review extracted values before using them in financial records. Application architecture, storage, and user interface choices are still open.

## Project structure

```text
notebook.ipynb              SmolVLM training and evaluation on an A100
smolvlm_inference.py        Local receipt inference using the trained adapter
gemini_inference.py         Hosted receipt inference using Gemini
receipt_confidence.py      Shared score formatting and token-to-field alignment
requirements.txt           Package snapshot from the model development environment
requirements-gemini.txt    Dependencies for the Gemini script
.env.example               Example API-key configuration
tests/                     Automated regression tests
dataset/                   Local datasets; ignored by Git
model/                     Local trained adapter and processor; ignored by Git
```

## Setup

Run commands from the project directory. Python 3.11 is used by the existing model environment.

```bash
python3 -m venv .venv
source .venv/bin/activate
```

Choose either inference path below, or install dependencies for both. `requirements.txt` records the existing development environment, including CUDA-specific packages; it may need adjustments for another machine.

## Local SmolVLM inference

Install a CUDA-enabled PyTorch build compatible with your NVIDIA driver, then install the inference dependencies:

```bash
pip install transformers peft accelerate bitsandbytes pillow
```

The script uses `HuggingFaceTB/SmolVLM-Base` with the trained LoRA adapter. Put the complete adapter export in:

```text
model/smolvlm-receipt-lora/
```

Keep all exported files together, including `adapter_model.safetensors`, `adapter_config.json`, `deployment_config.json`, tokenizer files, and processor configuration. These files are not included in Git; obtain them from the training export. The base model downloads on first use unless it is already cached.

```bash
python smolvlm_inference.py path/to/receipt.jpg
mkdir -p results
python smolvlm_inference.py path/to/receipt.jpg --output results/smolvlm.json
```

The default image setting is 768 pixels on the longest edge. The pipeline targets the existing 4 GB GPU workflow, but available memory and input size affect whether a receipt fits. `--no-confidence` reduces score-related memory use; `--image-longest-edge 384` reduces image memory use and may lower extraction accuracy. `--offline` requires the base model to already be cached.

### Training

Open `notebook.ipynb` on a single A100 with the dataset at `dataset/SROIE2019`. The notebook expects `train/` and `test/` splits, each with matching `img/*.jpg` and `entities/*.txt` JSON annotations.

Training uses BF16 LoRA, batch size 4, and two gradient accumulation steps. Set `MAX_STEPS = 5` for a smoke test. The export is written to `smolvlm-receipt-lora/`; copy the entire folder into the local `model/` directory for inference. The adapter stays separate from the base model, which is loaded in 4-bit for local inference.

## Gemini API inference

```bash
pip install -r requirements-gemini.txt
cp .env.example .env
```

Edit `.env` and insert your key:

```dotenv
GEMINI_API_KEY=your_gemini_api_key_here
```

Use a key from a Free Tier project if you intend to use the free tier. Model access and quotas depend on the project; check Google AI Studio for current availability and limits. The script does not enforce billing limits.

```bash
python gemini_inference.py path/to/receipt.jpg
python gemini_inference.py path/to/receipt.jpg --output results/gemini.json
```

The current default is `gemini-3.5-flash-lite`. Each call sends the image to Google, requests structured JSON, and prints token usage to stderr. It requires internet access and does not use the local SmolVLM adapter or GPU. The API key is read from the `.env` file beside the script; an existing `GEMINI_API_KEY` environment variable takes precedence.

## Output and field scores

Both scripts return this structure, with all four fields included:

```json
{
  "fields": {
    "company": {"value": "Example Store", "score": 0.85},
    "date": {"value": "09/11/2026", "score": 0.81},
    "address": {"value": "123 Example Street", "score": 0.72},
    "total": {"value": "77.83", "score": 0.92}
  },
  "score_method": "geometric_mean_token_probability",
  "calibrated": false
}
```

These values are illustrative. SmolVLM calculates the geometric mean probability of generated tokens overlapping each field's value. Gemini returns its own assessment of each field, labeled `model_self_report`; this is not a token-probability score. Empty values receive `null` scores. SmolVLM also returns `null` when it cannot align value tokens reliably.

**Scores are not calibrated probabilities of correctness, and the two methods are not directly comparable.** Validate extraction accuracy on labeled receipts before setting thresholds for automatic acceptance in the future software.

Add `--no-confidence` to either command to return the original flat JSON object containing only `company`, `date`, `address`, and `total`.

## Tests

With dependencies for both inference paths installed:

```bash
python -m unittest discover -s tests -v
```

The tests use synthetic inputs and mocked model/API responses. They do not require a GPU, send API requests, or establish extraction accuracy on real receipts.

## Files excluded from Git

`.gitignore` excludes API secrets, virtual environments, datasets, trained model artifacts, root-level receipt images, generated results, and caches. `.env.example`, code, dependency files, tests, and the training notebook remain trackable. Clear notebook outputs before sharing if they contain receipt data or credentials.

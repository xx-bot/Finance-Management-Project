# Finance Management

Receipt extraction and a Flutter mobile finance app, with **Gemini as the current extraction provider** and local model research kept in a separate experiment area.

The Python package reads a receipt image and returns **purchased items and the final total**. The mobile app provides expense tracking, receipt review, budgets, and category insights with local SQLite storage. The backend that connects mobile scans to Gemini is the next step; it has not been implemented. Item categories are currently selected by the user.

## Mobile app: Flutter

[apps/frontend](apps/frontend) contains **Pocket Ledger**, an Android/iOS app with a warm green interface inspired by Copilot Money's personal finance views and Ramp's receipt review workflow.

- Home: monthly spending, budget progress, recent expenses, and receipts needing review.
- Expenses: merchant/item search, month and category filters, editing, and deletion.
- Scan: camera/gallery selection, photo preview, and a sample receipt flow.
- Review: editable items, quantities, prices, categories, tax/discount adjustments, and final total.
- Insights: spending charts based on recorded expenses and item categories.
- Settings: IDR/MYR/USD ledgers, monthly budgets, CSV copy, and sample data controls.

### Run the app

Install the [Flutter SDK](https://docs.flutter.dev/install) and run `flutter doctor`. The project requires Flutter 3.35+ and Dart 3.9+. Android needs the Android toolchain, a compatible JDK (17 or later for the generated Gradle 9 runner), and an emulator or connected phone. iOS builds require macOS and Xcode.

From the repository root:

```bash
python3 apps/frontend/tool/bootstrap.py --check
cd apps/frontend
flutter devices
```

Start an Android emulator or connect an Android phone before launching the app. If `flutter devices` lists only Linux, Flutter currently sees your desktop, which this mobile project does not target.

- **Emulator:** in Android Studio, open **Tools → Device Manager**, create a phone virtual device if needed, and start it using the play button. Run `flutter devices` again after it finishes booting.
- **Phone:** enable Developer options and USB debugging, connect it by USB, and accept the debugging authorization on the phone. Run `flutter devices` to confirm it appears.

From `apps/frontend`, launch using the Android device ID printed by `flutter devices`:

```bash
flutter run -d YOUR_ANDROID_DEVICE_ID
```

Replace `YOUR_ANDROID_DEVICE_ID` with the actual ID, for example `emulator-5554`. If Android tooling is missing, run `flutter doctor -v` and follow the [Flutter Android setup guide](https://docs.flutter.dev/platform-integration/android/setup). Generating a Linux runner does not configure an Android device; desktop support would also need compatible storage and camera implementations.

The bootstrap creates missing Android/iOS platform runners using your installed Flutter SDK, configures camera/photo descriptions and Android network access, resolves packages, formats Dart, and runs analysis and tests. It preserves the app's `lib/`, `test/`, and `pubspec.yaml`. Commit the generated platform runners and `pubspec.lock` after setup to make subsequent checkouts reproducible.

If Gradle reports that it is running on Java 11, check `flutter doctor -v` for the Java version Flutter selected. `JAVA_HOME` can still point to Java 11 even when `java -version` reports a newer installation. Point Flutter explicitly to a compatible installed JDK. For example, on Ubuntu with OpenJDK 17 installed at the usual path:

```bash
flutter config --jdk-dir=/usr/lib/jvm/java-17-openjdk-amd64
flutter doctor -v
```

Use the JDK path on your machine. This setting applies to all Flutter projects for your user. Restart VS Code after changing it, then retry `flutter run -d YOUR_ANDROID_DEVICE_ID`. See [Flutter's Java selection instructions](https://docs.flutter.dev/release/breaking-changes/android-java-gradle-migration-guide#solution-2-command-line). The Java/Kotlin compile target in the app does not select the JVM that launches Gradle.

### Missing Android tools or NDK license

If `flutter doctor -v` reports missing `cmdline-tools` and the build reports an unaccepted NDK license, install the command-line tools before running license commands. An SDK containing only `platform-tools` provides ADB but does not contain the Android build toolchain.

For a VS Code setup without Android Studio, download the **Linux command-line tools ZIP** from the [official Android downloads page](https://developer.android.com/studio#command-line-tools-only). Review its terms when downloading. Use an SDK directory owned by your user, such as `~/Android/Sdk`, so package installation does not need changes to `/usr/lib/android-sdk`.

For the currently published Linux ZIP, after downloading it to `~/Downloads`:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
mkdir -p "$ANDROID_HOME/cmdline-tools"
unzip "$HOME/Downloads/commandlinetools-linux-15859902_latest.zip" -d "$ANDROID_HOME/cmdline-tools"
mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
```

These extraction commands assume a fresh SDK directory. Use the filename you downloaded if Google has updated it, and the JDK path installed on your machine. The resulting executable must be at `~/Android/Sdk/cmdline-tools/latest/bin/sdkmanager`.

Install the packages requested by Flutter 3.47.x:

```bash
sdkmanager --sdk_root="$ANDROID_HOME" --licenses
sdkmanager --sdk_root="$ANDROID_HOME" --install \
  "platform-tools" "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358"
flutter config --android-sdk "$ANDROID_HOME"
flutter doctor -v
```

The license command is interactive: read each agreement and accept it if you agree. Keep these commands in the same terminal so the exported variables apply. Flutter's SDK selection persists; restart VS Code after changing it. Then retry `flutter run -d YOUR_ANDROID_DEVICE_ID` from `apps/frontend`. The missing Chrome and Linux desktop tooling checks do not block an Android phone build. See the [SDK Manager instructions](https://developer.android.com/tools/sdkmanager) and [NDK version installation guide](https://developer.android.com/studio/projects/install-ndk#install-specific-version).

### Xiaomi/Redmi/POCO installation blocked

If the APK builds successfully but deployment ends with `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`, check the phone's installation permissions. Open **Settings → Additional settings → Developer options**, enable **Install via USB**, keep **USB debugging** enabled, and complete the phone's confirmation prompts. Then unlock the phone, retry `flutter run -d YOUR_ANDROID_DEVICE_ID`, and approve the Pocket Ledger installation prompt when it appears. Menu names can vary by MIUI/HyperOS version. See the [Xiaomi installation settings in Digital.ai's device setup documentation](https://docs.digital.ai/continuous-testing/docs/sta/seetest-automation-home/seetestautomation-how-to/seetestautomation-connecting-devices-and-emulators/seetestautomation-connecting-real-physical-devices/seetestautomation-connecting-an-android-device/connect-xiaomi-device).

### Try the app

The app starts with clearly labeled **sample data**, which stays separate from personal expenses. Try **Scan → Try a sample receipt → Save sample expense** to explore the flow without a backend or API key. Use **Settings → Start tracking my expenses** or **Add expense** to start your own ledger. Personal expenses and receipt copies persist on the device; sample edits last only for that app session. There is no account or cloud synchronization yet.

### Connect receipt extraction later

Manual entry and sample scans work immediately after Flutter setup. Real image extraction requires the backend. The frontend already calls this proposed interface:

```http
POST /api/receipts/extract
Content-Type: multipart/form-data

image: <receipt image file>
```

Return the receipt JSON shown below, either directly or under `{"receipt": ...}` as returned by `ExtractionResult.to_dict()`. The review screen asks for merchant, date, currency, and categories because the current extraction contract contains items and total only.

Once a backend implements that route, supply its base URL:

```bash
flutter run --dart-define=API_BASE_URL=https://your-backend.example
# Android emulator with a backend running on the host machine:
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

Android debug builds allow local HTTP development; use HTTPS for deployed services and iOS. The URL is a build-time setting. **Keep `GEMINI_API_KEY` in the backend `.env`; never put it in Flutter assets or `--dart-define`.** A configured URL indicates setup, not a successful health check. Backend authentication and deployment remain to be implemented.

Before saving, the user must confirm the printed number convention (`1,234.56` or `1.234,56`). Malformed grouping such as `3,26000.00` is rejected. Missing item amounts or totals are not inferred. Differences between items, adjustments, and the final total require correction or explicit acknowledgment. Nested subitems are retained and displayed as details; independent subitem editing is future work. Currency ledgers stay separate without exchange-rate conversion. Category charts allocate the paid total proportionally across item categories, including tax and discounts.

### Frontend code map

```text
apps/frontend/
  lib/
    main.dart                     App entry point and backend URL
    app.dart                      Initialization, navigation, dependency wiring
    core/money.dart               Exact amount parsing and currency formatting
    models/                       Saved expenses and editable receipt drafts
    data/                         SQLite repository and isolated sample fixtures
    services/                     Backend extraction client and camera/gallery
    state/                        Ledger operations, budgets, filters, export
    ui/
      theme.dart                  Shared colors, typography, component styles
      components/                 Cards, receipt preview, category picker, charts
      screens/                    Home, expenses, scan, review, insights, settings
  test/                           Financial validation, state, HTTP, widget tests
  tool/bootstrap.py               Generate/configure native platform runners
```

Screens depend on `ReceiptService` and `LedgerRepository`, so a future extraction provider or storage implementation can be connected without putting model experiment code into the mobile UI.

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
  backend/                        Future API and hosted application logic
  frontend/                       Flutter mobile app; local SQLite expense storage
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

The API key belongs in the backend environment. The Flutter frontend is prepared to submit images to the backend and display values for review. API routes, authentication, server storage, and automated category classification have not been implemented; the mobile app currently stores reviewed expenses locally.

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

After Flutter setup, run the mobile tests separately:

```bash
cd apps/frontend
flutter analyze --no-fatal-infos
flutter test
```

These tests use sample data, an in-memory repository, and mocked HTTP responses. They cover strict money parsing, amount reconciliation, category allocation, sample/personal separation, save retries, backend response handling, and the sample scan/review flow. Native camera permissions and SQLite persistence also need checks on an emulator or phone.

## Local documentation and Git

`README.md` contains the public setup and usage instructions. Additional `docs/` notes are local working material. Exclude them in each checkout through `.git/info/exclude`:

```bash
printf '\n/docs/\n' >> .git/info/exclude
```

This local rule is not pushed to GitHub. README remains trackable, and the shared `.gitignore` contains no docs rule. Local excludes do not remove files that were already tracked.

## Next application work

Implement the backend extraction route using `packages/receipt_extraction`, then connect and test real mobile scans. Add authentication, server storage/sync, and automated item category suggestions as needed. Keep user review before saving financial records and Gemini as the working baseline while experimenting with other models independently.

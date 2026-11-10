"""Command-line entry point for the current Gemini items-and-total workflow."""

import argparse
import json
from pathlib import Path
import sys

from .providers.gemini import GeminiReceiptExtractor


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--env-file", type=Path, help="Defaults to the project root .env")
    parser.add_argument("--model", help="Defaults to GEMINI_MODEL or gemini-3.5-flash-lite")
    parser.add_argument("--max-output-tokens", type=int, default=2048)
    parser.add_argument("--max-image-edge", type=int, default=1600)
    args = parser.parse_args(argv)
    if not args.image.is_file():
        parser.error(f"Image does not exist: {args.image}")
    if args.max_output_tokens < 1 or args.max_image_edge < 1:
        parser.error("Output token limit and image size must be positive")
    try:
        with GeminiReceiptExtractor.from_env(env_file=args.env_file, model=args.model,
                                             max_output_tokens=args.max_output_tokens,
                                             max_image_edge=args.max_image_edge) as extractor:
            result = extractor.extract(args.image)
        text = json.dumps(result.receipt, ensure_ascii=False, indent=2)
        if args.output is not None:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(text + "\n", encoding="utf-8")
    except (OSError, RuntimeError, ValueError) as exc:
        parser.exit(1, f"Error: {exc}\n")
    print(text)
    print("Token usage: " + json.dumps(result.usage), file=sys.stderr)

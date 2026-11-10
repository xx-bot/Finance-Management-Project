"""Repository paths and explicit environment loading, independent of the working directory."""

import os
from pathlib import Path


def project_root():
    for start in (Path.cwd(), Path(__file__).resolve().parent):
        for candidate in (start, *start.parents):
            if (candidate / "pyproject.toml").is_file() and (candidate / "packages/receipt_extraction").is_dir():
                return candidate
    return Path.cwd()


def load_api_key(env_file=None):
    from dotenv import load_dotenv

    path = Path(env_file) if env_file is not None else project_root() / ".env"
    load_dotenv(path, override=False)
    key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not key or key == "your_gemini_api_key_here":
        raise ValueError(f"Set GEMINI_API_KEY in your environment or {path}")
    return key

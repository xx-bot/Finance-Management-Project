"""Application-facing extraction API. Imports do not load models or read API keys."""

from .interfaces import ExtractionResult, ReceiptExtractor
from .providers.gemini import GeminiReceiptExtractor

__all__ = ["ExtractionResult", "GeminiReceiptExtractor", "ReceiptExtractor"]

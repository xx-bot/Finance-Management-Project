"""Contract a future local model can implement without changing the application."""

from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Protocol

from .schemas import Receipt


@dataclass
class ExtractionResult:
    receipt: Receipt
    provider: str
    model: str
    usage: dict[str, int | None] = field(default_factory=dict)
    model_version: str | None = None

    def to_dict(self):
        return asdict(self)


class ReceiptExtractor(Protocol):
    def extract(self, image_path: str | Path) -> ExtractionResult:
        """Extract one receipt and return the common validated structure."""
        ...

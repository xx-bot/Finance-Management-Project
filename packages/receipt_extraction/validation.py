"""Validate structure without guessing currency conventions or correcting amounts."""

import json
from decimal import Decimal
import re

from .schemas import ITEM_FIELDS, Receipt


class ReceiptValidationError(ValueError):
    pass


def validate_receipt(value) -> Receipt:
    if not isinstance(value, dict) or set(value) != {"items", "total"}:
        raise ReceiptValidationError("Expected exactly items and total")
    if value["total"] is not None and not isinstance(value["total"], str):
        raise ReceiptValidationError("Total must be a printed string or null")

    def check_items(items, depth=0):
        if not isinstance(items, list) or depth > 8:
            raise ReceiptValidationError("Invalid item list or excessive subitem depth")
        for item in items:
            if not isinstance(item, dict) or set(item) != ITEM_FIELDS:
                raise ReceiptValidationError("Item has missing or unexpected fields")
            if any(item[key] is not None and not isinstance(item[key], str)
                   for key in ITEM_FIELDS - {"sub_items"}):
                raise ReceiptValidationError("Item values must be printed strings or null")
            check_items(item["sub_items"], depth + 1)

    check_items(value["items"])
    return value


def parse_receipt(text) -> Receipt:
    try:
        value = json.loads(text)
    except (json.JSONDecodeError, TypeError) as exc:
        raise ReceiptValidationError("Model returned invalid or incomplete receipt JSON") from exc
    return validate_receipt(value)


def valid_schema(value):
    try:
        validate_receipt(value)
    except ReceiptValidationError:
        return False
    return True


def parse_amount(text, *, decimal_separator, thousands_separator=None):
    """Parse a printed amount only when the caller supplies its currency/locale convention.

    No automatic conversion is used during extraction. A valid amount can still be
    a wrong reading; reconciliation and human review belong in application logic.
    """
    if decimal_separator not in (".", ","):
        raise ValueError("decimal_separator must be '.' or ','")
    if thousands_separator not in (None, ".", ",") or thousands_separator == decimal_separator:
        raise ValueError("Use a distinct thousands separator or None")
    if not isinstance(text, str):
        raise ReceiptValidationError("Amount must be a string")
    decimal = re.escape(decimal_separator)
    integer = r"\d+"
    if thousands_separator is not None:
        grouping = re.escape(thousands_separator)
        integer = rf"(?:\d+|\d{{1,3}}(?:{grouping}\d{{3}})+)"
    if not re.fullmatch(rf"[+-]?{integer}(?:{decimal}\d+)?", text.strip()):
        raise ReceiptValidationError(f"Invalid amount for the supplied number convention: {text!r}")
    normalized = text.strip()
    if thousands_separator is not None:
        normalized = normalized.replace(thousands_separator, "")
    return Decimal(normalized.replace(decimal_separator, "."))

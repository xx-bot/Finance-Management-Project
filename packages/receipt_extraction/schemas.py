"""Common item/total output contract, also used by the model benchmark."""

from typing import TypedDict

ITEM_FIELDS = {"description", "quantity", "unit_price", "line_total", "sub_items"}


class ReceiptItem(TypedDict):
    description: str | None
    quantity: str | None
    unit_price: str | None
    line_total: str | None
    sub_items: list["ReceiptItem"]


class Receipt(TypedDict):
    items: list[ReceiptItem]
    total: str | None


def item_schema(depth=3):
    if depth < 0 or depth > 8:
        raise ValueError("Subitem schema depth must be between 0 and 8")
    children = ({"type": "array", "items": item_schema(depth - 1)} if depth else
                {"type": "array", "items": {"type": "object"}, "maxItems": 0})
    return {
        "type": "object",
        "properties": {
            **{key: {"anyOf": [{"type": "string"}, {"type": "null"}]}
               for key in sorted(ITEM_FIELDS - {"sub_items"})},
            "sub_items": children,
        },
        "required": sorted(ITEM_FIELDS),
        "additionalProperties": False,
    }


def receipt_schema(depth=3):
    return {
        "type": "object",
        "properties": {"items": {"type": "array", "items": item_schema(depth)},
                       "total": {"anyOf": [{"type": "string"}, {"type": "null"}]}},
        "required": ["items", "total"],
        "additionalProperties": False,
    }

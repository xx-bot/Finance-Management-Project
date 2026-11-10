"""Field scores are uncalibrated indicators, not probabilities of correctness."""

import json
import math
import os


def scored_receipt(fields, method):
    return {"fields": fields, "score_method": method, "calibrated": False}


def value_spans(text):
    """Locate string value contents in the first JSON object, respecting escapes."""
    decoder = json.JSONDecoder()
    i = len(text) - len(text.lstrip())
    if text[i:i + 1] != "{":
        raise ValueError("Expected a JSON object")
    i += 1
    spans = {}
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if text[i:i + 1] == "}":
            return spans
        key, i = decoder.raw_decode(text, i)
        while i < len(text) and text[i].isspace():
            i += 1
        if text[i:i + 1] != ":":
            raise ValueError("Expected a JSON key/value separator")
        i += 1
        while i < len(text) and text[i].isspace():
            i += 1
        start = i
        value, i = decoder.raw_decode(text, i)
        spans[key] = (start + 1, i - 1) if isinstance(value, str) and value else None
        while i < len(text) and text[i].isspace():
            i += 1
        if text[i:i + 1] == ",":
            i += 1
        elif text[i:i + 1] == "}":
            return spans
        else:
            raise ValueError("Expected a JSON object separator")


def token_spans(tokenizer, token_ids, text):
    """Align original generated tokens, including tokens that split UTF-8 characters.

    Re-tokenizing text can produce different token IDs, so decode original prefixes.
    Partial Unicode bytes are grouped with the next token that completes a character.
    """
    spans = [None] * len(token_ids)
    pending, previous = [], 0
    special_ids = set(getattr(tokenizer, "all_special_ids", []))
    for index, token in enumerate(token_ids):
        if token in special_ids:
            continue
        pending.append(index)
        prefix = tokenizer.decode(token_ids[:index + 1], skip_special_tokens=True,
                                  clean_up_tokenization_spaces=False)
        boundary = len(os.path.commonprefix([text, prefix]))
        if boundary < previous:
            # Do not attach probabilities to fields if this decoder rewrites earlier text.
            return [None] * len(token_ids)
        if boundary > previous:
            for token_index in pending:
                spans[token_index] = (previous, boundary)
            pending.clear()
            previous = boundary
    return spans


def score_generated_fields(receipt, text, tokenizer, token_ids, logprobs):
    """Geometric mean probability of tokens overlapping each field's value.

    JSON keys and punctuation-only tokens are excluded. A token crossing a value
    boundary contributes its whole probability. Missing/empty values score null.
    """
    if len(token_ids) != len(logprobs):
        raise ValueError("Generated token IDs and probabilities must have equal lengths")
    tokens = token_spans(tokenizer, token_ids, text)
    values = value_spans(text)
    fields = {}
    for key, value in receipt.items():
        span = values.get(key)
        selected = [prob for token, prob in zip(tokens, logprobs)
                    if span and token and token[0] < span[1] and token[1] > span[0]]
        score = math.exp(sum(selected) / len(selected)) if selected else None
        fields[key] = {"value": value, "score": round(score, 6) if score is not None else None}
    return scored_receipt(fields, "geometric_mean_token_probability")

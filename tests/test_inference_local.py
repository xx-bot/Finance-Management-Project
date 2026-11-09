import json
import unittest

import torch

from smolvlm_inference import parse_receipt, receipt_stopping_criteria


class CharacterTokenizer:
    def decode(self, tokens, **kwargs):
        return "".join(chr(token) for token in tokens.tolist())


class ReceiptOutputTests(unittest.TestCase):
    def test_repeated_objects_and_truncated_tail(self):
        first = {"company": "FRIENDLY RED'S", "date": "07/21/2018",
                 "address": "22 HAVERHILL RD, WINDHAM NH 104/1", "total": "77.83"}
        second = dict(first, date="12/28/2018")
        text = json.dumps(first) + "\n" + json.dumps(second) + '\n{"company": "FRIENDLY RED\''
        self.assertEqual(parse_receipt(text), first)

    def test_nested_object_and_braces_inside_strings(self):
        expected = {"address": 'Store {A}, "North" \\ Road', "extra": {"total": "10"}}
        self.assertEqual(parse_receipt(" \n" + json.dumps(expected) + "\ntrailing text"), expected)

    def test_incomplete_or_non_object_output_still_fails(self):
        for text in ('', '{"company": "unfinished', '[]', 'null', 'not JSON'):
            with self.subTest(text=text), self.assertRaises(RuntimeError):
                parse_receipt(text)

    def test_stops_at_object_end_without_counting_prompt(self):
        prompt = '{"this": "is the prompt"}'
        answer = json.dumps({"company": 'Shop } "A"', "total": "77.83"})
        criteria = receipt_stopping_criteria(CharacterTokenizer(), len(prompt))
        for length in range(len(answer) + 1):
            tokens = torch.tensor([[ord(char) for char in prompt + answer[:length]]])
            stopped = bool(criteria(tokens, scores=None).all().item())
            self.assertEqual(stopped, length == len(answer), f"prefix length {length}")


if __name__ == "__main__":
    unittest.main()

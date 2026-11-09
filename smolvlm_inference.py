"""Extract receipt JSON with the trained adapter on a local CUDA GPU.

CLI: python smolvlm_inference.py receipt.jpg
Python: extractor = ReceiptExtractor(); result = extractor.predict("receipt.jpg")
Dependencies: CUDA PyTorch, transformers, peft, accelerate, bitsandbytes, pillow.
Scores are uncalibrated token probabilities. Use --no-confidence for plain JSON.
"""

import argparse
import json
from pathlib import Path

from receipt_confidence import score_generated_fields

DEFAULT_ADAPTER = Path(__file__).resolve().parent / "model" / "smolvlm-receipt-lora"


def parse_receipt(text):
    """Read the first complete JSON object, allowing trailing model output."""
    try:
        result, _ = json.JSONDecoder().raw_decode(text.lstrip())
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Model returned invalid or incomplete JSON: {text}") from exc
    if not isinstance(result, dict):
        raise RuntimeError(f"Expected a receipt JSON object; model returned: {text}")
    return result


def receipt_stopping_criteria(tokenizer, prompt_length):
    """Stop single-receipt generation once its first JSON object is complete."""
    from transformers import StoppingCriteria, StoppingCriteriaList

    class CompleteReceipt(StoppingCriteria):
        def __call__(self, input_ids, scores, **kwargs):
            text = tokenizer.decode(input_ids[0, prompt_length:], skip_special_tokens=True)
            try:
                parse_receipt(text)
            except RuntimeError:
                return False
            return True

    return StoppingCriteriaList([CompleteReceipt()])


class ReceiptExtractor:
    """Load once, then process receipts one at a time with 4-bit NF4 weights."""

    def __init__(self, adapter=DEFAULT_ADAPTER, *, image_longest_edge=None,
                 max_new_tokens=None, offline=False):
        adapter = Path(adapter)
        config_path = adapter / "deployment_config.json"
        for path in (config_path, adapter / "adapter_config.json", adapter / "adapter_model.safetensors"):
            if not path.is_file():
                raise FileNotFoundError(f"Missing exported model file: {path}")
        config = json.loads(config_path.read_text())
        adapter_config = json.loads((adapter / "adapter_config.json").read_text())
        if config["model_id"] != adapter_config["base_model_name_or_path"]:
            raise ValueError("Deployment and adapter configs refer to different base models.")
        self.max_new_tokens = config["max_new_tokens"] if max_new_tokens is None else max_new_tokens
        longest_edge = config["image_longest_edge"] if image_longest_edge is None else image_longest_edge
        if longest_edge < 1 or self.max_new_tokens < 1:
            raise ValueError("Image size and max-new-tokens must be positive.")

        import torch
        from peft import PeftModel
        from transformers import AutoModelForImageTextToText, AutoProcessor, BitsAndBytesConfig

        if not torch.cuda.is_available():
            raise RuntimeError("4-bit inference requires a local CUDA GPU. Check your NVIDIA driver and CUDA-enabled PyTorch installation.")
        self.device = torch.device("cuda:0")
        self.dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
        quantization = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_use_double_quant=True,
            bnb_4bit_compute_dtype=self.dtype,
        )
        self.processor = AutoProcessor.from_pretrained(adapter, local_files_only=True)
        self.processor.image_processor.size = {"longest_edge": longest_edge}
        base = AutoModelForImageTextToText.from_pretrained(
            config["model_id"],
            quantization_config=quantization,
            dtype=self.dtype,
            attn_implementation="sdpa",
            device_map={"": 0},
            local_files_only=offline,
        )
        self.model = PeftModel.from_pretrained(
            base, adapter, is_trainable=False, autocast_adapter_dtype=False,
        )
        self.model.eval()
        messages = [{"role": "user", "content": [
            {"type": "image"}, {"type": "text", "text": config["question"]},
        ]}]
        self.prompt = self.processor.apply_chat_template(messages, add_generation_prompt=True)

    def predict(self, image_path, *, with_confidence=True):
        """Return field values and uncalibrated token scores (or plain values if disabled)."""
        import torch
        from PIL import Image

        with Image.open(image_path) as image:
            image_rgb = image.convert("RGB")
        inputs = self.processor(text=[self.prompt], images=[[image_rgb]], return_tensors="pt")
        inputs = {
            key: value.to(device=self.device, dtype=self.dtype if value.is_floating_point() else value.dtype)
            for key, value in inputs.items()
        }
        prompt_length = inputs["input_ids"].shape[1]
        # Training ended answers with <end_of_utterance>, which differs from the
        # tokenizer's default EOS. Honor both, plus stop at a complete JSON object.
        tokenizer = self.processor.tokenizer
        eos_ids = set()
        configured_eos = self.model.generation_config.eos_token_id
        if configured_eos is not None:
            eos_ids.update([configured_eos] if isinstance(configured_eos, int) else configured_eos)
        if tokenizer.eos_token_id is not None:
            eos_ids.add(tokenizer.eos_token_id)
        if "<end_of_utterance>" in tokenizer.get_vocab():
            eos_ids.add(tokenizer.convert_tokens_to_ids("<end_of_utterance>"))
        with torch.inference_mode(), torch.autocast(device_type="cuda", dtype=self.dtype):
            output = self.model.generate(
                **inputs, max_new_tokens=self.max_new_tokens, do_sample=False, use_cache=True,
                eos_token_id=sorted(eos_ids) if eos_ids else None,
                stopping_criteria=receipt_stopping_criteria(tokenizer, prompt_length),
                num_beams=1, num_return_sequences=1,
                return_dict_in_generate=with_confidence,
                output_logits=with_confidence,
                output_scores=False,
            )
        sequences = output.sequences if with_confidence else output
        token_ids = sequences[0, prompt_length:].tolist()
        text = tokenizer.decode(token_ids, skip_special_tokens=True, clean_up_tokenization_spaces=False)
        receipt = parse_receipt(text)
        if not with_confidence:
            return receipt
        # Normalize one step at a time rather than stacking vocabulary logits on a 4 GB GPU.
        # Raw logits avoid scores altered by EOS forcing or other generation processors.
        logprobs = []
        for token, logits in zip(token_ids, output.logits):
            step_logits = logits[0].float()
            logprobs.append((step_logits[token] - torch.logsumexp(step_logits, dim=-1)).item())
        return score_generated_fields(receipt, text, tokenizer, token_ids, logprobs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--adapter", type=Path, default=DEFAULT_ADAPTER)
    parser.add_argument("--max-new-tokens", type=int, default=None)
    parser.add_argument("--image-longest-edge", type=int, default=None)
    parser.add_argument("--offline", action="store_true", help="Use only the locally cached base model.")
    parser.add_argument("--no-confidence", action="store_true", help="Return plain fields without scores; reduces memory use.")
    parser.add_argument("--output", type=Path, help="Also save the extracted JSON to this file.")
    args = parser.parse_args()
    if not args.image.is_file():
        parser.error(f"Image does not exist: {args.image}")
    for name in ("max_new_tokens", "image_longest_edge"):
        value = getattr(args, name)
        if value is not None and value < 1:
            parser.error(f"--{name.replace('_', '-')} must be positive.")
    extractor = ReceiptExtractor(
        args.adapter, max_new_tokens=args.max_new_tokens,
        image_longest_edge=args.image_longest_edge, offline=args.offline,
    )
    text = json.dumps(extractor.predict(args.image, with_confidence=not args.no_confidence), ensure_ascii=False, indent=2)
    if args.output is not None:
        args.output.write_text(text + "\n", encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()

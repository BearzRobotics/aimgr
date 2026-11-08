#!/usr/bin/env python3
"""aimgr abliteration helper (runs inside the aimgr-managed venv).

Implements the refusal-direction ablation of Arditi et al. 2024
("Refusal in Language Models Is Mediated by a Single Direction",
arXiv:2406.11717), simplified:

  1. Run two prompt sets (A: prompts models typically refuse, B: ordinary
     prompts) and record the residual-stream activation at the last prompt
     token for one layer.
  2. direction r = normalize(mean(A) - mean(B)).
  3. Orthogonalize every matrix that writes into the residual stream
     (embeddings, attention o_proj, MLP down_proj) against r.

Simplifications versus the paper: the layer is chosen by a fraction of model
depth (--layer-frac), not by searching all layers; refusal is measured by
phrase matching on a few held-out prompts (informational only).

The original model files are never modified: output goes to --out.
Progress lines are plain text prefixed with the stage name.
"""
import argparse
import json
import os
import random
import sys

HARMFUL_REPO = "mlabonne/harmful_behaviors"
HARMFUL_REV = "01cead01398926d81f7c52bdb790ee8cf77ebba7"
HARMLESS_REPO = "mlabonne/harmless_alpaca"
HARMLESS_REV = "02c6a92cfcf11bb0c387334f8146d149d65b587f"
PARQUET = "data/train-00000-of-00001.parquet"
WIKITEXT_REPO = "Salesforce/wikitext"  # CC-BY-SA-3.0 / GFDL; fetched at run time, never bundled
WIKITEXT_REV = "b08601e04326c79dfdd32d625aee71d232d685c3"
WIKITEXT_FILE = "wikitext-2-raw-v1/test-00000-of-00001.parquet"

# Architectures whose module names match the ablation targets below. Others are
# refused rather than guessed (MoE models in particular are not supported).
SUPPORTED = {"llama", "mistral", "qwen2", "qwen3", "gemma", "gemma2"}

REFUSAL_MARKERS = [
    "i'm sorry", "i am sorry", "i cannot", "i can't", "i can’t", "i won't",
    "i will not", "i'm unable", "i am unable", "as an ai", "i apologize",
    "cannot assist", "can't assist", "can't help with", "cannot help with",
    "not able to", "i must decline",
]


def log(stage, msg):
    print(f"[{stage}] {msg}", flush=True)


def die(stage, msg, code=1):
    print(f"[{stage}] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


def mem_available_bytes():
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) * 1024
    except OSError:
        pass
    return None


def cmd_check(_a):
    out = {}
    for mod in ("torch", "transformers", "huggingface_hub", "safetensors", "pyarrow", "numpy"):
        try:
            m = __import__(mod)
            out[mod] = getattr(m, "__version__", "unknown")
        except Exception as e:  # noqa: BLE001
            out[mod] = None
            out[mod + "_error"] = str(e)
    print(json.dumps(out))
    sys.exit(0 if all(out.get(k) for k in ("torch", "transformers", "huggingface_hub", "pyarrow")) else 1)


def cmd_fetch(a):
    from huggingface_hub import snapshot_download
    log("fetch", f"downloading {a.repo}@{a.revision or 'main'} (network)")
    path = snapshot_download(
        repo_id=a.repo,
        revision=a.revision,
        local_dir=a.out,
        allow_patterns=["*.json", "*.safetensors", "*.model", "*.txt", "*.tiktoken", "*.jinja"],
    )
    total = sum(os.path.getsize(os.path.join(path, f)) for f in os.listdir(path) if f.endswith(".safetensors"))
    log("fetch", f"done: {path} ({total/1e9:.2f} GB of safetensors)")
    if total == 0:
        die("fetch", "no .safetensors files in this repo; abliteration needs full-precision safetensors weights (GGUF-only repos cannot be used)")


def read_text_column(path):
    import pyarrow.parquet as pq
    return [str(x) for x in pq.read_table(path, columns=["text"]).column("text").to_pylist() if str(x).strip()]


def load_prompts(a):
    """Return (harmful_train, harmless_train, harmful_holdout)."""
    if a.harmful and a.harmless:
        def read(p):
            with open(p, encoding="utf-8") as f:
                return [ln.strip() for ln in f if ln.strip()]
        harmful, harmless = read(a.harmful), read(a.harmless)
        log("prompts", f"using your files: {len(harmful)} / {len(harmless)} prompts")
    else:
        from huggingface_hub import hf_hub_download
        log("prompts", f"downloading {HARMFUL_REPO}@{HARMFUL_REV[:8]} and {HARMLESS_REPO}@{HARMLESS_REV[:8]} (network)")
        harmful = read_text_column(hf_hub_download(HARMFUL_REPO, PARQUET, repo_type="dataset", revision=HARMFUL_REV))
        harmless = read_text_column(hf_hub_download(HARMLESS_REPO, PARQUET, repo_type="dataset", revision=HARMLESS_REV))
    rng = random.Random(0)  # deterministic selection
    rng.shuffle(harmful)
    rng.shuffle(harmless)
    n, hold = a.n_prompts, a.holdout
    if len(harmful) < n + hold or len(harmless) < n:
        die("prompts", f"need at least {n + hold} refusal-type and {n} ordinary prompts, have {len(harmful)} / {len(harmless)}")
    return harmful[:n], harmless[:n], harmful[n:n + hold]


def chat_ids(tok, prompt):
    msgs = [{"role": "user", "content": prompt}]
    return tok.apply_chat_template(msgs, add_generation_prompt=True, return_tensors="pt", return_dict=True)


def mean_activation(model, tok, prompts, layer, stage):
    import torch
    acc, n = None, 0
    for i, p in enumerate(prompts):
        enc = chat_ids(tok, p)
        with torch.no_grad():
            hs = model(**enc, output_hidden_states=True).hidden_states[layer][0, -1, :].float()
        acc = hs if acc is None else acc + hs
        n += 1
        if (i + 1) % 8 == 0 or i + 1 == len(prompts):
            log(stage, f"{i + 1}/{len(prompts)} prompts")
    return acc / n


def refusal_rate(model, tok, prompts, stage):
    import torch
    refused = 0
    for i, p in enumerate(prompts):
        enc = chat_ids(tok, p)
        with torch.no_grad():
            out = model.generate(**enc, max_new_tokens=32, do_sample=False)
        text = tok.decode(out[0, enc["input_ids"].shape[1]:], skip_special_tokens=True).lower()
        if any(m in text for m in REFUSAL_MARKERS):
            refused += 1
        log(stage, f"{i + 1}/{len(prompts)}")
    return refused / max(len(prompts), 1)


def orthogonalize(model, r):
    import torch
    r = r.to(torch.float32)
    changed = 0
    with torch.no_grad():
        for name, mod in model.named_modules():
            w = getattr(mod, "weight", None)
            if w is None or w.ndim != 2:
                continue
            if name.endswith("embed_tokens"):            # [vocab, hidden]
                w32 = w.float()
                w.copy_((w32 - (w32 @ r)[:, None] * r[None, :]).to(w.dtype))
            elif name.endswith("o_proj") or name.endswith("down_proj"):  # [hidden, in]
                w32 = w.float()
                w.copy_((w32 - r[:, None] * (r @ w32)[None, :]).to(w.dtype))
                b = getattr(mod, "bias", None)
                if b is not None:
                    b32 = b.float()
                    b.copy_((b32 - r * (r @ b32)).to(b.dtype))
            else:
                continue
            changed += 1
    return changed


def cmd_abliterate(a):
    import torch
    from transformers import AutoConfig, AutoModelForCausalLM, AutoTokenizer

    cfg = AutoConfig.from_pretrained(a.model_dir)
    mt = getattr(cfg, "model_type", "?")
    if mt not in SUPPORTED:
        die("check", f"model_type '{mt}' is not supported (supported: {', '.join(sorted(SUPPORTED))}); refusing to guess module names")
    if any(getattr(cfg, k, None) for k in ("num_experts", "num_local_experts", "n_routed_experts")):
        die("check", "mixture-of-experts models are not supported")

    size = sum(os.path.getsize(os.path.join(a.model_dir, f)) for f in os.listdir(a.model_dir) if f.endswith(".safetensors"))
    avail = mem_available_bytes()
    log("check", f"model_type={mt}, weights {size/1e9:.2f} GB, MemAvailable {(avail or 0)/1e9:.1f} GB")
    if avail is not None and size * 1.5 > avail and not a.force:
        die("check", f"needs about {size*1.5/1e9:.1f} GB of RAM but only {avail/1e9:.1f} GB is available (use --force to try anyway)")

    harm, harmless, holdout = load_prompts(a)

    tok = AutoTokenizer.from_pretrained(a.model_dir)
    if tok.chat_template is None:
        die("check", "tokenizer has no chat template; use an instruct/chat model")
    log("load", "loading model in bfloat16 on CPU")
    model = AutoModelForCausalLM.from_pretrained(a.model_dir, torch_dtype=torch.bfloat16, low_cpu_mem_usage=True)
    model.eval()

    n_layers = cfg.num_hidden_layers
    layer = max(1, min(n_layers, int(round(a.layer_frac * n_layers))))
    log("direction", f"using layer {layer} of {n_layers} (fraction {a.layer_frac})")
    mh = mean_activation(model, tok, harm, layer, "direction-A")
    ml = mean_activation(model, tok, harmless, layer, "direction-B")
    r = mh - ml
    norm = r.norm().item()
    if norm == 0:
        die("direction", "zero difference between prompt sets; cannot compute a direction")
    r = r / norm
    log("direction", f"difference norm {norm:.3f}")

    before = refusal_rate(model, tok, holdout, "before") if a.holdout else None
    changed = orthogonalize(model, r)
    log("apply", f"orthogonalized {changed} weight matrices against the direction")
    after = refusal_rate(model, tok, holdout, "after") if a.holdout else None
    if before is not None:
        log("result", f"refusal-phrase rate on {len(holdout)} held-out prompts: before {before:.0%}, after {after:.0%} (phrase matching, informational)")

    os.makedirs(a.out, exist_ok=True)
    log("save", f"writing {a.out}")
    model.save_pretrained(a.out, safe_serialization=True)
    tok.save_pretrained(a.out)
    with open(os.path.join(a.out, "aimgr-abliteration.json"), "w") as f:
        json.dump({
            "method": "refusal-direction orthogonalization (Arditi et al. 2024, simplified)",
            "source_dir": os.path.abspath(a.model_dir), "layer": layer, "n_layers": n_layers,
            "n_prompts": a.n_prompts, "prompt_sources": "user files" if a.harmful else {
                HARMFUL_REPO: HARMFUL_REV, HARMLESS_REPO: HARMLESS_REV},
            "refusal_rate_before": before, "refusal_rate_after": after,
        }, f, indent=2)
    log("done", "abliterated weights saved")


# Ollama (Go template) chat formats, chosen from markers in the model's own HF
# chat template. Constants only: no model-supplied text is ever put in a Modelfile.
TEMPLATES = {
    "chatml": (
        '{{- if .System }}<|im_start|>system\n{{ .System }}<|im_end|>\n{{ end }}'
        '<|im_start|>user\n{{ .Prompt }}<|im_end|>\n<|im_start|>assistant\n',
        ["<|im_end|>", "<|im_start|>"],
    ),
    "llama3": (
        '{{ if .System }}<|start_header_id|>system<|end_header_id|>\n\n{{ .System }}<|eot_id|>{{ end }}'
        '<|start_header_id|>user<|end_header_id|>\n\n{{ .Prompt }}<|eot_id|>'
        '<|start_header_id|>assistant<|end_header_id|>\n\n',
        ["<|eot_id|>", "<|start_header_id|>", "<|end_header_id|>"],
    ),
    "gemma": (
        '<start_of_turn>user\n{{ if .System }}{{ .System }}\n{{ end }}{{ .Prompt }}<end_of_turn>\n<start_of_turn>model\n',
        ["<end_of_turn>"],
    ),
    "mistral": (
        '[INST] {{ if .System }}{{ .System }} {{ end }}{{ .Prompt }} [/INST]',
        ["[INST]", "[/INST]"],
    ),
}


def detect_format(chat_template):
    t = chat_template or ""
    for marker, name in (("<|im_start|>", "chatml"), ("<|start_header_id|>", "llama3"),
                         ("<start_of_turn>", "gemma"), ("[INST]", "mistral")):
        if marker in t:
            return name
    return None


def cmd_modelfile(a):
    from transformers import AutoTokenizer
    if "\n" in a.gguf or "\r" in a.gguf:
        die("modelfile", "gguf path contains a newline")
    tok = AutoTokenizer.from_pretrained(a.model_dir)
    fmt = detect_format(tok.chat_template)
    lines = [f"FROM {a.gguf}"]
    if fmt is None:
        log("modelfile", "WARNING: chat format not recognized; Ollama will use a raw prompt (no chat template)."
            " Edit the Modelfile TEMPLATE yourself if replies look wrong")
    else:
        tpl, stops = TEMPLATES[fmt]
        lines.append('TEMPLATE """' + tpl + '"""')
        lines += [f'PARAMETER stop "{s}"' for s in stops]
        log("modelfile", f"using the {fmt} chat template")
    with open(a.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def cmd_ppl_text(a):
    """Write a plain-text evaluation corpus for `llama perplexity`."""
    from huggingface_hub import hf_hub_download
    log("ppl-text", f"downloading {WIKITEXT_REPO}@{WIKITEXT_REV[:8]} wikitext-2 test split (network)")
    rows = read_text_column(hf_hub_download(WIKITEXT_REPO, WIKITEXT_FILE, repo_type="dataset", revision=WIKITEXT_REV))
    text = "\n".join(rows)[: a.max_chars]
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(text)
    log("ppl-text", f"wrote {len(text)} characters to {a.out}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check").set_defaults(fn=cmd_check)
    f = sub.add_parser("fetch")
    f.add_argument("--repo", required=True)
    f.add_argument("--revision")
    f.add_argument("--out", required=True)
    f.set_defaults(fn=cmd_fetch)
    ab = sub.add_parser("abliterate")
    ab.add_argument("--model-dir", required=True)
    ab.add_argument("--out", required=True)
    ab.add_argument("--layer-frac", type=float, default=0.6)
    ab.add_argument("--n-prompts", type=int, default=64)
    ab.add_argument("--holdout", type=int, default=8)
    ab.add_argument("--harmful")
    ab.add_argument("--harmless")
    ab.add_argument("--force", action="store_true")
    ab.set_defaults(fn=cmd_abliterate)
    pt = sub.add_parser("ppl-text")
    pt.add_argument("--out", required=True)
    pt.add_argument("--max-chars", type=int, default=250000)
    pt.set_defaults(fn=cmd_ppl_text)
    mf = sub.add_parser("modelfile")
    mf.add_argument("--model-dir", required=True)
    mf.add_argument("--gguf", required=True)
    mf.add_argument("--out", required=True)
    mf.set_defaults(fn=cmd_modelfile)
    a = p.parse_args()
    if not 0.1 <= getattr(a, "layer_frac", 0.6) <= 0.95:
        die("args", "--layer-frac must be between 0.1 and 0.95")
    a.fn(a)


if __name__ == "__main__":
    main()

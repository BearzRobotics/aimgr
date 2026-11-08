#!/usr/bin/env python3
"""Generate config/models.toml (the bundled seed catalog) from public registry metadata.

DEV-TIME TOOL: uses the network; aimgr itself never runs this. Output is a dated snapshot.

  Ollama   : popular models from https://ollama.com/library (name, description, sizes,
             capabilities), each `name:size` tag verified against registry.ollama.ai and its
             real download size taken from the manifest.
  llama    : top GGUF repos (by downloads) of a fixed list of well-known organizations from
             the Hugging Face API; description is built only from API metadata
             (architecture, parameter count, context length, license).

Entries in pinned.toml (hand-written) are kept first. Usage:
  python3 tools/catalog-gen/gen.py > config/models.toml
Progress goes to stderr.
"""
import datetime
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

UA = "aimgr-dev-catalog-generator (offline-first local model manager)"
OLLAMA_MODELS = 28          # popular library entries to consider
MAX_TAGS_PER_MODEL = 3
MAX_OLLAMA_GB = 45          # skip tags whose download is larger than this
ABLIT_HF = 40              # abliterated GGUF repos from Hugging Face
ABLIT_OLLAMA = 14          # abliterated models from the Ollama community registry
HF_ORGS = ["ggml-org", "unsloth", "bartowski", "lmstudio-community", "Qwen", "google", "mistralai",
           "microsoft", "nvidia", "LiquidAI", "openai", "meta-llama", "deepseek-ai", "HuggingFaceTB", "ibm-granite", "allenai"]
HF_PER_ORG = 3


def get(url, accept=None, method="GET"):
    req = urllib.request.Request(url, method=method, headers={"User-Agent": UA, **({"Accept": accept} if accept else {})})
    time.sleep(0.15)
    with urllib.request.urlopen(req, timeout=25) as r:
        return r.read()


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def esc(s):
    return json.dumps(s, ensure_ascii=False)  # TOML basic strings accept JSON escaping for our content


def arr(xs):
    return "[" + ", ".join(esc(x) for x in xs) + "]"


def entry(backend, id_, name, description, use_cases=(), tags=(), notes=None, access=None, size_bytes=None, params_b=None, context=None):
    lines = ["[[model]]", f"backend = {esc(backend)}", f"id = {esc(id_)}", f"name = {esc(name)}", f"description = {esc(description)}"]
    if use_cases:
        lines.append(f"use_cases = {arr(use_cases)}")
    if tags:
        lines.append(f"tags = {arr(tags)}")
    if access:
        lines.append(f"access = {esc(access)}")
    if size_bytes:
        lines.append(f"size_bytes = {int(size_bytes)}")
    if params_b:
        lines.append(f"params_b = {round(float(params_b), 3)}")
    if context:
        lines.append(f"context = {int(context)}")
    if notes:
        lines.append(f"notes = {esc(notes)}")
    return "\n".join(lines) + "\n"


# Controlled vocabulary for use_cases. Derived from evidence only (name patterns, registry
# capability badges, Hugging Face tags, GGUF metadata): "suited for" hints, NOT benchmark results.
USES = ["coding", "reasoning", "vision", "tools", "chat", "long-context", "small", "math", "multilingual", "creative-writing"]


def parse_params_b(text):
    m = re.search(r"(?<![A-Za-z0-9.])e?(\d+(?:\.\d+)?)\s*([bm])\b", text or "", re.I)
    if not m:
        return None
    v = float(m.group(1))
    return v / 1000 if m.group(2).lower() == "m" else v


def derive_uses(name, caps=(), hf_tags=(), ctx=None, params_b=None, pipeline=None):
    n = (name or "").lower()
    caps = [c.lower() for c in caps]
    tags = [t.lower() for t in hf_tags]
    u = []
    if re.search(r"coder|codestral|devstral|starcoder|codellama|code-|-code|deepseek-coder|granite-code", n) or "code" in tags:
        u.append("coding")
    if "thinking" in caps or re.search(r"r1|reason|thinking|magistral|qwq|-think|distill", n) or "reasoning" in tags:
        u.append("reasoning")
    if "vision" in caps or re.search(r"(^|[-_:.])(vl|vision|llava|pixtral|minicpm-v|moondream)|-v\d|omni", n) or pipeline == "image-text-to-text" or "image-text-to-text" in tags:
        u.append("vision")
    if "tools" in caps or "function-calling" in tags or "tool-use" in tags:
        u.append("tools")
    if re.search(r"math|mathstral", n):
        u.append("math")
    if re.search(r"roleplay|(^|[-_/])rp([-_]|$)|story|creative|writer", n) or "roleplay" in tags or "creative-writing" in tags:
        u.append("creative-writing")
    langs = [t for t in tags if re.fullmatch(r"[a-z]{2}", t)]
    if "multilingual" in tags or len(langs) >= 8:
        u.append("multilingual")
    if ctx and ctx >= 128000:
        u.append("long-context")
    if params_b is not None and params_b <= 4:
        u.append("small")
    if "coding" not in u or re.search(r"instruct|chat|-it\b|assistant", n) or "conversational" in tags or "chat" in caps:
        u.insert(0, "chat")
    seen = []
    for x in u:
        if x in USES and x not in seen:
            seen.append(x)
    return seen or ["chat"]


def clean(s):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", s)).strip()


def ollama_entries():
    html = get("https://ollama.com/library?sort=popular").decode("utf-8", "replace")
    blocks = re.split(r'<li\s+class="flex items-baseline', html)[1:]
    out, seen = [], 0
    for b in blocks:
        m = re.search(r'href="/library/([a-z0-9._-]+)"', b)
        if not m:
            continue
        name = m.group(1)
        desc = re.search(r'<p\s+class="max-w-lg[^>]*>(.*?)</p>', b, re.S)
        desc = clean(desc.group(1)) if desc else ""
        caps = [clean(x) for x in re.findall(r'bg-(?:indigo|cyan)-50[^>]*>\s*([^<]+?)\s*<', b)]
        sizes = [clean(x) for x in re.findall(r'bg-\[#ddf4ff\][^>]*>\s*([^<]+?)\s*<', b)]
        if "embedding" in caps or not sizes or not desc:
            continue
        seen += 1
        if seen > OLLAMA_MODELS:
            break
        picked = []
        for tag in sizes:
            try:
                man = json.loads(get(f"https://registry.ollama.ai/v2/library/{name}/manifests/{tag}",
                                     accept="application/vnd.docker.distribution.manifest.v2+json"))
            except (urllib.error.HTTPError, urllib.error.URLError, json.JSONDecodeError):
                log(f"  skip {name}:{tag} (not found in registry)")
                continue
            total = sum(l.get("size", 0) for l in man.get("layers", [])) + man.get("config", {}).get("size", 0)
            if total / 1e9 > MAX_OLLAMA_GB:
                continue
            picked.append((tag, total))
        # keep smallest, largest, and one in the middle
        if len(picked) > MAX_TAGS_PER_MODEL:
            picked = [picked[0], picked[len(picked) // 2], picked[-1]]
        for tag, total in picked:
            use = derive_uses(f"{name}:{tag}", caps=caps, params_b=parse_params_b(tag))
            out.append(entry("ollama", f"{name}:{tag}", f"{name} {tag}", desc, use, access="open", size_bytes=total, params_b=parse_params_b(tag),
                             notes=f"Registry download size about {total / 1e9:.1f} GB (from the registry manifest)."))
        if "cloud" in caps:
            try:
                tags_html = get(f"https://ollama.com/library/{name}/tags").decode("utf-8", "replace")
                ctags = sorted(set(re.findall(rf"/library/{re.escape(name)}:([A-Za-z0-9._-]*cloud)", tags_html)))[:2]
            except Exception:  # noqa: BLE001
                ctags = []
            for ct in ctags:
                out.append(entry("ollama", f"{name}:{ct}", f"{name} {ct}", desc, derive_uses(f"{name}:{ct}", caps=caps, params_b=parse_params_b(ct)), access="cloud",
                                 notes="Runs on Ollama's cloud service, not on this machine: needs an Ollama account (sign-in) and counts against API usage limits. Not available offline."))
        log(f"ollama {name}: {[t for t, _ in picked]}")
    return out


def hf_note(gated):
    base = "Snapshot of Hugging Face metadata; check the model card before relying on it."
    if gated:
        return base + " Gated: downloading needs a Hugging Face account, accepting the model's license on its page, and an access token (HF_TOKEN)."
    return base


def hf_entries(pinned_text):
    out = []
    pinned_ids = set(re.findall(r'^id = "([^"]+)"', pinned_text, re.M))
    pinned_repos = {i.split(':')[0] for i in pinned_ids}
    for org in HF_ORGS:
        q = urllib.parse.urlencode({"author": org, "filter": "gguf", "pipeline_tag": "text-generation",
                                    "sort": "downloads", "direction": "-1", "limit": HF_PER_ORG * 2})
        try:
            repos = json.loads(get(f"https://huggingface.co/api/models?{q}"))
        except Exception as e:  # noqa: BLE001
            log(f"hf {org}: failed ({e})")
            continue
        n = 0
        for r in repos:
            if n >= HF_PER_ORG:
                break
            rid = r["id"]
            try:
                d = json.loads(get(f"https://huggingface.co/api/models/{rid}"))
            except Exception:  # noqa: BLE001
                continue
            if d.get("private") or not d.get("gguf") or rid in pinned_repos:
                continue
            gated = bool(d.get("gated"))
            base0 = rid.split("/", 1)[1]
            chatty = "conversational" in d.get("tags", []) or re.search(r"instruct|[-_]it\b|chat|coder|thinking", base0, re.I)
            if not chatty or re.search(r"diariz|sft|gsm8k|bitnet|embed|rerank|ocr", base0, re.I):
                continue
            files = [s["rfilename"] for s in d.get("siblings", []) if s["rfilename"].endswith(".gguf")]
            quant = "Q4_K_M" if any("Q4_K_M" in f.upper() for f in files) else None
            g = d["gguf"]
            lic = next((t.split(":", 1)[1] for t in d.get("tags", []) if t.startswith("license:")), "unspecified")
            params = g.get("total")
            bits = [g.get("architecture", "unknown architecture")]
            if params:
                bits.append(f"{params / 1e9:.1f}B parameters")
            if g.get("context_length"):
                bits.append(f"{g['context_length']:,}-token context")
            desc = f"{', '.join(bits)}; license {lic} (from Hugging Face metadata)."
            base = rid.split("/", 1)[1]
            title = re.sub(r"[-_]?GGUF$", "", base, flags=re.I).replace("-", " ").replace("_", " ")
            uses = derive_uses(base, hf_tags=d.get("tags", []), ctx=g.get("context_length"),
                               params_b=(params / 1e9 if params else None), pipeline=d.get("pipeline_tag"))
            out.append(entry("llama", f"{rid}:{quant}" if quant else rid, title, desc, uses,
                             access="signin" if gated else "open", notes=hf_note(gated),
                             params_b=(params / 1e9 if params else None), context=g.get("context_length")))
            n += 1
            log(f"hf {rid}")
    return out


def abliterated_hf(seen_repos):
    out = []
    q = urllib.parse.urlencode({"search": "abliterated", "filter": "gguf", "sort": "downloads", "direction": "-1", "limit": 100})
    repos = json.loads(get(f"https://huggingface.co/api/models?{q}"))
    n = 0
    for r in repos:
        rid = r["id"]
        if "abliterat" not in rid.lower() or rid in seen_repos:
            continue
        if re.search(r"embed|rerank|ocr|vision-only", rid, re.I):
            continue
        try:
            d = json.loads(get(f"https://huggingface.co/api/models/{rid}"))
        except Exception:  # noqa: BLE001
            continue
        if d.get("private") or not d.get("gguf"):
            continue
        gated = bool(d.get("gated"))
        files = [x["rfilename"] for x in d.get("siblings", []) if x["rfilename"].endswith(".gguf")]
        quant = "Q4_K_M" if any("Q4_K_M" in f.upper() for f in files) else None
        g = d["gguf"]
        lic = next((t.split(":", 1)[1] for t in d.get("tags", []) if t.startswith("license:")), "unspecified")
        bits = [g.get("architecture", "unknown architecture")]
        if g.get("total"):
            bits.append(f"{g['total'] / 1e9:.1f}B parameters")
        if g.get("context_length"):
            bits.append(f"{g['context_length']:,}-token context")
        desc = f"Abliterated variant ({', '.join(bits)}); license {lic} (from Hugging Face metadata)."
        base = rid.split("/", 1)[1]
        title = re.sub(r"[-_]?GGUF$", "", base, flags=re.I).replace("-", " ").replace("_", " ")
        uses = derive_uses(base, hf_tags=d.get("tags", []), ctx=g.get("context_length"),
                           params_b=(g["total"] / 1e9 if g.get("total") else None), pipeline=d.get("pipeline_tag"))
        out.append(entry("llama", f"{rid}:{quant}" if quant else rid, title, desc, uses, ["abliterated"],
                         access="signin" if gated else "open",
                         params_b=(g["total"] / 1e9 if g.get("total") else None), context=g.get("context_length"),
                         notes="Third-party abliterated model (refusal behavior removed by weight editing); unvetted, quality varies. " + hf_note(gated)))
        seen_repos.add(rid)
        n += 1
        log(f"abliterated hf {rid}")
        if n >= ABLIT_HF:
            break
    return out


def abliterated_ollama():
    out = []
    html = get("https://ollama.com/search?q=abliterated").decode("utf-8", "replace")
    names = []
    for n in re.findall(r'href="/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)"', html):
        if n.startswith(("public/", "library/", "blog/")) or n in names or "abliterat" not in n.lower():
            continue
        names.append(n)
    for full in names:
        if len(out) >= ABLIT_OLLAMA:
            break
        try:
            tags_html = get(f"https://ollama.com/{full}/tags").decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            continue
        tags = sorted(set(re.findall(rf"/{re.escape(full)}:([A-Za-z0-9._-]+)", tags_html)))
        cand = []
        for tag in tags[:12]:
            try:
                man = json.loads(get(f"https://registry.ollama.ai/v2/{full}/manifests/{tag}",
                                     accept="application/vnd.docker.distribution.manifest.v2+json"))
            except Exception:  # noqa: BLE001
                continue
            total = sum(l.get("size", 0) for l in man.get("layers", [])) + man.get("config", {}).get("size", 0)
            if total and total / 1e9 <= MAX_OLLAMA_GB:
                cand.append((total, tag))
        cand.sort()
        for total, tag in cand[:2]:
            out.append(entry("ollama", f"{full}:{tag}", f"{full} {tag}",
                             f"Community abliterated model published by '{full.split('/')[0]}' in the Ollama registry.", derive_uses(f"{full}:{tag}", params_b=parse_params_b(tag) or parse_params_b(full)), ["abliterated"], access="open", size_bytes=total, params_b=parse_params_b(tag) or parse_params_b(full),
                             notes=f"Third-party, unvetted (refusal behavior removed by weight editing). Registry download size about {total / 1e9:.1f} GB (from the manifest)."))
            log(f"abliterated ollama {full}:{tag}")
    return out


def main():
    today = datetime.date.today().isoformat()
    pinned = open("tools/catalog-gen/pinned.toml", encoding="utf-8").read().strip() + "\n"
    head = (f"# Bundled seed catalog for aimgr. GENERATED {today} by tools/catalog-gen/gen.py from public\n"
            "# registry metadata (ollama.com/library + registry.ollama.ai, huggingface.co API). It is a dated\n"
            "# snapshot: models and sizes change. aimgr never contacts these services unless you ask it to.\n"
            "# use_cases are DERIVED hints (name patterns, registry capability badges, Hugging Face tags,\n"
            "# GGUF context length), not benchmark results. access: open | signin | cloud.\n"
            "# Entries are matched to installed models by exact backend + id, then aliases. User overlay:\n"
            "# ~/.config/aimgr/models.toml. Hand-written entries come first (from pinned.toml).\n\n")
    parts = [pinned]
    parts += ollama_entries()
    hf = hf_entries(pinned)
    parts += hf
    seen = set(re.findall(r'^id = "([^":]+)', "\n".join(hf), re.M))
    parts += abliterated_hf(seen)
    parts += abliterated_ollama()
    sys.stdout.write(head + "\n".join(parts))


if __name__ == "__main__":
    main()

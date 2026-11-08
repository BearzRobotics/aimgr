# 0007: Abliteration (creating abliterated models)

Status: accepted; run end to end once on Qwen/Qwen2.5-0.5B-Instruct. Date: 2026-11-08.

## What it is
Abliteration removes a model's refusal behavior by finding the "refusal direction"
in the residual stream and orthogonalizing the weights that write to it
(Arditi et al. 2024, arXiv:2406.11717). The direction is the difference of mean
activations (last prompt token, one layer) between prompts models typically
refuse and ordinary prompts. aimgr produces a NEW model; sources are never edited.

## Design
- `aimgr abliterate setup`: creates `$XDG_DATA_HOME/aimgr/abliterate/venv` and
  installs `tools/abliterate/requirements.txt` (CPU torch etc.). Network, confirmed.
- `aimgr abliterate run <owner/repo> [--name --quant --layer-frac --n-prompts --holdout
  --harmful/--harmless --register --force --yes --dry-run]`. Stages (each an argv, no shell):
  fetch (HF safetensors) -> abliterate (`helper.py`) -> convert (vendored
  `convert_hf_to_gguf.py`) -> quantize (`llama quantize`) -> Modelfile -> `ollama create`.
- Pure planning/validation in `src/abliterate.zig` (unit-tested); orchestration in
  `src/abliterate_cmd.zig`; compute in `tools/abliterate/helper.py` (Python only
  inside the managed venv, never system Python).
- Resources are installed by `zig build` to `zig-out/share/aimgr/` (`abliterate/`,
  `llama-convert/`); `AIMGR_RESOURCES` overrides.
- **Pinned converter:** `vendor/llama-convert` = ggml-org/llama.cpp commit
  `fd27b2034905f8dadd8bd6d2cc44595f4929d391`, the commit reported by the installed
  `llama version` (0.9.0-dev build 12182). Unmodified; PYTHONPATH points at its gguf-py.
- **Prompt sets:** default are `mlabonne/harmful_behaviors@01cead01` and
  `mlabonne/harmless_alpaca@02c6a92c`, fetched at run time (not bundled: neither
  declares a license). `--harmful/--harmless` supply local files instead.
- **Safety rails:** repo/name/quant/paths validated; unsupported architectures
  (anything outside llama, mistral, qwen2, qwen3, gemma, gemma2, and any MoE) are
  refused; RAM check before loading; never overwrites an existing Ollama model or GGUF;
  explicit confirmation naming network use; result is labeled as abliterated
  (tag/name heuristic from 0005 picks it up because the name contains "abliterated").

## Simplifications and known limits
- Layer chosen by depth fraction (default 0.6), not by searching all layers as in the
  paper. Refusal is measured by phrase matching on a few held-out prompts, before and
  after (informational, not a quality guarantee).
- Tied embeddings (e.g. small Qwen models) are orthogonalized too, which also changes the
  output projection; usually harmless but unverified.
- `ollama create` from a bare GGUF imported with `TEMPLATE {{ .Prompt }}` (no chat
  format; seen in the first real run). The helper's `modelfile` stage now writes a
  TEMPLATE + stop tokens chosen from markers in the model's own chat template
  (chatml, llama3, gemma, mistral; constants only). Unrecognized formats get a
  warning and a raw prompt. Only chatml has been verified in a real run.
- llama has no registration mechanism; use `--register none` and
  `llama serve -m <gguf>`, or Ollama registration.
- CPU only (no GPU on the dev machine): realistic for small models.

## Verification status
Real run (2026-11-08, CPU, 12 threads, 32 prompts per set): venv setup (torch 2.15.0+cpu,
transformers 5.22.2), fetch (0.99 GB), abliterate (layer 14 of 24; held-out refusal-phrase
rate 88% -> 0% on 8 prompts), convert, quantize (Q4_K_M, 397 MB), Modelfile, `ollama create`.
The model answered ordinary questions correctly (12 x 12 = 144) with the chatml template.
`aimgr remove` of the test model also worked for real. Not verified: models other than
Qwen2 (llama/mistral/gemma/qwen3 are allowed but untested), the llama3/gemma/mistral
templates, `--register none`, `--harmful/--harmless` files, larger models, and any measure of
quality loss beyond a two-question sanity check (llama perplexity comparison is not wired in).

## TUI integration (2026-11-08)
- Key `b` (Installed / Discover): if the venv is missing it offers `aimgr abliterate setup --yes`
  as a job; otherwise it prompts for an `owner/name` repo, validates it, checks Ollama/llama
  availability and name collisions, shows a confirmation naming the network use and the
  abliterated-model note, then starts `aimgr abliterate run <repo> --yes` as a job (the TUI
  spawns its own executable; jobs run in their own process group, output goes to a log).
- Cancel (`x` on Transfers): SIGTERM to the job; its runner forwards the stop to the current
  stage and exits 130; verified that no Python child is left. 
- Verified in a pty: prompt, invalid repo, name-collision refusal, confirm modal, TUI delete of the
  test model, cancel mid-"abliterate" stage (CANCELLED, exit 130), and a full run to DONE with
  the model registered. Not verified: the `setup` job from the TUI (venv already existed).

## Quality check (`--check-quality`, 2026-11-08)
Stages added after quantize: `ppl-text` (wikitext-2 test split, Salesforce/wikitext@b08601e0,
CC-BY-SA-3.0/GFDL, fetched at run time, 250k chars; or `--ppl-text FILE`), `convert-base` and
`quantize-base` (the original, same quant), `ppl-base`, `ppl-new` (`llama perplexity -c 512
--chunks N --log-file`), and a report parsed from "Final estimate: PPL = x +/- y".
Opt-in because it roughly doubles conversion time and disk for big models.
Real result (Qwen2.5-0.5B-Instruct, Q4_K_M, 40 chunks, 32 prompts per set):
original 14.27 +/- 0.41, abliterated 16.44 +/- 0.50, change +15.2% (outside the error bars).
That is a measurable cost on general text for this tiny model; it says nothing about other
kinds of degradation. Not wired into the TUI job (CLI only).

## Bug found by this run
`std.Io.File.Writer.init` writes positionally; with stdout/stderr redirected to a file it
overwrote the output of child processes sharing the offset (garbled logs). All aimgr
writers now use `initStreaming`.

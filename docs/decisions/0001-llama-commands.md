# 0001: llama backend uses the installed distribution's commands

Status: accepted. Date: 2026-11-07.

## Context
SPEC.md assumed `llama ls` and `llama pull`. The installed llama
(`version: 0.9.0-dev (build 12182, commit fd27b2034)`, installed via the
upstream curl script) has neither (`error: unknown command`). Per the user, the
installed llama is the reference.

## Decision
- Probe: `llama version` (first line `version: ...`).
- List: `llama cli --cache-list` -> `number of models in cache: N` then
  `  K. <repo>:<quant>` lines. Parser rejects count mismatches or unknown headers.
- Download/update: `llama download -hf <repo>[:quant]` (not yet implemented).
- Remove: no supported command found in `llama help all`; disabled with an
  explanation (see `backends/llama.zig` `capabilities`).
- Quantization is reported only when explicit in the identifier.

## Fixtures
`src/fixtures/` holds real captures, except `ollama-list-synthetic.txt`, which
is synthetic (no Ollama models were installed at capture time).

## Sources
- `llama help all`, `llama download --help`, `llama cli --help` on the installed build.

# 0004: Pull, update, remove

Status: accepted. Date: 2026-11-07.

## Decisions
- **Commands** (argv only, verified against installed versions):
  - ollama: `ollama pull <id>`, `ollama rm <id>`.
  - llama: `llama download -hf <user>/<model>[:quant]`.
  - llama removal: disabled with an explanation. `llama help all` (0.9.0-dev
    build 12182) lists no removal command; aimgr never deletes cache files itself.
- **Update = explicit re-pull** of an installed exact id, always printing the
  mutable-tag warning. aimgr does not check revisions.
- **Pull** refuses ids that are already installed (use update); **update** and
  **remove** require the exact id to be installed in that backend, so an action
  can never reach another backend's storage.
- **Confirmation:** every pull/update/remove prints backend, exact id, the exact
  command and a network/deletion notice, then asks y/N. `--yes` skips only the
  question; `--dry-run` prints the plan and runs nothing.
- **Duplicates on remove:** an identical id in the other backend is called out
  (and left untouched); models with the same base name (text after the last
  `/`, before `:`, lowercase, minus `-gguf`) are listed as "similar". This is a
  heuristic and is labeled as such.
- **Progress and errors:** the child inherits stdout/stderr, so its own
  progress and error text are shown unmodified; a non-zero exit is reported
  with its code.
- **Cancellation:** Ctrl-C or SIGTERM sends SIGTERM to the child; escalation to
  SIGKILL is asked first (shared logic with servers, `supervise.pollStop`).
  Cancelled runs exit 130. Partial downloads are left to the backend.

## Verification gaps
No real pull or remove was executed during development (it would use the
network or delete the user's only Ollama model). Argument generation, the
confirmation flow, refusal paths and dry-run were tested; the real transfer
path and cancellation are untested.

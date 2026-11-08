# 0003: Launch and supervision

Status: accepted. Date: 2026-11-07.

## Decisions
- **Offline:** the model must appear in the backend's own listing (exact id).
  llama launches add `--offline` (`llama serve --help`: "forces use of cache,
  prevents network access"). Ollama launches only run installed models.
- **Argv only:** `launcher.zig` is pure (no spawning). Model ids starting with
  `-` or containing control characters are rejected; ollama chat uses `--`.
- **Flag support is explicit:** `ollama run` has no context/GPU/host flags, so
  those options are rejected for ollama chat. For `ollama serve`, host/port go
  through `OLLAMA_HOST` and context through `OLLAMA_CONTEXT_LENGTH`; GPU layers
  are rejected. Ollama server mode takes no model (selection/preload is separate).
- **Shared Ollama daemon:** if the port is already in LISTEN state, aimgr
  attaches and starts nothing. Profile options are ignored with a note.
- **Defaults:** host 127.0.0.1; llama port 9931 (the installed llama's default),
  ollama port 11434. Any non-loopback host requires an interactive y/N
  confirmation naming the exact address; no TTY/stdin means refusal.
- **"Listening" is observed, not assumed:** /proc/net/tcp{,6} is polled for a
  LISTEN socket. procfs files report size 0, so they are read with a
  streaming reader (`netstat.readProc`).
- **Signals:** aimgr installs handlers (not SIG_IGN, which would be inherited
  by children). First Ctrl-C/SIGTERM sends SIGTERM to the server; if it is
  still alive after ~10 s or on a second Ctrl-C, aimgr asks before SIGKILL.
  The one global (an atomic stop counter) is required by signal handlers.
- **Logs:** server stdout/stderr go to `$XDG_STATE_HOME/aimgr/logs/<backend>-<port>.log`
  (truncated per run).
- **Chat:** child inherits the terminal; aimgr waits and returns its exit code.

## Not yet done
- Stored per-model launch profiles (config.toml) and CLI flag validation
  beyond the options above; arbitrary backend flags are intentionally not passed through.
- Showing server logs inside the TUI (milestone 5).

## Observed side effect
Starting `ollama serve` as a user creates `~/.ollama/id_ed25519`. This happened
once during development when a bug made aimgr start a second daemon; aimgr now
checks for a listener first.

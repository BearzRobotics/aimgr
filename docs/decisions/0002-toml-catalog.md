# 0002: TOML catalog and vendored toml-zig

Status: accepted. Date: 2026-11-07.

## Decisions
- TOML parsing uses `toml-zig` v0.1.0 (github.com/BearzRobotics/toml-zig, MIT,
  tarball hash `toml-0.1.0-dDatLI4xAgB1P1SWnx8mnn9oHfDkYSZbqBMOKvKR-X3N`),
  vendored in `vendor/toml-zig` and referenced as a path dependency, so builds
  never fetch from the network (SPEC section 5).
- Catalog schema: `[[model]]` tables with `backend`, `id`, and optional `name`,
  `description`, `notes`, `use_cases[]`, `aliases[]`.
- Matching: exact backend+id over all entries (user overlay first), then explicit
  aliases within the same backend. Unmatched models stay visible, marked
  "(no catalog entry)".
- Bundled seed: `config/models.toml`, embedded at build time. User overlay:
  `$XDG_CONFIG_HOME/aimgr/models.toml` or `~/.config/aimgr/models.toml`; an
  invalid overlay is ignored with a visible error that gives file, line, column.
- Overlay precedence is whole-entry (not per field).
- Seed descriptions are general knowledge, not read from model files.

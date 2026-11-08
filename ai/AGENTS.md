AGENTS.md — aimgr
Mission
Implement the spec.md faithfully. Build an offline-first, safe, understandable local AI model manager for Ollama and llama.cpp in Zig.
Engineering rules
1. Read spec.md and this file before modifying code. Record material design decisions and rationale under docs/decisions/.
2. Verify command flags and output formats against actual installed tools or captured fixtures. Do not invent backend features or assume output formats are stable.
3. Prefer Zig standard library; vendor and pin all source dependencies (currently toml-zig, libvaxis, uucode). No system libraries are required.
4. No shell command construction using user/model strings. Always use argument vectors.
5. Never delete model blobs, shared caches, or directories directly. Use documented backend deletion APIs or disable the operation.
6. No unexpected network access, automatic downloads, telemetry, or public server bindings.
7. Make failure visible: distinguish missing executables, bad output, incompatible versions, network errors, and permission failures.
8. Separate backend, catalog, process, and UI layers. Avoid global mutable state unless documented and justified.
9. Prefer small cohesive source files (aim for under ~500 lines; split when it improves maintainability, not as a hard rule).
10. Respect NO_COLOR; keyboard functionality must not depend on color. Restore terminal state on failure.
11. Add unit tests for parsers, model identity, deduplication, and argument generation; integration tests must not modify real model storage.
12. Cite official Zig, Ollama, and llama.cpp documentation in design decisions where applicable; document version-sensitive assumptions.
13. Keep documentation and help output synchronized with implementation. Do not mark planned features complete.
14. Run zig fmt, zig build, and zig build test when toolchain is available; report any unverified work honestly.
Implementation sequence
CLI probe/list -> metadata catalog -> launches -> management operations -> terminal UI -> hardware estimates and discovery.
Review checklist
- Does the action affect only the selected backend and exact model?
- Is it safe offline and under unexpected input?
- Does it avoid shell injection and accidental network calls?
- Are destructive and public-network actions confirmed?
- Does it handle unsupported features explicitly?
- Are tests and docs updated?

# toml-zig

TOML 1.1.0 (and 1.0.0) parser and writer for Zig 0.17, with no dependencies. It reads from any `std.Io.Reader` and writes to any `std.Io.Writer`, and never needs the whole input in memory. See `ai/SPEC.md` for requirements and known deviations (notably: comments are not preserved when writing).

```zig
// build.zig.zon: .toml = .{ .path = "../toml-zig" }
// build.zig:     exe.root_module.addImport("toml", b.dependency("toml", .{}).module("toml"));
var diag: toml.Diagnostic = .{};
var doc = try toml.Document.parse(gpa, text, .{}, &diag);
defer doc.deinit();

// Incrementally, from any std.Io.Reader (file, pipe, socket, ...):
var doc2 = try toml.Document.parseReader(gpa, &reader.interface, .{}, &diag);

// TOML 1.1 is the default; ask for 1.0 only to be strict:
var doc3 = try toml.Document.parse(gpa, text, .{ .version = .v1_0 }, &diag);
```

- `docs/writing-toml.md` — a short guide to the syntax, with links to the official specification.
- `docs/decisions/` — design decisions (e.g. why the parser is streaming).
- `zig build bench` — parse/write timings (ReleaseFast).
- `zig build cli` — builds `zig-out/bin/toml-parse` (`gen <bytes>`, `slice|reader <file>`) for whole-process comparisons of two builds with [poop](https://github.com/andrewrk/poop): `poop 'old/toml-parse slice f.toml' 'new/toml-parse slice f.toml'`.

`zig build test` runs the tests.

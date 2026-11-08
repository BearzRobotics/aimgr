# 0001: Architecture of md-zig

Status: accepted by the maintainer in conversation (dialect and order of work);
implemented for steps 1 to 5, including definition lists.

## Problem

dkde needs to read the markdown it writes as documentation, to show it in the
help application (GTK) and in the man tool (terminal). Neither should depend on
a C library, and `AGENTS.md` section 13 requires `std.Io` for portability.

## Decisions

1. **Dialect: CommonMark 0.31.2 plus GFM extensions plus a few more.**
   CommonMark is the specification (https://spec.commonmark.org/0.31.2/). Its
   official `spec.json` (652 examples) is the conformance suite and is kept in
   `test/fixtures/`. Extensions are `Options` flags, off in strict mode:
   GFM tables, strikethrough, task lists and extended autolinks; then footnotes,
   definition lists and a YAML front matter block that is kept as raw text.
   A pandoc `%` title block was considered and **rejected**: the maintainer
   confirmed it came from an assistant and is not wanted.

2. **Input is a `*std.Io.Reader`, read one line at a time.** CommonMark's block
   structure is line oriented, so the block parser consumes lines as the reader
   produces them and never needs the whole text at once. What stays in memory is
   the syntax tree plus the raw text of the leaf blocks still open. Inline
   parsing is a second pass over finished leaf blocks, because link reference
   definitions may come after their first use. `parse(gpa, source, ...)` wraps a
   fixed reader. Line length and total size are capped by `Options`.

3. **Output goes to a `*std.Io.Writer`.** `writeHtml` first (it is what the
   spec tests compare), then an ANSI/plain-text renderer for the terminal.
   Consumers that build their own output (the GTK help viewer) walk the tree.

4. **One tree type, arena allocated.** `Document` owns an arena; nodes are
   plain structs linked by parent/first-child/next-sibling pointers. Freeing
   the document frees everything. No toolkit, file system or OS calls in the
   library.

5. **Unicode.** Delimiter-run flanking needs "Unicode punctuation" and
   "Unicode whitespace". Without a Unicode database in the standard library
   these use ASCII plus the ranges of the common general-punctuation, symbol and
   CJK blocks (see `unicode.zig`). Case folding for link labels handles ASCII and
   the spec's sharp-s case only. Both are documented deviations.

6. **Entities.** The 2125 named references are generated from the WHATWG
   `entities.json` by `scripts/gen-entities.py` into `src/entities.zig`.

## Alternatives considered

- Read the whole input, then parse a slice: simpler, but it ignores the
  requirement and duplicates memory for large files.
- Bind cmark (C): fast and complete, but a C dependency in every consumer, and
  it would not exercise `std.Io`.
- Event/streaming output instead of a tree: cannot resolve reference links that
  are defined later, and the GTK viewer wants a tree anyway.

## Consequences

- Memory is proportional to the document, not to a copy of the source plus the
  document.
- Conformance is measured, not claimed: `zig build test` runs every spec example
  and reports the number that pass; known failures are listed in
  `test/known-failures.txt` and the test fails if a listed example starts
  passing or an unlisted one fails.

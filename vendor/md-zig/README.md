# md-zig

Markdown parser and renderer for Zig, built on `std.Io`.

- **CommonMark 0.31.2**: all 652 examples of the specification pass, byte for byte.
- **Extensions** (flags in `Extensions`, all off by default): GFM tables,
  strikethrough, task lists, extended autolinks and the tag filter (52 of 52
  examples of cmark-gfm's own suite pass), plus footnotes, definition lists and front matter.
- **Input** is a `*std.Io.Reader`, read one line at a time. **Output** goes to a
  `*std.Io.Writer`: HTML, or text for a terminal (word-wrapped, optional ANSI).
- No file system or OS calls in the library; one module, no dependencies.

Zig 0.17.1.

```zig
const md = @import("md");

var doc = try md.Document.parse(gpa, "# Hello *world*\n", .{});
defer doc.deinit();
try doc.writeHtml(gpa, writer);        // <h1>Hello <em>world</em></h1>
try doc.writeText(gpa, writer, .{ .width = 80, .color = true });
```

Read from any reader, with extensions:

```zig
var doc = try md.Document.parseReader(gpa, &reader, .{ .extensions = md.Extensions.gfm });
```

`Options` limit the input (`max_bytes`, `max_line_bytes`); a longer input fails
with `error.InputTooLarge` or `error.LineTooLong`. The tree (`doc.root`,
`md.Node`, walked iteratively with `md.Walker`) is public, for consumers that
build their own output, such as a GTK viewer.

Write it back out as Markdown (edit the tree, then save):

```zig
try doc.writeMarkdown(gpa, writer);          // or doc.toMarkdownAlloc(gpa)
```

The output has the same meaning, not the same spelling: parsing it gives a tree
that renders to the same HTML (checked on all 652 CommonMark and 52 GFM
examples). Raw HTML, and so `<!-- comments -->`, and front matter are written
back exactly as read. Headings come out ATX, code fenced, links inline (reference
definitions are resolved and not written), emphasis as `_x_`/`**x**`. Nesting
deeper than 200 fails with `error.TooDeep`.

Try it: `zig build` then `zig-out/bin/mdcat FILE [WIDTH]`.

## C interface (experimental)

An optional C adapter lives in `src/capi.zig` and `include/md.h`; the Zig API
does not depend on it. `zig build c-api` installs `libmd.a`, `libmd.so` and
`md.h`. It is **experimental and unstable**: no source or binary compatibility
is promised between releases. `zig build test` builds and runs a C program
(`test/c/smoke.c`) against it.

```c
md_document *doc;
if (md_parse(src, len, MD_EXT_ALL, &doc) == MD_OK) {
    uint8_t *html; size_t n;
    if (md_to_html(doc, &html, &n) == MD_OK) { fwrite(html, 1, n, stdout); md_free_string(html, n); }
    md_free(doc);
}
```

## Extensions

| Flag | Syntax |
|---|---|
| `tables` | `\| a \| b \|` with a `\| - \| - \|` row, alignment with `:` |
| `strikethrough` | `~text~`, `~~text~~` |
| `task_lists` | `- [ ] item`, `- [x] item` |
| `autolinks` | bare `https://...`, `www....`, `user@example.com` |
| `tagfilter` | `<script>` and a few other raw tags shown as text |
| `footnotes` | `text[^1]` and `[^1]: the note` |
| `definition_lists` | `Term` then `: definition` lines; every line above the first `:` is a term; indented lines continue a definition |
| `front_matter` | a `---` ... `---` block at the very start, kept in the tree, not rendered |

`Extensions.gfm` is the first five; `Extensions.all` is all of them.

## Not done

- The Markdown writer does not keep how a construct was spelled (setext vs ATX, `*` vs `_`, reference-style links, indented code, wrapping).

- A blank line between a term and its `: definition` (the `:` line must follow the term directly).
- Unicode: "punctuation" and "whitespace" for emphasis, and case folding of link
  labels, are approximated by ranges (no Unicode database in the standard
  library). Text outside those ranges is treated as letters. See
  `docs/decisions/0001-architecture.md`.
- The terminal renderer does not draw raw HTML (blocks are shown dimmed, inline
  HTML is dropped) and cuts off containers nested more than 64 deep.

## Tests

`zig build test` runs the CommonMark and GFM suites (`test/fixtures/`, from
https://spec.commonmark.org/0.31.2/spec.json and
https://github.com/github/cmark-gfm), the `std.Io` boundary tests (one-byte
buffers, readers and writers that fail part-way, size limits, leaks), and the
renderer tests. `scripts/gen-entities.py` and `scripts/extract-gfm-examples.py`
regenerate `src/entities.zig` and the GFM fixture.

## Layout

See `docs/architecture.md`. Engineering standards: `ai/AGENTS.md`. License: `LICENSE`.

# Architecture

    Reader --lines--> block.zig --tree of blocks--> inline.zig --> tree --> html.zig  --> Writer
                       (Parser.feed)                (per leaf)              term.zig

| File | Role |
|---|---|
| `root.zig` | Public API: `Document`, `Options`, `Extensions`; reads lines from the reader and feeds the block parser |
| `options.zig` | `Options`, `Extensions` |
| `ast.zig` | `Node`, `Kind`, and the iterative `Walker` |
| `block.zig` | Block structure, line by line (quotes, lists, code, HTML, headings, tables, footnote definitions, definition lists, front matter) |
| `inline.zig` | Emphasis, links, images, code spans, autolinks, entities, strikethrough, footnote references; link reference definitions |
| `autolink.zig` | GFM extended autolinks over the text nodes of a finished leaf |
| `scan.zig` | Hand-written matchers for the spec's regular expressions (raw HTML, autolinks) |
| `text.zig` | Escapes, character references, URL encoding, link label normalisation |
| `unicode.zig` | Punctuation/whitespace classes, UTF-8 helpers, display width |
| `entities.zig` | Generated table of the 2125 named character references |
| `html.zig` | HTML renderer (also footnote section, tag filter) |
| `term.zig` | Terminal renderer (wrapping, lists, tables, ANSI) |

## The tree as an interface

`ast.zig` is shared with other projects: gtroff-zig builds the same tree from
man and mdoc pages, and dkman renders it. Node kinds and fields are therefore
API. `Node.indent` is the one field Markdown never sets: readers of other
formats use it to ask the terminal renderer for plain indentation of a
`block_quote` (no bar) and for a `deflist_def` whose short term shares a line
with its text. A `code_block` with `indent` set is indented by that amount
instead of the default 4 (`Node.flush` for none).

## Data flow

1. `Document.parseReader` streams one line at a time out of the reader
   (`streamDelimiterLimit`), handles `\r\n`, lone `\r` and NUL, and calls
   `Parser.feed`.
2. The block parser follows the CommonMark appendix "A parsing strategy": match
   the open containers, try to start new blocks, add the rest of the line to the
   innermost open leaf. Leaf text is kept raw until the block closes.
3. When all lines are in, `Parser.finish` closes every block and runs
   `inline.processTree`: every paragraph, heading and table cell is parsed with
   the delimiter stack (emphasis) and bracket stack (links). Link reference
   definitions were collected in step 2, so a use before the definition works.
4. A renderer walks the tree with `Walker` (no recursion, so deep nesting cannot
   overflow the stack) and writes to a `std.Io.Writer`.

## Memory

A `Document` owns one arena; nodes, strings and the reference maps live in it.
Renderers use a temporary arena for their own bookkeeping (footnote numbering,
table cells).

## Limits

`Options.max_bytes` and `max_line_bytes` bound the input. Nesting of containers
is bounded by the input size only; the parser and the HTML renderer are
iterative. The terminal renderer recurses and stops at 64 levels.

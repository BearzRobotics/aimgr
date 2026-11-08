# 0002: Scope of md-zig and how dkman and the viewer use it

Status: accepted by the maintainer in conversation.

## Problem

dkde needs to show documentation in a terminal (the man tool, `dkman`) and in a
GTK help viewer. Documentation exists as Markdown (the project's own) and as
traditional man pages (roff man(7) and mdoc(7)). The question is which library
reads which format and who renders.

## Decisions

1. **md-zig reads Markdown only.** It does not read roff and gets no roff code.
   It keeps `writeHtml` and `writeText` (used by `mdcat` and by consumers that
   want a ready terminal rendering).
2. **A separate library, `gtroff-zig`, reads roff (man and mdoc).** It builds the
   same `md.Node` tree that md-zig builds (headings, paragraphs, lists,
   definition lists, code blocks, inline styles). It depends on md-zig for the
   tree type only. It has no terminal code.
3. **`dkman` is the program.** It finds pages (`MANPATH` and the traditional
   directories), picks the reader from the file name and content, and renders
   every tree with md-zig's `writeText`. One renderer gives one look for both
   formats. It adds search with fzf, a pager, and an optional TUI. Markdown
   support in dkman is an optional build flag.
4. **The GTK viewer** walks the same tree with `md.Walker`, so it can show
   Markdown and, through gtroff-zig, man pages.

## Alternatives considered

- Roff reader inside md-zig: breaks the library's single purpose and makes every
  Markdown consumer carry roff code.
- Extract the tree and renderer into a third shared package: cleaner in theory,
  but one more repository and a refactor with no current need. Can be revisited
  if a third format appears.
- Separate renderers per format: more code, and the two outputs drift apart.

## Consequences

- The `md.Node` tree is a public interface between three projects. Changes to
  `ast.zig` must be treated as API changes. The node kinds and their fields are
  to be documented in `docs/architecture.md` before gtroff-zig depends on them.
- roff carries information the tree cannot hold (exact indents, preformatted
  layout, tables from tbl). gtroff-zig maps these to the closest node kinds and
  records the loss in its own documentation.
- `writeText` options (`TextOptions`) are the terminal interface shared by every
  consumer.

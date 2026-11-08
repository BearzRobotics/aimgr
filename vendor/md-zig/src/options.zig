//! Parser options and the set of Markdown extensions.

/// Extensions beyond CommonMark. All are off by default, which gives plain
/// CommonMark 0.31.2. `gfm` turns on the GitHub Flavored Markdown ones.
pub const Extensions = packed struct {
    /// Pipe tables (GFM).
    tables: bool = false,
    /// `~text~` and `~~text~~` (GFM).
    strikethrough: bool = false,
    /// `- [ ] item` and `- [x] item` (GFM).
    task_lists: bool = false,
    /// Bare `https://...`, `www....` and e-mail addresses become links (GFM).
    autolinks: bool = false,
    /// Raw HTML for a few dangerous tags (`<script>`, `<style>`, ...) is shown as
    /// text (GFM "disallowed raw HTML").
    tagfilter: bool = false,
    /// `[^label]` references and `[^label]: text` definitions.
    footnotes: bool = false,
    /// A `---` ... `---` block at the very start is kept apart as front matter.
    front_matter: bool = false,
    /// `Term` followed by lines that start with `: definition`.
    definition_lists: bool = false,

    pub const gfm: Extensions = .{ .tables = true, .strikethrough = true, .task_lists = true, .autolinks = true, .tagfilter = true };
    /// Everything this library supports.
    pub const all: Extensions = .{
        .tables = true,
        .strikethrough = true,
        .task_lists = true,
        .autolinks = true,
        .tagfilter = true,
        .footnotes = true,
        .front_matter = true,
        .definition_lists = true,
    };
};

pub const Options = struct {
    /// Longest accepted input, in bytes.
    max_bytes: usize = 64 * 1024 * 1024,
    /// Longest accepted line, in bytes.
    max_line_bytes: usize = 4 * 1024 * 1024,
    extensions: Extensions = .{},
};

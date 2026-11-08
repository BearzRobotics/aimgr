//! Abliteration planning: validation, naming, paths, and the stage list.
//! Pure (no process spawning), so it is unit-tested. The heavy compute lives in
//! tools/abliterate/helper.py and runs only inside an aimgr-managed venv.
//!
//! "Abliteration" removes a model's refusal direction by orthogonalizing its
//! weights (Arditi et al. 2024, arXiv:2406.11717). aimgr writes a NEW model;
//! the source files are never modified.
const std = @import("std");

pub const Register = enum { ollama, none };

pub const Params = struct {
    /// Hugging Face repo with full-precision safetensors, e.g. "Qwen/Qwen2.5-0.5B-Instruct".
    repo: []const u8,
    /// Name of the new model (lowercase). Default derived from repo.
    name: ?[]const u8 = null,
    quant: []const u8 = "Q4_K_M",
    layer_frac: f32 = 0.6,
    n_prompts: u32 = 64,
    holdout: u32 = 8,
    harmful_file: ?[]const u8 = null,
    harmless_file: ?[]const u8 = null,
    register: Register = .ollama,
    force: bool = false,
    /// Compare perplexity of the original and abliterated model (same quant, same text).
    check_quality: bool = false,
    ppl_text_file: ?[]const u8 = null,
    ppl_chunks: u32 = 40,
};

pub const Error = error{
    InvalidRepo,
    InvalidName,
    InvalidQuant,
    InvalidNumber,
    NeedBothPromptFiles,
    InvalidPath,
    OutOfMemory,
};

pub fn errorText(e: Error) []const u8 {
    return switch (e) {
        error.InvalidRepo => "repo must look like <owner>/<name> (letters, digits, . _ -)",
        error.InvalidName => "model name must be lowercase letters, digits, . _ - (max 64)",
        error.InvalidQuant => "quant must be one of F16, Q8_0, Q6_K, Q5_K_M, Q5_K_S, Q4_K_M, Q4_K_S, Q4_0, Q3_K_M, Q2_K",
        error.InvalidNumber => "numeric option out of range",
        error.NeedBothPromptFiles => "--harmful and --harmless must be given together",
        error.InvalidPath => "path must be absolute-or-relative text without control characters",
        error.OutOfMemory => "out of memory",
    };
}

const quants = [_][]const u8{ "F16", "Q8_0", "Q6_K", "Q5_K_M", "Q5_K_S", "Q4_K_M", "Q4_K_S", "Q4_0", "Q3_K_M", "Q2_K" };

fn identChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-';
}

pub fn validRepo(repo: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, repo, '/') orelse return false;
    if (slash == 0 or slash + 1 >= repo.len or std.mem.indexOfScalarPos(u8, repo, slash + 1, '/') != null) return false;
    if (repo[0] == '-' or repo[slash + 1] == '-' or repo.len > 128) return false;
    for (repo) |c| if (c != '/' and !identChar(c)) return false;
    return true;
}

pub fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > 64 or n[0] == '-' or n[0] == '.') return false;
    for (n) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '.' or c == '_' or c == '-')) return false;
    return true;
}

fn validPath(p: []const u8) bool {
    if (p.len == 0 or p.len > 1024 or p[0] == '-') return false;
    for (p) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// "Qwen/Qwen2.5-0.5B-Instruct" -> "qwen2.5-0.5b-instruct-abliterated"
pub fn deriveName(arena: std.mem.Allocator, repo: []const u8) ![]u8 {
    const base = repo[std.mem.indexOfScalar(u8, repo, '/').? + 1 ..];
    var out: std.ArrayList(u8) = .empty;
    for (base) |c| try out.append(arena, std.ascii.toLower(c));
    if (std.ascii.findIgnoreCase(out.items, "abliterat") == null) try out.appendSlice(arena, "-abliterated");
    if (out.items.len > 64) out.shrinkRetainingCapacity(64);
    return out.toOwnedSlice(arena);
}

pub fn validate(p: Params) Error!void {
    if (!validRepo(p.repo)) return error.InvalidRepo;
    if (p.name) |n| if (!validName(n)) return error.InvalidName;
    var ok = false;
    for (quants) |q| if (std.mem.eql(u8, q, p.quant)) {
        ok = true;
    };
    if (!ok) return error.InvalidQuant;
    if (!(p.layer_frac >= 0.1 and p.layer_frac <= 0.95)) return error.InvalidNumber;
    if (p.n_prompts < 8 or p.n_prompts > 1024 or p.holdout > 64) return error.InvalidNumber;
    if ((p.harmful_file == null) != (p.harmless_file == null)) return error.NeedBothPromptFiles;
    if (p.harmful_file) |f| if (!validPath(f)) return error.InvalidPath;
    if (p.harmless_file) |f| if (!validPath(f)) return error.InvalidPath;
    if (p.ppl_text_file) |f| if (!validPath(f)) return error.InvalidPath;
    if (p.ppl_chunks < 4 or p.ppl_chunks > 1000) return error.InvalidNumber;
}

pub const Paths = struct {
    venv: []const u8,
    venv_python: []const u8,
    work: []const u8,
    source: []const u8,
    out_dir: []const u8,
    f16_gguf: []const u8,
    final_gguf: []const u8,
    modelfile: []const u8,
    helper: []const u8,
    requirements: []const u8,
    convert_script: []const u8,
    gguf_py: []const u8,
    ppl_text: []const u8,
    base_f16: []const u8,
    base_quant: []const u8,
    ppl_base_log: []const u8,
    ppl_new_log: []const u8,
};

/// `data` = $XDG_DATA_HOME/aimgr (abliterate/ and models/ live under it);
/// `res` = resource dir containing abliterate/ and llama-convert/.
pub fn paths(arena: std.mem.Allocator, data: []const u8, res: []const u8, name: []const u8, quant: []const u8) !Paths {
    const j = struct {
        fn f(a: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
            return std.fs.path.join(a, parts);
        }
    }.f;
    const venv = try j(arena, &.{ data, "abliterate", "venv" });
    const work = try j(arena, &.{ data, "abliterate", "work", name });
    const final_name = try std.fmt.allocPrint(arena, "{s}-{s}.gguf", .{ name, quant });
    return .{
        .venv = venv,
        .venv_python = try j(arena, &.{ venv, "bin", "python" }),
        .work = work,
        .source = try j(arena, &.{ work, "source" }),
        .out_dir = try j(arena, &.{ work, "abliterated" }),
        .f16_gguf = try j(arena, &.{ work, try std.fmt.allocPrint(arena, "{s}-f16.gguf", .{name}) }),
        .final_gguf = try j(arena, &.{ data, "models", final_name }),
        .modelfile = try j(arena, &.{ work, "Modelfile" }),
        .helper = try j(arena, &.{ res, "abliterate", "helper.py" }),
        .requirements = try j(arena, &.{ res, "abliterate", "requirements.txt" }),
        .convert_script = try j(arena, &.{ res, "llama-convert", "convert_hf_to_gguf.py" }),
        .gguf_py = try j(arena, &.{ res, "llama-convert", "gguf-py" }),
        .ppl_text = try j(arena, &.{ work, "ppl-text.txt" }),
        .base_f16 = try j(arena, &.{ work, "base-f16.gguf" }),
        .base_quant = try j(arena, &.{ work, try std.fmt.allocPrint(arena, "base-{s}.gguf", .{quant}) }),
        .ppl_base_log = try j(arena, &.{ work, "ppl-base.log" }),
        .ppl_new_log = try j(arena, &.{ work, "ppl-new.log" }),
    };
}

pub const Stage = struct {
    label: []const u8,
    what: []const u8,
    network: bool,
    action: union(enum) {
        run: []const []const u8,
        /// Write `content` to `path` (Modelfile).
        write_file: struct { path: []const u8, content: []const u8 },
        /// mkdir -p
        make_dir: []const u8,
        /// Print the perplexity comparison parsed from two llama logs.
        report_ppl: struct { base_log: []const u8, new_log: []const u8, quant: []const u8 },
    },
};

pub fn setupStages(arena: std.mem.Allocator, pa: Paths) ![]Stage {
    var out: std.ArrayList(Stage) = .empty;
    try out.append(arena, .{ .label = "venv", .what = "create an isolated Python environment", .network = false, .action = .{ .run = try dupeArgv(arena, &.{ "python3", "-m", "venv", pa.venv }) } });
    try out.append(arena, .{ .label = "pip", .what = "install torch (CPU), transformers and helpers into that environment", .network = true, .action = .{ .run = try dupeArgv(arena, &.{ pa.venv_python, "-m", "pip", "install", "--disable-pip-version-check", "-r", pa.requirements }) } });
    return out.toOwnedSlice(arena);
}

fn dupeArgv(arena: std.mem.Allocator, a: []const []const u8) ![]const []const u8 {
    return arena.dupe([]const u8, a);
}

pub fn runStages(arena: std.mem.Allocator, p: Params, name: []const u8, pa: Paths) ![]Stage {
    var out: std.ArrayList(Stage) = .empty;
    const py = pa.venv_python;
    try out.append(arena, .{ .label = "workdir", .what = "create the working directory", .network = false, .action = .{ .make_dir = pa.work } });
    try out.append(arena, .{ .label = "fetch", .what = "download the full-precision source model", .network = true, .action = .{ .run = try dupeArgv(arena, &.{ py, pa.helper, "fetch", "--repo", p.repo, "--out", pa.source }) } });

    var ab: std.ArrayList([]const u8) = .empty;
    try ab.appendSlice(arena, &.{ py, pa.helper, "abliterate", "--model-dir", pa.source, "--out", pa.out_dir });
    try ab.appendSlice(arena, &.{ "--layer-frac", try std.fmt.allocPrint(arena, "{d:.2}", .{p.layer_frac}) });
    try ab.appendSlice(arena, &.{ "--n-prompts", try std.fmt.allocPrint(arena, "{d}", .{p.n_prompts}) });
    try ab.appendSlice(arena, &.{ "--holdout", try std.fmt.allocPrint(arena, "{d}", .{p.holdout}) });
    if (p.harmful_file) |f| try ab.appendSlice(arena, &.{ "--harmful", f, "--harmless", p.harmless_file.? });
    if (p.force) try ab.append(arena, "--force");
    try out.append(arena, .{ .label = "abliterate", .what = "measure the refusal direction and edit the weights (slow on CPU)", .network = p.harmful_file == null, .action = .{ .run = try ab.toOwnedSlice(arena) } });

    const is_f16 = std.mem.eql(u8, p.quant, "F16");
    const gguf_target = if (is_f16) pa.final_gguf else pa.f16_gguf;
    try out.append(arena, .{ .label = "models-dir", .what = "create the output directory", .network = false, .action = .{ .make_dir = std.fs.path.dirname(pa.final_gguf).? } });
    try out.append(arena, .{ .label = "convert", .what = "convert to GGUF (llama.cpp convert script pinned to your llama build)", .network = false, .action = .{ .run = try dupeArgv(arena, &.{ py, pa.convert_script, pa.out_dir, "--outfile", gguf_target, "--outtype", "f16" }) } });
    if (!is_f16) {
        try out.append(arena, .{ .label = "quantize", .what = "quantize with `llama quantize`", .network = false, .action = .{ .run = try dupeArgv(arena, &.{ "llama", "quantize", pa.f16_gguf, pa.final_gguf, p.quant }) } });
    }
    if (p.check_quality) {
        const chunks = try std.fmt.allocPrint(arena, "{d}", .{p.ppl_chunks});
        const text_path = p.ppl_text_file orelse pa.ppl_text;
        if (p.ppl_text_file == null) {
            try out.append(arena, .{ .label = "ppl-text", .what = "download the wikitext-2 test split as the evaluation text", .network = true, .action = .{ .run = try dupeArgv(arena, &.{ py, pa.helper, "ppl-text", "--out", pa.ppl_text }) } });
        }
        try out.append(arena, .{ .label = "convert-base", .what = "convert the ORIGINAL model to GGUF for comparison", .network = false, .action = .{ .run = try dupeArgv(arena, &.{ py, pa.convert_script, pa.source, "--outfile", pa.base_f16, "--outtype", "f16" }) } });
        var base_gguf = pa.base_f16;
        if (!is_f16) {
            try out.append(arena, .{ .label = "quantize-base", .what = "quantize the original the same way", .network = false, .action = .{ .run = try dupeArgv(arena, &.{ "llama", "quantize", pa.base_f16, pa.base_quant, p.quant }) } });
            base_gguf = pa.base_quant;
        }
        try out.append(arena, .{ .label = "ppl-base", .what = "perplexity of the original", .network = false, .action = .{ .run = try dupeArgv(arena, &.{ "llama", "perplexity", "-m", base_gguf, "-f", text_path, "-c", "512", "--chunks", chunks, "--log-file", pa.ppl_base_log }) } });
        try out.append(arena, .{ .label = "ppl-new", .what = "perplexity of the abliterated model", .network = false, .action = .{ .run = try dupeArgv(arena, &.{ "llama", "perplexity", "-m", pa.final_gguf, "-f", text_path, "-c", "512", "--chunks", chunks, "--log-file", pa.ppl_new_log }) } });
        try out.append(arena, .{ .label = "ppl-report", .what = "compare the two", .network = false, .action = .{ .report_ppl = .{ .base_log = pa.ppl_base_log, .new_log = pa.ppl_new_log, .quant = p.quant } } });
    }
    if (p.register == .ollama) {
        try out.append(arena, .{ .label = "modelfile", .what = "write an Ollama Modelfile with the right chat template for this model", .network = false, .action = .{ .run = try dupeArgv(arena, &.{ py, pa.helper, "modelfile", "--model-dir", pa.out_dir, "--gguf", pa.final_gguf, "--out", pa.modelfile }) } });
        try out.append(arena, .{ .label = "register", .what = "import into Ollama with `ollama create` (supported import path)", .network = false, .action = .{ .run = try dupeArgv(arena, &.{ "ollama", "create", name, "-f", pa.modelfile }) } });
    }
    return out.toOwnedSlice(arena);
}

pub const Ppl = struct { value: f64, err: f64 };

/// Parse "Final estimate: PPL = 12.3456 +/- 0.12345" from a llama perplexity log.
pub fn parsePpl(text: []const u8) ?Ppl {
    const key = "Final estimate: PPL = ";
    const i = std.mem.lastIndexOf(u8, text, key) orelse return null;
    var it = std.mem.tokenizeAny(u8, text[i + key.len ..], " \t\r\n");
    const v = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    var e: f64 = 0;
    if (it.next()) |pm| if (std.mem.eql(u8, pm, "+/-")) {
        e = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
    };
    return .{ .value = v, .err = e };
}

/// PYTHONPATH value so the vendored convert script can import the pinned `gguf` package.
pub fn pythonPathFor(label: []const u8, pa: Paths) ?[]const u8 {
    return if (std.mem.eql(u8, label, "convert")) pa.gguf_py else null;
}

pub const note_after =
    "Result is an abliterated model: refusal behavior removed by weight editing; outputs are not filtered by the model. Quality can degrade; check it before relying on it.";

test "repo and name validation" {
    try std.testing.expect(validRepo("Qwen/Qwen2.5-0.5B-Instruct"));
    try std.testing.expect(!validRepo("noslash"));
    try std.testing.expect(!validRepo("a/b/c"));
    try std.testing.expect(!validRepo("-x/y"));
    try std.testing.expect(!validRepo("a/b;rm"));
    try std.testing.expect(validName("qwen2.5-abliterated"));
    try std.testing.expect(!validName("Upper"));
    try std.testing.expect(!validName("a b"));
}

test "derived name" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("qwen2.5-0.5b-instruct-abliterated", try deriveName(a.allocator(), "Qwen/Qwen2.5-0.5B-Instruct"));
    try std.testing.expectEqualStrings("foo-abliterated-v2", try deriveName(a.allocator(), "x/Foo-Abliterated-v2"));
}

test "param validation" {
    try validate(.{ .repo = "a/b" });
    try std.testing.expectError(error.InvalidQuant, validate(.{ .repo = "a/b", .quant = "Q9" }));
    try std.testing.expectError(error.InvalidNumber, validate(.{ .repo = "a/b", .layer_frac = 2.0 }));
    try std.testing.expectError(error.NeedBothPromptFiles, validate(.{ .repo = "a/b", .harmful_file = "x" }));
    try std.testing.expectError(error.InvalidPath, validate(.{ .repo = "a/b", .harmful_file = "-x", .harmless_file = "y" }));
}

test "stage list: order, network flags, argv, no shell" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const p: Params = .{ .repo = "Qwen/Qwen2.5-0.5B-Instruct" };
    const pa = try paths(a.allocator(), "/d/aimgr", "/r", "m-abliterated", p.quant);
    const st = try runStages(a.allocator(), p, "m-abliterated", pa);
    const labels = [_][]const u8{ "workdir", "fetch", "abliterate", "models-dir", "convert", "quantize", "modelfile", "register" };
    try std.testing.expectEqual(labels.len, st.len);
    for (labels, st) |l, s| try std.testing.expectEqualStrings(l, s.label);
    try std.testing.expect(st[1].network and st[2].network and !st[4].network);
    try std.testing.expectEqualStrings("/d/aimgr/abliterate/venv/bin/python", st[1].action.run[0]);
    try std.testing.expectEqualStrings("llama", st[5].action.run[0]);
    try std.testing.expectEqualStrings("/d/aimgr/models/m-abliterated-Q4_K_M.gguf", st[5].action.run[3]);
    try std.testing.expectEqualStrings("modelfile", st[6].action.run[2]);
    try std.testing.expectEqualStrings("/d/aimgr/models/m-abliterated-Q4_K_M.gguf", st[6].action.run[6]);
    // own prompt files => the abliterate stage needs no network
    const p2: Params = .{ .repo = "a/b", .harmful_file = "h.txt", .harmless_file = "l.txt", .register = .none, .quant = "F16" };
    const st2 = try runStages(a.allocator(), p2, "b-abliterated", try paths(a.allocator(), "/d", "/r", "b-abliterated", "F16"));
    try std.testing.expect(!st2[2].network);
    try std.testing.expectEqual(@as(usize, 5), st2.len); // no quantize, no register
}

test "parse perplexity log" {
    const t = "load...\nFinal estimate: PPL = 13.5172 +/- 0.29845\n";
    const r = parsePpl(t).?;
    try std.testing.expectApproxEqAbs(@as(f64, 13.5172), r.value, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.29845), r.err, 1e-9);
    try std.testing.expect(parsePpl("nothing here") == null);
}

test "quality stages" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const p: Params = .{ .repo = "a/b", .check_quality = true, .register = .none };
    const st = try runStages(a.allocator(), p, "b-abliterated", try paths(a.allocator(), "/d", "/r", "b-abliterated", p.quant));
    var labels: std.ArrayList([]const u8) = .empty;
    for (st) |s| try labels.append(a.allocator(), s.label);
    const want = [_][]const u8{ "workdir", "fetch", "abliterate", "models-dir", "convert", "quantize", "ppl-text", "convert-base", "quantize-base", "ppl-base", "ppl-new", "ppl-report" };
    try std.testing.expectEqual(want.len, labels.items.len);
    for (want, labels.items) |w, l| try std.testing.expectEqualStrings(w, l);
    try std.testing.expect(st[6].network);
}

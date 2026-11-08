//! Agent policy engine: decides what a model's tool request may do. Pure functions only (no I/O),
//! so every rule is unit-tested. The model never touches these settings; its output is data.
//!
//! Decisions: `.auto` (runs without a prompt), `.ask` (needs the user's keypress, with a reason),
//! `.deny` (never runs, reason is returned to the model so it can adapt).
const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

pub const Level = enum {
    /// Chat only; no tools are offered.
    off,
    /// File tools (list_dir, read_file) inside the allowed directories.
    read_only,
    /// + an allowlist of read-only commands inside the allowed directories.
    inspect,
    /// + anything else (other commands, file writes), each one approved by the user.
    ask,

    pub fn text(self: Level) []const u8 {
        return switch (self) {
            .off => "off",
            .read_only => "read-only",
            .inspect => "inspect",
            .ask => "ask",
        };
    }

    pub fn parse(s: []const u8) ?Level {
        inline for (.{ Level.off, Level.read_only, Level.inspect, Level.ask }) |l| {
            if (std.mem.eql(u8, s, l.text())) return l;
        }
        return null;
    }

    pub fn atLeast(self: Level, other: Level) bool {
        return @backingInt(self) >= @backingInt(other);
    }
};

pub const Sandbox = enum {
    /// Use bubblewrap when it is installed.
    auto,
    bwrap,
    none,

    pub fn parse(s: []const u8) ?Sandbox {
        return std.meta.stringToEnum(Sandbox, s);
    }
};

pub const Shell = enum {
    none,
    bash,
    sh,
    dksh,
    /// Windows PowerShell 5.1 (powershell.exe), PowerShell 7 (pwsh.exe) and cmd.exe.
    powershell,
    pwsh,
    cmd,

    pub fn isWindowsShell(self: Shell) bool {
        return self == .powershell or self == .pwsh or self == .cmd;
    }

    /// Executable name looked up on PATH.
    pub fn exeName(self: Shell) []const u8 {
        return switch (self) {
            .powershell => "powershell.exe",
            .pwsh => "pwsh.exe",
            .cmd => "cmd.exe",
            else => @tagName(self),
        };
    }

    pub fn text(self: Shell) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Shell {
        return std.meta.stringToEnum(Shell, s);
    }
};

pub const Settings = struct {
    level: Level = .read_only,
    /// Absolute, normalized directories the model may work in.
    dirs: []const []const u8 = &.{},
    max_steps: u32 = 20,
    timeout_s: u32 = 20,
    max_output_kb: u32 = 64,
    /// Extra command names (no paths) treated like the built-in read-only commands.
    allow_commands: []const []const u8 = &.{},
    sandbox: Sandbox = .auto,
    /// Whether root escalation may even be *requested* (still approval-gated).
    allow_root: bool = false,
    /// Which shell run_shell uses; null = default (bash at level `ask`, otherwise none).
    shell: ?Shell = null,
    /// web_fetch / web_search tools (every request is still approval-gated).
    web: bool = false,
    /// spawn_agent tool (sub-agents never have more autonomy than their parent).
    subagents: bool = true,
    /// Start every session in plan mode (read tools + submit_plan until the user approves).
    plan: bool = false,
    /// JSON search endpoint template containing "{q}" for web_search; null = web_search is not offered.
    search_url: ?[]const u8 = null,
    /// User-written rules "tool(pattern)". A matching deny rule always wins. An allow rule only turns an
    /// approval prompt into an automatic yes; it never overrides a refusal (outside the directories, secrets,
    /// sudo, plan mode, level).
    allow_rules: []const []const u8 = &.{},
    deny_rules: []const []const u8 = &.{},
};

/// The shell run_shell would use: only at level `ask`, bash unless configured otherwise.
pub fn effectiveShell(s: Settings) Shell {
    if (s.level != .ask) return .none;
    return s.shell orelse (if (is_windows) .powershell else .bash);
}

/// Default autonomy from what the model can do. Small models are unreliable at tool use, so they get
/// the narrowest level; every default can be overridden per model.
pub fn defaultLevel(has_tools: bool, params_b: ?f64) Level {
    if (!has_tools) return .off;
    const p = params_b orelse return .read_only;
    if (p < 7.0) return .read_only;
    if (p < 30.0) return .inspect;
    return .ask;
}

pub const Decision = union(enum) {
    auto,
    ask: []const u8,
    deny: []const u8,

    pub fn isDeny(self: Decision) bool {
        return self == .deny;
    }

    /// Test helper: does this decision have the given tag?
    pub fn decisionIs(self: Decision, tag: std.meta.Tag(Decision)) bool {
        return self == tag;
    }
};

// ---------------------------------------------------------------------------------------------
// Paths

pub fn normalizePath(arena: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    return normalizeWith(is_windows, arena, base, path);
}

/// Windows: backslashes become '/' and the "\\?\\" prefix is dropped. Elsewhere the text is unchanged.
/// Inside the agent every path uses '/' (Windows file APIs accept it) and drives look like "C:/dir".
pub fn canonicalWith(win: bool, arena: std.mem.Allocator, path: []const u8) ![]u8 {
    var p = path;
    if (win) {
        if (std.mem.startsWith(u8, p, "\\\\?\\") and p.len > 4 and !std.mem.startsWith(u8, p[4..], "UNC")) p = p[4..];
    }
    const out = try arena.dupe(u8, p);
    if (win) for (out) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    return out;
}

pub fn canonical(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    return canonicalWith(is_windows, arena, path);
}

fn isDrivePrefix(p: []const u8) bool {
    return p.len >= 2 and std.ascii.isAlphabetic(p[0]) and p[1] == ':';
}

pub fn normalizeWith(win: bool, arena: std.mem.Allocator, base_in: []const u8, path_in: []const u8) ![]u8 {
    const base = try canonicalWith(win, arena, base_in);
    const path = try canonicalWith(win, arena, path_in);
    var drive: ?u8 = null;
    var joined: []const u8 = undefined;
    if (win) {
        if (isDrivePrefix(path)) {
            drive = std.ascii.toUpper(path[0]);
            joined = path[2..];
            // "C:foo" (drive-relative) is treated as "C:/foo" from the root: never relative to a hidden cwd.
        } else {
            if (isDrivePrefix(base)) drive = std.ascii.toUpper(base[0]);
            joined = if (path.len > 0 and path[0] == '/') path else try std.fmt.allocPrint(arena, "{s}/{s}", .{ if (isDrivePrefix(base)) base[2..] else base, path });
        }
    } else {
        joined = if (path.len > 0 and path[0] == '/') path else try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, path });
    }
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, joined, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, seg);
    }
    var out: std.ArrayList(u8) = .empty;
    if (drive) |dl| {
        try out.append(arena, dl);
        try out.append(arena, ':');
    }
    if (parts.items.len == 0) {
        try out.append(arena, '/');
        return out.toOwnedSlice(arena);
    }
    for (parts.items) |seg| {
        try out.append(arena, '/');
        try out.appendSlice(arena, seg);
    }
    return out.toOwnedSlice(arena);
}

/// Windows paths that can alias or escape ("\\server\share", device names like CON/NUL, "file:stream",
/// trailing dots or spaces, wildcard characters). Checked on the canonical ('/') form.
pub fn windowsPathBad(canon: []const u8) bool {
    if (std.mem.startsWith(u8, canon, "//")) return true;
    const rest = if (isDrivePrefix(canon)) canon[2..] else canon;
    if (std.mem.indexOfAny(u8, rest, ":*?\"<>|") != null) return true;
    var it = std.mem.tokenizeScalar(u8, rest, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        const last = seg[seg.len - 1];
        if ((last == '.' or last == ' ') and !std.mem.eql(u8, seg, ".") and !std.mem.eql(u8, seg, "..")) return true;
        const dot = std.mem.indexOfScalar(u8, seg, '.') orelse seg.len;
        const stem = std.mem.trimEnd(u8, seg[0..dot], " ");
        const reserved = [_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" };
        for (reserved) |r| if (std.ascii.eqlIgnoreCase(stem, r)) return true;
        if (stem.len == 4 and (std.ascii.startsWithIgnoreCase(stem, "COM") or std.ascii.startsWithIgnoreCase(stem, "LPT")) and stem[3] >= '1' and stem[3] <= '9') return true;
    }
    return false;
}

/// True if normalized `path` is `dir` or below it (component boundary, so /a/bc is not within /a/b).
/// On Windows letters compare case-insensitively.
pub fn within(dirs: []const []const u8, path: []const u8) bool {
    return withinWith(is_windows, dirs, path);
}

pub fn withinWith(win: bool, dirs: []const []const u8, path: []const u8) bool {
    // Defensive: an un-normalized path with ".." could pass a prefix check while escaping.
    var segs = std.mem.tokenizeScalar(u8, path, '/');
    while (segs.next()) |seg| if (std.mem.eql(u8, seg, "..")) return false;
    for (dirs) |d_in| {
        const d = std.mem.trimEnd(u8, d_in, "/");
        if (d.len == 0) return true; // "/" itself
        const eq = struct {
            fn f(w: bool, x: []const u8, y: []const u8) bool {
                return if (w) std.ascii.eqlIgnoreCase(x, y) else std.mem.eql(u8, x, y);
            }
        }.f;
        if (eq(win, path, d)) return true;
        if (path.len > d.len and eq(win, path[0..d.len], d) and path[d.len] == '/') return true;
    }
    return false;
}

/// File names that commonly hold secrets: never auto-read, even inside an allowed directory.
pub fn looksSensitive(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    const exact = [_][]const u8{ "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", ".env", ".netrc", ".git-credentials", ".npmrc", ".pypirc", "shadow", "gshadow", "credentials", "secrets.toml", "known_hosts" };
    for (exact) |e| if (std.ascii.eqlIgnoreCase(base, e)) return true;
    const suffixes = [_][]const u8{ ".pem", ".key", ".p12", ".pfx", ".kdbx", ".gpg", ".asc" };
    for (suffixes) |sfx| if (std.ascii.endsWithIgnoreCase(base, sfx)) return true;
    if (std.ascii.startsWithIgnoreCase(base, ".env.")) return true;
    // directories that hold secrets
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".ssh") or std.mem.eql(u8, seg, ".gnupg") or std.mem.eql(u8, seg, ".aws") or std.mem.eql(u8, seg, ".kube")) return true;
    }
    return false;
}

/// Classify reading a (normalized) path with list_dir / read_file.
pub fn classifyRead(s: Settings, path: []const u8) Decision {
    if (!s.level.atLeast(.read_only)) return .{ .deny = "tools are off for this model" };
    const inside = within(s.dirs, path);
    if (looksSensitive(path)) {
        return if (s.level == .ask) .{ .ask = "reads a file that looks like it holds secrets" } else .{ .deny = "this file looks like it holds secrets and is not readable at this level" };
    }
    if (inside) return .auto;
    // Like Claude Code: outside the folders is not forbidden, it is the user's call (asked every time).
    return .{ .ask = "reads outside the allowed directories" };
}

/// Classify writing a (normalized) path with write_file. Writes always need approval.
pub fn classifyWrite(s: Settings, path: []const u8) Decision {
    if (s.level != .ask) return .{ .deny = "writing files needs level 'ask' for this model" };
    if (!within(s.dirs, path)) return .{ .deny = "writes are only allowed inside the allowed directories" };
    if (looksSensitive(path)) return .{ .deny = "refusing to write a file that looks like it holds secrets" };
    return .{ .ask = "writes a file" };
}

// ---------------------------------------------------------------------------------------------
// Commands

pub const SplitError = error{ Empty, ShellSyntax, UnbalancedQuote, OutOfMemory };

/// Split a command string into argv. Understands single and double quotes and backslash-escaped
/// spaces, but NOT shell syntax: unquoted `; | & < > ( ) { } $ ` * ? ~ #` or a newline is an error,
/// so no second command or expansion can hide in one request.
pub fn splitCommand(arena: std.mem.Allocator, s: []const u8) SplitError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var have = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            ' ', '\t' => if (have) {
                try out.append(arena, try cur.toOwnedSlice(arena));
                cur = .empty;
                have = false;
            },
            '\'' => {
                have = true;
                i += 1;
                while (i < s.len and s[i] != '\'') : (i += 1) try cur.append(arena, s[i]);
                if (i >= s.len) return error.UnbalancedQuote;
            },
            '"' => {
                have = true;
                i += 1;
                while (i < s.len and s[i] != '"') : (i += 1) {
                    if (s[i] == '$' or s[i] == '`') return error.ShellSyntax;
                    if (s[i] == '\\' and i + 1 < s.len and (s[i + 1] == '"' or s[i + 1] == '\\')) i += 1;
                    try cur.append(arena, s[i]);
                }
                if (i >= s.len) return error.UnbalancedQuote;
            },
            '\\' => if (is_windows) {
                // A path separator, not an escape.
                have = true;
                try cur.append(arena, c);
            } else {
                if (i + 1 >= s.len) return error.ShellSyntax;
                have = true;
                i += 1;
                try cur.append(arena, s[i]);
            },
            ';', '|', '&', '<', '>', '(', ')', '{', '}', '$', '`', '*', '?', '~', '#', '\n', '\r', '!' => return error.ShellSyntax,
            0...8, 11, 12, 14...31, 127 => return error.ShellSyntax,
            else => {
                have = true;
                try cur.append(arena, c);
            },
        }
    }
    if (have) try out.append(arena, try cur.toOwnedSlice(arena));
    if (out.items.len == 0) return error.Empty;
    return out.toOwnedSlice(arena);
}

const root_escalators = [_][]const u8{ "sudo", "su", "doas", "pkexec", "run0", "gsudo" };
/// Interpreters and wrappers that can run arbitrary other commands: denied outright.
const shell_like = [_][]const u8{ "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "ash", "busybox", "env", "xargs", "nohup", "eval", "exec", "setsid", "timeout", "nice", "ionice", "stdbuf", "script", "watch", "time", "command", "builtin", "chroot", "unshare", "nsenter", "flock", "powershell", "pwsh", "cmd", "wscript", "cscript", "mshta", "wsl", "start", "runas" };
/// Interpreters that are legitimate tools but can run anything: approval-gated at level ask.
const interpreters = [_][]const u8{ "python", "python3", "perl", "ruby", "node", "nodejs", "php", "lua", "awk", "gawk", "sed", "ssh", "scp", "rsync", "curl", "wget", "nc", "ncat", "socat", "make", "cargo", "go", "zig", "gcc", "cc", "tar", "unzip", "zip", "git" };
/// Obviously destructive or system-changing: approval-gated with a stronger reason.
const destructive = [_][]const u8{ "rm", "rmdir", "mv", "cp", "dd", "shred", "truncate", "chmod", "chown", "chgrp", "ln", "mkfs", "fdisk", "parted", "mount", "umount", "kill", "killall", "pkill", "systemctl", "service", "reboot", "shutdown", "poweroff", "apt", "apt-get", "dpkg", "snap", "pip", "pip3", "npm", "useradd", "userdel", "passwd", "crontab", "iptables", "ufw", "modprobe", "insmod", "rmmod", "mkdir", "touch", "tee", "install" };
/// Commands that only read and print (further checked for flags and path arguments).
const read_only_cmds = [_][]const u8{ "ls", "cat", "head", "tail", "grep", "find", "wc", "file", "stat", "du", "df", "pwd", "tree", "basename", "dirname", "realpath", "readlink", "date", "uname", "whoami", "id", "hostname", "which", "nproc", "uptime", "free", "lsblk",
    // text tools (no file output unless noted; those are checked in readOnlyArgsOk)
    "sort", "uniq", "cut", "diff", "cmp", "comm", "nl", "tac", "rev", "strings", "column", "fold", "fmt", "expand", "jq", "echo", "printf", "seq",
    "md5sum", "sha1sum", "sha256sum", "sha512sum", "b2sum", "cksum",
    "pdftotext", "pdfinfo", "ps", "lscpu", "lspci", "lsusb", "locale" };
const windows_read_only_cmds = [_][]const u8{ "where", "hostname", "whoami", "tasklist", "findstr", "fc", "systeminfo", "pdftotext", "pdfinfo", "jq" };
const git_ok_sub = [_][]const u8{ "status", "log", "diff", "show", "branch", "ls-files", "rev-parse", "remote", "shortlog", "describe" };
const find_bad_flags = [_][]const u8{ "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls" };

fn inSet(set: []const []const u8, x: []const u8) bool {
    for (set) |e| if (std.mem.eql(u8, e, x)) return true;
    return false;
}

fn looksLikePath(a: []const u8) bool {
    return a.len > 0 and (a[0] == '/' or a[0] == '.' or a[0] == '~' or std.mem.indexOfScalar(u8, a, '/') != null);
}

pub const Command = struct {
    decision: Decision,
    /// Plain-language label shown to the user, e.g. "read-only command".
    kind: []const u8,
};

/// Classify an argv. `argv[0]` must be a bare command name (no slashes) to be auto-approvable.
pub fn classifyCommand(arena: std.mem.Allocator, s: Settings, argv: []const []const u8) !Command {
    if (argv.len == 0) return .{ .decision = .{ .deny = "empty command" }, .kind = "invalid" };
    if (!s.level.atLeast(.inspect)) return .{ .decision = .{ .deny = "running commands needs level 'inspect' or 'ask' for this model" }, .kind = "command" };
    const first = if (is_windows) try canonical(arena, argv[0]) else argv[0];
    const has_slash = std.mem.indexOfScalar(u8, first, '/') != null or (is_windows and isDrivePrefix(first));
    var name = std.fs.path.basename(first);
    if (is_windows and std.ascii.endsWithIgnoreCase(name, ".exe")) name = name[0 .. name.len - 4];

    if (inSet(&root_escalators, name)) {
        if (!s.allow_root) return .{ .decision = .{ .deny = "privilege escalation (sudo/su/doas) is disabled for this model" }, .kind = "root" };
        if (s.level != .ask) return .{ .decision = .{ .deny = "root commands need level 'ask'" }, .kind = "root" };
        return .{ .decision = .{ .ask = "WARNING: this requests ROOT privileges" }, .kind = "root command" };
    }
    if (inSet(&shell_like, name)) return .{ .decision = .{ .deny = "shell interpreters and command wrappers are not allowed; give one plain command per call" }, .kind = "shell" };

    if (!has_slash and (inSet(if (is_windows) &windows_read_only_cmds else &read_only_cmds, name) or inSet(s.allow_commands, name) or std.mem.eql(u8, name, "git"))) {
        if (try readOnlyArgsOk(arena, s, name, argv)) |why_not| return why_not;
        return .{ .decision = .auto, .kind = "read-only command" };
    }

    if (s.level != .ask) return .{ .decision = .{ .deny = "not in the read-only allowlist; this model's level does not allow approving other commands" }, .kind = "command" };
    if (has_slash) return .{ .decision = .{ .ask = "runs a program by path" }, .kind = "command by path" };
    if (inSet(&destructive, name)) return .{ .decision = .{ .ask = "can change or delete files or system state" }, .kind = "modifying command" };
    if (inSet(&interpreters, name)) return .{ .decision = .{ .ask = "can run arbitrary code or reach the network" }, .kind = "powerful command" };
    return .{ .decision = .{ .ask = "not a known read-only command" }, .kind = "command" };
}

/// For allowlisted commands: returns a non-auto Command if flags or arguments are not safe.
fn readOnlyArgsOk(arena: std.mem.Allocator, s: Settings, name: []const u8, argv: []const []const u8) !?Command {
    const escalate = struct {
        fn f(level: Level, reason: []const u8) Command {
            return if (level == .ask) .{ .decision = .{ .ask = reason }, .kind = "command" } else .{ .decision = .{ .deny = reason }, .kind = "command" };
        }
    }.f;

    if (std.mem.eql(u8, name, "git")) {
        if (argv.len < 2) return escalate(s.level, "git without a subcommand");
        if (!inSet(&git_ok_sub, argv[1])) return escalate(s.level, "git subcommand is not read-only");
        for (argv[2..]) |a| {
            if (std.mem.startsWith(u8, a, "-c") or std.mem.startsWith(u8, a, "--exec") or std.mem.startsWith(u8, a, "--output") or std.mem.indexOf(u8, a, "ext-diff") != null or std.mem.indexOf(u8, a, "textconv") != null or std.mem.startsWith(u8, a, "--upload-pack") or std.mem.startsWith(u8, a, "--git-dir") or std.mem.startsWith(u8, a, "--work-tree"))
                return escalate(s.level, "git option can run programs or write files");
        }
    }
    if (std.mem.eql(u8, name, "find")) {
        for (argv[1..]) |a| if (inSet(&find_bad_flags, a)) return escalate(s.level, "find option can run programs or write/delete files");
    }
    if (std.mem.eql(u8, name, "tail")) {
        for (argv[1..]) |a| if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "-F") or std.mem.startsWith(u8, a, "--follow")) return escalate(s.level, "tail -f never finishes");
    }
    if (std.mem.eql(u8, name, "which") or std.mem.eql(u8, name, "date")) {
        for (argv[1..]) |a| if (std.mem.startsWith(u8, a, "-s") or std.mem.startsWith(u8, a, "--set")) return escalate(s.level, "date -s changes the clock");
    }
    if (std.mem.eql(u8, name, "sort")) {
        for (argv[1..]) |a| if (std.mem.startsWith(u8, a, "-o") or std.mem.startsWith(u8, a, "--output") or std.mem.startsWith(u8, a, "--compress-program")) return escalate(s.level, "sort -o writes a file");
    }
    if (std.mem.eql(u8, name, "uniq")) {
        var operands: usize = 0;
        for (argv[1..]) |a| if (a.len == 0 or a[0] != '-') {
            operands += 1;
        };
        if (operands > 1) return escalate(s.level, "uniq with a second file name writes to it");
    }
    if (std.mem.eql(u8, name, "pdftotext")) {
        // pdftotext [options] IN.pdf [OUT.txt]: only "-" (standard output) as the last argument is read-only.
        if (argv.len < 3 or !std.mem.eql(u8, argv[argv.len - 1], "-")) return escalate(s.level, "pdftotext writes a file unless the output is '-' (read_file reads PDFs directly)");
    }
    if (std.mem.eql(u8, name, "jq")) {
        for (argv[1..]) |a| if (std.mem.startsWith(u8, a, "--rawfile") or std.mem.startsWith(u8, a, "--slurpfile") or std.mem.startsWith(u8, a, "-L")) return escalate(s.level, "jq option loads other files");
    }
    // Path-like arguments must stay inside the allowed directories (resolved relative to dirs[0]).
    const base = if (s.dirs.len > 0) s.dirs[0] else "/";
    for (argv[1..]) |a| {
        if (a.len > 0 and a[0] == '-') continue;
        if (!looksLikePath(a)) continue;
        if (a[0] == '~') return escalate(s.level, "uses ~, which is not expanded and may mean a home directory");
        const norm = try normalizePath(arena, base, a);
        if (looksSensitive(norm)) return escalate(s.level, "touches a file that looks like it holds secrets");
        // Outside the folders: the user decides (asked every time), like read_file.
        if (!within(s.dirs, norm)) return .{ .decision = .{ .ask = "reads outside the allowed directories" }, .kind = "read-only command" };
    }
    return null;
}

// ---------------------------------------------------------------------------------------------
// Allow / deny rules, e.g.  run_command(git status*)   run_shell(zig build test)   edit_file(/stuff/Books/notes/*)
//   deny=web_fetch(*.example.com/*)   *(...) matches any tool. `*` in a pattern matches any characters.

pub const Rule = struct { tool: []const u8, pattern: []const u8 };

pub fn parseRule(rule: []const u8) ?Rule {
    const open = std.mem.indexOfScalar(u8, rule, '(') orelse return null;
    if (rule.len < open + 3 or rule[rule.len - 1] != ')' or open == 0) return null;
    const tool = rule[0..open];
    const pat = rule[open + 1 .. rule.len - 1];
    if (pat.len == 0 or pat.len > 300) return null;
    for (tool) |c| if (!(std.ascii.isLower(c) or c == '_' or c == '*')) return null;
    for (pat) |c| if (c < 0x20 or c == 0x7f) return null;
    return .{ .tool = tool, .pattern = pat };
}

/// `*` matches any run of characters (including none, and including `/`); everything else is literal.
pub fn wildcardMatch(pat: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (t < text.len) {
        if (p < pat.len and pat[p] == '*') {
            star = p;
            mark = t;
            p += 1;
        } else if (p < pat.len and pat[p] == text[t]) {
            p += 1;
            t += 1;
        } else if (star) |sp| {
            p = sp + 1;
            mark += 1;
            t = mark;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

/// Characters that give a shell string a second meaning (chaining, redirection, expansion, newlines).
pub fn hasShellMeta(subject: []const u8) bool {
    return std.mem.indexOfAny(u8, subject, ";|&<>$`()\n\r\\{}!^%") != null;
}

pub const RuleResult = union(enum) {
    none,
    allow: []const u8,
    deny: []const u8,
};

/// Deny rules first, then allow rules. For shell-type tools an allow rule with a wildcard is ignored when
/// the command contains shell metacharacters, so `run_shell(git status*)` cannot be used to smuggle `; rm`.
pub fn ruleCheck(s: Settings, tool: []const u8, subject: []const u8) RuleResult {
    for (s.deny_rules) |r| {
        const pr = parseRule(r) orelse continue;
        if ((std.mem.eql(u8, pr.tool, "*") or std.mem.eql(u8, pr.tool, tool)) and wildcardMatch(pr.pattern, subject)) return .{ .deny = r };
    }
    const shellish = std.mem.eql(u8, tool, "run_shell") or std.mem.eql(u8, tool, "run_background");
    for (s.allow_rules) |r| {
        const pr = parseRule(r) orelse continue;
        if (!(std.mem.eql(u8, pr.tool, "*") or std.mem.eql(u8, pr.tool, tool))) continue;
        if (!wildcardMatch(pr.pattern, subject)) continue;
        if (shellish and hasShellMeta(subject) and std.mem.indexOfScalar(u8, pr.pattern, '*') != null) continue;
        return .{ .allow = r };
    }
    return .none;
}

// ---------------------------------------------------------------------------------------------
// Tests

fn testSettings(level: Level) Settings {
    return .{ .level = level, .dirs = &.{"/stuff/Books"} };
}

fn cmd(a: std.mem.Allocator, s: Settings, line: []const u8) !Command {
    return classifyCommand(a, s, try splitCommand(a, line));
}

fn expectAuto(c: Command) !void {
    try std.testing.expect(c.decision == .auto);
}
fn expectAsk(c: Command) !void {
    try std.testing.expect(c.decision == .ask);
}
fn expectDeny(c: Command) !void {
    try std.testing.expect(c.decision == .deny);
}

test "default levels follow capability and size" {
    try std.testing.expectEqual(Level.off, defaultLevel(false, 70));
    try std.testing.expectEqual(Level.read_only, defaultLevel(true, 0.5));
    try std.testing.expectEqual(Level.read_only, defaultLevel(true, null));
    try std.testing.expectEqual(Level.inspect, defaultLevel(true, 11.9));
    try std.testing.expectEqual(Level.inspect, defaultLevel(true, 27));
    try std.testing.expectEqual(Level.ask, defaultLevel(true, 32));
}

test "path normalization and containment" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectEqualStrings("/stuff/Books/x", try normalizePath(a, "/stuff/Books", "x"));
    try std.testing.expectEqualStrings("/stuff", try normalizePath(a, "/stuff/Books", ".."));
    try std.testing.expectEqualStrings("/etc/passwd", try normalizePath(a, "/stuff/Books", "../../etc/passwd"));
    try std.testing.expectEqualStrings("/", try normalizePath(a, "/a", "../../../.."));
    try std.testing.expectEqualStrings("/stuff/Books/a/b", try normalizePath(a, "/x", "/stuff//Books/./a/b/"));
    const dirs = [_][]const u8{"/stuff/Books"};
    try std.testing.expect(within(&dirs, "/stuff/Books"));
    try std.testing.expect(within(&dirs, "/stuff/Books/Animals/a.txt"));
    try std.testing.expect(!within(&dirs, "/stuff/BooksEvil/x")); // component boundary
    try std.testing.expect(!within(&dirs, "/stuff"));
    try std.testing.expect(!within(&dirs, "/stuff/Books/../Secrets")); // ".." is rejected even un-normalized
}

test "reads: inside is automatic, outside depends on level, secrets are never automatic" {
    const ro = testSettings(.read_only);
    try std.testing.expect(classifyRead(ro, "/stuff/Books/Animals").decisionIs(.auto));
    try std.testing.expect(classifyRead(ro, "/etc/passwd").decisionIs(.ask));
    try std.testing.expect(classifyRead(testSettings(.ask), "/etc/passwd").decisionIs(.ask));
    try std.testing.expect(classifyRead(ro, "/stuff/Books/.env").decisionIs(.deny));
    try std.testing.expect(classifyRead(testSettings(.ask), "/stuff/Books/.ssh/id_ed25519").decisionIs(.ask));
    try std.testing.expect(classifyRead(testSettings(.off), "/stuff/Books/a").decisionIs(.deny));
}

test "writes always need approval and stay inside" {
    try std.testing.expect(classifyWrite(testSettings(.inspect), "/stuff/Books/n.txt").decisionIs(.deny));
    try std.testing.expect(classifyWrite(testSettings(.ask), "/stuff/Books/n.txt").decisionIs(.ask));
    try std.testing.expect(classifyWrite(testSettings(.ask), "/etc/cron.d/x").decisionIs(.deny));
    try std.testing.expect(classifyWrite(testSettings(.ask), "/stuff/Books/.env").decisionIs(.deny));
}

test "command splitting refuses shell syntax" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const ok = try splitCommand(a, "grep -rn 'two words' ./Animals");
    try std.testing.expectEqual(@as(usize, 4), ok.len);
    try std.testing.expectEqualStrings("two words", ok[2]);
    try std.testing.expectEqualStrings("a b", (try splitCommand(a, "ls a\\ b"))[1]);
    for ([_][]const u8{ "ls; rm -rf /", "ls && id", "ls | head", "cat a > b", "echo $(id)", "echo `id`", "ls *", "ls ~", "ls\nid", "cat \"$HOME\"", "ls (x)" }) |bad| {
        try std.testing.expectError(error.ShellSyntax, splitCommand(a, bad));
    }
    try std.testing.expectError(error.UnbalancedQuote, splitCommand(a, "ls 'x"));
    try std.testing.expectError(error.Empty, splitCommand(a, "   "));
    // metacharacters inside single quotes are literal data (an argument), not syntax
    try std.testing.expectEqualStrings("a;b", (try splitCommand(a, "grep 'a;b' f"))[1]);
}

test "read-only commands inside the directory run automatically" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = testSettings(.inspect);
    try expectAuto(try cmd(a, s, "ls -la /stuff/Books/Animals"));
    try expectAuto(try cmd(a, s, "ls"));
    try expectAuto(try cmd(a, s, "cat /stuff/Books/Animals/a.txt"));
    try expectAuto(try cmd(a, s, "grep -rn lion /stuff/Books"));
    try expectAuto(try cmd(a, s, "head -n 5 notes.txt"));
    try expectAuto(try cmd(a, s, "find /stuff/Books -name notes.txt"));
    try expectAuto(try cmd(a, s, "wc -l /stuff/Books/Arms"));
    try expectAuto(try cmd(a, s, "git status"));
    try expectAuto(try cmd(a, s, "git log -n 3"));
}

test "outside the directory, traversal, and secrets are not automatic" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = testSettings(.inspect);
    // Outside the folder is never automatic: the user is asked (at every level), like Claude Code.
    try expectAsk(try cmd(a, s, "cat /etc/passwd"));
    try expectAsk(try cmd(a, s, "cat ../../etc/passwd"));
    try expectAsk(try cmd(a, s, "ls /stuff/BooksEvil"));
    try expectAsk(try cmd(a, s, "cat /stuff/Books/../Secrets/x"));
    try expectDeny(try cmd(a, s, "cat /stuff/Books/.env")); // secrets: denied below level ask
    try expectAsk(try cmd(a, s, "ls /home"));
    // same requests at level ask become approvals, not silent runs
    const k = testSettings(.ask);
    try expectAsk(try cmd(a, k, "cat /etc/passwd"));
    try expectAsk(try cmd(a, k, "cat /stuff/Books/.env"));
}

test "basic text commands, and their file-writing forms" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = testSettings(.inspect);
    try expectAuto(try cmd(a, s, "sort /stuff/Books/list.txt"));
    try expectAuto(try cmd(a, s, "uniq -c /stuff/Books/list.txt"));
    try expectAuto(try cmd(a, s, "sha256sum /stuff/Books/a.pdf"));
    try expectAuto(try cmd(a, s, "pdftotext -l 2 /stuff/Books/a.pdf -"));
    try expectAuto(try cmd(a, s, "jq .name /stuff/Books/x.json"));
    try expectDeny(try cmd(a, s, "sort -o /stuff/Books/out /stuff/Books/in"));
    try expectDeny(try cmd(a, s, "uniq /stuff/Books/in /stuff/Books/out"));
    try expectDeny(try cmd(a, s, "pdftotext /stuff/Books/a.pdf /stuff/Books/a.txt"));
    try expectDeny(try cmd(a, s, "pdftotext /stuff/Books/a.pdf"));
}

test "dangerous flags on allowlisted commands" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = testSettings(.inspect);
    try expectDeny(try cmd(a, s, "find /stuff/Books -delete"));
    try expectDeny(try cmd(a, s, "find /stuff/Books -exec cat x"));
    try expectDeny(try cmd(a, s, "tail -f /stuff/Books/log"));
    try expectDeny(try cmd(a, s, "git push"));
    try expectDeny(try cmd(a, s, "git -c core.pager=x log"));
    try expectDeny(try cmd(a, s, "git diff --output=/tmp/x"));
    try expectDeny(try cmd(a, s, "git log --ext-diff"));
}

test "root escalation and shells" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_]Level{ .inspect, .ask }) |lv| {
        const s = testSettings(lv);
        try expectDeny(try cmd(a, s, "sudo ls"));
        try expectDeny(try cmd(a, s, "su -"));
        try expectDeny(try cmd(a, s, "bash -c id"));
        try expectDeny(try cmd(a, s, "sh script.sh"));
        try expectDeny(try cmd(a, s, "env FOO=1 ls"));
        try expectDeny(try cmd(a, s, "xargs rm"));
        try expectDeny(try cmd(a, s, "timeout 5 ls"));
    }
    var root = testSettings(.ask);
    root.allow_root = true;
    try expectAsk(try cmd(a, root, "sudo ls"));
    var root_low = testSettings(.inspect);
    root_low.allow_root = true;
    try expectDeny(try cmd(a, root_low, "sudo ls"));
    try expectDeny(try cmd(a, root, "bash -c id")); // allow_root never re-enables shells
}

test "everything else: denied at inspect, approval-gated at ask" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const i = testSettings(.inspect);
    const k = testSettings(.ask);
    try expectDeny(try cmd(a, i, "rm /stuff/Books/a.txt"));
    try expectDeny(try cmd(a, i, "python3 x.py"));
    try expectAsk(try cmd(a, k, "rm /stuff/Books/a.txt"));
    try expectAsk(try cmd(a, k, "python3 x.py"));
    try expectAsk(try cmd(a, k, "mv a b"));
    try expectAsk(try cmd(a, k, "/usr/bin/ls"));
    try expectAsk(try cmd(a, k, "somethingunknown --flag"));
    try expectDeny(try cmd(a, testSettings(.read_only), "ls")); // commands need inspect
    try expectDeny(try cmd(a, testSettings(.off), "ls"));
}

test "user-extended allowlist" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var s = testSettings(.inspect);
    try expectDeny(try cmd(a, s, "xxd /stuff/Books/Arms")); // not built in
    s.allow_commands = &.{"xxd"};
    try expectAuto(try cmd(a, s, "xxd /stuff/Books/Arms"));
    try expectAsk(try cmd(a, s, "xxd /etc/hostname")); // outside: the user decides
}

test "sensitive names" {
    try std.testing.expect(looksSensitive("/h/.ssh/config"));
    try std.testing.expect(looksSensitive("/x/server.pem"));
    try std.testing.expect(looksSensitive("/x/.env.production"));
    try std.testing.expect(looksSensitive("/x/ID_RSA"));
    try std.testing.expect(!looksSensitive("/stuff/Books/Animals/environment.txt"));
}

test "shell availability follows the level" {
    try std.testing.expectEqual(Shell.none, effectiveShell(.{ .level = .inspect }));
    try std.testing.expectEqual(Shell.bash, effectiveShell(.{ .level = .ask }));
    try std.testing.expectEqual(Shell.dksh, effectiveShell(.{ .level = .ask, .shell = .dksh }));
    try std.testing.expectEqual(Shell.none, effectiveShell(.{ .level = .ask, .shell = .none }));
    try std.testing.expectEqual(Shell.none, effectiveShell(.{ .level = .read_only, .shell = .bash })); // setting cannot raise the level's reach
    try std.testing.expectEqual(@as(?Shell, .sh), Shell.parse("sh"));
    try std.testing.expectEqual(@as(?Shell, null), Shell.parse("zsh"));
}

test "rule parsing" {
    const r = parseRule("run_command(git status*)").?;
    try std.testing.expectEqualStrings("run_command", r.tool);
    try std.testing.expectEqualStrings("git status*", r.pattern);
    try std.testing.expect(parseRule("*(foo)") != null);
    for ([_][]const u8{ "", "run_command", "run_command()", "(x)", "Run(x)", "run_command(x", "run command(x)", "a(b\nc)" }) |bad| try std.testing.expect(parseRule(bad) == null);
}

test "wildcards" {
    try std.testing.expect(wildcardMatch("git status*", "git status -s"));
    try std.testing.expect(wildcardMatch("git status*", "git status"));
    try std.testing.expect(!wildcardMatch("git status*", "git push"));
    try std.testing.expect(wildcardMatch("*.txt", "/a/b/c.txt"));
    try std.testing.expect(wildcardMatch("/stuff/*/notes/*", "/stuff/Books/notes/a.md"));
    try std.testing.expect(!wildcardMatch("/stuff/Books/*", "/stuff/Other/x"));
    try std.testing.expect(wildcardMatch("*", ""));
    try std.testing.expect(wildcardMatch("a*b*c", "aXXbYYc"));
    try std.testing.expect(!wildcardMatch("a*b*c", "aXXbYY"));
    try std.testing.expect(wildcardMatch("exact", "exact") and !wildcardMatch("exact", "exactly"));
}

test "deny beats allow; shell allow-rules cannot be chained" {
    const s: Settings = .{
        .level = .ask,
        .allow_rules = &.{ "run_command(git status*)", "run_shell(zig build*)", "run_shell(echo hi)", "edit_file(/work/*)" },
        .deny_rules = &.{ "edit_file(*/secrets/*)", "*(*.pem)" },
    };
    try std.testing.expect(ruleCheck(s, "run_command", "git status -s") == .allow);
    try std.testing.expect(ruleCheck(s, "run_command", "git push") == .none);
    try std.testing.expect(ruleCheck(s, "edit_file", "/work/a.txt") == .allow);
    try std.testing.expect(ruleCheck(s, "edit_file", "/work/secrets/a.txt") == .deny); // deny wins over the allow above
    try std.testing.expect(ruleCheck(s, "read_file", "/x/key.pem") == .deny); // any tool
    // run_shell: a wildcard allow does not cover chained / redirected / expanded commands
    try std.testing.expect(ruleCheck(s, "run_shell", "zig build test") == .allow);
    try std.testing.expect(ruleCheck(s, "run_shell", "zig build && rm -rf ~") == .none);
    try std.testing.expect(ruleCheck(s, "run_shell", "zig build; id") == .none);
    try std.testing.expect(ruleCheck(s, "run_shell", "zig build $(id)") == .none);
    try std.testing.expect(ruleCheck(s, "run_shell", "echo hi") == .allow); // exact rule, no wildcard
    try std.testing.expect(ruleCheck(s, "run_shell", "echo hi; id") == .none);
    try std.testing.expect(hasShellMeta("a | b") and hasShellMeta("a\nb") and !hasShellMeta("zig build test"));
}

test "windows path rules (checked on any host)" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    try std.testing.expectEqualStrings("C:/Users/me/x.txt", try normalizeWith(true, al, "C:/Users/me", "x.txt"));
    try std.testing.expectEqualStrings("C:/Users/me/sub/y", try normalizeWith(true, al, "C:\\Users\\me", "sub\\y"));
    try std.testing.expectEqualStrings("D:/data/z", try normalizeWith(true, al, "C:/Users/me", "d:\\data\\z"));
    try std.testing.expectEqualStrings("C:/Users", try normalizeWith(true, al, "C:/Users/me", "../"));
    try std.testing.expectEqualStrings("C:/", try normalizeWith(true, al, "C:/Users/me", "../../.."));
    try std.testing.expectEqualStrings("C:/etc", try normalizeWith(true, al, "C:/Users/me", "/etc"));
    try std.testing.expectEqualStrings("C:/Users/me/x", try normalizeWith(true, al, "\\\\?\\C:\\Users\\me", "x"));
    const dirs = [_][]const u8{"C:/Users/me"};
    try std.testing.expect(withinWith(true, &dirs, "c:/users/ME/doc.txt"));
    try std.testing.expect(!withinWith(true, &dirs, "C:/Users/mex/doc.txt"));
    try std.testing.expect(!withinWith(true, &dirs, "D:/Users/me"));
    try std.testing.expect(withinWith(true, &.{"C:/"}, "C:/anything"));
    try std.testing.expect(!withinWith(true, &.{"C:/"}, "D:/anything"));
    // posix stays case-sensitive
    try std.testing.expect(!withinWith(false, &.{"/a/B"}, "/a/b/c"));
}

test "windows path hazards" {
    for ([_][]const u8{ "//server/share/x", "C:/dir/NUL", "C:/dir/nul.txt", "C:/COM1", "C:/a/file.txt:stream", "C:/a/b.", "C:/a/b ", "C:/a/*.txt", "C:/a/LPT3.log" }) |bad| {
        try std.testing.expect(windowsPathBad(bad));
    }
    for ([_][]const u8{ "C:/Users/me/readme.md", "C:/a/console.txt", "D:/x/COM10", "C:/a/.git/config" }) |ok| {
        try std.testing.expect(!windowsPathBad(ok));
    }
}

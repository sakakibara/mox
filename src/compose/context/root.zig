//! The lexical context a capture sits in, so its value is written the way
//! that context reads it back. Each format has a tracker fed the literal
//! text compose emits; before a capture it names the capture's context, and
//! after the file it says whether the file could be followed to its end.
//! A value is encoded for its context or refused, and feeding the encoded
//! value must leave the tracker's state as it was.

const std = @import("std");

pub const toml = @import("toml.zig");
pub const yaml = @import("yaml.zig");
pub const ini = @import("ini.zig");
pub const shell = @import("shell.zig");
pub const powershell = @import("powershell.zig");

pub const types = @import("types.zig");
pub const encode = @import("encode.zig");
pub const encoder = @import("encoder.zig");
pub const Encoder = encoder.Encoder;
const format_mod = @import("../../source/format.zig");
pub const Encoding = types.Encoding;
pub const Context = types.Context;

/// The context after `prefix` in a file `kind` tracks.
pub fn contextAfter(kind: Kind, prefix: []const u8) Context {
    var t = Tracker.init(kind);
    t.feed(prefix);
    return t.context();
}

/// The tracker kinds.
pub const Kind = enum { toml, yaml, ini, gitconfig, sh, fish, powershell, text };

const shell_basenames = [_][]const u8{ ".profile", ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout", ".envrc" };

/// The tracker for a file at `path` of structured `format` whose text starts
/// with `head`. The JSON family keeps its own per-token expansion and takes
/// `.text` here.
pub fn kindFor(format: ?format_mod.Format, path: []const u8, head: []const u8) Kind {
    if (format) |f| return switch (f) {
        .toml => .toml,
        .yaml => .yaml,
        .ini => .ini,
        .gitconfig => .gitconfig,
        .json, .jsonc => .text,
    };
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".fish")) return .fish;
    for ([_][]const u8{ ".ps1", ".psm1", ".psd1" }) |ext| if (std.mem.endsWith(u8, base, ext)) return .powershell;
    for ([_][]const u8{ ".sh", ".bash", ".zsh" }) |ext| if (std.mem.endsWith(u8, base, ext)) return .sh;
    for (shell_basenames) |n| if (std.mem.eql(u8, base, n)) return .sh;
    const first = head[0 .. std.mem.indexOfScalar(u8, head, '\n') orelse head.len];
    if (std.mem.startsWith(u8, first, "#compdef")) return .sh;
    if (std.mem.startsWith(u8, first, "#!")) {
        var words = std.mem.tokenizeAny(u8, first[2..], " \t");
        var prog = std.fs.path.basename(words.next() orelse return .text);
        if (std.mem.eql(u8, prog, "env")) prog = words.next() orelse return .text;
        if (std.mem.eql(u8, prog, "fish")) return .fish;
        for ([_][]const u8{ "sh", "bash", "zsh", "dash", "ksh" }) |sh| if (std.mem.eql(u8, prog, sh)) return .sh;
    }
    return .text;
}

/// A tracker of any kind. Each kind's tracker is a value type with:
/// `init() T`, `feed(*T, bytes)` for literal text, `context(*const T)
/// Context` at the current position, `same(before, after) bool` for the
/// re-lex check (directional: `before` is the state where a value starts,
/// `after` the state once its encoded bytes are fed; a value may move a
/// tracker from a token's start into its interior), and `finish(*const T) ?[]const u8`, why the file could
/// not be followed to its end at top level (an unclosed quote, heredoc,
/// `$(`, string or block), or null; and `atLineTop(*const T) bool`.
pub const Tracker = union(Kind) {
    toml: toml.Tracker,
    yaml: yaml.Tracker,
    ini: ini.Tracker,
    gitconfig: ini.Tracker,
    sh: shell.Tracker,
    fish: shell.Tracker,
    powershell: powershell.Tracker,
    text: void,

    pub fn init(kind: Kind) Tracker {
        return switch (kind) {
            .toml => .{ .toml = toml.Tracker.init() },
            .yaml => .{ .yaml = yaml.Tracker.init() },
            .ini => .{ .ini = ini.Tracker.init(.generic) },
            .gitconfig => .{ .gitconfig = ini.Tracker.init(.gitconfig) },
            .sh => .{ .sh = shell.Tracker.init(.posix) },
            .fish => .{ .fish = shell.Tracker.init(.fish) },
            .powershell => .{ .powershell = powershell.Tracker.init() },
            .text => .text,
        };
    }

    pub fn feed(t: *Tracker, bytes: []const u8) void {
        switch (t.*) {
            .text => {},
            inline else => |*x| x.feed(bytes),
        }
    }

    pub fn context(t: *const Tracker) Context {
        return switch (t.*) {
            .text => .{ .enc = .raw },
            inline else => |*x| x.context(),
        };
    }

    pub fn same(a: *const Tracker, b: *const Tracker) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .text => true,
            inline else => |*x, tag| x.same(&@field(b.*, @tagName(tag))),
        };
    }

    pub fn finish(t: *const Tracker) ?[]const u8 {
        return switch (t.*) {
            .text => null,
            inline else => |*x| x.finish(),
        };
    }

    /// Whether the next byte starts a line outside every string, heredoc,
    /// block and bracket: where the `# mox: secret` directive's whole lines
    /// may begin and must end.
    pub fn atLineTop(t: *const Tracker) bool {
        return switch (t.*) {
            .text => true,
            inline else => |*x| x.atLineTop(),
        };
    }
};

test "kindFor: a structured format, a shell by name, extension, shebang or compdef, PowerShell, else text" {
    try std.testing.expectEqual(Kind.toml, kindFor(.toml, "a/x.toml", ""));
    try std.testing.expectEqual(Kind.text, kindFor(.jsonc, "a/x.jsonc", ""));
    try std.testing.expectEqual(Kind.sh, kindFor(null, "/h/.zshrc", ""));
    try std.testing.expectEqual(Kind.fish, kindFor(null, "/h/c/config.fish", ""));
    try std.testing.expectEqual(Kind.powershell, kindFor(null, "/h/p.ps1", ""));
    try std.testing.expectEqual(Kind.sh, kindFor(null, "/h/bin/tool", "#!/usr/bin/env zsh\necho\n"));
    try std.testing.expectEqual(Kind.sh, kindFor(null, "/h/.zcomp/_x", "#compdef x\n"));
    try std.testing.expectEqual(Kind.fish, kindFor(null, "/h/bin/f", "#!/opt/homebrew/bin/fish\n"));
    try std.testing.expectEqual(Kind.text, kindFor(null, "/h/notes.txt", "hello\n"));
}

test {
    _ = types;
    _ = encode;
    _ = encoder;
    _ = toml;
    _ = yaml;
    _ = ini;
    _ = shell;
    _ = powershell;
}

test "atLineTop: a line start outside every string, heredoc, block and bracket, for every kind" {
    const cases = [_]struct { kind: Kind, prefix: []const u8, top: bool }{
        .{ .kind = .toml, .prefix = "", .top = true },
        .{ .kind = .toml, .prefix = "a = 1\n[t]\n", .top = true },
        .{ .kind = .toml, .prefix = "a = 1", .top = false },
        .{ .kind = .toml, .prefix = "a = \"\"\"\n", .top = false },
        .{ .kind = .toml, .prefix = "a = [\n", .top = false },
        .{ .kind = .yaml, .prefix = "a: 1\n", .top = true },
        .{ .kind = .yaml, .prefix = "a: |\n  x\n", .top = false },
        .{ .kind = .yaml, .prefix = "a: \"x\n", .top = false },
        .{ .kind = .yaml, .prefix = "a: [1,\n", .top = false },
        .{ .kind = .ini, .prefix = "[s]\na=1\n", .top = true },
        .{ .kind = .ini, .prefix = "a=1", .top = false },
        .{ .kind = .gitconfig, .prefix = "[s]\n\ta = 1\n", .top = true },
        .{ .kind = .sh, .prefix = "echo a\n# c\n", .top = true },
        .{ .kind = .sh, .prefix = "echo a \\\n", .top = false },
        .{ .kind = .sh, .prefix = "cat <<EOF\n", .top = false },
        .{ .kind = .sh, .prefix = "x=\"\n", .top = false },
        .{ .kind = .sh, .prefix = "x=$(\n", .top = false },
        .{ .kind = .fish, .prefix = "echo a\n", .top = true },
        .{ .kind = .fish, .prefix = "echo 'a\n", .top = false },
        .{ .kind = .powershell, .prefix = "$a = 1\n", .top = true },
        .{ .kind = .powershell, .prefix = "$a = @\"\n", .top = false },
        .{ .kind = .powershell, .prefix = "Get-X `\n", .top = false },
        .{ .kind = .powershell, .prefix = "<# c\n", .top = false },
        .{ .kind = .text, .prefix = "anything \"\n", .top = true },
    };
    for (cases) |c| {
        var t = Tracker.init(c.kind);
        t.feed(c.prefix);
        std.testing.expectEqual(c.top, t.atLineTop()) catch |e| {
            std.debug.print("{s} after {f}\n", .{ @tagName(c.kind), std.zig.fmtString(c.prefix) });
            return e;
        };
    }
}

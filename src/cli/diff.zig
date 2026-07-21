//! `mox diff`: show, per managed file, a unified diff of the composed output
//! against the current live file. Read-only: takes no lock and writes nothing.
//! `--stat` prints a one-line added/removed summary per file instead of the
//! full hunks. Always exits 0 (reporting drift is not an error).

const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");

const Io = std.Io;
const Hunk = mox.diff.lines.Hunk;

const max_file_bytes: usize = 64 * 1024 * 1024;

/// Added/removed line counts for one file's diff.
pub const Stat = struct {
    added: usize = 0,
    removed: usize = 0,
};

/// Sum the added (`+`, from composed) and removed (`-`, from live) line counts
/// across every hunk. `a` is the live side, `b` the composed side.
pub fn statOf(hunks: []const Hunk) Stat {
    var s: Stat = .{};
    for (hunks) |h| {
        s.removed += h.a_len;
        s.added += h.b_len;
    }
    return s;
}

/// Render a unified diff for one file. `a_lines` is the live content, `b_lines`
/// the composed content, `hunks` the edit script turning live into composed.
/// `a_secret` / `b_secret` mark, per line, whether that line's provenance is a
/// resolved secret: any hunk touching a secret line has BOTH its sides redacted
/// to `secret_redaction`, so `mox diff` never prints a resolved secret value.
/// An empty mask means no secret info for that side (nothing redacted).
/// Returns arena-owned bytes; an empty string when there are no hunks.
pub fn renderFile(
    arena: std.mem.Allocator,
    label: []const u8,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
    hunks: []const Hunk,
    a_secret: []const bool,
    b_secret: []const bool,
) ![]u8 {
    if (hunks.len == 0) return "";
    const redaction = mox.provenance.map.secret_redaction;
    var aw: Io.Writer.Allocating = .init(arena);
    const out = &aw.writer;
    try out.print("--- {s} (live)\n", .{label});
    try out.print("+++ {s} (composed)\n", .{label});
    for (hunks) |h| {
        try out.print("@@ -{d},{d} +{d},{d} @@\n", .{ h.a_start + 1, h.a_len, h.b_start + 1, h.b_len });
        // Redact the whole hunk when a secret line sits on either side: the two
        // sides of a rotated/removed secret pair up here, and over-redacting a
        // mixed hunk in the DISPLAY is safe where leaking a value is not.
        const secret = hunkTouchesSecret(h, a_secret, b_secret);
        var i: u32 = 0;
        while (i < h.a_len) : (i += 1) {
            const line = if (secret) redaction else a_lines[h.a_start + i];
            try out.print("-{s}\n", .{line});
        }
        i = 0;
        while (i < h.b_len) : (i += 1) {
            const line = if (secret) redaction else b_lines[h.b_start + i];
            try out.print("+{s}\n", .{line});
        }
    }
    return aw.toOwnedSlice();
}

/// A hunk touches a secret when any live-side line (per persisted provenance) or
/// composed-side line (per fresh provenance) in its range is a resolved secret.
fn hunkTouchesSecret(h: Hunk, a_secret: []const bool, b_secret: []const bool) bool {
    var i: u32 = 0;
    while (i < h.a_len) : (i += 1) {
        const idx = h.a_start + i;
        if (idx < a_secret.len and a_secret[idx]) return true;
    }
    i = 0;
    while (i < h.b_len) : (i += 1) {
        const idx = h.b_start + i;
        if (idx < b_secret.len and b_secret[idx]) return true;
    }
    return false;
}

/// Build a per-line secret mask of length `count` from provenance `segments`:
/// `mask[i]` is true when output line `i` is covered by a `.secret` segment.
fn secretMask(arena: std.mem.Allocator, count: usize, segments: []const mox.provenance.map.Segment) ![]const bool {
    const mask = try arena.alloc(bool, count);
    @memset(mask, false);
    for (segments) |s| {
        if (s.origin != .secret) continue;
        var i: u32 = s.out_start;
        while (i < s.out_start + s.out_len and i < count) : (i += 1) mask[i] = true;
    }
    return mask;
}

const Spec = struct {
    stat: cli.spec.Flag(.{ .help = "per-file added/removed summary instead of full hunks" }),
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const stat_mode = a.stat;

    const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env);
    var bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);

    var secret_cache = mox.secret.cache.Cache.init(ctx.alloc);
    const secrets: mox.compose.catB.SecretCtx = .{ .env = context.env, .cache = &secret_cache };

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    const base_tree = mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, m_state.home) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox diff: source tree not found at {s}\n", .{src_dir});
            return 0;
        },
        else => return e,
    };
    const tree = try mox.private.layer.merge(ctx.alloc, ctx.io, base_tree, context.paths.private_dir, m_state.home);

    const ruleset = try mox.source.ignore.load.load(ctx.alloc, ctx.io, context.paths.repo_dir);
    const home = m_state.home;

    var total: Stat = .{};
    var changed: usize = 0;

    for (tree.files) |file| {
        // A tracked source matching an ignore rule (itself or a containing
        // directory) is never applied, so diff has nothing to compare it against.
        const rel = try mox.source.path.liveKeyRelToHome(ctx.alloc, home, file.live_path);
        if (ruleset.isPathIgnored(rel, false)) continue;
        // Seed-once and symlink files carry no line-level composed content to
        // diff (user-owned after first write / target-only respectively).
        if (file.create_once or file.is_symlink) continue;

        // Track provenance so secret-covered lines can be redacted from the
        // printed diff: the resolved secret is inlined into the composed bytes,
        // and must never reach stdout.
        var prov: std.ArrayList(mox.provenance.map.Segment) = .empty;
        var diag: mox.compose.interp.Diag = .{};
        const composed = mox.compose.composeFileTracked(ctx.alloc, ctx.io, file, &bindings, &m_state, secrets, &prov, &diag) catch |e| {
            try ctx.err.print("mox diff: {s}: compose failed: {s}\n", .{ file.live_path, @errorName(e) });
            if (diag.capture()) |cap|
                try ctx.err.print("mox diff:   failing item: {s}\n", .{cap});
            continue;
        };
        // Axis-gated off for this machine: nothing to compose, nothing to diff.
        const composed_bytes = composed orelse continue;

        const live: []const u8 = Io.Dir.cwd().readFileAlloc(ctx.io, file.live_path, ctx.alloc, .limited(max_file_bytes)) catch |e| switch (e) {
            error.FileNotFound => "",
            else => return e,
        };
        if (std.mem.eql(u8, live, composed_bytes)) continue;

        const a_lines = try mox.diff.lines.splitLines(ctx.alloc, live);
        const b_lines = try mox.diff.lines.splitLines(ctx.alloc, composed_bytes);
        const hunks = mox.diff.lines.diff(ctx.alloc, a_lines, b_lines) catch |e| switch (e) {
            error.TooManyLines => {
                try ctx.err.print("mox diff: {s}: too large to diff\n", .{file.live_path});
                continue;
            },
            else => return e,
        };
        if (hunks.len == 0) continue;

        changed += 1;
        const s = statOf(hunks);
        total.added += s.added;
        total.removed += s.removed;

        if (stat_mode) {
            try ctx.out.print(" {s} | +{d} -{d}\n", .{ file.live_path, s.added, s.removed });
        } else {
            // Composed-side secrets come from this compose's provenance; live-side
            // secrets from the last-applied provenance mox persisted for the path
            // (its resolved values may still sit on disk).
            const b_secret = try secretMask(ctx.alloc, b_lines.len, prov.items);
            const prior = try mox.provenance.map.read(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path);
            const a_secret = if (prior) |m| try secretMask(ctx.alloc, a_lines.len, m.segments) else &.{};
            const rendered = try renderFile(ctx.alloc, file.live_path, a_lines, b_lines, hunks, a_secret, b_secret);
            try ctx.out.writeAll(rendered);
        }
    }

    if (stat_mode) {
        try ctx.out.print(" {d} file(s) changed, +{d} -{d}\n", .{ changed, total.added, total.removed });
    }
    return 0;
}

pub const command = app.command(Spec, .{
    .name = "diff",
    .summary = "Show a unified diff of composed output vs each live file",
    .details = "Read-only, always exits 0.",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "statOf: sums added and removed across hunks" {
    const hunks = [_]Hunk{
        .{ .a_start = 1, .a_len = 1, .b_start = 1, .b_len = 2 },
        .{ .a_start = 5, .a_len = 3, .b_start = 6, .b_len = 0 },
    };
    const s = statOf(&hunks);
    try testing.expectEqual(@as(usize, 2), s.added);
    try testing.expectEqual(@as(usize, 4), s.removed);
}

test "renderFile: a changed line renders both sides under a hunk header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = [_][]const u8{ "one", "two", "three" };
    const b = [_][]const u8{ "one", "TWO", "three" };
    const hunks = [_]Hunk{.{ .a_start = 1, .a_len = 1, .b_start = 1, .b_len = 1 }};
    const no_secret: []const bool = &.{};
    const out = try renderFile(arena.allocator(), "/home/me/.zshrc", &a, &b, &hunks, no_secret, no_secret);
    const expected =
        "--- /home/me/.zshrc (live)\n" ++
        "+++ /home/me/.zshrc (composed)\n" ++
        "@@ -2,1 +2,1 @@\n" ++
        "-two\n" ++
        "+TWO\n";
    try testing.expectEqualStrings(expected, out);
}

test "renderFile: no hunks renders empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const empty: []const []const u8 = &.{};
    const no_secret: []const bool = &.{};
    const out = try renderFile(arena.allocator(), "x", empty, empty, &.{}, no_secret, no_secret);
    try testing.expectEqualStrings("", out);
}

test "renderFile: a hunk touching a secret line redacts both sides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = [_][]const u8{ "user = me", "token = old-s3cr3t" };
    const b = [_][]const u8{ "user = me", "token = new-s3cr3t" };
    const hunks = [_]Hunk{.{ .a_start = 1, .a_len = 1, .b_start = 1, .b_len = 1 }};
    // Line 1 is a resolved secret on both sides.
    const a_secret = [_]bool{ false, true };
    const b_secret = [_]bool{ false, true };
    const out = try renderFile(arena.allocator(), "/home/me/.netrc", &a, &b, &hunks, &a_secret, &b_secret);
    const red = mox.provenance.map.secret_redaction;
    const expected =
        "--- /home/me/.netrc (live)\n" ++
        "+++ /home/me/.netrc (composed)\n" ++
        "@@ -2,1 +2,1 @@\n" ++
        "-" ++ red ++ "\n" ++
        "+" ++ red ++ "\n";
    try testing.expectEqualStrings(expected, out);
    try testing.expect(std.mem.indexOf(u8, out, "s3cr3t") == null);
}

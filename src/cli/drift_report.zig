//! The shared drift report: the single renderer `mox apply` (end of run) and
//! `mox status` (its drift summary) both print from, so the two commands
//! cannot disagree on what a drifted tree looks like or how to resolve it.
//! Takes the classifier's `Unit` list (`apply/drift.zig`) as-is -- this
//! module only decides how to lay it out, never what counts as drift.

const std = @import("std");
const mox = @import("../root.zig");
const style = @import("style.zig");

pub const Unit = mox.apply.drift.Unit;

/// First-contact units beyond this count collapse into one migration block
/// instead of one row each: a fresh machine may have hundreds, and a wall of
/// identical rows reads as noise, not an obvious next action.
const collapse_threshold: usize = 6;
/// Names shown before "(+N more)" in a collapsed migration block.
const collapse_sample: usize = 3;
/// The path column never shrinks narrower than this, even on a very narrow
/// terminal -- past this point truncation buys nothing readable.
const min_path_col: usize = 12;
const row_indent = "    ";
const col_gap = 2;

/// What the report renders with, resolved once by the caller: a real
/// terminal query for `mox apply`/`mox status`, a fixed value in a test.
pub const Options = struct {
    /// Files this run wrote, printed as "Applied N files." before the drift
    /// summary. Null omits that prefix -- a report-only caller like `status`
    /// never writes anything itself.
    written: ?usize = null,
    /// Drift the classifier could not scope to a `Unit` (a foreign entry in
    /// a `.mox-exact` directory, an orphaned generator's leaf): it still
    /// needs a decision, but has no path of its own to name in a row. Zero
    /// outside `apply`.
    unrowed: usize = 0,
    home: []const u8,
    sty: style.Style,
    /// Terminal columns to align and truncate to.
    width: usize = 80,
};

/// Render the drift report to `out`. `units` is sorted in place -- the
/// report's sole ordering rule. Writes nothing when there is no drift at all.
pub fn render(arena: std.mem.Allocator, out: *std.Io.Writer, units: []Unit, opts: Options) !void {
    const total = units.len + opts.unrowed;
    if (total == 0) return;
    mox.apply.drift.sortByPath(units);

    var first_contact_count: usize = 0;
    for (units) |u| {
        if (u.first_contact) first_contact_count += 1;
    }
    const collapse = first_contact_count > collapse_threshold;

    try renderSuccessLine(out, opts, total);

    if (collapse) try renderMigrationBlock(arena, out, units, first_contact_count, opts);

    var rows: std.ArrayList(Unit) = .empty;
    for (units) |u| {
        if (collapse and u.first_contact) continue;
        try rows.append(arena, u);
    }
    if (rows.items.len > 0) try renderRows(arena, out, rows.items, opts);

    if (opts.unrowed > 0) {
        try out.writeAll("\n  ");
        try dimNum(out, opts.sty, opts.unrowed);
        try out.writeAll(" entries in exact dirs / orphaned generator leaves need attention (see messages above; mox apply --overwrite to remove)\n");
    }

    // A collapsed migration block already carries its own guidance for the
    // first-contact files it swallowed (the unscoped overwrite IS the point
    // of a first-apply migration); repeating it here would contradict it as
    // much as it would repeat it. Any OTHER row -- a file mox did write,
    // since edited -- is not covered by that guidance and still needs its
    // own scoped pre-fill, collapsed or not.
    if (rows.items.len > 0) try renderGuidance(out, rows.items);
}

fn renderSuccessLine(out: *std.Io.Writer, opts: Options, total: usize) !void {
    try out.writeAll("\n  ");
    if (opts.written) |n| {
        try greenText(out, opts.sty, "Applied ");
        try dimNum(out, opts.sty, n);
        try greenText(out, opts.sty, " files. ");
    }
    try dimNum(out, opts.sty, total);
    try greenText(out, opts.sty, " drifted, left untouched -- nothing was overwritten.\n");
}

/// The migration block: a fresh-machine `apply` may carry hundreds of
/// first-contact files, so these collapse to a count, a short sample, and one
/// set of guidance -- never a first-contact row per file.
fn renderMigrationBlock(arena: std.mem.Allocator, out: *std.Io.Writer, units: []const Unit, count: usize, opts: Options) !void {
    try out.writeAll("\n  ");
    try dimNum(out, opts.sty, count);
    try out.writeAll(" files exist that mox did not write (first apply / migration)\n      ");

    var shown: usize = 0;
    for (units) |u| {
        if (!u.first_contact) continue;
        if (shown > 0) try out.writeAll(", ");
        try out.writeAll(try homeRelative(arena, opts.home, u.path));
        shown += 1;
        if (shown >= collapse_sample) break;
    }
    // Only called once `count > collapse_threshold > collapse_sample`, so
    // there is always at least one name left over to fold into "+N more".
    try out.writeAll(", ... (+");
    try dimNum(out, opts.sty, count - shown);
    try out.writeAll(" more)\n");
    try out.writeAll("      take the repo's version: mox apply --overwrite\n");
    try out.writeAll("      keep a local edit: mox commit <path>\n");
    try out.writeAll("      list them: mox status\n");
}

const Row = struct { path: []const u8, what: []const u8, scope: []const u8, warn: bool };

/// One row per non-collapsed unit, columns aligned to the widest cell in
/// each, the path column budgeted (and, if still too wide, middle-truncated)
/// to fit `opts.width`.
fn renderRows(arena: std.mem.Allocator, out: *std.Io.Writer, units: []const Unit, opts: Options) !void {
    var display: std.ArrayList(Row) = .empty;
    for (units) |u| {
        try display.append(arena, .{
            .path = try homeRelative(arena, opts.home, u.path),
            .what = try whatDrifted(arena, u),
            .scope = mox.apply.drift.overwriteScope(u.kind),
            .warn = switch (u.kind) {
                .owned_key => false,
                else => true,
            },
        });
    }

    var what_w: usize = 0;
    var scope_w: usize = 0;
    for (display.items) |r| {
        what_w = @max(what_w, r.what.len);
        scope_w = @max(scope_w, r.scope.len);
    }

    const fixed = row_indent.len + col_gap + what_w + col_gap + "overwrite: ".len + scope_w + col_gap + "keep: mox commit".len;
    var path_w: usize = 0;
    for (display.items) |r| path_w = @max(path_w, r.path.len);
    if (fixed + path_w > opts.width) {
        path_w = if (opts.width > fixed + min_path_col) opts.width - fixed else min_path_col;
        for (display.items) |*r| {
            if (r.path.len > path_w) r.path = try truncateMiddle(arena, r.path, path_w);
        }
        path_w = 0;
        for (display.items) |r| path_w = @max(path_w, r.path.len);
    }

    try out.writeAll("\n");
    for (display.items) |r| {
        try out.writeAll(row_indent);
        try out.writeAll(r.path);
        try out.splatByteAll(' ', path_w - r.path.len + col_gap);
        try out.writeAll(r.what);
        try out.splatByteAll(' ', what_w - r.what.len + col_gap);
        try out.writeAll("overwrite: ");
        if (r.warn) try opts.sty.yellow(out);
        try out.writeAll(r.scope);
        if (r.warn) try opts.sty.close(out);
        try out.splatByteAll(' ', scope_w - r.scope.len + col_gap);
        try out.writeAll("keep: mox commit\n");
    }
}

/// Guidance for the non-collapsed case: exactly one drifted unit (the sole
/// scopeable thing this run found, regardless of how much unrowed drift rides
/// along with it) pre-fills its own path -- always safe, since the command
/// names that one path and nothing else. More than one never pre-fills an
/// all-paths overwrite: copy-pasting it would clobber a file the reader meant
/// to leave alone.
fn renderGuidance(out: *std.Io.Writer, units: []const Unit) !void {
    try out.writeAll("\n");
    if (units.len == 1) {
        try out.print("  overwrite it:  mox apply --overwrite {s}\n", .{units[0].path});
    } else {
        try out.writeAll("  see the full list:  mox status\n  overwrite one:      mox apply --overwrite <path>\n");
    }
}

/// The row's second column: what actually happened, in the shorthand a
/// reader scans a whole report by.
fn whatDrifted(arena: std.mem.Allocator, u: Unit) ![]const u8 {
    return switch (u.kind) {
        .whole_file => if (u.first_contact) "not written by mox" else "edited since mox wrote it",
        .owned_key => |k| if (k) |key| try std.fmt.allocPrint(arena, "owned key '{s}'", .{key}) else "owned content changed",
        .symlink_target => "symlink target differs",
        .generated_set => "generated set drifted",
    };
}

/// `live_path` relative to `home` with a leading `~/`, or `live_path` itself
/// when it does not sit under `home` (display only -- the actual resolution
/// commands below still use the unit's real path).
fn homeRelative(arena: std.mem.Allocator, home: []const u8, live_path: []const u8) ![]const u8 {
    if (try mox.source.path.liveKeyUnderHome(arena, home, live_path)) |rel| {
        return std.fmt.allocPrint(arena, "~/{s}", .{rel});
    }
    return live_path;
}

/// `s` shortened to at most `max` bytes when longer, keeping the basename
/// whole and a leading slice of `s` before a `...` marker -- "the middle
/// goes missing, the filename never does". Falls back to the basename's own
/// tail when `max` is too narrow to fit the marker plus the basename at all.
/// A cut that would land inside a multibyte UTF-8 codepoint backs off to the
/// nearest earlier boundary instead, so the result is always valid UTF-8
/// (a path component can be non-ASCII, e.g. a kana directory name); this can
/// make the result up to a few bytes shorter than `max`, never longer.
fn truncateMiddle(arena: std.mem.Allocator, s: []const u8, max: usize) ![]const u8 {
    if (s.len <= max) return s;
    const base = std.fs.path.basename(s);
    const marker = "...";
    if (base.len + marker.len >= max) {
        if (base.len <= max) return base;
        var tail_start = base.len - max;
        while (tail_start < base.len and base[tail_start] & 0xC0 == 0x80) tail_start += 1;
        return base[tail_start..];
    }
    var head_len = max - marker.len - base.len;
    while (head_len > 0 and s[head_len] & 0xC0 == 0x80) head_len -= 1;
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ s[0..head_len], marker, base });
}

fn greenText(out: *std.Io.Writer, sty: style.Style, text: []const u8) !void {
    try sty.green(out);
    try out.writeAll(text);
    try sty.close(out);
}

fn dimNum(out: *std.Io.Writer, sty: style.Style, n: usize) !void {
    try sty.dim(out);
    try out.print("{d}", .{n});
    try sty.close(out);
}

/// Every ANSI SGR escape this module ever writes, stripped -- used by tests
/// to prove color is emphasis only: the color-on report with codes removed
/// must equal the color-off report byte for byte.
pub fn stripAnsi(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            var j = i + 2;
            while (j < s.len and s[j] != 'm') j += 1;
            i = if (j < s.len) j + 1 else j;
            continue;
        }
        try buf.append(arena, s[i]);
        i += 1;
    }
    return buf.toOwnedSlice(arena);
}

const testing = std.testing;

fn renderToString(a: std.mem.Allocator, units: []Unit, opts: Options) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    try render(a, &aw.writer, units, opts);
    return aw.written();
}

const off = style.Style{ .on = false };
const on = style.Style{ .on = true };
const test_home = "/home/u";

test "render: no drift at all writes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var units = [_]Unit{};
    const s = try renderToString(arena.allocator(), &units, .{ .home = test_home, .sty = off, .width = 80 });
    try testing.expectEqualStrings("", s);
}

test "render: one row per kind, aligned columns, exact bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]Unit{
        .{ .path = "/home/u/.claude/settings.json", .kind = .{ .owned_key = "enabledPlugins" }, .first_contact = false },
        .{ .path = "/home/u/.claude/CLAUDE.md", .kind = .whole_file, .first_contact = false },
        .{ .path = "/home/u/.claude/hooks", .kind = .symlink_target, .first_contact = false },
        .{ .path = "/home/u/.config/gen.inc", .kind = .generated_set, .first_contact = false },
    };
    const s = try renderToString(a, &units, .{ .written = 18, .home = test_home, .sty = off, .width = 200 });
    try testing.expectEqualStrings(
        \\
        \\  Applied 18 files. 4 drifted, left untouched -- nothing was overwritten.
        \\
        \\    ~/.claude/CLAUDE.md      edited since mox wrote it   overwrite: whole file          keep: mox commit
        \\    ~/.claude/hooks          symlink target differs      overwrite: re-point            keep: mox commit
        \\    ~/.claude/settings.json  owned key 'enabledPlugins'  overwrite: that key            keep: mox commit
        \\    ~/.config/gen.inc        generated set drifted       overwrite: regenerate the set  keep: mox commit
        \\
        \\  see the full list:  mox status
        \\  overwrite one:      mox apply --overwrite <path>
        \\
    , s);
}

test "render: a single drifted unit pre-fills its own scoped overwrite, even alongside unrowed drift" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]Unit{
        .{ .path = "/home/u/.zshrc", .kind = .whole_file, .first_contact = false },
    };
    const s = try renderToString(a, &units, .{ .unrowed = 3, .home = test_home, .sty = off, .width = 80 });
    try testing.expect(std.mem.indexOf(u8, s, "overwrite it:  mox apply --overwrite /home/u/.zshrc\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "overwrite one:") == null);
    try testing.expect(std.mem.indexOf(u8, s, "3 entries in exact dirs / orphaned generator leaves need attention (see messages above; mox apply --overwrite to remove)") != null);
}

test "render: more than one drifted unit never pre-fills an unscoped overwrite" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]Unit{
        .{ .path = "/home/u/a", .kind = .whole_file, .first_contact = false },
        .{ .path = "/home/u/b", .kind = .whole_file, .first_contact = false },
    };
    const s = try renderToString(a, &units, .{ .home = test_home, .sty = off, .width = 80 });
    try testing.expect(std.mem.indexOf(u8, s, "overwrite it:") == null);
    try testing.expect(std.mem.indexOf(u8, s, "see the full list:  mox status") != null);
    try testing.expect(std.mem.indexOf(u8, s, "overwrite one:      mox apply --overwrite <path>") != null);
    // Never the bare unscoped form on its own line.
    try testing.expect(std.mem.indexOf(u8, s, "mox apply --overwrite\n") == null);
}

test "render: only unrowed drift (no scopeable unit) still carries a stdout explanation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]Unit{};
    const s = try renderToString(a, &units, .{ .written = 5, .unrowed = 2, .home = test_home, .sty = off, .width = 80 });
    try testing.expectEqualStrings(
        \\
        \\  Applied 5 files. 2 drifted, left untouched -- nothing was overwritten.
        \\
        \\  2 entries in exact dirs / orphaned generator leaves need attention (see messages above; mox apply --overwrite to remove)
        \\
    , s);
}

test "render: many first-contact units collapse into one migration block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units: [8]Unit = undefined;
    const names = [_][]const u8{ ".zshrc", ".gitconfig", ".vimrc", ".bashrc", ".profile", ".tmux.conf", ".editorconfig", ".npmrc" };
    for (names, 0..) |n, i| {
        units[i] = .{ .path = try std.fmt.allocPrint(a, "/home/u/{s}", .{n}), .kind = .whole_file, .first_contact = true };
    }
    const s = try renderToString(a, &units, .{ .written = 0, .home = test_home, .sty = off, .width = 80 });
    try testing.expectEqualStrings(
        \\
        \\  Applied 0 files. 8 drifted, left untouched -- nothing was overwritten.
        \\
        \\  8 files exist that mox did not write (first apply / migration)
        \\      ~/.bashrc, ~/.editorconfig, ~/.gitconfig, ... (+5 more)
        \\      take the repo's version: mox apply --overwrite
        \\      keep a local edit: mox commit <path>
        \\      list them: mox status
        \\
    , s);
    // Collapsed: no per-file first-contact row, and no second (contradicting)
    // scoped-guidance block under the migration block's own guidance.
    try testing.expect(std.mem.indexOf(u8, s, "not written by mox") == null);
    try testing.expect(std.mem.indexOf(u8, s, "overwrite it:") == null);
    try testing.expect(std.mem.indexOf(u8, s, "overwrite one:") == null);
}

test "render: a collapsed migration block still scopes guidance to an edited unit alongside it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units: [8]Unit = undefined;
    const names = [_][]const u8{ ".zshrc", ".gitconfig", ".vimrc", ".bashrc", ".profile", ".tmux.conf", ".editorconfig" };
    for (names, 0..) |n, i| {
        units[i] = .{ .path = try std.fmt.allocPrint(a, "/home/u/{s}", .{n}), .kind = .whole_file, .first_contact = true };
    }
    units[7] = .{ .path = "/home/u/.ssh/config", .kind = .whole_file, .first_contact = false };
    const s = try renderToString(a, &units, .{ .home = test_home, .sty = off, .width = 200 });
    // The migration block's own unscoped guidance still shows.
    try testing.expect(std.mem.indexOf(u8, s, "take the repo's version: mox apply --overwrite") != null);
    // The edited unit is not swallowed by the collapse: it still gets a row
    // and its own scoped pre-fill, not just the migration block's unscoped one.
    try testing.expect(std.mem.indexOf(u8, s, "~/.ssh/config") != null);
    try testing.expect(std.mem.indexOf(u8, s, "overwrite it:  mox apply --overwrite /home/u/.ssh/config\n") != null);
}

test "render: a small first-contact set does not collapse, rows normally instead" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]Unit{
        .{ .path = "/home/u/.zshrc", .kind = .whole_file, .first_contact = true },
    };
    const s = try renderToString(a, &units, .{ .home = test_home, .sty = off, .width = 80 });
    try testing.expect(std.mem.indexOf(u8, s, "first apply / migration") == null);
    try testing.expect(std.mem.indexOf(u8, s, "not written by mox") != null);
    try testing.expect(std.mem.indexOf(u8, s, "overwrite it:  mox apply --overwrite /home/u/.zshrc") != null);
}

test "render: color on, stripped, equals color off byte for byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units_on = [_]Unit{
        .{ .path = "/home/u/.claude/settings.json", .kind = .{ .owned_key = "enabledPlugins" }, .first_contact = false },
        .{ .path = "/home/u/.claude/CLAUDE.md", .kind = .whole_file, .first_contact = false },
    };
    var units_off = [_]Unit{
        .{ .path = "/home/u/.claude/settings.json", .kind = .{ .owned_key = "enabledPlugins" }, .first_contact = false },
        .{ .path = "/home/u/.claude/CLAUDE.md", .kind = .whole_file, .first_contact = false },
    };
    const colored = try renderToString(a, &units_on, .{ .written = 3, .home = test_home, .sty = on, .width = 200 });
    const plain = try renderToString(a, &units_off, .{ .written = 3, .home = test_home, .sty = off, .width = 200 });
    try testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
    try testing.expectEqualStrings(plain, try stripAnsi(a, colored));
}

test "render: a narrow terminal truncates a long path in the middle, basename intact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]Unit{
        .{ .path = "/home/u/.config/some/very/deeply/nested/application/settings.json", .kind = .whole_file, .first_contact = false },
    };
    const s = try renderToString(a, &units, .{ .home = test_home, .sty = off, .width = 100 });
    try testing.expect(std.mem.indexOf(u8, s, "settings.json") != null);
    try testing.expect(std.mem.indexOf(u8, s, "~/.config/so...settings.json") != null);
    try testing.expect(std.mem.indexOf(u8, s, "~/.config/some/very/deeply/nested/application/settings.json") == null);
    // The width budget governs the table row (an aligned column); the
    // guidance line below it prints the real, untruncated path on purpose --
    // a command has to be copy-pasteable, not merely narrow.
    var max_row_line: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, row_indent)) max_row_line = @max(max_row_line, line.len);
    }
    try testing.expect(max_row_line <= 100);
}

test "truncateMiddle: exact length, basename preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = "~/.config/some/very/deeply/nested/application/settings.json";
    const t = try truncateMiddle(a, long, 30);
    try testing.expectEqual(@as(usize, 30), t.len);
    try testing.expect(std.mem.endsWith(u8, t, "settings.json"));
    try testing.expect(std.mem.indexOf(u8, t, "...") != null);
    try testing.expectEqualStrings(long, try truncateMiddle(a, long, long.len));
}

test "truncateMiddle: a head cut that would split a multibyte codepoint backs off to the boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 14 ASCII bytes, then U+3042 (3 bytes), then 4 more ASCII bytes, then
    // "/file.txt" -- max=26 computes a head cut of 15 bytes, landing on the
    // second byte of the 3-byte codepoint.
    const s = "aaaaaaaaaaaaaa" ++ "\u{3042}" ++ "bbbb" ++ "/file.txt";
    const t = try truncateMiddle(a, s, 26);
    try testing.expect(std.unicode.utf8ValidateSlice(t));
    try testing.expect(std.mem.endsWith(u8, t, "file.txt"));
    try testing.expect(std.mem.indexOf(u8, t, "...") != null);
}

test "truncateMiddle: a basename-tail cut that would split a multibyte codepoint backs off to the boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Basename alone (with the marker) already exceeds max, so the fallback
    // keeps a tail slice of the basename -- U+3042 sits right at the cut.
    const s = "/dir/aa" ++ "\u{3042}" ++ "settings.json";
    const t = try truncateMiddle(a, s, 15);
    try testing.expect(std.unicode.utf8ValidateSlice(t));
}

test "render: a narrow terminal middle-truncates a kana path into valid UTF-8" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]Unit{
        .{ .path = "/home/u/.config/" ++ "\u{3075}\u{308a}\u{304c}\u{306a}" ** 6 ++ "/settings.json", .kind = .whole_file, .first_contact = false },
    };
    const s = try renderToString(a, &units, .{ .home = test_home, .sty = off, .width = 100 });
    try testing.expect(std.unicode.utf8ValidateSlice(s));
    try testing.expect(std.mem.indexOf(u8, s, "settings.json") != null);
}

//! A package backend that lives in the repo as an executable.
//!
//! The one extension point. A shipped backend is compiled; a plugin is any
//! executable under `scripts/backends/` that speaks this protocol, and it
//! satisfies exactly the same `Backend` contract, so nothing downstream can
//! tell them apart. Any manager, any language, no mox release.
//!
//!     <plugin> available          exit 0: usable here; 1: not usable here
//!     <plugin> id                 stdin: one row as an inline table
//!                                 stdout: exactly one id
//!                                 exit 1: the row is refused; stderr says why
//!     <plugin> list               stdout: one id per line, explicitly installed
//!     <plugin> install            stdin: rows, one per line; stdio streamed
//!     <plugin> declare <id>       stdout: a TOML row body naming this id
//!     <plugin> bootstrap <path>   optional: install the manager from the
//!                                 verified file; stdout: a bin dir, or nothing
//!     <plugin> limitation         optional: one line on what it cannot see
//!
//! Exit 64 from any verb means "not implemented"; any other nonzero exit is
//! a failed plugin, named as such, except `id`'s 1, which is a refusal.
//!
//! `id` is both `idOf` and `validate`: a row the plugin cannot name is refused
//! with the plugin's own reason, which is stronger than any key list mox could
//! check against. Ids are opaque; a plugin with two namespaces prefixes them
//! itself, and mox compares strings.
//!
//! An optional verb signals its absence with exit 64 (EX_USAGE), reported at
//! the call site by plugin and verb. Nothing is substituted for a missing
//! verb: a `declare` that quietly became `name = <id>` would write wrong rows.

const std = @import("std");
const toml = @import("toml");

const backend_mod = @import("backend.zig");
const exec = @import("exec.zig");
const manifest_mod = @import("manifest.zig");
const write_mod = @import("write.zig");

pub const Row = manifest_mod.Row;
pub const Diag = manifest_mod.Diag;
pub const Backend = backend_mod.Backend;

pub const exit_not_implemented: u8 = 64;

pub const Error = error{
    PluginNotRunnable,
    PluginRefusedRow,
    PluginVerbNotImplemented,
    PluginFailed,
    PluginTimedOut,
    PluginBadOutput,
    PluginRoundTripMismatch,
};

pub const Plugin = struct {
    name: []const u8,
    /// How to invoke it: the path alone, or an interpreter and the path.
    argv0: []const []const u8,
    runner: exec.Runner,
    /// Outlives every per-call arena: what `id` answered is kept here for
    /// the life of the plugin.
    alloc: std.mem.Allocator,
    /// Set when this machine cannot run the file (a `.ps1` on unix, a plain
    /// script on Windows). The plugin is then registered but never usable:
    /// its rows are inert here, as a dnf row is inert on a mac, rather than
    /// refused as naming nothing.
    not_runnable: ?[]const u8 = null,
    /// `id`'s answer per rendered row, refusals included. Validation,
    /// contradiction checks, selection and drift each ask for the same row
    /// in one pass, and a plugin is a process spawn per question.
    ids: std.StringHashMapUnmanaged(anyerror![]const u8) = .empty,

    pub fn backend(self: *Plugin) Backend {
        return .{
            .name = self.name,
            .ctx = self,
            .vtable = if (self.not_runnable != null) &inert_vtable else &vtable,
        };
    }

    const vtable: Backend.VTable = .{
        .available = availableImpl,
        .validate = validateImpl,
        .idOf = idOfImpl,
        .installedExplicit = installedExplicitImpl,
        .install = installImpl,
        .declare = declareImpl,
        .bootstrap = bootstrapImpl,
        .limitation = limitationImpl,
    };

    /// A plugin this machine cannot run has no optional verbs: nothing may
    /// plan to bootstrap through it, and nothing asks it what it cannot see.
    const inert_vtable: Backend.VTable = .{
        .available = availableImpl,
        .validate = validateImpl,
        .idOf = idOfImpl,
        .installedExplicit = installedExplicitImpl,
        .install = installImpl,
        .declare = declareImpl,
    };

    /// The one place a spawn's argv is built, so a file this machine cannot
    /// run is refused by name here rather than exec'd as a bare verb.
    fn argv(self: *const Plugin, arena: std.mem.Allocator, verb: []const u8, extra: []const []const u8) ![]const []const u8 {
        if (self.not_runnable != null) return Error.PluginNotRunnable;
        var out: std.ArrayList([]const u8) = .empty;
        try out.appendSlice(arena, self.argv0);
        try out.append(arena, verb);
        try out.appendSlice(arena, extra);
        return out.toOwnedSlice(arena);
    }

    /// The optional `limitation` verb. Exit 64 is "none"; a failure is a
    /// failure. Asked only of a usable backend, after the report has named
    /// every plugin, so nothing runs before it is listed.
    fn limitationImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!?[]const u8 {
        const self: *Plugin = @ptrCast(@alignCast(ctx));
        const res = try self.runner.runInput(arena, try self.argv(arena, "limitation", &.{}), "");
        if (res.timed_out) return Error.PluginTimedOut;
        if (res.code == exit_not_implemented) return null;
        if (!res.ok) return Error.PluginFailed;
        const line = firstLine(res.stdout);
        return if (line.len == 0) null else line;
    }

    /// Exit 0 is usable, exit 1 is not usable here, and anything else is a
    /// broken plugin: a script that dies on a syntax error exits 2, and
    /// reading that as "not usable" would make every row naming it vanish
    /// from every command without a word. Its stderr goes to the terminal
    /// for the same reason. A spawn failure of the plugin itself is likewise
    /// a broken plugin, not an absent manager: unlike a compiled adapter,
    /// argv[0] here is not the manager.
    fn availableImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!bool {
        const self: *Plugin = @ptrCast(@alignCast(ctx));
        if (self.not_runnable != null) return false;
        const res = try self.runner.runInput(arena, try self.argv(arena, "available", &.{}), "");
        if (res.timed_out) return Error.PluginTimedOut;
        if (res.code == exit_not_implemented) return Error.PluginVerbNotImplemented;
        if (res.code > 1) return Error.PluginFailed;
        return res.ok;
    }

    fn validateImpl(ctx: *anyopaque, row: Row, diag: ?*Diag) anyerror!void {
        const self: *Plugin = @ptrCast(@alignCast(ctx));
        // A row for a plugin this machine cannot run is checked where the
        // plugin runs; here it is inert, and refusing it would make one
        // shared manifest unreadable on every other OS.
        if (self.not_runnable != null) return;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        _ = self.idOne(arena.allocator(), row) catch |e| switch (e) {
            Error.PluginRefusedRow => {
                if (diag) |d| d.set(
                    "{s}: row \"{s}\": refused by plugin {s} (its reason is printed above)",
                    .{ row.label, row.name, self.name },
                );
                return e;
            },
            else => {
                if (diag) |d| d.set(
                    "{s}: row \"{s}\": plugin {s}: id failed: {s}",
                    .{ row.label, row.name, self.name, @errorName(e) },
                );
                return e;
            },
        };
    }

    fn idOfImpl(ctx: *anyopaque, arena: std.mem.Allocator, row: Row) anyerror![]const u8 {
        const self: *Plugin = @ptrCast(@alignCast(ctx));
        if (self.not_runnable != null) return row.name;
        return self.idOne(arena, row);
    }

    /// One row in, exactly one id out: `id` is called once per row, and an
    /// answer of any other shape (two lines, none) is bad output.
    fn idOne(self: *Plugin, arena: std.mem.Allocator, row: Row) ![]const u8 {
        const line = try write_mod.inlineRow(arena, row.name, row.fields);
        if (self.ids.get(line)) |memo| return memo;
        const memo: anyerror![]const u8 = if (self.idSpawn(arena, line)) |id|
            try self.alloc.dupe(u8, id)
        else |e|
            e;
        try self.ids.put(self.alloc, try self.alloc.dupe(u8, line), memo);
        return memo;
    }

    fn idSpawn(self: *Plugin, arena: std.mem.Allocator, line: []const u8) ![]const u8 {
        const input = try std.fmt.allocPrint(arena, "{s}\n", .{line});
        const res = try self.runner.runInput(arena, try self.argv(arena, "id", &.{}), input);
        if (res.timed_out) return Error.PluginTimedOut;
        if (res.code == exit_not_implemented) return Error.PluginVerbNotImplemented;
        // Exit 1 is the plugin declining the row; anything else is the plugin
        // dying (a shell syntax error exits 2), which must not read as a
        // considered refusal.
        if (res.code == 1) return Error.PluginRefusedRow;
        if (!res.ok) return Error.PluginFailed;

        const ids = try idLines(arena, res.stdout);
        if (ids.len != 1) return Error.PluginBadOutput;
        return ids[0];
    }

    fn installedExplicitImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *Plugin = @ptrCast(@alignCast(ctx));
        const res = try self.runner.runInput(arena, try self.argv(arena, "list", &.{}), "");
        if (res.timed_out) return Error.PluginTimedOut;
        if (res.code == exit_not_implemented) return Error.PluginVerbNotImplemented;
        if (!res.ok) return Error.PluginFailed;
        return idLines(arena, res.stdout);
    }

    fn installImpl(ctx: *anyopaque, arena: std.mem.Allocator, rows: []const Row) anyerror!void {
        const self: *Plugin = @ptrCast(@alignCast(ctx));
        if (rows.len == 0) return;
        var input: std.ArrayList(u8) = .empty;
        for (rows) |row| {
            try input.appendSlice(arena, try write_mod.inlineRow(arena, row.name, row.fields));
            try input.append(arena, '\n');
        }
        const res = try self.runner.streamInput(arena, try self.argv(arena, "install", &.{}), input.items);
        if (res.timed_out) return Error.PluginTimedOut;
        if (res.code == exit_not_implemented) return Error.PluginVerbNotImplemented;
        if (!res.ok) return Error.PluginFailed;
    }

    /// The round trip is enforced, not assumed: the row the plugin returns is
    /// handed back to `id`, and refused unless the answer is the id it came
    /// from. A plugin whose two halves disagree cannot write a row that will
    /// never match its own package.
    fn declareImpl(ctx: *anyopaque, arena: std.mem.Allocator, id: []const u8) anyerror!Backend.Declaration {
        const self: *Plugin = @ptrCast(@alignCast(ctx));
        const res = try self.runner.runInput(arena, try self.argv(arena, "declare", &.{id}), "");
        if (res.timed_out) return Error.PluginTimedOut;
        if (res.code == exit_not_implemented) return Error.PluginVerbNotImplemented;
        if (!res.ok) return Error.PluginFailed;

        const decl = try parseDeclaration(arena, res.stdout);
        const check: Row = .{
            .name = decl.name,
            .backend = self.name,
            .when = null,
            .fields = decl.fields,
            .origin = "",
            .label = self.name,
            .index = 0,
        };
        const back = try self.idOne(arena, check);
        if (!std.mem.eql(u8, back, id)) return Error.PluginRoundTripMismatch;
        return decl;
    }

    /// Progress goes to the terminal; the one line on stdout, if any, is a
    /// directory to put on PATH so this same run can use what it installed.
    fn bootstrapImpl(ctx: *anyopaque, arena: std.mem.Allocator, installer_path: []const u8) anyerror!?[]const u8 {
        const self: *Plugin = @ptrCast(@alignCast(ctx));
        const res = try self.runner.runInput(arena, try self.argv(arena, "bootstrap", &.{installer_path}), "");
        if (res.timed_out) return Error.PluginTimedOut;
        if (res.code == exit_not_implemented) return Error.PluginVerbNotImplemented;
        if (!res.ok) return Error.PluginFailed;
        const line = firstLine(res.stdout);
        return if (line.len == 0) null else line;
    }
};

/// Split on newline, trim `\r` and surrounding spaces (a PowerShell plugin
/// emits CRLF), drop blanks, and refuse any id whose shape says the plugin
/// lost its line separator.
fn idLines(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!backend_mod.idShapeOk(line)) return Error.PluginBadOutput;
        try out.append(arena, line);
    }
    return out.toOwnedSlice(arena);
}

fn firstLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0) return line;
    }
    return "";
}

/// A `declare` answer: a TOML body with a string `name` and flat fields.
fn parseDeclaration(arena: std.mem.Allocator, text: []const u8) !Backend.Declaration {
    const v = toml.parse(arena, text, .{}) catch return Error.PluginBadOutput;
    if (v != .table) return Error.PluginBadOutput;
    const name_v = v.table.get("name") orelse return Error.PluginBadOutput;
    if (name_v != .string or name_v.string.len == 0) return Error.PluginBadOutput;

    var fields: std.ArrayList(manifest_mod.Pair) = .empty;
    for (v.table.keys(), v.table.values()) |k, fv| {
        if (std.mem.eql(u8, k, "name")) continue;
        // A core key is mox's to write, and a key outside the bare charset
        // would be rendered unquoted into a manifest that then fails to
        // parse; both are the plugin answering wrong, not a row to record.
        if (std.mem.eql(u8, k, "backend") or std.mem.eql(u8, k, "when")) return Error.PluginBadOutput;
        if (!write_mod.keyOk(k)) return Error.PluginBadOutput;
        const f = (try manifest_mod.fieldOf(arena, fv)) orelse return Error.PluginBadOutput;
        try fields.append(arena, .{ .key = k, .value = f });
    }
    return .{ .name = name_v.string, .fields = try fields.toOwnedSlice(arena) };
}

const testing = std.testing;

fn rowOf(name: []const u8, fields: []const manifest_mod.Pair) Row {
    return .{
        .name = name,
        .backend = "macports",
        .when = null,
        .fields = fields,
        .origin = "/tmp/x.toml",
        .label = "data/packages/darwin.toml",
        .index = 0,
    };
}

fn pluginWith(fake: *exec.Fake) Plugin {
    return .{ .name = "macports", .argv0 = &.{"/r/scripts/backends/macports"}, .runner = fake.runner(), .alloc = fake.arena };
}

test "id: the same row is asked once, and a refusal is remembered too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports id", .stdout = "cask:ghostty\n" },
    } };
    var p = pluginWith(&fake);
    const row = rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }});

    try testing.expectEqualStrings("cask:ghostty", try p.backend().idOf(a, row));
    try testing.expectEqualStrings("cask:ghostty", try p.backend().idOf(a, row));
    try p.backend().validate(row, null);
    try testing.expectEqual(@as(usize, 1), fake.calls.items.len);

    var refusing: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports id", .code = 1 },
    } };
    var rp = pluginWith(&refusing);
    try testing.expectError(Error.PluginRefusedRow, rp.backend().validate(rowOf("x", &.{}), null));
    try testing.expectError(Error.PluginRefusedRow, rp.backend().idOf(a, rowOf("x", &.{})));
    try testing.expectEqual(@as(usize, 1), refusing.calls.items.len);
}

test "not runnable: no bootstrap, no limitation, and nothing is ever spawned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    var p: Plugin = .{
        .name = "macports",
        .argv0 = &.{},
        .runner = fake.runner(),
        .alloc = a,
        .not_runnable = "a windows-only kind; not runnable here",
    };
    const b = p.backend();
    try testing.expect(!b.canBootstrap());
    try testing.expectError(error.NoBootstrapForBackend, b.bootstrap(a, "/tmp/i"));
    try testing.expectError(Error.PluginNotRunnable, Plugin.bootstrapImpl(&p, a, "/tmp/i"));
    try testing.expect((try b.limitationOf(a)) == null);
    try testing.expect(!try b.available(a));
    try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "id: the row goes to stdin as one inline table and the id comes back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports id", .stdout = "cask:ghostty\n" },
    } };
    var p = pluginWith(&fake);

    const id = try p.backend().idOf(a, rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}));
    try testing.expectEqualStrings("cask:ghostty", id);
    try testing.expectEqualStrings(
        "{ name = \"ghostty\", kind = \"cask\" }\n",
        fake.inputTo("/r/scripts/backends/macports id").?,
    );
}

test "id: a plugin that dies is a failure, not a considered refusal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports id", .code = 2 },
    } };
    var p = pluginWith(&fake);
    try testing.expectError(Error.PluginFailed, p.backend().idOf(a, rowOf("x", &.{})));
}

test "declare: a core key or an unquotable key is bad output, never written" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports declare x", .stdout = "name = \"x\"\nbackend = \"other\"\n" },
        .{ .argv = "/r/scripts/backends/macports declare y", .stdout = "name = \"y\"\n\"my key\" = 1\n" },
    } };
    var p = pluginWith(&fake);
    try testing.expectError(Error.PluginBadOutput, p.backend().declare(a, "x"));
    try testing.expectError(Error.PluginBadOutput, p.backend().declare(a, "y"));
}

test "id: a refused row is the plugin's decision, surfaced through validate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports id", .code = 1 },
    } };
    var p = pluginWith(&fake);

    var d: Diag = .{};
    try testing.expectError(Error.PluginRefusedRow, p.backend().validate(rowOf("x", &.{}), &d));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "refused by plugin macports") != null);
}

test "list: CRLF is trimmed and a lost separator is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ok_fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports list", .stdout = "ripgrep\r\nbat\r\n\r\n" },
    } };
    var ok_p = pluginWith(&ok_fake);
    const got = try ok_p.backend().installedExplicit(a);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("bat", got[1]);

    var bad_fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports list", .stdout = "ripgrep bat\n" },
    } };
    var bad_p = pluginWith(&bad_fake);
    try testing.expectError(Error.PluginBadOutput, bad_p.backend().installedExplicit(a));
}

test "install: every row reaches stdin, one per line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports install" },
    } };
    var p = pluginWith(&fake);

    try p.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("bat", &.{}) });
    try testing.expectEqualStrings(
        "{ name = \"ripgrep\" }\n{ name = \"bat\" }\n",
        fake.inputTo("/r/scripts/backends/macports install").?,
    );
}

test "declare: the row is handed back to id and refused on mismatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A plugin whose declare and id agree.
    var good: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports declare cask:ghostty", .stdout = "name = \"ghostty\"\nkind = \"cask\"\n" },
        .{ .argv = "/r/scripts/backends/macports id", .stdout = "cask:ghostty\n" },
    } };
    var gp = pluginWith(&good);
    const decl = try gp.backend().declare(a, "cask:ghostty");
    try testing.expectEqualStrings("ghostty", decl.name);
    try testing.expectEqualStrings("cask", decl.fields[0].value.string);

    // One whose declare drops the kind: id then answers `ghostty`, not the
    // id it came from. Writing that row would never match the package.
    var bad: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports declare cask:ghostty", .stdout = "name = \"ghostty\"\n" },
        .{ .argv = "/r/scripts/backends/macports id", .stdout = "ghostty\n" },
    } };
    var bp = pluginWith(&bad);
    try testing.expectError(Error.PluginRoundTripMismatch, bp.backend().declare(a, "cask:ghostty"));
}

test "exit 64: an optional verb the plugin lacks is named, never defaulted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports declare x", .code = exit_not_implemented },
        .{ .argv = "/r/scripts/backends/macports bootstrap /tmp/i", .code = exit_not_implemented },
        .{ .argv = "/r/scripts/backends/macports limitation", .code = exit_not_implemented },
    } };
    var p = pluginWith(&fake);

    try testing.expectError(Error.PluginVerbNotImplemented, p.backend().declare(a, "x"));
    try testing.expectError(Error.PluginVerbNotImplemented, p.backend().bootstrap(a, "/tmp/i"));
    try testing.expect((try p.backend().limitationOf(a)) == null);
}

test "bootstrap: the line on stdout is the bin dir to put on PATH" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports bootstrap /tmp/i", .stdout = "/opt/local/bin\n" },
    } };
    var p = pluginWith(&fake);
    try testing.expectEqualStrings("/opt/local/bin", (try p.backend().bootstrap(a, "/tmp/i")).?);
}

test "limitation: the plugin's one line is carried onto the backend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports limitation", .stdout = "variants are not tracked\n" },
    } };
    var p = pluginWith(&fake);
    try testing.expectEqualStrings("variants are not tracked", (try p.backend().limitationOf(a)).?);
}

test "available: a plugin that cannot be spawned is an error, not an absent manager" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports available", .fail = error.FileNotFound },
    } };
    var p = pluginWith(&fake);
    try testing.expectError(error.FileNotFound, p.backend().available(a));
}

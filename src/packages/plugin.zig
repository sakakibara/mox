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
//!     <plugin> bootstrap <path> <out>  optional: install the manager from
//!                                 the verified file, streamed; write the
//!                                 bin dir, if any, as one absolute path
//!                                 on a line of its own into <out>
//!     <plugin> limitation         optional: one line on what it cannot see
//!
//! Exit 64 from an optional verb means "not implemented"; any other nonzero
//! exit is a failed plugin, named as such, except the two exits the table
//! above gives a meaning: `id`'s 1, a refusal, and `available`'s 1, not usable
//! here. `available` is not optional, so its 64 is just another exit it cannot
//! answer with: a broken backend, never a run-ending error.
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
const builtin = @import("builtin");
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
    io: std.Io,
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
            .inert = self.not_runnable != null,
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

    /// The one place a verb is spawned. A `.ps1` plugin's argv0 names
    /// `pwsh`, and `invoke` finds the PowerShell this machine has.
    fn call(self: *const Plugin, arena: std.mem.Allocator, verb: []const u8, extra: []const []const u8, stdin: []const u8, streamed: bool) anyerror!exec.Result {
        return self.runner.invoke(arena, try self.argv(arena, verb, extra), stdin, streamed);
    }

    /// The optional `limitation` verb. Exit 64 is "none"; a failure is a
    /// failure. Asked only of a usable backend, after the report has named
    /// every plugin, so nothing runs before it is listed.
    fn limitationImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!?[]const u8 {
        const self: *Plugin = @ptrCast(@alignCast(ctx));
        const res = try self.call(arena, "limitation", &.{}, "", false);
        if (res.timed_out) return Error.PluginTimedOut;
        if (res.code == exit_not_implemented) return null;
        if (!res.ok) return Error.PluginFailed;
        const line = firstLine(res.stdout);
        if (line.len == 0) return null;
        if (!limitationShapeOk(line)) return Error.PluginBadOutput;
        return line;
    }

    /// Exit 0 is usable, exit 1 is not usable here, and anything else is a
    /// broken plugin: a script that dies on a syntax error exits 2, and
    /// reading that as "not usable" would make every row naming it vanish
    /// from every command without a word. Its stderr goes to the terminal
    /// for the same reason. A spawn failure of the plugin itself is likewise
    /// a broken plugin, not an absent manager: unlike a compiled adapter,
    /// argv[0] here is not the manager.
    fn availableImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!Backend.Availability {
        const self: *Plugin = @ptrCast(@alignCast(ctx));
        if (self.not_runnable != null) return .absent;
        const res = try self.call(arena, "available", &.{}, "", false);
        if (res.timed_out) return Error.PluginTimedOut;
        // Anything but the two answers the protocol defines is a plugin
        // that cannot say whether its manager is here: broken, the same as
        // a shipped adapter whose probe cannot answer. 64 included: it is
        // the likeliest exit of a half-written plugin whose case statement
        // has no `available` arm, and `available` is not optional, so
        // reading it as "verb missing" would end the whole run over one
        // backend the manifest may not even name.
        if (res.code > 1) return .{ .broken = .{
            .code = res.code,
            .probe = try std.fmt.allocPrint(arena, "{s} available", .{self.name}),
        } };
        return if (res.ok) .present else .absent;
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
        const res = try self.call(arena, "id", &.{}, input, false);
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
        const res = try self.call(arena, "list", &.{}, "", false);
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
        const res = try self.call(arena, "install", &.{}, input.items, true);
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
        const res = try self.call(arena, "declare", &.{id}, "", false);
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

    /// Streamed like an install: an installer talks to the terminal and may
    /// take as long as one, so the bin dir cannot come back on stdout. The
    /// plugin writes it into the file named by the second argument, as one
    /// line holding an absolute path, and mox puts it on PATH so this same
    /// run can use what it installed.
    fn bootstrapImpl(ctx: *anyopaque, arena: std.mem.Allocator, installer_path: []const u8) anyerror!?[]const u8 {
        const self: *Plugin = @ptrCast(@alignCast(ctx));
        const out_path = try std.fmt.allocPrint(arena, "{s}.bindir", .{installer_path});
        std.Io.Dir.cwd().deleteFile(self.io, out_path) catch {};
        defer std.Io.Dir.cwd().deleteFile(self.io, out_path) catch {};
        const res = try self.call(arena, "bootstrap", &.{ installer_path, out_path }, "", true);
        if (res.timed_out) return Error.PluginTimedOut;
        if (res.code == exit_not_implemented) return Error.PluginVerbNotImplemented;
        if (!res.ok) return Error.PluginFailed;
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, out_path, arena, .limited(64 * 1024)) catch |e| switch (e) {
            error.FileNotFound => return null,
            // A file too large to hold one path is the plugin writing its
            // progress where the bin dir goes: the same deviation as a second
            // line, and reported as the same thing.
            error.StreamTooLong => return Error.PluginBadOutput,
            else => return e,
        };
        const line = (try onlyLine(text)) orelse return null;
        if (!std.fs.path.isAbsolute(line)) return Error.PluginBadOutput;
        return line;
    }
};

/// The one non-empty line of `text`, null for none, and bad output for more.
fn onlyLine(text: []const u8) !?[]const u8 {
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (found != null) return Error.PluginBadOutput;
        found = line;
    }
    return found;
}

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

/// A limitation is one sentence, printed unescaped as a `status` note beside
/// the backend's name. 200 bytes is a sentence and still fits a terminal line
/// under the report's own prefix; a plugin that emits more, or emits a control
/// byte, is writing to the terminal through mox rather than stating a gap.
const limitation_max = 200;

fn limitationShapeOk(line: []const u8) bool {
    if (line.len > limitation_max) return false;
    if (!std.unicode.utf8ValidateSlice(line)) return false;
    for (line) |c| {
        if (std.ascii.isControl(c)) return false;
    }
    return true;
}

/// A `declare` answer: a TOML body with a string `name` and flat fields.
fn parseDeclaration(arena: std.mem.Allocator, text: []const u8) !Backend.Declaration {
    const v = toml.parse(arena, text, .{}) catch return Error.PluginBadOutput;
    if (v != .table) return Error.PluginBadOutput;
    const name_v = v.table.get("name") orelse return Error.PluginBadOutput;
    // The manifest's own rule, applied before the row is written rather than
    // on the way back in: the round trip below constrains the id, not the
    // name, so a plugin mapping `gnu make` to `gnu@make` could otherwise have
    // commit record a name every later run refuses, with no mox command left
    // that can repair the file.
    if (name_v != .string or !backend_mod.nameShapeOk(name_v.string)) return Error.PluginBadOutput;

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
    return .{ .name = "macports", .argv0 = &.{"/r/scripts/backends/macports"}, .runner = fake.runner(), .alloc = fake.arena, .io = std.testing.io };
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
        .io = std.testing.io,
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
    try testing.expect((try b.available(a)) == .absent);
    try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "available: exit 0 is present, exit 1 is absent, and anything else is broken" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports available", .code = 0, .once = true },
        .{ .argv = "/r/scripts/backends/macports available", .code = 1, .once = true },
        .{ .argv = "/r/scripts/backends/macports available", .code = 2 },
    } };
    var p = pluginWith(&fake);
    try testing.expect((try p.backend().available(a)) == .present);
    try testing.expect((try p.backend().available(a)) == .absent);
    const broken = try p.backend().available(a);
    try testing.expect(broken == .broken);
    try testing.expectEqual(@as(u8, 2), broken.broken.code);
    try testing.expectEqualStrings("macports available", broken.broken.probe);
}

test "a .ps1 plugin runs through powershell when pwsh is not there" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const argv0 = try exec.powerShellArgv(a, "pwsh", &.{"C:\\r\\scripts\\backends\\macports.ps1"});
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\\r\\scripts\\backends\\macports.ps1 available", .fail = error.FileNotFound },
        .{ .argv = "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\r\\scripts\\backends\\macports.ps1 available" },
        .{ .argv = "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\\r\\scripts\\backends\\macports.ps1 list", .fail = error.FileNotFound },
        .{ .argv = "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\r\\scripts\\backends\\macports.ps1 list", .stdout = "ripgrep\r\n" },
    } };
    var p: Plugin = .{ .io = std.testing.io, .name = "macports", .argv0 = argv0, .runner = fake.runner(), .alloc = a };

    try testing.expect((try p.backend().available(a)) == .present);
    const got = try p.backend().installedExplicit(a);
    try testing.expectEqualStrings("ripgrep", got[0]);
    try testing.expectEqual(@as(usize, 4), fake.calls.items.len);
    try testing.expect(fake.called("powershell -NoProfile -ExecutionPolicy Bypass -File C:\\r\\scripts\\backends\\macports.ps1 list"));
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
        .{ .argv = "/r/scripts/backends/macports bootstrap /tmp/i", .match = .prefix, .code = exit_not_implemented },
        .{ .argv = "/r/scripts/backends/macports limitation", .code = exit_not_implemented },
    } };
    var p = pluginWith(&fake);

    try testing.expectError(Error.PluginVerbNotImplemented, p.backend().declare(a, "x"));
    try testing.expectError(Error.PluginVerbNotImplemented, p.backend().bootstrap(a, "/tmp/i"));
    try testing.expect((try p.backend().limitationOf(a)) == null);
}

/// A bin dir that is absolute on the host running the test.
const abs_bin = if (builtin.os.tag == .windows) "C:\\opt\\local\\bin" else "/opt/local/bin";

test "bootstrap: no line is no bin dir, and anything but one absolute path in the out file is bad output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, a);
    const installer = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "i" });
    const call = try std.fmt.allocPrint(a, "/r/scripts/backends/macports bootstrap {s}", .{installer});

    // Each scripted run writes its "answer" into the out file the plugin
    // was handed, as a real plugin would; stdout is the terminal's.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = call, .match = .prefix, .once = true },
        .{ .argv = call, .match = .prefix, .write_after = installer, .io = io, .stdout = "\n  \r\n", .once = true },
        .{ .argv = call, .match = .prefix, .write_after = installer, .io = io, .stdout = "installing...\n" ++ abs_bin ++ "\n", .once = true },
        .{ .argv = call, .match = .prefix, .write_after = installer, .io = io, .stdout = "opt/local/bin\n", .once = true },
        .{ .argv = call, .match = .prefix, .write_after = installer, .io = io, .stdout = abs_bin ++ "\n" },
    } };
    var p = pluginWith(&fake);
    try testing.expect((try p.backend().bootstrap(a, installer)) == null);
    try testing.expect((try p.backend().bootstrap(a, installer)) == null);
    try testing.expectError(Error.PluginBadOutput, p.backend().bootstrap(a, installer));
    try testing.expectError(Error.PluginBadOutput, p.backend().bootstrap(a, installer));
    try testing.expectEqualStrings(abs_bin, (try p.backend().bootstrap(a, installer)).?);
    // The out file never outlives the call.
    const out = try std.fmt.allocPrint(a, "{s}.bindir", .{installer});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, out, .{}));
    // The call itself is streamed: it carries the installer and the out file.
    try testing.expect(std.mem.endsWith(u8, fake.calls.items[0], out));
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

test "available: exit 64 is a broken backend, not a run-ending missing verb" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports available", .code = exit_not_implemented },
    } };
    var p = pluginWith(&fake);
    const got = try p.backend().available(a);
    try testing.expect(got == .broken);
    try testing.expectEqual(exit_not_implemented, got.broken.code);
    try testing.expectEqualStrings("macports available", got.broken.probe);
}

test "declare: a name the manifest would refuse is bad output, not a row commit writes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A plugin whose id maps `gnu make` onto `gnu@make`: the round trip
    // agrees, since it constrains the id and not the name, so only the name
    // rule stands between `declare` and a manifest row that never loads again.
    var spaced: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports declare gnu@make", .stdout = "name = \"gnu make\"\n" },
        .{ .argv = "/r/scripts/backends/macports id", .stdout = "gnu@make\n" },
    } };
    var sp = pluginWith(&spaced);
    try testing.expectError(Error.PluginBadOutput, sp.backend().declare(a, "gnu@make"));
    // Refused where the answer is read, before the row is handed back to `id`.
    try testing.expectEqual(@as(usize, 1), spaced.calls.items.len);

    var controlled: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports declare x", .stdout = "name = \"gnu\\u000bmake\"\n" },
        .{ .argv = "/r/scripts/backends/macports declare y", .stdout = "name = \"gnu\\u007fmake\"\n" },
    } };
    var cp = pluginWith(&controlled);
    try testing.expectError(Error.PluginBadOutput, cp.backend().declare(a, "x"));
    try testing.expectError(Error.PluginBadOutput, cp.backend().declare(a, "y"));
}

test "limitation: an oversize or control-carrying line is bad output, not a note" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const long = try std.fmt.allocPrint(a, "{s}\n", .{"x" ** (limitation_max + 1)});
    const at_cap = try std.fmt.allocPrint(a, "{s}\n", .{"x" ** limitation_max});
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "/r/scripts/backends/macports limitation", .stdout = long, .once = true },
        .{ .argv = "/r/scripts/backends/macports limitation", .stdout = "variants \x1b[31mare not\x1b[0m tracked\n", .once = true },
        .{ .argv = "/r/scripts/backends/macports limitation", .stdout = at_cap },
    } };
    var p = pluginWith(&fake);
    try testing.expectError(Error.PluginBadOutput, p.backend().limitationOf(a));
    try testing.expectError(Error.PluginBadOutput, p.backend().limitationOf(a));
    try testing.expectEqual(@as(usize, limitation_max), (try p.backend().limitationOf(a)).?.len);
}

test "bootstrap: an out file too large to hold one path is bad output, not a leaked read error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, a);
    const installer = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "i" });
    const call = try std.fmt.allocPrint(a, "/r/scripts/backends/macports bootstrap {s}", .{installer});

    const flood = try a.alloc(u8, 64 * 1024 + 1);
    @memset(flood, 'x');
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = call, .match = .prefix, .write_after = installer, .io = io, .stdout = flood },
    } };
    var p = pluginWith(&fake);
    try testing.expectError(Error.PluginBadOutput, p.backend().bootstrap(a, installer));
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

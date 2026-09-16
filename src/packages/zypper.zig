//! The zypper adapter.
//!
//! Unlike every other manager here, zypper cannot say what the user installed
//! on purpose. Verified against zypper 1.14: `--userinstalled` is not a flag
//! it knows, and `--installed-only` lists every dependency as well. So this
//! adapter keeps a ledger of what mox installed and treats that as the
//! explicit set, intersected with what rpm reports actually present.
//!
//! The intersection is what makes the ledger safe. A record alone would claim
//! a package is installed after someone removed it, and apply would never put
//! it back; a package that is gone drops out of the explicit set instead, is
//! reported missing, and is reinstalled.
//!
//! The cost is stated in `limitation`: a package installed by hand is
//! invisible here, so it is never offered for tracking.

const std = @import("std");

const backend_mod = @import("backend.zig");
const exec = @import("exec.zig");
const ledger_mod = @import("ledger.zig");
const manifest_mod = @import("manifest.zig");

const Io = std.Io;

pub const Row = manifest_mod.Row;
pub const Diag = manifest_mod.Diag;
pub const Backend = backend_mod.Backend;

pub const Error = error{
    UnknownZypperKey,
    ZypperQueryFailed,
    ZypperInstallFailed,
};

pub const Zypper = struct {
    runner: exec.Runner,
    ledger: ledger_mod.Ledger,
    /// Overrides the root check, so a test can exercise both paths on a host
    /// whose own uid it does not control.
    force_elevate: ?bool = null,

    pub fn backend(self: *Zypper) Backend {
        return .{
            .name = "zypper",
            .ctx = self,
            .vtable = &vtable,
            .limitation = "zypper cannot report what was installed by hand, so mox tracks only what it installed itself",
        };
    }

    const vtable: Backend.VTable = .{
        .available = availableImpl,
        .validate = validateImpl,
        .idOf = idOfImpl,
        .installedExplicit = installedExplicitImpl,
        .install = installImpl,
        .declare = declareImpl,
    };

    fn availableImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!Backend.Availability {
        const self: *Zypper = @ptrCast(@alignCast(ctx));
        return Backend.probeAvailability("zypper", self.runner.run(arena, &.{ "zypper", "--version" }));
    }

    fn validateImpl(_: *anyopaque, row: Row, diag: ?*Diag) anyerror!void {
        if (row.fields.len == 0) return;
        if (diag) |d| d.set(
            "{s}: row \"{s}\": zypper accepts no key \"{s}\"",
            .{ row.label, row.name, row.fields[0].key },
        );
        return Error.UnknownZypperKey;
    }

    fn idOfImpl(_: *anyopaque, _: std.mem.Allocator, row: Row) anyerror![]const u8 {
        return row.name;
    }

    /// The ledger, narrowed to what is actually installed. rpm is the query
    /// because it is the stable machine-readable one on this family; zypper's
    /// own search output is a table meant for a person.
    fn installedExplicitImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *Zypper = @ptrCast(@alignCast(ctx));

        const recorded = try self.ledger.read(arena);
        if (recorded.len == 0) return &.{};

        const res = try self.runner.run(arena, &.{ "rpm", "-qa", "--qf", "%{NAME}\n" });
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.ZypperQueryFailed;

        var present = std.StringHashMap(void).init(arena);
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            try present.put(line, {});
        }

        var out: std.ArrayList([]const u8) = .empty;
        for (recorded) |id| {
            if (present.contains(id)) try out.append(arena, id);
        }
        return out.toOwnedSlice(arena);
    }

    fn installImpl(ctx: *anyopaque, arena: std.mem.Allocator, rows: []const Row) anyerror!void {
        const self: *Zypper = @ptrCast(@alignCast(ctx));
        if (rows.len == 0) return;

        const elevate = if (self.force_elevate) |f| f else !exec.isRoot();

        var refresh: std.ArrayList([]const u8) = .empty;
        if (elevate) try refresh.append(arena, "sudo");
        try refresh.appendSlice(arena, &.{ "zypper", "--non-interactive", "refresh" });
        const up = try self.runner.stream(arena, refresh.items);
        try exec.checkTimedOut(up);
        if (!up.ok) return Error.ZypperInstallFailed;

        var argv: std.ArrayList([]const u8) = .empty;
        if (elevate) try argv.append(arena, "sudo");
        try argv.appendSlice(arena, &.{ "zypper", "--non-interactive", "install" });
        for (rows) |row| try argv.append(arena, row.name);

        const res = try self.runner.stream(arena, argv.items);
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.ZypperInstallFailed;

        // Recorded only after the install succeeded: a ledger entry for a
        // package that never landed would read as installed forever.
        var ids: std.ArrayList([]const u8) = .empty;
        for (rows) |row| try ids.append(arena, row.name);
        try self.ledger.add(arena, ids.items);
    }

    fn declareImpl(_: *anyopaque, _: std.mem.Allocator, id: []const u8) anyerror!Backend.Declaration {
        return .{ .name = id };
    }
};

const testing = std.testing;

fn rowOf(name: []const u8, fields: []const manifest_mod.Pair) Row {
    return .{
        .name = name,
        .backend = "zypper",
        .when = null,
        .fields = fields,
        .origin = "/tmp/x.toml",
        .label = "data/packages/suse.toml",
        .index = 0,
    };
}

fn tmpZypper(a: std.mem.Allocator, io: Io, sub: []const u8, fake: *exec.Fake) !Zypper {
    const cwd = try std.process.currentPathAlloc(io, a);
    const dir = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", sub, "state", "packages" });
    return .{
        .runner = fake.runner(),
        .ledger = .{ .io = io, .dir = dir, .backend = "zypper" },
        .force_elevate = true,
    };
}

test "installedExplicit: nothing recorded means nothing explicit, and rpm is not asked" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The Fake errors on anything unscripted, so querying rpm here would fail.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try testing.expectEqual(@as(usize, 0), (try z.backend().installedExplicit(a)).len);
    try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "installedExplicit: the ledger narrowed to what rpm reports present" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\nripgrep\nglibc\n" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    // `bat` was recorded but has since been removed behind mox's back.
    try z.ledger.add(a, &.{ "ripgrep", "bat" });

    const got = try z.backend().installedExplicit(a);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("ripgrep", got[0]);
}

test "installedExplicit: a package removed behind mox's back is reported missing again" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    try z.ledger.add(a, &.{"ripgrep"});

    // The record still names it; the system does not have it. Trusting the
    // record alone would leave it uninstalled forever.
    try testing.expectEqual(@as(usize, 0), (try z.backend().installedExplicit(a)).len);
}

test "installedExplicit: a failed rpm query is an error, never an empty set" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "rpm -qa --qf %{NAME}\n", .code = 1 },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    try z.ledger.add(a, &.{"ripgrep"});

    try testing.expectError(Error.ZypperQueryFailed, z.backend().installedExplicit(a));
}

test "install: refreshes, installs the batch, and records what landed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "sudo zypper --non-interactive install ripgrep bat" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try z.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("bat", &.{}) });
    const recorded = try z.ledger.read(a);
    try testing.expectEqual(@as(usize, 2), recorded.len);
    try testing.expectEqualStrings("ripgrep", recorded[0]);
}

test "install: a failure records nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "sudo zypper --non-interactive install ripgrep", .code = 1 },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try testing.expectError(Error.ZypperInstallFailed, z.backend().install(a, &.{rowOf("ripgrep", &.{})}));
    // A record here would claim it is installed forever.
    try testing.expectEqual(@as(usize, 0), (try z.ledger.read(a)).len);
}

test "install: root installs without sudo" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "zypper --non-interactive refresh" },
        .{ .argv = "zypper --non-interactive install bat" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    z.force_elevate = false;

    try z.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(fake.called("zypper --non-interactive install bat"));
}

test "backend: the blind spot is declared, not left to be discovered" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    try testing.expect(z.backend().limitation != null);
}

test "validate: a key meant for another manager is refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    var d: Diag = .{};
    const row = rowOf("bat", &.{.{ .key = "bucket", .value = .{ .string = "extras" } }});
    try testing.expectError(Error.UnknownZypperKey, z.backend().validate(row, &d));
}

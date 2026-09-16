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
    ZypperSelectorRow,
    ZypperQueryFailed,
    ZypperInstallFailed,
};

pub const Zypper = struct {
    runner: exec.Runner,
    ledger: ledger_mod.Ledger,
    /// Where a read-back failure after a failed install is said. The install's
    /// own error is what the call site reports, so this one has nowhere else
    /// to go and would otherwise be lost.
    err: ?*std.Io.Writer = null,
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
        return Backend.probeAvailability("zypper --version", self.runner.run(arena, &.{ "zypper", "--version" }));
    }

    fn validateImpl(_: *anyopaque, row: Row, diag: ?*Diag) anyerror!void {
        // zypper installs more than packages, but mox reads back what is
        // installed from `rpm`, which knows package names alone. A row
        // naming anything else would install and then read as missing on
        // every status, and be reinstalled on every apply.
        for ([_][]const u8{ "pattern:", "patch:", "product:", "srcpackage:", "application:" }) |selector| {
            if (!std.mem.startsWith(u8, row.name, selector)) continue;
            if (diag) |d| d.set(
                "{s}: row \"{s}\": zypper rows name packages; a \"{s}\" selector cannot be read back from rpm",
                .{ row.label, row.name, selector[0 .. selector.len - 1] },
            );
            return Error.ZypperSelectorRow;
        }
        // zypper also takes an arch- or version-qualified spec, which `rpm`
        // reports under the bare name: the row would install and then read
        // as missing forever.
        if (std.mem.indexOfAny(u8, row.name, "=<>")) |_| {
            if (diag) |d| d.set(
                "{s}: row \"{s}\": zypper rows name a package, with no version or relation",
                .{ row.label, row.name },
            );
            return Error.ZypperSelectorRow;
        }
        // Everything else zypper's install grammar accepts, refused by what a
        // package name IS rather than by a list of the shapes it is not:
        // `zypper install vim !nano` and `zypper install vim -nano` both
        // remove nano, and a capability (`pkgconfig(libcrypto)`) installs a
        // package of an entirely different name.
        if (backend_mod.nameProblem(row.name, .plain)) |problem| {
            if (diag) |d| d.set(
                "{s}: row \"{s}\": zypper rows name a package: {s}",
                .{ row.label, row.name, problem.text(.plain) },
            );
            return Error.ZypperSelectorRow;
        }
        if (backend_mod.rpmArchSuffix(row.name)) |_| {
            if (diag) |d| d.set(
                "{s}: row \"{s}\": zypper rows name a package, with no architecture",
                .{ row.label, row.name },
            );
            return Error.ZypperSelectorRow;
        }
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

    /// The ledger, narrowed to what is actually installed.
    fn installedExplicitImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *Zypper = @ptrCast(@alignCast(ctx));

        const recorded = try self.ledger.read(arena);
        if (recorded.len == 0) return &.{};
        return self.presentOf(arena, recorded);
    }

    /// The names of `ids` that rpm reports installed, in order. rpm is the
    /// query because it is the stable machine-readable one on this family;
    /// zypper's own search output is a table meant for a person.
    fn presentOf(self: *Zypper, arena: std.mem.Allocator, ids: []const []const u8) anyerror![]const []const u8 {
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
        for (ids) |id| {
            if (present.contains(id)) try out.append(arena, id);
        }
        return out.toOwnedSlice(arena);
    }

    /// zypper reports some outcomes that are not failures through its exit
    /// code: after a refresh, 100-103 (updates, patches, a reboot or a
    /// restart needed) and 106 (a repository skipped); after an install, 102
    /// and 103 (a reboot or restart needed for what was installed).
    fn refreshOk(res: exec.Result) bool {
        return res.ok or (res.code >= 100 and res.code <= 103) or res.code == 106;
    }

    fn installOk(res: exec.Result) bool {
        return res.ok or res.code == 102 or res.code == 103;
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
        if (!refreshOk(up)) return Error.ZypperInstallFailed;

        var argv: std.ArrayList([]const u8) = .empty;
        if (elevate) try argv.append(arena, "sudo");
        // `--` is accepted by zypper 1.14.101 and stops anything after it
        // being read as an option. `validate` is what refuses a name that is
        // not a package name; this bounds what a name reaching zypper can do.
        try argv.appendSlice(arena, &.{ "zypper", "--non-interactive", "install", "--" });
        for (rows) |row| try argv.append(arena, row.name);

        const res = try self.runner.stream(arena, argv.items);

        var ids: std.ArrayList([]const u8) = .empty;
        for (rows) |row| try ids.append(arena, row.name);
        if (!res.timed_out and installOk(res)) {
            try self.ledger.add(arena, ids.items);
            return;
        }
        // A batch that failed -- or was killed at its bound partway through --
        // may still have landed some of its rows, and a row that landed
        // unrecorded is invisible here forever: reported MISSING on every
        // status, re-attempted beside the same failing sibling on every apply.
        // Only what rpm confirms is recorded; nothing that never landed is.
        // A kill is the case the read-back matters most for, so it happens
        // before the timeout is reported, never instead of it.
        //
        // When rpm itself cannot answer, the whole batch is recorded: the
        // ledger is a candidate set that every read intersects with rpm, so
        // an id that never landed drops straight back out, while one that did
        // land and went unrecorded never comes back. The install is what
        // failed, so the read-back's own failure is said here rather than
        // returned in place of it.
        const landed = self.presentOf(arena, ids.items) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => blk: {
                if (self.err) |w| {
                    w.print(
                        "mox: zypper: rpm could not say which of the batch landed ({s}); all {d} are recorded, and every read narrows them to what rpm reports\n",
                        .{ exec.errorText(e), ids.items.len },
                    ) catch {};
                    w.flush() catch {};
                }
                break :blk ids.items;
            },
        };
        if (landed.len > 0) try self.ledger.add(arena, landed);
        try exec.checkTimedOut(res);
        return Error.ZypperInstallFailed;
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
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep bat" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try z.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("bat", &.{}) });
    const recorded = try z.ledger.read(a);
    try testing.expectEqual(@as(usize, 2), recorded.len);
    try testing.expectEqualStrings("ripgrep", recorded[0]);
}

test "install: a failure that landed nothing records nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep", .code = 1 },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\nglibc\n" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try testing.expectError(Error.ZypperInstallFailed, z.backend().install(a, &.{rowOf("ripgrep", &.{})}));
    // A record here would claim it is installed forever.
    try testing.expectEqual(@as(usize, 0), (try z.ledger.read(a)).len);
}

test "install: a failed batch records the rows that landed, and only those" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `ripgrep` landed before `nosuch` failed the batch. Unrecorded, it
    // would be MISSING on every status and re-attempted beside the same
    // failing sibling on every apply.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep nosuch", .code = 104 },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\nripgrep\n" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try testing.expectError(Error.ZypperInstallFailed, z.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("nosuch", &.{}) }));
    const recorded = try z.ledger.read(a);
    try testing.expectEqual(@as(usize, 1), recorded.len);
    try testing.expectEqualStrings("ripgrep", recorded[0]);
}

test "install: an install killed at its bound still records what landed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // MOX_INSTALL_TIMEOUT_MS kills zypper partway down the batch. Reporting
    // the kill without reading rpm back would leave everything zypper had
    // already committed unrecorded -- the exact loss the read-back exists to
    // prevent -- so the record happens first and the kill is still reported.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep bat", .timed_out = true },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\nripgrep\n" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try testing.expectError(error.TimedOut, z.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("bat", &.{}) }));
    const recorded = try z.ledger.read(a);
    try testing.expectEqual(@as(usize, 1), recorded.len);
    try testing.expectEqualStrings("ripgrep", recorded[0]);
}

test "install: a kill whose read-back also fails is still reported as a kill" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The rpm query cannot replace the kill with an error of its own: what
    // stopped the install is what the caller must be told.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep", .timed_out = true },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .code = 1 },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try testing.expectError(error.TimedOut, z.backend().install(a, &.{rowOf("ripgrep", &.{})}));
    try testing.expectEqual(@as(usize, 1), (try z.ledger.read(a)).len);
}

test "install: a failed batch whose read-back cannot run records the batch, and says so" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `ripgrep` landed before the batch failed, and rpm cannot say so.
    // Recording nothing would lose it forever -- MISSING on every status,
    // re-attempted on every apply -- while recording the batch costs only an
    // id that every read drops again.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep nosuch", .code = 4 },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    z.err = &w.writer;

    try testing.expectError(Error.ZypperInstallFailed, z.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("nosuch", &.{}) }));
    const recorded = try z.ledger.read(a);
    try testing.expectEqual(@as(usize, 2), recorded.len);
    try testing.expectEqualStrings(
        "mox: zypper: rpm could not say which of the batch landed (ZypperQueryFailed); all 2 are recorded, and every read narrows them to what rpm reports\n",
        w.written(),
    );

    // The record is a candidate set, not a claim: with rpm answering again,
    // the id that never landed is not in the explicit set.
    var after: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\nripgrep\n" },
    } };
    z.runner = after.runner();
    const explicit = try z.backend().installedExplicit(a);
    try testing.expectEqual(@as(usize, 1), explicit.len);
    try testing.expectEqualStrings("ripgrep", explicit[0]);
}

test "install: a reboot or restart needed after the install is a success" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ZYPPER_EXIT_INF_REBOOT_NEEDED (102) and ZYPPER_EXIT_INF_RESTART_NEEDED
    // (103) are informational; rpm is not consulted for a success.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "sudo zypper --non-interactive install -- kernel-default", .code = 102, .once = true },
        .{ .argv = "sudo zypper --non-interactive install -- kernel-default", .code = 103 },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try z.backend().install(a, &.{rowOf("kernel-default", &.{})});
    try z.backend().install(a, &.{rowOf("kernel-default", &.{})});
    const recorded = try z.ledger.read(a);
    try testing.expectEqual(@as(usize, 1), recorded.len);
    try testing.expectEqualStrings("kernel-default", recorded[0]);
    try testing.expect(!fake.called("rpm -qa --qf %{NAME}\n"));
}

test "install: an informational refresh exit is not a failed install" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const codes = [_]u8{ 100, 101, 102, 103, 106 };
    for (codes) |code| {
        var fake: exec.Fake = .{ .arena = a, .entries = &.{
            .{ .argv = "sudo zypper --non-interactive refresh", .code = code },
            .{ .argv = "sudo zypper --non-interactive install -- bat" },
        } };
        var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
        try z.backend().install(a, &.{rowOf("bat", &.{})});
        try testing.expect(fake.called("sudo zypper --non-interactive install -- bat"));
    }

    // 104 (ZYPPER_EXIT_INF_CAP_NOT_FOUND) after a refresh is not among them.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh", .code = 104 },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    try testing.expectError(Error.ZypperInstallFailed, z.backend().install(a, &.{rowOf("bat", &.{})}));
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
        .{ .argv = "zypper --non-interactive install -- bat" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    z.force_elevate = false;

    try z.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(fake.called("zypper --non-interactive install -- bat"));
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

test "validate: a selector row is refused, since rpm cannot read it back" {
    var d: Diag = .{};
    const row: Row = .{
        .name = "pattern:devel_basis",
        .backend = "zypper",
        .when = null,
        .fields = &.{},
        .origin = "/tmp/x.toml",
        .label = "data/packages/suse.toml",
        .index = 0,
    };
    var z: Zypper = .{ .runner = undefined, .ledger = undefined };
    try testing.expectError(Error.ZypperSelectorRow, z.backend().validate(row, &d));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "cannot be read back from rpm") != null);
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

test "validate: a name zypper would read as an operation is refused" {
    // `zypper --non-interactive install vim !nano` and the same with `-nano`
    // both report "1 to remove". Proved against zypper 1.14 in a tumbleweed
    // container; the row is refused before any argv is built.
    var z: Zypper = .{ .runner = undefined, .ledger = undefined };

    var d: Diag = .{};
    try testing.expectError(Error.ZypperSelectorRow, z.backend().validate(rowOf("!nano", &.{}), &d));
    try testing.expectEqualStrings(
        "data/packages/suse.toml: row \"!nano\": zypper rows name a package: a name begins with a letter or a digit",
        d.capture().?,
    );

    var minus: Diag = .{};
    try testing.expectError(Error.ZypperSelectorRow, z.backend().validate(rowOf("-nano", &.{}), &minus));
    try testing.expectEqualStrings(
        "data/packages/suse.toml: row \"-nano\": zypper rows name a package: a name begins with a letter or a digit",
        minus.capture().?,
    );

    var trailing: Diag = .{};
    try testing.expectError(Error.ZypperSelectorRow, z.backend().validate(rowOf("nano-", &.{}), &trailing));
    try testing.expectEqualStrings(
        "data/packages/suse.toml: row \"nano-\": zypper rows name a package: a name does not end with \"-\", which an install reads as a request to remove the package",
        trailing.capture().?,
    );
}

test "validate: a capability zypper resolves to another package is refused" {
    // `zypper install pkgconfig(libcrypto)` installs libressl-devel, which
    // rpm then reports under that name: the row would be MISSING on every
    // status and reinstalled on every apply.
    var z: Zypper = .{ .runner = undefined, .ledger = undefined };

    var d: Diag = .{};
    try testing.expectError(Error.ZypperSelectorRow, z.backend().validate(rowOf("pkgconfig(libcrypto)", &.{}), &d));
    try testing.expectEqualStrings(
        "data/packages/suse.toml: row \"pkgconfig(libcrypto)\": zypper rows name a package: a name holds only letters, digits and \".\", \"_\", \"+\" or \"-\"",
        d.capture().?,
    );

    for ([_][]const u8{ "perl(Foo::Bar)", "repo/pkg", "/usr/bin/vim", "vim,nano", "@group" }) |name| {
        var dg: Diag = .{};
        try testing.expectError(Error.ZypperSelectorRow, z.backend().validate(rowOf(name, &.{}), &dg));
    }
}

test "validate: the more specific selector and relation messages stand" {
    // The general rule would also refuse these, with a clause that says less
    // about why rpm cannot read the row back.
    var z: Zypper = .{ .runner = undefined, .ledger = undefined };

    var sel: Diag = .{};
    try testing.expectError(Error.ZypperSelectorRow, z.backend().validate(rowOf("pattern:devel_basis", &.{}), &sel));
    try testing.expectEqualStrings(
        "data/packages/suse.toml: row \"pattern:devel_basis\": zypper rows name packages; a \"pattern\" selector cannot be read back from rpm",
        sel.capture().?,
    );

    var rel: Diag = .{};
    try testing.expectError(Error.ZypperSelectorRow, z.backend().validate(rowOf("vim>=9.0", &.{}), &rel));
    try testing.expectEqualStrings(
        "data/packages/suse.toml: row \"vim>=9.0\": zypper rows name a package, with no version or relation",
        rel.capture().?,
    );

    var arch: Diag = .{};
    try testing.expectError(Error.ZypperSelectorRow, z.backend().validate(rowOf("vim.x86_64", &.{}), &arch));
    try testing.expectEqualStrings(
        "data/packages/suse.toml: row \"vim.x86_64\": zypper rows name a package, with no architecture",
        arch.capture().?,
    );
}

test "validate: the names real distributions ship are taken" {
    var z: Zypper = .{ .runner = undefined, .ledger = undefined };
    for ([_][]const u8{ "g++", "lib32-glibc", "python3.11", "gcc-c++", "zlib1g-dev", "perl-Foo-Bar", "libstdc++6" }) |name| {
        try z.backend().validate(rowOf(name, &.{}), null);
    }
}

test "install: the operands follow a --, so no name can be read as an option" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "sudo zypper --non-interactive install -- bat" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try z.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqualStrings("sudo zypper --non-interactive install -- bat", fake.calls.items[1]);
}

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
    /// Whether the last `install` ran zypper's install command, which
    /// `installSpawned` answers with: a refresh that fails stops the install
    /// before it, and nothing it named can have landed.
    spawned: bool = false,
    /// How many of the last `install`'s rows zypper was never handed, which
    /// `installRefused` answers with.
    refused: usize = 0,

    pub fn backend(self: *Zypper) Backend {
        return .{
            .name = "zypper",
            .ctx = self,
            .vtable = &vtable,
            .limitation = "zypper cannot report what was installed by hand, so mox tracks only what it installed itself",
            .install_check = "the package names zypper's repositories carry",
        };
    }

    const vtable: Backend.VTable = .{
        .available = availableImpl,
        .validate = validateImpl,
        .idOf = idOfImpl,
        .installedExplicit = installedExplicitImpl,
        .install = installImpl,
        .installSpawned = installSpawnedImpl,
        .installRefused = installRefusedImpl,
        .declare = declareImpl,
    };

    fn installSpawnedImpl(ctx: *anyopaque) bool {
        const self: *Zypper = @ptrCast(@alignCast(ctx));
        return self.spawned;
    }

    fn installRefusedImpl(ctx: *anyopaque) usize {
        const self: *Zypper = @ptrCast(@alignCast(ctx));
        return self.refused;
    }

    /// Say `fmt` where a refused row can be read, if anywhere.
    fn say(self: *Zypper, comptime fmt: []const u8, args: anytype) void {
        const w = self.err orelse return;
        w.print(fmt, args) catch {};
        w.flush() catch {};
    }

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

    /// The argv that asks zypper which of `names` its repositories carry
    /// under that exact name. `--match-exact` matches the NAME alone, never a
    /// capability: measured against zypper 1.14.94, `smtp_daemon` and `java`
    /// answer nothing here while the same search with `--provides` answers
    /// with the packages that provide them.
    ///
    /// Several operands are one OR search, so a batch is one call, and only
    /// the names that matched come back. `--quiet` drops the progress lines;
    /// what is left is zypper's `S | Name | Summary | Type` table, which is
    /// the only machine query zypper has for what its repositories carry.
    ///
    /// The pool includes what is already installed: measured on the same
    /// zypper, the first five names `rpm -qa` reported each answered here too,
    /// so a package that came from an rpm file rather than a repository is not
    /// refused.
    const search_head = [_][]const u8{ "zypper", "--non-interactive", "--quiet", "search", "--match-exact", "--type", "package" };

    /// zypper answers a search that matched nothing with
    /// ZYPPER_EXIT_INF_CAP_NOT_FOUND, which is an empty answer rather than a
    /// query that could not run.
    const exit_cap_not_found: u8 = 104;

    /// The names in one search table, or nothing when the search matched
    /// none. A row is a line whose last column is `package`, which the header
    /// (`Type`) and the rule under it are not; the name is the second column,
    /// ahead of the summary, so a summary carrying a `|` cannot move it.
    fn zypperNameSet(self: *Zypper, arena: std.mem.Allocator, argv: []const []const u8) anyerror!std.StringHashMap(void) {
        var set = std.StringHashMap(void).init(arena);
        const res = try self.runner.run(arena, argv);
        try exec.checkTimedOut(res);
        if (res.code == exit_cap_not_found) return set;
        if (!res.ok) return Error.ZypperQueryFailed;

        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            var fields = std.mem.splitScalar(u8, raw, '|');
            _ = fields.next() orelse continue;
            const name_field = fields.next() orelse continue;
            var columns: usize = 2;
            var last = name_field;
            while (fields.next()) |f| {
                last = f;
                columns += 1;
            }
            if (columns < 4) continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, last, " \t\r"), "package")) continue;
            const name = std.mem.trim(u8, name_field, " \t\r");
            if (name.len == 0) continue;
            try set.put(name, {});
        }
        return set;
    }

    /// The packages that provide `name`, never `name` itself, sorted: a hash
    /// map's order is not a message's.
    fn zypperProvidersOf(self: *Zypper, arena: std.mem.Allocator, name: []const u8) anyerror![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &search_head);
        try argv.appendSlice(arena, &.{ "--provides", "--", name });
        const set = try self.zypperNameSet(arena, argv.items);

        var out: std.ArrayList([]const u8) = .empty;
        var it = set.keyIterator();
        while (it.next()) |k| {
            if (std.mem.eql(u8, k.*, name)) continue;
            try out.append(arena, k.*);
        }
        std.mem.sort([]const u8, out.items, {}, lessThanString);
        return out.toOwnedSlice(arena);
    }

    /// Refuse the rows zypper has no package of that name for, and answer
    /// with the rest.
    ///
    /// An rpm virtual provide is spelled exactly like a package name, so it
    /// passes every shape rule there is: measured on openSUSE Leap 15.6 with
    /// zypper 1.14.94, `smtp_daemon` is no package, `zypper --non-interactive
    /// install -- smtp_daemon` exits 0 having installed `postfix`, and `rpm
    /// -qa` reports `postfix`. The row is missing on every status and
    /// reinstalled on every apply, and zypper exits 0 each time, so nothing
    /// ever surfaces it. `java` goes the same way, resolving to an openjdk.
    ///
    /// A name zypper has nothing at all for is refused too, rather than
    /// handed over: measured on the same zypper, `install -- ripgrep
    /// nosuchpkgxyz` exits 104 having installed NEITHER, so one bad row
    /// otherwise keeps every package beside it off the machine.
    ///
    /// Here rather than in `validate` because only the manager can answer it,
    /// and after the refresh because the refresh is what makes its answer the
    /// one the install will resolve against.
    fn refuseZypperNonPackages(self: *Zypper, arena: std.mem.Allocator, rows: []const Row) anyerror![]const Row {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &search_head);
        try argv.append(arena, "--");
        for (rows) |row| try argv.append(arena, row.name);
        const known = try self.zypperNameSet(arena, argv.items);

        var keep: std.ArrayList(Row) = .empty;
        for (rows) |row| {
            if (known.contains(row.name)) {
                try keep.append(arena, row);
                continue;
            }
            const providers = try self.zypperProvidersOf(arena, row.name);
            if (providers.len == 0) {
                self.say(
                    "mox: zypper: row \"{s}\" names no zypper package in this machine's repositories\n",
                    .{row.name},
                );
                continue;
            }
            var list: std.Io.Writer.Allocating = .init(arena);
            for (providers, 0..) |p, i| {
                if (i > 0) try list.writer.writeAll(", ");
                try list.writer.print("\"{s}\"", .{p});
            }
            self.say(
                "mox: zypper: row \"{s}\" names no zypper package; it is a capability provided by {s}, and rpm reports only the package name, so declare that instead\n",
                .{ row.name, list.written() },
            );
        }
        return keep.toOwnedSlice(arena);
    }

    fn installImpl(ctx: *anyopaque, arena: std.mem.Allocator, rows: []const Row) anyerror!void {
        const self: *Zypper = @ptrCast(@alignCast(ctx));
        self.spawned = false;
        self.refused = 0;
        if (rows.len == 0) return;

        const elevate = if (self.force_elevate) |f| f else !exec.isRoot();

        var refresh: std.ArrayList([]const u8) = .empty;
        if (elevate) try refresh.append(arena, "sudo");
        try refresh.appendSlice(arena, &.{ "zypper", "--non-interactive", "refresh" });
        const up = try self.runner.stream(arena, refresh.items);
        try exec.checkTimedOut(up);
        if (!refreshOk(up)) return Error.ZypperInstallFailed;

        // A row the manager has no package for is refused and the rest of the
        // batch installed: one row nobody can install must not keep every
        // other package off the machine, and `installRefused` reports how
        // many so the run counts them and exits non-zero.
        const keep = try self.refuseZypperNonPackages(arena, rows);
        self.refused = rows.len - keep.len;
        if (keep.len == 0) return;

        var argv: std.ArrayList([]const u8) = .empty;
        if (elevate) try argv.append(arena, "sudo");
        // `--` is accepted by zypper 1.14.101 and stops anything after it
        // being read as an option. `validate` is what refuses a name that is
        // not a package name; this bounds what a name reaching zypper can do.
        try argv.appendSlice(arena, &.{ "zypper", "--non-interactive", "install", "--" });
        for (keep) |row| try argv.append(arena, row.name);

        self.spawned = true;
        const res = try self.runner.stream(arena, argv.items);

        var ids: std.ArrayList([]const u8) = .empty;
        for (keep) |row| try ids.append(arena, row.name);
        if (!res.timed_out and installOk(res)) {
            // The install landed whatever the record can or cannot say about
            // it, so a state directory that cannot be written is said and not
            // reported as an install that failed. What is lost is the record:
            // these read as missing again on the next apply.
            self.ledger.add(arena, ids.items) catch |e| {
                if (e == error.OutOfMemory) return e;
                self.say(
                    "mox: zypper: the install landed, but its record could not be written ({s}); these {d} are reported missing again on the next apply\n",
                    .{ exec.errorText(e), ids.items.len },
                );
            };
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
                self.say(
                    "mox: zypper: rpm could not say which of the batch landed ({s}); all {d} are recorded, and every read narrows them to what rpm reports\n",
                    .{ exec.errorText(e), ids.items.len },
                );
                break :blk ids.items;
            },
        };
        if (landed.len > 0) {
            // What stopped the install is what the caller must be told, so a
            // record that cannot be written is said here rather than returned
            // in place of the install's own failure.
            self.ledger.add(arena, landed) catch |e| {
                if (e == error.OutOfMemory) return e;
                self.say(
                    "mox: zypper: {d} of the batch landed, but the record could not be written ({s}); they are reported missing again on the next apply\n",
                    .{ landed.len, exec.errorText(e) },
                );
            };
        }
        try exec.checkTimedOut(res);
        return Error.ZypperInstallFailed;
    }

    fn declareImpl(_: *anyopaque, _: std.mem.Allocator, id: []const u8) anyerror!Backend.Declaration {
        return .{ .name = id };
    }

    fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
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
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- ripgrep bat", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | bat | a package | package\n" },
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
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- ripgrep", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n" },
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
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- ripgrep nosuch", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | nosuch | a package | package\n" },
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
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- ripgrep bat", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | bat | a package | package\n" },
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
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- ripgrep", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n" },
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
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- ripgrep nosuch", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | nosuch | a package | package\n" },
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
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- kernel-default", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | kernel-default | a package | package\n" },
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
            .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- bat", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | bat | a package | package\n" },
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
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- bat", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | bat | a package | package\n" },
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
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- bat", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | bat | a package | package\n" },
        .{ .argv = "sudo zypper --non-interactive install -- bat" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try z.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqualStrings("sudo zypper --non-interactive install -- bat", fake.calls.items[2]);
}

test "install: a row naming an rpm virtual provide is refused, naming what provides it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on openSUSE Leap 15.6 with zypper 1.14.94: `smtp_daemon` is no
    // package, `zypper --non-interactive install -- smtp_daemon` exits 0
    // having installed postfix, and rpm reports postfix. The row would be
    // missing on every status and reinstalled on every apply, silently --
    // zypper exits 0 each time.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- ripgrep smtp_daemon", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n" },
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package --provides -- smtp_daemon", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | postfix | a mailer | package\n   | exim | a mailer | package\n" },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    z.err = &w.writer;

    try z.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("smtp_daemon", &.{}) });
    try testing.expectEqual(@as(usize, 1), z.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: zypper: row \"smtp_daemon\" names no zypper package; it is a capability provided by \"exim\", \"postfix\", and rpm reports only the package name, so declare that instead\n",
        w.written(),
    );
    // The row beside it was installed, and only it was recorded.
    try testing.expect(fake.called("sudo zypper --non-interactive install -- ripgrep"));
    const recorded = try z.ledger.read(a);
    try testing.expectEqual(@as(usize, 1), recorded.len);
    try testing.expectEqualStrings("ripgrep", recorded[0]);
}

test "install: a row zypper has nothing at all for is refused, and the batch beside it installed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on the same zypper: `install -- ripgrep nosuchpkgxyz` exits
    // 104 having installed NEITHER, so handing the bad name over would keep
    // the good one off the machine.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- ripgrep nosuchpkgxyz", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n" },
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package --provides -- nosuchpkgxyz", .code = 104 },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    z.err = &w.writer;

    try z.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("nosuchpkgxyz", &.{}) });
    try testing.expectEqual(@as(usize, 1), z.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: zypper: row \"nosuchpkgxyz\" names no zypper package in this machine's repositories\n",
        w.written(),
    );
    try testing.expect(fake.called("sudo zypper --non-interactive install -- ripgrep"));
}

test "install: a batch whose every row is refused never runs zypper" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- java", .code = 104 },
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package --provides -- java", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | java-11-openjdk | a runtime | package\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    z.err = &w.writer;

    try z.backend().install(a, &.{rowOf("java", &.{})});
    try testing.expectEqual(@as(usize, 1), z.backend().installRefused());
    try testing.expect(!z.backend().installSpawned());
    try testing.expectEqual(@as(usize, 0), (try z.ledger.read(a)).len);
}

test "install: a search that cannot run stops the install rather than refusing every row" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 104 is "matched nothing"; any other non-zero exit is a query that could
    // not answer, and reading that as "no row names a package" would refuse
    // every row on a machine whose zypper is merely unwell.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- bat", .code = 6 },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try testing.expectError(Error.ZypperQueryFailed, z.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!z.backend().installSpawned());
}

test "install: a record that cannot be written is said, not reported as a failed install" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A read-only state directory or a full disk. The install landed, so
    // reporting it as a failure would send the reader looking for a package
    // that is on the machine; what is lost is the record alone.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "zypper --non-interactive --quiet search --match-exact --type package -- bat", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | bat | a package | package\n" },
        .{ .argv = "sudo zypper --non-interactive install -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var z: Zypper = .{
        .runner = fake.runner(),
        // A path no directory can be made at: `ledger.add` fails on it.
        .ledger = .{ .io = io, .dir = "/dev/null/nowhere/packages", .backend = "zypper" },
        .force_elevate = true,
        .err = &w.writer,
    };

    try z.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(std.mem.startsWith(u8, w.written(), "mox: zypper: the install landed, but its record could not be written ("));
    try testing.expect(std.mem.endsWith(u8, w.written(), "); these 1 are reported missing again on the next apply\n"));
}

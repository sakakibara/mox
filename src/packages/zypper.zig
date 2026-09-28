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
    /// How many of the last `install`'s rows rpm reported present after the
    /// batch failed, which `installLanded` answers with; null when no batch
    /// failed, or rpm could not say.
    landed: ?usize = null,

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
        .installLanded = installLandedImpl,
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

    fn installLandedImpl(ctx: *anyopaque) ?usize {
        const self: *Zypper = @ptrCast(@alignCast(ctx));
        return self.landed;
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
        return self.presentOf(arena, recorded, false);
    }

    /// The names of `ids` that rpm reports installed, in order. rpm is the
    /// query because it is the stable machine-readable one on this family;
    /// zypper's own search output is a table meant for a person.
    ///
    /// `in_install` says which bound a kill answers to: a read made inside
    /// the streamed install is a captured call under the capture bound,
    /// which the install's call site cannot name on its own.
    fn presentOf(self: *Zypper, arena: std.mem.Allocator, ids: []const []const u8, in_install: bool) anyerror![]const []const u8 {
        const res = try self.runner.run(arena, &.{ "rpm", "-qa", "--qf", "%{NAME}\n" });
        if (in_install) try exec.checkCaptureTimedOut(res) else try exec.checkTimedOut(res);
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
    ///
    /// `--no-color`, because zypper.conf decides what a pipe gets: measured
    /// on zypper 1.14.101 with `useColors = always` under `[color]`, every
    /// cell of the captured table arrives wrapped in SGR sequences
    /// (`\e[22;27;39;49mpackage\e[0m`), which `NO_COLOR=1` does not undo,
    /// and the type column then matches nothing. `--no-color` restores the
    /// plain table there and on Leap 15.6's 1.14.94.
    const search_head = [_][]const u8{ "zypper", "--non-interactive", "--quiet", "--no-color", "search", "--match-exact", "--type", "package" };

    /// zypper answers a search that matched nothing with
    /// ZYPPER_EXIT_INF_CAP_NOT_FOUND, which is an empty answer rather than a
    /// query that could not run.
    const exit_cap_not_found: u8 = 104;

    const ZypperTable = struct {
        /// Every name the table carries as a package.
        names: std.StringHashMap(void),
        /// The names whose status column reads locked and not installed.
        locked: std.StringHashMap(void),
        /// The names whose status column reads locked and installed.
        installed_locked: std.StringHashMap(void),
    };

    /// The names in one search table, or nothing when the search matched
    /// none. A row is a line whose last column is `package`, which the header
    /// (`Type`) and the rule under it are not; the name is the second column,
    /// ahead of the summary, so a summary carrying a `|` cannot move it.
    ///
    /// `package` is the C-locale spelling, which the captured call runs
    /// under: measured on zypper 1.14.101 with its translations installed,
    /// the column reads `Paket` under `LANG=de_DE.UTF-8` and a Japanese word
    /// under `ja_JP.UTF-8`, and either would leave every row unmatched.
    ///
    /// The first column is the status, and a lock is read from it: measured
    /// on zypper 1.14.101 after `zypper addlock ripgrep`, the row reads
    /// ` l | ripgrep`, and once ripgrep is installed and still locked,
    /// `il | ripgrep`. The first is refused outright: with the lock on a
    /// package not yet installed, `zypper --non-interactive install --
    /// ripgrep bat` exits 4 asking for a solution and installs NEITHER. The
    /// second is refused only when an update is pending, which this table
    /// cannot say -- `il` reads the same with 1.0-69.1 available for the
    /// installed 1.0-68.1 as with nothing newer anywhere (measured on the
    /// same zypper with openSUSE-build-key) -- so `zypperUpdatePending` is
    /// asked about it.
    fn zypperNameSet(self: *Zypper, arena: std.mem.Allocator, argv: []const []const u8) anyerror!ZypperTable {
        var table: ZypperTable = .{
            .names = std.StringHashMap(void).init(arena),
            .locked = std.StringHashMap(void).init(arena),
            .installed_locked = std.StringHashMap(void).init(arena),
        };
        const res = try self.runner.run(arena, argv);
        try exec.checkCaptureTimedOut(res);
        if (res.code == exit_cap_not_found) return table;
        if (!res.ok) return Error.ZypperQueryFailed;

        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            var fields = std.mem.splitScalar(u8, raw, '|');
            const status_field = fields.next() orelse continue;
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
            try table.names.put(name, {});
            const status = std.mem.trim(u8, status_field, " \t\r");
            const locked = std.mem.indexOfScalar(u8, status, 'l') != null;
            const installed = std.mem.indexOfScalar(u8, status, 'i') != null;
            if (locked and !installed) try table.locked.put(name, {});
            if (locked and installed) try table.installed_locked.put(name, {});
        }
        return table;
    }

    /// The pending update of each of `names` that has one, as `current ->
    /// available`, or null when zypper could not say.
    ///
    /// `zypper list-updates --all` is the query, because zypper's own
    /// comparison is what decides: the `-s` search table lists every
    /// version a repository carries with `v` against each one not
    /// installed, and that reads the same for a newer version in one
    /// repository as for an older one left in another (measured on zypper
    /// 1.14.101: openSUSE-build-key 1.0-69.1 installed from Update shows
    /// `vl` for Oss's 1.0-68.1, and an install carrying it lands the batch
    /// and exits 0). `--all` because the plain listing omits an update a
    /// lock stops (measured: nothing without it, the `vl` row with it).
    /// The table is `S | Repository | Name | Current Version | Available
    /// Version | Arch`; a row is a line with those six columns whose name
    /// is one asked about.
    fn zypperUpdatePending(self: *Zypper, arena: std.mem.Allocator, names: std.StringHashMap(void)) anyerror!?std.StringHashMap([]const u8) {
        const res = try self.runner.run(arena, &.{ "zypper", "--non-interactive", "--quiet", "--no-color", "list-updates", "--all" });
        try exec.checkCaptureTimedOut(res);
        if (!res.ok) return null;

        var out = std.StringHashMap([]const u8).init(arena);
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            var fields = std.mem.splitScalar(u8, raw, '|');
            _ = fields.next() orelse continue;
            _ = fields.next() orelse continue;
            const name = std.mem.trim(u8, fields.next() orelse continue, " \t\r");
            const current = std.mem.trim(u8, fields.next() orelse continue, " \t\r");
            const available = std.mem.trim(u8, fields.next() orelse continue, " \t\r");
            if (!names.contains(name)) continue;
            try out.put(name, try std.fmt.allocPrint(arena, "{s} installed, {s} available", .{ current, available }));
        }
        return out;
    }

    /// The packages that provide `name`, never `name` itself, sorted: a hash
    /// map's order is not a message's.
    fn zypperProvidersOf(self: *Zypper, arena: std.mem.Allocator, name: []const u8) anyerror![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &search_head);
        try argv.appendSlice(arena, &.{ "--provides", "--", name });
        const table = try self.zypperNameSet(arena, argv.items);

        var out: std.ArrayList([]const u8) = .empty;
        var it = table.names.keyIterator();
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
    /// A LOCKED package is refused too, for the reason apt's held one is:
    /// `zypper install` answers a batch carrying one by installing none of
    /// it, exit 4 (measured, above), and the lock is the user's decision, so
    /// it is never lifted here. The name to lift it with is in the message.
    /// One installed and locked stops the batch only when an update is
    /// pending: measured on zypper 1.14.101 with openSUSE-build-key 1.0-68.1
    /// installed, 1.0-69.1 available and the lock on, `install --
    /// openSUSE-build-key ripgrep` exits 4 asking to choose a solution and
    /// ripgrep does not land; with 1.0-69.1 installed the same batch lands
    /// and exits 0. So such a row is refused when zypper lists an update
    /// for it -- and when zypper cannot say, since the batch is what is at
    /// stake.
    ///
    /// Here rather than in `validate` because only the manager can answer it,
    /// and after the refresh because the refresh is what makes its answer the
    /// one the install will resolve against.
    fn refuseZypperNonPackages(self: *Zypper, arena: std.mem.Allocator, rows: []const Row) anyerror![]const Row {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &search_head);
        try argv.append(arena, "--");
        for (rows) |row| try argv.append(arena, row.name);
        const table = try self.zypperNameSet(arena, argv.items);
        const known = table.names;
        const pending: ?std.StringHashMap([]const u8) = if (table.installed_locked.count() > 0)
            try self.zypperUpdatePending(arena, table.installed_locked)
        else
            std.StringHashMap([]const u8).init(arena);

        var keep: std.ArrayList(Row) = .empty;
        for (rows) |row| {
            if (table.locked.contains(row.name)) {
                self.say(
                    "mox: zypper: row \"{s}\" names a package zypper has locked, and an install carrying a locked package installs nothing at all, so it was not installed; `zypper removelock {s}` to let mox install it\n",
                    .{ row.name, row.name },
                );
                continue;
            }
            if (table.installed_locked.contains(row.name)) {
                const versions = pending orelse {
                    self.say(
                        "mox: zypper: row \"{s}\" names a package zypper has installed and locked, and zypper could not say whether an update is pending for it (`zypper list-updates --all` did not answer), which is what makes an install carrying it install nothing at all, so it was not installed; `zypper removelock {s}` to let mox install it\n",
                        .{ row.name, row.name },
                    );
                    continue;
                };
                if (versions.get(row.name)) |update| {
                    self.say(
                        "mox: zypper: row \"{s}\" names a package zypper has installed and locked with an update pending ({s}), and an install carrying it asks which to keep and installs nothing at all, so it was not installed; `zypper removelock {s}` to let mox install it\n",
                        .{ row.name, update, row.name },
                    );
                    continue;
                }
            }
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
        self.landed = null;
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

        var ids: std.ArrayList([]const u8) = .empty;
        for (keep) |row| try ids.append(arena, row.name);
        // What the machine has before the batch, so that a failed batch is
        // credited with what it landed and not with a package the user
        // installed by hand beside a failing sibling. rpm answering with a
        // failure, or not being there to answer at all, is a "no baseline"
        // case the record is written around; a read killed at its bound, or
        // one past the cap, is a machine that could not be read, and is that
        // error before any install.
        const before: ?[]const []const u8 = self.presentOf(arena, ids.items, true) catch |e| switch (e) {
            Error.ZypperQueryFailed => null,
            error.OutOfMemory => return e,
            error.StreamTooLong => {
                self.say(
                    "mox: zypper: `rpm -qa` answered with more than the {d} MiB mox reads from one query, so what the machine has could not be read and nothing was installed\n",
                    .{exec.max_query_bytes / (1024 * 1024)},
                );
                return e;
            },
            error.CaptureTimedOut => {
                self.say(
                    "mox: zypper: `rpm -qa` was killed at the bound a captured read gets, so what the machine has could not be read and nothing was installed\n",
                    .{},
                );
                return e;
            },
            else => blk: {
                self.say(
                    "mox: zypper: `rpm -qa` could not be run ({s}), so what this machine had before the batch is unknown and the install went ahead without it\n",
                    .{exec.errorText(e)},
                );
                break :blk null;
            },
        };

        self.spawned = true;
        const res = try self.runner.stream(arena, argv.items);

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
        // Only what rpm confirms landed IN THIS BATCH is recorded: present
        // now and absent before. A kill is the case the read-back matters
        // most for, so it happens before the timeout is reported, never
        // instead of it.
        //
        // When rpm could not answer, before or after, the whole batch is
        // recorded: the ledger is a candidate set that every read intersects
        // with rpm, so an id that never landed drops straight back out,
        // while one that did land and went unrecorded never comes back. The
        // install is what failed, so the read-back's own failure is said
        // here rather than returned in place of it.
        const landed = if (before == null) blk: {
            self.say(
                "mox: zypper: rpm could not say what the machine had before the batch; all {d} are recorded, and every read narrows them to what rpm reports\n",
                .{ids.items.len},
            );
            break :blk ids.items;
        } else if (self.presentOf(arena, ids.items, true)) |present| blk: {
            var new: std.ArrayList([]const u8) = .empty;
            for (present) |id| {
                const had = for (before.?) |b| {
                    if (std.mem.eql(u8, b, id)) break true;
                } else false;
                if (!had) try new.append(arena, id);
            }
            self.landed = new.items.len;
            break :blk new.items;
        } else |e| switch (e) {
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

fn countCalls(fake: *const exec.Fake, argv: []const u8) usize {
    var n: usize = 0;
    for (fake.calls.items) |c| {
        if (std.mem.eql(u8, c, argv)) n += 1;
    }
    return n;
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
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep bat", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | bat | a package | package\n" },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep bat" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
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
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n" },
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
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep nosuch", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | nosuch | a package | package\n" },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep nosuch", .code = 104 },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n", .once = true },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\nripgrep\n" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try testing.expectError(Error.ZypperInstallFailed, z.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("nosuch", &.{}) }));
    const recorded = try z.ledger.read(a);
    try testing.expectEqual(@as(usize, 1), recorded.len);
    try testing.expectEqualStrings("ripgrep", recorded[0]);
}

test "install: a package the machine had before a failed batch is neither counted nor recorded as landed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `ripgrep` was installed by hand before this apply; `nosuch` fails
    // the batch and zypper installs nothing. Read back with no baseline,
    // ripgrep counted as "1 row(s) landed" and went into the ledger though
    // the batch landed nothing.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep nosuch", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | nosuch | a package | package\n" },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep nosuch", .code = 104 },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\nripgrep\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    z.err = &w.writer;

    try testing.expectError(Error.ZypperInstallFailed, z.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("nosuch", &.{}) }));
    try testing.expectEqual(@as(?usize, 0), z.backend().installLanded());
    try testing.expectEqual(@as(usize, 0), (try z.ledger.read(a)).len);
    try testing.expectEqualStrings("", w.written());
    // The baseline is read before the batch, and the read-back after it.
    try testing.expectEqualStrings("rpm -qa --qf %{NAME}\n", fake.calls.items[2]);
    try testing.expectEqualStrings("sudo zypper --non-interactive install -- ripgrep nosuch", fake.calls.items[3]);
    try testing.expectEqualStrings("rpm -qa --qf %{NAME}\n", fake.calls.items[4]);

    // With no baseline to subtract, the batch is recorded as a candidate
    // set and said to be, as when the read-back itself cannot run.
    var blind: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep nosuch", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | nosuch | a package | package\n" },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep nosuch", .code = 104 },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .code = 1 },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var z2 = try tmpZypper(a, io, &tmp.sub_path, &blind);
    z2.err = &w2.writer;
    try testing.expectError(Error.ZypperInstallFailed, z2.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("nosuch", &.{}) }));
    try testing.expectEqual(@as(?usize, null), z2.backend().installLanded());
    try testing.expectEqualStrings(
        "mox: zypper: rpm could not say what the machine had before the batch; all 2 are recorded, and every read narrows them to what rpm reports\n",
        w2.written(),
    );
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
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep bat", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | bat | a package | package\n" },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep bat", .timed_out = true },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n", .once = true },
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
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n" },
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
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep nosuch", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | nosuch | a package | package\n" },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep nosuch", .code = 4 },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n", .once = true },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    z.err = &w.writer;

    try testing.expectError(Error.ZypperInstallFailed, z.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("nosuch", &.{}) }));
    const recorded = try z.ledger.read(a);
    try testing.expectEqual(@as(usize, 2), recorded.len);
    try testing.expectEqualStrings(
        "mox: zypper: rpm could not say which of the batch landed (the manager's own listing exited nonzero, saying why above); all 2 are recorded, and every read narrows them to what rpm reports\n",
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
    // (103) are informational; rpm is read for the baseline ahead of each
    // batch and not again after a success.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- kernel-default", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | kernel-default | a package | package\n" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
        .{ .argv = "sudo zypper --non-interactive install -- kernel-default", .code = 102, .once = true },
        .{ .argv = "sudo zypper --non-interactive install -- kernel-default", .code = 103 },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try z.backend().install(a, &.{rowOf("kernel-default", &.{})});
    try z.backend().install(a, &.{rowOf("kernel-default", &.{})});
    const recorded = try z.ledger.read(a);
    try testing.expectEqual(@as(usize, 1), recorded.len);
    try testing.expectEqualStrings("kernel-default", recorded[0]);
    try testing.expectEqual(@as(usize, 2), countCalls(&fake, "rpm -qa --qf %{NAME}\n"));
    try testing.expectEqualStrings("sudo zypper --non-interactive install -- kernel-default", fake.calls.items[fake.calls.items.len - 1]);
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
            .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- bat", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | bat | a package | package\n" },
            .{ .argv = "sudo zypper --non-interactive install -- bat" },
            .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
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
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- bat", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | bat | a package | package\n" },
        .{ .argv = "zypper --non-interactive install -- bat" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
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
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- bat", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | bat | a package | package\n" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
        .{ .argv = "sudo zypper --non-interactive install -- bat" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try z.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqualStrings("sudo zypper --non-interactive install -- bat", fake.calls.items[3]);
}

test "install: the name check asks zypper for a plain table, whatever zypper.conf colours" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Measured on Tumbleweed with `useColors = always` in zypper.conf: the
    // search's every cell reached the pipe as `\e[22;27;39;49mripgrep\e[0m`,
    // so a check reading the table refused both a real package and a name
    // zypper has nothing for, and the apply installed nothing. Only the
    // argv can hold that off; the Fake answers the plain table to it and
    // nothing to the argv without it.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{
            .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep",
            .stdout = "S | Name    | Summary                                  | Type\n--+---------+------------------------------------------+--------\n  | ripgrep | A search tool that combines ag with grep | package\n",
        },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try z.backend().install(a, &.{rowOf("ripgrep", &.{})});
    try testing.expectEqual(@as(usize, 0), z.backend().installRefused());
    try testing.expect(fake.called("sudo zypper --non-interactive install -- ripgrep"));
    for (fake.calls.items) |c| {
        if (std.mem.indexOf(u8, c, " search ") != null) try testing.expect(std.mem.indexOf(u8, c, " --no-color ") != null);
    }
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
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep smtp_daemon", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n" },
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package --provides -- smtp_daemon", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | postfix | a mailer | package\n   | exim | a mailer | package\n" },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
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
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep nosuchpkgxyz", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n" },
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package --provides -- nosuchpkgxyz", .code = 104 },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
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

test "install: a locked package is refused, naming the lock to lift, and the batch beside it installs" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on zypper 1.14.101 after `zypper addlock ripgrep`: the search
    // row reads ` l | ripgrep`, and `zypper --non-interactive install --
    // ripgrep bat` exits 4 asking to choose a solution, having installed
    // NEITHER -- on every apply, since the lock is the user's and stays.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{
            .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep bat",
            .stdout = "S  | Name    | Summary   | Type\n---+---------+-----------+--------\n   | bat     | a package | package\n l | ripgrep | a package | package\n",
        },
        .{ .argv = "sudo zypper --non-interactive install -- bat" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    z.err = &w.writer;

    try z.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("bat", &.{}) });
    try testing.expectEqual(@as(usize, 1), z.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: zypper: row \"ripgrep\" names a package zypper has locked, and an install carrying a locked package installs nothing at all, so it was not installed; `zypper removelock ripgrep` to let mox install it\n",
        w.written(),
    );
    try testing.expect(fake.called("sudo zypper --non-interactive install -- bat"));
    // The lock is never lifted, and the locked row is not asked about as a
    // provision either: it is a package, and the lock is the whole answer.
    for (fake.calls.items) |c| {
        try testing.expect(std.mem.indexOf(u8, c, "removelock") == null);
        try testing.expect(std.mem.indexOf(u8, c, "--provides") == null);
    }
    const recorded = try z.ledger.read(a);
    try testing.expectEqual(@as(usize, 1), recorded.len);
    try testing.expectEqualStrings("bat", recorded[0]);
}

const zypper_updates = "zypper --non-interactive --quiet --no-color list-updates --all";

test "install: a package installed and locked with no update pending is not refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on the same zypper with bat installed and then locked: the
    // row reads `il | bat`, `list-updates --all` lists nothing for it, and
    // `zypper --non-interactive install -- bat ripgrep` exits 0 having
    // landed ripgrep. A lock on a package the machine has at its newest
    // stops nothing, so refusing it would keep a row that converges off
    // the ledger for ever.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{
            .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- bat ripgrep",
            .stdout = "S  | Name    | Summary   | Type\n---+---------+-----------+--------\nil | bat     | a package | package\n   | ripgrep | a package | package\n",
        },
        .{ .argv = zypper_updates, .stdout = "" },
        .{ .argv = "sudo zypper --non-interactive install -- bat ripgrep" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    z.err = &w.writer;

    try z.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("ripgrep", &.{}) });
    try testing.expectEqual(@as(usize, 0), z.backend().installRefused());
    try testing.expectEqualStrings("", w.written());
    try testing.expect(fake.called("sudo zypper --non-interactive install -- bat ripgrep"));

    // With no installed-and-locked row in the table, updates are not asked
    // about at all: the Fake would fail the unscripted call.
    var plain: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{
            .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- bat ripgrep",
            .stdout = "S  | Name    | Summary   | Type\n---+---------+-----------+--------\ni+ | bat     | a package | package\n   | ripgrep | a package | package\n",
        },
        .{ .argv = "sudo zypper --non-interactive install -- bat ripgrep" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
    } };
    var z2 = try tmpZypper(a, io, &tmp.sub_path, &plain);
    try z2.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("ripgrep", &.{}) });
    try testing.expect(!plain.called(zypper_updates));
}

test "install: a package installed and locked with an update pending is refused, naming both versions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on zypper 1.14.101 with openSUSE-build-key 1.0-68.1
    // installed, 1.0-69.1 in the Update repository and `zypper addlock
    // openSUSE-build-key`: the search row reads `il`, exactly as with no
    // update anywhere, `list-updates --all` reads `vl | ... |
    // openSUSE-build-key | 1.0-68.1 | 1.0-69.1 | aarch64`, and `zypper
    // --non-interactive install -- openSUSE-build-key ripgrep` exits 4
    // asking to choose a solution with ripgrep NOT installed -- on every
    // apply. With the lock removed, both land.
    const search = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- openSUSE-build-key ripgrep";
    const table = "S  | Name               | Summary   | Type\n---+--------------------+-----------+--------\nil | openSUSE-build-key | gpg keys  | package\n   | ripgrep            | a package | package\n";
    const updates = "S  | Repository                 | Name               | Current Version | Available Version | Arch\n---+----------------------------+--------------------+-----------------+-------------------+--------\nvl | openSUSE-Tumbleweed-Update | openSUSE-build-key | 1.0-68.1        | 1.0-69.1          | aarch64\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = search, .stdout = table },
        .{ .argv = zypper_updates, .stdout = updates },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    z.err = &w.writer;

    try z.backend().install(a, &.{ rowOf("openSUSE-build-key", &.{}), rowOf("ripgrep", &.{}) });
    try testing.expectEqual(@as(usize, 1), z.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: zypper: row \"openSUSE-build-key\" names a package zypper has installed and locked with an update pending (1.0-68.1 installed, 1.0-69.1 available), and an install carrying it asks which to keep and installs nothing at all, so it was not installed; `zypper removelock openSUSE-build-key` to let mox install it\n",
        w.written(),
    );
    try testing.expect(fake.called("sudo zypper --non-interactive install -- ripgrep"));
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "removelock") == null);

    // When zypper cannot say whether an update is pending, the row goes
    // rather than the batch.
    var blind: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = search, .stdout = table },
        .{ .argv = zypper_updates, .code = 1 },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var z2 = try tmpZypper(a, io, &tmp.sub_path, &blind);
    z2.err = &w2.writer;
    try z2.backend().install(a, &.{ rowOf("openSUSE-build-key", &.{}), rowOf("ripgrep", &.{}) });
    try testing.expectEqual(@as(usize, 1), z2.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: zypper: row \"openSUSE-build-key\" names a package zypper has installed and locked, and zypper could not say whether an update is pending for it (`zypper list-updates --all` did not answer), which is what makes an install carrying it install nothing at all, so it was not installed; `zypper removelock openSUSE-build-key` to let mox install it\n",
        w2.written(),
    );
    try testing.expect(blind.called("sudo zypper --non-interactive install -- ripgrep"));
}

test "install: a captured call killed at its bound inside the install is reported under the capture bound" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The search answers to MOX_SCRIPT_TIMEOUT_MS; the install's call site
    // arms MOX_INSTALL_TIMEOUT_MS and would name it for a plain TimedOut.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- bat", .timed_out = true },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    try testing.expectError(error.CaptureTimedOut, z.backend().install(a, &.{rowOf("bat", &.{})}));

    // The explicit-install read is a captured verb of its own, bounded and
    // named by its caller: a kill there is a plain TimedOut.
    var status: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "rpm -qa --qf %{NAME}\n", .timed_out = true },
    } };
    var z2 = try tmpZypper(a, io, &tmp.sub_path, &status);
    try z2.ledger.add(a, &.{"bat"});
    try testing.expectError(error.TimedOut, z2.backend().installedExplicit(a));
}

test "install: a baseline read killed at its bound, or past the cap, is that error, and zypper never runs" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A kill under the capture bound, or an answer past the cap, is a
    // machine that could not be read rather than an empty one, and each
    // says which read it was: what apply prints of the error names the
    // bound alone, so the read behind it is named here.
    const search = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- bat";
    const table = "S  | Name | Summary | Type\n---+------+---------+--------\n   | bat | a package | package\n";
    var killed: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = search, .stdout = table },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .timed_out = true },
    } };
    var w0: std.Io.Writer.Allocating = .init(a);
    var z = try tmpZypper(a, io, &tmp.sub_path, &killed);
    z.err = &w0.writer;
    try testing.expectError(error.CaptureTimedOut, z.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!z.backend().installSpawned());
    try testing.expectEqualStrings(
        "mox: zypper: `rpm -qa` was killed at the bound a captured read gets, so what the machine has could not be read and nothing was installed\n",
        w0.written(),
    );
    try testing.expect(!killed.called("sudo zypper --non-interactive install -- bat"));

    var wide: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = search, .stdout = table },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .fail = error.StreamTooLong },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var z2 = try tmpZypper(a, io, &tmp.sub_path, &wide);
    z2.err = &w.writer;
    try testing.expectError(error.StreamTooLong, z2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!z2.backend().installSpawned());
    try testing.expectEqualStrings(
        "mox: zypper: `rpm -qa` answered with more than the 8 MiB mox reads from one query, so what the machine has could not be read and nothing was installed\n",
        w.written(),
    );
    try testing.expect(!wide.called("sudo zypper --non-interactive install -- bat"));
}

test "install: an rpm that cannot be run at all is a batch with no baseline, said, not an install that never ran" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The baseline is what a FAILED batch is credited against, and the
    // record is written around its absence. A spawn that finds no rpm is
    // that absence, not a machine that could not be read: zypper installs
    // what it can either way, and refusing to run it would keep every
    // package off this machine over a read the record does without.
    const search = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep bat";
    const table = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | bat | a package | package\n";
    const said = "mox: zypper: `rpm -qa` could not be run (it is not on this machine), so what this machine had before the batch is unknown and the install went ahead without it\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = search, .stdout = table },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .fail = error.FileNotFound },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    z.err = &w.writer;
    try z.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("bat", &.{}) });
    try testing.expect(z.backend().installSpawned());
    try testing.expect(fake.called("sudo zypper --non-interactive install -- ripgrep bat"));
    try testing.expectEqualStrings(said, w.written());
    try testing.expectEqual(@as(usize, 2), (try z.ledger.read(a)).len);

    // A batch that then fails records all of its rows, since nothing says
    // which of them the machine already had.
    var failed: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = search, .stdout = table },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .fail = error.FileNotFound },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep bat", .code = 4 },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var z2 = try tmpZypper(a, io, &tmp.sub_path, &failed);
    z2.err = &w2.writer;
    try testing.expectError(Error.ZypperInstallFailed, z2.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("bat", &.{}) }));
    try testing.expectEqual(@as(?usize, null), z2.backend().installLanded());
    try testing.expectEqualStrings(
        said ++ "mox: zypper: rpm could not say what the machine had before the batch; all 2 are recorded, and every read narrows them to what rpm reports\n",
        w2.written(),
    );
}

test "install: a failed batch says how many of its rows landed, when rpm could say" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const search = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep bat";
    const table = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | bat | a package | package\n";

    // The read-back found nothing: the caller has nothing to hedge about.
    var none: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = search, .stdout = table },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep bat", .code = 4 },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &none);
    try testing.expectError(Error.ZypperInstallFailed, z.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("bat", &.{}) }));
    try testing.expectEqual(@as(?usize, 0), z.backend().installLanded());

    // One landed: that is the count, and the record.
    var one: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = search, .stdout = table },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep bat", .code = 104 },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n", .once = true },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\nbat\n" },
    } };
    var z2 = try tmpZypper(a, io, &tmp.sub_path, &one);
    try testing.expectError(Error.ZypperInstallFailed, z2.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("bat", &.{}) }));
    try testing.expectEqual(@as(?usize, 1), z2.backend().installLanded());

    // rpm could not say: no count, and the caller hedges as before.
    var unknown: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = search, .stdout = table },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep bat", .code = 4 },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var z3 = try tmpZypper(a, io, &tmp.sub_path, &unknown);
    z3.err = &w.writer;
    try testing.expectError(Error.ZypperInstallFailed, z3.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("bat", &.{}) }));
    try testing.expectEqual(@as(?usize, null), z3.backend().installLanded());

    // A batch that succeeded has no count either: nothing failed.
    var fine: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = search, .stdout = table },
        .{ .argv = "sudo zypper --non-interactive install -- ripgrep bat" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
    } };
    var z4 = try tmpZypper(a, io, &tmp.sub_path, &fine);
    try z4.backend().install(a, &.{ rowOf("ripgrep", &.{}), rowOf("bat", &.{}) });
    try testing.expectEqual(@as(?usize, null), z4.backend().installLanded());
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
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- java", .code = 104 },
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package --provides -- java", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | java-11-openjdk | a runtime | package\n" },
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
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- bat", .code = 6 },
    } };
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);

    try testing.expectError(Error.ZypperQueryFailed, z.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!z.backend().installSpawned());
}

test "install: a record that cannot be written is said, not reported as a failed install" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A read-only state directory or a full disk. The install landed, so
    // reporting it as a failure would send the reader looking for a package
    // that is on the machine; what is lost is the record alone.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo zypper --non-interactive refresh" },
        .{ .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- bat", .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | bat | a package | package\n" },
        .{ .argv = "sudo zypper --non-interactive install -- bat" },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    // Under a regular file no directory can be made, on every platform:
    // `ledger.add` fails on it.
    try tmp.dir.writeFile(io, .{ .sub_path = "blocker", .data = "" });
    var z = try tmpZypper(a, io, &tmp.sub_path, &fake);
    const cwd = try std.process.currentPathAlloc(io, a);
    z.ledger.dir = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "blocker", "packages" });
    z.err = &w.writer;

    try z.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(std.mem.startsWith(u8, w.written(), "mox: zypper: the install landed, but its record could not be written ("));
    try testing.expect(std.mem.endsWith(u8, w.written(), "); these 1 are reported missing again on the next apply\n"));
}

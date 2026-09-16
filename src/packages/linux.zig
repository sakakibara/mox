//! The Linux distro adapters: apt, dnf, pacman.
//!
//! One file because they differ only in their argv: same identity (a bare
//! package name, no second namespace to keep apart), same rows (no fields
//! beyond the core set), same shape of query and install. A manager that
//! grows a concept of its own -- dnf module streams, apt architectures --
//! earns its fields here rather than in the core.
//!
//! Every install is non-interactive, because `mox apply` is: a manager that
//! stops to ask a question mox cannot answer would hang a bootstrap.
//!
//! An install elevates through `sudo` only when the process is not already
//! root. A container and a root WSL install commonly have no `sudo` at all,
//! where prepending it unconditionally turns every install into
//! "sudo: command not found". Queries never elevate.

const std = @import("std");

const backend_mod = @import("backend.zig");
const exec = @import("exec.zig");
const manifest_mod = @import("manifest.zig");

pub const Row = manifest_mod.Row;
pub const Diag = manifest_mod.Diag;
pub const Backend = backend_mod.Backend;

pub const Error = error{
    UnknownDistroKey,
    DistroSelectorRow,
    DistroQueryFailed,
    DistroInstallFailed,
    DistroNameNotAPackage,
};

pub const Manager = enum {
    apt,
    dnf,
    pacman,

    /// The executable whose presence means this manager is usable here.
    fn exe(self: Manager) []const u8 {
        return switch (self) {
            .apt => "apt-get",
            .dnf => "dnf",
            .pacman => "pacman",
        };
    }

    fn name(self: Manager) []const u8 {
        return @tagName(self);
    }

    /// How wide this manager's package namespace is. apt's own
    /// explicit-install query reports a foreign-architecture package as
    /// `pkg:arch`, so a row must be able to spell one; dnf and pacman have no
    /// such qualifier, and admitting a colon there would admit a name rpm
    /// and pacman never report back.
    fn nameClass(self: Manager) backend_mod.NameClass {
        return switch (self) {
            .apt => .multiarch,
            .dnf, .pacman => .plain,
        };
    }

    /// The query that answers "what did the user install on purpose", as
    /// opposed to what came in as a dependency.
    fn queryArgv(self: Manager) []const []const u8 {
        return switch (self) {
            .apt => &.{ "apt-mark", "showmanual" },
            // The trailing newline is load-bearing: without it dnf5 emits
            // every name concatenated into one line, which reads back as a
            // single absurd package and makes every declared row look
            // missing. The default format is full NEVRA
            // (`bat-0:0.24.0-1.fc44.aarch64`), which matches no row either.
            // `-q` because dnf4 (RHEL 8 and 9, Fedora up to 40) prints
            // "Last metadata expiration check ..." on stdout, where it would
            // read as a package name.
            .dnf => &.{ "dnf", "-q", "repoquery", "--userinstalled", "--qf", "%{name}\n" },
            .pacman => &.{ "pacman", "-Qeq" },
        };
    }

    /// What this manager's install asks the manager itself about a row, for a
    /// dry run to name as what it did not check.
    fn installCheck(self: Manager) []const u8 {
        return switch (self) {
            .apt => "apt's own package list",
            .dnf => "the packages dnf's repositories carry",
            .pacman => "the packages pacman's repositories carry",
        };
    }
};

pub const Distro = struct {
    manager: Manager,
    runner: exec.Runner,
    /// Overrides the root check, so a test can exercise both paths on a host
    /// whose own uid it does not control.
    force_elevate: ?bool = null,
    /// Where a row refused at install time is said. The install's own error
    /// is what the call site reports, so the row and the name to write in its
    /// place have nowhere else to go.
    err: ?*std.Io.Writer = null,
    /// Whether the last `install` ran the manager's install command, which
    /// `installSpawned` answers with.
    spawned: bool = false,

    pub fn backend(self: *Distro) Backend {
        return .{
            .name = self.manager.name(),
            .ctx = self,
            .vtable = &vtable,
            .install_check = self.manager.installCheck(),
        };
    }

    const vtable: Backend.VTable = .{
        .available = availableImpl,
        .validate = validateImpl,
        .idOf = idOfImpl,
        .installedExplicit = installedExplicitImpl,
        .install = installImpl,
        .installSpawned = installSpawnedImpl,
        .declare = declareImpl,
    };

    fn installSpawnedImpl(ctx: *anyopaque) bool {
        const self: *Distro = @ptrCast(@alignCast(ctx));
        return self.spawned;
    }

    fn availableImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!Backend.Availability {
        const self: *Distro = @ptrCast(@alignCast(ctx));
        const exe = self.manager.exe();
        return Backend.probeAvailability(try std.fmt.allocPrint(arena, "{s} --version", .{exe}), self.runner.run(arena, &.{ exe, "--version" }));
    }

    /// A row names one plain package and carries no key.
    ///
    /// The name is checked against `nameProblem` rather than against a
    /// list of bad shapes: an install argv accepts more than package names,
    /// and `apt-get install -y vim nano-` removes nano -- which would make
    /// `mox apply` uninstall a package on every run.
    ///
    /// Only the shape is judged here. Whether apt or dnf has a package of
    /// that name needs the manager, and is judged where the install is.
    ///
    /// Refusing an unknown key keeps a key that means something to a
    /// different manager (a brew `kind`, a scoop `bucket`) from sitting in a
    /// row that silently ignores it.
    fn validateImpl(ctx: *anyopaque, row: Row, diag: ?*Diag) anyerror!void {
        const self: *Distro = @ptrCast(@alignCast(ctx));
        const class = self.manager.nameClass();
        if (backend_mod.nameProblem(row.name, class)) |problem| {
            if (diag) |d| d.set(
                "{s}: row \"{s}\": {s} rows name a package: {s}",
                .{ row.label, row.name, self.manager.name(), problem.text(class) },
            );
            return Error.DistroSelectorRow;
        }
        // dnf also takes a full NEVRA (`bat-0.24.0-1.x86_64`) and a bare
        // `name.arch`, both of which rpm reports under the bare name: the row
        // would install and then read as missing on every status after. apt
        // and pacman have no such spelling within the plain-name class.
        if (self.manager == .dnf) {
            if (backend_mod.rpmArchSuffix(row.name)) |_| {
                if (diag) |d| d.set(
                    "{s}: row \"{s}\": dnf rows name a package, with no architecture",
                    .{ row.label, row.name },
                );
                return Error.DistroSelectorRow;
            }
        }
        if (row.fields.len == 0) return;
        if (diag) |d| d.set(
            "{s}: row \"{s}\": {s} accepts no key \"{s}\"",
            .{ row.label, row.name, self.manager.name(), row.fields[0].key },
        );
        return Error.UnknownDistroKey;
    }

    /// A package name is its own identity here: one namespace, no kinds.
    fn idOfImpl(_: *anyopaque, _: std.mem.Allocator, row: Row) anyerror![]const u8 {
        return row.name;
    }

    fn installedExplicitImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *Distro = @ptrCast(@alignCast(ctx));
        const res = try self.runner.run(arena, self.manager.queryArgv());
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;

        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            try out.append(arena, line);
        }
        return out.toOwnedSlice(arena);
    }

    /// The whole set in one invocation: these managers resolve a batch in a
    /// single pass, and pacman's `-Syu` syncs the database as it goes, so
    /// driving them one package at a time would repeat that work per package.
    fn installImpl(ctx: *anyopaque, arena: std.mem.Allocator, rows: []const Row) anyerror!void {
        const self: *Distro = @ptrCast(@alignCast(ctx));
        self.spawned = false;
        if (rows.len == 0) return;

        const elevate = self.elevates();

        if (self.manager == .apt) {
            // An install resolves against the index, so a stale one turns a
            // present package into "not found".
            var up_argv: std.ArrayList([]const u8) = .empty;
            if (elevate) try up_argv.append(arena, "sudo");
            try up_argv.appendSlice(arena, &apt_env);
            try up_argv.appendSlice(arena, &.{ "apt-get", "update" });
            const up = try self.runner.stream(arena, up_argv.items);
            try exec.checkTimedOut(up);
            if (!up.ok) return Error.DistroInstallFailed;
            try self.refuseAptNonNames(arena, rows);
        }
        if (self.manager == .dnf) try self.refuseDnfNonPackages(arena, rows);
        if (self.manager == .pacman) try self.refusePacmanNonPackages(arena, rows, elevate);

        var argv: std.ArrayList([]const u8) = .empty;
        if (elevate) try argv.append(arena, "sudo");
        if (self.manager == .apt) try argv.appendSlice(arena, &apt_env);
        const head: []const []const u8 = switch (self.manager) {
            .apt => &.{ "apt-get", "install", "-y" },
            .dnf => &.{ "dnf", "install", "-y" },
            .pacman => &.{ "pacman", "-Syu", "--needed", "--noconfirm" },
        };
        try argv.appendSlice(arena, head);
        // `--` stops an operand being read as an option, and apt-get 3.0.3
        // and pacman 7.1.0 both take one. It is not the fix -- `validate`
        // refuses a name that is not a package name, and apt reads its remove
        // suffix after a `--` all the same -- but it bounds what a name
        // reaching the manager can do. dnf takes none at all: dnf5 5.2.x,
        // which is every Fedora from 41 to 43, fails an install or a
        // repoquery carrying one with `Unknown argument "--"` and exit 2.
        // Nothing is lost there, because the name class refuses a leading
        // `-`, so no operand mox passes can be read as an option.
        if (self.manager != .dnf) try argv.append(arena, "--");
        for (rows) |row| try argv.append(arena, row.name);

        self.spawned = true;
        const res = try self.runner.stream(arena, argv.items);
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroInstallFailed;
    }

    /// Say `fmt` where a refused row can be read, if anywhere.
    fn say(self: *Distro, comptime fmt: []const u8, args: anytype) void {
        const w = self.err orelse return;
        w.print(fmt, args) catch {};
        w.flush() catch {};
    }

    /// The names apt has, one per line. Verified against apt 3.0.3: this is
    /// the query that matches an operand LITERALLY -- `apt-cache show` and
    /// `apt-cache policy` both take a regex -- and it lists the bare name
    /// alone, never a `:arch` form. About 1.2 MiB on Debian trixie and
    /// 1.8 MiB on Ubuntu 24.04, well inside a captured call's cap.
    const apt_names_argv = [_][]const u8{ "apt-cache", "--generate", "pkgnames" };

    /// Refuse a batch carrying a name apt has no package for.
    ///
    /// `apt-get install` falls back to matching an operand as an unanchored
    /// POSIX regex over every package name when no package is named exactly,
    /// and `--` does not stop it. `.` and `+` are regex metacharacters and
    /// both are in the name class because `python3.11` and `g++` need them,
    /// so an operand such as `ruby.dev` installs hundreds of packages no
    /// manifest declares -- which mox then reports as untracked forever while
    /// the row itself stays missing.
    ///
    /// Here rather than in `validate` because only the manager can answer it:
    /// `validate` runs at manifest load on every machine, including one with
    /// no apt at all, and a rule that needs a manager query would make the
    /// same manifest load on one machine and be refused on another.
    fn refuseAptNonNames(self: *Distro, arena: std.mem.Allocator, rows: []const Row) anyerror!void {
        const known = try self.universeNames(arena, &apt_names_argv, "apt-cache --generate pkgnames");

        const native = try self.aptNativeArch(arena);
        var refused = false;
        for (rows) |row| {
            const bare = backend_mod.bareName(row.name);
            if (!known.contains(bare)) {
                refused = true;
                self.say(
                    "mox: apt: row \"{s}\" names no apt package; apt-get would read it as a regular expression and install every package it matched, so nothing was installed\n",
                    .{row.name},
                );
                continue;
            }
            // apt-mark reports a package of the machine's own architecture
            // without a qualifier, so a row that spells one installs and then
            // reads as missing on every status after.
            const arch = backend_mod.archOf(row.name) orelse continue;
            if (nativeAlias(arch)) {
                refused = true;
                self.say(
                    "mox: apt: row \"{s}\" carries the qualifier \"{s}\", which apt resolves to this machine's own architecture and apt-mark then reports bare, so the row could never read as installed; declare \"{s}\" instead\n",
                    .{ row.name, arch, bare },
                );
                continue;
            }
            if (!std.mem.eql(u8, arch, native)) continue;
            refused = true;
            self.say(
                "mox: apt: row \"{s}\" qualifies this machine's own architecture, which apt-mark reports bare, so the row could never read as installed; declare \"{s}\" instead\n",
                .{ row.name, bare },
            );
        }
        if (refused) return Error.DistroNameNotAPackage;
    }

    /// Whether `arch` is one of apt's own names for the native package rather
    /// than an architecture. Verified against apt 3.0.3: `pkg:native`,
    /// `pkg:all` and `pkg:any` each install the native package, which
    /// `apt-mark showmanual` reports bare -- the same harm as spelling the
    /// machine's architecture, and invisible to a comparison against
    /// `dpkg --print-architecture`.
    fn nativeAlias(arch: []const u8) bool {
        for ([_][]const u8{ "native", "all", "any" }) |alias| {
            if (std.mem.eql(u8, arch, alias)) return true;
        }
        return false;
    }

    /// The name set a whole-universe listing answers with.
    ///
    /// Two of its failures are not "this row names no package", and saying so
    /// would blame the manifest for the machine. An empty listing is a
    /// machine with no repositories configured, where every row would be
    /// refused for a reason none of them has; an answer past the cap on a
    /// captured call is a listing mox could not read at all. Both leave every
    /// row unjudged, so both stop the install rather than refusing rows.
    fn universeNames(
        self: *Distro,
        arena: std.mem.Allocator,
        argv: []const []const u8,
        listing: []const u8,
    ) anyerror!std.StringHashMap(void) {
        const res = self.runner.run(arena, argv) catch |e| switch (e) {
            error.StreamTooLong => {
                self.say(
                    "mox: {s}: `{s}` answered with more than the {d} MiB mox reads from one query, so no row could be checked against it and nothing was installed\n",
                    .{ self.manager.name(), listing, exec.max_query_bytes / (1024 * 1024) },
                );
                return Error.DistroQueryFailed;
            },
            else => return e,
        };
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;

        var known = std.StringHashMap(void).init(arena);
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            try known.put(line, {});
        }
        if (known.count() == 0) {
            self.say(
                "mox: {s}: `{s}` lists no packages at all, which is a machine with no repositories configured rather than a row that names none, so no row could be checked and nothing was installed\n",
                .{ self.manager.name(), listing },
            );
            return Error.DistroQueryFailed;
        }
        return known;
    }

    /// The architecture dpkg calls native here. Every other one is a
    /// multiarch qualifier apt keeps in the name it reports back.
    fn aptNativeArch(self: *Distro, arena: std.mem.Allocator) anyerror![]const u8 {
        const res = try self.runner.run(arena, &.{ "dpkg", "--print-architecture" });
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;
        return std.mem.trim(u8, res.stdout, " \t\r\n");
    }

    /// Refuse a batch carrying a name dnf has no package for.
    ///
    /// An rpm virtual provide is spelled exactly like a package name, so it
    /// passes every shape rule there is: `zlib-devel` is not a package in
    /// Fedora 44, only a capability `zlib-ng-compat-devel` provides. dnf
    /// installs the provider, rpm reports the provider's name, and the row is
    /// missing on every status and reinstalled on every apply.
    ///
    /// Refused rather than installed-then-reported, because installing the
    /// provider puts a package on the machine that no row declares -- the
    /// same harm as apt's regex fallback -- and leaves the user to work out
    /// what to write. The name to write is in the message instead.
    fn refuseDnfNonPackages(self: *Distro, arena: std.mem.Allocator, rows: []const Row) anyerror!void {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &dnf_names_argv);
        for (rows) |row| try argv.append(arena, row.name);
        const known = try self.dnfNameSet(arena, argv.items);

        var refused = false;
        for (rows) |row| {
            if (known.contains(row.name)) continue;
            refused = true;
            const providers = try self.dnfProvidersOf(arena, row.name);
            if (providers.len == 0) {
                self.say(
                    "mox: dnf: row \"{s}\" names no dnf package in this machine's repositories\n",
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
                "mox: dnf: row \"{s}\" names no dnf package; it is a capability provided by {s}, and rpm reports only the package name, so declare that instead\n",
                .{ row.name, list.written() },
            );
        }
        if (refused) return Error.DistroNameNotAPackage;
    }

    /// Which of the operands name a real package. `-q` and the trailing
    /// newline for the reasons `queryArgv` gives; neither dnf4 nor dnf5 fails
    /// on an operand that matches nothing, so a non-zero exit is a query that
    /// could not run at all. No `--` before the operands, for the reason the
    /// install argv gives.
    const dnf_names_argv = [_][]const u8{ "dnf", "-q", "repoquery", "--qf", "%{name}\n" };

    fn dnfNameSet(self: *Distro, arena: std.mem.Allocator, argv: []const []const u8) anyerror!std.StringHashMap(void) {
        const res = try self.runner.run(arena, argv);
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;

        var set = std.StringHashMap(void).init(arena);
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            try set.put(line, {});
        }
        return set;
    }

    /// The packages that provide `name`, never `name` itself.
    fn dnfProvidersOf(self: *Distro, arena: std.mem.Allocator, name: []const u8) anyerror![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &dnf_names_argv);
        try argv.appendSlice(arena, &.{ "--whatprovides", name });
        const set = try self.dnfNameSet(arena, argv.items);

        var out: std.ArrayList([]const u8) = .empty;
        var it = set.keyIterator();
        while (it.next()) |k| {
            if (std.mem.eql(u8, k.*, name)) continue;
            try out.append(arena, k.*);
        }
        std.mem.sort([]const u8, out.items, {}, lessThanString);
        return out.toOwnedSlice(arena);
    }

    /// A hash map's order is not a message's, and a message that reorders
    /// itself between runs cannot be asserted on.
    fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }

    /// Every package pacman's repositories carry, one per line, and the
    /// members of one group. Verified against pacman 7.1.0: `-Slq` lists
    /// package names alone and no group name among them (15263 names,
    /// 215 KiB on a current Arch), and `-Sg <name>` prints `<group> <member>`
    /// per member and exits 1 on a name that is not a group.
    const pacman_names_argv = [_][]const u8{ "pacman", "-Slq" };

    /// Refuse a batch carrying a name pacman would not install under that
    /// name.
    ///
    /// A group is spelled exactly like a package and passes every shape rule
    /// there is. `pacman -S xfce4` installs all 14 of its members -- `gnome`
    /// has 58, `plasma` 70 -- and `pacman -Qeq`, the adapter's own query,
    /// reports the members and never the group: the row is MISSING on every
    /// status while the machine carries packages no manifest declares, and
    /// every apply installs the group again.
    ///
    /// The package universe is asked first because a name that is both is
    /// pacman's package: `pacman -S kdevelop` resolves the package kdevelop
    /// and not the group's kdevelop-php and kdevelop-python. `base` and
    /// `base-devel` are packages in their own right now, so they pass here
    /// while `pacman -Sg base-devel` says it is no group.
    fn refusePacmanNonPackages(self: *Distro, arena: std.mem.Allocator, rows: []const Row, elevate: bool) anyerror!void {
        // Both queries read the sync database, and a container or a fresh
        // machine has never downloaded one: unsynced, pacman answers that
        // every name is unknown and every row would be refused. The install's
        // own `-Syu` syncs again, which downloads nothing once current.
        var sync: std.ArrayList([]const u8) = .empty;
        if (elevate) try sync.append(arena, "sudo");
        try sync.appendSlice(arena, &.{ "pacman", "-Sy", "--noconfirm" });
        const up = try self.runner.stream(arena, sync.items);
        try exec.checkTimedOut(up);
        if (!up.ok) return Error.DistroInstallFailed;

        const known = try self.universeNames(arena, &pacman_names_argv, "pacman -Slq");

        var refused = false;
        for (rows) |row| {
            if (known.contains(row.name)) continue;
            refused = true;
            const members = try self.pacmanGroupMembers(arena, row.name);
            if (members.len == 0) {
                self.say(
                    "mox: pacman: row \"{s}\" names no pacman package in this machine's repositories\n",
                    .{row.name},
                );
                continue;
            }
            var list: std.Io.Writer.Allocating = .init(arena);
            for (members, 0..) |m, i| {
                if (i > 0) try list.writer.writeAll(", ");
                try list.writer.print("\"{s}\"", .{m});
            }
            self.say(
                "mox: pacman: row \"{s}\" names no pacman package; it is a group of {d} packages ({s}), and pacman reports each of them under its own name, so declare the ones you want instead\n",
                .{ row.name, members.len, list.written() },
            );
        }
        if (refused) return Error.DistroNameNotAPackage;
    }

    /// The members of the group `name`, or nothing when `name` is no group.
    /// Sorted, because a message that reorders itself between runs cannot be
    /// asserted on and pacman's own order is its database's.
    fn pacmanGroupMembers(self: *Distro, arena: std.mem.Allocator, name: []const u8) anyerror![]const []const u8 {
        const res = try self.runner.run(arena, &.{ "pacman", "-Sg", name });
        try exec.checkTimedOut(res);
        if (!res.ok) return &.{};

        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const member = std.mem.trim(u8, line[space + 1 ..], " \t");
            if (member.len == 0) continue;
            try out.append(arena, member);
        }
        std.mem.sort([]const u8, out.items, {}, lessThanString);
        return out.toOwnedSlice(arena);
    }

    /// `-y` alone answers apt's own questions; debconf asks its own through
    /// a frontend, and only this setting keeps it from stopping the install.
    /// Set through `env` rather than mox's environment so it holds after
    /// `sudo` resets the environment.
    const apt_env = [_][]const u8{ "env", "DEBIAN_FRONTEND=noninteractive" };

    /// Whether an install needs `sudo`. Root already has the privilege, and
    /// a minimal image that runs as root often ships no `sudo` binary.
    fn elevates(self: *Distro) bool {
        if (self.force_elevate) |f| return f;
        return !exec.isRoot();
    }

    fn declareImpl(_: *anyopaque, _: std.mem.Allocator, id: []const u8) anyerror!Backend.Declaration {
        return .{ .name = id };
    }
};

const testing = std.testing;

fn rowOf(name: []const u8, fields: []const manifest_mod.Pair) Row {
    return .{
        .name = name,
        .backend = "apt",
        .when = null,
        .fields = fields,
        .origin = "/tmp/x.toml",
        .label = "data/packages/debian.toml",
        .index = 0,
    };
}

test "installedExplicit: manual packages come back one per line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showmanual", .stdout = "bat\nfd-find\n\nripgrep\n" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = true };

    const got = try d.backend().installedExplicit(a);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("bat", got[0]);
    try testing.expectEqualStrings("ripgrep", got[2]);
}

test "installedExplicit: a failed query is an error, never an empty set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qeq", .code = 1 },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true };
    try testing.expectError(Error.DistroQueryFailed, d.backend().installedExplicit(a));
}

test "dnf: the query asks for newline-separated bare names" {
    // Verified against dnf5 5.4.3: the default format is full NEVRA, and a
    // format string without the newline concatenates every name into one.
    try testing.expectEqualStrings("%{name}\n", Manager.dnf.queryArgv()[5]);
}

test "dnf: the query is quiet, so dnf4's metadata notice cannot read as a package" {
    // Verified against dnf 4.14 (Rocky 9): without `-q` the first stdout
    // line is "Last metadata expiration check: ...", which the line split
    // would report as an installed package.
    try testing.expectEqualStrings("-q", Manager.dnf.queryArgv()[1]);
}

test "install: root installs without sudo, which a minimal image lacks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "dnf install -y bat" },
    } };
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false };

    // The Fake errors on anything unscripted, so a stray `sudo` fails here.
    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(fake.called("dnf install -y bat"));
}

test "install: apt as root refreshes without sudo too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "apt-cache --generate pkgnames", .stdout = "bat\nnano\n" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get update"));
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat"));
}

test "install: apt refreshes the index, then installs the whole set at once, debconf silenced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The frontend setting rides after sudo, which would otherwise strip it
    // from the environment along with everything else.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "apt-cache --generate pkgnames", .stdout = "bat\nfd-find\n" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat fd-find" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("fd-find", &.{}) });
    try testing.expectEqualStrings("sudo env DEBIAN_FRONTEND=noninteractive apt-get update", fake.calls.items[0]);
    try testing.expectEqualStrings("sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat fd-find", fake.calls.items[3]);
}

test "install: dnf takes one non-interactive command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n bat ripgrep", .stdout = "bat\nripgrep\n" },
        .{ .argv = "sudo dnf install -y bat ripgrep" },
    } };
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = true };

    // The Fake errors on anything unscripted, so a stray refresh fails here.
    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("ripgrep", &.{}) });
    try testing.expect(fake.called("sudo dnf install -y bat ripgrep"));
}

test "install: pacman syncs and installs only what is needed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo pacman -Sy --noconfirm" },
        .{ .argv = "pacman -Slq", .stdout = "bat\nripgrep\n" },
        .{ .argv = "sudo pacman -Syu --needed --noconfirm -- bat" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(fake.called("sudo pacman -Syu --needed --noconfirm -- bat"));
}

test "install: a failed install is an error, not a silent skip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "sudo dnf install -y bat", .code = 1 },
    } };
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = true };
    try testing.expectError(Error.DistroInstallFailed, d.backend().install(a, &.{rowOf("bat", &.{})}));
}

test "install: nothing to install runs no command at all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{});
    try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "validate: a key meant for another manager is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = a;

    var fake: exec.Fake = .{ .arena = undefined, .entries = &.{} };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = true };

    const row = rowOf("bat", &.{.{ .key = "kind", .value = .{ .string = "cask" } }});
    var diag: Diag = .{};
    try testing.expectError(Error.UnknownDistroKey, d.backend().validate(row, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.capture().?, "apt accepts no key \"kind\"") != null);
}

test "available: absent means not usable, any other failure propagates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var missing: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "dnf --version", .fail = error.FileNotFound }},
    };
    var d1: Distro = .{ .manager = .dnf, .runner = missing.runner() };
    try testing.expect((try d1.backend().available(a)) == .absent);

    var denied: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "dnf --version", .fail = error.AccessDenied }},
    };
    var d2: Distro = .{ .manager = .dnf, .runner = denied.runner() };
    try testing.expectError(error.AccessDenied, d2.backend().available(a));

    var present: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "apt-get --version", .stdout = "apt 2.6\n" }},
    };
    var d3: Distro = .{ .manager = .apt, .runner = present.runner() };
    try testing.expect((try d3.backend().available(a)) == .present);

    // There, but its own version query fails: broken, naming the executable.
    var broken: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "apt-get --version", .code = 100 }},
    };
    var d4: Distro = .{ .manager = .apt, .runner = broken.runner() };
    const got = try d4.backend().available(a);
    try testing.expectEqual(@as(u8, 100), got.broken.code);
    try testing.expectEqualStrings("apt-get --version", got.broken.probe);
}

test "declare: an observed name round-trips to a bare row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true };
    const be = d.backend();

    const decl = try be.declare(a, "ripgrep");
    try testing.expectEqualStrings("ripgrep", decl.name);
    try testing.expectEqual(@as(usize, 0), decl.fields.len);
    try testing.expectEqualStrings("ripgrep", try be.idOf(a, rowOf(decl.name, decl.fields)));
}

test "validate: a name the manager would read as an operation is refused" {
    var fake: exec.Fake = .{ .arena = undefined, .entries = &.{} };

    // `apt-get install -y vim nano-` removes nano. Proved against apt 3.0.3
    // in a debian container; the row is refused before any argv is built.
    var apt: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = true };
    var d: Diag = .{};
    try testing.expectError(Error.DistroSelectorRow, apt.backend().validate(rowOf("nano-", &.{}), &d));
    try testing.expectEqualStrings(
        "data/packages/debian.toml: row \"nano-\": apt rows name a package: a name does not end with \"-\", which an install reads as a request to remove the package",
        d.capture().?,
    );

    // Every manager here, since a manifest row is not the manager's to trust.
    for ([_]Manager{ .apt, .dnf, .pacman }) |m| {
        var dd: Distro = .{ .manager = m, .runner = fake.runner(), .force_elevate = true };
        for ([_][]const u8{ "nano-", "!vim", "-vim", "+pkg", "@group", ".foo", "/usr/bin/x" }) |name| {
            var diag: Diag = .{};
            try testing.expectError(Error.DistroSelectorRow, dd.backend().validate(rowOf(name, &.{}), &diag));
            try testing.expect(std.mem.indexOf(u8, diag.capture().?, "rows name a package: a name") != null);
        }
    }
}

test "validate: a name that resolves to a package of another name is refused" {
    var fake: exec.Fake = .{ .arena = undefined, .entries = &.{} };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = true };

    var diag: Diag = .{};
    try testing.expectError(Error.DistroSelectorRow, d.backend().validate(rowOf("pkgconfig(libcrypto)", &.{}), &diag));
    try testing.expectEqualStrings(
        "data/packages/debian.toml: row \"pkgconfig(libcrypto)\": apt rows name a package: a name holds only letters, digits and \".\", \"_\", \"+\" or \"-\", optionally followed by \":\" and an architecture",
        diag.capture().?,
    );

    // apt's own qualified spellings resolve the same package under a name the
    // query never reports, so the row would be MISSING on every status.
    for ([_][]const u8{ "pkg=1.2", "repo/pkg", "bat,ripgrep" }) |name| {
        var dg: Diag = .{};
        try testing.expectError(Error.DistroSelectorRow, d.backend().validate(rowOf(name, &.{}), &dg));
    }
}

test "validate: a multiarch qualifier is apt's alone" {
    var fake: exec.Fake = .{ .arena = undefined, .entries = &.{} };

    // `apt-mark showmanual` reports a foreign-architecture package as
    // `pkg:arch`, so the row apt needs is the row apt's query answers with.
    var apt: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = true };
    try apt.backend().validate(rowOf("libc6:armhf", &.{}), null);
    try apt.backend().validate(rowOf("g++:i386", &.{}), null);

    // A qualifier apt would not read as an architecture is still refused:
    // zypper's selectors are spelled the same way.
    var dg: Diag = .{};
    try testing.expectError(Error.DistroSelectorRow, apt.backend().validate(rowOf("pattern:devel_basis", &.{}), &dg));
    try testing.expectEqualStrings(
        "data/packages/debian.toml: row \"pattern:devel_basis\": apt rows name a package: a name carries one \":\" at most, and an architecture holds only letters, digits and \"-\"",
        dg.capture().?,
    );

    // rpm and pacman have no such qualifier and never report one back, so a
    // colon there is a name that could not converge.
    for ([_]Manager{ .dnf, .pacman }) |m| {
        var other: Distro = .{ .manager = m, .runner = fake.runner(), .force_elevate = true };
        var d2: Diag = .{};
        try testing.expectError(Error.DistroSelectorRow, other.backend().validate(rowOf("libc6:armhf", &.{}), &d2));
        try testing.expect(std.mem.indexOf(u8, d2.capture().?, "letters, digits and \".\", \"_\", \"+\" or \"-\"") != null);
        try testing.expect(std.mem.indexOf(u8, d2.capture().?, "architecture") == null);
    }
}

test "validate: dnf NEVRA and an arch suffix are refused, which rpm reads back bare" {
    var fake: exec.Fake = .{ .arena = undefined, .entries = &.{} };
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = true };

    var diag: Diag = .{};
    try testing.expectError(Error.DistroSelectorRow, d.backend().validate(rowOf("foo-1.2-3.x86_64", &.{}), &diag));
    try testing.expectEqualStrings(
        "data/packages/debian.toml: row \"foo-1.2-3.x86_64\": dnf rows name a package, with no architecture",
        diag.capture().?,
    );

    var bare: Diag = .{};
    try testing.expectError(Error.DistroSelectorRow, d.backend().validate(rowOf("bat.noarch", &.{}), &bare));

    // apt and pacman have no such spelling; a dot-and-arch name there is a
    // name like any other, and refusing it would refuse a real package.
    var apt: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = true };
    try apt.backend().validate(rowOf("bat.noarch", &.{}), null);
}

test "validate: the names real distributions ship are taken" {
    var fake: exec.Fake = .{ .arena = undefined, .entries = &.{} };
    const names = [_][]const u8{ "g++", "lib32-glibc", "python3.11", "gcc-c++", "zlib1g-dev", "perl-Foo-Bar", "libstdc++6" };
    for ([_]Manager{ .apt, .dnf, .pacman }) |m| {
        var d: Distro = .{ .manager = m, .runner = fake.runner(), .force_elevate = true };
        for (names) |name| try d.backend().validate(rowOf(name, &.{}), null);
    }
}

test "install: the install argv is exactly this, per manager" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The whole point of this table is the byte-for-byte argv, which is what
    // the manager parses. apt and pacman take a `--` before the operands;
    // dnf must carry none, because dnf5 5.2.x (Fedora 41, 42, 43) exits 2 on
    // `Unknown argument "--"` and installs nothing at all.
    for ([_]struct { m: Manager, argv: []const u8 }{
        .{ .m = .apt, .argv = "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat" },
        .{ .m = .dnf, .argv = "sudo dnf install -y bat" },
        .{ .m = .pacman, .argv = "sudo pacman -Syu --needed --noconfirm -- bat" },
    }) |c| {
        var fake: exec.Fake = .{ .arena = a, .entries = &.{
            .{ .argv = "sudo env DEBIAN_FRONTEND=noninteractive apt-get update" },
            .{ .argv = "apt-cache --generate pkgnames", .stdout = "bat\n" },
            .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
            .{ .argv = "dnf -q repoquery --qf %{name}\n bat", .stdout = "bat\n" },
            .{ .argv = "sudo pacman -Sy --noconfirm" },
            .{ .argv = "pacman -Slq", .stdout = "bat\n" },
            .{ .argv = c.argv },
        } };
        var d: Distro = .{ .manager = c.m, .runner = fake.runner(), .force_elevate = true };
        try d.backend().install(a, &.{rowOf("bat", &.{})});
        try testing.expectEqualStrings(c.argv, fake.calls.items[fake.calls.items.len - 1]);
    }
}

test "install: no argv dnf parses carries a --, which dnf5 5.2.x refuses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured: fedora:41 (dnf5 5.2.17) and fedora:42 and :43 (5.2.18) exit 2
    // on `--` for both `install` and `repoquery`; fedora:44 (5.4.3) and Rocky
    // 9 (dnf4 4.14) accept it. A `--` here is therefore every dnf row on
    // three current Fedora releases failing, so no argv may carry one.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n bat zlib-devel", .stdout = "bat\n" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n --whatprovides zlib-devel", .stdout = "zlib-ng-compat-devel\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(
        Error.DistroNameNotAPackage,
        d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("zlib-devel", &.{}) }),
    );
    for (fake.calls.items) |c| {
        try testing.expect(!std.mem.startsWith(u8, c, "dnf --"));
        try testing.expect(std.mem.indexOf(u8, c, " -- ") == null);
        try testing.expect(!std.mem.endsWith(u8, c, " --"));
    }

    // The query that drives `mox status` is built the same way.
    for (Manager.dnf.queryArgv()) |arg| try testing.expect(!std.mem.eql(u8, arg, "--"));
}

test "install: apt refuses a name it would resolve as a regular expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved against apt 3.0.3 on Debian trixie: `apt-get -s install -y --
    // bsdextrautil.` installs bsdextrautils, because apt falls back to
    // matching an operand as an unanchored regex and `.` is a metacharacter
    // the name class must keep for `python3.11`.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "apt-cache --generate pkgnames", .stdout = "bat\nbsdextrautils\nnano\n" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroNameNotAPackage, d.backend().install(a, &.{rowOf("bsdextrautil.", &.{})}));
    try testing.expectEqualStrings(
        "mox: apt: row \"bsdextrautil.\" names no apt package; apt-get would read it as a regular expression and install every package it matched, so nothing was installed\n",
        w.written(),
    );
    // The batch never reached apt-get, so nothing undeclared was installed.
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "apt-get install") == null);
}

test "install: apt refuses a batch for one bad name, naming every one of them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "apt-cache --generate pkgnames", .stdout = "bat\n" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroNameNotAPackage, d.backend().install(a, &.{
        rowOf("bat", &.{}),
        rowOf("ruby.dev", &.{}),
        rowOf("libz.dev", &.{}),
    }));
    try testing.expect(std.mem.indexOf(u8, w.written(), "row \"ruby.dev\" names no apt package") != null);
    try testing.expect(std.mem.indexOf(u8, w.written(), "row \"libz.dev\" names no apt package") != null);
    try testing.expect(std.mem.indexOf(u8, w.written(), "\"bat\"") == null);
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "apt-get install") == null);
}

test "install: apt takes a multiarch name, resolving the half apt lists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `apt-cache pkgnames` lists `libc6`, never `libc6:armhf`, while
    // `apt-mark showmanual` reports the foreign-architecture package
    // qualified -- so the row apt's query answers with must install.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "apt-cache --generate pkgnames", .stdout = "libc6\nbat\n" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- libc6:armhf" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{rowOf("libc6:armhf", &.{})});
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- libc6:armhf"));
}

test "install: apt refuses a qualifier naming this machine's own architecture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved on Debian trixie: `apt-get install bsdextrautils:arm64` on an
    // arm64 machine makes `apt-mark showmanual` report `bsdextrautils`, so
    // the qualified row would read as missing after every install.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "apt-cache --generate pkgnames", .stdout = "bsdextrautils\n" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroNameNotAPackage, d.backend().install(a, &.{rowOf("bsdextrautils:arm64", &.{})}));
    try testing.expectEqualStrings(
        "mox: apt: row \"bsdextrautils:arm64\" qualifies this machine's own architecture, which apt-mark reports bare, so the row could never read as installed; declare \"bsdextrautils\" instead\n",
        w.written(),
    );
}

test "install: a name query that cannot run stops the install, never waves it through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var apt: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "apt-cache --generate pkgnames", .code = 100 },
    } };
    var d: Distro = .{ .manager = .apt, .runner = apt.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroQueryFailed, d.backend().install(a, &.{rowOf("bat", &.{})}));

    var dnf: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n bat", .code = 1 },
    } };
    var d2: Distro = .{ .manager = .dnf, .runner = dnf.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroQueryFailed, d2.backend().install(a, &.{rowOf("bat", &.{})}));
}

test "install: dnf refuses a virtual provide, naming the package that provides it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved against dnf5 5.4.3 on Fedora 44: `zlib-devel` is not a package
    // there, only a capability `zlib-ng-compat-devel` provides. rpm reports
    // the provider's name, so the row is missing on every status after.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n zlib-devel", .stdout = "" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n --whatprovides zlib-devel", .stdout = "zlib-ng-compat-devel\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroNameNotAPackage, d.backend().install(a, &.{rowOf("zlib-devel", &.{})}));
    try testing.expectEqualStrings(
        "mox: dnf: row \"zlib-devel\" names no dnf package; it is a capability provided by \"zlib-ng-compat-devel\", and rpm reports only the package name, so declare that instead\n",
        w.written(),
    );
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "dnf install") == null);
}

test "install: dnf names every provider of a capability several packages carry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n java-devel", .stdout = "" },
        .{
            .argv = "dnf -q repoquery --qf %{name}\n --whatprovides java-devel",
            .stdout = "java-21-openjdk-devel\njava-17-openjdk-devel\njava-21-openjdk-devel\n",
        },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroNameNotAPackage, d.backend().install(a, &.{rowOf("java-devel", &.{})}));
    try testing.expectEqualStrings(
        "mox: dnf: row \"java-devel\" names no dnf package; it is a capability provided by \"java-17-openjdk-devel\", \"java-21-openjdk-devel\", and rpm reports only the package name, so declare that instead\n",
        w.written(),
    );
}

test "install: dnf says so plainly when nothing provides the name either" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n ripgrepp", .stdout = "" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n --whatprovides ripgrepp", .stdout = "" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroNameNotAPackage, d.backend().install(a, &.{rowOf("ripgrepp", &.{})}));
    try testing.expectEqualStrings(
        "mox: dnf: row \"ripgrepp\" names no dnf package in this machine's repositories\n",
        w.written(),
    );
}

test "install: pacman refuses a group, naming the packages to declare instead" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved against pacman 7.1.0 on archlinux:latest: `pacman -S fprint`
    // installs libfprint and fprintd, and `pacman -Qeq` reports those two and
    // never fprint, so the row is MISSING on every status after.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Sy --noconfirm" },
        .{ .argv = "pacman -Slq", .stdout = "bat\nfprintd\nlibfprint\n" },
        .{ .argv = "pacman -Sg fprint", .stdout = "fprint libfprint\nfprint fprintd\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroNameNotAPackage, d.backend().install(a, &.{rowOf("fprint", &.{})}));
    try testing.expectEqualStrings(
        "mox: pacman: row \"fprint\" names no pacman package; it is a group of 2 packages (\"fprintd\", \"libfprint\"), and pacman reports each of them under its own name, so declare the ones you want instead\n",
        w.written(),
    );
    // The batch never reached pacman, so no member of the group landed.
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "-Syu") == null);
}

test "install: pacman refuses a name no repository carries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Sy --noconfirm" },
        .{ .argv = "pacman -Slq", .stdout = "bat\nripgrep\n" },
        .{ .argv = "pacman -Sg ripgrepp", .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroNameNotAPackage, d.backend().install(a, &.{rowOf("ripgrepp", &.{})}));
    try testing.expectEqualStrings(
        "mox: pacman: row \"ripgrepp\" names no pacman package in this machine's repositories\n",
        w.written(),
    );
}

test "install: pacman takes a name that is a package and a group both" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `kdevelop` and `rhvoice` are each a package and a group in current
    // Arch. Proved against pacman 7.1.0: `pacman -S kdevelop` resolves the
    // package, never the group's kdevelop-php and kdevelop-python, so the
    // package universe is what decides. `base` and `base-devel` are plain
    // packages and go the same way.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Sy --noconfirm" },
        .{ .argv = "pacman -Slq", .stdout = "base\nbase-devel\nkdevelop\nkdevelop-php\n" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- kdevelop base-devel base" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{ rowOf("kdevelop", &.{}), rowOf("base-devel", &.{}), rowOf("base", &.{}) });
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- kdevelop base-devel base"));
    // Asked about no name it already found, so no group query ran at all.
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "-Sg") == null);
}

test "install: pacman syncs before it reads the database it judges rows against" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An unsynced machine has no database at all, where every name reads as
    // unknown and every row would be refused for a reason none of them has.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo pacman -Sy --noconfirm" },
        .{ .argv = "pacman -Slq", .stdout = "bat\n" },
        .{ .argv = "sudo pacman -Syu --needed --noconfirm -- bat" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqualStrings("sudo pacman -Sy --noconfirm", fake.calls.items[0]);
    try testing.expectEqualStrings("pacman -Slq", fake.calls.items[1]);

    // A sync that fails stops the install: the check cannot run, and the
    // install's own `-Syu` would fail the same way.
    var down: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Sy --noconfirm", .code = 1 },
    } };
    var d2: Distro = .{ .manager = .pacman, .runner = down.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroInstallFailed, d2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!d2.backend().installSpawned());
}

test "install: apt refuses the qualifiers apt reads as the native architecture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved on apt 3.0.3 / Debian trixie: `bsdextrautils:native`,
    // `bsdmainutils:all` and `sl:any` each install, and `apt-mark showmanual`
    // then reports the bare name -- so a comparison against
    // `dpkg --print-architecture` alone lets all three through.
    for ([_]struct { name: []const u8, qualifier: []const u8, bare: []const u8 }{
        .{ .name = "bsdextrautils:native", .qualifier = "native", .bare = "bsdextrautils" },
        .{ .name = "bsdmainutils:all", .qualifier = "all", .bare = "bsdmainutils" },
        .{ .name = "sl:any", .qualifier = "any", .bare = "sl" },
    }) |c| {
        var fake: exec.Fake = .{ .arena = a, .entries = &.{
            .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
            .{ .argv = "apt-cache --generate pkgnames", .stdout = "bsdextrautils\nbsdmainutils\nsl\n" },
            .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        } };
        var w: std.Io.Writer.Allocating = .init(a);
        var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

        try testing.expectError(Error.DistroNameNotAPackage, d.backend().install(a, &.{rowOf(c.name, &.{})}));
        const want = try std.fmt.allocPrint(
            a,
            "mox: apt: row \"{s}\" carries the qualifier \"{s}\", which apt resolves to this machine's own architecture and apt-mark then reports bare, so the row could never read as installed; declare \"{s}\" instead\n",
            .{ c.name, c.qualifier, c.bare },
        );
        try testing.expectEqualStrings(want, w.written());
        for (fake.calls.items) |call| try testing.expect(std.mem.indexOf(u8, call, "apt-get install") == null);
    }

    // A real foreign architecture still installs: it is the one name apt
    // reports with a colon in it.
    var ok: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "apt-cache --generate pkgnames", .stdout = "libc6\n" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- libc6:armhf" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = ok.runner(), .force_elevate = false };
    try d.backend().install(a, &.{rowOf("libc6:armhf", &.{})});
}

test "install: a listing that answers nothing stops the install, saying which" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A machine with no configured sources lists no package at all. Refusing
    // every row for naming no package would blame the manifest for the
    // machine, and name a cause none of the rows has.
    var apt: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "apt-cache --generate pkgnames", .stdout = "" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = apt.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroQueryFailed, d.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expectEqualStrings(
        "mox: apt: `apt-cache --generate pkgnames` lists no packages at all, which is a machine with no repositories configured rather than a row that names none, so no row could be checked and nothing was installed\n",
        w.written(),
    );
    try testing.expect(!d.backend().installSpawned());

    var pac: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Sy --noconfirm" },
        .{ .argv = "pacman -Slq", .stdout = "" },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = pac.runner(), .force_elevate = false, .err = &w2.writer };

    try testing.expectError(Error.DistroQueryFailed, d2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expectEqualStrings(
        "mox: pacman: `pacman -Slq` lists no packages at all, which is a machine with no repositories configured rather than a row that names none, so no row could be checked and nothing was installed\n",
        w2.written(),
    );
}

test "install: a listing past the cap stops the install, saying that is what happened" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // apt's own list is 1.8 MiB on Ubuntu 24.04, inside the cap but not by a
    // wide margin. Past it, mox has read no names at all, which is not a row
    // that names no package.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "apt-cache --generate pkgnames", .fail = error.StreamTooLong },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroQueryFailed, d.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expectEqualStrings(
        "mox: apt: `apt-cache --generate pkgnames` answered with more than the 8 MiB mox reads from one query, so no row could be checked against it and nothing was installed\n",
        w.written(),
    );
}

test "install: whether the manager ran is what says the rows may have landed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every way an install can fail before apt-get install exists: the index
    // refresh, the name listing, the architecture query, and a refused row.
    // None of them can have installed anything.
    var refresh: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update", .code = 100 },
    } };
    var d1: Distro = .{ .manager = .apt, .runner = refresh.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroInstallFailed, d1.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!d1.backend().installSpawned());

    var timeout: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "apt-cache --generate pkgnames", .timed_out = true },
    } };
    var d2: Distro = .{ .manager = .apt, .runner = timeout.runner(), .force_elevate = false };
    try testing.expectError(error.TimedOut, d2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!d2.backend().installSpawned());

    var arch: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "apt-cache --generate pkgnames", .stdout = "bat\n" },
        .{ .argv = "dpkg --print-architecture", .code = 2 },
    } };
    var d3: Distro = .{ .manager = .apt, .runner = arch.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroQueryFailed, d3.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!d3.backend().installSpawned());

    var refused: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n zlib-devel", .stdout = "" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n --whatprovides zlib-devel", .stdout = "zlib-ng-compat-devel\n" },
    } };
    var d4: Distro = .{ .manager = .dnf, .runner = refused.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroNameNotAPackage, d4.backend().install(a, &.{rowOf("zlib-devel", &.{})}));
    try testing.expect(!d4.backend().installSpawned());

    // A manager that ran and failed part-way through is the other answer: its
    // rows may be on the machine, and a re-read must assume they are.
    var ran: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "dnf install -y bat", .code = 1 },
    } };
    var d5: Distro = .{ .manager = .dnf, .runner = ran.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroInstallFailed, d5.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(d5.backend().installSpawned());

    // An adapter is asked afresh each time, never left saying what the last
    // batch did.
    var again: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n ripgrepp", .stdout = "" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n --whatprovides ripgrepp", .stdout = "" },
    } };
    d5.runner = again.runner();
    try testing.expectError(Error.DistroNameNotAPackage, d5.backend().install(a, &.{rowOf("ripgrepp", &.{})}));
    try testing.expect(!d5.backend().installSpawned());
}

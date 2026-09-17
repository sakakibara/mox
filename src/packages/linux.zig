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
    /// The index or database refresh an install resolves against failed, so
    /// no install ran. Its own error because it is not an install failure:
    /// reported as one, it says a manager was asked to install something when
    /// it never was.
    DistroRefreshFailed,
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

    /// What this manager's install asks the manager itself about a row, in
    /// the order it asks, for a dry run to name as what it did not check.
    fn installCheck(self: Manager) []const u8 {
        return switch (self) {
            .apt => "what apt has installed as a dependency, apt's own package list, what dpkg has installed, its holds and its pins",
            .dnf => "what dnf already has installed, and the packages and provisions its repositories carry",
            .pacman => "what pacman has installed as a dependency, and the packages, groups and provisions its repositories carry",
        };
    }

    /// What this manager calls a package the user asked for, in the words its
    /// own mark command reports back.
    fn explicitWord(self: Manager) []const u8 {
        return switch (self) {
            .apt => "manually installed",
            .dnf => "user installed",
            .pacman => "explicitly installed",
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
    /// How many of the last `install`'s rows the manager was never handed,
    /// which `installRefused` answers with.
    refused: usize = 0,
    /// How many of the last `install`'s rows were converged by marking a
    /// package the manager already had, which `installMarked` answers with.
    marked: usize = 0,
    /// How many of the last `install`'s rows named a package the manager
    /// already had and could not be marked, which `installUnmarked` answers
    /// with.
    unmarked: usize = 0,
    /// Whether this install's own check already ran a full `pacman -Syu`, so
    /// the install that follows does not refresh a second time.
    synced: bool = false,

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
        .installRefused = installRefusedImpl,
        .installMarked = installMarkedImpl,
        .installUnmarked = installUnmarkedImpl,
        .declare = declareImpl,
    };

    fn installSpawnedImpl(ctx: *anyopaque) bool {
        const self: *Distro = @ptrCast(@alignCast(ctx));
        return self.spawned;
    }

    fn installRefusedImpl(ctx: *anyopaque) usize {
        const self: *Distro = @ptrCast(@alignCast(ctx));
        return self.refused;
    }

    fn installMarkedImpl(ctx: *anyopaque) usize {
        const self: *Distro = @ptrCast(@alignCast(ctx));
        return self.marked;
    }

    fn installUnmarkedImpl(ctx: *anyopaque) usize {
        const self: *Distro = @ptrCast(@alignCast(ctx));
        return self.unmarked;
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
    ///
    /// A row the manager has no package for is refused and the rest of the
    /// batch installed. One row nobody can install must not keep every other
    /// package off the machine, and the refusal is the row's own failure
    /// rather than the batch's: `installRefused` reports how many, so the run
    /// counts them and exits non-zero.
    ///
    /// What the machine already has is asked before anything resolves. A
    /// row whose package the manager already has cannot converge through an
    /// install -- each of these three leaves its explicit-install record
    /// alone for a package it is not putting on the machine, so the row
    /// would read missing again on every status and every apply after -- and
    /// it needs no resolution either: resolution answers what an install
    /// would land, and no install is going to happen for it. Judging such a
    /// row by the repositories first refuses what the machine demonstrably
    /// holds (dnf, once no enabled repository carries the package), refuses
    /// it for a hold that stops an install it does not need (apt), or keeps
    /// a purely local mark behind a sync the machine cannot make (pacman).
    fn installImpl(ctx: *anyopaque, arena: std.mem.Allocator, rows: []const Row) anyerror!void {
        const self: *Distro = @ptrCast(@alignCast(ctx));
        self.spawned = false;
        self.refused = 0;
        self.marked = 0;
        self.unmarked = 0;
        self.synced = false;
        if (rows.len == 0) return;

        const elevate = self.elevates();

        const present = try self.installedAlready(arena, rows);
        var to_mark: std.ArrayList(Row) = .empty;
        var to_resolve: std.ArrayList(Row) = .empty;
        for (rows) |row| {
            if (present.contains(row.name)) {
                try to_mark.append(arena, row);
            } else {
                try to_resolve.append(arena, row);
            }
        }
        if (to_mark.items.len > 0) try self.markExplicit(arena, to_mark.items, elevate);
        if (to_resolve.items.len == 0) return;

        if (self.manager == .apt) {
            // An install resolves against the index, so a stale one turns a
            // present package into "not found".
            var up_argv: std.ArrayList([]const u8) = .empty;
            if (elevate) try up_argv.append(arena, "sudo");
            try up_argv.appendSlice(arena, &apt_env);
            try up_argv.appendSlice(arena, &.{ "apt-get", "update" });
            const up = try self.runner.stream(arena, up_argv.items);
            try exec.checkTimedOut(up);
            if (!up.ok) return Error.DistroRefreshFailed;
        }
        const to_install = switch (self.manager) {
            .apt => try self.refuseAptUninstallable(arena, try self.refuseAptNonNames(arena, to_resolve.items)),
            .dnf => try self.refuseDnfNonPackages(arena, to_resolve.items),
            .pacman => try self.refusePacmanNonPackages(arena, to_resolve.items, elevate),
        };
        self.refused = to_resolve.items.len - to_install.len;
        if (to_install.len == 0) return;

        var argv: std.ArrayList([]const u8) = .empty;
        if (elevate) try argv.append(arena, "sudo");
        if (self.manager == .apt) try argv.appendSlice(arena, &apt_env);
        // pacman's install refreshes as it goes, except when the check ahead
        // of it already ran that same full `-Syu`: repeating it there costs a
        // second whole-system upgrade for a database that is already current.
        const head: []const []const u8 = switch (self.manager) {
            .apt => &.{ "apt-get", "install", "-y" },
            .dnf => &.{ "dnf", "install", "-y" },
            .pacman => if (self.synced)
                &.{ "pacman", "-S", "--needed", "--noconfirm" }
            else
                &.{ "pacman", "-Syu", "--needed", "--noconfirm" },
        };
        try argv.appendSlice(arena, head);
        // `--` stops an operand being read as an option, and apt-get 3.0.3
        // and pacman 7.1.0 both take one. It is not the fix -- `validate`
        // refuses a name that is not a package name, and apt reads its remove
        // suffix after a `--` all the same -- but it bounds what a name
        // reaching the manager can do. dnf gets none, because the dnf5 range
        // in use does not agree about it: 5.2.x, which is every Fedora from
        // 41 to 43, fails an install or a repoquery carrying one with
        // `Unknown argument "--"` and exit 2, while 5.4.3 accepts it.
        // Nothing is lost there, because the name class refuses a leading
        // `-`, so no operand mox passes can be read as an option.
        if (self.manager != .dnf) try argv.append(arena, "--");
        for (to_install) |row| try argv.append(arena, row.name);

        self.spawned = true;
        const res = try self.runner.stream(arena, argv.items);
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroInstallFailed;
    }

    /// Which of `rows` the manager has on the machine already.
    ///
    /// Every row reaching here is absent from the manager's own
    /// explicit-install query, so a package the manager does have is one it
    /// holds under some other record -- a dependency of something else -- and
    /// that record is the whole of what the row is missing.
    ///
    /// apt and pacman are asked for their whole dependency set, which is one
    /// local read of a few hundred names; dnf is asked about the row names
    /// alone, because its query reaches for repository metadata and the rows
    /// are the only names any of this has a question about.
    fn installedAlready(self: *Distro, arena: std.mem.Allocator, rows: []const Row) anyerror!std.StringHashMap(void) {
        var set: std.StringHashMap(void) = .init(arena);
        var argv: std.ArrayList([]const u8) = .empty;
        switch (self.manager) {
            .apt => try argv.appendSlice(arena, &apt_auto_argv),
            .pacman => try argv.appendSlice(arena, &pacman_deps_argv),
            .dnf => {
                try argv.appendSlice(arena, &dnf_installed_argv);
                for (rows) |row| try argv.append(arena, row.name);
            },
        }
        const res = self.runner.run(arena, argv.items) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.sayUnlistable();
                return set;
            },
        };
        // `pacman -Qdq` exits 1 with nothing on stdout when NO package at all
        // is installed as a dependency, which is an answer and not a failure.
        // Measured on pacman 7.1.0: a local database it cannot read exits 255
        // with nothing, so that is told apart by the code; a local database
        // that is MISSING exits 1 with nothing too, and reads as the answer.
        const empty_answer = self.manager == .pacman and res.code == 1 and res.stdout.len == 0;
        if (res.timed_out or (!res.ok and !empty_answer)) {
            self.sayUnlistable();
            return set;
        }
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            try set.put(line, {});
        }
        return set;
    }

    /// A query that could not be answered leaves the rows to the install, as
    /// before this check existed; the rows that cannot converge that way are
    /// said so the run does not look clean.
    fn sayUnlistable(self: *Distro) void {
        self.say(
            "mox: {s}: what this machine already has installed could not be listed, so a row naming a package the manager has already may not converge this run\n",
            .{self.manager.name()},
        );
    }

    /// Record the user's own claim on each package the manager already has.
    /// A mark that does not take is that row's own failure, counted in
    /// `unmarked`, never the batch's: the rows beside it are untouched by it.
    ///
    /// Marking, not installing: the package was on the machine before this
    /// run and is untouched: what changes is the manager's record of who
    /// asked for it, which is the row's own claim. mox never uninstalls, and
    /// this direction only makes an autoremove keep more.
    ///
    /// Measured, each against a package the manager held as a dependency:
    ///
    /// - `pacman -S --needed` skips it ("up to date -- skipping"), and even a
    ///   full `pacman -S` reinstall leaves the reason `dependency`, so
    ///   `pacman -Qeq` goes on omitting it (pacman 7.1.0).
    /// - `dnf install` exits 0 saying the package is installed already and
    ///   changes no reason, so `dnf repoquery --userinstalled` goes on
    ///   omitting it (dnf 4.14.0, dnf5 5.2.18 and 5.4.3).
    /// - `apt-get install` sets it manual when it has no upgrade to do, but
    ///   apt 3.0.3 upgrading the package leaves it automatically installed
    ///   and `apt-mark showmanual` omits it until a later apply finds it
    ///   current (apt 2.6.1 sets it manual either way).
    ///
    /// No `--` before the name: each name here came back from the manager's
    /// own listing of what it has installed, so it is a package name rather
    /// than anything an option parser could read.
    fn markExplicit(self: *Distro, arena: std.mem.Allocator, rows: []const Row, elevate: bool) anyerror!void {
        const name = self.manager.name();
        const word = self.manager.explicitWord();
        const verb: []const []const u8 = switch (self.manager) {
            .apt => &.{ "apt-mark", "manual" },
            .pacman => &.{ "pacman", "-D", "--asexplicit" },
            .dnf => blk: {
                const five = self.dnfIsFive(arena) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        self.say(
                            "mox: dnf: which dnf this machine has could not be read, so no row could be marked {s} and each one stays missing\n",
                            .{word},
                        );
                        self.unmarked += rows.len;
                        return;
                    },
                };
                break :blk if (five)
                    &[_][]const u8{ "dnf", "mark", "user", "-y" }
                else
                    &[_][]const u8{ "dnf", "mark", "install" };
            },
        };

        for (rows) |row| {
            self.say(
                "mox: {s}: \"{s}\" is installed already as a dependency, so what the row is missing is {s}'s record of who asked for it; marking it {s}\n",
                .{ name, row.name, name, word },
            );
            var argv: std.ArrayList([]const u8) = .empty;
            if (elevate) try argv.append(arena, "sudo");
            try argv.appendSlice(arena, verb);
            try argv.append(arena, row.name);
            const res = try self.runner.stream(arena, argv.items);
            try exec.checkTimedOut(res);
            if (res.ok) {
                self.marked += 1;
                continue;
            }
            self.say(
                "mox: {s}: \"{s}\" could not be marked {s}, so the row stays missing\n",
                .{ name, row.name, word },
            );
            self.unmarked += 1;
        }
    }

    /// Whether this machine's dnf is dnf5, which spells the user reason
    /// `dnf mark user` where dnf4 spells it `dnf mark install`; each exits 2
    /// on the other's spelling. Measured: dnf 4.14.0 (Rocky 9) answers
    /// `4.14.0`, dnf5 5.2.18 (Fedora 42) and 5.4.3 (Fedora 44) answer
    /// `dnf5 version <version>`.
    ///
    /// dnf5 prompts for a mark and aborts unanswered, so it carries the same
    /// `-y` the install does; dnf4's mark asks nothing.
    fn dnfIsFive(self: *Distro, arena: std.mem.Allocator) anyerror!bool {
        const res = try self.runner.run(arena, &.{ "dnf", "--version" });
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;
        const line = std.mem.trim(u8, std.mem.sliceTo(res.stdout, '\n'), " \t\r");
        return std.mem.startsWith(u8, line, "dnf5");
    }

    /// The packages apt has installed as another package's dependency, one
    /// per line. It spells a foreign-architecture package `name:arch` and a
    /// native one bare, which is how `apt-mark showmanual` spells them and so
    /// how a row spells one too; measured on apt 2.6.1 and 3.0.3 with armhf
    /// added. A machine with none exits 0 printing nothing.
    const apt_auto_argv = [_][]const u8{ "apt-mark", "showauto" };

    /// The packages pacman has installed as another package's dependency.
    const pacman_deps_argv = [_][]const u8{ "pacman", "-Qdq" };

    /// Which of the operands rpm has installed, whatever reason it records
    /// for them. `-q` and the trailing newline for the reasons `queryArgv`
    /// gives; no `--` for the reason the install argv gives. An operand rpm
    /// has nothing for contributes no line and does not fail the query
    /// (measured on dnf 4.14.0, dnf5 5.2.18 and 5.4.3).
    const dnf_installed_argv = [_][]const u8{ "dnf", "-q", "repoquery", "--installed", "--qf", "%{name}\n" };

    /// Say `fmt` where a refused row can be read, if anywhere.
    fn say(self: *Distro, comptime fmt: []const u8, args: anytype) void {
        const w = self.err orelse return;
        w.print(fmt, args) catch {};
        w.flush() catch {};
    }

    /// The names a BARE row may resolve to, one per line: every package of
    /// the native architecture that a configured repository carries.
    ///
    /// `--generate pkgnames` is the query that matches an operand LITERALLY
    /// -- `apt-cache show` and `apt-cache policy` both take a regex -- and it
    /// lists the bare name alone, never a `:arch` form. Both options narrow
    /// what it lists, and each closes a hole the plain listing has. Verified
    /// against apt 2.6.1 (bookworm), 2.8.3 (Ubuntu 24.04) and 3.0.3 (trixie),
    /// each arm64 with armhf added:
    ///
    /// - `APT::Architectures=<native>` drops the names only a foreign index
    ///   carries. The plain listing prints 78 of trixie's 90 armhf-only names
    ///   BARE (120 of 133 on bookworm, 57 of 73 on Ubuntu), so a row spelling
    ///   one is kept, apt installs the foreign package, and `apt-mark
    ///   showmanual` reports it `name:armhf` -- missing and untracked for
    ///   ever. With the option the listing holds none of them.
    /// - `Dir::State::status=/dev/null` drops the dpkg status file, which is
    ///   not a repository: it prints a foreign package already installed
    ///   under its bare name (the same hole again), and it keeps the listing
    ///   non-empty -- 78 lines on trixie, 88 on bookworm -- on a machine with
    ///   no repositories at all, where the emptiness IS the signal.
    ///
    /// So this answers what the REPOSITORIES carry natively, and nothing
    /// about what is already on the machine. A package installed from a .deb
    /// is in no repository, so it is absent here and its row is judged
    /// against `aptInstalledArches` instead.
    ///
    /// About 1.2 MiB on Debian trixie and 1.8 MiB on Ubuntu 24.04, well
    /// inside a captured call's cap. A qualified name is asked about per row
    /// instead, because the listing holds bare names alone.
    fn aptNamesArgv(arena: std.mem.Allocator, native: []const u8) ![]const []const u8 {
        return arena.dupe([]const u8, &.{
            "apt-cache",
            "-o",
            try std.fmt.allocPrint(arena, "APT::Architectures={s}", .{native}),
            "-o",
            "Dir::State::status=/dev/null",
            "--generate",
            "pkgnames",
        });
    }

    /// Refuse the rows apt has no package for, and answer with the rest.
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
    ///
    /// The qualifier is judged before the package list, because a row apt
    /// resolves to the native package is wrong for a reason of its own and
    /// must be told the bare name to declare rather than the regex warning.
    ///
    /// A bare row is held to the NATIVE architecture, because that is the one
    /// apt-mark reports bare. A name apt has only for a foreign architecture
    /// installs under the qualified name and reads as missing for ever, so it
    /// is refused and told the qualified spelling -- which the name class
    /// already accepts.
    ///
    /// A bare name the repositories lack may still be a package installed
    /// from a .deb, and one of those apt WOULD install: measured identically
    /// on apt 2.4.14, 2.6.1, 2.8.3 and 3.0.3, `apt-get install -y -- <name>`
    /// on such a package exits 0 and marks it manually installed, after which
    /// `apt-mark showmanual` reports it and the row converges. So the
    /// installed architectures answer for it where the repository listing
    /// cannot.
    fn refuseAptNonNames(self: *Distro, arena: std.mem.Allocator, rows: []const Row) anyerror![]const Row {
        // The listing is made only if a row needs it: it costs a megabyte and
        // a rebuild of apt's cache, and a batch of qualified rows alone never
        // reads it.
        var known: ?std.StringHashMap(void) = null;
        var installed: ?Arches = null;
        const native = try self.aptNativeArch(arena);

        var keep: std.ArrayList(Row) = .empty;
        for (rows) |row| {
            const bare = backend_mod.bareName(row.name);
            if (backend_mod.archOf(row.name)) |arch| {
                // apt-mark reports a package of the machine's own
                // architecture without a qualifier, so a row that spells one
                // installs and then reads as missing on every status after.
                if (nativeAlias(arch)) {
                    self.say(
                        "mox: apt: row \"{s}\" carries the qualifier \"{s}\", which apt resolves to this machine's own architecture and apt-mark then reports bare, so the row could never read as installed; declare \"{s}\" instead\n",
                        .{ row.name, arch, bare },
                    );
                    continue;
                }
                if (std.mem.eql(u8, arch, native)) {
                    self.say(
                        "mox: apt: row \"{s}\" qualifies this machine's own architecture, which apt-mark reports bare, so the row could never read as installed; declare \"{s}\" instead\n",
                        .{ row.name, bare },
                    );
                    continue;
                }
                if ((try self.aptArchesOf(arena, row.name)).len > 0) {
                    try keep.append(arena, row);
                    continue;
                }
                if (installed == null) installed = try self.aptInstalledArches(arena);
                if (hasArch(installed.?, bare, arch)) {
                    try keep.append(arena, row);
                    continue;
                }
                self.say(
                    "mox: apt: row \"{s}\" names no apt package for the architecture \"{s}\", so it was not installed\n",
                    .{ row.name, arch },
                );
                continue;
            }
            if (known == null) {
                const argv = try aptNamesArgv(arena, native);
                known = try self.universeNames(arena, argv, try std.mem.join(arena, " ", argv));
            }
            if (known.?.contains(bare)) {
                try keep.append(arena, row);
                continue;
            }
            if (installed == null) installed = try self.aptInstalledArches(arena);
            // A package installed under the architecture apt-mark reports
            // bare -- this machine's own, or `all` -- is installed under the
            // row's own spelling, and apt-get marks it manual rather than
            // reaching for a regex.
            if (hasArch(installed.?, bare, native) or hasArch(installed.?, bare, "all")) {
                try keep.append(arena, row);
                continue;
            }
            // Only a foreign architecture can be suggested: a native one is
            // what the listing already answered for, and spelling it would
            // send the user to a row apt-mark reports bare.
            if (try self.aptForeignArchOf(arena, row.name, native, installed.?)) |arch| {
                self.say(
                    "mox: apt: row \"{s}\" names an apt package for the architecture \"{s}\" alone, which apt-mark reports as \"{s}:{s}\", so the row could never read as installed; declare \"{s}:{s}\" instead\n",
                    .{ row.name, arch, row.name, arch, row.name, arch },
                );
                continue;
            }
            const providers = try self.aptProvidersOf(arena, row.name);
            if (providers.len > 0) {
                var list: std.Io.Writer.Allocating = .init(arena);
                for (providers, 0..) |p, i| {
                    if (i > 0) try list.writer.writeAll(", ");
                    try list.writer.print("\"{s}\"", .{p});
                }
                self.say(
                    "mox: apt: row \"{s}\" names no apt package; it is a virtual name provided by {s}, and apt-mark reports only a package's own name, so declare the one you want instead\n",
                    .{ row.name, list.written() },
                );
                continue;
            }
            self.say(
                "mox: apt: row \"{s}\" names no apt package; apt-get would read it as a regular expression and install every package it matched, so it was not installed\n",
                .{row.name},
            );
        }
        return keep.toOwnedSlice(arena);
    }

    /// The binary architectures apt has this exact name under, in the order
    /// madison reports them, with no repeats. Empty means apt has no binary
    /// package by that name at all.
    ///
    /// `apt-cache madison` is the one query verified to answer LITERALLY.
    /// Against apt 3.0.3 on Debian trixie: it answers `wine32:armhf`, `g++`
    /// and `libstdc++6` -- names carrying the regex metacharacters the class
    /// admits -- with their own line, and answers `bsdextrautil.`,
    /// `w.ne32:armhf`, `libc.`, `^libc6$`, `libc6.*`, `g..` and the prefix
    /// `wine3` with nothing at all, while `apt-cache show` and `apt-cache
    /// policy` resolve those same patterns to a package. A purely virtual
    /// name (`awk`) also answers with nothing, so a capability cannot pass
    /// here either.
    ///
    /// A line is `<name> | <version> | <url> <suite>/<component> <arch>
    /// Packages`, so the architecture is the word before the last. Verified
    /// in that shape on apt 2.6.1, 2.8.3 and 3.0.3, and for a package built
    /// `Architecture: all`, which madison reports once per enabled
    /// architecture rather than as `all`.
    ///
    /// Only a line naming a binary index counts: with `deb-src` configured
    /// madison prints a `Sources` line too, and a source package is nothing
    /// `apt-get install` can put on the machine.
    fn aptArchesOf(self: *Distro, arena: std.mem.Allocator, name: []const u8) anyerror![]const []const u8 {
        const res = try self.runner.run(arena, &.{ "apt-cache", "madison", name });
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;

        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.endsWith(u8, line, " Packages")) continue;
            const head = line[0 .. line.len - " Packages".len];
            const space = std.mem.lastIndexOfScalar(u8, head, ' ') orelse continue;
            const arch = head[space + 1 ..];
            if (arch.len == 0) continue;
            for (out.items) |seen| {
                if (std.mem.eql(u8, seen, arch)) break;
            } else try out.append(arena, arch);
        }
        return out.toOwnedSlice(arena);
    }

    /// The architectures dpkg has each INSTALLED package under, keyed by the
    /// bare name -- `${Package}` spells one the same way whatever its
    /// architecture, so a row name compares against the key and the value
    /// separately.
    ///
    /// This is the half of the oracle the repository listing cannot answer.
    /// Measured identically on apt 2.4.14 (Ubuntu 22.04), 2.6.1 (bookworm),
    /// 2.8.3 (Ubuntu 24.04) and 3.0.3 (trixie), with sources fully
    /// configured: a package installed with `dpkg -i` and then marked auto --
    /// the state an obsolete dependency is in after a release upgrade or a
    /// removed PPA -- is absent from `apt-mark showmanual` and from every
    /// repository, yet `apt-get install -y -- <name>` exits 0 and marks it
    /// manual, after which `apt-mark showmanual` reports it. Its architecture
    /// is what says which spelling apt-mark will use.
    ///
    /// Only a package dpkg calls `installed` counts: a removed one left in
    /// `config-files` is a name `apt-get install` answers with "Unable to
    /// locate package" when no repository carries it (verified on all four).
    fn aptInstalledArches(self: *Distro, arena: std.mem.Allocator) anyerror!Arches {
        const res = try self.runner.run(arena, &.{ "dpkg-query", "-W", "-f", "${Package} ${Architecture} ${Status}\\n" });
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;

        var out = Arches.init(arena);
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const name = fields.next() orelse continue;
            const arch = fields.next() orelse continue;
            // `${Status}` is three words, of which the last is the state.
            _ = fields.next() orelse continue;
            _ = fields.next() orelse continue;
            const state = fields.next() orelse continue;
            if (!std.mem.eql(u8, state, "installed")) continue;
            const slot = try out.getOrPut(name);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(arena, arch);
        }
        return out;
    }

    /// The packages that provide `name` without being it, sorted, or nothing
    /// when apt knows no such capability.
    ///
    /// `apt-cache showpkg` takes a regex, so only the stanza whose own
    /// `Package:` line is this exact name is read. Verified on apt 2.4.14 and
    /// 3.0.3: a purely virtual name answers a stanza with an empty `Versions:`
    /// and a `Reverse Provides:` list of `<package> <version> (= )` lines,
    /// and a name apt has never heard of answers no stanza at all.
    ///
    /// An answer past the capture cap is a pattern that matched much of the
    /// archive, which is the regex case and is reported as such.
    fn aptProvidersOf(self: *Distro, arena: std.mem.Allocator, name: []const u8) anyerror![]const []const u8 {
        const res = self.runner.run(arena, &.{ "apt-cache", "showpkg", name }) catch |e| switch (e) {
            error.StreamTooLong => return &.{},
            else => return e,
        };
        try exec.checkTimedOut(res);
        if (!res.ok) return &.{};

        var out: std.ArrayList([]const u8) = .empty;
        var mine = false;
        var listing = false;
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, " \t\r");
            if (stringAfter(line, "Package:")) |pkg| {
                mine = std.mem.eql(u8, pkg, name);
                listing = false;
                continue;
            }
            if (!mine) continue;
            if (std.mem.startsWith(u8, line, "Reverse Provides:")) {
                listing = true;
                continue;
            }
            if (!listing) continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const provider = fields.next() orelse continue;
            if (std.mem.eql(u8, provider, name)) continue;
            for (out.items) |seen| {
                if (std.mem.eql(u8, seen, provider)) break;
            } else try out.append(arena, provider);
        }
        std.mem.sort([]const u8, out.items, {}, lessThanString);
        return out.toOwnedSlice(arena);
    }

    /// Refuse the rows apt has a package for but would not install, and
    /// answer with the rest.
    ///
    /// A hold and a pin are decisions about the machine that neither the
    /// index nor the package list knows about, and apt-get answers a batch
    /// carrying one by installing NOTHING: verified against apt 2.6.1 and
    /// 3.0.3, `apt-get install -y -qq -- sl bat` exits 100 with "Held
    /// packages were changed and -y was used without
    /// --allow-change-held-packages" when `sl` is held, and with "Package
    /// 'cowsay' has no installation candidate" when a `Pin-Priority: -1`
    /// rejects every version of it -- and `bat` lands neither time. So one
    /// such row would keep every other package in the manifest off the
    /// machine, which is exactly what a row-level refusal exists to prevent.
    ///
    /// Not overridden: `--allow-change-held-packages` would install over a
    /// hold the user put there, and a pin is the same decision written in
    /// apt's preferences. The row is refused and the machine left as its
    /// owner set it up.
    fn refuseAptUninstallable(self: *Distro, arena: std.mem.Allocator, rows: []const Row) anyerror![]const Row {
        if (rows.len == 0) return rows;
        const held = try self.aptHeld(arena);
        const candidates = try self.aptCandidates(arena, rows);

        var keep: std.ArrayList(Row) = .empty;
        for (rows) |row| {
            if (held.contains(row.name)) {
                self.say(
                    "mox: apt: row \"{s}\" names a package apt-mark holds, and an install carrying a held package installs nothing at all, so it was not installed; `apt-mark unhold {s}` to let mox install it\n",
                    .{ row.name, row.name },
                );
                continue;
            }
            if (candidates.get(row.name)) |has_candidate| {
                if (!has_candidate) {
                    self.say(
                        "mox: apt: row \"{s}\" names a package apt has no installation candidate for, which a pin in apt's preferences does, and an install carrying it installs nothing at all, so it was not installed\n",
                        .{row.name},
                    );
                    continue;
                }
            }
            try keep.append(arena, row);
        }
        return keep.toOwnedSlice(arena);
    }

    /// The names `apt-mark showhold` reports, one per line. It spells a
    /// foreign-architecture package `name:arch`, which is how a row spells
    /// one too, so a row name compares directly.
    fn aptHeld(self: *Distro, arena: std.mem.Allocator) anyerror!std.StringHashMap(void) {
        const res = try self.runner.run(arena, &.{ "apt-mark", "showhold" });
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

    /// Whether apt has an installation candidate for each row, asked for the
    /// whole batch at once.
    ///
    /// `apt-cache policy` prints a stanza per package: a header at column
    /// zero -- the name apt resolves the operand to, then a `:` -- and
    /// indented lines, of which `Candidate:` is the version apt would
    /// install or `(none)`. It falls back to a regex only when no package is
    /// named exactly, and every row reaching here named one, so each answers
    /// with a single stanza whose header is the row's own name.
    ///
    /// `Candidate:` is the C-locale spelling, which the captured call runs
    /// under; measured on apt 3.0.3 under `LANG=ja_JP.UTF-8`, the same line
    /// is printed in Japanese and would match nothing here.
    fn aptCandidates(self: *Distro, arena: std.mem.Allocator, rows: []const Row) anyerror!std.StringHashMap(bool) {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "apt-cache", "policy" });
        for (rows) |row| try argv.append(arena, row.name);
        const res = try self.runner.run(arena, argv.items);
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;

        var out = std.StringHashMap(bool).init(arena);
        var name: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (line[0] != ' ' and line[0] != '\t') {
                name = if (std.mem.endsWith(u8, line, ":")) line[0 .. line.len - 1] else null;
                continue;
            }
            const field = std.mem.trimStart(u8, line, " \t");
            const value = stringAfter(field, "Candidate:") orelse continue;
            const key = name orelse continue;
            try out.put(key, !std.mem.eql(u8, value, "(none)"));
        }
        return out;
    }

    /// The first architecture other than `native` that apt has `name` under,
    /// in a repository or already installed, or null when apt has it under
    /// none. A package installed from a .deb is in no repository, so madison
    /// alone would miss the one spelling that row could converge under.
    fn aptForeignArchOf(
        self: *Distro,
        arena: std.mem.Allocator,
        name: []const u8,
        native: []const u8,
        installed: Arches,
    ) anyerror!?[]const u8 {
        for (try self.aptArchesOf(arena, name)) |arch| {
            if (!std.mem.eql(u8, arch, native)) return arch;
        }
        const list = installed.get(name) orelse return null;
        for (list.items) |arch| {
            if (!std.mem.eql(u8, arch, native)) return arch;
        }
        return null;
    }

    /// Each installed package's architectures, keyed by its bare name.
    const Arches = std.StringHashMap(std.ArrayList([]const u8));

    fn hasArch(arches: Arches, name: []const u8, arch: []const u8) bool {
        const list = arches.get(name) orelse return false;
        for (list.items) |have| {
            if (std.mem.eql(u8, have, arch)) return true;
        }
        return false;
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

    /// Refuse the rows dnf has no package for, and answer with the rest.
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
    fn refuseDnfNonPackages(self: *Distro, arena: std.mem.Allocator, rows: []const Row) anyerror![]const Row {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &dnf_names_argv);
        for (rows) |row| try argv.append(arena, row.name);
        const known = try self.dnfNameSet(arena, argv.items);

        var keep: std.ArrayList(Row) = .empty;
        for (rows) |row| {
            if (known.contains(row.name)) {
                try keep.append(arena, row);
                continue;
            }
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
        return keep.toOwnedSlice(arena);
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

    /// Whether any row names something the listing does not carry, which is
    /// the only row the group and provision questions are asked about.
    fn anyUnlisted(rows: []const Row, known: std.StringHashMap(void)) bool {
        for (rows) |row| {
            if (!known.contains(row.name)) return true;
        }
        return false;
    }

    /// What follows `prefix` in `line`, trimmed, or null when `line` does not
    /// begin with it.
    fn stringAfter(line: []const u8, prefix: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, line, prefix)) return null;
        return std.mem.trim(u8, line[prefix.len..], " \t");
    }

    /// Every package pacman's repositories carry, one per line, and the
    /// members of one group. Verified against pacman 7.1.0: `-Sl` prints
    /// `<repo> <name> <version>` per package and no group name among them
    /// (15265 lines, 440 KiB on a current Arch), and `-Sg <name>` prints
    /// `<group> <member>` per member and exits 1 on a name that is not a
    /// group.
    ///
    /// `-Sl` rather than `-Slq` because the repository each name came from is
    /// what says whether the database is complete, and only a complete one
    /// can answer "this is no group".
    const pacman_names_argv = [_][]const u8{ "pacman", "-Sl" };

    /// The repositories pacman.conf configures, whatever their databases.
    const pacman_repos_argv = [_][]const u8{ "pacman-conf", "--repo-list" };

    const PacmanUniverse = struct {
        names: std.StringHashMap(void),
        /// The repositories that contributed a line, which is every
        /// configured one whose database is present and non-empty.
        repos: std.StringHashMap(void),
    };

    /// The package universe, and which repositories answered for it.
    ///
    /// A missing database is not an error and not an empty answer: verified
    /// against pacman 7.1.0, `pacman -Sl` with one of two databases removed
    /// exits 0, warns "database file for 'extra' does not exist" on stderr,
    /// and prints the other repository's 299 packages -- indistinguishable on
    /// stdout from a repository that is genuinely empty.
    fn pacmanUniverse(self: *Distro, arena: std.mem.Allocator) anyerror!PacmanUniverse {
        const res = self.runner.run(arena, &pacman_names_argv) catch |e| switch (e) {
            error.StreamTooLong => {
                self.say(
                    "mox: pacman: `pacman -Sl` answered with more than the {d} MiB mox reads from one query, so no row could be checked against it and nothing was installed\n",
                    .{exec.max_query_bytes / (1024 * 1024)},
                );
                return Error.DistroQueryFailed;
            },
            else => return e,
        };
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;

        var out: PacmanUniverse = .{
            .names = std.StringHashMap(void).init(arena),
            .repos = std.StringHashMap(void).init(arena),
        };
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const repo = fields.next() orelse continue;
            const name = fields.next() orelse continue;
            try out.repos.put(repo, {});
            try out.names.put(name, {});
        }
        return out;
    }

    /// Whether every configured repository contributed to `universe`.
    fn pacmanDatabaseComplete(self: *Distro, arena: std.mem.Allocator, universe: PacmanUniverse) anyerror!bool {
        const res = try self.runner.run(arena, &pacman_repos_argv);
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;

        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const repo = std.mem.trim(u8, raw, " \t\r");
            if (repo.len == 0) continue;
            if (!universe.repos.contains(repo)) return false;
        }
        return true;
    }

    /// Refuse the rows pacman positively identifies as something other than a
    /// package of that name -- a GROUP, or a PROVISION some other package
    /// satisfies -- and answer with the rest.
    ///
    /// A group is spelled exactly like a package and passes every shape rule
    /// there is. `pacman -S xfce4` installs all 14 of its members -- `gnome`
    /// has 58, `plasma` 70 -- and `pacman -Qeq`, the adapter's own query,
    /// reports the members and never the group: the row is MISSING on every
    /// status while the machine carries packages no manifest declares, and
    /// every apply installs the group again.
    ///
    /// A PROVISION goes the same way and is spelled the same again: `cron` is
    /// in no `pacman -Sl` line and `pacman -Sg cron` exits 1, but `pacman -Syu
    /// --needed --noconfirm -- cron` installs `cronie`, and `pacman -Qeq`
    /// reports `cronie`. Measured on pacman 7.1.0 against fully synced
    /// databases, `sh` resolves to `bash`, `java-runtime` to `jdk-openjdk`,
    /// `ttf-font` to `gnu-free-fonts` and `smtp-forwarder` to `exim` the same
    /// way.
    ///
    /// The package universe is asked first because a name that is both is
    /// pacman's package: `pacman -S kdevelop` resolves the package kdevelop
    /// and not the group's kdevelop-php and kdevelop-python. `base` and
    /// `base-devel` are packages in their own right now, so they pass here
    /// while `pacman -Sg base-devel` says it is no group.
    ///
    /// Only a POSITIVE answer refuses. A name no query resolves at all is
    /// KEPT: the listing is whatever this machine last synced, and refusing
    /// what it merely failed to find would refuse installable packages on any
    /// machine whose database is a few days old.
    ///
    /// "This is no group", though, is acted on rather than merely believed,
    /// so it is asked of a COMPLETE database. Verified against pacman 7.1.0
    /// with one of two sync databases removed -- the state a machine is in
    /// when a repository was added and never synced, or a download failed:
    /// `pacman -Sl` exits 0 listing the other repository's 299 packages, and
    /// `pacman -Sg xfce4` exits 1 saying the group was not found, which is
    /// what a genuine non-group answers too. Acting on that keeps the row,
    /// and `pacman -Syu -- xfce4` then installs all of the group's members.
    /// The provision oracle needs no such guarantee of its own -- it refuses
    /// only on a resolution pacman actually made, which a short database
    /// cannot manufacture -- but it is asked after the same sync all the same,
    /// because a database that answered nothing for the row would otherwise
    /// leave both questions unanswered.
    fn refusePacmanNonPackages(self: *Distro, arena: std.mem.Allocator, rows: []const Row, elevate: bool) anyerror![]const Row {
        // Every one of these queries reads the sync database, and a container
        // or a fresh machine has never downloaded one: unsynced, `pacman -Sl`
        // exits 0 with nothing at all (verified against pacman 7.1.0) and
        // every row would be judged against a database that holds nothing.
        //
        // So the database is ASKED first and written only when its answer is
        // unusable, and what is then run is the full `-Syu` the install itself
        // was about to run, never a bare `-Sy`. A `-Sy` alone leaves the
        // database ahead of the installed packages, which Arch documents as an
        // unsupported partial-upgrade state, and every path out of here -- a
        // refused row, an empty listing, a kill at the bound -- would leave the
        // machine in it. The install that follows drops its own `-y` once this
        // has run, so no apply upgrades the system twice.
        //
        // Completeness is asked only when some row is absent from the listing,
        // because that is the only row any of this has a question about. A
        // repository configured with an EMPTY database contributes no line and
        // so can never read as complete -- measured on pacman 7.1.0 against a
        // `repo-add` database with nothing in it, which `pacman -Sl` answers
        // for exactly as it answers for a database that is missing -- and
        // asking it on every apply would sync every apply for nothing.
        var universe = try self.pacmanUniverse(arena);
        if (anyUnlisted(rows, universe.names) and !try self.pacmanDatabaseComplete(arena, universe)) {
            var sync: std.ArrayList([]const u8) = .empty;
            if (elevate) try sync.append(arena, "sudo");
            try sync.appendSlice(arena, &.{ "pacman", "-Syu", "--noconfirm" });
            const up = try self.runner.stream(arena, sync.items);
            try exec.checkTimedOut(up);
            if (!up.ok) return Error.DistroRefreshFailed;
            self.synced = true;
            universe = try self.pacmanUniverse(arena);
        }
        const known = universe.names;
        if (known.count() == 0) {
            self.say(
                "mox: pacman: `pacman -Sl` lists no packages at all, which is a machine with no repositories configured rather than a row that names none, so no row could be checked and nothing was installed\n",
                .{},
            );
            return Error.DistroQueryFailed;
        }

        var keep: std.ArrayList(Row) = .empty;
        for (rows) |row| {
            if (known.contains(row.name)) {
                try keep.append(arena, row);
                continue;
            }
            const members = try self.pacmanGroupMembers(arena, row.name);
            if (members.len == 0) {
                if (try self.pacmanProvider(arena, row.name)) |provider| {
                    self.say(
                        "mox: pacman: row \"{s}\" names no pacman package; it is a provision that \"{s}\" satisfies, and pacman reports only the package name, so declare that instead\n",
                        .{ row.name, provider },
                    );
                    continue;
                }
                // Absence from the listing is not evidence against the row
                // here, where it is for apt: mox runs `apt-get update` itself
                // immediately before reading apt's listing, so that listing
                // answers for the index the install will resolve against,
                // while pacman's sync database is whatever the machine last
                // downloaded -- the normal state of an Arch machine between
                // upgrades. The install argv syncs before it resolves, so a
                // name this database has never heard of may well be a package
                // once it has; pacman reports a name that is truly wrong
                // itself.
                try keep.append(arena, row);
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
        return keep.toOwnedSlice(arena);
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

    /// The package pacman would install for `name` when `name` is not itself
    /// one; null when pacman resolves `name` to itself, and null again when it
    /// resolves it to nothing at all.
    ///
    /// `pacman -S --print` resolves the operand and prints the transaction it
    /// would run without committing any of it: measured on pacman 7.1.0,
    /// nothing under the database path changes across a run of these.
    /// `--print-format '%n'` reduces each entry to a bare package name.
    ///
    /// A name with no target exits 1 saying "target not found", which is why
    /// this cannot refuse an installable name on a stale database: only an
    /// exit 0, a resolution pacman actually made, is acted on.
    ///
    /// No `--needed`, which the install argv does carry: measured on the same
    /// pacman, `-S --print --needed` prints NOTHING for a target already
    /// installed, and an empty transaction is indistinguishable from one that
    /// resolved elsewhere. Without it an installed target prints its own name.
    ///
    /// The transaction carries the target's dependencies too, and the target
    /// is its LAST entry, because a dependency is installed before the package
    /// that needs it: `cron` prints `run-parts` then `cronie`, `bat` prints
    /// three libraries then `bat`, `smtp-forwarder` four then `exim`.
    fn pacmanProvider(self: *Distro, arena: std.mem.Allocator, name: []const u8) anyerror!?[]const u8 {
        const res = try self.runner.run(arena, &.{ "pacman", "-S", "--print", "--print-format", "%n", "--", name });
        try exec.checkTimedOut(res);
        if (!res.ok) return null;

        var last: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (std.mem.eql(u8, line, name)) return null;
            last = line;
        }
        return last;
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

/// The bare-name listing argv the apt adapter builds for `native`.
fn aptNamesCall(comptime native: []const u8) []const u8 {
    return "apt-cache -o APT::Architectures=" ++ native ++ " -o Dir::State::status=/dev/null --generate pkgnames";
}

/// The installed-architecture listing argv the apt adapter builds.
const apt_installed_call = "dpkg-query -W -f ${Package} ${Architecture} ${Status}\\n";

fn countCalls(fake: *const exec.Fake, argv: []const u8) usize {
    var n: usize = 0;
    for (fake.calls.items) |c| {
        if (std.mem.eql(u8, c, argv)) n += 1;
    }
    return n;
}

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
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n", .match = .prefix },
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
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = aptNamesCall("amd64"), .stdout = "bat\nnano\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix },
        .{ .argv = "apt-mark showauto" },
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
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "sudo env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = aptNamesCall("amd64"), .stdout = "bat\nfd-find\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat fd-find" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("fd-find", &.{}) });
    try testing.expectEqualStrings("sudo env DEBIAN_FRONTEND=noninteractive apt-get update", fake.calls.items[1]);
    try testing.expectEqualStrings("sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat fd-find", fake.calls.items[fake.calls.items.len - 1]);
}

test "install: dnf takes one non-interactive command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n bat ripgrep", .stdout = "bat\nripgrep\n" },
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n", .match = .prefix },
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
        .{ .argv = "pacman -Sl", .stdout = "core bat 0.25.0-1\nextra ripgrep 14.1.1-1\n" },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\nextra\n" },
        .{ .argv = "pacman -Qdq" },
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
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n", .match = .prefix },
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
            .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
            .{ .argv = aptNamesCall("amd64"), .stdout = "bat\n" },
            .{ .argv = "apt-mark showhold" },
            .{ .argv = "apt-cache policy", .match = .prefix },
            .{ .argv = "dnf -q repoquery --qf %{name}\n bat", .stdout = "bat\n" },
            .{ .argv = "pacman -Sl", .stdout = "core bat 0.25.0-1\n" },
            .{ .argv = "pacman-conf --repo-list", .stdout = "core\n" },
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
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n", .match = .prefix },
        .{ .argv = "dnf install -y bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("zlib-devel", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
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
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\nbsdextrautils\nnano\n" },
        .{ .argv = apt_installed_call, .stdout = "bat arm64 install ok installed\n" },
        .{ .argv = "apt-cache madison bsdextrautil.", .stdout = "" },
        .{ .argv = "apt-cache showpkg bsdextrautil.", .stdout = "" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("bsdextrautil.", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: apt: row \"bsdextrautil.\" names no apt package; apt-get would read it as a regular expression and install every package it matched, so it was not installed\n",
        w.written(),
    );
    // The row never reached apt-get, so nothing undeclared was installed.
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "apt-get install") == null);
}

test "install: apt refuses the bad names and installs the rest of the batch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One row nobody can install must not keep the others off the machine.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = aptNamesCall("amd64"), .stdout = "bat\n" },
        .{ .argv = apt_installed_call, .stdout = "bat amd64 install ok installed\n" },
        .{ .argv = "apt-cache madison", .match = .prefix, .stdout = "" },
        .{ .argv = "apt-cache showpkg", .match = .prefix, .stdout = "" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{
        rowOf("bat", &.{}),
        rowOf("ruby.dev", &.{}),
        rowOf("libz.dev", &.{}),
    });
    try testing.expectEqual(@as(usize, 2), d.backend().installRefused());
    try testing.expect(std.mem.indexOf(u8, w.written(), "row \"ruby.dev\" names no apt package") != null);
    try testing.expect(std.mem.indexOf(u8, w.written(), "row \"libz.dev\" names no apt package") != null);
    try testing.expect(std.mem.indexOf(u8, w.written(), "\"bat\"") == null);
    // Only the good row is an operand: a refused one is never passed on.
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat"));
}

test "install: a foreign-architecture row is asked about as written, never by its bare half" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `apt-cache pkgnames` lists bare names alone and omits a package that
    // exists only for a foreign architecture, so the bare half answers
    // nothing about the row: `wine32` is in no listing on an arm64 machine,
    // while apt installs `wine32:armhf` and `apt-mark showmanual` reports
    // exactly that. madison is asked about the name as written instead.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{
            .argv = "apt-cache madison wine32:armhf",
            .stdout = "wine32:armhf | 10.0~repack-6 | http://deb.debian.org/debian trixie/main armhf Packages\n",
        },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- wine32:armhf" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{rowOf("wine32:armhf", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- wine32:armhf"));
    // The listing is never asked for: it could not answer about this row.
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "pkgnames") == null);
}

test "install: apt refuses a qualified name madison has no binary package for" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A `Sources` line is not a package `apt-get install` can put on the
    // machine, and with `deb-src` configured madison prints one for a source
    // package of the same name.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{
            .argv = "apt-cache madison wine:armhf",
            .stdout = "      wine | 10.0~repack-6 | http://deb.debian.org/debian trixie/main Sources\n",
        },
        .{ .argv = apt_installed_call, .stdout = "bat arm64 install ok installed\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("wine:armhf", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: apt: row \"wine:armhf\" names no apt package for the architecture \"armhf\", so it was not installed\n",
        w.written(),
    );
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "apt-get install") == null);
}

test "install: apt refuses a qualifier naming this machine's own architecture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved on Debian trixie: `apt-get install bsdextrautils:arm64` on an
    // arm64 machine makes `apt-mark showmanual` report `bsdextrautils`, so
    // the qualified row would read as missing after every install.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bsdextrautils\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("bsdextrautils:arm64", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
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
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = aptNamesCall("amd64"), .code = 100 },
    } };
    var d: Distro = .{ .manager = .apt, .runner = apt.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroQueryFailed, d.backend().install(a, &.{rowOf("bat", &.{})}));

    var dnf: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n bat", .code = 1 },
    } };
    var d2: Distro = .{ .manager = .dnf, .runner = dnf.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroQueryFailed, d2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(dnf.called("dnf -q repoquery --installed --qf %{name}\n bat"));
}

test "install: dnf refuses a virtual provide, naming the package that provides it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved against dnf5 5.4.3 on Fedora 44: `zlib-devel` is not a package
    // there, only a capability `zlib-ng-compat-devel` provides. rpm reports
    // the provider's name, so the row is missing on every status after.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n zlib-devel" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n zlib-devel", .stdout = "" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n --whatprovides zlib-devel", .stdout = "zlib-ng-compat-devel\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("zlib-devel", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: dnf: row \"zlib-devel\" names no dnf package; it is a capability provided by \"zlib-ng-compat-devel\", and rpm reports only the package name, so declare that instead\n",
        w.written(),
    );
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "dnf install") == null);
}

test "install: a row dnf has as a dependency is marked user installed, never installed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on dnf5 5.2.18 and 5.4.3: `dnf install` on a package installed
    // as a dependency exits 0 saying it is installed already and leaves the
    // reason alone, so `dnf repoquery --userinstalled` goes on omitting it
    // and the row reads missing on every status after.
    //
    // No repository is asked about it either. Proved on Fedora with
    // groff-base dependency-installed and every repository `enabled=0`:
    // `dnf -q repoquery --qf '%{name}\n' groff-base` answers nothing, as
    // does `--whatprovides`, while `--installed` answers and `dnf mark user
    // -y groff-base` exits 0. A row judged by the repositories first is
    // refused for ever, for a package the machine demonstrably has.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "dnf --version", .stdout = "dnf5 version 5.2.18.0\ndnf5 plugin API version 2.0\n" },
        .{ .argv = "sudo dnf mark user -y bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = true, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installMarked());
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expect(fake.called("sudo dnf mark user -y bat"));
    for (fake.calls.items) |c| {
        try testing.expect(std.mem.indexOf(u8, c, "dnf install") == null);
        try testing.expect(std.mem.indexOf(u8, c, "--installed") != null or std.mem.indexOf(u8, c, "repoquery") == null);
    }
    try testing.expectEqualStrings(
        "mox: dnf: \"bat\" is installed already as a dependency, so what the row is missing is dnf's record of who asked for it; marking it user installed\n",
        w.written(),
    );
}

test "install: dnf4 takes the other mark spelling, which dnf5 exits 2 on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured: dnf 4.14.0 has no `mark user` and dnf5 no `mark install`,
    // each exiting 2 on the other's, and only dnf5's version line names
    // itself.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "dnf --version", .stdout = "4.14.0\n  Installed: dnf-0:4.14.0-8.el9.noarch\n" },
        .{ .argv = "dnf mark install bat" },
    } };
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installMarked());
    try testing.expect(fake.called("dnf mark install bat"));
}

test "install: a mark that fails is that row's failure, and the rows beside it go on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A mark is the only thing that converges the row, so a failed one must
    // not fall back to an install that exits 0 and leaves it missing. Nor
    // is it the batch's failure: the row beside it is marked, and the one
    // after that installed, exactly as if the failed row were not there.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n bat fd-find ripgrep", .stdout = "bat\nfd-find\n" },
        .{ .argv = "dnf --version", .stdout = "dnf5 version 5.4.3.0\n" },
        .{ .argv = "dnf mark user -y bat", .code = 1 },
        .{ .argv = "dnf mark user -y fd-find" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n ripgrep", .stdout = "ripgrep\n" },
        .{ .argv = "dnf install -y ripgrep" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("fd-find", &.{}), rowOf("ripgrep", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installUnmarked());
    try testing.expectEqual(@as(usize, 1), d.backend().installMarked());
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expect(fake.called("dnf install -y ripgrep"));
    try testing.expect(!fake.called("dnf install -y bat"));
    try testing.expect(std.mem.indexOf(u8, w.written(), "\"bat\" could not be marked user installed, so the row stays missing") != null);
}

test "install: a dnf whose generation cannot be read marks nothing and says which rows stay missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n bat fd-find", .stdout = "bat\nfd-find\n" },
        .{ .argv = "dnf --version", .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("fd-find", &.{}) });
    try testing.expectEqual(@as(usize, 0), d.backend().installMarked());
    // Every row that needed the mark is counted as failed, so the run cannot
    // read clean over rows that are still missing.
    try testing.expectEqual(@as(usize, 2), d.backend().installUnmarked());
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "dnf install") == null);
    try testing.expect(std.mem.indexOf(u8, w.written(), "which dnf this machine has could not be read") != null);
}

test "install: the rows a manager already has are counted apart from the ones it installed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n bat ripgrep", .stdout = "bat\n" },
        .{ .argv = "dnf --version", .stdout = "dnf5 version 5.4.3.0\n" },
        .{ .argv = "dnf mark user -y bat" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n ripgrep", .stdout = "ripgrep\n" },
        .{ .argv = "dnf install -y ripgrep" },
    } };
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("ripgrep", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installMarked());
    // The install carries the other row alone: handing it the marked one
    // would install nothing and cost a resolution.
    try testing.expect(fake.called("dnf install -y ripgrep"));
}

test "install: a row apt has as a dependency is marked manual, never installed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on apt 3.0.3: `apt-get install` on an automatically installed
    // package it also has an upgrade for upgrades it and leaves it automatic,
    // so `apt-mark showmanual` omits it and the row reads missing until a
    // later apply finds the package current.
    //
    // Nothing is going to be installed, so nothing is resolved either: no
    // index refresh, no listing, no hold or pin check.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showauto", .stdout = "bat\nlibc6\n" },
        .{ .argv = "apt-mark manual bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installMarked());
    try testing.expect(fake.called("apt-mark manual bat"));
    try testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    try testing.expect(std.mem.indexOf(u8, w.written(), "marking it manually installed") != null);
}

test "install: a held package apt already has is marked, never refused for the hold" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The hold refusal exists because an install carrying a held package
    // installs nothing at all -- and a package already on the machine has no
    // install coming. `apt-mark manual` takes a held package, so the row
    // converges and the hold stays as its owner set it; the row beside it
    // resolves and installs as usual.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showauto", .stdout = "groff-base\n" },
        .{ .argv = "apt-mark manual groff-base" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = aptNamesCall("amd64"), .stdout = "bat\ngroff-base\n" },
        .{ .argv = "apt-mark showhold", .stdout = "groff-base\n" },
        .{ .argv = "apt-cache policy bat", .stdout = "bat:\n  Installed: (none)\n  Candidate: 0.25.0-2\n" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("groff-base", &.{}), rowOf("bat", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installMarked());
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expect(fake.called("apt-mark manual groff-base"));
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat"));
    try testing.expect(std.mem.indexOf(u8, w.written(), "holds") == null);
    for (fake.calls.items) |c| {
        try testing.expect(std.mem.indexOf(u8, c, "allow-change-held-packages") == null);
        try testing.expect(std.mem.indexOf(u8, c, "unhold") == null);
    }
}

test "install: a row pacman has as a dependency is marked explicit, never installed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0: `pacman -S --needed` skips a package it has
    // already, and even a full reinstall leaves the reason `dependency`, so
    // `pacman -Qeq` goes on omitting it.
    //
    // Both the question and the mark are local reads and writes of pacman's
    // own database, so the sync database is never opened: a row for a
    // package the machine has converges on a machine that cannot sync.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .stdout = "bat\n" },
        .{ .argv = "sudo pacman -D --asexplicit bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installMarked());
    try testing.expect(fake.called("sudo pacman -D --asexplicit bat"));
    try testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    try testing.expect(std.mem.indexOf(u8, w.written(), "marking it explicitly installed") != null);
}

test "install: a pacman that cannot sync still marks what the machine already has" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured with mox on an Arch machine whose sync fails: judged by the
    // repositories first, the batch ended in `install did not run:
    // DistroRefreshFailed` with the record unchanged, though marking needs
    // only `pacman -Qdq` and `pacman -D --asexplicit`, both local. The row
    // the machine has is marked before the sync is tried; the sync's
    // failure is still the failure of the row that needed it.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .stdout = "acl\n" },
        .{ .argv = "pacman -D --asexplicit acl" },
        .{ .argv = "pacman -Sl", .stdout = "" },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\nextra\n" },
        .{ .argv = "pacman -Syu --noconfirm", .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroRefreshFailed, d.backend().install(a, &.{ rowOf("acl", &.{}), rowOf("bat", &.{}) }));
    try testing.expectEqual(@as(usize, 1), d.backend().installMarked());
    try testing.expect(!d.backend().installSpawned());
    try testing.expectEqualStrings("pacman -Qdq", fake.calls.items[0]);
    try testing.expectEqualStrings("pacman -D --asexplicit acl", fake.calls.items[1]);
}

test "install: a -Qdq that could not answer is said, never read as no dependency at all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0: a local database pacman cannot read exits
    // 255 with nothing on stdout. Reading that as "nothing is a dependency"
    // would hand a row the machine has to an install that cannot converge
    // it, with no word about why.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 255 },
        .{ .argv = "pacman -Sl", .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installMarked());
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- bat"));
    try testing.expectEqualStrings(
        "mox: pacman: what this machine already has installed could not be listed, so a row naming a package the manager has already may not converge this run\n",
        w.written(),
    );
}

test "install: a machine with no dependency at all is an answer, not a failed query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0: `pacman -Qdq` exits 1 with nothing on stdout
    // when no package is installed as a dependency, which reading as a
    // failure would turn into a warning on every apply.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Sl", .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman -Syu --needed --noconfirm -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installMarked());
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- bat"));
    try testing.expectEqualStrings("", w.written());
}

test "install: a listing that could not be read leaves the rows to the install, and says so" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix },
        .{ .argv = "apt-mark showauto", .code = 7 },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installMarked());
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat"));
    try testing.expect(std.mem.indexOf(u8, w.written(), "what this machine already has installed could not be listed") != null);
}

test "install: dnf names every provider of a capability several packages carry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n java-devel" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n java-devel", .stdout = "" },
        .{
            .argv = "dnf -q repoquery --qf %{name}\n --whatprovides java-devel",
            .stdout = "java-21-openjdk-devel\njava-17-openjdk-devel\njava-21-openjdk-devel\n",
        },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("java-devel", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
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
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n ripgrepp" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n ripgrepp", .stdout = "" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n --whatprovides ripgrepp", .stdout = "" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("ripgrepp", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
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
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman -Sl", .stdout = "core bat 0.25.0-1\nextra fprintd 1.94.9-1\nextra libfprint 1.94.9-1\n" },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\nextra\n" },
        .{ .argv = "pacman -Sg fprint", .stdout = "fprint libfprint\nfprint fprintd\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("fprint", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"fprint\" names no pacman package; it is a group of 2 packages (\"fprintd\", \"libfprint\"), and pacman reports each of them under its own name, so declare the ones you want instead\n",
        w.written(),
    );
    // The row never reached pacman, so no member of the group landed, and a
    // check that refused it wrote nothing to the machine either.
    for (fake.calls.items) |c| {
        try testing.expect(std.mem.indexOf(u8, c, "-Syu") == null);
        try testing.expect(std.mem.indexOf(u8, c, "-Sy ") == null);
    }
}

test "install: pacman installs a name its database has not heard of, rather than refusing it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved with pacman 7.1.0 synced from the 2024-01-01 Arch archive and
    // then pointed at a current mirror: `pacman -Sl` answers 13801 names and
    // has none of `ghostty`, `uv`, `zed` or `opencode`, all four of which the
    // current repositories carry. The install argv is `pacman -Syu`, which
    // syncs before it resolves, so absence from this database says nothing
    // about the row and pacman itself answers for a name that is truly wrong.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Sl", .stdout = "core bat 0.25.0-1\nextra ripgrep 14.1.1-1\n" },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\nextra\n" },
        .{ .argv = "pacman -Sg ghostty", .code = 1 },
        .{ .argv = "pacman -S --print --print-format %n -- ghostty", .code = 1 },
        .{ .argv = "pacman -Qdq" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- ghostty" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("ghostty", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expectEqualStrings("", w.written());
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- ghostty"));
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
        .{ .argv = "pacman -Sl", .stdout = "core base 3-2\ncore base-devel 1-2\nextra kdevelop 25.08.1-1\nextra kdevelop-php 25.08.1-1\n" },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\nextra\n" },
        .{ .argv = "pacman -Qdq" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- kdevelop base-devel base" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{ rowOf("kdevelop", &.{}), rowOf("base-devel", &.{}), rowOf("base", &.{}) });
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- kdevelop base-devel base"));
    // Asked about no name it already found, so no group query ran at all.
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "-Sg") == null);
}

test "install: a group in a repository this machine never synced is still refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved against pacman 7.1.0 with `extra.db` removed and `core.db`
    // kept -- the state a machine is in when a repository was added and
    // never synced, or one database failed to download. `pacman -Sl` exits 0
    // listing core's 299 packages, so the listing is not empty and nothing
    // says it is short; `pacman -Sg xfce4` exits 1 with "package group
    // 'xfce4' was not found", which is exactly what a genuine non-group
    // answers. Acting on that keeps the row, and `pacman -Syu -- xfce4`
    // then installs all 14 of the group's members.
    //
    // So the group question is asked of a database every configured
    // repository answered for.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman -Sl", .stdout = "core bat 0.25.0-1\n", .once = true },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\nextra\n" },
        .{ .argv = "sudo pacman -Syu --noconfirm" },
        .{ .argv = "pacman -Sl", .stdout = "core bat 0.25.0-1\nextra exo 4.20.0-1\nextra garcon 4.20.0-1\n" },
        .{ .argv = "pacman -Sg xfce4", .stdout = "xfce4 exo\nxfce4 garcon\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("xfce4", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"xfce4\" names no pacman package; it is a group of 2 packages (\"exo\", \"garcon\"), and pacman reports each of them under its own name, so declare the ones you want instead\n",
        w.written(),
    );
    // The group question came after the sync, never against the short
    // database the first listing came from.
    try testing.expectEqualStrings("sudo pacman -Syu --noconfirm", fake.calls.items[3]);
    try testing.expectEqualStrings("pacman -Sg xfce4", fake.calls.items[5]);
    try testing.expect(!fake.called("sudo pacman -Syu --needed --noconfirm -- xfce4"));
}

test "install: a configured repository with no packages in it is not a short database" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured against pacman 7.1.0: a custom repository built with
    // `repo-add` and holding nothing syncs, and `pacman -Sl` then prints no
    // line for it -- the same stdout a missing database gives. A sync that
    // succeeded is what tells the two apart, so one sync is the most this
    // can cost, and the install that follows carries no `-y` of its own.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Sl", .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\nemptyrepo\n" },
        .{ .argv = "sudo pacman -Syu --noconfirm" },
        .{ .argv = "pacman -Sg ghostty", .code = 1 },
        .{ .argv = "pacman -S --print --print-format %n -- ghostty", .code = 1 },
        .{ .argv = "pacman -Qdq" },
        .{ .argv = "sudo pacman -S --needed --noconfirm -- ghostty" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{rowOf("ghostty", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expectEqual(@as(usize, 1), countCalls(&fake, "sudo pacman -Syu --noconfirm"));
    try testing.expect(fake.called("sudo pacman -S --needed --noconfirm -- ghostty"));
}

test "install: a row naming an ALPM provision is refused, naming what provides it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved on pacman 7.1.0 against fully synced databases: `cron` is in no
    // `pacman -Sl` line, `pacman -Sg cron` exits 1, `pacman -Syu --needed
    // --noconfirm -- cron` installs `cronie`, and `pacman -Qeq` reports
    // `cronie`. The row would be MISSING for ever while cronie reads
    // UNTRACKED for ever, and every apply would install it again.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Sl", .stdout = "core bat 0.25.0-1\ncore cronie 1.7.2-1\n" },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\n" },
        .{ .argv = "pacman -Sg cron", .code = 1 },
        .{ .argv = "pacman -S --print --print-format %n -- cron", .stdout = "run-parts\ncronie\n" },
        .{ .argv = "pacman -Qdq" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("cron", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"cron\" names no pacman package; it is a provision that \"cronie\" satisfies, and pacman reports only the package name, so declare that instead\n",
        w.written(),
    );
    // One row nobody can install must not keep the rest off the machine.
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- bat"));
}

test "install: the provision oracle reads the transaction's last name, never a dependency" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A dependency is installed before the package that needs it, so the
    // target is the transaction's last entry: measured on pacman 7.1.0,
    // `smtp-forwarder` prints four libraries and then `exim`, and
    // `java-runtime` sixteen and then `jdk-openjdk`.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Sl", .stdout = "core bash 5.3-1\n" },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\n" },
        .{ .argv = "pacman -Sg smtp-forwarder", .code = 1 },
        .{ .argv = "pacman -S --print --print-format %n -- smtp-forwarder", .stdout = "libidn\nlibspf2\ndb5.3\nperl\nexim\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("smtp-forwarder", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expect(!d.backend().installSpawned());
    try testing.expect(std.mem.indexOf(u8, w.written(), "a provision that \"exim\" satisfies") != null);
}

test "install: a name pacman resolves to itself is kept, dependencies and all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The transaction for a real package carries its dependencies too, and
    // the row's own name among them is what says the row is a package: on
    // pacman 7.1.0 `bat` prints three libraries and then `bat`. A database
    // that merely has not heard of the name yet answers exit 1 instead, and
    // the row stands -- only a POSITIVE resolution refuses.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Sl", .stdout = "core glibc 2.42-1\n" },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\n" },
        .{ .argv = "pacman -Sg bat", .code = 1 },
        .{ .argv = "pacman -S --print --print-format %n -- bat", .stdout = "llhttp\nlibgit2\noniguruma\nbat\n" },
        .{ .argv = "pacman -Qdq" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expectEqualStrings("", w.written());
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- bat"));
}

test "install: a group is named as a group, never as a provision" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `pacman -S --print -- <group>` resolves a group too, so the oracle
    // would refuse it with a message that names one member as its provider.
    // The group question is asked first, where the whole membership is what
    // the user needs to read.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Sl", .stdout = "extra exo 4.20.0-1\nextra garcon 4.20.0-1\n" },
        .{ .argv = "pacman-conf --repo-list", .stdout = "extra\n" },
        .{ .argv = "pacman -Sg xfce4", .stdout = "xfce4 exo\nxfce4 garcon\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("xfce4", &.{})});
    try testing.expect(std.mem.indexOf(u8, w.written(), "it is a group of 2 packages") != null);
    try testing.expect(!fake.called("pacman -S --print --print-format %n -- xfce4"));
}

test "install: a row the listing already carries asks the database nothing more" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The empty repository above can never read as complete, so asking
    // whether the database is whole on every apply would sync on every apply.
    // Nothing here has a question for it: every row is in the listing, so no
    // group and no provision is asked about, and the install's own `-Syu` is
    // the only refresh the machine pays for.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Sl", .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = "pacman -Qdq" },
        .{ .argv = "sudo pacman -Syu --needed --noconfirm -- bat" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqual(@as(usize, 3), fake.calls.items.len);
    try testing.expect(!fake.called("pacman-conf --repo-list"));
    try testing.expect(!fake.called("sudo pacman -Syu --noconfirm"));
}

test "install: a pacman listing past the cap stops the install, saying that is what happened" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `pacman -Sl` is 440 KiB on a current Arch, well inside the cap, but
    // past it mox has read no repository and no name at all.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman -Sl", .fail = error.StreamTooLong },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroQueryFailed, d.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expectEqualStrings(
        "mox: pacman: `pacman -Sl` answered with more than the 8 MiB mox reads from one query, so no row could be checked against it and nothing was installed\n",
        w.written(),
    );
    try testing.expect(!d.backend().installSpawned());
}

test "install: a pacman check reads the database and never writes to it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A machine whose database is already there is asked and left alone: a
    // check that syncs would leave the database ahead of the installed
    // packages, which Arch documents as an unsupported partial upgrade, on
    // every path that then refuses a row or fails.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman -Sl", .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\n" },
        .{ .argv = "pacman -Sg ghostty", .code = 1 },
        .{ .argv = "pacman -S --print --print-format %n -- ghostty", .code = 1 },
        .{ .argv = "sudo pacman -Syu --needed --noconfirm -- bat ghostty" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("ghostty", &.{}) });
    try testing.expectEqualStrings("pacman -Sl", fake.calls.items[1]);
    try testing.expectEqualStrings("pacman-conf --repo-list", fake.calls.items[2]);
    try testing.expectEqual(@as(usize, 6), fake.calls.items.len);
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "-Sy") == null or
        std.mem.indexOf(u8, c, "--needed") != null);
}

test "install: an unsynced pacman database is brought up by the upgrade the install was about to run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Verified against pacman 7.1.0: with no database downloaded, `pacman
    // -Sl` exits 0 with nothing at all, and no configured repository has
    // answered for it. Only then is anything done about it,
    // and what runs is the full `-Syu` -- never a bare `-Sy`, which would
    // leave the machine in the partial-upgrade state whichever way the rest
    // of this went.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman -Sl", .stdout = "", .once = true },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\nextra\n" },
        .{ .argv = "sudo pacman -Syu --noconfirm" },
        .{ .argv = "pacman -Sl", .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = "sudo pacman -S --needed --noconfirm -- bat" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqualStrings("pacman -Sl", fake.calls.items[1]);
    try testing.expectEqualStrings("pacman-conf --repo-list", fake.calls.items[2]);
    try testing.expectEqualStrings("sudo pacman -Syu --noconfirm", fake.calls.items[3]);
    try testing.expectEqualStrings("pacman -Sl", fake.calls.items[4]);
    // The check's own upgrade is the run's only one: repeating `-Syu` in the
    // install would upgrade the whole system a second time.
    try testing.expectEqualStrings("sudo pacman -S --needed --noconfirm -- bat", fake.calls.items[5]);
    try testing.expectEqual(@as(usize, 1), countCalls(&fake, "sudo pacman -Syu --noconfirm"));
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "-Sy ") == null);

    // An upgrade that fails is not an install that failed: no install ran.
    var down: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman -Sl", .stdout = "" },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\nextra\n" },
        .{ .argv = "pacman -Syu --noconfirm", .code = 1 },
    } };
    var d2: Distro = .{ .manager = .pacman, .runner = down.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroRefreshFailed, d2.backend().install(a, &.{rowOf("bat", &.{})}));
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
            .{ .argv = "apt-mark showauto" },
            .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
            .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
            .{ .argv = aptNamesCall("arm64"), .stdout = "bsdextrautils\nbsdmainutils\nsl\n" },
        } };
        var w: std.Io.Writer.Allocating = .init(a);
        var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

        try d.backend().install(a, &.{rowOf(c.name, &.{})});
        try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
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
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{
            .argv = "apt-cache madison libc6:armhf",
            .stdout = "libc6:armhf | 2.41-12+deb13u4 | http://deb.debian.org/debian trixie/main armhf Packages\n",
        },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix },
        .{ .argv = "apt-mark showauto" },
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
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = aptNamesCall("amd64"), .stdout = "" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = apt.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroQueryFailed, d.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expectEqualStrings(
        "mox: apt: `" ++ comptime aptNamesCall("amd64") ++ "` lists no packages at all, which is a machine with no repositories configured rather than a row that names none, so no row could be checked and nothing was installed\n",
        w.written(),
    );
    try testing.expect(!d.backend().installSpawned());

    // pacman's listing is empty on a machine that has never synced, so it is
    // reported only once the upgrade has run and it is still empty.
    var pac: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman -Sl", .stdout = "" },
        .{ .argv = "pacman-conf --repo-list", .stdout = "core\nextra\n" },
        .{ .argv = "pacman -Syu --noconfirm" },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = pac.runner(), .force_elevate = false, .err = &w2.writer };

    try testing.expectError(Error.DistroQueryFailed, d2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expectEqualStrings(
        "mox: pacman: `pacman -Sl` lists no packages at all, which is a machine with no repositories configured rather than a row that names none, so no row could be checked and nothing was installed\n",
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
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = aptNamesCall("amd64"), .fail = error.StreamTooLong },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroQueryFailed, d.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expectEqualStrings(
        "mox: apt: `" ++ comptime aptNamesCall("amd64") ++ "` answered with more than the 8 MiB mox reads from one query, so no row could be checked against it and nothing was installed\n",
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
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update", .code = 100 },
    } };
    var d1: Distro = .{ .manager = .apt, .runner = refresh.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroRefreshFailed, d1.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!d1.backend().installSpawned());

    var timeout: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = aptNamesCall("amd64"), .timed_out = true },
    } };
    var d2: Distro = .{ .manager = .apt, .runner = timeout.runner(), .force_elevate = false };
    try testing.expectError(error.TimedOut, d2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!d2.backend().installSpawned());

    var arch: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .code = 2 },
    } };
    var d3: Distro = .{ .manager = .apt, .runner = arch.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroQueryFailed, d3.backend().install(a, &.{rowOf("bat:armhf", &.{})}));
    try testing.expect(!d3.backend().installSpawned());

    // A batch whose every row is refused reaches no manager either: there is
    // nothing left to hand it.
    var refused: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n zlib-devel" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n zlib-devel", .stdout = "" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n --whatprovides zlib-devel", .stdout = "zlib-ng-compat-devel\n" },
    } };
    var d4: Distro = .{ .manager = .dnf, .runner = refused.runner(), .force_elevate = false };
    try d4.backend().install(a, &.{rowOf("zlib-devel", &.{})});
    try testing.expectEqual(@as(usize, 1), d4.backend().installRefused());
    try testing.expect(!d4.backend().installSpawned());

    // A manager that ran and failed part-way through is the other answer: its
    // rows may be on the machine, and a re-read must assume they are.
    var ran: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n", .match = .prefix },
        .{ .argv = "dnf install -y bat", .code = 1 },
    } };
    var d5: Distro = .{ .manager = .dnf, .runner = ran.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroInstallFailed, d5.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(d5.backend().installSpawned());

    // An adapter is asked afresh each time, never left saying what the last
    // batch did.
    var again: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n ripgrepp" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n ripgrepp", .stdout = "" },
        .{ .argv = "dnf -q repoquery --qf %{name}\n --whatprovides ripgrepp", .stdout = "" },
    } };
    d5.runner = again.runner();
    try d5.backend().install(a, &.{rowOf("ripgrepp", &.{})});
    try testing.expectEqual(@as(usize, 1), d5.backend().installRefused());
    try testing.expect(!d5.backend().installSpawned());
    // And the count is the last batch's, never the one before it.
    var clean: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q repoquery --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "dnf -q repoquery --installed --qf %{name}\n", .match = .prefix },
        .{ .argv = "dnf install -y bat" },
    } };
    d5.runner = clean.runner();
    try d5.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqual(@as(usize, 0), d5.backend().installRefused());
}

test "install: a qualifier apt reads as native is judged before the package list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `wine32` is in no `apt-cache pkgnames` listing on an arm64 machine, so
    // asking the listing first would answer this row with the regex warning
    // -- true of the bare name, and no use at all to someone who wrote
    // `:native`. The qualifier is the row's problem, and the bare name is
    // what to declare.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("wine32:native", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: apt: row \"wine32:native\" carries the qualifier \"native\", which apt resolves to this machine's own architecture and apt-mark then reports bare, so the row could never read as installed; declare \"wine32\" instead\n",
        w.written(),
    );
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "pkgnames") == null);
}

test "install: a foreign-architecture row beside a good one installs both" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on Debian trixie arm64 with armhf added: `apt-cache --generate
    // pkgnames` lists neither `wine32` nor `wine32:armhf`, while apt installs
    // `wine32:armhf` and `apt-mark showmanual` reports exactly that. Judged
    // by the listing, the row is refused -- and with the batch refused with
    // it, `sl` never lands either.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "sl\nbat\n" },
        .{
            .argv = "apt-cache madison wine32:armhf",
            .stdout = "wine32:armhf | 10.0~repack-6 | http://deb.debian.org/debian trixie/main armhf Packages\n",
        },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- wine32:armhf sl" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{ rowOf("wine32:armhf", &.{}), rowOf("sl", &.{}) });
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- wine32:armhf sl"));
}

test "install: a bare row apt has only as a locally installed package is kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved identically on apt 2.4.14 (Ubuntu 22.04), 2.6.1 (bookworm),
    // 2.8.3 (Ubuntu 24.04) and 3.0.3 (trixie), with sources fully
    // configured: a package installed with `dpkg -i` and then marked auto is
    // absent from `apt-mark showmanual` -- so mox calls the row MISSING --
    // and absent from the repository listing, while `apt-get install -y --
    // <name>` exits 0 and marks it manually installed, after which
    // `apt-mark showmanual` reports it and the row converges.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\nsl\n" },
        .{ .argv = apt_installed_call, .stdout = "bat arm64 install ok installed\nmoxlocaldemo arm64 install ok installed\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- moxlocaldemo" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("moxlocaldemo", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expectEqualStrings("", w.written());
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- moxlocaldemo"));
}

test "install: a bare row whose package is an Architecture: all one is kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // dpkg spells such a package's architecture `all`, and apt-mark reports
    // it bare -- verified on all four apt versions, where `adduser all
    // install ok installed` is the shape every one of them prints.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\n" },
        .{ .argv = apt_installed_call, .stdout = "moxallpkg all install ok installed\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- moxallpkg" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{rowOf("moxallpkg", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
}

test "install: a bare row whose package is installed for a foreign architecture alone is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The other half of the same oracle. Proved on apt 3.0.3: an armhf .deb
    // installed on an arm64 machine answers `dpkg-query` with `armhf`, no
    // repository carries it, and `apt-get install -y -- <bare>` exits 0
    // having set `<name>:armhf` to manually installed -- which is the name
    // `apt-mark showmanual` then reports, so the bare row could never read
    // as installed.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\n" },
        .{ .argv = apt_installed_call, .stdout = "moxforeigndemo armhf install ok installed\n" },
        .{ .argv = "apt-cache madison moxforeigndemo", .stdout = "" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("moxforeigndemo", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: apt: row \"moxforeigndemo\" names an apt package for the architecture \"armhf\" alone, which apt-mark reports as \"moxforeigndemo:armhf\", so the row could never read as installed; declare \"moxforeigndemo:armhf\" instead\n",
        w.written(),
    );
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "apt-get install") == null);
}

test "install: a package removed but left in config-files is not a row apt would install" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on all four apt versions: `apt-get install` of such a name
    // that no repository carries exits 100 with "Unable to locate package",
    // so only a package dpkg calls `installed` answers for a row.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\n" },
        .{ .argv = apt_installed_call, .stdout = "moxgonedemo arm64 deinstall ok config-files\n" },
        .{ .argv = "apt-cache madison moxgonedemo", .stdout = "" },
        .{ .argv = "apt-cache showpkg moxgonedemo", .stdout = "" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("moxgonedemo", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: apt: row \"moxgonedemo\" names no apt package; apt-get would read it as a regular expression and install every package it matched, so it was not installed\n",
        w.written(),
    );
}

test "install: apt names what provides a virtual name rather than warning about a regex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on apt 2.4.14 and 3.0.3: `a52dec` is no package, and
    // `apt-get install -s -- a52dec` installs `liba52-0.7.4-dev`, which
    // apt-mark reports under its own name -- the row missing and that
    // package untracked for ever. Debian trixie carries 64492 names that are
    // a capability with exactly one provider, so no regex is involved and
    // saying one is would send the user looking for the wrong thing.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\nliba52-0.7.4-dev\n" },
        .{ .argv = apt_installed_call, .stdout = "bat arm64 install ok installed\n" },
        .{ .argv = "apt-cache madison a52dec", .stdout = "" },
        .{
            .argv = "apt-cache showpkg a52dec",
            .stdout =
            \\Package: a52dec
            \\Versions: 
            \\
            \\Reverse Depends: 
            \\  liba52-0.7.4-dev,a52dec
            \\Dependencies: 
            \\Provides: 
            \\Reverse Provides: 
            \\liba52-0.7.4-dev 0.7.4-20+b3 (= )
            \\
            ,
        },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("a52dec", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: apt: row \"a52dec\" names no apt package; it is a virtual name provided by \"liba52-0.7.4-dev\", and apt-mark reports only a package's own name, so declare the one you want instead\n",
        w.written(),
    );
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "apt-get install") == null);
}

test "install: showpkg answers about a regex, so only the stanza this row names is read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `apt-cache showpkg ruby.dev` prints 13 stanzas on trixie and 8 on
    // Ubuntu 22.04, none of them named `ruby.dev`, so the row is the regex
    // case and must be told so.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\n" },
        .{ .argv = apt_installed_call, .stdout = "bat arm64 install ok installed\n" },
        .{ .argv = "apt-cache madison ruby.dev", .stdout = "" },
        .{
            .argv = "apt-cache showpkg ruby.dev",
            .stdout =
            \\Package: ruby-dev
            \\Versions: 
            \\1:3.1 (/var/lib/apt/lists/x_Packages)
            \\Reverse Provides: 
            \\somethingelse 1.0 (= )
            \\Package: ruby-devise
            \\Versions: 
            \\Reverse Provides: 
            \\another 2.0 (= )
            \\
            ,
        },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("ruby.dev", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: apt: row \"ruby.dev\" names no apt package; apt-get would read it as a regular expression and install every package it matched, so it was not installed\n",
        w.written(),
    );
}

test "install: a qualified row whose package is installed for that architecture alone is kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The spelling the refusal above tells the user to write. No repository
    // carries it, so madison answers nothing; dpkg has it under armhf, and
    // `apt-get install -- <name>:armhf` marks that package manual, which is
    // the name apt-mark reports.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = "apt-cache madison moxforeigndemo:armhf", .stdout = "" },
        .{ .argv = apt_installed_call, .stdout = "moxforeigndemo armhf install ok installed\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- moxforeigndemo:armhf" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{rowOf("moxforeigndemo:armhf", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- moxforeigndemo:armhf"));
}

test "install: a bare row apt has only for a foreign architecture is refused, naming the qualified spelling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved against apt 3.0.3 (trixie), 2.8.3 (Ubuntu 24.04) and 2.6.1
    // (bookworm), each arm64 with armhf added: the plain listing prints
    // `armv8-support` BARE even though only the armhf index carries it, and
    // `apt-get install -y -- armv8-support` exits 0 having installed
    // `armv8-support:armhf`, which `apt-mark showmanual` reports under that
    // qualified name -- so the row is missing and the package untracked on
    // every run after, and every apply installs it again.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\nsl\n" },
        .{ .argv = apt_installed_call, .stdout = "bat arm64 install ok installed\n" },
        .{
            .argv = "apt-cache madison armv8-support",
            .stdout = "armv8-support:armhf |         27 | http://deb.debian.org/debian trixie/main armhf Packages\n",
        },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- sl" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("armv8-support", &.{}), rowOf("sl", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: apt: row \"armv8-support\" names an apt package for the architecture \"armhf\" alone, which apt-mark reports as \"armv8-support:armhf\", so the row could never read as installed; declare \"armv8-support:armhf\" instead\n",
        w.written(),
    );
    // The refused row never reached apt-get, and the row beside it did.
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- sl"));
}

test "install: the bare-name listing asks for the native architecture alone, and for no dpkg status" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Each option closes a hole measured on apt 2.6.1, 2.8.3 and 3.0.3. The
    // architecture option drops the 78 armhf-only names the plain listing
    // prints bare on trixie; the status option drops the dpkg status file,
    // which prints an already-installed foreign package bare and keeps the
    // listing non-empty (78 lines on trixie, 88 on bookworm) on a machine
    // with no repositories at all.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = aptNamesCall("amd64"), .stdout = "bat\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(fake.called(
        "apt-cache -o APT::Architectures=amd64 -o Dir::State::status=/dev/null --generate pkgnames",
    ));
}

test "install: apt refuses a held row and installs the rest of the batch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved on apt 3.0.3: with `sl` held, `apt-get install -y -qq -- sl bat`
    // exits 100 with "Held packages were changed and -y was used without
    // --allow-change-held-packages" and `bat` does not land either. The hold
    // is the user's decision, so the row goes rather than the hold.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = aptNamesCall("amd64"), .stdout = "bat\nsl\n" },
        .{ .argv = "apt-mark showhold", .stdout = "sl\n" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = "bat:\n  Installed: (none)\n  Candidate: 0.25.0-2\n" },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("sl", &.{}), rowOf("bat", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: apt: row \"sl\" names a package apt-mark holds, and an install carrying a held package installs nothing at all, so it was not installed; `apt-mark unhold sl` to let mox install it\n",
        w.written(),
    );
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat"));
    // The hold is never overridden.
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "allow-change-held-packages") == null);
}

test "install: apt refuses a row a pin leaves no candidate for, and installs the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved on apt 3.0.3: with `Pin-Priority: -1` on cowsay, `apt-cache
    // policy cowsay` answers `Candidate: (none)` and `apt-get install -y -qq
    // -- cowsay bat` exits 100 with "Package 'cowsay' has no installation
    // candidate", leaving `bat` uninstalled too.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = aptNamesCall("amd64"), .stdout = "bat\ncowsay\n" },
        .{ .argv = "apt-mark showhold" },
        .{
            .argv = "apt-cache policy cowsay bat",
            .stdout =
            \\cowsay:
            \\  Installed: (none)
            \\  Candidate: (none)
            \\  Version table:
            \\     3.03+dfsg2-8 -1
            \\        500 http://deb.debian.org/debian trixie/main amd64 Packages
            \\bat:
            \\  Installed: (none)
            \\  Candidate: 0.25.0-2+b2
            \\  Version table:
            \\     0.25.0-2+b2 500
            \\        500 http://deb.debian.org/debian trixie/main amd64 Packages
            \\
            ,
        },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("cowsay", &.{}), rowOf("bat", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: apt: row \"cowsay\" names a package apt has no installation candidate for, which a pin in apt's preferences does, and an install carrying it installs nothing at all, so it was not installed\n",
        w.written(),
    );
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat"));
}

test "install: a qualified row is judged by its own policy stanza, which carries the architecture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on apt 3.0.3: `apt-cache policy libc6:armhf` heads its stanza
    // `libc6:armhf:`, which is how the row spells it, so a pin on the foreign
    // package is read against the right row.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{
            .argv = "apt-cache madison libc6:armhf",
            .stdout = "libc6:armhf | 2.41-12+deb13u4 | http://deb.debian.org/debian trixie/main armhf Packages\n",
        },
        .{ .argv = "apt-mark showhold" },
        .{
            .argv = "apt-cache policy libc6:armhf",
            .stdout = "libc6:armhf:\n  Installed: (none)\n  Candidate: (none)\n",
        },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("libc6:armhf", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expect(std.mem.indexOf(u8, w.written(), "row \"libc6:armhf\" names a package apt has no installation candidate for") != null);
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "apt-get install") == null);
}

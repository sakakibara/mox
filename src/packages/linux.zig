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
    /// pacman's install did not complete. Its own error because a pacman
    /// install is the whole-system upgrade pacman requires of one, so what
    /// stopped it may be a package no row declares.
    DistroUpgradeInstallFailed,
    /// apt resolves against one architecture and dpkg reports another, so
    /// neither half of the apt oracle answers for this machine. Its own error
    /// because nothing was asked of apt that it failed to answer: it answered,
    /// about a machine other than this one.
    DistroArchitectureDisagrees,
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
            // read as a package name. `--assumeno` for the reason
            // `dnf_names_argv` gives.
            .dnf => &.{ "dnf", "-q", "--assumeno", "repoquery", "--userinstalled", "--qf", "%{name}\n" },
            .pacman => &.{ "pacman", "-Qeq" },
        };
    }

    /// What this manager's install asks the manager itself about a row, in
    /// the order it asks, for a dry run to name as what it did not check.
    fn installCheck(self: Manager) []const u8 {
        return switch (self) {
            .apt => "what apt has installed as a dependency, apt's own package list, what dpkg has installed, its holds and its pins",
            .dnf => "what dnf already has installed, and the packages and provisions its repositories carry",
            .pacman => "what pacman has installed as a dependency, the packages, groups and provisions its repositories carry, and what those packages and the installed ones declare conflicts with",
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

    /// apt's answer is intersected with what dpkg has installed AND
    /// configured: `apt-mark showmanual` lists a package an interrupted run
    /// left `install ok unpacked`, which is on the disk and not set up, and
    /// a row reading clean over it would never be finished. Measured on apt
    /// 2.6.1 and 3.0.3 with `sl` unpacked by `dpkg --unpack` over its
    /// installed self: `apt-mark showmanual` prints `sl`, `dpkg-query`
    /// answers `sl arm64 install ok unpacked`, and `apt-get install -y --
    /// sl` exits 0 printing `Setting up sl`, after which dpkg calls it
    /// `installed`. So the row reads missing, and the install configures it.
    fn installedExplicitImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *Distro = @ptrCast(@alignCast(ctx));
        const res = try self.runner.run(arena, self.manager.queryArgv());
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;
        const machine: ?AptMachine = if (self.manager == .apt) try self.aptMachine(arena) else null;

        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (machine) |m| {
                if (!m.hasConfigured(line)) continue;
            }
            // dnf writes prose onto the stdout this reads names from, so a
            // line that is not a package name is the manager talking; every
            // name here is offered to the user as one to record.
            if (self.manager == .dnf and backend_mod.nameProblem(line, self.manager.nameClass()) != null) continue;
            try out.append(arena, line);
        }
        return out.toOwnedSlice(arena);
    }

    /// The whole set in one invocation: these managers resolve a batch in a
    /// single pass, and pacman's install is a full system upgrade, so
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
        if (rows.len == 0) return;

        const elevate = self.elevates();

        const machine: ?AptMachine = if (self.manager == .apt) try self.aptMachine(arena) else null;
        const present = try self.installedAlready(arena, rows, machine);
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
            .apt => try self.refuseAptUninstallable(arena, try self.refuseAptNonNames(arena, to_resolve.items, machine.?)),
            .dnf => try self.refuseDnfNonPackages(arena, to_resolve.items),
            .pacman => try self.refusePacmanNonPackages(arena, to_resolve.items, elevate),
        };
        self.refused = to_resolve.items.len - to_install.len;
        if (to_install.len == 0) return;

        var argv: std.ArrayList([]const u8) = .empty;
        if (elevate) try argv.append(arena, "sudo");
        if (self.manager == .apt) try argv.appendSlice(arena, &apt_env);
        // pacman's install is one `-Syu` transaction with the rows as its
        // targets, never a sync-and-upgrade followed by a `-S`: measured on
        // pacman 7.1.0 with a repository whose upgrade of `a` newly depends
        // on `foo`, `-Syu` then `-S --needed -- foo` leaves foo "Installed
        // as a dependency" (the second step skips it as up to date), so the
        // row reads MISSING on every status after, while `-Syu --needed --
        // foo` leaves it "Explicitly installed", being a target of the
        // transaction that installs it.
        //
        // dnf carries `--setopt=assumeno=0` because a dnf.conf `assumeno=True`
        // outranks `-y`: measured on dnf 4.14.0, dnf5 5.2.18 and 5.4.3, `dnf
        // install -y` under it exits 1 with "Operation aborted." (dnf4) or
        // "Operation aborted by the user." (dnf5) having installed nothing,
        // and with the option each installs.
        const head: []const []const u8 = switch (self.manager) {
            .apt => &.{ "apt-get", "install", "-y" },
            .dnf => &.{ "dnf", "install", "-y", "--setopt=assumeno=0" },
            .pacman => &.{ "pacman", "-Syu", "--needed", "--noconfirm" },
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
        if (res.ok) return;
        // The manager's own message says what stopped it, on the terminal
        // above; this says which rows were in the batch it stopped, since
        // the run counts the batch as one failure.
        var list: std.Io.Writer.Allocating = .init(arena);
        for (to_install, 0..) |row, i| {
            if (i > 0) try list.writer.writeAll(", ");
            try list.writer.print("\"{s}\"", .{row.name});
        }
        self.say(
            "mox: {s}: the batch of {s} failed as one; {s}'s own message above says which row stopped it\n",
            .{ self.manager.name(), list.written(), self.manager.name() },
        );
        return if (self.manager == .pacman) Error.DistroUpgradeInstallFailed else Error.DistroInstallFailed;
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
    ///
    /// apt's set is intersected with what dpkg has configured, as the
    /// explicit query's is: a package left `install ok unpacked` is one
    /// `apt-mark manual` leaves unpacked (measured on apt 2.6.1 and 3.0.3),
    /// while `apt-get install -y -- <name>` on it prints "already the newest
    /// version", sets it manual and configures it.
    fn installedAlready(self: *Distro, arena: std.mem.Allocator, rows: []const Row, machine: ?AptMachine) anyerror!std.StringHashMap(void) {
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
            if (machine) |m| {
                if (!m.hasConfigured(line)) continue;
            }
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
                    &[_][]const u8{ "dnf", "mark", "user", "-y", "--setopt=assumeno=0" }
                else
                    &[_][]const u8{ "dnf", "mark", "install", "--setopt=assumeno=0" };
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
    /// `-y` the install does, and the same `--setopt=assumeno=0`: under a
    /// dnf.conf `assumeno=True`, `dnf mark user -y` exits 1 with "Operation
    /// aborted by the user." and marks nothing (measured on 5.2.18 and
    /// 5.4.3), and with the option it marks. dnf4's mark asks nothing and
    /// takes the option all the same (measured on 4.14.0).
    fn dnfIsFive(self: *Distro, arena: std.mem.Allocator) anyerror!bool {
        const res = try self.runner.run(arena, &.{ "dnf", "--version" });
        try exec.checkCaptureTimedOut(res);
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
    /// for them. `-q`, `--assumeno` and the trailing newline for the reasons
    /// `queryArgv` and `dnf_names_argv` give; no `--` for the reason the
    /// install argv gives. An operand rpm has nothing for contributes no line
    /// and does not fail the query (measured on dnf 4.14.0, dnf5 5.2.18 and
    /// 5.4.3).
    const dnf_installed_argv = [_][]const u8{ "dnf", "-q", "--assumeno", "repoquery", "--installed", "--qf", "%{name}\n" };

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
    /// - `APT::Cache::AllNames=false` keeps virtual names out whatever
    ///   apt.conf says. With `APT::Cache::AllNames "true"` configured the
    ///   listing prints `awk` (119883 lines against 62840 on bookworm), a
    ///   name `apt-cache policy` answers `Candidate: (none)` for, so the row
    ///   would be refused as pinned instead of told what provides it.
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
            "-o",
            "APT::Cache::AllNames=false",
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
    ///
    /// A qualified row naming an architecture dpkg has not enabled is kept
    /// only when dpkg has the package installed under it (`dpkg -i
    /// --force-architecture` leaves one there, and `apt-get install` on it
    /// exits 0 and marks it manual, measured on apt 2.6.1 and 3.0.3). A
    /// repository can still carry the name -- a flat one holds every
    /// architecture in a single index, and apt 3.0.3 lists such a package
    /// with a candidate -- but the install then fails at dpkg with "package
    /// architecture (i386) does not match system (arm64)", taking the batch
    /// with it.
    fn refuseAptNonNames(self: *Distro, arena: std.mem.Allocator, rows: []const Row, machine: AptMachine) anyerror![]const Row {
        // The listing is made only if a row needs it: it costs a megabyte and
        // a rebuild of apt's cache, and a batch of qualified rows alone never
        // reads it.
        var known: ?std.StringHashMap(void) = null;
        var foreign: ?std.StringHashMap(void) = null;
        const native = machine.native;
        const installed = machine.installed;

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
                if (hasArch(installed, bare, arch)) {
                    try keep.append(arena, row);
                    continue;
                }
                if (foreign == null) foreign = try self.aptForeignArches(arena);
                if (!foreign.?.contains(arch)) {
                    self.say(
                        "mox: apt: row \"{s}\" qualifies the architecture \"{s}\", which this machine's dpkg has not enabled and has no package installed under, so it was not installed; `dpkg --add-architecture {s}` to let mox install it\n",
                        .{ row.name, arch, arch },
                    );
                    continue;
                }
                if ((try self.aptArchesOf(arena, row.name, native)).len > 0) {
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
            // A package installed under the architecture apt-mark reports
            // bare -- this machine's own, or `all` -- is installed under the
            // row's own spelling, and apt-get marks it manual rather than
            // reaching for a regex.
            if (hasArch(installed, bare, native) or hasArch(installed, bare, "all")) {
                try keep.append(arena, row);
                continue;
            }
            // Only a foreign architecture can be suggested: a native one is
            // what the listing already answered for, and spelling it would
            // send the user to a row apt-mark reports bare.
            if (try self.aptForeignArchOf(arena, row.name, native, installed)) |arch| {
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
    /// A flat repository (`deb [trusted=yes] file:/repo ./`) has one index
    /// for every architecture, and its line is `<name> | <version> | <url>
    /// ./ Packages` -- the word before the last is the suite, which ends in
    /// `/`, and the architecture is in the name column instead: measured on
    /// apt 2.6.1 and 3.0.3, `mox-flat-armhf:armhf |        1.0 | file:/repo
    /// ./ Packages` for an armhf package and `mox-flat-native |        1.0 |
    /// file:/repo ./ Packages` for a native one.
    ///
    /// Only a line naming a binary index counts: with `deb-src` configured
    /// madison prints a `Sources` line too, and a source package is nothing
    /// `apt-get install` can put on the machine.
    fn aptArchesOf(self: *Distro, arena: std.mem.Allocator, name: []const u8, native: []const u8) anyerror![]const []const u8 {
        const res = try self.runner.run(arena, &.{ "apt-cache", "madison", name });
        try exec.checkCaptureTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;

        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.endsWith(u8, line, " Packages")) continue;
            const head = line[0 .. line.len - " Packages".len];
            const space = std.mem.lastIndexOfScalar(u8, head, ' ') orelse continue;
            var arch = head[space + 1 ..];
            if (arch.len == 0) continue;
            if (std.mem.endsWith(u8, arch, "/")) {
                const bar = std.mem.indexOfScalar(u8, line, '|') orelse continue;
                const spelled = std.mem.trim(u8, line[0..bar], " \t");
                arch = backend_mod.archOf(spelled) orelse native;
            }
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
        try exec.checkCaptureTimedOut(res);
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
        try exec.checkCaptureTimedOut(res);
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
    ///
    /// The same query settles what a bare row from a FLAT repository would
    /// land, which the package listing cannot: a flat index carries every
    /// architecture, so the native listing prints its foreign-only names bare
    /// (measured on apt 2.6.1, 2.8.3 and 3.0.3 with armhf added and an index
    /// from dpkg-scanpackages holding an armhf and an i386 package: both
    /// listed). `apt-cache policy` heads the armhf package's stanza
    /// `mox-flat-armhf:armhf:`, and `apt-get install -y -- mox-flat-armhf`
    /// installs `mox-flat-armhf:armhf`, which apt-mark reports qualified --
    /// so the row is refused with that spelling, as a foreign-only name
    /// from any other index is. The i386 package, whose architecture dpkg
    /// has not enabled, is refused too: apt 2.6.1 answers no stanza for it
    /// and its install "Unable to locate package", apt 3.0.3 answers a
    /// stanza headed `mox-flat-i386:i386:` and its install fails at dpkg
    /// with "package architecture (i386) does not match system (arm64)" --
    /// and either way the batch it is in installs nothing.
    ///
    /// No stanza at all says only that apt could not resolve the operand,
    /// which is why the refusal for it names nothing narrower. Measured on
    /// apt 2.6.1 and 3.0.3: `mox-no-such-package`, `sl:notanarch` and
    /// `foo:bar:baz` each print zero bytes and exit 0, while the two
    /// conditions a package can be in and still not install DO print a
    /// stanza -- a purely virtual name heads `awk:` with `Candidate:
    /// (none)`, and a package built for an architecture alone heads
    /// `care:armhf:` -- and are refused on the branches below.
    fn refuseAptUninstallable(self: *Distro, arena: std.mem.Allocator, rows: []const Row) anyerror![]const Row {
        if (rows.len == 0) return rows;
        const held = try self.aptHeld(arena);
        const stanzas = try self.aptStanzas(arena, rows);
        var foreign: ?std.StringHashMap(void) = null;

        var keep: std.ArrayList(Row) = .empty;
        for (rows, stanzas) |row, answer| {
            if (held.contains(row.name)) {
                self.say(
                    "mox: apt: row \"{s}\" names a package apt-mark holds, and an install carrying a held package installs nothing at all, so it was not installed; `apt-mark unhold {s}` to let mox install it\n",
                    .{ row.name, row.name },
                );
                continue;
            }
            const stanza = answer orelse {
                self.say(
                    "mox: apt: row \"{s}\" names a package apt-cache policy prints no stanza for, which is an operand apt cannot locate at all, and an install carrying one installs nothing at all, so it was not installed\n",
                    .{row.name},
                );
                continue;
            };
            if (backend_mod.archOf(stanza.header)) |arch| {
                if (backend_mod.archOf(row.name) == null) {
                    if (foreign == null) foreign = try self.aptForeignArches(arena);
                    if (foreign.?.contains(arch)) {
                        self.say(
                            "mox: apt: row \"{s}\" names an apt package for the architecture \"{s}\" alone, which apt-mark reports as \"{s}:{s}\", so the row could never read as installed; declare \"{s}:{s}\" instead\n",
                            .{ row.name, arch, row.name, arch, row.name, arch },
                        );
                    } else {
                        self.say(
                            "mox: apt: row \"{s}\" names an apt package for the architecture \"{s}\" alone, which this machine's dpkg has not enabled, so an install carrying it fails at dpkg and installs nothing at all, and it was not installed; `dpkg --add-architecture {s}` and declare \"{s}:{s}\" to let mox install it\n",
                            .{ row.name, arch, arch, row.name, arch },
                        );
                    }
                    continue;
                }
            }
            if (!stanza.candidate) {
                self.say(
                    "mox: apt: row \"{s}\" names a package apt has no installation candidate for, which a pin in apt's preferences does, and an install carrying it installs nothing at all, so it was not installed\n",
                    .{row.name},
                );
                continue;
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
        try exec.checkCaptureTimedOut(res);
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

    /// What `apt-cache policy` says of one package: the name at the head of
    /// its stanza, which is the name apt resolved the operand to, and
    /// whether apt has a version to install.
    const Stanza = struct {
        header: []const u8,
        candidate: bool,
    };

    /// Each row's policy stanza, asked for the whole batch at once, or null
    /// where apt printed none.
    ///
    /// `apt-cache policy` prints a stanza per package: a header at column
    /// zero -- the name apt resolves the operand to, then a `:` -- and
    /// indented lines, of which `Candidate:` is the version apt would
    /// install or `(none)`. It falls back to a regex only when no package is
    /// named exactly, and every row reaching here named one.
    ///
    /// The stanzas come in operand order, and an operand apt cannot locate
    /// gets none -- nothing on stdout, nothing on stderr, exit 0 (measured
    /// on apt 2.6.1 and 3.0.3 with a nonexistent name among real ones) --
    /// so they are matched to the rows in order, each row taking the next
    /// stanza that answers it. A stanza answers a row when its header is the
    /// row's name, or, for a bare row, the row's name qualified: that is
    /// how apt heads a package a flat index holds for a foreign
    /// architecture alone.
    ///
    /// `Candidate:` is the C-locale spelling, which the captured call runs
    /// under; measured on apt 3.0.3 under `LANG=ja_JP.UTF-8`, the same line
    /// is printed in Japanese and would match nothing here.
    fn aptStanzas(self: *Distro, arena: std.mem.Allocator, rows: []const Row) anyerror![]const ?Stanza {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "apt-cache", "policy" });
        for (rows) |row| try argv.append(arena, row.name);
        const res = try self.runner.run(arena, argv.items);
        try exec.checkCaptureTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;

        var printed: std.ArrayList(Stanza) = .empty;
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (line[0] != ' ' and line[0] != '\t') {
                if (std.mem.endsWith(u8, line, ":")) {
                    try printed.append(arena, .{ .header = line[0 .. line.len - 1], .candidate = false });
                }
                continue;
            }
            const field = std.mem.trimStart(u8, line, " \t");
            const value = stringAfter(field, "Candidate:") orelse continue;
            if (printed.items.len == 0) continue;
            printed.items[printed.items.len - 1].candidate = !std.mem.eql(u8, value, "(none)");
        }

        const out = try arena.alloc(?Stanza, rows.len);
        var next: usize = 0;
        for (rows, out) |row, *slot| {
            slot.* = null;
            var i = next;
            while (i < printed.items.len) : (i += 1) {
                if (stanzaAnswers(printed.items[i].header, row.name)) {
                    slot.* = printed.items[i];
                    next = i + 1;
                    break;
                }
            }
        }
        return out;
    }

    fn stanzaAnswers(header: []const u8, name: []const u8) bool {
        if (std.mem.eql(u8, header, name)) return true;
        if (backend_mod.archOf(name) != null) return false;
        return header.len > name.len and std.mem.startsWith(u8, header, name) and header[name.len] == ':';
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
        for (try self.aptArchesOf(arena, name, native)) |arch| {
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
        try exec.checkCaptureTimedOut(res);
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
        try exec.checkCaptureTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;
        return std.mem.trim(u8, res.stdout, " \t\r\n");
    }

    /// The architecture apt itself resolves against, or null where apt names
    /// none at all.
    ///
    /// `apt-config dump APT::Architecture` answers with one line, `APT::Architecture
    /// "<arch>";`, and with nothing at all for a key apt has no value for
    /// (exit 0 either way). Measured identically on apt 2.6.1 (bookworm) and
    /// 3.0.3 (trixie), arm64 with armhf added, unset and set alike. The
    /// plural `APT::Architectures` is a sibling node rather than a child, so
    /// it is not in this answer, and its own lines are `APT::Architectures
    /// "";` followed by one `APT::Architectures:: "<arch>";` per
    /// architecture -- neither of which starts with the singular key and a
    /// space.
    ///
    /// Only the singular key can put apt on another machine's architecture.
    /// apt forces its own into the plural list whatever the configuration
    /// says: with `APT::Architectures { "armhf"; };` configured on an arm64
    /// machine, both versions dump `arm64` then `armhf`, `apt-cache policy
    /// sl` still heads an arm64 candidate and `apt-get install -y -- sl`
    /// installs the arm64 package, which `apt-mark showmanual` then reports
    /// bare.
    fn aptConfiguredArch(self: *Distro, arena: std.mem.Allocator) anyerror!?[]const u8 {
        const res = try self.runner.run(arena, &apt_arch_argv);
        try exec.checkCaptureTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;

        const key = "APT::Architecture ";
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, key)) continue;
            const rest = std.mem.trimStart(u8, line[key.len..], " \t");
            if (rest.len == 0 or rest[0] != '"') continue;
            const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse continue;
            const arch = rest[1..end];
            if (arch.len == 0) continue;
            return arch;
        }
        return null;
    }

    /// The architectures dpkg has enabled beside the native one, one per
    /// line. A machine with none prints nothing and exits 0 (measured on
    /// apt 2.6.1 and 3.0.3).
    fn aptForeignArches(self: *Distro, arena: std.mem.Allocator) anyerror!std.StringHashMap(void) {
        const res = try self.runner.run(arena, &.{ "dpkg", "--print-foreign-architectures" });
        try exec.checkCaptureTimedOut(res);
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

    /// What dpkg says of this machine: its native architecture, and the
    /// architectures each installed package is configured under.
    const AptMachine = struct {
        native: []const u8,
        installed: Arches,

        /// Whether the package apt-mark spells `name` -- bare for the native
        /// architecture and for `all`, `name:<arch>` for a foreign one -- is
        /// installed and configured here.
        fn hasConfigured(self: AptMachine, name: []const u8) bool {
            const bare = backend_mod.bareName(name);
            if (backend_mod.archOf(name)) |arch| return hasArch(self.installed, bare, arch);
            return hasArch(self.installed, bare, self.native) or hasArch(self.installed, bare, "all");
        }
    };

    /// What dpkg says of this machine, refused whole where apt is answering
    /// about a different one.
    ///
    /// Both halves of the apt oracle key on dpkg's architecture -- the
    /// bare-name listing is generated for it, the qualifier rules judge
    /// against it, and apt-mark's bare spelling is what it means -- so apt
    /// resolving against another architecture makes every one of them answer
    /// about a machine that is not this one. Measured on apt 2.6.1 and 3.0.3,
    /// arm64 with armhf added and `APT::Architecture "armhf";` configured:
    /// `apt-cache policy sl` heads the stanza bare over an armhf-only version
    /// table and madison reports the armhf line alone, so nothing in the parse
    /// notices; the row passes every refusal and `apt-get install -y -- sl`
    /// then fails on `libc6`, `libncurses6` and `libtinfo6`, taking every
    /// other row of the batch with it, identically on every apply after. The
    /// same setting makes `apt-mark showmanual` print a set no row declares
    /// and dpkg has as dependencies -- 10 names on bookworm and 9 on trixie
    /// where an untouched machine prints none -- each of them installed and
    /// configured, so `status` would report them untracked and `commit` would
    /// write them into the manifest.
    ///
    /// Machine-level rather than per-row because no row can converge under it
    /// and none of them caused it: the same message per row would say a
    /// hundred times what one setting did once, and would still leave the
    /// installed set wrong.
    fn aptMachine(self: *Distro, arena: std.mem.Allocator) anyerror!AptMachine {
        const native = try self.aptNativeArch(arena);
        if (try self.aptConfiguredArch(arena)) |configured| {
            if (!std.mem.eql(u8, configured, native)) {
                self.say(
                    "mox: apt: apt's own APT::Architecture is \"{s}\" while dpkg's architecture is \"{s}\", so apt resolves every row against packages dpkg cannot install and no row on this machine could converge; unset APT::Architecture so apt agrees with `dpkg --print-architecture`\n",
                    .{ configured, native },
                );
                return Error.DistroArchitectureDisagrees;
            }
        }
        return .{
            .native = native,
            .installed = try self.aptInstalledArches(arena),
        };
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
                // An excluded package answers the same as an absent one:
                // measured with `excludepkgs=jq` in dnf.conf on dnf 4.14.0,
                // 5.2.18 and 5.4.3, `repoquery jq` and `--whatprovides jq`
                // both print nothing, and only dnf4 has a flag that lifts
                // the exclude for one query (`--disableexcludes=all`; both
                // dnf5 releases reject that spelling and `--disable-excludes`
                // alike). So the two are not told apart, and the message
                // names both.
                self.say(
                    "mox: dnf: row \"{s}\" names no package dnf will install here: no enabled repository carries it, or an exclude in dnf's configuration keeps it out\n",
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
    ///
    /// `--assumeno` because dnf4 otherwise writes a QUESTION to the stdout
    /// this reads names from: whether to import a repository's signing key.
    /// Measured on dnf 4.14.0 (rockylinux:9) with `repo_gpgcheck=1` and
    /// `skip_if_unavailable=1` on one repository whose key rpm has not
    /// imported -- both are settable per repository and in dnf.conf, where
    /// they hold for every one -- `dnf -q repoquery --qf '%{name}\n' jq`
    /// exits 0 having written `Is this ok [y/N]: jq\n\n`. The question ends
    /// without a newline of its own, so the listing's first name is glued to
    /// it and lost with it; with every repository so configured the whole of
    /// stdout is the question repeated. Without `skip_if_unavailable` the
    /// query exits non-zero instead, which is already read as a query that
    /// could not run.
    ///
    /// Not `-y`, which answers that question rather than declining it: with
    /// every repository so configured it takes the same listing from 0 names
    /// to 5735, having said yes on the machine's behalf to a key rpm does not
    /// hold. Accepting a signing key is the administrator's decision, never a
    /// listing's.
    ///
    /// The option is neutral otherwise. Measured over every name, the
    /// installed listing and the `--userinstalled` listing on dnf 4.14.0,
    /// dnf5 5.2.18 and 5.4.3: exit 0 and byte-identical output with it and
    /// without it (12076, 72747 and 69627 lines). Both dnf5 releases take
    /// the option, so one argv serves the pair.
    const dnf_names_argv = [_][]const u8{ "dnf", "-q", "--assumeno", "repoquery", "--qf", "%{name}\n" };

    /// A line that is not a package name is not read as one: the manager's
    /// stdout is a listing, and anything else on it is the manager talking.
    fn dnfNameSet(self: *Distro, arena: std.mem.Allocator, argv: []const []const u8) anyerror!std.StringHashMap(void) {
        const res = try self.runner.run(arena, argv);
        try exec.checkCaptureTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;

        var set = std.StringHashMap(void).init(arena);
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (backend_mod.nameProblem(line, self.manager.nameClass()) != null) continue;
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

    /// What follows `prefix` in `line`, trimmed, or null when `line` does not
    /// begin with it.
    fn stringAfter(line: []const u8, prefix: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, line, prefix)) return null;
        return std.mem.trim(u8, line[prefix.len..], " \t");
    }

    /// mox's own copy of pacman's sync database, in the layout `--dbpath`
    /// wants: `sync/` beside a `local` that is a symlink to the system's.
    ///
    /// A check never mutates the system. Every question the pacman check
    /// asks is answered by a sync database, and the system's is whatever
    /// the machine last synced -- absence from it says nothing about a row
    /// -- while a bare `pacman -Sy` that brought it forward would leave it
    /// ahead of the installed packages, the state Arch documents as an
    /// unsupported partial upgrade, on every path that then refuses a row.
    /// So the check syncs a copy of its own, the way `checkupdates` from
    /// pacman-contrib does, and reads that: measured on pacman 7.1.0,
    /// `pacman -Sy --dbpath <here> --logfile /dev/null` writes under this
    /// path alone, and `/var/lib/pacman/sync` and `pacman.log` are what they
    /// were.
    ///
    /// Under `/var/cache` rather than mox's per-user state directory,
    /// because pacman 7 downloads as its `DownloadUser` (`alpm` on Arch):
    /// measured on the same pacman, an elevated sync into a dbpath under a
    /// home directory of mode 0700 -- Arch's `HOME_MODE` default -- fails
    /// with "could not open file .../sync/download-XXXXXX/core.db.part:
    /// Permission denied", the download user having no way into the home.
    /// `checkupdates` sidesteps that with a dbpath under `/tmp` and a
    /// `fakeroot` a base install does not ship. A root-owned path under
    /// `/var/cache` is one the download user reaches and only root writes;
    /// the sync is elevated in any case, pacman refusing `-Sy` to a user
    /// whatever the dbpath ("you cannot perform this operation unless you
    /// are root", measured). The copy is kept between applies: the elevated
    /// sync leaves it root-owned, so no user could remove it, and it is the
    /// cache its path says it is.
    pub const pacman_private_db = "/var/cache/mox/pacman-db";

    /// Every package pacman's repositories carry, one per line, and the
    /// members of one group. Verified against pacman 7.1.0: `-Sl` prints
    /// `<repo> <name> <version>` per package and no group name among them
    /// (15265 lines, 440 KiB on a current Arch), and `-Sg <name>` prints
    /// `<group> <member>` per member and exits 1 on a name that is not a
    /// group. Both read `pacman_private_db`, which needs no elevation:
    /// measured as an unprivileged user against a copy root had synced,
    /// `-Sl`, `-Sg` and `-S --print` all answer.
    const pacman_names_argv = [_][]const u8{ "pacman", "-Sl", "--dbpath", pacman_private_db };

    /// The cache directory the copy lives under, made with the copy.
    pub const pacman_cache_dir = "/var/cache/mox";

    /// The one call that makes the copy, as root through `sh -c`, so a
    /// password prompt comes once, on the terminal: `$1` and `$2` are the
    /// two levels, `$3` the system's `local`, `$4` the copy's.
    ///
    /// `install -d -m 755` makes both levels, and sets 755 on each whether
    /// it made them or found them: measured with coreutils 9.11 under
    /// `umask 077`, `mkdir -p` leaves the parent 700 and `mkdir -p -m 755`
    /// repairs nothing that exists, while this creates and repairs both.
    /// 755 because pacman 7 downloads as `DownloadUser` (`alpm`), which
    /// must traverse both to reach `sync/`, and the user reads the copy
    /// unelevated: measured, a 750 copy fails the sync with "Permission
    /// denied" on every apply, the mode outliving the umask that set it.
    ///
    /// `ln -sfnT` replaces whatever stands at the copy's `local`, a
    /// directory excepted: measured with the same coreutils, `ln -sfn`
    /// against a real directory there nests the link inside it, so
    /// `readlink` fails and the make runs on every apply after, and `-T`
    /// refuses the directory with "cannot overwrite directory". A real
    /// directory there is what a sync into the copy before the link makes,
    /// empty; it is removed so the link can go in, and one with entries in
    /// it is left, with `pacman_local_kept` to say so.
    const pacman_make_script = "install -d -m 755 \"$1\" \"$2\" && { [ -L \"$4\" ] || [ ! -d \"$4\" ] || rmdir \"$4\" || exit 3; } && ln -sfnT \"$3\" \"$4\"";

    /// What the make exits when the copy's `local` is a directory with
    /// entries in it, which it leaves alone.
    const pacman_local_kept: u8 = 3;

    /// The lock file a pacman killed outright mid-sync leaves in the copy.
    const pacman_private_lock = pacman_private_db ++ "/db.lck";

    /// Bring `pacman_private_db` forward from the mirrors.
    ///
    /// pacman does not create the dbpath itself ("failed to resolve path",
    /// measured), so it is made first, and the `local` symlink goes in
    /// before the first sync: a sync into a dbpath with no `local` creates
    /// an empty directory there (measured on pacman 7.1.0). With the
    /// symlink, `-S --print` resolves against what the machine has, as the
    /// install will: `bat` prints `oniguruma` then `bat` against the real
    /// local database and its whole dependency closure against an empty
    /// one. `pacman-conf DBPath` is where the system's `local` is, which
    /// `checkupdates` reads the same way; it answers with a trailing slash.
    ///
    /// Making the copy is elevated, and only pacman need be: once the tree
    /// is there, an apply elevates `pacman -Sy` alone, so a sudoers rule
    /// that grants pacman and nothing else -- the Arch wiki's example --
    /// serves every apply after the first, and the first tells the user
    /// the one-time command when it cannot make the copy itself. The copy
    /// cannot live somewhere the user owns instead: the sync is root's,
    /// and root writing into a directory another user controls is what a
    /// symlink planted there turns into a write anywhere.
    ///
    /// The make is streamed, as the sync and the install are: a captured
    /// child has no terminal, and sudo asking it for a password stops it,
    /// which the read loop reports as killed (measured on a user sudoers
    /// grants with a password: the first apply failed, and no copy was
    /// made). Only its exit code is read.
    fn pacmanSyncPrivate(self: *Distro, arena: std.mem.Allocator, elevate: bool) anyerror!void {
        const conf = try self.runner.run(arena, &.{ "pacman-conf", "DBPath" });
        try exec.checkCaptureTimedOut(conf);
        if (!conf.ok) return Error.DistroQueryFailed;
        var db_path = std.mem.trimEnd(u8, std.mem.trim(u8, conf.stdout, " \t\r\n"), "/");
        if (db_path.len == 0) db_path = "/var/lib/pacman";
        const local = try std.fmt.allocPrint(arena, "{s}/local", .{db_path});
        const link = pacman_private_db ++ "/local";

        switch (try self.pacmanCopyProbe(arena, local)) {
            .ready => {},
            .blocked => |found| {
                self.say(
                    "mox: pacman: {s} is a {s}, not a directory, so the copy of pacman's databases the check reads at {s} cannot be made; move it aside as root, after which an apply makes the copy\n",
                    .{ found.path, found.kind, pacman_private_db },
                );
                return Error.DistroQueryFailed;
            },
            .wanting => {
                var argv: std.ArrayList([]const u8) = .empty;
                if (elevate) try argv.append(arena, "sudo");
                try argv.appendSlice(arena, &.{ "sh", "-c", pacman_make_script, "sh", pacman_cache_dir, pacman_private_db, local, link });
                const res = try self.runner.stream(arena, argv.items);
                try exec.checkTimedOut(res);
                if (!res.ok) {
                    if (res.code == pacman_local_kept) {
                        self.say(
                            "mox: pacman: {s} is a directory with entries in it, where the copy of pacman's databases the check reads keeps a link to {s}; mox removes nothing there, so move it aside as root, after which an apply makes the link\n",
                            .{ link, local },
                        );
                    } else {
                        self.say(
                            "mox: pacman: `{s}sh -c` making the copy of pacman's databases the check reads at {s} exited {d}, so the copy could not be made; make it once as root with `install -d -m 755 {s} {s} && {{ [ -L {s} ] || [ ! -d {s} ] || rmdir {s}; }} && ln -sfnT {s} {s}`, after which an apply elevates nothing but pacman\n",
                            .{ if (elevate) "sudo " else "", pacman_private_db, res.code, pacman_cache_dir, pacman_private_db, link, link, link, local, link },
                        );
                    }
                    return Error.DistroQueryFailed;
                }
            },
        }

        var sync: std.ArrayList([]const u8) = .empty;
        if (elevate) try sync.append(arena, "sudo");
        try sync.appendSlice(arena, &.{ "pacman", "-Sy", "--dbpath", pacman_private_db, "--logfile", "/dev/null" });
        const up = try self.runner.stream(arena, sync.items);
        try exec.checkTimedOut(up);
        if (up.ok) return;
        // pacman says only "unable to lock database" for a sync, and prints
        // its "you can remove" hint for a transaction alone (measured on
        // 7.1.0). An interrupt makes pacman remove the lock; a kill, an
        // out-of-memory kill or a power loss leaves it. Which of the two this
        // is cannot be decided from here: the copy is one machine-global
        // path, mox's own lock is one per state directory, and an apply under
        // another state directory syncs this same copy without taking any
        // lock this apply can see.
        if (try self.pacmanLockLeft(arena)) self.say(
            "mox: pacman: the sync of mox's database copy failed and {s} exists, which is either a pacman syncing that copy at this moment -- {s} is one path every mox on this machine shares, while the lock mox takes is one per state directory -- or one killed outright mid-sync; once no pacman is running it may be removed, as root\n",
            .{ pacman_private_lock, pacman_private_db },
        );
        return Error.DistroRefreshFailed;
    }

    const CopyProbe = union(enum) {
        ready,
        wanting,
        /// Something that is not a directory stands at one of the two
        /// levels: what `stat` calls it, and where.
        blocked: struct { path: []const u8, kind: []const u8 },
    };

    /// Whether the copy is there to sync into, as an unelevated read sees
    /// it: both levels directories readable and traversable by others
    /// (`alpm` downloads into the copy, and the user reads it), and `local`
    /// a link to where the system's is. Anything short of that, or a read
    /// that cannot be made, is left to the elevated make to make or repair,
    /// except a non-directory at either level: `install -d` fails on one
    /// with "File exists" (measured, coreutils 9.11), so it is named here
    /// instead. `stat -L` follows a symlink at either level to what it
    /// names, and `%n %a %F` reads `<path> <mode> <kind>` per line (measured:
    /// `/var/cache/mox 755 directory`; `/var/cache/mox 644 regular empty
    /// file`, and exit 1 with the level under it unreadable). Both probes
    /// capture stderr: a first apply finds nothing there, and `stat` saying
    /// so is the expected answer, not a diagnostic.
    fn pacmanCopyProbe(self: *Distro, arena: std.mem.Allocator, local: []const u8) anyerror!CopyProbe {
        const modes = try self.runner.runBoth(arena, &.{ "stat", "-L", "-c", "%n %a %F", pacman_cache_dir, pacman_private_db });
        try exec.checkCaptureTimedOut(modes);
        var seen: usize = 0;
        var traversable = true;
        var it = std.mem.tokenizeAny(u8, modes.stdout, "\r\n");
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            const after_path = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const rest = line[after_path + 1 ..];
            const after_mode = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
            const kind = rest[after_mode + 1 ..];
            if (!std.mem.eql(u8, kind, "directory")) return .{ .blocked = .{ .path = line[0..after_path], .kind = kind } };
            const mode = std.fmt.parseInt(u32, rest[0..after_mode], 8) catch return .wanting;
            if (mode & 0o005 != 0o005) traversable = false;
            seen += 1;
        }
        if (!modes.ok or seen != 2 or !traversable) return .wanting;
        const target = try self.runner.runBoth(arena, &.{ "readlink", pacman_private_db ++ "/local" });
        try exec.checkCaptureTimedOut(target);
        if (!target.ok) return .wanting;
        return if (std.mem.eql(u8, std.mem.trim(u8, target.stdout, " \t\r\n"), local)) .ready else .wanting;
    }

    /// Whether a stale lock sits in the copy.
    fn pacmanLockLeft(self: *Distro, arena: std.mem.Allocator) anyerror!bool {
        const res = try self.runner.run(arena, &.{ "test", "-e", pacman_private_lock });
        try exec.checkCaptureTimedOut(res);
        return res.ok;
    }

    /// The package universe: every name the private sync database carries.
    fn pacmanUniverse(self: *Distro, arena: std.mem.Allocator) anyerror!std.StringHashMap(void) {
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
        try exec.checkCaptureTimedOut(res);
        if (!res.ok) return Error.DistroQueryFailed;

        var out = std.StringHashMap(void).init(arena);
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            _ = fields.next() orelse continue;
            const name = fields.next() orelse continue;
            try out.put(name, {});
        }
        return out;
    }

    /// Refuse the rows pacman would not install as a package of that name --
    /// a GROUP, a PROVISION some other package satisfies, nothing at all, or
    /// a name pacman lists and still will not install -- and answer with the
    /// rest.
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
    /// A name pacman resolves to NOTHING is refused too, rather than handed
    /// over: measured on pacman 7.1.0 against a synced database, `pacman -S
    /// --needed --noconfirm -- cowsay mox-no-such-package` exits 1 with
    /// "target not found" having installed NEITHER, so one bad row otherwise
    /// keeps every package beside it off the machine, on every apply. The
    /// database asked is `pacman_private_db`, synced moments before, so
    /// absence from it is the row's own answer and not the age of the
    /// system's.
    ///
    /// The listing decides group against package -- a name that is both is
    /// pacman's package: `pacman -S kdevelop` resolves the package kdevelop
    /// and not the group's kdevelop-php and kdevelop-python, and `base` and
    /// `base-devel` are packages in their own right now, so they pass here
    /// while `pacman -Sg base-devel` says it is no group -- and nothing
    /// more. Every row to install is then asked of `-S --print`, listed or
    /// not: measured on pacman 7.1.0, a repository configured `Usage = Sync
    /// Search` puts its packages in `-Sl` while `pacman -S` answers each
    /// with "target not found", and a batch carrying one installs nothing.
    fn refusePacmanNonPackages(self: *Distro, arena: std.mem.Allocator, rows: []const Row, elevate: bool) anyerror![]const Row {
        try self.pacmanSyncPrivate(arena, elevate);
        const known = try self.pacmanUniverse(arena);
        if (known.count() == 0) {
            self.say(
                "mox: pacman: `pacman -Sl` lists no packages at all, which is a machine with no repositories configured rather than a row that names none, so no row could be checked and nothing was installed\n",
                .{},
            );
            return Error.DistroQueryFailed;
        }

        var candidates: std.ArrayList(Row) = .empty;
        for (rows) |row| {
            if (!known.contains(row.name)) {
                const members = try self.pacmanGroupMembers(arena, row.name);
                if (members.len > 0) {
                    var list: std.Io.Writer.Allocating = .init(arena);
                    for (members, 0..) |m, i| {
                        if (i > 0) try list.writer.writeAll(", ");
                        try list.writer.print("\"{s}\"", .{m});
                    }
                    self.say(
                        "mox: pacman: row \"{s}\" names no pacman package; it is a group of {d} packages ({s}), and pacman reports each of them under its own name, so declare the ones you want instead\n",
                        .{ row.name, members.len, list.written() },
                    );
                    continue;
                }
            }
            try candidates.append(arena, row);
        }

        // The whole batch in one `--print` first: measured on pacman 7.1.0,
        // ten rows asked one at a time cost 1.3 s and asked together 0.14 s,
        // and a batch every row of which is a package prints every row's
        // name. Only a row that transaction does not carry, or every row of
        // a batch pacman would not print at all, is asked about alone.
        const printed = try self.pacmanPrinted(arena, candidates.items);
        var keep: std.ArrayList(Row) = .empty;
        for (candidates.items) |row| {
            if (printed) |set| {
                if (set.contains(row.name)) {
                    try keep.append(arena, row);
                    continue;
                }
            }
            switch (try self.pacmanResolution(arena, row.name)) {
                .itself => try keep.append(arena, row),
                .provider => |provider| self.say(
                    "mox: pacman: row \"{s}\" names no pacman package; it is a provision that \"{s}\" satisfies, and pacman reports only the package name, so declare that instead\n",
                    .{ row.name, provider },
                ),
                .nothing => |said| if (known.contains(row.name)) self.say(
                    "mox: pacman: row \"{s}\" names a package pacman lists and still will not install ({s}), which is a repository whose Usage in pacman.conf leaves out Install; widen that, or drop the row\n",
                    .{ row.name, said },
                ) else self.say(
                    "mox: pacman: row \"{s}\" names no pacman package in this machine's repositories\n",
                    .{row.name},
                ),
                .unsatisfiable => |notes| self.say(
                    "mox: pacman: row \"{s}\" names a package pacman cannot install here, a dependency of it being satisfied by nothing in this machine's repositories ({s}), so it was not installed; add the repository that carries it, or drop the row\n",
                    .{ row.name, notes },
                ),
                .failed => |f| self.say(
                    "mox: pacman: row \"{s}\" was not installed: `pacman -S --print` exited {d} resolving it{s}{s}\n",
                    .{ row.name, f.code, if (f.said.len > 0) ", saying: " else ", saying nothing", f.said },
                ),
            }
        }
        return self.refusePacmanConflicts(arena, keep.items);
    }

    /// The members of the group `name`, or nothing when `name` is no group.
    /// Sorted, because a message that reorders itself between runs cannot be
    /// asserted on and pacman's own order is its database's.
    fn pacmanGroupMembers(self: *Distro, arena: std.mem.Allocator, name: []const u8) anyerror![]const []const u8 {
        const res = try self.runner.run(arena, &.{ "pacman", "-Sg", "--dbpath", pacman_private_db, name });
        try exec.checkCaptureTimedOut(res);
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

    const pacman_print_head = [_][]const u8{ "pacman", "-S", "--print", "--print-format", "%n", "--dbpath", pacman_private_db, "--" };

    /// The package names in the transaction pacman would run for all of
    /// `rows` at once, or null when pacman would run none: measured on
    /// pacman 7.1.0, a batch with one name pacman resolves to nothing exits
    /// 1 having printed only "target not found", whichever rows stand beside
    /// it. Its stderr is captured: on a failure it is dropped, every row of
    /// a batch that fails being asked about alone, and that answer relays
    /// what pacman said; beside a transaction pacman does print it is
    /// written through as it came, since it is a warning `run` would have
    /// left on the terminal (measured: `warning: config file
    /// /etc/pacman.conf, line 97: directive 'BogusDirective' in section
    /// 'options' not recognized.`, and exit 0).
    fn pacmanPrinted(self: *Distro, arena: std.mem.Allocator, rows: []const Row) anyerror!?std.StringHashMap(void) {
        if (rows.len == 0) return null;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &pacman_print_head);
        for (rows) |row| try argv.append(arena, row.name);
        const res = try self.runner.runBoth(arena, argv.items);
        try exec.checkCaptureTimedOut(res);
        if (!res.ok) return null;
        if (res.stderr.len > 0) self.say("{s}", .{res.stderr});

        var set = std.StringHashMap(void).init(arena);
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            try set.put(line, {});
        }
        return set;
    }

    const PacmanResolution = union(enum) {
        /// The transaction carries `name` itself: it is a package.
        itself,
        /// The package pacman would install for `name` in place of itself.
        provider: []const u8,
        /// pacman resolves `name` to nothing at all; its own line says so.
        nothing: []const u8,
        /// A dependency of `name` pacman could not satisfy; pacman's own
        /// lines name it.
        unsatisfiable: []const u8,
        /// pacman would not resolve `name` for a reason not read here: its
        /// exit code, and what it said.
        failed: struct { code: u8, said: []const u8 },
    };

    /// What pacman would install for `name` alone.
    ///
    /// `pacman -S --print` resolves the operand and prints the transaction it
    /// would run without committing any of it: measured on pacman 7.1.0,
    /// nothing under the database path changes across a run of these, and
    /// it takes no lock, so a stale `db.lck` in the copy does not stop it.
    /// `--print-format '%n'` reduces each entry to a bare package name.
    ///
    /// It fails two ways that only stderr tells apart, so stderr is
    /// captured here and relayed in the refusal (measured on the same
    /// pacman, against a synced database): a name with no target exits 1
    /// with `error: target not found: <name>` and nothing on stdout, which
    /// against the private database the caller has just synced is the
    /// answer for a row that names nothing; a name whose dependency no
    /// repository satisfies exits 1 too, with `error: failed to prepare
    /// transaction (could not satisfy dependencies)` on stderr and `::
    /// unable to satisfy dependency '<dep>' required by <name>` on STDOUT.
    /// A conflict with an installed package is not a failure here at all:
    /// the transaction prints and exits 0, so `refusePacmanConflicts` asks
    /// about that separately.
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
    fn pacmanResolution(self: *Distro, arena: std.mem.Allocator, name: []const u8) anyerror!PacmanResolution {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &pacman_print_head);
        try argv.append(arena, name);
        const res = try self.runner.runBoth(arena, argv.items);
        try exec.checkCaptureTimedOut(res);
        if (!res.ok) {
            const said = try oneLine(arena, res.stderr);
            if (std.mem.indexOf(u8, said, "target not found") != null) return .{ .nothing = said };
            if (std.mem.indexOf(u8, said, "could not satisfy dependencies") != null) {
                const notes = try pacmanNotes(arena, res.stdout);
                return .{ .unsatisfiable = if (notes.len > 0) notes else said };
            }
            return .{ .failed = .{ .code = res.code, .said = said } };
        }

        var last: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, res.stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (std.mem.eql(u8, line, name)) return .itself;
            last = line;
        }
        if (last) |provider| return .{ .provider = provider };
        return .{ .nothing = "" };
    }

    /// pacman's `:: ` notes on stdout, one line each, as one line without
    /// the markers.
    fn pacmanNotes(arena: std.mem.Allocator, stdout: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var it = std.mem.splitScalar(u8, stdout, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, ":: ")) continue;
            if (out.written().len > 0) try out.writer.writeAll("; ");
            try out.writer.writeAll(line[3..]);
        }
        return out.written();
    }

    /// `text` trimmed, its lines joined by `; `, for quoting inside a
    /// message of mox's own.
    fn oneLine(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (out.written().len > 0) try out.writer.writeAll("; ");
            try out.writer.writeAll(line);
        }
        return out.written();
    }

    const PacmanInfo = struct {
        name: []const u8,
        version: []const u8,
        provides: []const []const u8,
        conflicts: []const []const u8,
        replaces: []const []const u8,
    };

    /// The packages `pacman -Si` or `pacman -Qi` described in `text`, one
    /// block per package (measured on pacman 7.1.0): `Name`, `Version`,
    /// `Provides`, `Conflicts With` and `Replaces` are each one `Key :
    /// value` line, a list value is space-separated with no space inside a
    /// spec, and an empty one reads `None`.
    fn pacmanInfoBlocks(arena: std.mem.Allocator, text: []const u8) ![]const PacmanInfo {
        var out: std.ArrayList(PacmanInfo) = .empty;
        var current: ?PacmanInfo = null;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, " \t\r");
            const colon = std.mem.indexOf(u8, line, " : ") orelse continue;
            const key = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 3 ..], " \t");
            if (std.mem.eql(u8, key, "Name")) {
                if (current) |c| try out.append(arena, c);
                current = .{ .name = value, .version = "", .provides = &.{}, .conflicts = &.{}, .replaces = &.{} };
                continue;
            }
            const c = &(current orelse continue);
            if (std.mem.eql(u8, key, "Version")) {
                c.version = value;
            } else if (std.mem.eql(u8, key, "Provides")) {
                c.provides = try pacmanSpecList(arena, value);
            } else if (std.mem.eql(u8, key, "Conflicts With")) {
                c.conflicts = try pacmanSpecList(arena, value);
            } else if (std.mem.eql(u8, key, "Replaces")) {
                c.replaces = try pacmanSpecList(arena, value);
            }
        }
        if (current) |c| try out.append(arena, c);
        return out.toOwnedSlice(arena);
    }

    fn pacmanSpecList(arena: std.mem.Allocator, value: []const u8) ![]const []const u8 {
        if (std.mem.eql(u8, value, "None")) return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, value, " \t");
        while (it.next()) |spec| try out.append(arena, spec);
        return out.toOwnedSlice(arena);
    }

    const PacmanSpec = struct {
        text: []const u8,
        name: []const u8,
        /// `<`, `<=`, `=`, `>=` or `>`; empty for a bare name.
        op: []const u8,
        version: []const u8,
    };

    /// A dependency spec split: the name, then an operator and a version
    /// when it carries them (`xorg-server<21.1.1`, `nvidia-utils<=331.20`,
    /// `virt=2`; measured on pacman 7.1.0, with no space between).
    fn pacmanSpecParts(spec: []const u8) PacmanSpec {
        const start = std.mem.indexOfAny(u8, spec, "<>=") orelse return .{ .text = spec, .name = spec, .op = "", .version = "" };
        var end = start + 1;
        if (end < spec.len and spec[end] == '=') end += 1;
        return .{ .text = spec, .name = spec[0..start], .op = spec[start..end], .version = spec[end..] };
    }

    /// Whether `version` satisfies `spec`, by pacman's own comparison:
    /// `vercmp a b` prints -1, 0 or 1 (measured on pacman 7.1.0: `vercmp
    /// 1:1.6.8-1 2` is 1, the epoch deciding; `vercmp 2-1 2` is 0, a
    /// release absent from one side being left out). A bare name is
    /// satisfied by any version, and a versioned spec by no bare
    /// provision, as alpm has it.
    fn pacmanSpecHolds(self: *Distro, arena: std.mem.Allocator, spec: PacmanSpec, version: []const u8) anyerror!bool {
        if (spec.op.len == 0) return true;
        if (version.len == 0) return false;
        const res = try self.runner.run(arena, &.{ "vercmp", version, spec.version });
        try exec.checkCaptureTimedOut(res);
        const said = std.mem.trim(u8, res.stdout, " \t\r\n");
        const sign = std.fmt.parseInt(i8, said, 10) catch null;
        if (!res.ok or sign == null) {
            self.say(
                "mox: pacman: `vercmp {s} {s}` exited {d} rather than comparing them, so whether \"{s}\" is a conflict is left to pacman, which then installs none of the batch if it is\n",
                .{ version, spec.version, res.code, spec.text },
            );
            return false;
        }
        const c = sign.?;
        if (std.mem.eql(u8, spec.op, "<")) return c < 0;
        if (std.mem.eql(u8, spec.op, "<=")) return c <= 0;
        if (std.mem.eql(u8, spec.op, "=")) return c == 0;
        if (std.mem.eql(u8, spec.op, ">=")) return c >= 0;
        return c > 0;
    }

    /// The version under which `info` answers to `name`: its own when it
    /// is `name`, the provision's when it provides `name` ("" for a bare
    /// provision), and null when it does neither.
    fn pacmanVersionFor(info: PacmanInfo, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, info.name, name)) return info.version;
        for (info.provides) |prov| {
            const parts = pacmanSpecParts(prov);
            if (std.mem.eql(u8, parts.name, name)) return parts.version;
        }
        return null;
    }

    /// Whether installing `candidate` replaces the installed `pkg`: a
    /// `Replaces` naming it, at a version the installed one satisfies.
    /// alpm reads a replacement against the package's own name, never a
    /// provision of it.
    fn pacmanReplaces(self: *Distro, arena: std.mem.Allocator, candidate: PacmanInfo, pkg: PacmanInfo) anyerror!bool {
        for (candidate.replaces) |r| {
            const parts = pacmanSpecParts(r);
            if (std.mem.eql(u8, parts.name, pkg.name) and try self.pacmanSpecHolds(arena, parts, pkg.version)) return true;
        }
        return false;
    }

    /// The packages the apply's `-Syu` will bring forward, each with the
    /// version it will leave: measured on pacman 7.1.0, `pacman -Qu`
    /// against the copy prints `<name> <installed> -> <new>` per package,
    /// with ` [ignored]` after one `IgnorePkg` keeps back, and exits 1
    /// printing nothing when no upgrade is pending.
    ///
    /// That empty exit 1 is the only failure that means "nothing pending",
    /// so every other one is said out loud rather than read as an empty
    /// answer: measured on the same pacman, a dbpath that is not there
    /// exits 1 with `error: 'failed to resolve path '/no/such/path' passed
    /// to '--dbpath': No such file or directory` on stderr, and a dbpath
    /// whose `local` is not a directory exits 255 with `error: failed to
    /// initialize alpm library:` and `could not open database`.
    fn pacmanPending(self: *Distro, arena: std.mem.Allocator) anyerror!std.StringHashMap([]const u8) {
        var out = std.StringHashMap([]const u8).init(arena);
        const res = try self.runner.runBoth(arena, &.{ "pacman", "-Qu", "--dbpath", pacman_private_db });
        try exec.checkCaptureTimedOut(res);
        if (!res.ok) {
            if (res.code != 1 or res.stdout.len > 0 or res.stderr.len > 0) self.say(
                "mox: pacman: what the apply's `-Syu` will bring forward could not be read (`pacman -Qu --dbpath {s}` exited {d}: {s}), so a versioned conflict is judged against the version installed now, and a row the upgrade would have made room for may be refused\n",
                .{ pacman_private_db, res.code, try oneLine(arena, if (res.stderr.len > 0) res.stderr else res.stdout) },
            );
            return out;
        }
        var it = std.mem.tokenizeAny(u8, res.stdout, "\r\n");
        while (it.next()) |line| {
            var words = std.mem.tokenizeAny(u8, line, " \t");
            const name = words.next() orelse continue;
            _ = words.next() orelse continue;
            const arrow = words.next() orelse continue;
            const new = words.next() orelse continue;
            if (!std.mem.eql(u8, arrow, "->") or words.next() != null) continue;
            try out.put(name, new);
        }
        return out;
    }

    /// The machine the apply's `-Syu` will leave, as far as an installed
    /// package's own name goes.
    const PacmanFuture = struct {
        /// The block of the version the upgrade will leave, for each
        /// installed package with a pending upgrade.
        upgraded: std.StringHashMap(PacmanInfo),
        /// The installed packages the upgrade will remove.
        removed: std.StringHashMap(void),

        /// What the installed `p` will be once the upgrade has run, or null
        /// when it will not be on the machine at all.
        fn after(self: PacmanFuture, p: PacmanInfo) ?PacmanInfo {
            if (self.removed.contains(p.name)) return null;
            return self.upgraded.get(p.name) orelse p;
        }
    };

    /// What each installed package will be once the apply's `-Syu` has run:
    /// its block from `pacman -Si` against the copy at the pending version
    /// where a name is carried by more than one repository, and, for the
    /// packages the upgrade removes rather than upgrades, nothing.
    ///
    /// `pacman -Qu` is blind to a replacement, so it cannot answer the
    /// second half on its own. Measured on pacman 7.1.0 with `oldname 1-1`
    /// installed and the repository carrying only `newname 2-1`, whose
    /// `Replaces` names it: `pacman -Qu --dbpath <copy>` exits 1 printing
    /// nothing, while `pacman -Su --print --print-format '%n' --dbpath
    /// <copy>` exits 0 printing `newname`, and the `-Syu` the apply runs
    /// answers its own ":: Replace oldname with moxtest/newname? [Y/n]" yes
    /// under `--noconfirm`, removing oldname and installing newname. So the
    /// upgrade's own targets are asked for, `-Si` read for the ones the
    /// machine does not already have, and each installed package their
    /// `Replaces` names at a version it satisfies is gone from the future.
    /// With nothing pending that print exits 0 having printed nothing.
    fn pacmanFutureOf(self: *Distro, arena: std.mem.Allocator, installed: []const PacmanInfo, pending: std.StringHashMap([]const u8)) anyerror!PacmanFuture {
        var out: PacmanFuture = .{
            .upgraded = std.StringHashMap(PacmanInfo).init(arena),
            .removed = std.StringHashMap(void).init(arena),
        };
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "pacman", "-Si", "--dbpath", pacman_private_db, "--" });
        for (installed) |p| {
            if (pending.contains(p.name)) try argv.append(arena, p.name);
        }
        if (argv.items.len > 5) {
            const res = try self.runner.runBoth(arena, argv.items);
            try exec.checkCaptureTimedOut(res);
            if (res.ok) {
                for (try pacmanInfoBlocks(arena, res.stdout)) |block| {
                    const new = pending.get(block.name) orelse continue;
                    const have = out.upgraded.get(block.name);
                    if (have == null or std.mem.eql(u8, block.version, new)) try out.upgraded.put(block.name, block);
                }
            } else {
                const said = try oneLine(arena, res.stderr);
                self.say(
                    "mox: pacman: what the apply's `-Syu` will leave of the packages it upgrades could not be read (`pacman -Si --dbpath {s}` exited {d}{s}{s}), so each of them is judged at the version installed now, and a row the upgrade would have made room for may be refused\n",
                    .{ pacman_private_db, res.code, if (said.len > 0) ", saying: " else ", saying nothing", said },
                );
            }
        }

        var newcomers: std.ArrayList([]const u8) = .empty;
        try newcomers.appendSlice(arena, &.{ "pacman", "-Si", "--dbpath", pacman_private_db, "--" });
        for (try self.pacmanUpgradeTargets(arena)) |name| {
            for (installed) |p| {
                if (std.mem.eql(u8, p.name, name)) break;
            } else try newcomers.append(arena, name);
        }
        if (newcomers.items.len == 5) return out;
        const info = try self.runner.runBoth(arena, newcomers.items);
        try exec.checkCaptureTimedOut(info);
        if (!info.ok) {
            const said = try oneLine(arena, info.stderr);
            self.say(
                "mox: pacman: what the apply's `-Syu` will install in place of a package it removes could not be read (`pacman -Si --dbpath {s}` exited {d}{s}{s}), so an installed package the upgrade would replace is judged as still installed, and a row that conflicts with it may be refused\n",
                .{ pacman_private_db, info.code, if (said.len > 0) ", saying: " else ", saying nothing", said },
            );
            return out;
        }
        for (try pacmanInfoBlocks(arena, info.stdout)) |block| {
            for (installed) |p| {
                if (try self.pacmanReplaces(arena, block, p)) try out.removed.put(p.name, {});
            }
        }
        return out;
    }

    /// The names the apply's `-Syu` would install, whether as an upgrade of
    /// an installed package, as a new dependency, or in place of one it
    /// replaces. `--print` resolves and prints without committing and takes
    /// no lock, as the `-S --print` above does; `--print-format '%n'`
    /// reduces each entry to a bare name. Measured on pacman 7.1.0, it
    /// exits 0 with nothing on either stream when there is nothing to do,
    /// so any other answer is a failure and is said out loud: a dbpath that
    /// is not there exits 1 with `error: 'failed to resolve path
    /// '/no/such/path' passed to '--dbpath': No such file or directory`.
    fn pacmanUpgradeTargets(self: *Distro, arena: std.mem.Allocator) anyerror![]const []const u8 {
        const res = try self.runner.runBoth(arena, &.{ "pacman", "-Su", "--print", "--print-format", "%n", "--dbpath", pacman_private_db });
        try exec.checkCaptureTimedOut(res);
        if (!res.ok) {
            self.say(
                "mox: pacman: what the apply's `-Syu` would install could not be read (`pacman -Su --print --print-format %n --dbpath {s}` exited {d}: {s}), so an installed package the upgrade would replace is judged as still installed, and a row that conflicts with it may be refused\n",
                .{ pacman_private_db, res.code, try oneLine(arena, if (res.stderr.len > 0) res.stderr else res.stdout) },
            );
            return &.{};
        }
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, res.stdout, " \t\r\n");
        while (it.next()) |name| try out.append(arena, name);
        return out.toOwnedSlice(arena);
    }

    /// Refuse the rows whose package conflicts with one this machine has
    /// installed and will still have once the apply's `-Syu` has run, and
    /// answer with the rest.
    ///
    /// `pacman -S --print` does not report such a conflict -- the
    /// transaction prints and exits 0 (measured on pacman 7.1.0, with
    /// `--noconfirm` too) -- and the install then asks "Remove <installed>?
    /// [y/N]", which `--noconfirm` answers no, says "unresolvable package
    /// conflicts detected" and exits 1 having installed none of the batch:
    /// measured with pulseaudio installed and `pipewire-pulse cowsay` as
    /// the batch, cowsay never lands, on every apply. mox never removes a
    /// package, so the row goes rather than the batch.
    ///
    /// The install is one `-Syu`, so a conflict is judged against the
    /// machine that transaction leaves, not the one it starts from
    /// (measured on the same pacman): an installed package the row's
    /// `Replaces` names is answered "Replace <it> with <row>? [Y/n]" yes by
    /// `--noconfirm`, and is no conflict; an installed package some OTHER
    /// pending package replaces is gone from that machine too, and is no
    /// conflict either; and a versioned spec is judged against the version
    /// the upgrade will leave -- `xf86-*` declares `xorg-server<21.1.1`,
    /// which the same upgrade moves past. Both directions are read, since 42 of the
    /// 136 conflict pairs in the current repositories are declared on one
    /// side only (`exfatprogs` names `exfat-utils`, `iptables-legacy`
    /// names `iptables`; none names them back): the row's own `Conflicts
    /// With` (from `-Si`, against the copy) against what `pacman -Qi` says
    /// is installed, by name or by provision; and each installed package's
    /// own `Conflicts With` -- of the version the upgrade will leave, from
    /// `-Si` against the copy when one is pending -- against the row and
    /// what it provides. A versioned spec is compared by `vercmp`, pacman's
    /// own comparison, epoch and all.
    fn refusePacmanConflicts(self: *Distro, arena: std.mem.Allocator, rows: []const Row) anyerror![]const Row {
        if (rows.len == 0) return rows;

        var si: std.ArrayList([]const u8) = .empty;
        try si.appendSlice(arena, &.{ "pacman", "-Si", "--dbpath", pacman_private_db, "--" });
        for (rows) |row| try si.append(arena, row.name);
        const info = try self.runner.runBoth(arena, si.items);
        try exec.checkCaptureTimedOut(info);
        if (!info.ok) {
            const said = try oneLine(arena, info.stderr);
            self.say(
                "mox: pacman: what the rows to install conflict with could not be read (`pacman -Si --dbpath {s}` exited {d}{s}{s}), so a row it did not describe is left to pacman, which then installs none of the batch if that row conflicts with an installed package\n",
                .{ pacman_private_db, info.code, if (said.len > 0) ", saying: " else ", saying nothing", said },
            );
        }
        const candidates = try pacmanInfoBlocks(arena, info.stdout);

        const qi = try self.runner.run(arena, &.{ "pacman", "-Qi" });
        try exec.checkCaptureTimedOut(qi);
        if (!qi.ok) {
            self.say(
                "mox: pacman: what this machine has installed could not be read in full (`pacman -Qi` exited {d}), so a row that conflicts with an installed package, or that one declares a conflict with, is left to pacman, which then installs none of the batch\n",
                .{qi.code},
            );
            return rows;
        }
        const installed = try pacmanInfoBlocks(arena, qi.stdout);
        const pending = try self.pacmanPending(arena);
        const future = try self.pacmanFutureOf(arena, installed, pending);

        var keep: std.ArrayList(Row) = .empty;
        rows: for (rows) |row| {
            const candidate = for (candidates) |c| {
                if (std.mem.eql(u8, c.name, row.name)) break c;
            } else {
                try keep.append(arena, row);
                continue;
            };
            for (candidate.conflicts) |text| {
                const spec = pacmanSpecParts(text);
                for (installed) |p| {
                    if (try self.pacmanReplaces(arena, candidate, p)) continue;
                    const after = future.after(p) orelse continue;
                    const version = pacmanVersionFor(after, spec.name) orelse continue;
                    if (!try self.pacmanSpecHolds(arena, spec, version)) continue;
                    if (std.mem.eql(u8, p.name, text)) {
                        self.say(
                            "mox: pacman: row \"{s}\" names a package that conflicts with \"{s}\", which this machine has installed; pacman would have to remove {s} to install it, and mox never removes a package, so the row was not installed: remove {s} yourself, or drop the row\n",
                            .{ row.name, text, p.name, p.name },
                        );
                    } else {
                        self.say(
                            "mox: pacman: row \"{s}\" names a package that conflicts with \"{s}\", which this machine has installed as \"{s}\"; pacman would have to remove {s} to install it, and mox never removes a package, so the row was not installed: remove {s} yourself, or drop the row\n",
                            .{ row.name, text, p.name, p.name, p.name },
                        );
                    }
                    continue :rows;
                }
            }
            for (installed) |p| {
                if (try self.pacmanReplaces(arena, candidate, p)) continue;
                const after = future.after(p) orelse continue;
                for (after.conflicts) |text| {
                    const spec = pacmanSpecParts(text);
                    const version = pacmanVersionFor(candidate, spec.name) orelse continue;
                    if (!try self.pacmanSpecHolds(arena, spec, version)) continue;
                    self.say(
                        "mox: pacman: row \"{s}\" names a package that \"{s}\", which this machine has installed, declares a conflict with (\"{s}\"); pacman would have to remove {s} to install it, and mox never removes a package, so the row was not installed: remove {s} yourself, or drop the row\n",
                        .{ row.name, p.name, text, p.name, p.name },
                    );
                    continue :rows;
                }
            }
            try keep.append(arena, row);
        }
        return keep.toOwnedSlice(arena);
    }

    /// `-y` alone answers apt's own questions; debconf asks its own through
    /// a frontend, and only this setting keeps it from stopping the install.
    /// Set through `env` rather than mox's environment so it holds after
    /// `sudo` resets the environment.
    const apt_env = [_][]const u8{ "env", "DEBIAN_FRONTEND=noninteractive" };

    /// The one key that says which architecture apt resolves against. Asked
    /// of apt itself rather than read from `/etc/apt/apt.conf.d`, which is
    /// one of the places apt reads and not the answer.
    const apt_arch_argv = [_][]const u8{ "apt-config", "dump", "APT::Architecture" };

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
    return "apt-cache -o APT::Architectures=" ++ native ++ " -o Dir::State::status=/dev/null -o APT::Cache::AllNames=false --generate pkgnames";
}

/// The installed-architecture listing argv the apt adapter builds.
const apt_installed_call = "dpkg-query -W -f ${Package} ${Architecture} ${Status}\\n";

/// The argv that asks apt which architecture it resolves against.
const apt_arch_call = "apt-config dump APT::Architecture";

/// What that argv answers on a machine apt agrees with, in the shape apt
/// 2.6.1 and 3.0.3 print it.
fn aptArchDump(comptime arch: []const u8) []const u8 {
    return "APT::Architecture \"" ++ arch ++ "\";\n";
}

/// The stanza `apt-cache policy` prints for a package it has a version of,
/// in the shape apt 2.6.1 and 3.0.3 print it.
fn aptStanza(comptime name: []const u8) []const u8 {
    return name ++ ":\n  Installed: (none)\n  Candidate: 1.0\n  Version table:\n     1.0 500\n        500 http://deb.debian.org/debian trixie/main arm64 Packages\n";
}

fn countCalls(fake: *const exec.Fake, argv: []const u8) usize {
    var n: usize = 0;
    for (fake.calls.items) |c| {
        if (std.mem.eql(u8, c, argv)) n += 1;
    }
    return n;
}

const pdb = Distro.pacman_private_db;
const pacman_cache = Distro.pacman_cache_dir;
const pacman_private_sync = "pacman -Sy --dbpath " ++ pdb ++ " --logfile /dev/null";

/// Whether `call` writes to the system's pacman databases: an upgrade, or a
/// sync with no `--dbpath` of its own.
fn touchesPacmanSystem(call: []const u8) bool {
    if (std.mem.indexOf(u8, call, "-Syu") != null) return true;
    return std.mem.indexOf(u8, call, " -Sy ") != null and std.mem.indexOf(u8, call, "--dbpath") == null;
}

/// How many calls touched the system's pacman databases.
fn pacmanSystemWrites(fake: *const exec.Fake) usize {
    var n: usize = 0;
    for (fake.calls.items) |c| {
        if (touchesPacmanSystem(c)) n += 1;
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
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = apt_installed_call, .stdout = "bat arm64 install ok installed\nfd-find arm64 install ok installed\nripgrep arm64 install ok installed\n" },
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
    try testing.expectEqualStrings("%{name}\n", Manager.dnf.queryArgv()[6]);
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
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n", .match = .prefix },
        .{ .argv = "dnf install -y --setopt=assumeno=0 bat" },
    } };
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false };

    // The Fake errors on anything unscripted, so a stray `sudo` fails here.
    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(fake.called("dnf install -y --setopt=assumeno=0 bat"));
}

test "install: apt as root refreshes without sudo too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("amd64") },
        .{ .argv = aptNamesCall("amd64"), .stdout = "bat\nnano\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = aptStanza("bat") },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = apt_installed_call },
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
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("amd64") },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "sudo env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = aptNamesCall("amd64"), .stdout = "bat\nfd-find\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = comptime (aptStanza("bat") ++ aptStanza("fd-find")) },
        .{ .argv = "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat fd-find" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("fd-find", &.{}) });
    try testing.expectEqualStrings("sudo env DEBIAN_FRONTEND=noninteractive apt-get update", fake.calls.items[4]);
    try testing.expectEqualStrings("sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat fd-find", fake.calls.items[fake.calls.items.len - 1]);
}

test "install: dnf takes one non-interactive command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n bat ripgrep", .stdout = "bat\nripgrep\n" },
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n", .match = .prefix },
        .{ .argv = "sudo dnf install -y --setopt=assumeno=0 bat ripgrep" },
    } };
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = true };

    // The Fake errors on anything unscripted, so a stray refresh fails here.
    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("ripgrep", &.{}) });
    try testing.expect(fake.called("sudo dnf install -y --setopt=assumeno=0 bat ripgrep"));
}

test "install: pacman checks against its own copy of the database, and installs in one transaction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq" },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = "sudo " ++ pacman_make },
        .{ .argv = "sudo pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\nextra ripgrep 14.1.1-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- bat", .stdout = "oniguruma\nbat\n" },
        .{ .argv = "sudo pacman -Syu --needed --noconfirm -- bat" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(fake.called("sudo pacman -Syu --needed --noconfirm -- bat"));
    // The install's `-Syu` is the run's only write to the system's
    // databases; the check's sync went to mox's own copy.
    try testing.expectEqual(@as(usize, 1), pacmanSystemWrites(&fake));
}

test "install: a failed install is an error, not a silent skip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n", .match = .prefix },
        .{ .argv = "sudo dnf install -y --setopt=assumeno=0 bat", .code = 1 },
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

test "available: absent, present, and a manager that answers nonzero is broken; only a spawn failure propagates" {
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
        .{ .m = .dnf, .argv = "sudo dnf install -y --setopt=assumeno=0 bat" },
        .{ .m = .pacman, .argv = "sudo pacman -Syu --needed --noconfirm -- bat" },
    }) |c| {
        var fake: exec.Fake = .{ .arena = a, .entries = &.{
            .{ .argv = "sudo env DEBIAN_FRONTEND=noninteractive apt-get update" },
            .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
            .{ .argv = apt_arch_call, .stdout = aptArchDump("amd64") },
            .{ .argv = apt_installed_call },
            .{ .argv = "apt-mark showauto" },
            .{ .argv = aptNamesCall("amd64"), .stdout = "bat\n" },
            .{ .argv = "apt-mark showhold" },
            .{ .argv = "apt-cache policy", .match = .prefix, .stdout = aptStanza("bat") },
            .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n bat", .stdout = "bat\n" },
            .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
            .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
            .{ .argv = "sudo " ++ pacman_make },
            .{ .argv = "sudo pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
            .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\n" },
            .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
            .{ .argv = "pacman -Qi" },
            .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
            nothing_to_upgrade,
            .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- bat", .stdout = "bat\n" },
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
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n bat zlib-devel", .stdout = "bat\n" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n --whatprovides zlib-devel", .stdout = "zlib-ng-compat-devel\n" },
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n", .match = .prefix },
        .{ .argv = "dnf install -y --setopt=assumeno=0 bat" },
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

test "install: no dnf listing carries -y, which would import a repository's key to answer its own question" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on dnf 4.14.0 (rockylinux:9) with `repo_gpgcheck=1` and
    // `skip_if_unavailable=1` on a repository whose signing key rpm has not
    // imported: `-y` says yes to importing it and takes the same listing
    // from 0 names to 5735. Accepting a key is the administrator's
    // decision, so a read-only listing declines the question instead.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n bat zlib-devel", .stdout = "bat\n" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n --whatprovides zlib-devel", .stdout = "zlib-ng-compat-devel\n" },
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n", .match = .prefix },
        .{ .argv = "dnf install -y --setopt=assumeno=0 bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("zlib-devel", &.{}) });
    var listings: usize = 0;
    for (fake.calls.items) |c| {
        if (std.mem.indexOf(u8, c, "repoquery") == null) continue;
        listings += 1;
        try testing.expect(std.mem.indexOf(u8, c, " -y") == null);
    }
    try testing.expectEqual(@as(usize, 3), listings);
    // The listing `mox status` reads is built the same way.
    for (Manager.dnf.queryArgv()) |arg| try testing.expect(!std.mem.eql(u8, arg, "-y"));
    for (Distro.dnf_names_argv) |arg| try testing.expect(!std.mem.eql(u8, arg, "-y"));
    for (Distro.dnf_installed_argv) |arg| try testing.expect(!std.mem.eql(u8, arg, "-y"));
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("amd64") },
        .{ .argv = aptNamesCall("amd64"), .stdout = "bat\n" },
        .{ .argv = apt_installed_call, .stdout = "bat amd64 install ok installed\n" },
        .{ .argv = "apt-cache madison", .match = .prefix, .stdout = "" },
        .{ .argv = "apt-cache showpkg", .match = .prefix, .stdout = "" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = aptStanza("bat") },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{
            .argv = "apt-cache madison wine32:armhf",
            .stdout = "wine32:armhf | 10.0~repack-6 | http://deb.debian.org/debian trixie/main armhf Packages\n",
        },
        .{ .argv = "dpkg --print-foreign-architectures", .stdout = "armhf\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = aptStanza("wine32:armhf") },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = apt_installed_call },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{
            .argv = "apt-cache madison wine:armhf",
            .stdout = "      wine | 10.0~repack-6 | http://deb.debian.org/debian trixie/main Sources\n",
        },
        .{ .argv = "dpkg --print-foreign-architectures", .stdout = "armhf\n" },
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
        .{ .argv = apt_installed_call },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
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
        .{ .argv = apt_installed_call },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("amd64") },
        .{ .argv = aptNamesCall("amd64"), .code = 100 },
    } };
    var d: Distro = .{ .manager = .apt, .runner = apt.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroQueryFailed, d.backend().install(a, &.{rowOf("bat", &.{})}));

    var dnf: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n bat", .code = 1 },
    } };
    var d2: Distro = .{ .manager = .dnf, .runner = dnf.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroQueryFailed, d2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(dnf.called("dnf -q --assumeno repoquery --installed --qf %{name}\n bat"));
}

test "install: dnf refuses a virtual provide, naming the package that provides it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved against dnf5 5.4.3 on Fedora 44: `zlib-devel` is not a package
    // there, only a capability `zlib-ng-compat-devel` provides. rpm reports
    // the provider's name, so the row is missing on every status after.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n zlib-devel" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n zlib-devel", .stdout = "" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n --whatprovides zlib-devel", .stdout = "zlib-ng-compat-devel\n" },
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
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "dnf --version", .stdout = "dnf5 version 5.2.18.0\ndnf5 plugin API version 2.0\n" },
        .{ .argv = "sudo dnf mark user -y --setopt=assumeno=0 bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = true, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installMarked());
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expect(fake.called("sudo dnf mark user -y --setopt=assumeno=0 bat"));
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
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "dnf --version", .stdout = "4.14.0\n  Installed: dnf-0:4.14.0-8.el9.noarch\n" },
        .{ .argv = "dnf mark install --setopt=assumeno=0 bat" },
    } };
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installMarked());
    try testing.expect(fake.called("dnf mark install --setopt=assumeno=0 bat"));
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
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n bat fd-find ripgrep", .stdout = "bat\nfd-find\n" },
        .{ .argv = "dnf --version", .stdout = "dnf5 version 5.4.3.0\n" },
        .{ .argv = "dnf mark user -y --setopt=assumeno=0 bat", .code = 1 },
        .{ .argv = "dnf mark user -y --setopt=assumeno=0 fd-find" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n ripgrep", .stdout = "ripgrep\n" },
        .{ .argv = "dnf install -y --setopt=assumeno=0 ripgrep" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("fd-find", &.{}), rowOf("ripgrep", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installUnmarked());
    try testing.expectEqual(@as(usize, 1), d.backend().installMarked());
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expect(fake.called("dnf install -y --setopt=assumeno=0 ripgrep"));
    try testing.expect(!fake.called("dnf install -y --setopt=assumeno=0 bat"));
    try testing.expect(std.mem.indexOf(u8, w.written(), "\"bat\" could not be marked user installed, so the row stays missing") != null);
}

test "install: a dnf whose generation cannot be read marks nothing and says which rows stay missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n bat fd-find", .stdout = "bat\nfd-find\n" },
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
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n bat ripgrep", .stdout = "bat\n" },
        .{ .argv = "dnf --version", .stdout = "dnf5 version 5.4.3.0\n" },
        .{ .argv = "dnf mark user -y --setopt=assumeno=0 bat" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n ripgrep", .stdout = "ripgrep\n" },
        .{ .argv = "dnf install -y --setopt=assumeno=0 ripgrep" },
    } };
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("ripgrep", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installMarked());
    // The install carries the other row alone: handing it the marked one
    // would install nothing and cost a resolution.
    try testing.expect(fake.called("dnf install -y --setopt=assumeno=0 ripgrep"));
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
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = apt_installed_call, .stdout = "bat arm64 install ok installed\nlibc6 arm64 install ok installed\n" },
        .{ .argv = "apt-mark showauto", .stdout = "bat\nlibc6\n" },
        .{ .argv = "apt-mark manual bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installMarked());
    try testing.expect(fake.called("apt-mark manual bat"));
    try testing.expectEqual(@as(usize, 5), fake.calls.items.len);
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
        .{ .argv = apt_installed_call, .stdout = "groff-base amd64 install ok installed\n" },
        .{ .argv = "apt-mark manual groff-base" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("amd64") },
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
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null", .code = 1 },
        .{ .argv = "test -e /var/cache/mox/pacman-db/db.lck", .code = 1 },
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
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- bat", .stdout = "bat\n" },
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
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- bat", .stdout = "bat\n" },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = aptStanza("bat") },
        .{ .argv = apt_installed_call },
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
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n java-devel" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n java-devel", .stdout = "" },
        .{
            .argv = "dnf -q --assumeno repoquery --qf %{name}\n --whatprovides java-devel",
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
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n ripgrepp" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n ripgrepp", .stdout = "" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n --whatprovides ripgrepp", .stdout = "" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("ripgrepp", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: dnf: row \"ripgrepp\" names no package dnf will install here: no enabled repository carries it, or an exclude in dnf's configuration keeps it out\n",
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
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\nextra fprintd 1.94.9-1\nextra libfprint 1.94.9-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Sg --dbpath /var/cache/mox/pacman-db fprint", .stdout = "fprint libfprint\nfprint fprintd\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("fprint", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"fprint\" names no pacman package; it is a group of 2 packages (\"fprintd\", \"libfprint\"), and pacman reports each of them under its own name, so declare the ones you want instead\n",
        w.written(),
    );
    // The row never reached an install, so no member of the group landed,
    // and a check never mutates the system: the only sync went to mox's own
    // copy of the database.
    try testing.expect(!d.backend().installSpawned());
    try testing.expectEqual(@as(usize, 0), pacmanSystemWrites(&fake));
    try testing.expectEqual(@as(usize, 1), countCalls(&fake, pacman_private_sync));
}

test "install: pacman installs a name only a current database has heard of, rather than refusing it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved with pacman 7.1.0 synced from the 2024-01-01 Arch archive and
    // then pointed at a current mirror: `pacman -Sl` answers 13801 names and
    // has none of `ghostty`, `uv`, `zed` or `opencode`, all four of which the
    // current repositories carry. The listing read is mox's own copy of the
    // database, synced moments before, so the row is never judged by the
    // system's old one -- and the system's is left as old as it was.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq" },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\nextra ghostty 1.2.0-1\nextra ripgrep 14.1.1-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- ghostty", .stdout = "ghostty\n" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- ghostty" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("ghostty", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expectEqualStrings("", w.written());
    try testing.expectEqualStrings(pacman_private_sync, fake.calls.items[4]);
    try testing.expectEqualStrings("pacman -Sl --dbpath /var/cache/mox/pacman-db", fake.calls.items[5]);
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- ghostty"));
    try testing.expectEqual(@as(usize, 1), pacmanSystemWrites(&fake));
}

test "install: pacman refuses a name its synced database has nothing for, and installs the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved on pacman 7.1.0 with a synced database: `pacman -S --needed
    // --noconfirm -- cowsay mox-no-such-package` exits 1 with "target not
    // found" and installs neither, and `pacman -S --print -- mox-no-such-
    // package` exits 1 the same way. Judged against mox's copy of the
    // database, synced moments before, the answer is current, and the row
    // is refused on its own rather than failing the batch on every apply.
    // The batch `--print` exits 1 the same way with the bad row in it, and
    // says nothing of the good one, so each is then asked about alone.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\nextra cowsay 3.04-6\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Sg --dbpath /var/cache/mox/pacman-db mox-no-such-package", .code = 1 },
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- cowsay mox-no-such-package", .code = 1 },
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- cowsay", .stdout = "cowsay\n" },
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- mox-no-such-package", .code = 1, .stderr = "error: target not found: mox-no-such-package\n" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- cowsay" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("cowsay", &.{}), rowOf("mox-no-such-package", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"mox-no-such-package\" names no pacman package in this machine's repositories\n",
        w.written(),
    );
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- cowsay"));
    try testing.expectEqual(@as(usize, 1), pacmanSystemWrites(&fake));
}

test "install: a name pacman lists and still will not install is refused, naming why" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0 with a repository configured `Usage = Sync
    // Search`: `pacman -Sl` prints its `sidepkg`, `pacman -S --print --
    // sidepkg` exits 1 "target not found", and `pacman -S --needed
    // --noconfirm -- sidepkg bat` installs neither. So the listing settles
    // group against package alone, and every row is asked of `--print`.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\nside sidepkg 1-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- sidepkg bat", .code = 1 },
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- sidepkg", .code = 1, .stderr = "error: target not found: sidepkg\n" },
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- bat", .stdout = "oniguruma\nbat\n" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("sidepkg", &.{}), rowOf("bat", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"sidepkg\" names a package pacman lists and still will not install (error: target not found: sidepkg), which is a repository whose Usage in pacman.conf leaves out Install; widen that, or drop the row\n",
        w.written(),
    );
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- bat"));
    // A listed name is no group, so the group question is never asked.
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "-Sg") == null);
}

test "install: a batch that fails names the rows that were in it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\nextra cowsay 3.04-6\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- bat cowsay", .stdout = "bat\ncowsay\n" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- bat cowsay", .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    // pacman's install is the whole-system upgrade, so its failure is its
    // own error, and the words for it say so: what stopped the transaction
    // may be a package no row declares.
    try testing.expectError(Error.DistroUpgradeInstallFailed, d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("cowsay", &.{}) }));
    try testing.expect(d.backend().installSpawned());
    try testing.expectEqualStrings(
        "mox: pacman: the batch of \"bat\", \"cowsay\" failed as one; pacman's own message above says which row stopped it\n",
        w.written(),
    );
    try testing.expectEqualStrings(
        "the install did not complete, and on pacman an install is the whole-system upgrade pacman requires of one, so pacman's own message above may name a package no row declares",
        exec.errorText(Error.DistroUpgradeInstallFailed),
    );

    // The other managers' install is an install and nothing more.
    var dnf: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n bat" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "dnf install -y --setopt=assumeno=0 bat", .code = 1 },
    } };
    var d2: Distro = .{ .manager = .dnf, .runner = dnf.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroInstallFailed, d2.backend().install(a, &.{rowOf("bat", &.{})}));
}

test "install: an elevated install with no sudo on the machine says so" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on debian:stable as a user with no `sudo` on the machine: the
    // apply reported `install did not run: FileNotFound`, naming neither
    // the program nor that elevation was what the install lacked.
    var pac: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = "sudo " ++ pacman_make, .fail = error.FileNotFound },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = pac.runner(), .force_elevate = true };
    try testing.expectError(exec.Error.SudoNotFound, d.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!d.backend().installSpawned());

    var apt: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showauto" },
        .{ .argv = apt_installed_call },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = "sudo env DEBIAN_FRONTEND=noninteractive apt-get update", .fail = error.FileNotFound },
    } };
    var d2: Distro = .{ .manager = .apt, .runner = apt.runner(), .force_elevate = true };
    try testing.expectError(exec.Error.SudoNotFound, d2.backend().install(a, &.{rowOf("bat", &.{})}));

    // The mark is elevated too, and a row the machine has is marked first.
    var mark: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .stdout = "acl\n" },
        .{ .argv = "sudo pacman -D --asexplicit acl", .fail = error.FileNotFound },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d3: Distro = .{ .manager = .pacman, .runner = mark.runner(), .force_elevate = true, .err = &w.writer };
    try testing.expectError(exec.Error.SudoNotFound, d3.backend().install(a, &.{rowOf("acl", &.{})}));
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
        .{ .argv = "pacman -Qdq" },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core base 3-2\ncore base-devel 1-2\nextra kdevelop 25.08.1-1\nextra kdevelop-php 25.08.1-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- kdevelop base-devel base", .stdout = "kdevelop\nbase-devel\nbase\n" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- kdevelop base-devel base" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{ rowOf("kdevelop", &.{}), rowOf("base-devel", &.{}), rowOf("base", &.{}) });
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- kdevelop base-devel base"));
    // Asked about no name it already found, so no group query ran at all,
    // and the three were resolved in one `--print`.
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "-Sg") == null);
    try testing.expectEqual(@as(usize, 12), fake.calls.items.len);
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
    // So the group question is asked of mox's own copy of the database,
    // synced whole moments before; the system's short one is left alone.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = "sudo " ++ pacman_make },
        .{ .argv = "sudo pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\nextra exo 4.20.0-1\nextra garcon 4.20.0-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Sg --dbpath /var/cache/mox/pacman-db xfce4", .stdout = "xfce4 exo\nxfce4 garcon\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("xfce4", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"xfce4\" names no pacman package; it is a group of 2 packages (\"exo\", \"garcon\"), and pacman reports each of them under its own name, so declare the ones you want instead\n",
        w.written(),
    );
    // The listing and the group question both came after the private sync,
    // never against the short database.
    try testing.expectEqualStrings("sudo " ++ pacman_private_sync, fake.calls.items[4]);
    try testing.expectEqualStrings("pacman -Sl --dbpath /var/cache/mox/pacman-db", fake.calls.items[5]);
    try testing.expectEqualStrings("pacman -Sg --dbpath /var/cache/mox/pacman-db xfce4", fake.calls.items[6]);
    try testing.expect(!d.backend().installSpawned());
    try testing.expectEqual(@as(usize, 0), pacmanSystemWrites(&fake));
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
    var fake: exec.Fake = .{
        .arena = a,
        .entries = &.{
            .{ .argv = "pacman -Qdq" },
            .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
            .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
            .{ .argv = pacman_make },
            .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
            .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\ncore cronie 1.7.2-1\n" },
            .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
            .{ .argv = "pacman -Qi" },
            .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
            nothing_to_upgrade,
            .{ .argv = "pacman -Sg --dbpath /var/cache/mox/pacman-db cron", .code = 1 },
            // The batch resolves, and carries bat but not cron: measured, `--
            // bat cron` prints bat's libraries, bat, run-parts and cronie.
            .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- bat cron", .stdout = "oniguruma\nbat\nrun-parts\ncronie\n" },
            .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- cron", .stdout = "run-parts\ncronie\n" },
            .{ .argv = "pacman -Syu --needed --noconfirm -- bat" },
        },
    };
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
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bash 5.3-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Sg --dbpath /var/cache/mox/pacman-db smtp-forwarder", .code = 1 },
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- smtp-forwarder", .stdout = "libidn\nlibspf2\ndb5.3\nperl\nexim\n" },
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
    // pacman 7.1.0 `bat` prints three libraries and then `bat`.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq" },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core glibc 2.42-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Sg --dbpath /var/cache/mox/pacman-db bat", .code = 1 },
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- bat", .stdout = "llhttp\nlibgit2\noniguruma\nbat\n" },
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
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "extra exo 4.20.0-1\nextra garcon 4.20.0-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Sg --dbpath /var/cache/mox/pacman-db xfce4", .stdout = "xfce4 exo\nxfce4 garcon\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("xfce4", &.{})});
    try testing.expect(std.mem.indexOf(u8, w.written(), "it is a group of 2 packages") != null);
    try testing.expect(!fake.called("pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- xfce4"));
}

test "install: a row the listing already carries is asked of --print, and of nothing more" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every row is in the listing, so no group is asked about; `--print`
    // is asked of every row, listed or not, and of the whole batch at once.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq" },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = "sudo " ++ pacman_make },
        .{ .argv = "sudo pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\nextra ripgrep 14.1.1-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- bat ripgrep", .stdout = "oniguruma\nbat\nripgrep\n" },
        .{ .argv = "sudo pacman -Syu --needed --noconfirm -- bat ripgrep" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("ripgrep", &.{}) });
    try testing.expectEqual(@as(usize, 12), fake.calls.items.len);
    var prints: usize = 0;
    for (fake.calls.items) |c| {
        try testing.expect(std.mem.indexOf(u8, c, "-Sg") == null);
        if (std.mem.indexOf(u8, c, "-S --print") != null) prints += 1;
    }
    try testing.expectEqual(@as(usize, 1), prints);
}

test "install: a pacman listing past the cap stops the install, saying that is what happened" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `pacman -Sl` is 440 KiB on a current Arch, well inside the cap, but
    // past it mox has read no repository and no name at all.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .fail = error.StreamTooLong },
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

test "install: the pacman check syncs its own copy, and the install is the only write to the system" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A check never mutates the system. The listing, the group question and
    // the resolution all read mox's own copy of the database, synced first,
    // so a name none of them has is refused on its own; the system's
    // database is written by the install alone, and by the one `-Syu` it
    // is. The batch `--print` exits 1 with the bad row in it, so each row
    // is then asked about alone.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = "sudo " ++ pacman_make },
        .{ .argv = "sudo pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Sg --dbpath /var/cache/mox/pacman-db ghostty", .code = 1 },
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- bat ghostty", .code = 1 },
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- bat", .stdout = "bat\n" },
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- ghostty", .code = 1, .stderr = "error: target not found: ghostty\n" },
        .{ .argv = "sudo pacman -Syu --needed --noconfirm -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("ghostty", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings("pacman-conf DBPath", fake.calls.items[1]);
    try testing.expectEqualStrings(pacman_probe, fake.calls.items[2]);
    try testing.expectEqualStrings("sudo " ++ pacman_make, fake.calls.items[3]);
    try testing.expectEqualStrings("sudo " ++ pacman_private_sync, fake.calls.items[4]);
    try testing.expectEqualStrings("pacman -Sl --dbpath /var/cache/mox/pacman-db", fake.calls.items[5]);
    try testing.expectEqualStrings("sudo pacman -Syu --needed --noconfirm -- bat", fake.calls.items[14]);
    try testing.expectEqual(@as(usize, 15), fake.calls.items.len);
    try testing.expectEqual(@as(usize, 1), pacmanSystemWrites(&fake));
    for (fake.calls.items[0..11]) |c| try testing.expect(!touchesPacmanSystem(c));
    try testing.expectEqualStrings(
        "mox: pacman: row \"ghostty\" names no pacman package in this machine's repositories\n",
        w.written(),
    );
}

test "install: an unsynced pacman database is read through mox's copy, and synced only by the install" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Verified against pacman 7.1.0: with no database downloaded, `pacman
    // -Sl` exits 0 with nothing at all, so a check that read the system's
    // would judge every row against nothing. The check reads its own copy,
    // and never runs a bare `-Sy` on the system, which would leave the
    // machine in the partial-upgrade state whichever way the rest went; the
    // install's `-Syu` is what brings the system forward.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = "sudo " ++ pacman_make },
        .{ .argv = "sudo pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- bat", .stdout = "bat\n" },
        .{ .argv = "sudo pacman -Syu --needed --noconfirm -- bat" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqualStrings("sudo " ++ pacman_private_sync, fake.calls.items[4]);
    try testing.expectEqualStrings("pacman -Sl --dbpath /var/cache/mox/pacman-db", fake.calls.items[5]);
    try testing.expectEqualStrings("sudo pacman -Syu --needed --noconfirm -- bat", fake.calls.items[11]);
    try testing.expectEqual(@as(usize, 1), pacmanSystemWrites(&fake));

    // A private sync that fails is not an install that failed: no install
    // ran, and the system was not touched.
    var down: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync, .code = 1 },
        .{ .argv = "test -e " ++ pdb ++ "/db.lck", .code = 1 },
    } };
    var d2: Distro = .{ .manager = .pacman, .runner = down.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroRefreshFailed, d2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!d2.backend().installSpawned());
    try testing.expectEqual(@as(usize, 0), pacmanSystemWrites(&down));

    // The system's local database is wherever pacman.conf says, and a
    // DBPath without its trailing slash joins the same way.
    var conf: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/mnt/arch/var/lib/pacman\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacmanMakeCall("/mnt/arch/var/lib/pacman/local") },
        .{ .argv = pacman_private_sync, .code = 1 },
        .{ .argv = "test -e " ++ pdb ++ "/db.lck", .code = 1 },
    } };
    var d3: Distro = .{ .manager = .pacman, .runner = conf.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroRefreshFailed, d3.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(conf.called(pacmanMakeCall("/mnt/arch/var/lib/pacman/local")));
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
            .{ .argv = apt_installed_call },
            .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
            .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
            .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
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
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{
            .argv = "apt-cache madison libc6:armhf",
            .stdout = "libc6:armhf | 2.41-12+deb13u4 | http://deb.debian.org/debian trixie/main armhf Packages\n",
        },
        .{ .argv = "dpkg --print-foreign-architectures", .stdout = "armhf\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = aptStanza("libc6:armhf") },
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
        .{ .argv = apt_installed_call },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("amd64") },
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
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null" },
        .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "" },
        .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
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
        .{ .argv = apt_installed_call },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("amd64") },
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
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("amd64") },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update", .code = 100 },
    } };
    var d1: Distro = .{ .manager = .apt, .runner = refresh.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroRefreshFailed, d1.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!d1.backend().installSpawned());

    var timeout: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("amd64") },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = aptNamesCall("amd64"), .timed_out = true },
    } };
    var d2: Distro = .{ .manager = .apt, .runner = timeout.runner(), .force_elevate = false };
    try testing.expectError(error.CaptureTimedOut, d2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(!d2.backend().installSpawned());

    var arch: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dpkg --print-architecture", .code = 2 },
    } };
    var d3: Distro = .{ .manager = .apt, .runner = arch.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroQueryFailed, d3.backend().install(a, &.{rowOf("bat:armhf", &.{})}));
    try testing.expect(!d3.backend().installSpawned());

    // A batch whose every row is refused reaches no manager either: there is
    // nothing left to hand it.
    var refused: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n zlib-devel" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n zlib-devel", .stdout = "" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n --whatprovides zlib-devel", .stdout = "zlib-ng-compat-devel\n" },
    } };
    var d4: Distro = .{ .manager = .dnf, .runner = refused.runner(), .force_elevate = false };
    try d4.backend().install(a, &.{rowOf("zlib-devel", &.{})});
    try testing.expectEqual(@as(usize, 1), d4.backend().installRefused());
    try testing.expect(!d4.backend().installSpawned());

    // A manager that ran and failed part-way through is the other answer: its
    // rows may be on the machine, and a re-read must assume they are.
    var ran: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n", .match = .prefix },
        .{ .argv = "dnf install -y --setopt=assumeno=0 bat", .code = 1 },
    } };
    var d5: Distro = .{ .manager = .dnf, .runner = ran.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroInstallFailed, d5.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(d5.backend().installSpawned());

    // An adapter is asked afresh each time, never left saying what the last
    // batch did.
    var again: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n ripgrepp" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n ripgrepp", .stdout = "" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n --whatprovides ripgrepp", .stdout = "" },
    } };
    d5.runner = again.runner();
    try d5.backend().install(a, &.{rowOf("ripgrepp", &.{})});
    try testing.expectEqual(@as(usize, 1), d5.backend().installRefused());
    try testing.expect(!d5.backend().installSpawned());
    // And the count is the last batch's, never the one before it.
    var clean: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n bat", .stdout = "bat\n" },
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n", .match = .prefix },
        .{ .argv = "dnf install -y --setopt=assumeno=0 bat" },
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
        .{ .argv = apt_installed_call },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = aptNamesCall("arm64"), .stdout = "sl\nbat\n" },
        .{
            .argv = "apt-cache madison wine32:armhf",
            .stdout = "wine32:armhf | 10.0~repack-6 | http://deb.debian.org/debian trixie/main armhf Packages\n",
        },
        .{ .argv = "dpkg --print-foreign-architectures", .stdout = "armhf\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = comptime (aptStanza("wine32:armhf") ++ aptStanza("sl")) },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = apt_installed_call },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\nsl\n" },
        .{ .argv = apt_installed_call, .stdout = "bat arm64 install ok installed\nmoxlocaldemo arm64 install ok installed\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = aptStanza("moxlocaldemo") },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\n" },
        .{ .argv = apt_installed_call, .stdout = "moxallpkg all install ok installed\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = aptStanza("moxallpkg") },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = "apt-cache madison moxforeigndemo:armhf", .stdout = "" },
        .{ .argv = "dpkg --print-foreign-architectures", .stdout = "armhf\n" },
        .{ .argv = apt_installed_call, .stdout = "moxforeigndemo armhf install ok installed\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = aptStanza("moxforeigndemo:armhf") },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\nsl\n" },
        .{ .argv = apt_installed_call, .stdout = "bat arm64 install ok installed\n" },
        .{
            .argv = "apt-cache madison armv8-support",
            .stdout = "armv8-support:armhf |         27 | http://deb.debian.org/debian trixie/main armhf Packages\n",
        },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy sl", .stdout = aptStanza("sl") },
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

test "install: the bare-name listing asks for the native architecture alone, no dpkg status, and no virtual names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Each option closes a hole measured on apt 2.6.1, 2.8.3 and 3.0.3. The
    // architecture option drops the 78 armhf-only names the plain listing
    // prints bare on trixie; the status option drops the dpkg status file,
    // which prints an already-installed foreign package bare and keeps the
    // listing non-empty (78 lines on trixie, 88 on bookworm) on a machine
    // with no repositories at all. The AllNames option overrides an apt.conf
    // `APT::Cache::AllNames "true"`, under which the listing prints `awk`
    // (119883 lines against 62840 on bookworm) and the row would be refused
    // as pinned rather than told what provides it.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "amd64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("amd64") },
        .{ .argv = aptNamesCall("amd64"), .stdout = "bat\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = aptStanza("bat") },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = apt_installed_call },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(fake.called(
        "apt-cache -o APT::Architectures=amd64 -o Dir::State::status=/dev/null -o APT::Cache::AllNames=false --generate pkgnames",
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("amd64") },
        .{ .argv = aptNamesCall("amd64"), .stdout = "bat\nsl\n" },
        .{ .argv = "apt-mark showhold", .stdout = "sl\n" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = "bat:\n  Installed: (none)\n  Candidate: 0.25.0-2\n" },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = apt_installed_call },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("amd64") },
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
        .{ .argv = apt_installed_call },
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
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{
            .argv = "apt-cache madison libc6:armhf",
            .stdout = "libc6:armhf | 2.41-12+deb13u4 | http://deb.debian.org/debian trixie/main armhf Packages\n",
        },
        .{ .argv = "dpkg --print-foreign-architectures", .stdout = "armhf\n" },
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

/// What `apt-cache policy mox-flat-armhf mox-flat-i386 sl` printed on apt
/// 3.0.3 (trixie, arm64 with armhf added) over a flat repository holding an
/// armhf and an i386 package: every operand gets a stanza, the i386 one
/// included though dpkg has not enabled i386.
const flat_policy_303 =
    \\mox-flat-armhf:armhf:
    \\  Installed: (none)
    \\  Candidate: 1.0
    \\  Version table:
    \\     1.0 500
    \\        500 file:/repo ./ Packages
    \\mox-flat-i386:i386:
    \\  Installed: (none)
    \\  Candidate: 1.0
    \\  Version table:
    \\     1.0 500
    \\        500 file:/repo ./ Packages
    \\sl:
    \\  Installed: (none)
    \\  Candidate: 5.02-1+b1
    \\  Version table:
    \\     5.02-1+b1 500
    \\        500 http://deb.debian.org/debian stable/main arm64 Packages
    \\
;

/// The same query on apt 2.6.1 (bookworm): the i386 operand gets no stanza
/// at all, and nothing on stderr either.
const flat_policy_261 =
    \\mox-flat-armhf:armhf:
    \\  Installed: (none)
    \\  Candidate: 1.0
    \\  Version table:
    \\     1.0 500
    \\        500 file:/repo ./ Packages
    \\sl:
    \\  Installed: (none)
    \\  Candidate: 5.02-1
    \\  Version table:
    \\     5.02-1 500
    \\        500 http://deb.debian.org/debian bookworm/main arm64 Packages
    \\
;

test "install: a bare row a flat index holds for a foreign architecture alone is refused by its policy header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on apt 2.6.1, 2.8.3 and 3.0.3 with `deb [trusted=yes]
    // file:/repo ./` over an index from dpkg-scanpackages: the native
    // listing prints both `mox-flat-armhf` and `mox-flat-i386` bare, and
    // `apt-get install -y -- mox-flat-armhf` installs `mox-flat-armhf:armhf`,
    // which apt-mark reports qualified. The i386 row takes the batch down
    // instead: "Unable to locate package" on 2.6.1, "package architecture
    // (i386) does not match system (arm64)" from dpkg on 3.0.3.
    for ([_]struct { policy: []const u8, i386: []const u8 }{
        .{
            .policy = flat_policy_303,
            .i386 = "mox: apt: row \"mox-flat-i386\" names an apt package for the architecture \"i386\" alone, which this machine's dpkg has not enabled, so an install carrying it fails at dpkg and installs nothing at all, and it was not installed; `dpkg --add-architecture i386` and declare \"mox-flat-i386:i386\" to let mox install it\n",
        },
        .{
            .policy = flat_policy_261,
            .i386 = "mox: apt: row \"mox-flat-i386\" names a package apt-cache policy prints no stanza for, which is an operand apt cannot locate at all, and an install carrying one installs nothing at all, so it was not installed\n",
        },
    }) |c| {
        var fake: exec.Fake = .{ .arena = a, .entries = &.{
            .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
            .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
            .{ .argv = apt_installed_call },
            .{ .argv = "apt-mark showauto" },
            .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
            .{ .argv = aptNamesCall("arm64"), .stdout = "mox-flat-i386\nmox-flat-armhf\nsl\n" },
            .{ .argv = "apt-mark showhold" },
            .{ .argv = "apt-cache policy mox-flat-armhf mox-flat-i386 sl", .stdout = c.policy },
            .{ .argv = "dpkg --print-foreign-architectures", .stdout = "armhf\n" },
            .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- sl" },
        } };
        var w: std.Io.Writer.Allocating = .init(a);
        var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

        try d.backend().install(a, &.{ rowOf("mox-flat-armhf", &.{}), rowOf("mox-flat-i386", &.{}), rowOf("sl", &.{}) });
        try testing.expectEqual(@as(usize, 2), d.backend().installRefused());
        const want = try std.mem.concat(a, u8, &.{
            "mox: apt: row \"mox-flat-armhf\" names an apt package for the architecture \"armhf\" alone, which apt-mark reports as \"mox-flat-armhf:armhf\", so the row could never read as installed; declare \"mox-flat-armhf:armhf\" instead\n",
            c.i386,
        });
        try testing.expectEqualStrings(want, w.written());
        try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- sl"));
        // The flat index gave the listing nothing to refuse on, so madison
        // was never the oracle here.
        for (fake.calls.items) |call| try testing.expect(std.mem.indexOf(u8, call, "madison") == null);
    }
}

test "install: a bare row after the qualified one for the same package takes its own stanza, not the one before it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `apt-cache policy` prints one stanza per operand, in operand order,
    // with no dedup, so each row must take the next stanza that answers it
    // rather than the first. Both rows are legal on a machine with armhf
    // added, and measured there on apt 3.0.3 (trixie) and 2.6.1
    // (bookworm), `apt-cache policy sl:armhf sl` prints the armhf stanza
    // first:
    //
    //     sl:armhf:
    //       Installed: (none)
    //       Candidate: 5.02-1
    //       Version table:
    //          5.02-1 500
    //             500 http://deb.debian.org/debian stable/main armhf Packages
    //     sl:
    //       Installed: (none)
    //       Candidate: 5.02-1+b1
    //       Version table:
    //          5.02-1+b1 500
    //             500 http://deb.debian.org/debian stable/main arm64 Packages
    //
    // A bare row taking the first stanza that answers it would read the
    // armhf header and be refused as foreign-only, though apt installs it
    // native.
    const policy =
        "sl:armhf:\n  Installed: (none)\n  Candidate: 5.02-1\n  Version table:\n     5.02-1 500\n        500 http://deb.debian.org/debian stable/main armhf Packages\n" ++
        "sl:\n  Installed: (none)\n  Candidate: 5.02-1+b1\n  Version table:\n     5.02-1+b1 500\n        500 http://deb.debian.org/debian stable/main arm64 Packages\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "dpkg --print-foreign-architectures", .stdout = "armhf\n" },
        .{
            .argv = "apt-cache madison sl:armhf",
            .stdout = "sl:armhf |     5.02-1 | http://deb.debian.org/debian stable/main armhf Packages\n",
        },
        .{ .argv = aptNamesCall("arm64"), .stdout = "sl\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy sl:armhf sl", .stdout = policy },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- sl:armhf sl" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("sl:armhf", &.{}), rowOf("sl", &.{}) });
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expectEqualStrings("", w.written());
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- sl:armhf sl"));
}

test "install: a stanza whose header merely extends the row's name answers the row it was printed for" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A stanza answers a bare row when its header is that name qualified,
    // which is a `:` after the name and nothing else. Measured on apt 2.6.1
    // (bookworm) with a flat index from dpkg-scanpackages holding
    // `mox-flat-i386` built i386 and `mox-flat-i386-tools` built arm64,
    // i386 not enabled: the native listing prints both bare, and
    // `apt-cache policy mox-flat-i386 mox-flat-i386-tools` prints one
    // stanza only --
    //
    //     mox-flat-i386-tools:
    //       Installed: (none)
    //       Candidate: 1.0
    //       Version table:
    //          1.0 500
    //             500 file:/repo ./ Packages
    //
    // -- so a rule that took any header starting with the row's name would
    // keep the row apt cannot locate and refuse the one it would install.
    const policy = "mox-flat-i386-tools:\n  Installed: (none)\n  Candidate: 1.0\n  Version table:\n     1.0 500\n        500 file:/repo ./ Packages\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "mox-flat-i386\nmox-flat-i386-tools\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy mox-flat-i386 mox-flat-i386-tools", .stdout = policy },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- mox-flat-i386-tools" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("mox-flat-i386", &.{}), rowOf("mox-flat-i386-tools", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: apt: row \"mox-flat-i386\" names a package apt-cache policy prints no stanza for, which is an operand apt cannot locate at all, and an install carrying one installs nothing at all, so it was not installed\n",
        w.written(),
    );
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- mox-flat-i386-tools"));
}

test "install: the policy stanzas are matched to the rows in order, a row apt cannot locate taking none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The unlocatable row sits between two answered ones, so a match by
    // position would hand it the stanza after it and refuse the wrong row.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\nmox-flat-i386\nsl\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy bat mox-flat-i386 sl", .stdout = comptime (aptStanza("bat") ++ aptStanza("sl")) },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat sl" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("mox-flat-i386", &.{}), rowOf("sl", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expect(std.mem.indexOf(u8, w.written(), "row \"mox-flat-i386\" names a package apt-cache policy prints no stanza for") != null);
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat sl"));
}

test "install: a qualified row a flat index carries installs, madison naming the architecture in the name column" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on apt 2.6.1 and 3.0.3: the flat line is `mox-flat-armhf:armhf
    // |        1.0 | file:/repo ./ Packages`, whose word before `Packages`
    // is the suite `./` rather than an architecture, and `apt-get install
    // -y -- mox-flat-armhf:armhf` installs it, after which apt-mark reports
    // `mox-flat-armhf:armhf` and the row converges.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-foreign-architectures", .stdout = "armhf\n" },
        .{ .argv = "apt-cache madison mox-flat-armhf:armhf", .stdout = "mox-flat-armhf:armhf |        1.0 | file:/repo ./ Packages\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy mox-flat-armhf:armhf", .stdout = "mox-flat-armhf:armhf:\n  Installed: (none)\n  Candidate: 1.0\n  Version table:\n     1.0 500\n        500 file:/repo ./ Packages\n" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- mox-flat-armhf:armhf" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("mox-flat-armhf:armhf", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expectEqualStrings("", w.written());
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- mox-flat-armhf:armhf"));

    // The same line read for a bare row the listing lacks: the architecture
    // comes from the name column, never from the suite, so the row is told
    // the qualified spelling rather than kept for a `./` architecture.
    var bare: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "sl\n" },
        .{ .argv = "apt-cache madison mox-flat-armhf", .stdout = "mox-flat-armhf:armhf |        1.0 | file:/repo ./ Packages\n" },
    } };
    var bw: std.Io.Writer.Allocating = .init(a);
    var db: Distro = .{ .manager = .apt, .runner = bare.runner(), .force_elevate = false, .err = &bw.writer };
    try db.backend().install(a, &.{rowOf("mox-flat-armhf", &.{})});
    try testing.expectEqual(@as(usize, 1), db.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: apt: row \"mox-flat-armhf\" names an apt package for the architecture \"armhf\" alone, which apt-mark reports as \"mox-flat-armhf:armhf\", so the row could never read as installed; declare \"mox-flat-armhf:armhf\" instead\n",
        bw.written(),
    );

    // A native package in a flat index is spelled bare in that column, and
    // is what the listing already kept: the line names no foreign
    // architecture, so the row is refused as the listing's regex case.
    var native: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "sl\n" },
        .{ .argv = "apt-cache madison mox-flat-native", .stdout = "mox-flat-native |        1.0 | file:/repo ./ Packages\n" },
        .{ .argv = "apt-cache showpkg mox-flat-native", .stdout = "" },
    } };
    var nw: std.Io.Writer.Allocating = .init(a);
    var dn: Distro = .{ .manager = .apt, .runner = native.runner(), .force_elevate = false, .err = &nw.writer };
    try dn.backend().install(a, &.{rowOf("mox-flat-native", &.{})});
    try testing.expect(std.mem.indexOf(u8, nw.written(), "declare") == null);
    try testing.expect(std.mem.indexOf(u8, nw.written(), "row \"mox-flat-native\" names no apt package") != null);
}

test "install: a qualified row naming an architecture dpkg has not enabled is refused, unless dpkg has the package under it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on apt 2.6.1 and 3.0.3: `dpkg --print-foreign-architectures`
    // prints nothing when none is enabled, and `apt-cache madison` on 3.0.3
    // still lists `mox-flat-i386:i386` from a flat index -- so the enabled
    // set is what says the install would fail at dpkg.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "dpkg --print-foreign-architectures", .stdout = "" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("mox-flat-i386:i386", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: apt: row \"mox-flat-i386:i386\" qualifies the architecture \"i386\", which this machine's dpkg has not enabled and has no package installed under, so it was not installed; `dpkg --add-architecture i386` to let mox install it\n",
        w.written(),
    );
    for (fake.calls.items) |call| try testing.expect(std.mem.indexOf(u8, call, "madison") == null);

    // `dpkg -i --force-architecture` leaves a package installed under an
    // architecture dpkg has not enabled; measured on both, `apt-cache policy
    // mox-force-i386:i386` answers a stanza from the status file and
    // `apt-get install -y -- mox-force-i386:i386` exits 0 setting it manual.
    var forced: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = apt_installed_call, .stdout = "mox-force-i386 i386 install ok installed\n" },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy mox-force-i386:i386", .stdout = "mox-force-i386:i386:\n  Installed: 1.0\n  Candidate: 1.0\n  Version table:\n *** 1.0 100\n        100 /var/lib/dpkg/status\n" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- mox-force-i386:i386" },
    } };
    var fw: std.Io.Writer.Allocating = .init(a);
    var df: Distro = .{ .manager = .apt, .runner = forced.runner(), .force_elevate = false, .err = &fw.writer };
    try df.backend().install(a, &.{rowOf("mox-force-i386:i386", &.{})});
    try testing.expectEqual(@as(usize, 0), df.backend().installRefused());
    try testing.expectEqualStrings("", fw.written());
    try testing.expect(forced.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- mox-force-i386:i386"));
}

test "installedExplicit: apt's manual set holds only what dpkg has configured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on apt 2.6.1 and 3.0.3 with `sl` unpacked by `dpkg --unpack`
    // over its installed self: `apt-mark showmanual` prints `sl` and
    // `dpkg-query` answers `sl arm64 install ok unpacked`. A foreign package
    // is spelled qualified by apt-mark and bare with its architecture by
    // dpkg-query, and a Multi-Arch: same native one is bare in both.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showmanual", .stdout = "sl\ncowsay\nlibc6\nlibc6:armhf\nmox-gone\n" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{
            .argv = apt_installed_call,
            .stdout = "cowsay all install ok installed\nlibc6 arm64 install ok installed\nlibc6 armhf install ok installed\nmox-gone arm64 deinstall ok config-files\nsl arm64 install ok unpacked\n",
        },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = true };

    const got = try d.backend().installedExplicit(a);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("cowsay", got[0]);
    try testing.expectEqualStrings("libc6", got[1]);
    try testing.expectEqualStrings("libc6:armhf", got[2]);
}

test "install: apt is asked which architecture it resolves against, and agreeing costs the run nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The argv, and the answer, measured identically on apt 2.6.1 (Debian
    // bookworm) and 3.0.3 (Debian trixie), arm64 with armhf added, both with
    // `APT::Architecture "arm64";` configured and with the key unset:
    //
    //     $ apt-config dump APT::Architecture
    //     APT::Architecture "arm64";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = "apt-config dump APT::Architecture", .stdout = "APT::Architecture \"arm64\";\n" },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = aptStanza("bat") },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(fake.called("apt-config dump APT::Architecture"));
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat"));
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expectEqualStrings("", w.written());
}

test "install: apt resolving against another architecture than dpkg's stops the whole pass, naming both" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on apt 2.6.1 and 3.0.3, arm64 with armhf added and
    // `APT::Architecture "armhf";` in /etc/apt/apt.conf.d: `dpkg
    // --print-architecture` still answers `arm64` while
    //
    //     $ apt-config dump APT::Architecture
    //     APT::Architecture "armhf";
    //
    // Nothing else in the oracle sees it -- `apt-cache policy sl` heads the
    // stanza bare over an armhf-only version table and `apt-cache madison sl`
    // reports the armhf line alone -- so the row passes every refusal and
    // `apt-get install -y -- sl` then fails on libc6, libncurses6 and
    // libtinfo6, taking the rest of the batch with it.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = "apt-config dump APT::Architecture", .stdout = "APT::Architecture \"armhf\";\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(
        Error.DistroArchitectureDisagrees,
        d.backend().install(a, &.{ rowOf("sl", &.{}), rowOf("bat", &.{}) }),
    );
    // The refusal lands before anything is read, refreshed or installed, so
    // no row of the batch is judged and none is put on the machine.
    try testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    try testing.expect(!d.backend().installSpawned());
    try testing.expectEqualStrings(
        "mox: apt: apt's own APT::Architecture is \"armhf\" while dpkg's architecture is \"arm64\", so apt resolves every row against packages dpkg cannot install and no row on this machine could converge; unset APT::Architecture so apt agrees with `dpkg --print-architecture`\n",
        w.written(),
    );
}

test "installedExplicit: the same disagreement stops the report, so apt-mark's other machine is never read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The same setting makes apt-mark answer about the architecture apt is
    // configured for: measured on apt 2.6.1 and 3.0.3 under `APT::Architecture
    // "armhf";`, `apt-mark showmanual` prints 10 names on bookworm and 9 on
    // trixie -- adduser, debconf, debian-archive-keyring and the rest -- where
    // the same untouched machine prints none. Every one of them is installed
    // and configured, so nothing downstream would drop them and `status` would
    // report each as untracked.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "apt-mark showmanual", .stdout = "debconf\ndebian-archive-keyring\ninit-system-helpers\n" },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = "apt-config dump APT::Architecture", .stdout = "APT::Architecture \"armhf\";\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = true, .err = &w.writer };

    try testing.expectError(Error.DistroArchitectureDisagrees, d.backend().installedExplicit(a));
    try testing.expect(!fake.called(apt_installed_call));
    try testing.expect(std.mem.indexOf(u8, w.written(), "APT::Architecture is \"armhf\"") != null);
}

test "install: apt naming no architecture of its own is nothing to disagree with" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `apt-config dump <key>` prints nothing at all and exits 0 for a key apt
    // has no value for, measured on apt 2.6.1 and 3.0.3. apt always has one
    // for this key, so an empty answer is a shape neither version produces;
    // reading it as a disagreement would refuse a machine over an answer that
    // names no architecture to disagree about.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = "apt-config dump APT::Architecture" },
        .{ .argv = apt_installed_call },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "bat\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy", .match = .prefix, .stdout = aptStanza("bat") },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- bat"));
}

test "install: an apt-config that cannot answer is a failed query, never an agreement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = "apt-config dump APT::Architecture", .code = 100 },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false };

    try testing.expectError(Error.DistroQueryFailed, d.backend().install(a, &.{rowOf("bat", &.{})}));
}

test "install: a row apt-mark reports but dpkg left unpacked is installed, which configures it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on apt 2.6.1 and 3.0.3: `apt-get install -y -- sl` on the
    // unpacked package exits 0 printing `Setting up sl`, and on an unpacked
    // package apt-mark holds as auto it prints "cowsay is already the newest
    // version", "cowsay set to manually installed" and configures it too --
    // where `apt-mark manual cowsay` alone leaves it unpacked. So neither
    // row is marked; both go to the install.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = apt_arch_call, .stdout = aptArchDump("arm64") },
        .{ .argv = apt_installed_call, .stdout = "cowsay all install ok unpacked\nsl arm64 install ok unpacked\n" },
        .{ .argv = "apt-mark showauto", .stdout = "cowsay\n" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update" },
        .{ .argv = aptNamesCall("arm64"), .stdout = "cowsay\nsl\n" },
        .{ .argv = "apt-mark showhold" },
        .{ .argv = "apt-cache policy sl cowsay", .stdout = comptime (aptStanza("sl") ++ aptStanza("cowsay")) },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- sl cowsay" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("sl", &.{}), rowOf("cowsay", &.{}) });
    try testing.expectEqual(@as(usize, 0), d.backend().installMarked());
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expect(fake.called("env DEBIAN_FRONTEND=noninteractive apt-get install -y -- sl cowsay"));
    for (fake.calls.items) |call| try testing.expect(std.mem.indexOf(u8, call, "apt-mark manual") == null);
}

test "install: dnf's install and mark carry --setopt=assumeno=0, which a dnf.conf assumeno=True would otherwise beat" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured under `assumeno=True` in dnf.conf: `dnf install -y tree`
    // exits 1 with "Operation aborted." on dnf 4.14.0 and `dnf install -y
    // sl` with "Operation aborted by the user." on dnf5 5.2.18 and 5.4.3,
    // nothing installed; `dnf mark user -y sl` on both dnf5 the same. With
    // the option each exits 0 and does its work.
    var five: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n bat sl", .stdout = "bat\n" },
        .{ .argv = "dnf --version", .stdout = "dnf5 version 5.2.18.0\n" },
        .{ .argv = "sudo dnf mark user -y --setopt=assumeno=0 bat" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n sl", .stdout = "sl\n" },
        .{ .argv = "sudo dnf install -y --setopt=assumeno=0 sl" },
    } };
    var d5: Distro = .{ .manager = .dnf, .runner = five.runner(), .force_elevate = true };
    try d5.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("sl", &.{}) });
    try testing.expect(five.called("sudo dnf mark user -y --setopt=assumeno=0 bat"));
    try testing.expectEqualStrings("sudo dnf install -y --setopt=assumeno=0 sl", five.calls.items[five.calls.items.len - 1]);

    var four: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n bat tree", .stdout = "bat\n" },
        .{ .argv = "dnf --version", .stdout = "4.14.0\n" },
        .{ .argv = "sudo dnf mark install --setopt=assumeno=0 bat" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n tree", .stdout = "tree\n" },
        .{ .argv = "sudo dnf install -y --setopt=assumeno=0 tree" },
    } };
    var d4: Distro = .{ .manager = .dnf, .runner = four.runner(), .force_elevate = true };
    try d4.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("tree", &.{}) });
    try testing.expect(four.called("sudo dnf mark install --setopt=assumeno=0 bat"));
    try testing.expectEqualStrings("sudo dnf install -y --setopt=assumeno=0 tree", four.calls.items[four.calls.items.len - 1]);
}

test "query: every dnf listing carries --assumeno, which declines the question dnf asks on stdout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on dnf 4.14.0 (rockylinux:9), dnf5 5.2.18 (fedora:42) and
    // 5.4.3 (fedora:latest): each of these three listings exits 0 and comes
    // back byte for byte identical with the option and without it, the whole
    // name listing among them at 12076, 72747 and 69627 lines.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --userinstalled --qf %{name}\n", .stdout = "bat\n" },
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n jq", .stdout = "" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n jq", .stdout = "jq\n" },
        .{ .argv = "dnf install -y --setopt=assumeno=0 jq" },
    } };
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false };

    const explicit = try d.backend().installedExplicit(a);
    try testing.expectEqual(@as(usize, 1), explicit.len);
    try d.backend().install(a, &.{rowOf("jq", &.{})});

    var listings: usize = 0;
    for (fake.calls.items) |c| {
        if (std.mem.indexOf(u8, c, "repoquery") == null) continue;
        listings += 1;
        try testing.expect(std.mem.indexOf(u8, c, "dnf -q --assumeno repoquery") != null);
    }
    try testing.expectEqual(@as(usize, 3), listings);
    try testing.expect(fake.called("dnf install -y --setopt=assumeno=0 jq"));
}

test "query: dnf's key question is not read back as a package name, whatever puts it on stdout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on dnf 4.14.0 (rockylinux:9) with `repo_gpgcheck=1` and
    // `skip_if_unavailable=1` on the `extras` repository, whose signing key
    // rpm has not imported, and `jq` in `baseos`, which answers: `dnf -q
    // repoquery --qf '%{name}\n' jq` exits 0 having written `Is this ok
    // [y/N]: jq\n\n` -- the question, ended without a newline of its own, so
    // the one real name is glued to it, then dnf4's own blank line.
    // `--assumeno` keeps the question off that stdout; this is the second
    // line of defence, so the double writes those bytes back on the argv
    // that carries the option.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n jq" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n jq", .stdout = "Is this ok [y/N]: jq\n\n" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n --whatprovides jq", .stdout = "Is this ok [y/N]: jq\n\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .dnf, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("jq", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: dnf: row \"jq\" names no package dnf will install here: no enabled repository carries it, or an exclude in dnf's configuration keeps it out\n",
        w.written(),
    );
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "dnf install") == null);

    // The listing that answers what the user installed on purpose is read
    // the same way: a question left on it would otherwise be a package
    // `status` calls untracked and `commit` offers to record.
    var listed: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "dnf -q --assumeno repoquery --userinstalled --qf %{name}\n", .stdout = "Is this ok [y/N]: jq\n\nbat\n" },
    } };
    var d2: Distro = .{ .manager = .dnf, .runner = listed.runner(), .force_elevate = false };
    const explicit = try d2.backend().installedExplicit(a);
    try testing.expectEqual(@as(usize, 1), explicit.len);
    try testing.expectEqualStrings("bat", explicit[0]);
}

const pacman_probe = "stat -L -c %n %a %F " ++ pacman_cache ++ " " ++ pdb;
const pacman_probe_ready = pacman_cache ++ " 755 directory\n" ++ pdb ++ " 755 directory\n";
const pacman_link = "readlink " ++ pdb ++ "/local";
const pacman_make = pacmanMakeCall("/var/lib/pacman/local");

/// The one call that makes the copy, with `local` the system's, as the
/// Fake joins it.
fn pacmanMakeCall(comptime local: []const u8) []const u8 {
    return "sh -c " ++ Distro.pacman_make_script ++ " sh " ++ pacman_cache ++ " " ++ pdb ++ " " ++ local ++ " " ++ pdb ++ "/local";
}
const pacman_print = "pacman -S --print --print-format %n --dbpath " ++ pdb ++ " --";
const pacman_info = "pacman -Si --dbpath " ++ pdb ++ " --";
const pacman_pending = "pacman -Qu --dbpath " ++ pdb;

/// What the upgrade's own target list prints on a machine with nothing to
/// upgrade: measured on pacman 7.1.0, exit 0 with both streams empty.
const nothing_to_upgrade: exec.Fake.Entry = .{ .argv = "pacman -Su --print --print-format %n --dbpath " ++ pdb };

test "install: pacman refuses a row whose dependency nothing satisfies, in pacman's own words, and installs the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0 with synced databases: `pacman -S --print
    // -- amsynth` exits 1 with `error: failed to prepare transaction (could
    // not satisfy dependencies)` on stderr and `:: unable to satisfy
    // dependency 'gtk2' required by amsynth` on stdout, the same exit as
    // "target not found". Read by the exit code alone, mox told the user
    // their repository's Usage in pacman.conf was wrong, quoting a "target
    // not found" pacman never printed.
    const unsat_err = "error: failed to prepare transaction (could not satisfy dependencies)\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "extra amsynth 1.13.4-1\nextra cowsay 3.8.4-1\n" },
        .{ .argv = pacman_print ++ " amsynth cowsay", .code = 1, .stderr = unsat_err, .stdout = ":: unable to satisfy dependency 'gtk2' required by amsynth\n" },
        .{ .argv = pacman_print ++ " amsynth", .code = 1, .stderr = unsat_err, .stdout = ":: unable to satisfy dependency 'gtk2' required by amsynth\n" },
        .{ .argv = pacman_print ++ " cowsay", .stdout = "cowsay\n" },
        .{ .argv = pacman_info ++ " cowsay", .stdout = "Name            : cowsay\nVersion         : 3.8.4-1\nProvides        : None\nConflicts With  : None\n" },
        .{ .argv = "pacman -Qi", .stdout = "Name            : bash\nVersion         : 5.3-1\nProvides        : sh\nConflicts With  : None\n" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Syu --needed --noconfirm -- cowsay" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("amsynth", &.{}), rowOf("cowsay", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"amsynth\" names a package pacman cannot install here, a dependency of it being satisfied by nothing in this machine's repositories (unable to satisfy dependency 'gtk2' required by amsynth), so it was not installed; add the repository that carries it, or drop the row\n",
        w.written(),
    );
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- cowsay"));
    try testing.expect(std.mem.indexOf(u8, w.written(), "Usage") == null);
    try testing.expect(std.mem.indexOf(u8, w.written(), "target not found") == null);

    // A failure pacman explains some other way is relayed as pacman said
    // it, and refuses the row alone.
    var other: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "extra cowsay 3.8.4-1\nside odd 1-1\n" },
        .{ .argv = pacman_print ++ " odd cowsay", .code = 1, .stderr = "error: database 'side' is not valid (invalid or corrupted database (PGP signature))\n" },
        .{ .argv = pacman_print ++ " odd", .code = 1, .stderr = "error: database 'side' is not valid (invalid or corrupted database (PGP signature))\n" },
        .{ .argv = pacman_print ++ " cowsay", .stdout = "cowsay\n" },
        .{ .argv = pacman_info, .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Syu --needed --noconfirm -- cowsay" },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = other.runner(), .force_elevate = false, .err = &w2.writer };
    try d2.backend().install(a, &.{ rowOf("odd", &.{}), rowOf("cowsay", &.{}) });
    try testing.expectEqual(@as(usize, 1), d2.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"odd\" was not installed: `pacman -S --print` exited 1 resolving it, saying: error: database 'side' is not valid (invalid or corrupted database (PGP signature))\n",
        w2.written(),
    );
    try testing.expect(other.called("pacman -Syu --needed --noconfirm -- cowsay"));
}

test "install: pacman refuses a row that conflicts with an installed package, naming it, and installs the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0 with pulseaudio installed: `pacman -S
    // --print -- pipewire-pulse cowsay` prints both and exits 0, with
    // `--noconfirm` too; `pacman -Syu --needed --noconfirm -- pipewire-pulse
    // cowsay` asks "Remove pulseaudio? [y/N]", answers it no, says
    // "unresolvable package conflicts detected", exits 1, and cowsay is
    // not installed -- on every apply. `pacman -Si pipewire-pulse` reads
    // `Conflicts With  : pulseaudio`, and `pacman -Qi` has pulseaudio.
    const si = "Name            : pipewire-pulse\nVersion         : 1:1.6.8-1\nProvides        : pulse-native-provider\nConflicts With  : pulseaudio\nReplaces        : None\n\nName            : cowsay\nVersion         : 3.8.4-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n";
    const qi = "Name            : pulseaudio\nVersion         : 17.0+r98+gb096704c0-1\nProvides        : pulse-native-provider\nConflicts With  : pipewire-pulse\nReplaces        : None\n\nName            : bash\nVersion         : 5.3-1\nProvides        : sh\nConflicts With  : None\nReplaces        : None\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "extra pipewire-pulse 1:1.6.8-1\nextra cowsay 3.8.4-1\n" },
        .{ .argv = pacman_print ++ " pipewire-pulse cowsay", .stdout = "libpipewire\npipewire-pulse\ncowsay\n" },
        .{ .argv = pacman_info ++ " pipewire-pulse cowsay", .stdout = si },
        .{ .argv = "pacman -Qi", .stdout = qi },
        .{ .argv = pacman_pending, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Syu --needed --noconfirm -- cowsay" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("pipewire-pulse", &.{}), rowOf("cowsay", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"pipewire-pulse\" names a package that conflicts with \"pulseaudio\", which this machine has installed; pacman would have to remove pulseaudio to install it, and mox never removes a package, so the row was not installed: remove pulseaudio yourself, or drop the row\n",
        w.written(),
    );
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- cowsay"));
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "-R") == null);
    // A bare spec needs no comparison.
    try testing.expectEqual(@as(usize, 0), countCalls(&fake, "vercmp"));

    // A conflict spelled as a provision names the package that provides
    // it, `pacman -Qi` listing the provision under that package. The spec
    // nothing installed answers to (`jack<2`) is no conflict.
    var prov: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "extra other-sound 1-1\n" },
        .{ .argv = pacman_print ++ " other-sound", .stdout = "other-sound\n" },
        .{ .argv = pacman_info ++ " other-sound", .stdout = "Name            : other-sound\nVersion         : 1-1\nProvides        : None\nConflicts With  : jack<2  pulse-native-provider\nReplaces        : None\n" },
        .{ .argv = "pacman -Qi", .stdout = qi },
        .{ .argv = pacman_pending, .code = 1 },
        nothing_to_upgrade,
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = prov.runner(), .force_elevate = false, .err = &w2.writer };
    try d2.backend().install(a, &.{rowOf("other-sound", &.{})});
    try testing.expectEqual(@as(usize, 1), d2.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"other-sound\" names a package that conflicts with \"pulse-native-provider\", which this machine has installed as \"pulseaudio\"; pacman would have to remove pulseaudio to install it, and mox never removes a package, so the row was not installed: remove pulseaudio yourself, or drop the row\n",
        w2.written(),
    );
    try testing.expect(!d2.backend().installSpawned());
}

test "install: a versioned pacman conflict is judged against the version the apply's upgrade leaves" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0 with a repository of `srv` at 1-1 and 2-1
    // and `drv` declaring `conflict = srv<2`, srv 1-1 installed: `pacman
    // -Qu --dbpath <copy>` prints `srv 1-1 -> 2-1` and exits 0, `vercmp
    // 1-1 2` is -1 and `vercmp 2-1 2` is 0, and `pacman -Syu --needed
    // --noconfirm -- drv` upgrades srv and installs drv in the one
    // transaction (`Packages (2) srv-2-1  drv-1-1`, exit 0). Judged
    // against the machine as it stood, the row was refused on every
    // apply, with instructions to remove a package the upgrade moves past.
    const drv = "Name            : drv\nVersion         : 1-1\nProvides        : None\nConflicts With  : srv<2\nReplaces        : None\n";
    const srv_old = "Name            : srv\nVersion         : 1-1\nProvides        : virt=1\nConflicts With  : None\nReplaces        : None\n";
    const srv_new = "Repository      : moxtest\nName            : srv\nVersion         : 2-1\nProvides        : virt=2\nConflicts With  : None\nReplaces        : None\n";
    var pending: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest drv 1-1\nmoxtest srv 2-1\n" },
        .{ .argv = pacman_print ++ " drv", .stdout = "drv\n" },
        .{ .argv = pacman_info ++ " drv", .stdout = drv },
        .{ .argv = "pacman -Qi", .stdout = srv_old },
        .{ .argv = pacman_pending, .stdout = "libsecret 0.21.7-1 -> 0.21.8.2-1\nsrv 1-1 -> 2-1\n" },
        nothing_to_upgrade,
        .{ .argv = pacman_info ++ " srv", .stdout = srv_new },
        .{ .argv = "vercmp 2-1 2", .stdout = "0\n" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- drv" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = pending.runner(), .force_elevate = false, .err = &w.writer };
    try d.backend().install(a, &.{rowOf("drv", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expectEqualStrings("", w.written());
    try testing.expect(pending.called("pacman -Syu --needed --noconfirm -- drv"));
    try testing.expect(!pending.called("vercmp 1-1 2"));

    // No upgrade pending: the installed version is the one judged, and it
    // does satisfy `srv<2`.
    var settled: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest drv 1-1\nmoxtest srv 1-1\n" },
        .{ .argv = pacman_print ++ " drv", .stdout = "drv\n" },
        .{ .argv = pacman_info ++ " drv", .stdout = drv },
        .{ .argv = "pacman -Qi", .stdout = srv_old },
        .{ .argv = pacman_pending, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "vercmp 1-1 2", .stdout = "-1\n" },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = settled.runner(), .force_elevate = false, .err = &w2.writer };
    try d2.backend().install(a, &.{rowOf("drv", &.{})});
    try testing.expectEqual(@as(usize, 1), d2.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"drv\" names a package that conflicts with \"srv<2\", which this machine has installed as \"srv\"; pacman would have to remove srv to install it, and mox never removes a package, so the row was not installed: remove srv yourself, or drop the row\n",
        w2.written(),
    );
    try testing.expect(!d2.backend().installSpawned());

    // An upgrade `IgnorePkg` keeps back is not one the apply makes: the
    // installed version stays the one judged.
    var ignored: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest drv 1-1\nmoxtest srv 2-1\n" },
        .{ .argv = pacman_print ++ " drv", .stdout = "drv\n" },
        .{ .argv = pacman_info ++ " drv", .stdout = drv },
        .{ .argv = "pacman -Qi", .stdout = srv_old },
        .{ .argv = pacman_pending, .stdout = "srv 1-1 -> 2-1 [ignored]\n" },
        nothing_to_upgrade,
        .{ .argv = "vercmp 1-1 2", .stdout = "-1\n" },
    } };
    var w3: std.Io.Writer.Allocating = .init(a);
    var d3: Distro = .{ .manager = .pacman, .runner = ignored.runner(), .force_elevate = false, .err = &w3.writer };
    try d3.backend().install(a, &.{rowOf("drv", &.{})});
    try testing.expectEqual(@as(usize, 1), d3.backend().installRefused());
    try testing.expect(!ignored.called(pacman_info ++ " srv"));

    // A provision the upgrade raises past the spec: `virt<2` against
    // `virt=1` today and `virt=2` after.
    const vdrv = "Name            : vdrv\nVersion         : 1-1\nProvides        : None\nConflicts With  : virt<2\nReplaces        : None\n";
    var provided: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest vdrv 1-1\nmoxtest srv 2-1\n" },
        .{ .argv = pacman_print ++ " vdrv", .stdout = "vdrv\n" },
        .{ .argv = pacman_info ++ " vdrv", .stdout = vdrv },
        .{ .argv = "pacman -Qi", .stdout = srv_old },
        .{ .argv = pacman_pending, .stdout = "srv 1-1 -> 2-1\n" },
        nothing_to_upgrade,
        .{ .argv = pacman_info ++ " srv", .stdout = srv_new },
        .{ .argv = "vercmp 2 2", .stdout = "0\n" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- vdrv" },
    } };
    var d4: Distro = .{ .manager = .pacman, .runner = provided.runner(), .force_elevate = false };
    try d4.backend().install(a, &.{rowOf("vdrv", &.{})});
    try testing.expectEqual(@as(usize, 0), d4.backend().installRefused());
    try testing.expect(provided.called("pacman -Syu --needed --noconfirm -- vdrv"));

    // `vercmp` that could not compare: said, and the row left to pacman.
    var broken: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest drv 1-1\nmoxtest srv 1-1\n" },
        .{ .argv = pacman_print ++ " drv", .stdout = "drv\n" },
        .{ .argv = pacman_info ++ " drv", .stdout = drv },
        .{ .argv = "pacman -Qi", .stdout = srv_old },
        .{ .argv = pacman_pending, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "vercmp 1-1 2", .code = 127 },
        .{ .argv = "pacman -Syu --needed --noconfirm -- drv" },
    } };
    var w5: std.Io.Writer.Allocating = .init(a);
    var d5: Distro = .{ .manager = .pacman, .runner = broken.runner(), .force_elevate = false, .err = &w5.writer };
    try d5.backend().install(a, &.{rowOf("drv", &.{})});
    try testing.expectEqual(@as(usize, 0), d5.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: `vercmp 1-1 2` exited 127 rather than comparing them, so whether \"srv<2\" is a conflict is left to pacman, which then installs none of the batch if it is\n",
        w5.written(),
    );
    try testing.expect(broken.called("pacman -Syu --needed --noconfirm -- drv"));
}

test "install: a package the row replaces is no conflict, since the apply's upgrade replaces it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0 with `newpkg` declaring `conflict = oldpkg`
    // and `replaces = oldpkg<2`, oldpkg 1-1 installed: `pacman -Si` reads
    // `Conflicts With  : oldpkg` and `Replaces        : oldpkg<2`, `vercmp
    // 1-1 2` is -1, and `pacman -Syu --needed --noconfirm -- newpkg` asks
    // ":: Replace oldpkg with moxtest/newpkg? [Y/n]", takes the yes, and
    // exits 0 with newpkg installed and oldpkg gone. Judged as a conflict,
    // the row was refused on every apply, with instructions to remove a
    // package pacman would have replaced.
    const si = "Name            : newpkg\nVersion         : 1-1\nProvides        : None\nConflicts With  : oldpkg\nReplaces        : oldpkg<2\n";
    const qi = "Name            : oldpkg\nVersion         : 1-1\nProvides        : None\nConflicts With  : newpkg\nReplaces        : None\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest newpkg 1-1\nmoxtest oldpkg 1-1\n" },
        .{ .argv = pacman_print ++ " newpkg", .stdout = "newpkg\n" },
        .{ .argv = pacman_info ++ " newpkg", .stdout = si },
        .{ .argv = "pacman -Qi", .stdout = qi },
        .{ .argv = pacman_pending, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "vercmp 1-1 2", .stdout = "-1\n" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- newpkg" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };
    try d.backend().install(a, &.{rowOf("newpkg", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expectEqualStrings("", w.written());
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- newpkg"));

    // A replacement the installed version does not satisfy replaces
    // nothing, and the conflict stands.
    var newer: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest newpkg 1-1\nmoxtest oldpkg 3-1\n" },
        .{ .argv = pacman_print ++ " newpkg", .stdout = "newpkg\n" },
        .{ .argv = pacman_info ++ " newpkg", .stdout = si },
        .{ .argv = "pacman -Qi", .stdout = "Name            : oldpkg\nVersion         : 3-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n" },
        .{ .argv = pacman_pending, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "vercmp 3-1 2", .stdout = "1\n" },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = newer.runner(), .force_elevate = false, .err = &w2.writer };
    try d2.backend().install(a, &.{rowOf("newpkg", &.{})});
    try testing.expectEqual(@as(usize, 1), d2.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"newpkg\" names a package that conflicts with \"oldpkg\", which this machine has installed; pacman would have to remove oldpkg to install it, and mox never removes a package, so the row was not installed: remove oldpkg yourself, or drop the row\n",
        w2.written(),
    );
}

test "install: an installed package a THIRD package replaces is no conflict, read from the upgrade's own targets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `pacman -Qu` is blind to a replacement, so the row's own `Replaces`
    // is not the whole answer. Measured on pacman 7.1.0 with `oldname 1-1`
    // installed and the repository carrying `newname 2-1` alone, whose
    // `Replaces        : oldname`: `pacman -Qu --dbpath <copy>` exits 1
    // printing nothing on either stream, `pacman -Su --print --print-format
    // '%n' --dbpath <copy>` exits 0 printing `newname`, and `pacman -Syu
    // --needed --noconfirm -- conflictrow goodpkg` exits 0 having answered
    // ":: Replace oldname with moxtest/newname? [Y/n]" yes, removing
    // oldname and installing all three. Judged against `-Qu` alone, mox
    // refused conflictrow and told the user to remove oldname itself.
    const si = "Name            : conflictrow\nVersion         : 1-1\nProvides        : None\nConflicts With  : oldname\nReplaces        : None\n";
    const qi = "Name            : oldname\nVersion         : 1-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n";
    const newname = "Repository      : moxtest\nName            : newname\nVersion         : 2-1\nProvides        : None\nConflicts With  : None\nReplaces        : oldname\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest conflictrow 1-1\nmoxtest newname 2-1\n" },
        .{ .argv = pacman_print ++ " conflictrow", .stdout = "conflictrow\n" },
        .{ .argv = pacman_info ++ " conflictrow", .stdout = si },
        .{ .argv = "pacman -Qi", .stdout = qi },
        .{ .argv = pacman_pending, .code = 1 },
        .{ .argv = "pacman -Su --print --print-format %n --dbpath " ++ pdb, .stdout = "newname\n" },
        .{ .argv = pacman_info ++ " newname", .stdout = newname },
        .{ .argv = "pacman -Syu --needed --noconfirm -- conflictrow" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };
    try d.backend().install(a, &.{rowOf("conflictrow", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expectEqualStrings("", w.written());
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- conflictrow"));
    // Only the names the machine does not already have are asked about.
    try testing.expect(!fake.called(pacman_info ++ " oldname"));

    // Nothing pending replaces it: oldname is on the machine the upgrade
    // leaves, and the conflict stands.
    var settled: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest conflictrow 1-1\nmoxtest oldname 1-1\n" },
        .{ .argv = pacman_print ++ " conflictrow", .stdout = "conflictrow\n" },
        .{ .argv = pacman_info ++ " conflictrow", .stdout = si },
        .{ .argv = "pacman -Qi", .stdout = qi },
        .{ .argv = pacman_pending, .code = 1 },
        nothing_to_upgrade,
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = settled.runner(), .force_elevate = false, .err = &w2.writer };
    try d2.backend().install(a, &.{rowOf("conflictrow", &.{})});
    try testing.expectEqual(@as(usize, 1), d2.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"conflictrow\" names a package that conflicts with \"oldname\", which this machine has installed; pacman would have to remove oldname to install it, and mox never removes a package, so the row was not installed: remove oldname yourself, or drop the row\n",
        w2.written(),
    );
    try testing.expect(!d2.backend().installSpawned());

    // A `Replaces` the installed version does not satisfy replaces nothing.
    const bounded = "Repository      : moxtest\nName            : newname\nVersion         : 2-1\nProvides        : None\nConflicts With  : None\nReplaces        : oldname<1\n";
    var unsatisfied: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest conflictrow 1-1\nmoxtest newname 2-1\n" },
        .{ .argv = pacman_print ++ " conflictrow", .stdout = "conflictrow\n" },
        .{ .argv = pacman_info ++ " conflictrow", .stdout = si },
        .{ .argv = "pacman -Qi", .stdout = qi },
        .{ .argv = pacman_pending, .code = 1 },
        .{ .argv = "pacman -Su --print --print-format %n --dbpath " ++ pdb, .stdout = "newname\n" },
        .{ .argv = pacman_info ++ " newname", .stdout = bounded },
        .{ .argv = "vercmp 1-1 1", .stdout = "0\n" },
    } };
    var w3: std.Io.Writer.Allocating = .init(a);
    var d3: Distro = .{ .manager = .pacman, .runner = unsatisfied.runner(), .force_elevate = false, .err = &w3.writer };
    try d3.backend().install(a, &.{rowOf("conflictrow", &.{})});
    try testing.expectEqual(@as(usize, 1), d3.backend().installRefused());
    try testing.expect(std.mem.indexOf(u8, w3.written(), "remove oldname yourself") != null);

    // The other direction: the replaced package is the one declaring the
    // conflict, and it is gone from the same machine.
    const plain = "Name            : rowx\nVersion         : 1-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n";
    const declares = "Name            : oldname\nVersion         : 1-1\nProvides        : None\nConflicts With  : rowx\nReplaces        : None\n";
    var reverse: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest rowx 1-1\nmoxtest newname 2-1\n" },
        .{ .argv = pacman_print ++ " rowx", .stdout = "rowx\n" },
        .{ .argv = pacman_info ++ " rowx", .stdout = plain },
        .{ .argv = "pacman -Qi", .stdout = declares },
        .{ .argv = pacman_pending, .code = 1 },
        .{ .argv = "pacman -Su --print --print-format %n --dbpath " ++ pdb, .stdout = "newname\n" },
        .{ .argv = pacman_info ++ " newname", .stdout = newname },
        .{ .argv = "pacman -Syu --needed --noconfirm -- rowx" },
    } };
    var w4: std.Io.Writer.Allocating = .init(a);
    var d4: Distro = .{ .manager = .pacman, .runner = reverse.runner(), .force_elevate = false, .err = &w4.writer };
    try d4.backend().install(a, &.{rowOf("rowx", &.{})});
    try testing.expectEqual(@as(usize, 0), d4.backend().installRefused());
    try testing.expectEqualStrings("", w4.written());
    try testing.expect(reverse.called("pacman -Syu --needed --noconfirm -- rowx"));
}

test "install: a target list that could not be read is said, never read as nothing to upgrade" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const si = "Name            : conflictrow\nVersion         : 1-1\nProvides        : None\nConflicts With  : oldname\nReplaces        : None\n";
    const qi = "Name            : oldname\nVersion         : 1-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n";
    const said = "error: 'failed to resolve path '/var/cache/mox/pacman-db' passed to '--dbpath': No such file or directory\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest conflictrow 1-1\n" },
        .{ .argv = pacman_print ++ " conflictrow", .stdout = "conflictrow\n" },
        .{ .argv = pacman_info ++ " conflictrow", .stdout = si },
        .{ .argv = "pacman -Qi", .stdout = qi },
        .{ .argv = pacman_pending, .code = 1 },
        .{ .argv = "pacman -Su --print --print-format %n --dbpath " ++ pdb, .code = 1, .stderr = said },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };
    try d.backend().install(a, &.{rowOf("conflictrow", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: what the apply's `-Syu` would install could not be read (`pacman -Su --print --print-format %n --dbpath /var/cache/mox/pacman-db` exited 1: error: 'failed to resolve path '/var/cache/mox/pacman-db' passed to '--dbpath': No such file or directory), so an installed package the upgrade would replace is judged as still installed, and a row that conflicts with it may be refused\n" ++
            "mox: pacman: row \"conflictrow\" names a package that conflicts with \"oldname\", which this machine has installed; pacman would have to remove oldname to install it, and mox never removes a package, so the row was not installed: remove oldname yourself, or drop the row\n",
        w.written(),
    );
}

test "install: a -Qu that failed for a reason is said, never read as no upgrade pending" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Exit 1 with both streams empty is how pacman 7.1.0 answers "nothing
    // pending", so only that shape may pass in silence. Measured on the
    // same pacman, a dbpath that is not there exits 1 with `error: 'failed
    // to resolve path '/no/such/path' passed to '--dbpath': No such file or
    // directory` on stderr, and one whose `local` is a regular file exits
    // 255 with `error: failed to initialize alpm library:` and `(root: /,
    // dbpath: /tmp/broken)` and `could not open database`. Read as an empty
    // answer, every versioned conflict was then judged against the version
    // installed now with nothing said.
    const drv = "Name            : drv\nVersion         : 1-1\nProvides        : None\nConflicts With  : srv<2\nReplaces        : None\n";
    const srv_old = "Name            : srv\nVersion         : 1-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n";
    const said = "error: failed to initialize alpm library:\n(root: /, dbpath: /var/cache/mox/pacman-db)\ncould not open database\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest drv 1-1\nmoxtest srv 2-1\n" },
        .{ .argv = pacman_print ++ " drv", .stdout = "drv\n" },
        .{ .argv = pacman_info ++ " drv", .stdout = drv },
        .{ .argv = "pacman -Qi", .stdout = srv_old },
        .{ .argv = pacman_pending, .code = 255, .stderr = said },
        nothing_to_upgrade,
        .{ .argv = "vercmp 1-1 2", .stdout = "-1\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };
    try d.backend().install(a, &.{rowOf("drv", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: what the apply's `-Syu` will bring forward could not be read (`pacman -Qu --dbpath /var/cache/mox/pacman-db` exited 255: error: failed to initialize alpm library:; (root: /, dbpath: /var/cache/mox/pacman-db); could not open database), so a versioned conflict is judged against the version installed now, and a row the upgrade would have made room for may be refused\n" ++
            "mox: pacman: row \"drv\" names a package that conflicts with \"srv<2\", which this machine has installed as \"srv\"; pacman would have to remove srv to install it, and mox never removes a package, so the row was not installed: remove srv yourself, or drop the row\n",
        w.written(),
    );

    // The empty exit 1 is the no-upgrades answer, and says nothing at all.
    var quiet: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest drv 1-1\nmoxtest srv 2-1\n" },
        .{ .argv = pacman_print ++ " drv", .stdout = "drv\n" },
        .{ .argv = pacman_info ++ " drv", .stdout = drv },
        .{ .argv = "pacman -Qi", .stdout = srv_old },
        .{ .argv = pacman_pending, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "vercmp 1-1 2", .stdout = "-1\n" },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = quiet.runner(), .force_elevate = false, .err = &w2.writer };
    try d2.backend().install(a, &.{rowOf("drv", &.{})});
    try testing.expectEqualStrings(
        "mox: pacman: row \"drv\" names a package that conflicts with \"srv<2\", which this machine has installed as \"srv\"; pacman would have to remove srv to install it, and mox never removes a package, so the row was not installed: remove srv yourself, or drop the row\n",
        w2.written(),
    );
}

test "install: rows the repositories could not describe are said, never read as rows that conflict with nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0: a dbpath that is not there exits 1 with
    // `error: 'failed to resolve path '/no/such/path' passed to '--dbpath':
    // No such file or directory` on stderr and no block on stdout, and
    // `pacman -Si -- bash mox-no-such-package` exits 1 having printed
    // bash's block and said `error: package 'mox-no-such-package' was not
    // found`. Read as "this row conflicts with nothing", the row went to an
    // install pacman then refuses whole, with nothing said.
    const qi = "Name            : pulseaudio\nVersion         : 17.0-1\nProvides        : None\nConflicts With  : pipewire-pulse\nReplaces        : None\n";
    const said = "error: 'failed to resolve path '/var/cache/mox/pacman-db' passed to '--dbpath': No such file or directory\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "extra pipewire-pulse 1:1.6.8-1\n" },
        .{ .argv = pacman_print ++ " pipewire-pulse", .stdout = "pipewire-pulse\n" },
        .{ .argv = pacman_info ++ " pipewire-pulse", .code = 1, .stderr = said },
        .{ .argv = "pacman -Qi", .stdout = qi },
        .{ .argv = pacman_pending, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Syu --needed --noconfirm -- pipewire-pulse" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };
    try d.backend().install(a, &.{rowOf("pipewire-pulse", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: what the rows to install conflict with could not be read (`pacman -Si --dbpath /var/cache/mox/pacman-db` exited 1, saying: error: 'failed to resolve path '/var/cache/mox/pacman-db' passed to '--dbpath': No such file or directory), so a row it did not describe is left to pacman, which then installs none of the batch if that row conflicts with an installed package\n",
        w.written(),
    );
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- pipewire-pulse"));

    // The blocks a partly failed read did print are still read: the row it
    // described is judged against the machine, the one it left out is the
    // one left to pacman.
    const partial = "Name            : pipewire-pulse\nVersion         : 1:1.6.8-1\nProvides        : None\nConflicts With  : pulseaudio\nReplaces        : None\n";
    var some: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "extra pipewire-pulse 1:1.6.8-1\nextra cowsay 3.8.4-1\n" },
        .{ .argv = pacman_print ++ " pipewire-pulse cowsay", .stdout = "pipewire-pulse\ncowsay\n" },
        .{ .argv = pacman_info ++ " pipewire-pulse cowsay", .code = 1, .stdout = partial, .stderr = "error: package 'cowsay' was not found\n" },
        .{ .argv = "pacman -Qi", .stdout = qi },
        .{ .argv = pacman_pending, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Syu --needed --noconfirm -- cowsay" },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = some.runner(), .force_elevate = false, .err = &w2.writer };
    try d2.backend().install(a, &.{ rowOf("pipewire-pulse", &.{}), rowOf("cowsay", &.{}) });
    try testing.expectEqual(@as(usize, 1), d2.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: what the rows to install conflict with could not be read (`pacman -Si --dbpath /var/cache/mox/pacman-db` exited 1, saying: error: package 'cowsay' was not found), so a row it did not describe is left to pacman, which then installs none of the batch if that row conflicts with an installed package\n" ++
            "mox: pacman: row \"pipewire-pulse\" names a package that conflicts with \"pulseaudio\", which this machine has installed; pacman would have to remove pulseaudio to install it, and mox never removes a package, so the row was not installed: remove pulseaudio yourself, or drop the row\n",
        w2.written(),
    );
    try testing.expect(some.called("pacman -Syu --needed --noconfirm -- cowsay"));
}

test "install: a pending upgrade's own block, unread, is said and judged at the version installed now" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0: a dbpath whose `local` is a regular file
    // exits 255 with `error: failed to initialize alpm library:` and
    // `could not open database`. Read as "no pending block", the version
    // the upgrade will leave is judged as the version installed now, and a
    // row the upgrade makes room for is refused with nothing said.
    const drv = "Name            : drv\nVersion         : 1-1\nProvides        : None\nConflicts With  : srv<2\nReplaces        : None\n";
    const srv_old = "Name            : srv\nVersion         : 1-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n";
    const said = "error: failed to initialize alpm library:\n(root: /, dbpath: /var/cache/mox/pacman-db)\ncould not open database\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest drv 1-1\nmoxtest srv 2-1\n" },
        .{ .argv = pacman_print ++ " drv", .stdout = "drv\n" },
        .{ .argv = pacman_info ++ " drv", .stdout = drv },
        .{ .argv = "pacman -Qi", .stdout = srv_old },
        .{ .argv = pacman_pending, .stdout = "srv 1-1 -> 2-1\n" },
        .{ .argv = pacman_info ++ " srv", .code = 255, .stderr = said },
        nothing_to_upgrade,
        .{ .argv = "vercmp 1-1 2", .stdout = "-1\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };
    try d.backend().install(a, &.{rowOf("drv", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: what the apply's `-Syu` will leave of the packages it upgrades could not be read (`pacman -Si --dbpath /var/cache/mox/pacman-db` exited 255, saying: error: failed to initialize alpm library:; (root: /, dbpath: /var/cache/mox/pacman-db); could not open database), so each of them is judged at the version installed now, and a row the upgrade would have made room for may be refused\n" ++
            "mox: pacman: row \"drv\" names a package that conflicts with \"srv<2\", which this machine has installed as \"srv\"; pacman would have to remove srv to install it, and mox never removes a package, so the row was not installed: remove srv yourself, or drop the row\n",
        w.written(),
    );
    try testing.expect(!d.backend().installSpawned());
}

test "install: an upgrade newcomer's own block, unread, is said and the package it replaces judged as installed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0: `pacman -Si -- <name>` the repositories do
    // not carry exits 1 with `error: package '<name>' was not found` on
    // stderr. Read as "the upgrade replaces nothing", an installed package
    // the upgrade removes is judged as still on the machine, and the row
    // that conflicts with it is refused with nothing said.
    const si = "Name            : conflictrow\nVersion         : 1-1\nProvides        : None\nConflicts With  : oldname\nReplaces        : None\n";
    const qi = "Name            : oldname\nVersion         : 1-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest conflictrow 1-1\nmoxtest newname 2-1\n" },
        .{ .argv = pacman_print ++ " conflictrow", .stdout = "conflictrow\n" },
        .{ .argv = pacman_info ++ " conflictrow", .stdout = si },
        .{ .argv = "pacman -Qi", .stdout = qi },
        .{ .argv = pacman_pending, .code = 1 },
        .{ .argv = "pacman -Su --print --print-format %n --dbpath " ++ pdb, .stdout = "newname\n" },
        .{ .argv = pacman_info ++ " newname", .code = 1, .stderr = "error: package 'newname' was not found\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };
    try d.backend().install(a, &.{rowOf("conflictrow", &.{})});
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: what the apply's `-Syu` will install in place of a package it removes could not be read (`pacman -Si --dbpath /var/cache/mox/pacman-db` exited 1, saying: error: package 'newname' was not found), so an installed package the upgrade would replace is judged as still installed, and a row that conflicts with it may be refused\n" ++
            "mox: pacman: row \"conflictrow\" names a package that conflicts with \"oldname\", which this machine has installed; pacman would have to remove oldname to install it, and mox never removes a package, so the row was not installed: remove oldname yourself, or drop the row\n",
        w.written(),
    );
    try testing.expect(!d.backend().installSpawned());
}

test "install: pacman refuses a row an installed package declares a conflict with, versions judged by pacman" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 42 of the 136 conflict pairs in the current repositories are declared
    // on one side only (measured over `pacman -Si` on pacman 7.1.0):
    // `exfatprogs` names `exfat-utils` and exfat-utils names nothing back,
    // so a row `exfat-utils` beside an installed exfatprogs is refused by
    // pacman all the same, and only `pacman -Qi` can say so.
    const qi = "Name            : exfatprogs\nVersion         : 1.2.9-1\nProvides        : None\nConflicts With  : exfat-utils\nReplaces        : None\n\nName            : xorg-server\nVersion         : 21.1.18-1\nProvides        : X-ABI-VIDEODRV_VERSION=25.2\nConflicts With  : nvidia-utils<=331.20  glamor-egl  xf86-video-modesetting\nReplaces        : None\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "extra exfat-utils 1.4.0-1\nextra cowsay 3.8.4-1\n" },
        .{ .argv = pacman_print ++ " exfat-utils cowsay", .stdout = "exfat-utils\ncowsay\n" },
        .{ .argv = pacman_info ++ " exfat-utils cowsay", .stdout = "Name            : exfat-utils\nVersion         : 1.4.0-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n\nName            : cowsay\nVersion         : 3.8.4-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n" },
        .{ .argv = "pacman -Qi", .stdout = qi },
        .{ .argv = pacman_pending, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Syu --needed --noconfirm -- cowsay" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{ rowOf("exfat-utils", &.{}), rowOf("cowsay", &.{}) });
    try testing.expectEqual(@as(usize, 1), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"exfat-utils\" names a package that \"exfatprogs\", which this machine has installed, declares a conflict with (\"exfat-utils\"); pacman would have to remove exfatprogs to install it, and mox never removes a package, so the row was not installed: remove exfatprogs yourself, or drop the row\n",
        w.written(),
    );
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- cowsay"));
    try testing.expectEqual(@as(usize, 0), countCalls(&fake, "vercmp"));

    // A versioned declaration is judged by `vercmp` against the version the
    // row would install: `nvidia-utils<=331.20` holds against 331.20-1
    // (`vercmp 331.20-1 331.20` is 0) and not against 580.82-1 (1).
    const nv_info = "Name            : nvidia-utils\nVersion         : 580.82-1\nProvides        : vulkan-driver  opengl-driver\nConflicts With  : None\nReplaces        : None\n";
    var newer: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "extra nvidia-utils 580.82-1\n" },
        .{ .argv = pacman_print ++ " nvidia-utils", .stdout = "nvidia-utils\n" },
        .{ .argv = pacman_info ++ " nvidia-utils", .stdout = nv_info },
        .{ .argv = "pacman -Qi", .stdout = qi },
        .{ .argv = pacman_pending, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "vercmp 580.82-1 331.20", .stdout = "1\n" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- nvidia-utils" },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = newer.runner(), .force_elevate = false, .err = &w2.writer };
    try d2.backend().install(a, &.{rowOf("nvidia-utils", &.{})});
    try testing.expectEqual(@as(usize, 0), d2.backend().installRefused());
    try testing.expectEqualStrings("", w2.written());
    try testing.expect(newer.called("pacman -Syu --needed --noconfirm -- nvidia-utils"));

    var older: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "old nvidia-utils 331.20-1\n" },
        .{ .argv = pacman_print ++ " nvidia-utils", .stdout = "nvidia-utils\n" },
        .{ .argv = pacman_info ++ " nvidia-utils", .stdout = "Name            : nvidia-utils\nVersion         : 331.20-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n" },
        .{ .argv = "pacman -Qi", .stdout = qi },
        .{ .argv = pacman_pending, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "vercmp 331.20-1 331.20", .stdout = "0\n" },
    } };
    var w3: std.Io.Writer.Allocating = .init(a);
    var d3: Distro = .{ .manager = .pacman, .runner = older.runner(), .force_elevate = false, .err = &w3.writer };
    try d3.backend().install(a, &.{rowOf("nvidia-utils", &.{})});
    try testing.expectEqual(@as(usize, 1), d3.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: row \"nvidia-utils\" names a package that \"xorg-server\", which this machine has installed, declares a conflict with (\"nvidia-utils<=331.20\"); pacman would have to remove xorg-server to install it, and mox never removes a package, so the row was not installed: remove xorg-server yourself, or drop the row\n",
        w3.written(),
    );
    try testing.expect(!d3.backend().installSpawned());

    // An installed package the apply's upgrade brings forward declares
    // what its NEW version declares: `guard` 1-1 names `rowb`, and the
    // 2-1 the copy carries names nothing, so the row goes in beside the
    // upgrade.
    var upgraded: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest rowb 1-1\nmoxtest guard 2-1\n" },
        .{ .argv = pacman_print ++ " rowb", .stdout = "rowb\n" },
        .{ .argv = pacman_info ++ " rowb", .stdout = "Name            : rowb\nVersion         : 1-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n" },
        .{ .argv = "pacman -Qi", .stdout = "Name            : guard\nVersion         : 1-1\nProvides        : None\nConflicts With  : rowb\nReplaces        : None\n" },
        .{ .argv = pacman_pending, .stdout = "guard 1-1 -> 2-1\n" },
        nothing_to_upgrade,
        .{ .argv = pacman_info ++ " guard", .stdout = "Repository      : moxtest\nName            : guard\nVersion         : 2-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n" },
        .{ .argv = "pacman -Syu --needed --noconfirm -- rowb" },
    } };
    var w4: std.Io.Writer.Allocating = .init(a);
    var d4: Distro = .{ .manager = .pacman, .runner = upgraded.runner(), .force_elevate = false, .err = &w4.writer };
    try d4.backend().install(a, &.{rowOf("rowb", &.{})});
    try testing.expectEqual(@as(usize, 0), d4.backend().installRefused());
    try testing.expectEqualStrings("", w4.written());
    try testing.expect(upgraded.called("pacman -Syu --needed --noconfirm -- rowb"));

    // The same name in two repositories: the block at the pending version
    // is the one read (`-Si` prints one block per repository, measured).
    var twice: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "moxtest rowb 1-1\nmoxtest guard 2-1\n" },
        .{ .argv = pacman_print ++ " rowb", .stdout = "rowb\n" },
        .{ .argv = pacman_info ++ " rowb", .stdout = "Name            : rowb\nVersion         : 1-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n" },
        .{ .argv = "pacman -Qi", .stdout = "Name            : guard\nVersion         : 1-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n" },
        .{ .argv = pacman_pending, .stdout = "guard 1-1 -> 2-1\n" },
        nothing_to_upgrade,
        .{ .argv = pacman_info ++ " guard", .stdout = "Repository      : testing\nName            : guard\nVersion         : 3-1\nProvides        : None\nConflicts With  : None\nReplaces        : None\n\nRepository      : moxtest\nName            : guard\nVersion         : 2-1\nProvides        : None\nConflicts With  : rowb\nReplaces        : None\n" },
    } };
    var w5: std.Io.Writer.Allocating = .init(a);
    var d5: Distro = .{ .manager = .pacman, .runner = twice.runner(), .force_elevate = false, .err = &w5.writer };
    try d5.backend().install(a, &.{rowOf("rowb", &.{})});
    try testing.expectEqual(@as(usize, 1), d5.backend().installRefused());
    try testing.expect(std.mem.indexOf(u8, w5.written(), "\"guard\", which this machine has installed, declares a conflict with (\"rowb\")") != null);
}

test "install: a conflict check that cannot read the machine says so and leaves the row to pacman" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "extra pipewire-pulse 1:1.6.8-1\n" },
        .{ .argv = pacman_print ++ " pipewire-pulse", .stdout = "pipewire-pulse\n" },
        .{ .argv = pacman_info ++ " pipewire-pulse", .stdout = "Name            : pipewire-pulse\nVersion         : 1:1.6.8-1\nProvides        : None\nConflicts With  : pulseaudio\nReplaces        : None\n" },
        .{ .argv = "pacman -Qi", .code = 255 },
        .{ .argv = "pacman -Syu --needed --noconfirm -- pipewire-pulse" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try d.backend().install(a, &.{rowOf("pipewire-pulse", &.{})});
    try testing.expectEqual(@as(usize, 0), d.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: pacman: what this machine has installed could not be read in full (`pacman -Qi` exited 255), so a row that conflicts with an installed package, or that one declares a conflict with, is left to pacman, which then installs none of the batch\n",
        w.written(),
    );
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- pipewire-pulse"));
    try testing.expectEqual(@as(usize, 0), countCalls(&fake, pacman_pending));
}

test "install: the pacman copy is made and repaired only when a probe finds it wanting, so a settled machine elevates pacman alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0: an unprivileged user reads `stat -L`
    // and `readlink` of the copy, and `sudo pacman -Sy --dbpath <copy>`
    // into a tree already there succeeds. So a sudoers rule granting
    // `/usr/bin/pacman` alone serves every apply once the copy exists.
    var settled: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .stdout = pacman_probe_ready },
        .{ .argv = pacman_link, .stdout = "/var/lib/pacman/local\n" },
        .{ .argv = "sudo " ++ pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = pacman_print ++ " bat", .stdout = "bat\n" },
        .{ .argv = pacman_info, .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "sudo pacman -Syu --needed --noconfirm -- bat" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = settled.runner(), .force_elevate = true };
    try d.backend().install(a, &.{rowOf("bat", &.{})});
    var elevated: usize = 0;
    for (settled.calls.items) |c| {
        try testing.expect(std.mem.indexOf(u8, c, "install -d") == null);
        try testing.expect(std.mem.indexOf(u8, c, "sh -c") == null);
        if (std.mem.startsWith(u8, c, "sudo ")) {
            try testing.expect(std.mem.startsWith(u8, c, "sudo pacman "));
            elevated += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), elevated);

    // A caller's umask of 077 or 027 under sudo (measured: 700 and 750
    // trees) leaves `alpm` unable to traverse, and `-Sy` fails with
    // "Permission denied" on this and every later apply, since `mkdir -p`
    // never repaired what existed. `install -d -m 755` on both levels does
    // (measured, coreutils 9.11: 700 -> 755 on an existing directory).
    var narrow: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .stdout = "/var/cache/mox 750 directory\n/var/cache/mox/pacman-db 755 directory\n" },
        .{ .argv = "sudo " ++ pacman_make },
        .{ .argv = "sudo " ++ pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = pacman_print ++ " bat", .stdout = "bat\n" },
        .{ .argv = pacman_info, .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "sudo pacman -Syu --needed --noconfirm -- bat" },
    } };
    var d2: Distro = .{ .manager = .pacman, .runner = narrow.runner(), .force_elevate = true };
    try d2.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(narrow.called("sudo " ++ pacman_make));
    try testing.expect(!narrow.called(pacman_link));

    // A `local` pointing elsewhere is repaired too.
    var moved: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/mnt/root/var/lib/pacman\n" },
        .{ .argv = pacman_probe, .stdout = pacman_probe_ready },
        .{ .argv = pacman_link, .stdout = "/var/lib/pacman/local\n" },
        .{ .argv = pacmanMakeCall("/mnt/root/var/lib/pacman/local") },
        .{ .argv = pacman_private_sync, .code = 1 },
        .{ .argv = "test -e " ++ pdb ++ "/db.lck", .code = 1 },
    } };
    var d3: Distro = .{ .manager = .pacman, .runner = moved.runner(), .force_elevate = false };
    try testing.expectError(Error.DistroRefreshFailed, d3.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(moved.called(pacmanMakeCall("/mnt/root/var/lib/pacman/local")));
}

test "install: a copy that could not be made says what needed elevation, and the one-time command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A sudoers rule granting pacman alone: sudo refuses `sh` (its own
    // message on the terminal) and the apply said only `DistroQueryFailed`.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = "sudo " ++ pacman_make, .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true, .err = &w.writer };

    try testing.expectError(Error.DistroQueryFailed, d.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expectEqualStrings(
        "mox: pacman: `sudo sh -c` making the copy of pacman's databases the check reads at /var/cache/mox/pacman-db exited 1, so the copy could not be made; make it once as root with `install -d -m 755 /var/cache/mox /var/cache/mox/pacman-db && { [ -L /var/cache/mox/pacman-db/local ] || [ ! -d /var/cache/mox/pacman-db/local ] || rmdir /var/cache/mox/pacman-db/local; } && ln -sfnT /var/lib/pacman/local /var/cache/mox/pacman-db/local`, after which an apply elevates nothing but pacman\n",
        w.written(),
    );
    try testing.expect(!d.backend().installSpawned());
    try testing.expectEqual(@as(usize, 0), pacmanSystemWrites(&fake));
    try testing.expectEqual(@as(usize, 0), countCalls(&fake, "sudo " ++ pacman_private_sync));

    // Unelevated, the same call is `sh -c` alone.
    var root: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = pacman_make, .code = 1 },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = root.runner(), .force_elevate = false, .err = &w2.writer };
    try testing.expectError(Error.DistroQueryFailed, d2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(std.mem.startsWith(u8, w2.written(), "mox: pacman: `sh -c` making the copy"));
}

test "install: the pacman copy is made by one streamed call, so sudo can ask for its password" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0 with a user sudoers grants with a password,
    // under `script`: the make as two captured calls stopped at sudo's
    // prompt, the read loop reported "stopped, and this run has no
    // terminal that could resume it; killed", the first apply failed and
    // no copy was made. Streamed, sudo asks on the terminal once.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1 },
        .{ .argv = "sudo " ++ pacman_make },
        .{ .argv = "sudo " ++ pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = pacman_print ++ " bat", .stdout = "bat\n" },
        .{ .argv = pacman_info, .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath " ++ pdb, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "sudo pacman -Syu --needed --noconfirm -- bat" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true };
    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqualStrings(pacman_probe, fake.calls.items[2]);
    try testing.expect(!fake.streamed.items[2]);
    try testing.expectEqualStrings("sudo " ++ pacman_make, fake.calls.items[3]);
    try testing.expect(fake.streamed.items[3]);
    try testing.expectEqualStrings("sudo " ++ pacman_private_sync, fake.calls.items[4]);
    try testing.expect(fake.streamed.items[4]);
    try testing.expectEqual(@as(usize, 1), countCalls(&fake, "sudo " ++ pacman_make));
    try testing.expectEqualStrings(
        "sudo sh -c install -d -m 755 \"$1\" \"$2\" && { [ -L \"$4\" ] || [ ! -d \"$4\" ] || rmdir \"$4\" || exit 3; } && ln -sfnT \"$3\" \"$4\" sh /var/cache/mox /var/cache/mox/pacman-db /var/lib/pacman/local /var/cache/mox/pacman-db/local",
        fake.calls.items[3],
    );
}

test "install: a real directory at the pacman copy's local is replaced when empty, and named when not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured with coreutils 9.11: `readlink` exits 1 on a directory, so
    // the probe finds the copy wanting; the make removes an empty one
    // (`rmdir`) and links over it, and exits 3 leaving one with entries.
    var empty: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .stdout = pacman_probe_ready },
        .{ .argv = pacman_link, .code = 1 },
        .{ .argv = pacman_make },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = pacman_print ++ " bat", .stdout = "bat\n" },
        .{ .argv = pacman_info, .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath " ++ pdb, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Syu --needed --noconfirm -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = empty.runner(), .force_elevate = false, .err = &w.writer };
    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(empty.called(pacman_make));
    try testing.expectEqualStrings("", w.written());

    var kept: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .stdout = pacman_probe_ready },
        .{ .argv = pacman_link, .code = 1 },
        .{ .argv = pacman_make, .code = 3 },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = kept.runner(), .force_elevate = false, .err = &w2.writer };
    try testing.expectError(Error.DistroQueryFailed, d2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expectEqualStrings(
        "mox: pacman: /var/cache/mox/pacman-db/local is a directory with entries in it, where the copy of pacman's databases the check reads keeps a link to /var/lib/pacman/local; mox removes nothing there, so move it aside as root, after which an apply makes the link\n",
        w2.written(),
    );
    try testing.expect(!d2.backend().installSpawned());
    try testing.expectEqual(@as(usize, 0), countCalls(&kept, pacman_private_sync));
}

test "install: a non-directory where the pacman copy goes is named, and the make never runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured with coreutils 9.11 and a regular file at /var/cache/mox:
    // `stat -L -c '%n %a %F'` prints `/var/cache/mox 644 regular empty
    // file` and exits 1 (the level under it "Not a directory"), and
    // `install -d` on it fails "File exists" -- the one-time command the
    // message used to give would have failed the same way.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .code = 1, .stdout = "/var/cache/mox 644 regular empty file\n", .stderr = "stat: cannot statx '/var/cache/mox/pacman-db': Not a directory\n" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true, .err = &w.writer };
    try testing.expectError(Error.DistroQueryFailed, d.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expectEqualStrings(
        "mox: pacman: /var/cache/mox is a regular empty file, not a directory, so the copy of pacman's databases the check reads at /var/cache/mox/pacman-db cannot be made; move it aside as root, after which an apply makes the copy\n",
        w.written(),
    );
    try testing.expectEqual(@as(usize, 3), fake.calls.items.len);

    // The inner level as a file: the outer one reads fine first.
    var inner: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .stdout = "/var/cache/mox 755 directory\n/var/cache/mox/pacman-db 644 regular file\n" },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = inner.runner(), .force_elevate = true, .err = &w2.writer };
    try testing.expectError(Error.DistroQueryFailed, d2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expect(std.mem.startsWith(u8, w2.written(), "mox: pacman: /var/cache/mox/pacman-db is a regular file, not a directory, so"));
}

test "install: what pacman says beside a batch it does resolve reaches the terminal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0 with a directive pacman.conf does not know:
    // `pacman -S --print` prints the transaction, exits 0, and says this on
    // stderr -- which the batch's capture used to drop.
    const warning = "warning: config file /etc/pacman.conf, line 97: directive 'BogusDirective' in section 'options' not recognized.\n";
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .stdout = pacman_probe_ready },
        .{ .argv = pacman_link, .stdout = "/var/lib/pacman/local\n" },
        .{ .argv = pacman_private_sync },
        .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "core bat 0.25.0-1\n" },
        .{ .argv = pacman_print ++ " bat", .stdout = "bat\n", .stderr = warning },
        .{ .argv = pacman_info, .match = .prefix },
        .{ .argv = "pacman -Qi" },
        .{ .argv = "pacman -Qu --dbpath " ++ pdb, .code = 1 },
        nothing_to_upgrade,
        .{ .argv = "pacman -Syu --needed --noconfirm -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };
    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expectEqualStrings(warning, w.written());
    try testing.expect(fake.called("pacman -Syu --needed --noconfirm -- bat"));
}

test "install: a lock in the pacman copy is named when the sync fails, with both things it can mean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Measured on pacman 7.1.0: a `pacman -Sy --dbpath <copy>` killed with
    // SIGKILL mid-download leaves `<copy>/db.lck`; the next sync says only
    // "error: failed to synchronize all databases (unable to lock
    // database)" and exits 1 -- the "you can remove" hint is printed for a
    // transaction, never a sync -- and mox said `install did not run:
    // DistroRefreshFailed`. An interrupt (mox's own bound) removes the lock.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .stdout = pacman_probe_ready },
        .{ .argv = pacman_link, .stdout = "/var/lib/pacman/local\n" },
        .{ .argv = pacman_private_sync, .code = 1 },
        .{ .argv = "test -e " ++ pdb ++ "/db.lck" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false, .err = &w.writer };

    try testing.expectError(Error.DistroRefreshFailed, d.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expectEqualStrings(
        "mox: pacman: the sync of mox's database copy failed and /var/cache/mox/pacman-db/db.lck exists, which is either a pacman syncing that copy at this moment -- /var/cache/mox/pacman-db is one path every mox on this machine shares, while the lock mox takes is one per state directory -- or one killed outright mid-sync; once no pacman is running it may be removed, as root\n",
        w.written(),
    );
    try testing.expectEqualStrings(
        "the index or database refresh the install resolves against did not complete, so nothing was installed",
        exec.errorText(Error.DistroRefreshFailed),
    );

    // No lock: nothing is said beyond the error.
    var plain: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qdq", .code = 1 },
        .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
        .{ .argv = pacman_probe, .stdout = pacman_probe_ready },
        .{ .argv = pacman_link, .stdout = "/var/lib/pacman/local\n" },
        .{ .argv = pacman_private_sync, .code = 1 },
        .{ .argv = "test -e " ++ pdb ++ "/db.lck", .code = 1 },
    } };
    var w2: std.Io.Writer.Allocating = .init(a);
    var d2: Distro = .{ .manager = .pacman, .runner = plain.runner(), .force_elevate = false, .err = &w2.writer };
    try testing.expectError(Error.DistroRefreshFailed, d2.backend().install(a, &.{rowOf("bat", &.{})}));
    try testing.expectEqualStrings("", w2.written());
}

test "install: a captured pacman call killed at its bound inside the install is reported under the capture bound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Each of these is captured under MOX_SCRIPT_TIMEOUT_MS; the install's
    // call site arms MOX_INSTALL_TIMEOUT_MS and names it for a plain
    // TimedOut, which would send the user to a variable that changes
    // nothing here.
    const killed = [_][]const u8{
        "pacman-conf DBPath",
        pacman_probe,
        "pacman -Sl --dbpath " ++ pdb,
        pacman_print ++ " bat",
        pacman_info ++ " bat",
    };
    for (killed) |argv| {
        var fake: exec.Fake = .{ .arena = a, .entries = &.{
            .{ .argv = "pacman -Qdq", .code = 1 },
            .{ .argv = argv, .timed_out = true },
            .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" },
            .{ .argv = pacman_probe, .stdout = pacman_probe_ready },
            .{ .argv = pacman_link, .stdout = "/var/lib/pacman/local\n" },
            .{ .argv = pacman_private_sync },
            .{ .argv = "pacman -Sl --dbpath " ++ pdb, .stdout = "core bat 0.25.0-1\n" },
            .{ .argv = pacman_print ++ " bat", .stdout = "bat\n" },
        } };
        var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = false };
        try testing.expectError(error.CaptureTimedOut, d.backend().install(a, &.{rowOf("bat", &.{})}));
        try testing.expect(!d.backend().installSpawned());
    }

    // The explicit-install query is its own captured verb, bounded and
    // named by its caller: a kill there stays a plain TimedOut.
    var status: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pacman -Qeq", .timed_out = true },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = status.runner(), .force_elevate = false };
    try testing.expectError(error.TimedOut, d.backend().installedExplicit(a));
}

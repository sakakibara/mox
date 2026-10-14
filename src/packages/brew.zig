//! The Homebrew adapter.
//!
//! Rows take one key beyond the core set: `kind`, `"formula"` (the default)
//! or `"cask"`. A tap is not a key -- a tap-qualified `name`
//! (`owner/tap/formula`) names its own tap, and declaring such a row IS the
//! decision to trust that tap, which the adapter acts on by tapping and
//! trusting the single formula rather than the whole tap.
//!
//! The explicit set is `brew list --full-name --installed-on-request`, and
//! each half of that is load-bearing. `brew leaves` is the wrong question: it
//! excludes any formula that something else depends on, so a package the user
//! asked for by name vanishes the moment anything needs it and is reported
//! missing forever. `--full-name` spells a tapped formula the way a row does
//! (`owner/tap/name`); without it the same formula comes back bare and never
//! matches its row. Casks are queried separately, with the same `--full-name`
//! for the same reason, and are a namespace that can collide with a formula of
//! the same name, so a cask's id carries its kind -- and a cask can come from a
//! third-party tap just as a formula can.
//!
//! The cask half is NOT an explicit-install query, and brew offers none:
//! `--cask` and `--installed-on-request` are declared as conflicting options
//! (verified against brew 7.0.1, which answers that argv with its usage and
//! exit 1). So `brew list --cask --full-name` lists the whole Caskroom,
//! including a cask pulled in by another cask's `depends_on cask:`, which is
//! reported untracked for as long as it is installed. That is stated in
//! `limitation` rather than papered over with a query brew does not have.
//!
//! An install asks a second question of the formula half: `brew list
//! --formula --full-name`, which is every installed formula whether or not
//! it was asked for by name. A formula brew already has, linked and current,
//! is dropped from `brew install`'s own work list before an installer is
//! built for it, so the receipt flag the explicit-install query reads is
//! never written and the command exits 0 having done nothing. Such a row is
//! missing on every run and "installed" again on every apply, so the adapter
//! writes that flag itself with `brew tab` instead of running an install
//! that cannot converge the row.
//!
//! An install is one `brew install` per row, so each package's failure is its
//! own, with one exception: the casks whose install elevates. Homebrew clears
//! sudo's cached credential (`sudo --reset-timestamp`, from `utils/sudo.sh`)
//! the first time each brew process needs sudo, so one process per such cask
//! asks for the administrator password once per cask. They are installed
//! together in one `brew install --cask`, before everything else, while the
//! user who answered the bootstrap's prompt is still at the keyboard.

const std = @import("std");
const builtin = @import("builtin");
const json = @import("json");

const backend_mod = @import("backend.zig");
const bootstrap_mod = @import("bootstrap.zig");
const exec = @import("exec.zig");
const manifest_mod = @import("manifest.zig");

const Io = std.Io;

pub const Row = manifest_mod.Row;
pub const Diag = manifest_mod.Diag;
pub const Backend = backend_mod.Backend;

pub const Error = error{
    UnknownBrewKey,
    BadBrewKind,
    BrewNameNotAPackage,
};

pub const Kind = enum { formula, cask };

/// The prefix a cask id carries so it cannot collide with the formula of the
/// same name. Opaque to the core, which only compares ids.
pub const cask_prefix = "cask:";

pub const default_prefixes = [_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin" };

/// brew answers "which casks are installed", never "which casks were asked
/// for": `--cask` conflicts with `--installed-on-request`.
pub const cask_limitation = "brew has no explicit-install query for casks, so a cask installed as another cask's dependency is reported untracked";

pub const Brew = struct {
    runner: exec.Runner,
    /// Staging a verified installer, and reading an install receipt.
    io: ?std.Io = null,
    /// How brew is invoked. `brew` until a bootstrap installs it, then the
    /// absolute path it landed at: a child's PATH is never used to resolve
    /// argv[0] (only the parent's is), so a freshly installed brew that is on
    /// no PATH yet can only be reached by name of its full path.
    exe: []const u8 = "brew",
    /// Where the installer leaves `brew`; probed after a bootstrap.
    prefixes: []const []const u8 = &default_prefixes,
    /// Whether the last `install` ran `brew install`, which `installSpawned`
    /// answers with: a tap or a trust that fails stops the row before it, and
    /// a batch of one such row never reaches brew at all.
    spawned: bool = false,
    /// How many of the last `install`'s rows brew was never handed, which
    /// `installRefused` answers with.
    refused: usize = 0,
    /// How many of the last `install`'s rows were converged by marking a
    /// formula brew already had, which `installMarked` answers with.
    marked: usize = 0,
    /// How many of the last `install`'s rows named a formula brew already had
    /// and could not be marked, which `installUnmarked` answers with.
    unmarked: usize = 0,
    /// Where a row refused at install time is said. The install's own error
    /// is what the call site reports, so the row and the name to write in its
    /// place have nowhere else to go.
    err: ?*Io.Writer = null,
    /// What the whole per-name fallback in `resolveNames` gets, in
    /// milliseconds; NEGATIVE leaves it unbounded, and zero spends none of it.
    /// Each of that fallback's calls answers to the per-call bound alone, so
    /// without one budget over all of them a batch of 120 names costs 120 of
    /// those and no setting caps the total. Set from the same bound one call
    /// runs under, so the check as a whole costs about what one query may.
    probe_budget_ms: i64 = exec.default_timeout_ms,
    /// The last bootstrap's installer exit code, when it exited nonzero.
    installer_exit: ?u8 = null,

    pub fn backend(self: *Brew) Backend {
        return .{
            .name = "brew",
            .ctx = self,
            .vtable = &vtable,
            .limitation = cask_limitation,
            .install_check = "the formula and cask names brew resolves a row to, and the formulae it already has",
            .bootstrap_elevates_on = "darwin",
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
        .astray = astrayImpl,
        .declare = declareImpl,
        .bootstrap = bootstrapImpl,
        .installerExit = installerExitImpl,
        .spacePaths = spacePathsImpl,
    };

    /// brew's prefix, where every formula lands, and on a mac the
    /// temporary directory a cask is staged in before it is moved into
    /// place. The prefix is the one this brew runs from; a brew on PATH
    /// outside every known prefix names none, and only the staging
    /// directory is checked.
    fn spacePathsImpl(ctx: *anyopaque, arena: std.mem.Allocator, rows: []const Row) anyerror![]const []const u8 {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        var out: std.ArrayList([]const u8) = .empty;
        if (self.prefixDir(arena)) |dir| try out.append(arena, dir);
        if (builtin.os.tag == .macos) {
            for (rows) |row| {
                if (try kindOf(row) != .cask) continue;
                try out.append(arena, "/private/tmp");
                break;
            }
        }
        return out.toOwnedSlice(arena);
    }

    /// The directory above the bin directory brew runs from.
    fn prefixDir(self: *Brew, arena: std.mem.Allocator) ?[]const u8 {
        if (std.fs.path.isAbsolute(self.exe)) return std.fs.path.dirname(std.fs.path.dirname(self.exe) orelse return null);
        const exe = self.inPrefix(arena) orelse return null;
        return std.fs.path.dirname(std.fs.path.dirname(exe) orelse return null);
    }

    fn installerExitImpl(ctx: *anyopaque) ?u8 {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        return self.installer_exit;
    }

    /// Homebrew is not there on a fresh mac, so its own installer puts it
    /// there, from a file mox has already fetched and verified.
    /// `NONINTERACTIVE` because `mox apply` is: the installer otherwise stops
    /// to ask for a keypress no unattended run can give it. The bin dir it
    /// installed into comes back so this same run can use it: on a fresh
    /// machine it is on no PATH yet.
    fn bootstrapImpl(ctx: *anyopaque, arena: std.mem.Allocator, installer_path: []const u8) anyerror!?[]const u8 {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        const io = self.io orelse return error.NoBootstrapForBackend;

        self.installer_exit = null;
        const res = try self.runner.streamStep(arena, &(stream_env ++ .{ "NONINTERACTIVE=1", "/bin/bash", installer_path }), "brew: Homebrew's installer");
        try exec.checkTimedOut(res);
        if (!res.ok) {
            self.installer_exit = res.code;
            return bootstrap_mod.Error.BootstrapInstallerFailed;
        }

        for (self.prefixes) |dir| {
            const exe = try std.fs.path.join(arena, &.{ dir, "brew" });
            Io.Dir.cwd().access(io, exe, .{}) catch continue;
            self.exe = exe;
            return dir;
        }
        // An installer that reported success but left `brew` in none of its
        // prefixes is a failed bootstrap, not a manager that then reads as
        // absent for the rest of the run.
        return bootstrap_mod.Error.BootstrapFailed;
    }

    /// Bare, not under `query_env`: `env` would answer an absent brew with
    /// exit 127 rather than the spawn failure that means absent, and
    /// `--version` is answered before brew reaches anything that fetches.
    ///
    /// A brew on no PATH is still looked for where its installer puts it --
    /// the same `prefixes` a bootstrap probes -- before it is called absent,
    /// and one found there is the brew the run uses. Homebrew's installer
    /// leaves `/opt/homebrew/bin` off PATH until a shell profile adds it, so
    /// a second apply from a shell without that line would otherwise ask for
    /// the password and run the installer again over the brew it installed.
    fn availableImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!Backend.Availability {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        const got = Backend.probeAvailability(try std.fmt.allocPrint(arena, "{s} --version", .{self.exe}), self.runner.run(arena, &.{ self.exe, "--version" }));
        if (std.fs.path.isAbsolute(self.exe)) return got;
        const avail = try got;
        if (avail != .absent) return avail;
        const exe = self.inPrefix(arena) orelse return avail;
        self.exe = exe;
        return Backend.probeAvailability(try std.fmt.allocPrint(arena, "{s} --version", .{exe}), self.runner.run(arena, &.{ exe, "--version" }));
    }

    /// The `brew` in the first of `prefixes` that has one, or null.
    fn inPrefix(self: *Brew, arena: std.mem.Allocator) ?[]const u8 {
        const io = self.io orelse return null;
        for (self.prefixes) |dir| {
            const exe = std.fs.path.join(arena, &.{ dir, "brew" }) catch return null;
            Io.Dir.cwd().access(io, exe, .{}) catch continue;
            return exe;
        }
        return null;
    }

    /// `brew list` refreshes the formula and cask API data when the cached
    /// copy is older than a week; under this it never refreshes on that
    /// timer, so a read-only `mox status` does not go to the network for
    /// age alone. A cache that does not exist yet is still populated, once.
    /// Through `env` because an adapter has no environment of its own.
    ///
    /// `HOMEBREW_NO_INSTALL_FROM_API` is unset for the same reason: under it
    /// brew reads homebrew/core and homebrew/cask from local checkouts
    /// instead of the API, and `brew list --installed-on-request` on a
    /// machine that has never tapped homebrew/core clones the whole tap
    /// first -- minutes of network for a listing that needs only the
    /// install receipts. The install is streamed under the user's own
    /// environment, so a user who set it still installs the way they chose.
    const query_env = [_][]const u8{ "env", "-u", "HOMEBREW_NO_INSTALL_FROM_API", "HOMEBREW_NO_AUTO_UPDATE=1", ask_off };

    /// What a streamed brew call runs under: the user's own environment with
    /// Homebrew's ask mode off. Homebrew 7.0.8 turns `HOMEBREW_ASK` on by
    /// default, and with stdin and stdout on a terminal -- an install's are,
    /// when mox has one -- `brew install` stops at `Do you want to proceed
    /// with the installation? [y/n]` whenever its plan carries a dependency
    /// the row did not name (`env_config.rb`; `cmd/install.rb` reads
    /// `--no-ask` from `HOMEBREW_NO_ASK`). Set in the environment rather than
    /// passed as `--yes`, because an older brew ignores a variable it does
    /// not know where it would refuse a flag, and every call is built from
    /// this, so no new one can be made without it.
    const stream_env = [_][]const u8{ "env", ask_off };

    const ask_off = "HOMEBREW_NO_ASK=1";

    /// A row names one formula or cask, and takes `kind` alone.
    ///
    /// The name is judged by what brew accepts, which is not the distro rule:
    /// `@` is in the class because `openssl@3` is a formula, and a
    /// tap-qualified `owner/tap/name` is the one place a `/` belongs -- a row
    /// that spells one IS the decision to trust that tap, which `install`
    /// acts on. Everything else a brew operand can be is refused here.
    /// `brew install --help` exits 0, so a row named `--help` would be
    /// counted installed, reported missing by the query that follows, and
    /// installed again on every apply; `brew install ./x.rb` runs a Ruby file
    /// out of the working directory; `owner/tap` alone names a tap, which is
    /// nothing `brew list` can ever report back.
    fn validateImpl(_: *anyopaque, row: Row, diag: ?*Diag) anyerror!void {
        if (backend_mod.nameProblem(row.name, .tapped)) |problem| {
            if (diag) |d| d.set(
                "{s}: row \"{s}\": brew rows name a formula or cask: {s}",
                .{ row.label, row.name, problem.text(.tapped) },
            );
            return Error.BrewNameNotAPackage;
        }
        for (row.fields) |p| {
            if (!std.mem.eql(u8, p.key, "kind")) {
                if (diag) |d| d.set(
                    "{s}: row \"{s}\": brew accepts no key \"{s}\" (brew rows take \"kind\")",
                    .{ row.label, row.name, p.key },
                );
                return Error.UnknownBrewKey;
            }
            const v = switch (p.value) {
                .string => |s| s,
                else => {
                    if (diag) |d| d.set(
                        "{s}: row \"{s}\": \"kind\" must be \"formula\" or \"cask\"",
                        .{ row.label, row.name },
                    );
                    return Error.BadBrewKind;
                },
            };
            if (!std.mem.eql(u8, v, "formula") and !std.mem.eql(u8, v, "cask")) {
                if (diag) |d| d.set(
                    "{s}: row \"{s}\": \"kind\" is \"{s}\", not \"formula\" or \"cask\"",
                    .{ row.label, row.name, v },
                );
                return Error.BadBrewKind;
            }
        }
    }

    fn idOfImpl(_: *anyopaque, arena: std.mem.Allocator, row: Row) anyerror![]const u8 {
        return switch (try kindOf(row)) {
            .formula => row.name,
            .cask => std.fmt.allocPrint(arena, "{s}{s}", .{ cask_prefix, row.name }),
        };
    }

    fn installedExplicitImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *Brew = @ptrCast(@alignCast(ctx));

        var out: std.ArrayList([]const u8) = .empty;

        const formulae = try self.runner.run(arena, &(query_env ++ .{ self.exe, "list", "--full-name", "--installed-on-request" }));
        try exec.checkTimedOut(formulae);
        if (!formulae.ok) return error.BrewQueryFailed;
        try appendLines(arena, &out, formulae.stdout, "");

        const casks = try self.runner.run(arena, &(query_env ++ .{ self.exe, "list", "--cask", "--full-name" }));
        try exec.checkTimedOut(casks);
        if (!casks.ok) return error.BrewQueryFailed;
        try appendLines(arena, &out, casks.stdout, cask_prefix);

        return out.toOwnedSlice(arena);
    }

    /// The formula rows installed through an alias that now names another
    /// formula. Homebrew records the name an install was asked by in the
    /// install receipt, and `brew upgrade` and `brew reinstall` follow a tap
    /// alias recorded there to whatever it names now
    /// (`Formula#latest_formula`): `brew install emacs-plus` while that alias
    /// named `emacs-plus@30` leaves an `emacs-plus@30` the next upgrade
    /// replaces with `emacs-plus@31`, and when the new target is from an
    /// untrusted tap, every `brew upgrade` and `brew outdated` fails instead.
    ///
    /// No brew query answers this: `brew info --json=v2` carries no install
    /// alias, and `brew outdated` names one only in prose, after loading the
    /// new target -- the load an untrusted one fails. So the receipt is read
    /// from the keg Homebrew reads it from and judged by Homebrew's own rule
    /// (`Formula#installed_alias_path`, `#installed_alias_target_changed?`):
    /// the recorded source is a symlink in the `Aliases` directory of a tap,
    /// and the alias of that name in the formula's own tap names a formula
    /// other than this one by its current name. An install from the API
    /// records no alias, and Homebrew follows none.
    ///
    /// A formula that cannot be judged is that row's answer alone; only a
    /// brew that cannot say where it keeps its kegs and taps fails them all.
    /// Casks have no aliases, and a formula with no receipt is a keg brew
    /// cannot judge either: both are passed over.
    fn astrayImpl(ctx: *anyopaque, arena: std.mem.Allocator, rows: []const Row) anyerror!Backend.Judged {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        var formulae: std.ArrayList(Row) = .empty;
        for (rows) |row| {
            if (try kindOf(row) == .formula) try formulae.append(arena, row);
        }
        if (formulae.items.len == 0) return .{};
        const io = self.io orelse return error.NoIo;

        const places: Places = .{
            .prefix = try self.queryPath(arena, "--prefix"),
            .taps = try std.fs.path.join(arena, &.{ try self.queryPath(arena, "--repository"), "Library", "Taps" }),
        };
        var astray: std.ArrayList(Backend.Astray) = .empty;
        var unchecked: std.ArrayList(Backend.Unchecked) = .empty;
        for (formulae.items) |row| {
            switch (try self.judge(arena, io, places, row)) {
                .held => {},
                .astray => |s| try astray.append(arena, s),
                .unchecked => |why| try unchecked.append(arena, .{ .id = row.name, .why = why }),
            }
        }
        return .{
            .astray = try astray.toOwnedSlice(arena),
            .unchecked = try unchecked.toOwnedSlice(arena),
        };
    }

    const Places = struct {
        prefix: []const u8,
        /// `<repository>/Library/Taps`.
        taps: []const u8,
    };

    const Verdict = union(enum) {
        held,
        astray: Backend.Astray,
        /// Why the row could not be judged, as a clause.
        unchecked: []const u8,
    };

    /// One formula row, judged. Fails only when memory runs out: anything
    /// else that stops the judgment is the row's own `unchecked`.
    fn judge(self: *Brew, arena: std.mem.Allocator, io: Io, places: Places, row: Row) std.mem.Allocator.Error!Verdict {
        const keg = baseName(row.name);
        const path = receiptPath(arena, io, places.prefix, keg) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return .{ .unchecked = try std.fmt.allocPrint(arena, "the keg brew links for it could not be found: {s}", .{fileErrorText(e)}) };
        } orelse return .held;
        const receipt = readReceipt(arena, io, path) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return .{ .unchecked = try std.fmt.allocPrint(arena, "its install receipt {s} could not be read: {s}", .{ path, fileErrorText(e) }) };
        } orelse return .held;
        const recorded = recordedAlias(arena, io, places.taps, receipt.source_path) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return .{ .unchecked = try std.fmt.allocPrint(arena, "the alias {s} its receipt records could not be read: {s}", .{ receipt.source_path, fileErrorText(e) }) };
        } orelse return .held;

        // Homebrew looks the alias up in the formula's own tap
        // (`Formula#full_installed_alias_name`), which the receipt records.
        // An alias there that names nothing it can load fails every
        // `brew upgrade` and `brew outdated` as surely as one that moved.
        const tap = receipt.tap orelse recorded.tap;
        const target: ?[]const u8 = if (tap) |t| blk: {
            const dir = try tapDir(arena, places.taps, t);
            const alias = try std.fs.path.join(arena, &.{ dir, "Aliases", recorded.name });
            const named = aliasTarget(arena, io, alias) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                return .{ .unchecked = try std.fmt.allocPrint(arena, "the alias {s} could not be read: {s}", .{ alias, fileErrorText(e) }) };
            };
            if (named != null) break :blk named;
            // With no alias of that name, Homebrew loads the name as the tap
            // has it otherwise (`Formulary.tap_formula_name_type`): renamed,
            // migrated to another tap, or a formula of its own.
            const instead = tapLoads(arena, io, dir, recorded.name) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                return .{ .unchecked = try std.fmt.allocPrint(arena, "the tap {s} could not be read: {s}", .{ dir, fileErrorText(e) }) };
            };
            break :blk switch (instead) {
                .formula => |f| f,
                .migrated => |to| return .{ .unchecked = try std.fmt.allocPrint(arena, "the alias \"{s}\" is not in its tap any more, whose tap_migrations.json moves that name to \"{s}\", which mox does not follow", .{ recorded.name, to }) },
                .nothing => null,
            };
        } else blk: {
            // Homebrew resolves a homebrew/core alias through the API unless
            // told not to, so a local core checkout can be stale: brew itself
            // is asked, under the user's own environment.
            const named = self.describe(arena, recorded.name) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                return .{ .unchecked = try std.fmt.allocPrint(arena, "brew could not say what the alias \"{s}\" names now: {s}", .{ recorded.name, exec.errorText(e) }) };
            };
            break :blk named.name;
        };
        if (target) |t| if (std.mem.eql(u8, t, keg)) return .held;

        // A formula renamed since it was installed keeps its keg's old name,
        // while Homebrew compares the alias's target with the current one.
        const current = self.describe(arena, row.name) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return .{ .unchecked = try std.fmt.allocPrint(arena, "brew could not describe it, to tell a moved alias from a renamed formula: {s}", .{exec.errorText(e)}) };
        };
        if (target) |t| if (std.mem.eql(u8, t, current.name)) return .held;

        const alias_name = try qualifyBy(arena, tap, recorded.name);
        const why = if (target) |t| blk: {
            const target_name = try qualifyBy(arena, tap, t);
            break :blk try std.fmt.allocPrint(
                arena,
                "installed through the alias \"{s}\", which now names \"{s}\", so brew upgrade and brew reinstall follow it to \"{s}\", and fail while that cannot be loaded",
                .{ alias_name, target_name, target_name },
            );
        } else try std.fmt.allocPrint(
            arena,
            "installed through the alias \"{s}\", which names no formula brew can load now, so brew upgrade and brew outdated fail loading it",
            .{alias_name},
        );
        return .{ .astray = .{
            .id = row.name,
            .why = why,
            .fix = try repair(arena, row.name, receipt, current.disabled, if (target) |t| try qualifyBy(arena, tap, t) else null),
        } };
    }

    /// The absolute path `brew <flag>` prints.
    fn queryPath(self: *Brew, arena: std.mem.Allocator, flag: []const u8) ![]const u8 {
        const res = try self.runner.run(arena, &(query_env ++ .{ self.exe, flag }));
        try exec.checkTimedOut(res);
        if (!res.ok) return error.BrewAnswerFailed;
        const path = std.mem.trim(u8, res.stdout, " \t\r\n");
        if (!std.fs.path.isAbsolute(path)) return error.BrewAnswerUnreadable;
        return path;
    }

    const Described = struct {
        /// The formula's current name, renames and aliases resolved.
        name: []const u8,
        disabled: bool,
    };

    /// The formula `name` loads as, as the user's own brew resolves it:
    /// through the API, or the local checkout when
    /// `HOMEBREW_NO_INSTALL_FROM_API` says so.
    fn describe(self: *Brew, arena: std.mem.Allocator, name: []const u8) !Described {
        const res = try self.runner.run(arena, &.{ "env", "HOMEBREW_NO_AUTO_UPDATE=1", ask_off, self.exe, "info", "--json=v2", "--formula", "--", name });
        try exec.checkTimedOut(res);
        if (!res.ok) return error.BrewAnswerFailed;
        const doc = json.parse(arena, res.stdout, .{}) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return error.BrewAnswerUnreadable,
        };
        if (doc != .object) return error.BrewAnswerUnreadable;
        const list = doc.get("formulae") orelse return error.BrewAnswerUnreadable;
        if (list != .array or list.array.len == 0 or list.array[0] != .object) return error.BrewAnswerUnreadable;
        const got = list.array[0].get("name") orelse return error.BrewAnswerUnreadable;
        if (got != .string or got.string.len == 0) return error.BrewAnswerUnreadable;
        const disabled = list.array[0].get("disabled");
        return .{
            .name = got.string,
            .disabled = disabled != null and disabled.? == .bool and disabled.?.bool,
        };
    }

    /// One `brew install` per row, every row attempted: a formula that fails
    /// halfway down the list must not leave the ones after it uninstalled.
    /// The batch then fails as a whole if any row's install, tap or trust
    /// did. A mark that does not take is that row's own failure instead,
    /// counted in `unmarked`: the rows beside it install all the same.
    ///
    /// The casks whose install elevates (`elevates`) are the exception: they
    /// go first, in one `brew install --cask`, so Homebrew asks for the
    /// password once for all of them rather than once each. Every one of them
    /// is still attempted -- brew 7.0.8 goes on to the next cask when one
    /// fails (`cmd/install.rb` rescues each with `ofail`) -- and when the run
    /// fails, the casks it left uninstalled are read back and named one by
    /// one, so a failure is still attributed to its package. A cask brew
    /// could not describe is not classified, and installs on its own as any
    /// other row does.
    ///
    /// `--` before the name, verified against Homebrew 7.0.1: `brew install
    /// --help` exits 0 having installed nothing, while `brew install --
    /// --help` reads the operand as a formula name and exits 1. `validate` is
    /// what refuses such a name; this bounds what a name reaching brew can
    /// do.
    fn installImpl(ctx: *anyopaque, arena: std.mem.Allocator, rows: []const Row) anyerror!void {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        self.spawned = false;
        self.refused = 0;
        self.marked = 0;
        self.unmarked = 0;
        var elevated: std.StringHashMap(void) = .init(arena);
        const keep = try self.refuseAliases(arena, rows, &elevated);
        self.refused = rows.len - keep.len;

        var together: std.ArrayList(Row) = .empty;
        var alone: std.ArrayList(Row) = .empty;
        for (keep) |row| {
            if (try kindOf(row) == .cask and elevated.contains(row.name)) {
                try together.append(arena, row);
            } else {
                try alone.append(arena, row);
            }
        }

        var failed = false;
        if (together.items.len > 0) {
            if (!try self.installElevated(arena, together.items)) failed = true;
        }

        // Asked once for the batch, and only when a formula row is in it.
        var installed: ?std.StringHashMap(void) = null;
        for (alone.items) |row| {
            const kind = try kindOf(row);
            if (kind == .formula) {
                if (installed == null) installed = try self.installedFormulae(arena);
                // Already there, so it is marked rather than installed, and
                // the tap and the trust an install needs are moot: the tap is
                // on this machine or the formula could not have come from it.
                if (installed.?.contains(row.name)) {
                    try self.markOnRequest(arena, row.name);
                    continue;
                }
            }
            if (!try self.trustTap(arena, row.name, kind)) {
                failed = true;
                continue;
            }
            self.spawned = true;
            const step = try std.fmt.allocPrint(arena, "brew: {s}", .{row.name});
            const res = switch (kind) {
                .formula => try self.runner.streamStep(arena, &(stream_env ++ .{ self.exe, "install", "--", row.name }), step),
                .cask => try self.runner.streamStep(arena, &(stream_env ++ .{ self.exe, "install", "--cask", "--", row.name }), step),
            };
            try exec.checkTimedOut(res);
            if (!res.ok) failed = true;
        }
        if (failed) return error.BrewInstallFailed;
    }

    /// Tap and trust what a tap-qualified name needs before brew will install
    /// it; a core name needs neither. False when either step failed, which
    /// fails that row alone.
    fn trustTap(self: *Brew, arena: std.mem.Allocator, name: []const u8, kind: Kind) anyerror!bool {
        const tap = tapOf(name) orelse return true;
        const tapped = try self.runner.stream(arena, &(stream_env ++ .{ self.exe, "tap", "--", tap }));
        try exec.checkTimedOut(tapped);
        if (!tapped.ok) return false;
        // Trust the one thing named, never the whole tap: an untrusted
        // third-party tap is ignored outright since Homebrew 6.0, and
        // whole-tap trust would extend to every formula and cask it ever
        // adds. brew keeps the two target kinds apart, so a cask trusted as a
        // formula is recorded in the wrong namespace and stays untrusted.
        const flag: []const u8 = switch (kind) {
            .formula => "--formula",
            .cask => "--cask",
        };
        const trusted = try self.runner.stream(arena, &(stream_env ++ .{ self.exe, "trust", flag, "--", name }));
        try exec.checkTimedOut(trusted);
        return trusted.ok;
    }

    /// Install the casks that elevate in one brew run, after saying why the
    /// password may be asked for again. brew fetches every download of the
    /// run before it installs any of them, so that prompt comes once the
    /// downloads are done, not at the start of the run. False when any of them failed: its
    /// tap or trust, or the run itself, after which the casks it left
    /// uninstalled are named.
    fn installElevated(self: *Brew, arena: std.mem.Allocator, rows: []const Row) anyerror!bool {
        var ok = true;
        var names: std.ArrayList([]const u8) = .empty;
        for (rows) |row| {
            if (!try self.trustTap(arena, row.name, .cask)) {
                ok = false;
                continue;
            }
            try names.append(arena, row.name);
        }
        if (names.items.len == 0) return ok;

        const list = try std.mem.join(arena, ", ", names.items);
        self.say(
            "mox: brew: {s} {s} administrator access to install, so {s} installed first, in one brew run; Homebrew downloads them all first, then clears sudo's cached credential before its first elevated step, so the administrator password may be asked once more when the downloads are done\n",
            .{ list, if (names.items.len == 1) "needs" else "need", if (names.items.len == 1) "it is" else "they are" },
        );
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &stream_env);
        try argv.appendSlice(arena, &.{ self.exe, "install", "--cask", "--" });
        try argv.appendSlice(arena, names.items);
        self.spawned = true;
        const res = try self.runner.streamStep(arena, argv.items, try std.fmt.allocPrint(arena, "brew: {s}", .{list}));
        try exec.checkTimedOut(res);
        if (res.ok) return ok;

        // The cask query lists the whole Caskroom, so a name it carries is a
        // cask that is installed, whatever the run's exit said of it.
        const now = self.runner.run(arena, &(query_env ++ .{ self.exe, "list", "--cask", "--full-name" })) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => null,
        };
        if (now == null or now.?.timed_out or !now.?.ok) {
            self.say(
                "mox: brew: the installed casks could not be listed after the batch failed, so whether {s} landed is unknown; brew's message above names the one that failed\n",
                .{list},
            );
            return false;
        }
        var present: std.StringHashMap(void) = .init(arena);
        var lines = std.mem.splitScalar(u8, now.?.stdout, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len > 0) try present.put(line, {});
        }
        for (names.items) |name| {
            if (present.contains(name)) continue;
            self.say("mox: brew: \"{s}\" is not installed after the batch failed; brew's message above says why\n", .{name});
        }
        return false;
    }

    /// Every formula brew has, asked for by name or pulled in behind one --
    /// the question `--installed-on-request` deliberately does not answer.
    /// `--full-name` for the same reason the explicit query carries it: a
    /// tapped formula must come back spelled the way a row spells it.
    ///
    /// A query that cannot be answered yields nothing rather than failing the
    /// batch, which leaves every row to `brew install` as before; the rows
    /// that cannot converge that way are said so the run does not look
    /// clean.
    fn installedFormulae(self: *Brew, arena: std.mem.Allocator) std.mem.Allocator.Error!std.StringHashMap(void) {
        var set: std.StringHashMap(void) = .init(arena);
        const res = self.runner.run(arena, &(query_env ++ .{ self.exe, "list", "--formula", "--full-name" })) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.sayUnlistable();
                return set;
            },
        };
        if (res.timed_out or !res.ok) {
            self.sayUnlistable();
            return set;
        }
        var lines = std.mem.splitScalar(u8, res.stdout, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            try set.put(line, {});
        }
        return set;
    }

    fn sayUnlistable(self: *Brew) void {
        self.say(
            "mox: brew: the installed formulae could not be listed, so a row naming one that is installed already may not converge this run\n",
            .{},
        );
    }

    /// Record that the user asked for an already-installed formula by name.
    /// A mark that does not take is that row's own failure, counted in
    /// `unmarked`, never the batch's: the rows beside it are untouched by it.
    ///
    /// `brew install` writes the flag too, for a formula already current
    /// (`Install.install_formula?`), but upgrades an outdated one on the way,
    /// and an apply installs what is missing and nothing more. `brew tab`
    /// writes the flag alone, refuses a name that is not installed, and keeps
    /// formulae and casks apart the way `brew trust` does. brew's own
    /// `bundle` marks with it too.
    ///
    /// Marking, not installing: the package was on the machine before this
    /// run and is untouched: what changes is brew's record of who asked for
    /// it, which is the row's own claim. mox never uninstalls, and this
    /// direction only makes `brew autoremove` keep more.
    ///
    /// Only the formula half needs it. The cask query lists the whole
    /// Caskroom, so an installed cask is already reported and its row is
    /// never missing.
    fn markOnRequest(self: *Brew, arena: std.mem.Allocator, name: []const u8) anyerror!void {
        self.say(
            "mox: brew: \"{s}\" is installed already but not on request; marking it as installed on request and leaving the package as it is\n",
            .{name},
        );
        const res = try self.runner.stream(arena, &(stream_env ++ .{ self.exe, "tab", "--installed-on-request", "--formula", "--", name }));
        try exec.checkTimedOut(res);
        if (res.ok) {
            self.marked += 1;
            return;
        }
        self.say(
            "mox: brew: \"{s}\" could not be marked as installed on request, so the row stays missing; \"brew tab\" is in Homebrew 4.3.6 and newer\n",
            .{name},
        );
        self.unmarked += 1;
    }

    fn installSpawnedImpl(ctx: *anyopaque) bool {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        return self.spawned;
    }

    fn installRefusedImpl(ctx: *anyopaque) usize {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        return self.refused;
    }

    fn installMarkedImpl(ctx: *anyopaque) usize {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        return self.marked;
    }

    fn installUnmarkedImpl(ctx: *anyopaque) usize {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        return self.unmarked;
    }

    /// Say `fmt` where a refused row can be read, if anywhere.
    fn say(self: *Brew, comptime fmt: []const u8, args: anytype) void {
        const w = self.err orelse return;
        w.print(fmt, args) catch {};
        w.flush() catch {};
    }

    /// Refuse the rows that name an alias rather than the package brew
    /// reports back, and answer with the rest.
    ///
    /// `brew install ag` installs the formula `the_silver_searcher`, and
    /// `brew list --full-name --installed-on-request` maps each installed
    /// formula through its own name: an alias is not one, so the row is
    /// missing and the formula untracked on every run, and every apply
    /// installs it again. Homebrew's own core data carries 469 formula
    /// aliases (`ag`, `7zip`, `awscli@2`) and not one of them is also a
    /// formula name. An old name and a cask's old token go the same way.
    ///
    /// Refused rather than installed-then-reported, because installing under
    /// the alias puts a package on the machine that no row declares and
    /// leaves the user to work out what to write. The canonical name is in
    /// the message instead.
    ///
    /// Only a name brew POSITIVELY resolves to another package is refused.
    /// A tap-qualified row is asked about too, and refused when brew reports
    /// the formula under another name: `brew info --json=v2 --formula --
    /// homebrew/core/ripgrep` exits 0 answering `"full_name": "ripgrep"`, so
    /// that row installs ripgrep and reads as missing for ever. A row naming
    /// a tap this machine does not have gets no answer at all, so it is kept
    /// -- declaring it is the decision to trust that tap.
    ///
    /// The same answers say which casks elevate to install, recorded in
    /// `elevated` by canonical name.
    fn refuseAliases(self: *Brew, arena: std.mem.Allocator, rows: []const Row, elevated: *std.StringHashMap(void)) anyerror![]const Row {
        var asked: [2]bool = .{ false, false };
        // Canonical name -> itself, and each other spelling -> the canonical
        // one. One map per kind, because the two are separate namespaces
        // that share names: 16 of Homebrew's formula aliases and old names
        // are also canonical cask tokens (`dash`, `mediainfo`, `cutter`),
        // and `docker` goes the other way -- a canonical formula name and an
        // old token of the cask `docker-desktop`. One shared map would let
        // whichever kind was asked first answer for the other and suppress
        // its refusal.
        var resolved: [2]std.StringHashMap([]const u8) = .{
            std.StringHashMap([]const u8).init(arena),
            std.StringHashMap([]const u8).init(arena),
        };

        var keep: std.ArrayList(Row) = .empty;
        for (rows) |row| {
            const kind = try kindOf(row);
            const slot = @intFromEnum(kind);
            if (!asked[slot]) {
                asked[slot] = true;
                try self.resolveNames(arena, kind, rows, &resolved[slot], elevated);
            }
            const canonical = resolved[slot].get(row.name) orelse {
                try keep.append(arena, row);
                continue;
            };
            if (std.mem.eql(u8, canonical, row.name)) {
                try keep.append(arena, row);
                continue;
            }
            if (tapOf(row.name) != null) {
                self.say(
                    "mox: brew: row \"{s}\" names the {s} \"{s}\", which is the name brew reports it under, so declare \"{s}\" instead\n",
                    .{ row.name, @tagName(kind), canonical, canonical },
                );
                continue;
            }
            self.say(
                "mox: brew: row \"{s}\" is an alias for the {s} \"{s}\", and brew reports only the {s} name, so declare \"{s}\" instead\n",
                .{ row.name, @tagName(kind), canonical, @tagName(kind), canonical },
            );
        }
        return keep.toOwnedSlice(arena);
    }

    /// Ask brew what each name of `kind` stands for, and record every answer
    /// in `into`: a canonical name under itself, and each alias and old name
    /// under the package it names.
    ///
    /// `brew info --json=v2` is read-only, answers for an uninstalled
    /// package, and is asked about the batch's own names rather than the
    /// whole catalogue: `brew formulae` enumerates every formula there is,
    /// which on a Linux machine without `jq` falls back to Ruby per formula,
    /// warns once per formula, and exhausts a container's memory.
    ///
    /// A formula's `full_name` and a cask's `full_token` are the names `brew
    /// list --full-name` reports, which is what a row must match.
    ///
    /// brew answers for NONE of a batch that carries one name it does not
    /// have: `brew info --json=v2 --formula -- ag zzz-removed-formula` exits
    /// 1 with empty stdout, while the same call without the bad name exits 0.
    /// So a batch that fails is asked again one name at a time -- brew
    /// answers each on its own -- rather than abandoning the check, which
    /// would let one typo or one upstream removal disable alias refusal for
    /// every other row of that kind. That fallback is one call per name and
    /// only on a failed batch; a one-name batch is already its own per-name
    /// call, so it is not repeated.
    ///
    /// A name brew still answers nothing for is left unresolved, which keeps
    /// its row: brew itself answers for a name it does not have when the
    /// install runs.
    fn resolveNames(
        self: *Brew,
        arena: std.mem.Allocator,
        kind: Kind,
        rows: []const Row,
        into: *std.StringHashMap([]const u8),
        elevated: *std.StringHashMap(void),
    ) anyerror!void {
        const flag: []const u8 = switch (kind) {
            .formula => "--formula",
            .cask => "--cask",
        };
        const head = query_env ++ .{ self.exe, "info", "--json=v2", flag, "--" };

        var names: std.ArrayList([]const u8) = .empty;
        for (rows) |row| {
            if (try kindOf(row) != kind) continue;
            try names.append(arena, row.name);
        }
        if (names.items.len == 0) return;

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &head);
        try argv.appendSlice(arena, names.items);
        if (self.runner.run(arena, argv.items)) |res| {
            try exec.checkCaptureTimedOut(res);
            if (res.ok) {
                try recordAnswers(arena, kind, res.stdout, into, elevated);
                return;
            }
        } else |e| switch (e) {
            // A batch answered past the capture cap is one brew answered for,
            // in more JSON than mox reads at once. Each name on its own is an
            // answer that fits, which is what the fallback below asks for.
            error.StreamTooLong => {},
            else => return e,
        }
        if (names.items.len == 1) return;

        // A clock this adapter has no `Io` for cannot bound anything, and a
        // negative budget asks for no bound: both leave the fallback to the
        // per-call one, which is what it had before.
        const clock = if (self.probe_budget_ms < 0) null else self.io;
        const started = if (clock) |io| Io.Timestamp.now(io, .awake) else null;
        for (names.items, 0..) |name, asked| {
            if (started) |from| {
                const elapsed = from.durationTo(Io.Timestamp.now(clock.?, .awake)).toMilliseconds();
                if (elapsed >= self.probe_budget_ms) {
                    self.say(
                        "mox: brew: asking about the {d} {s} names one at a time passed the {d} ms this check gets in total, so {d} of them went unasked; a row naming an alias among those installs under the alias\n",
                        .{ names.items.len, @tagName(kind), self.probe_budget_ms, names.items.len - asked },
                    );
                    return;
                }
            }
            var one: std.ArrayList([]const u8) = .empty;
            try one.appendSlice(arena, &head);
            try one.append(arena, name);
            const got = self.runner.run(arena, one.items) catch |e| switch (e) {
                error.StreamTooLong => {
                    self.say(
                        "mox: brew: `brew info --json=v2 {s} -- {s}` answered with more than the {d} MiB mox reads from one query, so \"{s}\" went unchecked; if it is an alias, its row installs under the alias\n",
                        .{ flag, name, exec.max_query_bytes / (1024 * 1024), name },
                    );
                    continue;
                },
                else => return e,
            };
            try exec.checkCaptureTimedOut(got);
            if (!got.ok) continue;
            try recordAnswers(arena, kind, got.stdout, into, elevated);
        }
    }
};

/// Record one `brew info --json=v2` answer in `into`: the canonical name
/// under itself, each alias and old name under the package it names, and the
/// tap-qualified spelling of the package under the canonical name too.
///
/// The qualified key is what lets a tap-qualified row be judged: brew answers
/// `homebrew/core/ripgrep` with `"tap": "homebrew/core"`, `"name":
/// "ripgrep"` and `"full_name": "ripgrep"`, so the row's own spelling maps to
/// the bare name brew reports. A third-party tap answers `"full_name":
/// "owner/tap/name"`, which is the qualified spelling itself, so such a row
/// resolves to what it already says.
///
/// A cask whose install elevates goes into `elevated` under its canonical
/// name.
fn recordAnswers(
    arena: std.mem.Allocator,
    kind: Kind,
    stdout: []const u8,
    into: *std.StringHashMap([]const u8),
    elevated: *std.StringHashMap(void),
) !void {
    const doc = json.parse(arena, stdout, .{}) catch return;
    if (doc != .object) return;
    const list = doc.get(switch (kind) {
        .formula => "formulae",
        .cask => "casks",
    }) orelse return;
    if (list != .array) return;

    for (list.array) |entry| {
        if (entry != .object) continue;
        const canonical = entry.get(switch (kind) {
            .formula => "full_name",
            .cask => "full_token",
        }) orelse continue;
        if (canonical != .string or canonical.string.len == 0) continue;
        try into.put(canonical.string, canonical.string);
        if (kind == .cask and elevates(entry)) try elevated.put(canonical.string, {});
        if (try qualifiedName(arena, kind, entry)) |qualified| {
            if (!into.contains(qualified)) try into.put(qualified, canonical.string);
        }
        for ([_][]const u8{
            switch (kind) {
                .formula => "aliases",
                .cask => "old_tokens",
            },
            "oldnames",
        }) |key| {
            const names = entry.get(key) orelse continue;
            if (names != .array) continue;
            for (names.array) |n| {
                if (n != .string or n.string.len == 0) continue;
                if (into.contains(n.string)) continue;
                try into.put(n.string, canonical.string);
            }
        }
    }
}

/// Whether installing the cask `brew info --json=v2` describes runs anything
/// under sudo, as far as that JSON can say. It mirrors Homebrew 7.0.8's own
/// `requires_sudo?`, the check that makes brew reset sudo's credential and
/// ask for the password: a `pkg` and a `keyboard_layout` always elevate; an
/// `installer` does when its script says `sudo: true`; preflight and
/// postflight steps do when a step says `sudo: true` or deletes a keychain
/// certificate (the optional `"if_needed"` is left out, as brew leaves it
/// out). Uninstall stanzas never count: nothing here uninstalls.
///
/// What the JSON cannot show is not classified: a cask that elevates only
/// from a `preflight`/`postflight` Ruby block, or through a sudo fallback of
/// its own, appears there as nothing that elevates. Such a cask installs on
/// its own, as any other row does, and its brew run may ask for the
/// password again.
fn elevates(entry: json.Value) bool {
    const artifacts = entry.get("artifacts") orelse return false;
    if (artifacts != .array) return false;
    for (artifacts.array) |artifact| {
        if (artifact != .object) continue;
        const o = artifact.object;
        if (o.get("pkg") != null or o.get("keyboard_layout") != null) return true;
        if (o.get("installer")) |args| {
            if (args == .array) for (args.array) |arg| {
                if (arg != .object) continue;
                const script = arg.object.get("script") orelse continue;
                if (script != .object) continue;
                const sudo = script.object.get("sudo") orelse continue;
                if (sudo == .bool and sudo.bool) return true;
            };
        }
        for ([_][]const u8{ "preflight_steps", "postflight_steps" }) |key| {
            const args = o.get(key) orelse continue;
            if (args != .array) continue;
            for (args.array) |arg| {
                if (arg != .object) continue;
                const steps = arg.object.get("steps") orelse continue;
                if (steps != .array) continue;
                for (steps.array) |step| {
                    if (step != .object) continue;
                    if (step.object.get("sudo")) |v| {
                        if (v == .bool and v.bool) return true;
                    }
                    if (step.object.get("type")) |v| {
                        if (v == .string and std.mem.eql(u8, v.string, "delete_keychain_certificate")) return true;
                    }
                }
            }
        }
    }
    return false;
}

/// `<tap>/<name>` for one `brew info` entry, or null when it carries neither.
fn qualifiedName(arena: std.mem.Allocator, kind: Kind, entry: json.Value) std.mem.Allocator.Error!?[]const u8 {
    const tap = entry.get("tap") orelse return null;
    if (tap != .string or tap.string.len == 0) return null;
    const bare = entry.get(switch (kind) {
        .formula => "name",
        .cask => "token",
    }) orelse return null;
    if (bare != .string or bare.string.len == 0) return null;
    const joined: []const u8 = try std.fmt.allocPrint(arena, "{s}/{s}", .{ tap.string, bare.string });
    return joined;
}

fn declareImpl(_: *anyopaque, _: std.mem.Allocator, id: []const u8) anyerror!Backend.Declaration {
    if (std.mem.startsWith(u8, id, cask_prefix)) {
        return .{
            .name = id[cask_prefix.len..],
            .fields = &.{.{ .key = "kind", .value = .{ .string = "cask" } }},
        };
    }
    return .{ .name = id };
}

/// `validate` has already refused anything but `"formula"` or `"cask"`, so
/// an unexpected value here is a caller that skipped validation, not user
/// input to paper over.
fn kindOf(row: Row) !Kind {
    const f = row.field("kind") orelse return .formula;
    const s = switch (f) {
        .string => |v| v,
        else => return Error.BadBrewKind,
    };
    if (std.mem.eql(u8, s, "formula")) return .formula;
    if (std.mem.eql(u8, s, "cask")) return .cask;
    return Error.BadBrewKind;
}

/// The tap a qualified name belongs to (`owner/tap` of `owner/tap/name`), or
/// null for a core formula or cask.
fn tapOf(name: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, name, '/') orelse return null;
    const rest = name[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return name[0 .. first + 1 + second];
}

/// A formula name without the tap qualifying it: the name of its keg.
fn baseName(name: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
    return name[slash + 1 ..];
}

/// `name` qualified by `tap`, if there is one.
fn qualifyBy(arena: std.mem.Allocator, tap: ?[]const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ tap orelse "", if (tap == null) "" else "/", name });
}

/// What puts an astray formula back under its own name. Only an install by
/// that name rewrites the receipt, and `brew install` leaves an installed
/// formula as it is, so the formula is uninstalled first, ignoring
/// dependents, which `brew uninstall` otherwise refuses over and the install
/// right after it satisfies again. The install is the one the receipt
/// records, `--HEAD` and build options included, which `brew reinstall`
/// would have kept. A disabled formula `brew install` refuses, so the row
/// has to name another -- the alias's target, when it names one -- and the
/// uninstall comes once it does, minding dependents, since nothing installs
/// the formula again.
fn repair(arena: std.mem.Allocator, name: []const u8, receipt: Receipt, disabled: bool, target: ?[]const u8) std.mem.Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    // An allocating writer fails only for want of memory.
    writeRepair(&w.writer, name, receipt, disabled, target) catch return error.OutOfMemory;
    return w.written();
}

fn writeRepair(w: *std.Io.Writer, name: []const u8, receipt: Receipt, disabled: bool, target: ?[]const u8) std.Io.Writer.Error!void {
    if (disabled) {
        try w.print("brew install refuses \"{s}\", which is disabled, so declare ", .{name});
        if (target) |t| try w.print("\"{s}\"", .{t}) else try w.writeAll("a formula brew still installs");
        try w.writeAll(" in its place, then run brew uninstall --formula ");
        try writeShellWord(w, name);
        return w.writeAll(" && mox apply");
    }
    try w.writeAll("brew uninstall --formula --ignore-dependencies ");
    try writeShellWord(w, name);
    try w.writeAll(" && brew install --formula");
    if (receipt.head) try w.writeAll(" --HEAD");
    for (receipt.options) |o| {
        try w.writeByte(' ');
        try writeShellWord(w, o);
    }
    try w.writeByte(' ');
    try writeShellWord(w, name);
}

/// What an install receipt says about how a formula was installed.
const Receipt = struct {
    /// What the install was asked for by: a formula file, an alias, or the
    /// API's cache.
    source_path: []const u8,
    /// The tap the formula came from as a name qualifies a formula with,
    /// null for homebrew/core; itself null when the receipt does not say.
    tap: ??[]const u8,
    head: bool,
    /// The build options the install was given.
    options: []const []const u8,
};

/// The receipt brew writes is a few KiB; anything near this is not one.
const max_receipt_bytes = 4 * 1024 * 1024;

/// The receipt of the keg Homebrew reads a formula's from (`Keg.from_rack`):
/// the linked keg, else the opt-linked one. Null for a formula with neither.
fn receiptPath(arena: std.mem.Allocator, io: Io, prefix: []const u8, keg: []const u8) !?[]const u8 {
    for ([_][]const u8{ "var/homebrew/linked", "opt" }) |dir| {
        const link = try std.fs.path.join(arena, &.{ prefix, dir, keg });
        const st = Io.Dir.cwd().statFile(io, link, .{}) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
        if (st.kind != .directory) continue;
        return try std.fs.path.join(arena, &.{ link, "INSTALL_RECEIPT.json" });
    }
    return null;
}

/// The receipt at `path`; null when there is none or it records no source
/// path.
fn readReceipt(arena: std.mem.Allocator, io: Io, path: []const u8) !?Receipt {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_receipt_bytes)) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return null,
        else => return e,
    };
    const doc = json.parse(arena, bytes, .{}) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return error.NotJson,
    };
    if (doc != .object) return error.NotJson;
    const source = doc.get("source") orelse return null;
    if (source != .object) return null;
    const source_path = source.get("path") orelse return null;
    if (source_path != .string) return null;

    const spec = source.get("spec");
    const tap = source.get("tap");
    var options: std.ArrayList([]const u8) = .empty;
    if (doc.get("used_options")) |used| {
        if (used == .array) for (used.array) |o| {
            if (o == .string and o.string.len > 0) try options.append(arena, o.string);
        };
    }
    return .{
        .source_path = source_path.string,
        .tap = if (tap == null or tap.? != .string or tap.?.string.len == 0)
            null
        else if (isCoreTap(tap.?.string)) @as(?[]const u8, null) else try std.ascii.allocLowerString(arena, tap.?.string),
        .head = spec != null and spec.? == .string and std.mem.eql(u8, spec.?.string, "head"),
        .options = try options.toOwnedSlice(arena),
    };
}

/// Whether `tap` (`user/repo`, as Homebrew spells a tap) is homebrew/core.
fn isCoreTap(tap: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, tap, '/') orelse return false;
    const user = tap[0..slash];
    const repo = tap[slash + 1 ..];
    return (std.ascii.eqlIgnoreCase(user, "homebrew") or std.ascii.eqlIgnoreCase(user, "linuxbrew")) and
        (std.ascii.eqlIgnoreCase(repo, "core") or std.ascii.eqlIgnoreCase(repo, "homebrew-core"));
}

const RecordedAlias = struct {
    /// The alias's own name.
    name: []const u8,
    /// Its tap as a name qualifies a formula with (`owner/tap`), or null for
    /// homebrew/core's.
    tap: ?[]const u8,
};

/// The alias a receipt's `path` records an install through, when it is a
/// symlink in the `Aliases` directory of a tap under `taps`
/// (`<taps>/<user>/<repo>/Aliases/<name>`); null for anything else, which
/// Homebrew follows no alias for.
fn recordedAlias(arena: std.mem.Allocator, io: Io, taps: []const u8, path: []const u8) !?RecordedAlias {
    if (!std.mem.startsWith(u8, path, taps) or path.len <= taps.len or path[taps.len] != '/') return null;
    var parts = std.mem.splitScalar(u8, path[taps.len + 1 ..], '/');
    const user = parts.next() orelse return null;
    const repo = parts.next() orelse return null;
    const dir = parts.next() orelse return null;
    if (user.len == 0 or repo.len == 0 or !std.mem.eql(u8, dir, "Aliases")) return null;
    // Homebrew matches the path anywhere below `Aliases` and names the alias
    // by its basename.
    var name: []const u8 = "";
    while (parts.next()) |part| name = part;
    if (name.len == 0) return null;

    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return null,
        else => return e,
    };
    if (st.kind != .sym_link) return null;
    const short = if (std.mem.startsWith(u8, repo, "homebrew-")) repo["homebrew-".len..] else repo;
    const tap = try std.fmt.allocPrint(arena, "{s}/{s}", .{ user, short });
    return .{
        .name = try arena.dupe(u8, name),
        .tap = if (isCoreTap(tap)) null else tap,
    };
}

/// Where the tap `tap` (`user/repo`) is checked out, as `Tap#path` spells
/// it.
fn tapDir(arena: std.mem.Allocator, taps: []const u8, tap: []const u8) ![]const u8 {
    const slash = std.mem.indexOfScalar(u8, tap, '/') orelse return std.fs.path.join(arena, &.{ taps, tap });
    var repo = tap[slash + 1 ..];
    for ([_][]const u8{ "homebrew-", "linuxbrew-" }) |official| {
        if (std.mem.startsWith(u8, repo, official)) repo = repo[official.len..];
    }
    const rel = try std.fmt.allocPrint(arena, "{s}/homebrew-{s}", .{ tap[0..slash], repo });
    return std.fs.path.join(arena, &.{ taps, std.ascii.lowerString(rel, rel) });
}

const Loads = union(enum) {
    /// The formula the name loads, by its name.
    formula: []const u8,
    /// Where the tap's `tap_migrations.json` sends the name.
    migrated: []const u8,
    nothing,
};

/// What the tap at `dir` loads `name` as when it has no alias of that name,
/// in Homebrew's order (`Formulary.tap_formula_name_type`, then
/// `find_formula_in_tap`): a rename in `formula_renames.json`, a move in
/// `tap_migrations.json`, or a formula file of that name in `Tap#formula_dir`
/// -- the first of `Formula` and `HomebrewFormula` that exists, sharded
/// below, else the tap's root.
fn tapLoads(arena: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8) !Loads {
    if (try jsonEntry(arena, io, try std.fs.path.join(arena, &.{ dir, "formula_renames.json" }), name)) |new| return .{ .formula = new };
    if (try jsonEntry(arena, io, try std.fs.path.join(arena, &.{ dir, "tap_migrations.json" }), name)) |to| return .{ .migrated = to };
    const file = try std.fmt.allocPrint(arena, "{s}.rb", .{name});
    for ([_][]const u8{ "Formula", "HomebrewFormula" }) |sub| {
        const formulae = try std.fs.path.join(arena, &.{ dir, sub });
        var d = Io.Dir.cwd().openDir(io, formulae, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
        defer d.close(io);
        var walker = try d.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .directory and std.mem.eql(u8, entry.basename, file)) return .{ .formula = name };
        }
        return .nothing;
    }
    _ = Io.Dir.cwd().statFile(io, try std.fs.path.join(arena, &.{ dir, file }), .{}) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return .nothing,
        else => return e,
    };
    return .{ .formula = name };
}

/// The string `key` maps to in the JSON object at `path`; null when there is
/// no such file or key.
fn jsonEntry(arena: std.mem.Allocator, io: Io, path: []const u8, key: []const u8) !?[]const u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_receipt_bytes)) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return null,
        else => return e,
    };
    const doc = json.parse(arena, bytes, .{}) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return error.NotJson,
    };
    if (doc != .object) return error.NotJson;
    const v = doc.get(key) orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

/// The formula the alias at `path` names, as Homebrew's alias table has it
/// (`Tap#alias_table`): the file its symlink points at, resolved one level.
/// Null for an alias that is not there or names nothing, which the table
/// leaves out and Homebrew then fails to load.
fn aliasTarget(arena: std.mem.Allocator, io: Io, path: []const u8) !?[]const u8 {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return null,
        else => return e,
    };
    if (st.kind != .file) return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = if (Io.Dir.cwd().readLink(io, path, &buf)) |n|
        std.fs.path.basename(buf[0..n])
    else |e| switch (e) {
        error.NotLink => std.fs.path.basename(path),
        else => return e,
    };
    const target = if (std.mem.endsWith(u8, file, ".rb")) file[0 .. file.len - ".rb".len] else file;
    if (target.len == 0) return null;
    return try arena.dupe(u8, target);
}

/// Why a file brew keeps could not be read, as a clause.
fn fileErrorText(e: anyerror) []const u8 {
    return switch (e) {
        error.NotJson => "it is not JSON",
        error.StreamTooLong => "it is larger than any install receipt",
        error.AccessDenied, error.PermissionDenied => "this user may not read it",
        else => @errorName(e),
    };
}

/// `word` as one word of a POSIX shell command line: bare when it holds
/// nothing a shell reads, single-quoted otherwise.
fn writeShellWord(w: *std.Io.Writer, word: []const u8) !void {
    const bare = word.len > 0 and for (word) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_=.,/+@:%", c) != null)) break false;
    } else true;
    if (bare) return w.writeAll(word);
    try w.writeByte('\'');
    for (word) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

fn appendLines(
    arena: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    text: []const u8,
    prefix: []const u8,
) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        try out.append(arena, if (prefix.len == 0)
            line
        else
            try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, line }));
    }
}

const testing = std.testing;

/// The answer that leaves every formula row to `brew install`: an install
/// asks which formulae are installed already, and a machine with none sends
/// nothing down the marking path.
const nothing_installed: exec.Fake.Entry = .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --formula --full-name" };

fn rowOf(name: []const u8, fields: []const manifest_mod.Pair) Row {
    return .{
        .name = name,
        .backend = "brew",
        .when = null,
        .fields = fields,
        .origin = "/tmp/x.toml",
        .label = "data/packages/darwin.toml",
        .index = 0,
    };
}

test "tapOf: a qualified name names its tap, a core formula none" {
    try testing.expectEqualStrings("d12frosted/emacs-plus", tapOf("d12frosted/emacs-plus/emacs-plus@30").?);
    try testing.expect(tapOf("ripgrep") == null);
    // A two-part name is a tap, not a formula in one; it names no formula to trust.
    try testing.expect(tapOf("owner/tap") == null);
}

test "validate: an unknown key is refused by name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b: Brew = .{ .runner = undefined };
    const be = b.backend();

    const row = rowOf("ripgrep", &.{.{ .key = "tap", .value = .{ .string = "x/y" } }});
    var d: Diag = .{};
    try testing.expectError(Error.UnknownBrewKey, be.validate(row, &d));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "no key \"tap\"") != null);
}

test "validate: kind outside the accepted set is refused" {
    var b: Brew = .{ .runner = undefined };
    const be = b.backend();

    const row = rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "keg" } }});
    var d: Diag = .{};
    try testing.expectError(Error.BadBrewKind, be.validate(row, &d));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "not \"formula\" or \"cask\"") != null);
}

test "validate: a bare row and an explicit kind both pass" {
    var b: Brew = .{ .runner = undefined };
    const be = b.backend();

    try be.validate(rowOf("ripgrep", &.{}), null);
    try be.validate(rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}), null);
}

test "declare: a cask id round-trips back to a cask row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Brew = .{ .runner = undefined };
    const be = b.backend();

    const d = try be.declare(a, "cask:ghostty");
    try testing.expectEqualStrings("ghostty", d.name);
    try testing.expectEqualStrings("cask", d.fields[0].value.string);

    // The contract: idOf of what declare produced is the id it came from.
    const row = rowOf(d.name, d.fields);
    try testing.expectEqualStrings("cask:ghostty", try be.idOf(a, row));
}

test "declare: a formula id round-trips with no fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Brew = .{ .runner = undefined };
    const be = b.backend();

    const d = try be.declare(a, "d12frosted/emacs-plus/emacs-plus@30");
    try testing.expectEqualStrings("d12frosted/emacs-plus/emacs-plus@30", d.name);
    try testing.expectEqual(@as(usize, 0), d.fields.len);
    try testing.expectEqualStrings(
        "d12frosted/emacs-plus/emacs-plus@30",
        try be.idOf(a, rowOf(d.name, d.fields)),
    );
}

test "idOf: a cask id cannot collide with the formula of the same name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Brew = .{ .runner = undefined };
    const be = b.backend();

    const formula = try be.idOf(a, rowOf("docker", &.{}));
    const cask = try be.idOf(a, rowOf("docker", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}));
    try testing.expectEqualStrings("docker", formula);
    try testing.expectEqualStrings("cask:docker", cask);
    try testing.expect(!std.mem.eql(u8, formula, cask));
}

test "installedExplicit: formulae bare, tapped fully qualified, casks prefixed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{
            .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --full-name --installed-on-request",
            .stdout = "ripgrep\nd12frosted/emacs-plus/emacs-plus@30\n",
        },
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --cask --full-name", .stdout = "ghostty\n1password\n" },
    } };
    var b: Brew = .{ .runner = fake.runner() };
    const be = b.backend();

    const got = try be.installedExplicit(a);
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqualStrings("ripgrep", got[0]);
    try testing.expectEqualStrings("d12frosted/emacs-plus/emacs-plus@30", got[1]);
    try testing.expectEqualStrings("cask:ghostty", got[2]);
    try testing.expectEqualStrings("cask:1password", got[3]);
}

test "backend: the cask blind spot is declared, not left to be discovered" {
    var b: Brew = .{ .runner = undefined };
    // Without this, a cask pulled in by another cask's `depends_on cask:`
    // is reported untracked forever with nothing saying why.
    try testing.expectEqualStrings(cask_limitation, b.backend().limitation.?);
    try testing.expect(std.mem.indexOf(u8, cask_limitation, "cask") != null);
}

test "installedExplicit: the cask query is the whole Caskroom, which is what the limitation says" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `--installed-on-request` is not on the cask query and must not be: brew
    // declares the two options as conflicting, so that argv exits 1 with its
    // usage and every cask row would read as missing.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --full-name --installed-on-request", .stdout = "" },
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --cask --full-name", .stdout = "ghostty\n" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    const got = try b.backend().installedExplicit(a);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expect(!fake.called("env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --cask --full-name --installed-on-request"));
}

test "installedExplicit: a failed query is an error, never an empty set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An empty list would read as "nothing installed" and make every desired
    // package look missing.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --full-name --installed-on-request", .code = 1 },
    } };
    var b: Brew = .{ .runner = fake.runner() };
    const be = b.backend();

    try testing.expectError(error.BrewQueryFailed, be.installedExplicit(a));
}

test "available: present when brew answers, absent when it is not there" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ok_fake: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "brew --version", .stdout = "Homebrew 6.0.0\n" }},
    };
    var ok_brew: Brew = .{ .runner = ok_fake.runner() };
    try testing.expect((try ok_brew.backend().available(a)) == .present);

    var missing: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "brew --version", .fail = error.FileNotFound }},
    };
    var missing_brew: Brew = .{ .runner = missing.runner() };
    try testing.expect((try missing_brew.backend().available(a)) == .absent);
}

test "available: a brew that is there but cannot answer is broken, not absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Reading this as "brew is missing" would make every brew row inert
    // with no diagnostic anywhere.
    var fake: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "/opt/homebrew/bin/brew --version", .code = 1 }},
    };
    var b: Brew = .{ .runner = fake.runner(), .exe = "/opt/homebrew/bin/brew" };
    const got = try b.backend().available(a);
    try testing.expectEqual(@as(u8, 1), got.broken.code);
    try testing.expectEqualStrings("/opt/homebrew/bin/brew --version", got.broken.probe);
}

test "available: a failure other than an absent brew is not reported as absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var broken: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "brew --version", .fail = error.AccessDenied }},
    };
    var b: Brew = .{ .runner = broken.runner() };
    try testing.expectError(error.AccessDenied, b.backend().available(a));

    var hung: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "brew --version", .timed_out = true }},
    };
    var h: Brew = .{ .runner = hung.runner() };
    try testing.expectError(error.TimedOut, h.backend().available(a));
}

test "kindOf: a value validate would refuse is an error, not a formula" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Brew = .{ .runner = undefined };

    // Capitalised, so not the accepted spelling: installing it as a formula
    // would run `brew install` against a cask.
    const row = rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "Cask" } }});
    try testing.expectError(Error.BadBrewKind, b.backend().idOf(a, row));
}

test "install: a tapped cask is trusted as a cask, not as a formula" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tap -- owner/tap" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew trust --cask -- owner/tap/somecask" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install --cask -- owner/tap/somecask" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    // The Fake errors on any unscripted command, so `--formula` here fails.
    try b.backend().install(a, &.{rowOf("owner/tap/somecask", &.{.{ .key = "kind", .value = .{ .string = "cask" } }})});
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew trust --cask -- owner/tap/somecask"));
}

test "install: a tapped formula is tapped and trusted narrowly before installing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tap -- d12frosted/emacs-plus" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew trust --formula -- d12frosted/emacs-plus/emacs-plus@30" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- d12frosted/emacs-plus/emacs-plus@30" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try b.backend().install(a, &.{rowOf("d12frosted/emacs-plus/emacs-plus@30", &.{})});
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew tap -- d12frosted/emacs-plus"));
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew trust --formula -- d12frosted/emacs-plus/emacs-plus@30"));
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install -- d12frosted/emacs-plus/emacs-plus@30"));
}

test "install: a core formula is neither tapped nor trusted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- ripgrep" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    // The Fake errors on any command it was not scripted for, so a stray tap
    // or trust here would fail the test rather than pass unnoticed.
    try b.backend().install(a, &.{rowOf("ripgrep", &.{})});
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install -- ripgrep"));
}

test "install: a cask installs through --cask" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install --cask -- ghostty" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try b.backend().install(a, &.{rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }})});
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install --cask -- ghostty"));
}

test "bootstrap: after installing, brew is invoked by the path it landed at" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The probe list is fixed, so nothing is planted: on a machine with brew
    // in one of the prefixes the exe becomes absolute, on any other the
    // bootstrap is a named failure rather than a manager that reads as absent.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env HOMEBREW_NO_ASK=1 NONINTERACTIVE=1 /bin/bash /tmp/i" },
    } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const before = b.exe;
    if (b.backend().bootstrap(a, "/tmp/i")) |dir| {
        try testing.expect(dir != null);
        try testing.expect(std.fs.path.isAbsolute(b.exe));
        try testing.expect(std.mem.endsWith(u8, b.exe, "/brew"));
    } else |e| {
        try testing.expectEqual(bootstrap_mod.Error.BootstrapFailed, e);
        try testing.expectEqualStrings(before, b.exe);
    }
}

test "bootstrap: an installer killed at its bound is a timeout, not a failed bootstrap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env HOMEBREW_NO_ASK=1 NONINTERACTIVE=1 /bin/bash /tmp/i", .timed_out = true },
    } };
    var b: Brew = .{ .runner = fake.runner(), .io = std.testing.io };

    try testing.expectError(error.TimedOut, b.backend().bootstrap(a, "/tmp/i"));
    try testing.expectEqualStrings("brew", b.exe);
}

test "install: a failed tap fails its row and the rows after it still run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The tapped row's trust and install are unscripted, so reaching either
    // would fail the test with a different error than the one asserted.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tap -- owner/tap", .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- ripgrep" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{
        rowOf("owner/tap/thing", &.{}),
        rowOf("ripgrep", &.{}),
    }));
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install -- ripgrep"));
}

test "install: a failed trust fails its row and the rows after it still run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tap -- owner/tap" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew trust --cask -- owner/tap/somecask", .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install --cask -- ghostty" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{
        rowOf("owner/tap/somecask", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}),
        rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}),
    }));
    try testing.expect(!fake.called("env HOMEBREW_NO_ASK=1 brew install --cask -- owner/tap/somecask"));
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install --cask -- ghostty"));
}

test "install: a failed install is an error, not a silent skip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- ripgrep", .code = 1 },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{rowOf("ripgrep", &.{})}));
}

test "validate: a row that is not a formula or cask name is refused" {
    var b: Brew = .{ .runner = undefined };
    const be = b.backend();

    // Measured against Homebrew 7.0.1: `brew install --help` exits 0 having
    // installed nothing, so this row would be counted installed, reported
    // MISSING by the query that follows, and installed again forever.
    for ([_][]const u8{ "--help", "-i", "./evil.rb", "/tmp/evil.rb", "https://evil/x.rb", "owner/tap" }) |name| {
        var d: Diag = .{};
        try testing.expectError(Error.BrewNameNotAPackage, be.validate(rowOf(name, &.{}), &d));
        try testing.expect(std.mem.indexOf(u8, d.capture().?, "brew rows name a formula or cask") != null);
    }

    // What brew really ships still passes.
    for ([_][]const u8{ "ripgrep", "openssl@3", "d12frosted/emacs-plus/emacs-plus@30", "font-fira-code-nerd-font" }) |name| {
        try be.validate(rowOf(name, &.{}), null);
    }
}

test "install: every name brew is handed comes after a --" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Verified against Homebrew 7.0.1: `brew install -- --help` reads the
    // operand as a formula name and exits 1, where `brew install --help`
    // exits 0. `brew tap` and `brew trust` answer a `--` the same way.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tap -- owner/tap" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew trust --formula -- owner/tap/thing" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- owner/tap/thing" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- ripgrep" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install --cask -- ghostty" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try b.backend().install(a, &.{
        rowOf("owner/tap/thing", &.{}),
        rowOf("ripgrep", &.{}),
        rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}),
    });
    for (fake.calls.items) |c| {
        // The one call that hands brew no name at all: it asks which
        // formulae are installed, so there is nothing for a `--` to guard.
        if (std.mem.indexOf(u8, c, "brew list ") != null) continue;
        try testing.expect(std.mem.indexOf(u8, c, " -- ") != null);
    }
}

test "install: a formula brew already has is marked on request, never handed to the installer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A tapped name goes the same way, and needs neither the tap nor the
    // trust: the formula could not be installed from a tap the machine does
    // not have. The Fake errors on any unscripted command, so a stray
    // install, tap or trust here fails the test.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{
            .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --formula --full-name",
            .stdout = "brotli\nd12frosted/emacs-plus/emacs-plus@30\n",
        },
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tab --installed-on-request --formula -- brotli" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tab --installed-on-request --formula -- d12frosted/emacs-plus/emacs-plus@30" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install --cask -- ghostty" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    // The cask beside them still installs: the cask query lists the whole
    // Caskroom, so a missing cask row names a cask that is not there.
    try b.backend().install(a, &.{
        rowOf("brotli", &.{}),
        rowOf("d12frosted/emacs-plus/emacs-plus@30", &.{}),
        rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}),
    });
    try testing.expectEqual(@as(usize, 0), b.backend().installRefused());
    // Two marked, one installed: a run that called all three installed would
    // say mox put two packages on a machine that already had them.
    try testing.expectEqual(@as(usize, 2), b.backend().installMarked());
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew tab --installed-on-request --formula -- brotli"));
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install --cask -- ghostty"));
    // Asked once for the batch, not once per row.
    var asks: usize = 0;
    for (fake.calls.items) |c| {
        if (std.mem.endsWith(u8, c, "brew list --formula --full-name")) asks += 1;
    }
    try testing.expectEqual(@as(usize, 1), asks);
    try testing.expect(std.mem.indexOf(u8, w.written(), "marking it as installed on request and leaving the package as it is") != null);
}

test "install: a mark that fails is that row's failure, and the rows beside it go on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `brew tab` arrived in Homebrew 4.3.6; an older brew answers this argv
    // with an unknown command, and the row cannot converge at all. Falling
    // back to `brew install` would report a success that leaves it missing.
    // Nor is it the batch's failure: the row beside it installs all the same.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --formula --full-name", .stdout = "brotli\n" },
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tab --installed-on-request --formula -- brotli", .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- ripgrep" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try b.backend().install(a, &.{ rowOf("brotli", &.{}), rowOf("ripgrep", &.{}) });
    try testing.expectEqual(@as(usize, 1), b.backend().installUnmarked());
    try testing.expectEqual(@as(usize, 0), b.backend().installMarked());
    try testing.expectEqual(@as(usize, 0), b.backend().installRefused());
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install -- ripgrep"));
    try testing.expect(!fake.called("env HOMEBREW_NO_ASK=1 brew install -- brotli"));
    try testing.expect(std.mem.indexOf(u8, w.written(), "could not be marked as installed on request") != null);
}

test "install: a mark alone never says the batch reached brew's installer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `brew tab` writes a receipt; it installs nothing. A batch of marks
    // that a later row's tap then fails has landed no row at all, so the
    // hedge `installSpawned` drives must not be raised over it.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --formula --full-name", .stdout = "brotli\n" },
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tab --installed-on-request --formula -- brotli" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tap -- owner/tap", .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{ rowOf("brotli", &.{}), rowOf("owner/tap/thing", &.{}) }));
    try testing.expectEqual(@as(usize, 1), b.backend().installMarked());
    try testing.expect(!b.backend().installSpawned());
}

test "install: a query that cannot say what is installed leaves the rows to brew, and says so" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --formula --full-name", .code = 1 },
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- ripgrep" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try b.backend().install(a, &.{rowOf("ripgrep", &.{})});
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install -- ripgrep"));
    try testing.expect(std.mem.indexOf(u8, w.written(), "could not be listed") != null);
}

test "install: whether brew's installer ran is what says the rows may have landed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A tap that fails stops its row before any install, so a batch of that
    // one row reached brew's installer not at all and nothing can have
    // landed.
    var tap: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tap -- owner/tap", .code = 1 },
    } };
    var b1: Brew = .{ .runner = tap.runner() };
    try testing.expectError(error.BrewInstallFailed, b1.backend().install(a, &.{rowOf("owner/tap/thing", &.{})}));
    try testing.expect(!b1.backend().installSpawned());

    // An install that ran and failed is the other answer.
    var ran: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- ripgrep", .code = 1 },
    } };
    var b2: Brew = .{ .runner = ran.runner() };
    try testing.expectError(error.BrewInstallFailed, b2.backend().install(a, &.{rowOf("ripgrep", &.{})}));
    try testing.expect(b2.backend().installSpawned());

    // And the answer is the last batch's, never the one before it.
    var tap2: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tap -- owner/tap", .code = 1 },
    } };
    b2.runner = tap2.runner();
    try testing.expectError(error.BrewInstallFailed, b2.backend().install(a, &.{rowOf("owner/tap/thing", &.{})}));
    try testing.expect(!b2.backend().installSpawned());
}

test "install: an alias row is refused, naming the formula brew reports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved read-only against Homebrew 7.0.1: `brew install ag` installs the
    // formula `the_silver_searcher`, which is the name `brew list --full-name
    // --installed-on-request` reports, so an `ag` row is missing and that
    // formula untracked on every run. `brew info --json=v2 ag` answers
    // `"full_name": "the_silver_searcher"`, with `ag` among its aliases.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{
            .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- ag ripgrep",
            .stdout =
            \\{"formulae":[{"full_name":"the_silver_searcher","aliases":["ag"],"oldnames":[]},{"full_name":"ripgrep","aliases":[],"oldnames":[]}],"casks":[]}
            ,
        },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- ripgrep" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try b.backend().install(a, &.{ rowOf("ag", &.{}), rowOf("ripgrep", &.{}) });
    try testing.expectEqual(@as(usize, 1), b.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: brew: row \"ag\" is an alias for the formula \"the_silver_searcher\", and brew reports only the formula name, so declare \"the_silver_searcher\" instead\n",
        w.written(),
    );
    // The alias never reached brew, and the row beside it did.
    try testing.expect(!fake.called("env HOMEBREW_NO_ASK=1 brew install -- ag"));
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install -- ripgrep"));
}

test "install: a cask's old token is refused the same way, and asks only about casks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{
            .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --cask -- oldghost",
            .stdout =
            \\{"formulae":[],"casks":[{"token":"ghostty","full_token":"ghostty","old_tokens":["oldghost"]}]}
            ,
        },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try b.backend().install(a, &.{rowOf("oldghost", &.{.{ .key = "kind", .value = .{ .string = "cask" } }})});
    try testing.expectEqual(@as(usize, 1), b.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: brew: row \"oldghost\" is an alias for the cask \"ghostty\", and brew reports only the cask name, so declare \"ghostty\" instead\n",
        w.written(),
    );
    // The formula side is never asked about: a cask row is judged as a cask.
    for (fake.calls.items) |c| try testing.expect(std.mem.indexOf(u8, c, "--formula") == null);
}

test "install: a name brew resolves to nothing is handed to brew, not refused here" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Only a name brew POSITIVELY resolves to another package is refused.
    // brew itself is what answers for a name it has never heard of.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- nosuchthing", .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- nosuchthing", .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{rowOf("nosuchthing", &.{})}));
    try testing.expectEqual(@as(usize, 0), b.backend().installRefused());
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install -- nosuchthing"));
}

test "install: a row naming a tap the machine lacks is kept, brew answering nothing for it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Verified against Homebrew 7.0.2: `brew info --json=v2 --formula --
    // zzzowner/zzztap/thing` exits 1 with "This command requires the tap
    // zzzowner/zzztap". Nothing resolved the row, so it reaches the tap and
    // install this same run adds -- declaring it IS the decision to trust
    // that tap.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- d12frosted/emacs-plus/emacs-plus@30", .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tap -- d12frosted/emacs-plus" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew trust --formula -- d12frosted/emacs-plus/emacs-plus@30" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- d12frosted/emacs-plus/emacs-plus@30" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try b.backend().install(a, &.{rowOf("d12frosted/emacs-plus/emacs-plus@30", &.{})});
    try testing.expectEqual(@as(usize, 0), b.backend().installRefused());
}

test "install: a row qualifying a tap brew reports bare is refused, naming the bare formula" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved read-only against Homebrew 7.0.2: `brew info --json=v2
    // --formula -- homebrew/core/ripgrep` exits 0 with `"tap":
    // "homebrew/core"`, `"name": "ripgrep"` and `"full_name": "ripgrep"`, and
    // `brew list --full-name --installed-on-request` reports that formula
    // `ripgrep` -- so the qualified row would read as missing for ever.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{
            .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- homebrew/core/ripgrep",
            .stdout =
            \\{"formulae":[{"full_name":"ripgrep","name":"ripgrep","tap":"homebrew/core","aliases":[],"oldnames":[]}],"casks":[]}
            ,
        },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try b.backend().install(a, &.{rowOf("homebrew/core/ripgrep", &.{})});
    try testing.expectEqual(@as(usize, 1), b.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: brew: row \"homebrew/core/ripgrep\" names the formula \"ripgrep\", which is the name brew reports it under, so declare \"ripgrep\" instead\n",
        w.written(),
    );
    try testing.expect(!fake.called("env HOMEBREW_NO_ASK=1 brew tap -- homebrew/core"));
    try testing.expect(!fake.called("env HOMEBREW_NO_ASK=1 brew install -- homebrew/core/ripgrep"));
}

test "install: a row qualifying a third-party tap is kept, brew reporting it qualified" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved read-only against Homebrew 7.0.2 with that tap present: the
    // answer carries `"full_name": "d12frosted/emacs-plus/emacs-plus@30"`,
    // which is the row's own spelling, so nothing is refused.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{
            .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- d12frosted/emacs-plus/emacs-plus@30",
            .stdout =
            \\{"formulae":[{"full_name":"d12frosted/emacs-plus/emacs-plus@30","name":"emacs-plus@30","tap":"d12frosted/emacs-plus","aliases":[],"oldnames":[]}],"casks":[]}
            ,
        },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew tap -- d12frosted/emacs-plus" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew trust --formula -- d12frosted/emacs-plus/emacs-plus@30" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- d12frosted/emacs-plus/emacs-plus@30" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try b.backend().install(a, &.{rowOf("d12frosted/emacs-plus/emacs-plus@30", &.{})});
    try testing.expectEqual(@as(usize, 0), b.backend().installRefused());
    try testing.expectEqualStrings("", w.written());
}

test "install: one unresolvable name does not disable alias refusal for the batch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved read-only against Homebrew 7.0.2: `brew info --json=v2
    // --formula -- ag zzz-removed-formula` exits 1 with EMPTY stdout, while
    // the same call without the bad name exits 0. On a fresh machine every
    // brew row is missing, so the whole manifest is one batch and one typo
    // would otherwise turn the check off for all of it.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- ag zzz-removed-formula", .code = 1 },
        .{
            .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- ag",
            .stdout =
            \\{"formulae":[{"full_name":"the_silver_searcher","name":"the_silver_searcher","tap":"homebrew/core","aliases":["ag"],"oldnames":[]}],"casks":[]}
            ,
        },
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- zzz-removed-formula", .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- zzz-removed-formula", .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{
        rowOf("ag", &.{}),
        rowOf("zzz-removed-formula", &.{}),
    }));
    try testing.expectEqual(@as(usize, 1), b.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: brew: row \"ag\" is an alias for the formula \"the_silver_searcher\", and brew reports only the formula name, so declare \"the_silver_searcher\" instead\n",
        w.written(),
    );
    // The alias never reached brew; the name brew could not resolve did.
    try testing.expect(!fake.called("env HOMEBREW_NO_ASK=1 brew install -- ag"));
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install -- zzz-removed-formula"));
}

test "install: the per-name fallback stops at its budget, saying what went unasked" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every call of the fallback answers to the per-call bound alone, so a
    // manifest of 120 formulas and one bad name costs 121 of those and no
    // setting caps the total. One budget over all of them does.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- ag bat zzz-removed-formula", .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- ag" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- bat" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- zzz-removed-formula" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .io = io, .err = &w.writer, .probe_budget_ms = 0 };

    try b.backend().install(a, &.{ rowOf("ag", &.{}), rowOf("bat", &.{}), rowOf("zzz-removed-formula", &.{}) });
    try testing.expectEqualStrings(
        "mox: brew: asking about the 3 formula names one at a time passed the 0 ms this check gets in total, so 3 of them went unasked; a row naming an alias among those installs under the alias\n",
        w.written(),
    );
    // Unasked is not refused: the rows stand, which is the direction that
    // installs rather than the one that keeps packages off the machine.
    try testing.expectEqual(@as(usize, 0), b.backend().installRefused());
    try testing.expect(!fake.called("env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- ag"));
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install -- ag"));
}

test "install: a budget mox has no clock for leaves the fallback as it was" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every name is still asked about: a bound that cannot be measured must
    // not silently turn the check off.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- ag bat", .code = 1 },
        .{
            .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- ag",
            .stdout =
            \\{"formulae":[{"full_name":"the_silver_searcher","name":"the_silver_searcher","tap":"homebrew/core","aliases":["ag"],"oldnames":[]}],"casks":[]}
            ,
        },
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- bat", .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer, .probe_budget_ms = 0 };

    try b.backend().install(a, &.{ rowOf("ag", &.{}), rowOf("bat", &.{}) });
    try testing.expectEqual(@as(usize, 1), b.backend().installRefused());
    try testing.expect(fake.called("env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- ag"));
    try testing.expect(std.mem.indexOf(u8, w.written(), "went unasked") == null);
}

test "install: a batch answered past the capture cap is asked name by name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `brew info --json=v2` over a whole manifest is the one answer here that
    // can outgrow what mox reads from a query. Letting that abort the install
    // would keep every package off the machine over an answer that is merely
    // large; each name on its own is an answer that fits.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- ag bat", .fail = error.StreamTooLong },
        .{
            .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- ag",
            .stdout =
            \\{"formulae":[{"full_name":"the_silver_searcher","name":"the_silver_searcher","tap":"homebrew/core","aliases":["ag"],"oldnames":[]}],"casks":[]}
            ,
        },
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- bat", .fail = error.StreamTooLong },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- bat" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try b.backend().install(a, &.{ rowOf("ag", &.{}), rowOf("bat", &.{}) });
    // The alias was still caught, and the name that answered with nothing
    // usable was left to brew -- said by name, so a row that then installs
    // under an alias has its reason on the terminal.
    try testing.expectEqual(@as(usize, 1), b.backend().installRefused());
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install -- bat"));
    try testing.expect(!fake.called("env HOMEBREW_NO_ASK=1 brew install -- ag"));
    try testing.expect(std.mem.startsWith(
        u8,
        w.written(),
        "mox: brew: `brew info --json=v2 --formula -- bat` answered with more than the 8 MiB mox reads from one query, so \"bat\" went unchecked; if it is an alias, its row installs under the alias\n",
    ));
}

test "install: a formula row and a cask row of one name each get their own answer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved read-only against Homebrew 7.0.2: `docker` is a canonical
    // FORMULA name and an old token of the cask `docker-desktop`. One map
    // shared by both kinds let the formula answer claim the key and the cask
    // row install docker-desktop, which `brew list --cask --full-name`
    // reports under that name alone.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{
            .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- docker",
            .stdout =
            \\{"formulae":[{"full_name":"docker","name":"docker","tap":"homebrew/core","aliases":[],"oldnames":[]}],"casks":[]}
            ,
        },
        .{
            .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --cask -- docker",
            .stdout =
            \\{"formulae":[],"casks":[{"token":"docker-desktop","full_token":"docker-desktop","tap":"homebrew/cask","old_tokens":["docker"]}]}
            ,
        },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- docker" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try b.backend().install(a, &.{
        rowOf("docker", &.{}),
        rowOf("docker", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}),
    });
    try testing.expectEqual(@as(usize, 1), b.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: brew: row \"docker\" is an alias for the cask \"docker-desktop\", and brew reports only the cask name, so declare \"docker-desktop\" instead\n",
        w.written(),
    );
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install -- docker"));
    try testing.expect(!fake.called("env HOMEBREW_NO_ASK=1 brew install --cask -- docker"));
}

test "install: a cask row and a formula row of one name each get their own answer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The mirror case, and the one that proves the fix is not an ordering
    // accident: `dash` is a canonical CASK token and an old name of the
    // formula `dash-shell`, both verified read-only against Homebrew 7.0.2.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        nothing_installed,
        .{
            .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --cask -- dash",
            .stdout =
            \\{"formulae":[],"casks":[{"token":"dash","full_token":"dash","tap":"homebrew/cask","old_tokens":[]}]}
            ,
        },
        .{
            .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- dash",
            .stdout =
            \\{"formulae":[{"full_name":"dash-shell","name":"dash-shell","tap":"homebrew/core","aliases":[],"oldnames":["dash"]}],"casks":[]}
            ,
        },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install --cask -- dash" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try b.backend().install(a, &.{
        rowOf("dash", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}),
        rowOf("dash", &.{}),
    });
    try testing.expectEqual(@as(usize, 1), b.backend().installRefused());
    try testing.expectEqualStrings(
        "mox: brew: row \"dash\" is an alias for the formula \"dash-shell\", and brew reports only the formula name, so declare \"dash-shell\" instead\n",
        w.written(),
    );
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install --cask -- dash"));
    try testing.expect(!fake.called("env HOMEBREW_NO_ASK=1 brew install -- dash"));
}

test "the captured queries run without HOMEBREW_NO_INSTALL_FROM_API, and the install keeps the caller's environment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Under that variable brew reads homebrew/core from a local checkout,
    // and `brew list --installed-on-request` on a machine that has never
    // tapped it clones the whole tap first -- minutes of network for a
    // read-only status. The install is the user's own call, in the user's
    // own environment.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --full-name --installed-on-request", .stdout = "ripgrep\n" },
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --cask --full-name", .stdout = "" },
        nothing_installed,
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- bat" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    const got = try b.backend().installedExplicit(a);
    try testing.expectEqual(@as(usize, 1), got.len);
    try b.backend().install(a, &.{rowOf("bat", &.{})});

    for (fake.calls.items, fake.streamed.items) |call, streamed| {
        if (streamed) {
            // The caller's own environment, with ask mode alone turned off.
            try testing.expect(std.mem.startsWith(u8, call, "env HOMEBREW_NO_ASK=1 brew "));
        } else {
            try testing.expect(std.mem.startsWith(u8, call, "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew "));
        }
    }
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install -- bat"));
}

/// `brew info --json=v2 --cask` for a plain cask and the two shapes of a cask
/// whose install elevates, as Homebrew 7.0.8 writes them: karabiner-elements
/// installs a `pkg`, logi-options+ runs its installer under `sudo: true`.
const sudo_casks_info =
    \\{"formulae":[],"casks":[
    \\{"token":"ghostty","full_token":"ghostty","tap":"homebrew/cask","old_tokens":[],"artifacts":[{"app":["Ghostty.app"],"target":"/Applications/Ghostty.app"}]},
    \\{"token":"karabiner-elements","full_token":"karabiner-elements","tap":"homebrew/cask","old_tokens":[],"artifacts":[{"uninstall":[{"early_script":{"executable":"/x/remove_files.sh","sudo":true}}]},{"pkg":["Karabiner-Elements.pkg"]},{"binary":["/x/karabiner_cli"]}]},
    \\{"token":"logi-options+","full_token":"logi-options+","tap":"homebrew/cask","old_tokens":[],"artifacts":[{"installer":[{"script":{"executable":"logioptionsplus_installer.app/Contents/MacOS/logioptionsplus_installer","args":["--quiet"],"sudo":true}}]}]}
    \\]}
;

const cask_info_argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --cask -- ";
const formula_info_argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- ";
const cask_list_argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew list --cask --full-name";

fn caskRow(name: []const u8) Row {
    return rowOf(name, &.{.{ .key = "kind", .value = .{ .string = "cask" } }});
}

const batch_heads_up = "mox: brew: karabiner-elements, logi-options+ need administrator access to install, so they are installed first, in one brew run; Homebrew downloads them all first, then clears sudo's cached credential before its first elevated step, so the administrator password may be asked once more when the downloads are done\n";

test "install: the casks that elevate install first, in one brew run, after a heads-up" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = formula_info_argv ++ "fd", .code = 1 },
        .{ .argv = cask_info_argv ++ "ghostty karabiner-elements logi-options+", .stdout = sudo_casks_info },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install --cask -- karabiner-elements logi-options+" },
        nothing_installed,
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- fd" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install --cask -- ghostty" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try b.backend().install(a, &.{ rowOf("fd", &.{}), caskRow("ghostty"), caskRow("karabiner-elements"), caskRow("logi-options+") });

    // Homebrew asks for the password again in every brew process that first
    // needs sudo, so the two that elevate share one process, and it runs
    // before the formulae while the user is still at the keyboard.
    try testing.expectEqualSlices(u8, "env HOMEBREW_NO_ASK=1 brew install --cask -- karabiner-elements logi-options+", fake.calls.items[2]);
    const want = [_][]const u8{
        formula_info_argv ++ "fd",
        cask_info_argv ++ "ghostty karabiner-elements logi-options+",
        "env HOMEBREW_NO_ASK=1 brew install --cask -- karabiner-elements logi-options+",
        nothing_installed.argv,
        "env HOMEBREW_NO_ASK=1 brew install -- fd",
        "env HOMEBREW_NO_ASK=1 brew install --cask -- ghostty",
    };
    try testing.expectEqual(want.len, fake.calls.items.len);
    for (want, fake.calls.items) |x, y| try testing.expectEqualStrings(x, y);
    try testing.expectEqualStrings("brew: karabiner-elements, logi-options+", fake.steps.items[2]);
    try testing.expectEqualStrings("brew: fd", fake.steps.items[4]);
    try testing.expectEqualStrings("brew: ghostty", fake.steps.items[5]);
    try testing.expectEqualStrings(batch_heads_up, w.written());
}

test "install: a batch that fails part-way is read back, and each cask it left out is named" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // brew 7.0.8 goes on to the next cask when one fails (`cmd/install.rb`
    // rescues each with `ofail`), so the batch exits 1 having installed the
    // rest; what landed is read back rather than guessed at.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = cask_info_argv ++ "ghostty karabiner-elements logi-options+", .stdout = sudo_casks_info },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install --cask -- karabiner-elements logi-options+", .code = 1 },
        .{ .argv = cask_list_argv, .stdout = "firefox\nkarabiner-elements\n" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install --cask -- ghostty" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{ caskRow("ghostty"), caskRow("karabiner-elements"), caskRow("logi-options+") }));
    try testing.expect(b.backend().installSpawned());
    // The row after the batch still runs.
    try testing.expect(fake.called("env HOMEBREW_NO_ASK=1 brew install --cask -- ghostty"));
    try testing.expectEqualStrings(
        batch_heads_up ++
            "mox: brew: \"logi-options+\" is not installed after the batch failed; brew's message above says why\n",
        w.written(),
    );
}

test "install: a failed batch whose casks cannot be listed says which of them may not have landed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = cask_info_argv ++ "karabiner-elements logi-options+", .stdout = sudo_casks_info },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install --cask -- karabiner-elements logi-options+", .code = 1 },
        .{ .argv = cask_list_argv, .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{ caskRow("karabiner-elements"), caskRow("logi-options+") }));
    try testing.expectEqualStrings(
        batch_heads_up ++
            "mox: brew: the installed casks could not be listed after the batch failed, so whether karabiner-elements, logi-options+ landed is unknown; brew's message above names the one that failed\n",
        w.written(),
    );
}

test "install: with no cask that elevates there is no batch and no heads-up" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = formula_info_argv ++ "fd", .code = 1 },
        .{ .argv = cask_info_argv ++ "ghostty", .stdout = sudo_casks_info },
        nothing_installed,
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install -- fd" },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install --cask -- ghostty" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try b.backend().install(a, &.{ rowOf("fd", &.{}), caskRow("ghostty") });
    const want = [_][]const u8{
        formula_info_argv ++ "fd",
        cask_info_argv ++ "ghostty",
        nothing_installed.argv,
        "env HOMEBREW_NO_ASK=1 brew install -- fd",
        "env HOMEBREW_NO_ASK=1 brew install --cask -- ghostty",
    };
    try testing.expectEqual(want.len, fake.calls.items.len);
    for (want, fake.calls.items) |x, y| try testing.expectEqualStrings(x, y);
    try testing.expectEqualStrings("", w.written());
}

test "install: a cask brew cannot describe is installed on its own, as before" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No answer means no classification, never a guess that it elevates.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = cask_info_argv ++ "logi-options+", .code = 1 },
        .{ .argv = "env HOMEBREW_NO_ASK=1 brew install --cask -- logi-options+" },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try b.backend().install(a, &.{caskRow("logi-options+")});
    try testing.expectEqualStrings("", w.written());
}

test "elevates: Homebrew's own rule for an install that needs sudo, read from brew info" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { artifacts: []const u8, want: bool }{
        .{ .artifacts = "[{\"app\":[\"A.app\"]}]", .want = false },
        .{ .artifacts = "[{\"pkg\":[\"A.pkg\"]}]", .want = true },
        .{ .artifacts = "[{\"keyboard_layout\":[\"A.bundle\"]}]", .want = true },
        .{ .artifacts = "[{\"installer\":[{\"script\":{\"executable\":\"x\",\"sudo\":true}}]}]", .want = true },
        .{ .artifacts = "[{\"installer\":[{\"script\":{\"executable\":\"x\",\"sudo\":false}}]}]", .want = false },
        .{ .artifacts = "[{\"installer\":[{\"script\":\"x\"}]}]", .want = false },
        .{ .artifacts = "[{\"installer\":[{\"manual\":\"A Installer.app\"}]}]", .want = false },
        .{ .artifacts = "[{\"preflight_steps\":[{\"steps\":[{\"type\":\"run\",\"sudo\":true}]}]}]", .want = true },
        .{ .artifacts = "[{\"postflight_steps\":[{\"steps\":[{\"type\":\"delete_keychain_certificate\"}]}]}]", .want = true },
        .{ .artifacts = "[{\"postflight_steps\":[{\"steps\":[{\"type\":\"run\",\"sudo\":\"if_needed\"}]}]}]", .want = false },
        // An uninstall step that elevates says nothing about the install.
        .{ .artifacts = "[{\"uninstall\":[{\"early_script\":{\"executable\":\"x\",\"sudo\":true}}]}]", .want = false },
    };
    for (cases) |c| {
        const doc = try json.parse(a, try std.fmt.allocPrint(a, "{{\"artifacts\":{s}}}", .{c.artifacts}), .{});
        try testing.expectEqual(c.want, elevates(doc));
    }
}

test "every brew child but the bare version probe runs with ask mode off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Homebrew 7.0.8 asks `Do you want to proceed with the installation?`
    // whenever stdin and stdout are terminals, which an install's are, and
    // reads the answer from the terminal; `HOMEBREW_NO_ASK` turns that off,
    // and an older brew ignores a variable it does not know. Every kind of
    // call is made here: the queries, the elevated batch, a tap and a trust,
    // a mark, a plain install, and the installer.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew --version", .stdout = "Homebrew 7.0.8\n" },
        .{ .argv = formula_info_argv, .match = .prefix, .code = 1 },
        .{ .argv = cask_info_argv ++ "ghostty karabiner-elements logi-options+", .stdout = sudo_casks_info },
        .{ .argv = "brew install --cask -- karabiner-elements logi-options+", .match = .suffix },
        .{ .argv = "brew list --formula --full-name", .match = .suffix, .stdout = "brotli\n" },
        .{ .argv = "brew tab --installed-on-request --formula -- brotli", .match = .suffix },
        .{ .argv = "brew tap -- owner/tap", .match = .suffix },
        .{ .argv = "brew trust --formula -- owner/tap/thing", .match = .suffix },
        .{ .argv = "brew install -- owner/tap/thing", .match = .suffix },
        .{ .argv = "brew install --cask -- ghostty", .match = .suffix },
        .{ .argv = "/bin/bash /tmp/i", .match = .suffix, .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer, .io = std.testing.io };

    _ = try b.backend().available(a);
    try b.backend().install(a, &.{
        rowOf("brotli", &.{}),
        rowOf("owner/tap/thing", &.{}),
        caskRow("ghostty"),
        caskRow("karabiner-elements"),
        caskRow("logi-options+"),
    });
    _ = b.backend().bootstrap(a, "/tmp/i") catch {};

    try testing.expect(fake.calls.items.len >= 11);
    for (fake.calls.items) |call| {
        if (std.mem.eql(u8, call, "brew --version")) continue;
        errdefer std.debug.print("without HOMEBREW_NO_ASK=1: {s}\n", .{call});
        try testing.expect(std.mem.startsWith(u8, call, "env ") and std.mem.indexOf(u8, call, " HOMEBREW_NO_ASK=1 ") != null);
    }
}

/// A Homebrew prefix in a scratch directory, holding just what the astray
/// check reads: a tap's `Aliases` and `Formula` directories, and the
/// install receipts under `opt`.
const Prefix = struct {
    a: std.mem.Allocator,
    io: Io,
    root: []const u8,

    const tap_dir = "Library/Taps/owner/homebrew-tap";

    fn init(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir) !Prefix {
        const cwd = try std.process.currentPathAlloc(io, a);
        const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
        try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ root, tap_dir, "Aliases" }));
        try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ root, tap_dir, "Formula" }));
        return .{ .a = a, .io = io, .root = root };
    }

    /// A tap alias naming `formula`, whose file the tap has.
    fn alias(self: Prefix, name: []const u8, formula: []const u8) !void {
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = try self.formulaPath(formula), .data = "" });
        const link = try std.fs.path.join(self.a, &.{ self.root, tap_dir, "Aliases", name });
        try Io.Dir.cwd().symLink(self.io, try std.fmt.allocPrint(self.a, "../Formula/{s}.rb", .{formula}), link, .{});
    }

    fn aliasPath(self: Prefix, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.a, &.{ self.root, tap_dir, "Aliases", name });
    }

    fn formulaPath(self: Prefix, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.a, &.{ self.root, tap_dir, "Formula", try std.fmt.allocPrint(self.a, "{s}.rb", .{name}) });
    }

    /// An installed `keg` whose receipt records `source` as where it was
    /// installed from.
    fn installed(self: Prefix, keg: []const u8, source: []const u8) !void {
        return self.installedWith(keg, source, "owner/tap", "stable", "[]");
    }

    fn installedWith(self: Prefix, keg: []const u8, source: []const u8, tap: []const u8, spec: []const u8, options: []const u8) !void {
        const dir = try std.fs.path.join(self.a, &.{ self.root, "opt", keg });
        try Io.Dir.cwd().createDirPath(self.io, dir);
        try Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = try std.fs.path.join(self.a, &.{ dir, "INSTALL_RECEIPT.json" }),
            .data = try std.fmt.allocPrint(self.a, "{{\"installed_on_request\":true,\"used_options\":{s},\"source\":{{\"tap\":\"{s}\",\"path\":\"{s}\",\"spec\":\"{s}\"}}}}", .{ options, tap, source, spec }),
        });
    }

    /// The answers to `brew --prefix` and `brew --repository`, which are one
    /// directory here, as on an Apple silicon mac.
    fn entries(self: Prefix) [2]exec.Fake.Entry {
        return .{
            .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew --prefix", .stdout = self.root },
            .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew --repository", .stdout = self.root },
        };
    }
};

/// What `brew info` says `name` is now: `current`, disabled or not.
fn described(a: std.mem.Allocator, name: []const u8, current: []const u8, disabled: bool) !exec.Fake.Entry {
    return .{
        .argv = try std.fmt.allocPrint(a, "env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- {s}", .{name}),
        .stdout = try std.fmt.allocPrint(a, "{{\"formulae\":[{{\"name\":\"{s}\",\"disabled\":{}}}]}}", .{ current, disabled }),
    };
}

test "astray: a formula installed through an alias that now names another formula" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    // Installed as `owner/tap/emacs-plus` while the alias named @30; the
    // alias has since moved to @31.
    try p.alias("emacs-plus", "emacs-plus@31");
    try p.installed("emacs-plus@30", try p.aliasPath("emacs-plus"));

    const where = p.entries();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], try described(a, "owner/tap/emacs-plus@30", "emacs-plus@30", false) } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("owner/tap/emacs-plus@30", &.{})});

    try testing.expectEqual(@as(usize, 1), got.astray.len);
    try testing.expectEqualStrings("owner/tap/emacs-plus@30", got.astray[0].id);
    try testing.expectEqualStrings(
        "installed through the alias \"owner/tap/emacs-plus\", which now names \"owner/tap/emacs-plus@31\", so brew upgrade and brew reinstall follow it to \"owner/tap/emacs-plus@31\", and fail while that cannot be loaded",
        got.astray[0].why,
    );
    // `brew reinstall` would follow the alias too, so the repair is an
    // uninstall and an install by the formula's own name.
    try testing.expectEqualStrings(
        "brew uninstall --formula --ignore-dependencies owner/tap/emacs-plus@30 && brew install --formula owner/tap/emacs-plus@30",
        got.astray[0].fix,
    );
}

test "astray: a formula is held by its own name, or by an alias that still names it" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    try p.alias("emacs-plus", "emacs-plus@31");
    try p.installed("emacs-plus@31", try p.aliasPath("emacs-plus"));
    try p.installed("emacs-plus@30", try p.formulaPath("emacs-plus@30"));
    // Installed from the API, which records no alias at all.
    try p.installed("ripgrep", "/Users/x/Library/Caches/Homebrew/api/formula.jws.json");

    var fake: exec.Fake = .{ .arena = a, .entries = &p.entries() };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{
        rowOf("owner/tap/emacs-plus@31", &.{}),
        rowOf("owner/tap/emacs-plus@30", &.{}),
        rowOf("ripgrep", &.{}),
    });
    try testing.expectEqual(@as(usize, 0), got.astray.len);
}

test "astray: an alias path that is no longer a tap's alias symlink binds nothing" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    // The tap dropped the alias: Homebrew follows only a path that is still
    // a symlink.
    try p.installed("gone", try p.aliasPath("gone-alias"));
    // A regular file where the alias was.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try p.aliasPath("plain"), .data = "" });
    try p.installed("plain-target", try p.aliasPath("plain"));
    // A symlink outside any tap's Aliases directory.
    const elsewhere = try std.fs.path.join(a, &.{ p.root, "elsewhere" });
    try Io.Dir.cwd().symLink(io, "Formula/other.rb", elsewhere, .{});
    try p.installed("outside", elsewhere);

    var fake: exec.Fake = .{ .arena = a, .entries = &p.entries() };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{
        rowOf("gone", &.{}),
        rowOf("plain-target", &.{}),
        rowOf("outside", &.{}),
        // No receipt at all: a keg brew cannot judge either.
        rowOf("no-receipt", &.{}),
    });
    try testing.expectEqual(@as(usize, 0), got.astray.len);
}

test "astray: a core alias is resolved by brew, not by a checkout that may be stale" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    // The local checkout still says python@3.13; the API, which brew
    // resolves a core alias through, says python@3.14.
    const core = try std.fs.path.join(a, &.{ p.root, "Library/Taps/homebrew/homebrew-core" });
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ core, "Aliases" }));
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ core, "Formula/p" }));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ core, "Formula/p/python@3.13.rb" }), .data = "" });
    const link = try std.fs.path.join(a, &.{ core, "Aliases", "python" });
    try Io.Dir.cwd().symLink(io, "../Formula/p/python@3.13.rb", link, .{});
    try p.installedWith("python@3.13", link, "homebrew/core", "stable", "[]");

    const where = p.entries();
    var fake: exec.Fake = .{
        .arena = a,
        .entries = &.{
            where[0],
            where[1],
            // Under the user's own environment: HOMEBREW_NO_INSTALL_FROM_API is
            // theirs to set, and decides what the alias names for them.
            .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- python", .stdout = "{\"formulae\":[{\"name\":\"python@3.14\",\"full_name\":\"python@3.14\"}]}" },
            try described(a, "python@3.13", "python@3.13", false),
        },
    };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("python@3.13", &.{})});
    try testing.expectEqual(@as(usize, 1), got.astray.len);
    try testing.expectEqualStrings(
        "installed through the alias \"python\", which now names \"python@3.14\", so brew upgrade and brew reinstall follow it to \"python@3.14\", and fail while that cannot be loaded",
        got.astray[0].why,
    );
}

test "astray: casks are never asked about, and brew is not called for them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No entries: any brew call fails the test.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    var b: Brew = .{ .runner = fake.runner(), .io = testing.io };
    const got = try b.backend().astray(a, &.{rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }})});
    try testing.expectEqual(@as(usize, 0), got.astray.len);
}

test "astray: a prefix brew cannot name is an error, never a clean answer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var failed: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew --prefix", .code = 1 },
    } };
    var b: Brew = .{ .runner = failed.runner(), .io = testing.io };
    try testing.expectError(error.BrewAnswerFailed, b.backend().astray(a, &.{rowOf("ripgrep", &.{})}));

    var garbled: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew --prefix", .stdout = "not a path\n" },
    } };
    var g: Brew = .{ .runner = garbled.runner(), .io = testing.io };
    try testing.expectError(error.BrewAnswerUnreadable, g.backend().astray(a, &.{rowOf("ripgrep", &.{})}));
}

test "astray: a receipt that is not JSON leaves that row unchecked, and the rest are judged" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    const dir = try std.fs.path.join(a, &.{ p.root, "opt", "ripgrep" });
    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "INSTALL_RECEIPT.json" }), .data = "{truncated" });

    // And beside it, a formula held astray: one row that cannot be judged
    // does not hide another that can.
    try p.alias("emacs-plus", "emacs-plus@31");
    try p.installed("emacs-plus@30", try p.aliasPath("emacs-plus"));

    const where = p.entries();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], try described(a, "owner/tap/emacs-plus@30", "emacs-plus@30", false) } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{ rowOf("ripgrep", &.{}), rowOf("owner/tap/emacs-plus@30", &.{}) });
    try testing.expectEqual(@as(usize, 1), got.astray.len);
    try testing.expectEqualStrings("owner/tap/emacs-plus@30", got.astray[0].id);
    try testing.expectEqual(@as(usize, 1), got.unchecked.len);
    try testing.expectEqualStrings("ripgrep", got.unchecked[0].id);
    // Named by path, so the receipt to look at is in the row.
    try testing.expect(std.mem.endsWith(u8, got.unchecked[0].why, "opt/ripgrep/INSTALL_RECEIPT.json could not be read: it is not JSON"));
}

test "astray: the repair installs as the receipt says, HEAD and build options included" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    try p.alias("emacs-plus", "emacs-plus@31");
    try p.installedWith("emacs-plus@30", try p.aliasPath("emacs-plus"), "owner/tap", "head", "[\"--with-native-comp\",\"--with-icon=a b\"]");

    const where = p.entries();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], try described(a, "owner/tap/emacs-plus@30", "emacs-plus@30", false) } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("owner/tap/emacs-plus@30", &.{})});
    try testing.expectEqual(@as(usize, 1), got.astray.len);
    // What `brew reinstall` would have kept, and a shell reads each option as
    // one word.
    try testing.expectEqualStrings(
        "brew uninstall --formula --ignore-dependencies owner/tap/emacs-plus@30 && brew install --formula --HEAD --with-native-comp '--with-icon=a b' owner/tap/emacs-plus@30",
        got.astray[0].fix,
    );
}

test "astray: an alias in a tap of another brew is not one this brew follows" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    const other = try std.fs.path.join(a, &.{ p.root, "other-brew/Library/Taps/owner/homebrew-tap/Aliases" });
    try Io.Dir.cwd().createDirPath(io, other);
    const link = try std.fs.path.join(a, &.{ other, "emacs-plus" });
    try Io.Dir.cwd().symLink(io, "../Formula/emacs-plus@31.rb", link, .{});
    try p.installed("emacs-plus@30", link);

    var fake: exec.Fake = .{ .arena = a, .entries = &p.entries() };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("owner/tap/emacs-plus@30", &.{})});
    try testing.expectEqual(@as(usize, 0), got.astray.len);
}

test "writeShellWord: a word with nothing a shell reads stays bare, anything else is quoted whole" {
    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    for ([_][]const u8{ "--with-x", "a b", "it's", "" }) |word| {
        try writeShellWord(&w.writer, word);
        try w.writer.writeByte('|');
    }
    try testing.expectEqualStrings("--with-x|'a b'|'it'\\''s'|''|", w.written());
}

test "astray: an alias is named by the formula's tap, whatever the row spells" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    try p.alias("emacs-plus", "emacs-plus@31");
    try p.installed("emacs-plus@30", try p.aliasPath("emacs-plus"));

    const where = p.entries();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], try described(a, "emacs-plus@30", "emacs-plus@30", false) } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("emacs-plus@30", &.{})});
    try testing.expectEqual(@as(usize, 1), got.astray.len);
    try testing.expect(std.mem.startsWith(u8, got.astray[0].why, "installed through the alias \"owner/tap/emacs-plus\", which now names \"owner/tap/emacs-plus@31\""));
}

test "astray: a brew with no way to read files is an error, never a clean answer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    var b: Brew = .{ .runner = fake.runner() };
    try testing.expectError(error.NoIo, b.backend().astray(a, &.{rowOf("ripgrep", &.{})}));
}

test "astray: a core alias brew cannot resolve leaves that row unchecked, never clean" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    const core = try std.fs.path.join(a, &.{ p.root, "Library/Taps/homebrew/homebrew-core" });
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ core, "Aliases" }));
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ core, "Formula/p" }));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ core, "Formula/p/python@3.13.rb" }), .data = "" });
    const link = try std.fs.path.join(a, &.{ core, "Aliases", "python" });
    try Io.Dir.cwd().symLink(io, "../Formula/p/python@3.13.rb", link, .{});
    try p.installedWith("python@3.13", link, "homebrew/core", "stable", "[]");

    const info = "env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- python";
    const where = p.entries();
    for ([_]exec.Fake.Entry{
        .{ .argv = info, .code = 1 },
        .{ .argv = info, .stdout = "not json" },
        .{ .argv = info, .stdout = "{\"formulae\":[]}" },
    }, [_][]const u8{
        "brew could not say what the alias \"python\" names now: brew exited nonzero answering what mox asked, saying why above",
        "brew could not say what the alias \"python\" names now: brew answered in a shape mox could not read",
        "brew could not say what the alias \"python\" names now: brew answered in a shape mox could not read",
    }) |answer, want| {
        var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], answer } };
        var b: Brew = .{ .runner = fake.runner(), .io = io };
        const got = try b.backend().astray(a, &.{rowOf("python@3.13", &.{})});
        try testing.expectEqual(@as(usize, 0), got.astray.len);
        try testing.expectEqual(@as(usize, 1), got.unchecked.len);
        try testing.expectEqualStrings("python@3.13", got.unchecked[0].id);
        try testing.expectEqualStrings(want, got.unchecked[0].why);
    }

    // And brew answering with the formula itself is an alias that still
    // names it.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], .{ .argv = info, .stdout = "{\"formulae\":[{\"name\":\"python@3.13\"}]}" } } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const held = try b.backend().astray(a, &.{rowOf("python@3.13", &.{})});
    try testing.expectEqual(@as(usize, 0), held.astray.len);
    try testing.expectEqual(@as(usize, 0), held.unchecked.len);
}

test "astray: an official tap other than core is resolved by its symlink and named qualified" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    const tap = try std.fs.path.join(a, &.{ p.root, "Library/Taps/homebrew/homebrew-foo" });
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ tap, "Aliases" }));
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ tap, "Formula" }));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ tap, "Formula/bar@2.rb" }), .data = "" });
    const link = try std.fs.path.join(a, &.{ tap, "Aliases", "bar" });
    try Io.Dir.cwd().symLink(io, "../Formula/bar@2.rb", link, .{});
    try p.installedWith("bar@1", link, "homebrew/foo", "stable", "[]");

    // `brew info` only for the formula itself, never for the alias: the
    // Fake fails on any call it was not given.
    const where = p.entries();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], try described(a, "homebrew/foo/bar@1", "bar@1", false) } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("homebrew/foo/bar@1", &.{})});
    try testing.expectEqual(@as(usize, 1), got.astray.len);
    try testing.expect(std.mem.startsWith(u8, got.astray[0].why, "installed through the alias \"homebrew/foo/bar\", which now names \"homebrew/foo/bar@2\""));
}

test "astray: a symlink outside a tap's Aliases directory binds nothing" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    // A symlink in the tap's Formula directory.
    const in_formula = try p.formulaPath("shim");
    try Io.Dir.cwd().symLink(io, "other.rb", in_formula, .{});
    try p.installed("shim-target", in_formula);

    var fake: exec.Fake = .{ .arena = a, .entries = &p.entries() };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("shim-target", &.{})});
    try testing.expectEqual(@as(usize, 0), got.astray.len);
    try testing.expectEqual(@as(usize, 0), got.unchecked.len);
}

test "astray: an alias that names nothing Homebrew can load is astray, its upgrade failing" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    // Still a symlink, so Homebrew follows it (`installed_alias_path`), but
    // to a formula file the tap no longer has, which it cannot load.
    const dangling = try p.aliasPath("gone");
    try Io.Dir.cwd().symLink(io, "../Formula/gone@2.rb", dangling, .{});
    try p.installed("gone@1", dangling);

    const where = p.entries();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], try described(a, "owner/tap/gone@1", "gone@1", false) } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("owner/tap/gone@1", &.{})});
    try testing.expectEqual(@as(usize, 1), got.astray.len);
    try testing.expectEqualStrings(
        "installed through the alias \"owner/tap/gone\", which names no formula brew can load now, so brew upgrade and brew outdated fail loading it",
        got.astray[0].why,
    );
    try testing.expectEqualStrings(
        "brew uninstall --formula --ignore-dependencies owner/tap/gone@1 && brew install --formula owner/tap/gone@1",
        got.astray[0].fix,
    );
}

test "astray: a formula renamed since it was installed, its alias moving with it, is held" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    // The keg keeps the old name; Homebrew loads it as the new one and
    // compares the alias's target with that.
    try p.alias("thing", "newname");
    try p.installed("oldname", try p.aliasPath("thing"));

    const where = p.entries();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], try described(a, "owner/tap/oldname", "newname", false) } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("owner/tap/oldname", &.{})});
    try testing.expectEqual(@as(usize, 0), got.astray.len);
    try testing.expectEqual(@as(usize, 0), got.unchecked.len);
}

test "astray: a disabled formula brew install refuses is repaired by naming the alias's target" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    try p.alias("emacs-plus", "emacs-plus@31");
    try p.installed("emacs-plus@30", try p.aliasPath("emacs-plus"));

    const where = p.entries();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], try described(a, "owner/tap/emacs-plus@30", "emacs-plus@30", true) } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("owner/tap/emacs-plus@30", &.{})});
    try testing.expectEqual(@as(usize, 1), got.astray.len);
    // Uninstalling first would leave nothing installed: the reinstall fails.
    try testing.expectEqualStrings(
        "brew install refuses \"owner/tap/emacs-plus@30\", which is disabled, so declare \"owner/tap/emacs-plus@31\" in its place, then run brew uninstall --formula owner/tap/emacs-plus@30 && mox apply",
        got.astray[0].fix,
    );
}

test "astray: a formula brew cannot describe leaves that row unchecked" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    try p.alias("emacs-plus", "emacs-plus@31");
    try p.installed("emacs-plus@30", try p.aliasPath("emacs-plus"));

    const where = p.entries();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 brew info --json=v2 --formula -- owner/tap/emacs-plus@30", .code = 1 } } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("owner/tap/emacs-plus@30", &.{})});
    try testing.expectEqual(@as(usize, 0), got.astray.len);
    try testing.expectEqual(@as(usize, 1), got.unchecked.len);
    try testing.expectEqualStrings(
        "brew could not describe it, to tell a moved alias from a renamed formula: brew exited nonzero answering what mox asked, saying why above",
        got.unchecked[0].why,
    );
}

test "astray: the receipt is read from the linked keg before the opt-linked one" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    // opt says installed by its own name; the keg brew links says through
    // the alias, and that one is what Homebrew reads (`Keg.from_rack`).
    try p.alias("emacs-plus", "emacs-plus@31");
    try p.installed("emacs-plus@30", try p.formulaPath("emacs-plus@30"));
    const linked = try std.fs.path.join(a, &.{ p.root, "var/homebrew/linked/emacs-plus@30" });
    try Io.Dir.cwd().createDirPath(io, linked);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(a, &.{ linked, "INSTALL_RECEIPT.json" }),
        .data = try std.fmt.allocPrint(a, "{{\"source\":{{\"tap\":\"owner/tap\",\"path\":\"{s}\",\"spec\":\"stable\"}}}}", .{try p.aliasPath("emacs-plus")}),
    });

    const where = p.entries();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], try described(a, "owner/tap/emacs-plus@30", "emacs-plus@30", false) } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("owner/tap/emacs-plus@30", &.{})});
    try testing.expectEqual(@as(usize, 1), got.astray.len);
}

test "astray: the alias is looked up in the formula's own tap, not the tap its path names" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    // Recorded through another tap's alias, which still names the formula;
    // the receipt's own tap has an alias of that name that moved.
    const other = try std.fs.path.join(a, &.{ p.root, "Library/Taps/other/homebrew-x" });
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ other, "Aliases" }));
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ other, "Formula" }));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ other, "Formula/emacs-plus@30.rb" }), .data = "" });
    const recorded = try std.fs.path.join(a, &.{ other, "Aliases", "emacs-plus" });
    try Io.Dir.cwd().symLink(io, "../Formula/emacs-plus@30.rb", recorded, .{});
    try p.alias("emacs-plus", "emacs-plus@31");
    try p.installed("emacs-plus@30", recorded);

    const where = p.entries();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], try described(a, "owner/tap/emacs-plus@30", "emacs-plus@30", false) } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("owner/tap/emacs-plus@30", &.{})});
    try testing.expectEqual(@as(usize, 1), got.astray.len);
    try testing.expect(std.mem.startsWith(u8, got.astray[0].why, "installed through the alias \"owner/tap/emacs-plus\", which now names \"owner/tap/emacs-plus@31\""));
}

test "astray: an alias is resolved one level, as Homebrew's alias table resolves it" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    // The alias names b.rb, itself a symlink to c.rb: Homebrew sees `b`.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try p.formulaPath("c"), .data = "" });
    try Io.Dir.cwd().symLink(io, "c.rb", try p.formulaPath("b"), .{});
    try Io.Dir.cwd().symLink(io, "../Formula/b.rb", try p.aliasPath("a"), .{});
    try p.installed("b", try p.aliasPath("a"));

    var fake: exec.Fake = .{ .arena = a, .entries = &p.entries() };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("owner/tap/b", &.{})});
    try testing.expectEqual(@as(usize, 0), got.astray.len);
    try testing.expectEqual(@as(usize, 0), got.unchecked.len);
}

test "astray: an alias the tap dropped for a formula of that name follows the formula" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);

    // Recorded through another tap's alias; the receipt's tap has no alias
    // `emacs-plus` but a formula `emacs-plus`, which Homebrew loads instead.
    const other = try std.fs.path.join(a, &.{ p.root, "Library/Taps/other/homebrew-x" });
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ other, "Aliases" }));
    const recorded = try std.fs.path.join(a, &.{ other, "Aliases", "emacs-plus" });
    try Io.Dir.cwd().symLink(io, "../Formula/emacs-plus@30.rb", recorded, .{});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try p.formulaPath("emacs-plus"), .data = "" });
    // The receipt spells its tap in capitals; the checkout is lowercase.
    try p.installedWith("emacs-plus@30", recorded, "Owner/Tap", "stable", "[]");

    const where = p.entries();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{ where[0], where[1], try described(a, "owner/tap/emacs-plus@30", "emacs-plus@30", false) } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{rowOf("owner/tap/emacs-plus@30", &.{})});
    try testing.expectEqual(@as(usize, 0), got.unchecked.len);
    try testing.expectEqual(@as(usize, 1), got.astray.len);
    // Named as Homebrew names a tap: lowercase.
    try testing.expect(std.mem.indexOf(u8, got.astray[0].why, "which now names \"owner/tap/emacs-plus\"") != null);
}

test "astray: a dropped alias loads as the tap has the name otherwise: renamed, sharded, migrated" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try Prefix.init(a, io, &tmp);
    const tap = try std.fs.path.join(a, &.{ p.root, Prefix.tap_dir });

    // Each recorded through an alias nested below Aliases, which Homebrew
    // follows by its basename, and which the tap has no top-level alias for.
    const nested = try std.fs.path.join(a, &.{ tap, "Aliases", "sub" });
    try Io.Dir.cwd().createDirPath(io, nested);
    for ([_][]const u8{ "renamed", "sharded", "moved" }) |alias| {
        try Io.Dir.cwd().symLink(io, "../../Formula/x.rb", try std.fs.path.join(a, &.{ nested, alias }), .{});
    }
    try p.installed("renamed@1", try std.fs.path.join(a, &.{ nested, "renamed" }));
    try p.installed("sharded@1", try std.fs.path.join(a, &.{ nested, "sharded" }));
    try p.installed("moved@1", try std.fs.path.join(a, &.{ nested, "moved" }));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ tap, "formula_renames.json" }), .data = "{\"renamed\":\"renamed@2\"}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ tap, "tap_migrations.json" }), .data = "{\"moved\":\"other/tap\"}" });
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ tap, "Formula", "s" }));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ tap, "Formula", "s", "sharded.rb" }), .data = "" });

    const where = p.entries();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        where[0],
        where[1],
        try described(a, "owner/tap/renamed@1", "renamed@1", false),
        try described(a, "owner/tap/sharded@1", "sharded@1", false),
    } };
    var b: Brew = .{ .runner = fake.runner(), .io = io };
    const got = try b.backend().astray(a, &.{ rowOf("owner/tap/renamed@1", &.{}), rowOf("owner/tap/sharded@1", &.{}), rowOf("owner/tap/moved@1", &.{}) });
    try testing.expectEqual(@as(usize, 2), got.astray.len);
    try testing.expect(std.mem.indexOf(u8, got.astray[0].why, "which now names \"owner/tap/renamed@2\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.astray[1].why, "which now names \"owner/tap/sharded\"") != null);
    try testing.expectEqual(@as(usize, 1), got.unchecked.len);
    try testing.expectEqualStrings("owner/tap/moved@1", got.unchecked[0].id);
    try testing.expect(std.mem.indexOf(u8, got.unchecked[0].why, "moves that name to \"other/tap\", which mox does not follow") != null);
}

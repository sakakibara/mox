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

const std = @import("std");
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
    /// Only the bootstrap path needs these: staging a verified installer.
    io: ?std.Io = null,
    scratch_dir: []const u8 = "",
    /// How brew is invoked. `brew` until a bootstrap installs it, then the
    /// absolute path it landed at: a child's PATH is never used to resolve
    /// argv[0] (only the parent's is), so a freshly installed brew that is on
    /// no PATH yet can only be reached by name of its full path.
    exe: []const u8 = "brew",
    /// Where the installer leaves `brew`; probed after a bootstrap.
    prefixes: []const []const u8 = &default_prefixes,
    /// Whether the last `install` ran `brew install`, which `installSpawned`
    /// answers with: a tap or a trust that fails stops the row before it, and
    /// a batch of one such row never reaches brew's installer at all.
    spawned: bool = false,
    /// How many of the last `install`'s rows brew was never handed, which
    /// `installRefused` answers with.
    refused: usize = 0,
    /// Where a row refused at install time is said. The install's own error
    /// is what the call site reports, so the row and the name to write in its
    /// place have nowhere else to go.
    err: ?*Io.Writer = null,

    pub fn backend(self: *Brew) Backend {
        return .{
            .name = "brew",
            .ctx = self,
            .vtable = &vtable,
            .limitation = cask_limitation,
            .install_check = "the formula and cask names brew resolves a row to",
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
        .bootstrap = bootstrapImpl,
    };

    /// Homebrew is not there on a fresh mac, so its own installer puts it
    /// there, from a file mox has already fetched and verified.
    /// `NONINTERACTIVE` because `mox apply` is: the installer otherwise stops
    /// to ask for a keypress no unattended run can give it. The bin dir it
    /// installed into comes back so this same run can use it: on a fresh
    /// machine it is on no PATH yet.
    fn bootstrapImpl(ctx: *anyopaque, arena: std.mem.Allocator, installer_path: []const u8) anyerror!?[]const u8 {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        const io = self.io orelse return error.NoBootstrapForBackend;

        const res = try self.runner.stream(arena, &.{ "env", "NONINTERACTIVE=1", "/bin/bash", installer_path });
        try exec.checkTimedOut(res);
        if (!res.ok) return bootstrap_mod.Error.BootstrapFailed;

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
    fn availableImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!Backend.Availability {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        return Backend.probeAvailability(try std.fmt.allocPrint(arena, "{s} --version", .{self.exe}), self.runner.run(arena, &.{ self.exe, "--version" }));
    }

    /// `brew list` refreshes the formula and cask API data when the cached
    /// copy is older than a week; under this it never refreshes on that
    /// timer, so a read-only `mox status` does not go to the network for
    /// age alone. A cache that does not exist yet is still populated, once.
    /// Through `env` because an adapter has no environment of its own.
    const query_env = [_][]const u8{ "env", "HOMEBREW_NO_AUTO_UPDATE=1" };

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

    /// One `brew install` per row, every row attempted: a formula that fails
    /// halfway down the list must not leave the ones after it uninstalled.
    /// The batch then fails as a whole if any row did.
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
        const keep = try self.refuseAliases(arena, rows);
        self.refused = rows.len - keep.len;
        var failed = false;
        for (keep) |row| {
            const kind = try kindOf(row);
            if (tapOf(row.name)) |tap| {
                const tapped = try self.runner.stream(arena, &.{ self.exe, "tap", "--", tap });
                try exec.checkTimedOut(tapped);
                if (!tapped.ok) {
                    failed = true;
                    continue;
                }
                // Trust the one thing named, never the whole tap: an
                // untrusted third-party tap is ignored outright since
                // Homebrew 6.0, and whole-tap trust would extend to every
                // formula and cask it ever adds. brew keeps the two target
                // kinds apart, so a cask trusted as a formula is recorded in
                // the wrong namespace and stays untrusted.
                const flag: []const u8 = switch (kind) {
                    .formula => "--formula",
                    .cask => "--cask",
                };
                const trusted = try self.runner.stream(arena, &.{ self.exe, "trust", flag, "--", row.name });
                try exec.checkTimedOut(trusted);
                if (!trusted.ok) {
                    failed = true;
                    continue;
                }
            }
            self.spawned = true;
            const res = switch (kind) {
                .formula => try self.runner.stream(arena, &.{ self.exe, "install", "--", row.name }),
                .cask => try self.runner.stream(arena, &.{ self.exe, "install", "--cask", "--", row.name }),
            };
            try exec.checkTimedOut(res);
            if (!res.ok) failed = true;
        }
        if (failed) return error.BrewInstallFailed;
    }

    fn installSpawnedImpl(ctx: *anyopaque) bool {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        return self.spawned;
    }

    fn installRefusedImpl(ctx: *anyopaque) usize {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        return self.refused;
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
    fn refuseAliases(self: *Brew, arena: std.mem.Allocator, rows: []const Row) anyerror![]const Row {
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
                try self.resolveNames(arena, kind, rows, &resolved[slot]);
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
        const res = try self.runner.run(arena, argv.items);
        try exec.checkTimedOut(res);
        if (res.ok) {
            try recordAnswers(arena, kind, res.stdout, into);
            return;
        }
        if (names.items.len == 1) return;

        for (names.items) |name| {
            var one: std.ArrayList([]const u8) = .empty;
            try one.appendSlice(arena, &head);
            try one.append(arena, name);
            const got = try self.runner.run(arena, one.items);
            try exec.checkTimedOut(got);
            if (!got.ok) continue;
            try recordAnswers(arena, kind, got.stdout, into);
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
fn recordAnswers(
    arena: std.mem.Allocator,
    kind: Kind,
    stdout: []const u8,
    into: *std.StringHashMap([]const u8),
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
            .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew list --full-name --installed-on-request",
            .stdout = "ripgrep\nd12frosted/emacs-plus/emacs-plus@30\n",
        },
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask --full-name", .stdout = "ghostty\n1password\n" },
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
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew list --full-name --installed-on-request", .stdout = "" },
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask --full-name", .stdout = "ghostty\n" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    const got = try b.backend().installedExplicit(a);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expect(!fake.called("env HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask --full-name --installed-on-request"));
}

test "installedExplicit: a failed query is an error, never an empty set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An empty list would read as "nothing installed" and make every desired
    // package look missing.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew list --full-name --installed-on-request", .code = 1 },
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
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "brew tap -- owner/tap" },
        .{ .argv = "brew trust --cask -- owner/tap/somecask" },
        .{ .argv = "brew install --cask -- owner/tap/somecask" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    // The Fake errors on any unscripted command, so `--formula` here fails.
    try b.backend().install(a, &.{rowOf("owner/tap/somecask", &.{.{ .key = "kind", .value = .{ .string = "cask" } }})});
    try testing.expect(fake.called("brew trust --cask -- owner/tap/somecask"));
}

test "install: a tapped formula is tapped and trusted narrowly before installing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "brew tap -- d12frosted/emacs-plus" },
        .{ .argv = "brew trust --formula -- d12frosted/emacs-plus/emacs-plus@30" },
        .{ .argv = "brew install -- d12frosted/emacs-plus/emacs-plus@30" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try b.backend().install(a, &.{rowOf("d12frosted/emacs-plus/emacs-plus@30", &.{})});
    try testing.expect(fake.called("brew tap -- d12frosted/emacs-plus"));
    try testing.expect(fake.called("brew trust --formula -- d12frosted/emacs-plus/emacs-plus@30"));
    try testing.expect(fake.called("brew install -- d12frosted/emacs-plus/emacs-plus@30"));
}

test "install: a core formula is neither tapped nor trusted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "brew install -- ripgrep" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    // The Fake errors on any command it was not scripted for, so a stray tap
    // or trust here would fail the test rather than pass unnoticed.
    try b.backend().install(a, &.{rowOf("ripgrep", &.{})});
    try testing.expect(fake.called("brew install -- ripgrep"));
}

test "install: a cask installs through --cask" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "brew install --cask -- ghostty" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try b.backend().install(a, &.{rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }})});
    try testing.expect(fake.called("brew install --cask -- ghostty"));
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
        .{ .argv = "env NONINTERACTIVE=1 /bin/bash /tmp/i" },
    } };
    var b: Brew = .{ .runner = fake.runner(), .io = io, .scratch_dir = "/tmp" };
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
        .{ .argv = "env NONINTERACTIVE=1 /bin/bash /tmp/i", .timed_out = true },
    } };
    var b: Brew = .{ .runner = fake.runner(), .io = std.testing.io, .scratch_dir = "/tmp" };

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
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "brew tap -- owner/tap", .code = 1 },
        .{ .argv = "brew install -- ripgrep" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{
        rowOf("owner/tap/thing", &.{}),
        rowOf("ripgrep", &.{}),
    }));
    try testing.expect(fake.called("brew install -- ripgrep"));
}

test "install: a failed trust fails its row and the rows after it still run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "brew tap -- owner/tap" },
        .{ .argv = "brew trust --cask -- owner/tap/somecask", .code = 1 },
        .{ .argv = "brew install --cask -- ghostty" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{
        rowOf("owner/tap/somecask", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}),
        rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}),
    }));
    try testing.expect(!fake.called("brew install --cask -- owner/tap/somecask"));
    try testing.expect(fake.called("brew install --cask -- ghostty"));
}

test "install: a failed install is an error, not a silent skip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "brew install -- ripgrep", .code = 1 },
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
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "brew tap -- owner/tap" },
        .{ .argv = "brew trust --formula -- owner/tap/thing" },
        .{ .argv = "brew install -- owner/tap/thing" },
        .{ .argv = "brew install -- ripgrep" },
        .{ .argv = "brew install --cask -- ghostty" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try b.backend().install(a, &.{
        rowOf("owner/tap/thing", &.{}),
        rowOf("ripgrep", &.{}),
        rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}),
    });
    for (fake.calls.items) |c| {
        try testing.expect(std.mem.indexOf(u8, c, " -- ") != null);
    }
}

test "install: whether brew's installer ran is what says the rows may have landed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A tap that fails stops its row before any install, so a batch of that
    // one row reached brew's installer not at all and nothing can have
    // landed.
    var tap: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "brew tap -- owner/tap", .code = 1 },
    } };
    var b1: Brew = .{ .runner = tap.runner() };
    try testing.expectError(error.BrewInstallFailed, b1.backend().install(a, &.{rowOf("owner/tap/thing", &.{})}));
    try testing.expect(!b1.backend().installSpawned());

    // An install that ran and failed is the other answer.
    var ran: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "brew install -- ripgrep", .code = 1 },
    } };
    var b2: Brew = .{ .runner = ran.runner() };
    try testing.expectError(error.BrewInstallFailed, b2.backend().install(a, &.{rowOf("ripgrep", &.{})}));
    try testing.expect(b2.backend().installSpawned());

    // And the answer is the last batch's, never the one before it.
    var tap2: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 ", .match = .prefix, .code = 1 },
        .{ .argv = "brew tap -- owner/tap", .code = 1 },
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
        .{
            .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --formula -- ag ripgrep",
            .stdout =
            \\{"formulae":[{"full_name":"the_silver_searcher","aliases":["ag"],"oldnames":[]},{"full_name":"ripgrep","aliases":[],"oldnames":[]}],"casks":[]}
            ,
        },
        .{ .argv = "brew install -- ripgrep" },
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
    try testing.expect(!fake.called("brew install -- ag"));
    try testing.expect(fake.called("brew install -- ripgrep"));
}

test "install: a cask's old token is refused the same way, and asks only about casks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{
            .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --cask -- oldghost",
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
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --formula -- nosuchthing", .code = 1 },
        .{ .argv = "brew install -- nosuchthing", .code = 1 },
    } };
    var w: std.Io.Writer.Allocating = .init(a);
    var b: Brew = .{ .runner = fake.runner(), .err = &w.writer };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{rowOf("nosuchthing", &.{})}));
    try testing.expectEqual(@as(usize, 0), b.backend().installRefused());
    try testing.expect(fake.called("brew install -- nosuchthing"));
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
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --formula -- d12frosted/emacs-plus/emacs-plus@30", .code = 1 },
        .{ .argv = "brew tap -- d12frosted/emacs-plus" },
        .{ .argv = "brew trust --formula -- d12frosted/emacs-plus/emacs-plus@30" },
        .{ .argv = "brew install -- d12frosted/emacs-plus/emacs-plus@30" },
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
        .{
            .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --formula -- homebrew/core/ripgrep",
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
    try testing.expect(!fake.called("brew tap -- homebrew/core"));
    try testing.expect(!fake.called("brew install -- homebrew/core/ripgrep"));
}

test "install: a row qualifying a third-party tap is kept, brew reporting it qualified" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Proved read-only against Homebrew 7.0.2 with that tap present: the
    // answer carries `"full_name": "d12frosted/emacs-plus/emacs-plus@30"`,
    // which is the row's own spelling, so nothing is refused.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{
            .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --formula -- d12frosted/emacs-plus/emacs-plus@30",
            .stdout =
            \\{"formulae":[{"full_name":"d12frosted/emacs-plus/emacs-plus@30","name":"emacs-plus@30","tap":"d12frosted/emacs-plus","aliases":[],"oldnames":[]}],"casks":[]}
            ,
        },
        .{ .argv = "brew tap -- d12frosted/emacs-plus" },
        .{ .argv = "brew trust --formula -- d12frosted/emacs-plus/emacs-plus@30" },
        .{ .argv = "brew install -- d12frosted/emacs-plus/emacs-plus@30" },
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
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --formula -- ag zzz-removed-formula", .code = 1 },
        .{
            .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --formula -- ag",
            .stdout =
            \\{"formulae":[{"full_name":"the_silver_searcher","name":"the_silver_searcher","tap":"homebrew/core","aliases":["ag"],"oldnames":[]}],"casks":[]}
            ,
        },
        .{ .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --formula -- zzz-removed-formula", .code = 1 },
        .{ .argv = "brew install -- zzz-removed-formula", .code = 1 },
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
    try testing.expect(!fake.called("brew install -- ag"));
    try testing.expect(fake.called("brew install -- zzz-removed-formula"));
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
        .{
            .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --formula -- docker",
            .stdout =
            \\{"formulae":[{"full_name":"docker","name":"docker","tap":"homebrew/core","aliases":[],"oldnames":[]}],"casks":[]}
            ,
        },
        .{
            .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --cask -- docker",
            .stdout =
            \\{"formulae":[],"casks":[{"token":"docker-desktop","full_token":"docker-desktop","tap":"homebrew/cask","old_tokens":["docker"]}]}
            ,
        },
        .{ .argv = "brew install -- docker" },
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
    try testing.expect(fake.called("brew install -- docker"));
    try testing.expect(!fake.called("brew install --cask -- docker"));
}

test "install: a cask row and a formula row of one name each get their own answer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The mirror case, and the one that proves the fix is not an ordering
    // accident: `dash` is a canonical CASK token and an old name of the
    // formula `dash-shell`, both verified read-only against Homebrew 7.0.2.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{
            .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --cask -- dash",
            .stdout =
            \\{"formulae":[],"casks":[{"token":"dash","full_token":"dash","tap":"homebrew/cask","old_tokens":[]}]}
            ,
        },
        .{
            .argv = "env HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --formula -- dash",
            .stdout =
            \\{"formulae":[{"full_name":"dash-shell","name":"dash-shell","tap":"homebrew/core","aliases":[],"oldnames":["dash"]}],"casks":[]}
            ,
        },
        .{ .argv = "brew install --cask -- dash" },
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
    try testing.expect(fake.called("brew install --cask -- dash"));
    try testing.expect(!fake.called("brew install -- dash"));
}

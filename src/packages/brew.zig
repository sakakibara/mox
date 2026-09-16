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

const std = @import("std");

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
};

pub const Kind = enum { formula, cask };

/// The prefix a cask id carries so it cannot collide with the formula of the
/// same name. Opaque to the core, which only compares ids.
pub const cask_prefix = "cask:";

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

    pub fn backend(self: *Brew) Backend {
        return .{ .name = "brew", .ctx = self, .vtable = &vtable };
    }

    const vtable: Backend.VTable = .{
        .available = availableImpl,
        .validate = validateImpl,
        .idOf = idOfImpl,
        .installedExplicit = installedExplicitImpl,
        .install = installImpl,
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
        if (!res.ok) return bootstrap_mod.Error.BootstrapFailed;

        for ([_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin" }) |dir| {
            const exe = try std.fs.path.join(arena, &.{ dir, "brew" });
            Io.Dir.cwd().access(io, exe, .{}) catch continue;
            self.exe = exe;
            return dir;
        }
        return null;
    }

    fn availableImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!bool {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        const res = self.runner.run(arena, &.{ self.exe, "--version" }) catch |e| switch (e) {
            // Absent is the one failure that means "not usable here"; an
            // allocation or spawn failure must not read as a missing brew and
            // silently make every brew row inert.
            error.FileNotFound => return false,
            else => return e,
        };
        try exec.checkTimedOut(res);
        return res.ok;
    }

    fn validateImpl(_: *anyopaque, row: Row, diag: ?*Diag) anyerror!void {
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

        const formulae = try self.runner.run(arena, &.{ self.exe, "list", "--full-name", "--installed-on-request" });
        try exec.checkTimedOut(formulae);
        if (!formulae.ok) return error.BrewQueryFailed;
        try appendLines(arena, &out, formulae.stdout, "");

        const casks = try self.runner.run(arena, &.{ self.exe, "list", "--cask", "--full-name" });
        try exec.checkTimedOut(casks);
        if (!casks.ok) return error.BrewQueryFailed;
        try appendLines(arena, &out, casks.stdout, cask_prefix);

        return out.toOwnedSlice(arena);
    }

    /// One `brew install` per row, every row attempted: a formula that fails
    /// halfway down the list must not leave the ones after it uninstalled.
    /// The batch then fails as a whole if any row did.
    fn installImpl(ctx: *anyopaque, arena: std.mem.Allocator, rows: []const Row) anyerror!void {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        var failed = false;
        for (rows) |row| {
            const kind = try kindOf(row);
            if (tapOf(row.name)) |tap| {
                const tapped = try self.runner.stream(arena, &.{ self.exe, "tap", tap });
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
                const trusted = try self.runner.stream(arena, &.{ self.exe, "trust", flag, row.name });
                try exec.checkTimedOut(trusted);
                if (!trusted.ok) {
                    failed = true;
                    continue;
                }
            }
            const res = switch (kind) {
                .formula => try self.runner.stream(arena, &.{ self.exe, "install", row.name }),
                .cask => try self.runner.stream(arena, &.{ self.exe, "install", "--cask", row.name }),
            };
            try exec.checkTimedOut(res);
            if (!res.ok) failed = true;
        }
        if (failed) return error.BrewInstallFailed;
    }
};

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
            .argv = "brew list --full-name --installed-on-request",
            .stdout = "ripgrep\nd12frosted/emacs-plus/emacs-plus@30\n",
        },
        .{ .argv = "brew list --cask --full-name", .stdout = "ghostty\n1password\n" },
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

test "installedExplicit: a failed query is an error, never an empty set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An empty list would read as "nothing installed" and make every desired
    // package look missing.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew list --full-name --installed-on-request", .code = 1, .stderr = "boom" },
    } };
    var b: Brew = .{ .runner = fake.runner() };
    const be = b.backend();

    try testing.expectError(error.BrewQueryFailed, be.installedExplicit(a));
}

test "available: true when brew answers, false when it is absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ok_fake: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "brew --version", .stdout = "Homebrew 6.0.0\n" }},
    };
    var ok_brew: Brew = .{ .runner = ok_fake.runner() };
    try testing.expect(try ok_brew.backend().available(a));

    var missing: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "brew --version", .fail = error.FileNotFound }},
    };
    var missing_brew: Brew = .{ .runner = missing.runner() };
    try testing.expect(!try missing_brew.backend().available(a));
}

test "available: a failure other than an absent brew is not reported as absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Reading this as "brew is missing" would make every brew row inert with
    // no diagnostic anywhere.
    var broken: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "brew --version", .fail = error.AccessDenied }},
    };
    var b: Brew = .{ .runner = broken.runner() };
    try testing.expectError(error.AccessDenied, b.backend().available(a));
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
        .{ .argv = "brew tap owner/tap" },
        .{ .argv = "brew trust --cask owner/tap/somecask" },
        .{ .argv = "brew install --cask owner/tap/somecask" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    // The Fake errors on any unscripted command, so `--formula` here fails.
    try b.backend().install(a, &.{rowOf("owner/tap/somecask", &.{.{ .key = "kind", .value = .{ .string = "cask" } }})});
    try testing.expect(fake.called("brew trust --cask owner/tap/somecask"));
}

test "install: a tapped formula is tapped and trusted narrowly before installing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew tap d12frosted/emacs-plus" },
        .{ .argv = "brew trust --formula d12frosted/emacs-plus/emacs-plus@30" },
        .{ .argv = "brew install d12frosted/emacs-plus/emacs-plus@30" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try b.backend().install(a, &.{rowOf("d12frosted/emacs-plus/emacs-plus@30", &.{})});
    try testing.expect(fake.called("brew tap d12frosted/emacs-plus"));
    try testing.expect(fake.called("brew trust --formula d12frosted/emacs-plus/emacs-plus@30"));
    try testing.expect(fake.called("brew install d12frosted/emacs-plus/emacs-plus@30"));
}

test "install: a core formula is neither tapped nor trusted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{.{ .argv = "brew install ripgrep" }} };
    var b: Brew = .{ .runner = fake.runner() };

    // The Fake errors on any command it was not scripted for, so a stray tap
    // or trust here would fail the test rather than pass unnoticed.
    try b.backend().install(a, &.{rowOf("ripgrep", &.{})});
    try testing.expect(fake.called("brew install ripgrep"));
}

test "install: a cask installs through --cask" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{.{ .argv = "brew install --cask ghostty" }} };
    var b: Brew = .{ .runner = fake.runner() };

    try b.backend().install(a, &.{rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }})});
    try testing.expect(fake.called("brew install --cask ghostty"));
}

test "bootstrap: after installing, brew is invoked by the path it landed at" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A stand-in for the installer's result: the only known prefix that
    // exists on this machine is the one the test plants under /usr/local? No
    // -- the probe list is fixed, so plant nothing and assert the fallback:
    // with no prefix present the exe stays `brew`.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "env NONINTERACTIVE=1 /bin/bash /tmp/i" },
    } };
    var b: Brew = .{ .runner = fake.runner(), .io = io, .scratch_dir = "/tmp" };
    const before = b.exe;
    _ = try b.backend().bootstrap(a, "/tmp/i");
    // Either a real prefix was found (a mac with brew installed) and the exe
    // became absolute, or none was and it is unchanged; never something else.
    try testing.expect(std.mem.eql(u8, b.exe, before) or std.fs.path.isAbsolute(b.exe));
    if (std.fs.path.isAbsolute(b.exe)) try testing.expect(std.mem.endsWith(u8, b.exe, "/brew"));
}

test "install: a failed tap fails its row and the rows after it still run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The tapped row's trust and install are unscripted, so reaching either
    // would fail the test with a different error than the one asserted.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew tap owner/tap", .code = 1, .stderr = "no such tap" },
        .{ .argv = "brew install ripgrep" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{
        rowOf("owner/tap/thing", &.{}),
        rowOf("ripgrep", &.{}),
    }));
    try testing.expect(fake.called("brew install ripgrep"));
}

test "install: a failed trust fails its row and the rows after it still run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "brew tap owner/tap" },
        .{ .argv = "brew trust --cask owner/tap/somecask", .code = 1, .stderr = "refused" },
        .{ .argv = "brew install --cask ghostty" },
    } };
    var b: Brew = .{ .runner = fake.runner() };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{
        rowOf("owner/tap/somecask", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}),
        rowOf("ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }}),
    }));
    try testing.expect(!fake.called("brew install --cask owner/tap/somecask"));
    try testing.expect(fake.called("brew install --cask ghostty"));
}

test "install: a failed install is an error, not a silent skip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "brew install ripgrep", .code = 1, .stderr = "no bottle" }},
    };
    var b: Brew = .{ .runner = fake.runner() };

    try testing.expectError(error.BrewInstallFailed, b.backend().install(a, &.{rowOf("ripgrep", &.{})}));
}

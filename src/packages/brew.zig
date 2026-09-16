//! The Homebrew adapter.
//!
//! Rows take one key beyond the core set: `kind`, `"formula"` (the default)
//! or `"cask"`. A tap is not a key -- a tap-qualified `name`
//! (`owner/tap/formula`) names its own tap, and declaring such a row IS the
//! decision to trust that tap, which the adapter acts on by tapping and
//! trusting the single formula rather than the whole tap.
//!
//! Names need no translation: `brew leaves --installed-on-request` reports a
//! core formula bare and a tapped one fully qualified, exactly as a row
//! spells it. Casks are a separate namespace that can collide with a formula
//! of the same name, so a cask's id carries its kind.

const std = @import("std");

const backend_mod = @import("backend.zig");
const exec = @import("exec.zig");
const manifest_mod = @import("manifest.zig");

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

    pub fn backend(self: *Brew) Backend {
        return .{ .name = "brew", .ctx = self, .vtable = &vtable };
    }

    const vtable: Backend.VTable = .{
        .available = availableImpl,
        .validate = validateImpl,
        .idOf = idOfImpl,
        .installedExplicit = installedExplicitImpl,
        .install = installImpl,
    };

    fn availableImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!bool {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        const res = self.runner.run(arena, &.{ "brew", "--version" }) catch return false;
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
        return switch (kindOf(row)) {
            .formula => row.name,
            .cask => std.fmt.allocPrint(arena, "{s}{s}", .{ cask_prefix, row.name }),
        };
    }

    fn installedExplicitImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *Brew = @ptrCast(@alignCast(ctx));

        var out: std.ArrayList([]const u8) = .empty;

        const formulae = try self.runner.run(arena, &.{ "brew", "leaves", "--installed-on-request" });
        if (!formulae.ok) return error.BrewQueryFailed;
        try appendLines(arena, &out, formulae.stdout, "");

        const casks = try self.runner.run(arena, &.{ "brew", "list", "--cask" });
        if (!casks.ok) return error.BrewQueryFailed;
        try appendLines(arena, &out, casks.stdout, cask_prefix);

        return out.toOwnedSlice(arena);
    }

    fn installImpl(ctx: *anyopaque, arena: std.mem.Allocator, rows: []const Row) anyerror!void {
        const self: *Brew = @ptrCast(@alignCast(ctx));
        for (rows) |row| {
            if (tapOf(row.name)) |tap| {
                const tapped = try self.runner.run(arena, &.{ "brew", "tap", tap });
                if (!tapped.ok) return error.BrewTapFailed;
                // Trust the one formula named, never the whole tap: an
                // untrusted third-party tap is ignored outright since
                // Homebrew 6.0, and whole-tap trust would extend to every
                // formula it ever adds.
                const trusted = try self.runner.run(arena, &.{ "brew", "trust", "--formula", row.name });
                if (!trusted.ok) return error.BrewTrustFailed;
            }
            const res = switch (kindOf(row)) {
                .formula => try self.runner.run(arena, &.{ "brew", "install", row.name }),
                .cask => try self.runner.run(arena, &.{ "brew", "install", "--cask", row.name }),
            };
            if (!res.ok) return error.BrewInstallFailed;
        }
    }
};

fn kindOf(row: Row) Kind {
    const f = row.field("kind") orelse return .formula;
    return switch (f) {
        .string => |s| if (std.mem.eql(u8, s, "cask")) .cask else .formula,
        else => .formula,
    };
}

/// The tap a qualified name belongs to (`owner/tap` of `owner/tap/formula`),
/// or null for a core formula. A cask name never qualifies this way.
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
            .argv = "brew leaves --installed-on-request",
            .stdout = "ripgrep\nd12frosted/emacs-plus/emacs-plus@30\n",
        },
        .{ .argv = "brew list --cask", .stdout = "ghostty\n1password\n" },
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
        .{ .argv = "brew leaves --installed-on-request", .code = 1, .stderr = "boom" },
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

    var missing: exec.Fake = .{ .arena = a, .entries = &.{} };
    var missing_brew: Brew = .{ .runner = missing.runner() };
    try testing.expect(!try missing_brew.backend().available(a));
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

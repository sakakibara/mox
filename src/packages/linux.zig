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
    DistroQueryFailed,
    DistroInstallFailed,
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
            .dnf => &.{ "dnf", "repoquery", "--userinstalled", "--qf", "%{name}\n" },
            .pacman => &.{ "pacman", "-Qeq" },
        };
    }
};

pub const Distro = struct {
    manager: Manager,
    runner: exec.Runner,
    /// Overrides the root check, so a test can exercise both paths on a host
    /// whose own uid it does not control.
    force_elevate: ?bool = null,

    pub fn backend(self: *Distro) Backend {
        return .{ .name = self.manager.name(), .ctx = self, .vtable = &vtable };
    }

    const vtable: Backend.VTable = .{
        .available = availableImpl,
        .validate = validateImpl,
        .idOf = idOfImpl,
        .installedExplicit = installedExplicitImpl,
        .install = installImpl,
        .declare = declareImpl,
    };

    fn availableImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!bool {
        const self: *Distro = @ptrCast(@alignCast(ctx));
        const res = self.runner.run(arena, &.{ self.manager.exe(), "--version" }) catch |e| switch (e) {
            error.FileNotFound => return false,
            else => return e,
        };
        try exec.checkTimedOut(res);
        return res.ok;
    }

    /// These managers take no row keys of their own yet. Refusing an unknown
    /// one keeps a key that means something to a different manager (a brew
    /// `kind`, a scoop `bucket`) from sitting in a row that silently ignores
    /// it.
    fn validateImpl(ctx: *anyopaque, row: Row, diag: ?*Diag) anyerror!void {
        const self: *Distro = @ptrCast(@alignCast(ctx));
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
        if (rows.len == 0) return;

        const elevate = self.elevates();

        if (self.manager == .apt) {
            // An install resolves against the index, so a stale one turns a
            // present package into "not found".
            var up_argv: std.ArrayList([]const u8) = .empty;
            if (elevate) try up_argv.append(arena, "sudo");
            try up_argv.appendSlice(arena, &.{ "apt-get", "update" });
            const up = try self.runner.stream(arena, up_argv.items);
            try exec.checkTimedOut(up);
            if (!up.ok) return Error.DistroInstallFailed;
        }

        var argv: std.ArrayList([]const u8) = .empty;
        if (elevate) try argv.append(arena, "sudo");
        const head: []const []const u8 = switch (self.manager) {
            .apt => &.{ "apt-get", "install", "-y" },
            .dnf => &.{ "dnf", "install", "-y" },
            .pacman => &.{ "pacman", "-Syu", "--needed", "--noconfirm" },
        };
        try argv.appendSlice(arena, head);
        for (rows) |row| try argv.append(arena, row.name);

        const res = try self.runner.stream(arena, argv.items);
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.DistroInstallFailed;
    }

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
    try testing.expectEqualStrings("%{name}\n", Manager.dnf.queryArgv()[4]);
}

test "install: root installs without sudo, which a minimal image lacks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
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
        .{ .argv = "apt-get update" },
        .{ .argv = "apt-get install -y bat" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = false };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(fake.called("apt-get update"));
}

test "install: apt refreshes the index, then installs the whole set at once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "sudo apt-get update" },
        .{ .argv = "sudo apt-get install -y bat fd-find" },
    } };
    var d: Distro = .{ .manager = .apt, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{ rowOf("bat", &.{}), rowOf("fd-find", &.{}) });
    try testing.expect(fake.called("sudo apt-get update"));
    try testing.expect(fake.called("sudo apt-get install -y bat fd-find"));
}

test "install: dnf takes one non-interactive command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
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
        .{ .argv = "sudo pacman -Syu --needed --noconfirm bat" },
    } };
    var d: Distro = .{ .manager = .pacman, .runner = fake.runner(), .force_elevate = true };

    try d.backend().install(a, &.{rowOf("bat", &.{})});
    try testing.expect(fake.called("sudo pacman -Syu --needed --noconfirm bat"));
}

test "install: a failed install is an error, not a silent skip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
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
    try testing.expect(!try d1.backend().available(a));

    var broken: exec.Fake = .{
        .arena = a,
        .entries = &.{.{ .argv = "dnf --version", .fail = error.AccessDenied }},
    };
    var d2: Distro = .{ .manager = .dnf, .runner = broken.runner() };
    try testing.expectError(error.AccessDenied, d2.backend().available(a));
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

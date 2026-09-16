//! The Windows adapters: scoop and winget.
//!
//! Both report what is installed as JSON rather than as text to scrape, which
//! is the whole reason these are the query commands: `scoop list` and
//! `winget list` are human-formatted and rot, `scoop export` and
//! `winget export` are machine formats.
//!
//! Identity differs between them, and neither needs a second namespace the
//! way brew's casks do:
//!
//! - scoop installs one app per name, so the NAME is the identity. A bucket
//!   says where an app comes from, not which app it is, so it is a field used
//!   at install time rather than part of the id.
//! - winget's identity is the `PackageIdentifier` (`Microsoft.PowerShell`),
//!   which is what a row spells and what an export reports. Its display name
//!   is not unique and is never used here.
//!
//! Exercised against the real managers only by the Windows integration job;
//! the unit tests cover the parsing against fixtures.

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
    UnknownScoopKey,
    UnknownWingetKey,
    BadWingetValue,
    ScoopQueryFailed,
    ScoopInstallFailed,
    WingetQueryFailed,
    WingetInstallFailed,
    UnreadableExport,
};

/// `scoop export` emits `{"apps":[{"Name":...,"Source":...}],...}`.
pub const Scoop = struct {
    runner: exec.Runner,
    /// Where scoop lands (`<home>\scoop\shims`), so a bootstrap can name the
    /// bin dir for this same run. Empty means unknown.
    home: []const u8 = "",
    /// How scoop is invoked: `scoop` until a bootstrap installs it, then its
    /// own shim script through pwsh, because a child's PATH is never used to
    /// resolve argv[0] and a freshly installed scoop is on no PATH yet.
    argv0: []const []const u8 = &.{"scoop"},

    pub fn backend(self: *Scoop) Backend {
        return .{ .name = "scoop", .ctx = self, .vtable = &vtable };
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

    /// scoop installs itself from a PowerShell script mox has already fetched
    /// and verified. `-RunAsAdmin` because the installer otherwise refuses an
    /// elevated shell, which a CI runner is; it changes nothing elsewhere.
    fn bootstrapImpl(ctx: *anyopaque, arena: std.mem.Allocator, installer_path: []const u8) anyerror!?[]const u8 {
        const self: *Scoop = @ptrCast(@alignCast(ctx));
        const res = try exec.runPowerShell(self.runner, arena, &.{ installer_path, "-RunAsAdmin" }, null, true);
        try exec.checkTimedOut(res);
        if (!res.ok) return bootstrap_mod.Error.BootstrapFailed;
        if (self.home.len == 0) return null;
        const shims = try std.fs.path.join(arena, &.{ self.home, "scoop", "shims" });
        const shim = try std.fs.path.join(arena, &.{ shims, "scoop.ps1" });
        self.argv0 = try exec.powerShellArgv(arena, exec.powershell_hosts[0], &.{shim});
        return shims;
    }

    fn argv(self: *const Scoop, arena: std.mem.Allocator, rest: []const []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        try out.appendSlice(arena, self.argv0);
        try out.appendSlice(arena, rest);
        return out.toOwnedSlice(arena);
    }

    /// Every scoop call goes through `invoke`: once a bootstrap has made
    /// argv0 a PowerShell script, the host is found by trying.
    fn call(self: *const Scoop, arena: std.mem.Allocator, rest: []const []const u8, streamed: bool) anyerror!exec.Result {
        return self.runner.invoke(arena, try self.argv(arena, rest), null, streamed);
    }

    fn availableImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!Backend.Availability {
        const self: *Scoop = @ptrCast(@alignCast(ctx));
        return Backend.probeAvailability(self.argv0[0], self.call(arena, &.{"--version"}, false));
    }

    fn validateImpl(_: *anyopaque, row: Row, diag: ?*Diag) anyerror!void {
        for (row.fields) |p| {
            if (std.mem.eql(u8, p.key, "bucket")) {
                if (p.value != .string) {
                    if (diag) |d| d.set(
                        "{s}: row \"{s}\": \"bucket\" must be a string",
                        .{ row.label, row.name },
                    );
                    return Error.UnknownScoopKey;
                }
                continue;
            }
            if (diag) |d| d.set(
                "{s}: row \"{s}\": scoop accepts no key \"{s}\" (scoop rows take \"bucket\")",
                .{ row.label, row.name, p.key },
            );
            return Error.UnknownScoopKey;
        }
    }

    /// The bare app name. scoop installs one app per name regardless of which
    /// bucket supplied it, so a bucket-qualified row and a bare one naming the
    /// same app are the same package.
    fn idOfImpl(_: *anyopaque, _: std.mem.Allocator, row: Row) anyerror![]const u8 {
        return row.name;
    }

    fn installedExplicitImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *Scoop = @ptrCast(@alignCast(ctx));
        const res = try self.call(arena, &.{"export"}, false);
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.ScoopQueryFailed;
        return appNames(arena, res.stdout);
    }

    fn installImpl(ctx: *anyopaque, arena: std.mem.Allocator, rows: []const Row) anyerror!void {
        const self: *Scoop = @ptrCast(@alignCast(ctx));
        // One row at a time, and every row is attempted: one app that fails
        // to resolve must not stop the rest of the set.
        var failed = false;
        for (rows) |row| {
            // A bucket must exist before an app in it can resolve, exactly as
            // a brew tap must. Adding one already present is a no-op.
            if (bucketOf(row)) |bucket| {
                const added = try self.call(arena, &.{ "bucket", "add", bucket }, true);
                try exec.checkTimedOut(added);
                if (!added.ok) {
                    failed = true;
                    continue;
                }
            }
            const target = if (bucketOf(row)) |bucket|
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ bucket, row.name })
            else
                row.name;
            const res = try self.call(arena, &.{ "install", target }, true);
            try exec.checkTimedOut(res);
            if (!res.ok) failed = true;
        }
        if (failed) return Error.ScoopInstallFailed;
    }

    fn declareImpl(_: *anyopaque, _: std.mem.Allocator, id: []const u8) anyerror!Backend.Declaration {
        // The bucket an installed app came from is not part of its identity,
        // and a row without one installs from whichever bucket provides it.
        return .{ .name = id };
    }
};

fn bucketOf(row: Row) ?[]const u8 {
    const f = row.field("bucket") orelse return null;
    return switch (f) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

/// Every `apps[].Name` of a `scoop export` document.
fn appNames(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const v = json.parse(arena, text, .{}) catch return Error.UnreadableExport;
    if (v != .object) return Error.UnreadableExport;
    const apps = v.get("apps") orelse return Error.UnreadableExport;
    if (apps != .array) return Error.UnreadableExport;

    var out: std.ArrayList([]const u8) = .empty;
    for (apps.array) |app| {
        if (app != .object) continue;
        const name = app.get("Name") orelse continue;
        if (name != .string or name.string.len == 0) continue;
        try out.append(arena, name.string);
    }
    return out.toOwnedSlice(arena);
}

/// `winget export` writes `{"Sources":[{"Packages":[{"PackageIdentifier":...}]}]}`
/// to a FILE rather than to stdout, so this adapter needs a path to hand it
/// and the ability to read one back.
pub const Winget = struct {
    runner: exec.Runner,
    io: Io,
    /// Where an export is staged. mox's own state directory, so a machine
    /// with an unwritable TEMP still works and nothing is left in a shared
    /// location.
    scratch_dir: []const u8,

    pub fn backend(self: *Winget) Backend {
        return .{ .name = "winget", .ctx = self, .vtable = &vtable };
    }

    const vtable: Backend.VTable = .{
        .available = availableImpl,
        .validate = validateImpl,
        .idOf = idOfImpl,
        .installedExplicit = installedExplicitImpl,
        .install = installImpl,
        .declare = declareImpl,
    };

    fn availableImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!Backend.Availability {
        const self: *Winget = @ptrCast(@alignCast(ctx));
        return Backend.probeAvailability("winget", self.runner.run(arena, &.{ "winget", "--version" }));
    }

    fn validateImpl(_: *anyopaque, row: Row, diag: ?*Diag) anyerror!void {
        for (row.fields) |p| {
            const known = std.mem.eql(u8, p.key, "source") or
                std.mem.eql(u8, p.key, "scope") or
                std.mem.eql(u8, p.key, "override");
            if (!known) {
                if (diag) |d| d.set(
                    "{s}: row \"{s}\": winget accepts no key \"{s}\" (winget rows take \"source\", \"scope\", \"override\")",
                    .{ row.label, row.name, p.key },
                );
                return Error.UnknownWingetKey;
            }
            if (p.value != .string) {
                if (diag) |d| d.set(
                    "{s}: row \"{s}\": \"{s}\" must be a string",
                    .{ row.label, row.name, p.key },
                );
                return Error.BadWingetValue;
            }
            if (std.mem.eql(u8, p.key, "scope")) {
                const v = p.value.string;
                if (!std.mem.eql(u8, v, "user") and !std.mem.eql(u8, v, "machine")) {
                    if (diag) |d| d.set(
                        "{s}: row \"{s}\": \"scope\" is \"{s}\", not \"user\" or \"machine\"",
                        .{ row.label, row.name, v },
                    );
                    return Error.BadWingetValue;
                }
            }
        }
    }

    /// The `PackageIdentifier`, which is what the row spells.
    fn idOfImpl(_: *anyopaque, _: std.mem.Allocator, row: Row) anyerror![]const u8 {
        return row.name;
    }

    fn installedExplicitImpl(ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *Winget = @ptrCast(@alignCast(ctx));

        // Named per process: a status running beside an apply must not read
        // the other's half-written export as this machine's state.
        const name = try std.fmt.allocPrint(arena, "winget-export-{d}.json", .{exec.processId()});
        const tmp_dir = try exec.scratchTmpDir(arena, self.scratch_dir);
        const path = try std.fs.path.join(arena, &.{ tmp_dir, name });
        try Io.Dir.cwd().createDirPath(self.io, tmp_dir);
        // A stale export from an interrupted run would otherwise be read as
        // this machine's current state.
        Io.Dir.cwd().deleteFile(self.io, path) catch {};

        const res = try self.runner.run(arena, &.{
            "winget",                     "export",
            "-o",                         path,
            "--accept-source-agreements",
        });
        try exec.checkTimedOut(res);
        if (!res.ok) return Error.WingetQueryFailed;

        const text = Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(8 << 20)) catch
            return Error.UnreadableExport;
        defer Io.Dir.cwd().deleteFile(self.io, path) catch {};
        return packageIdentifiers(arena, text);
    }

    fn installImpl(ctx: *anyopaque, arena: std.mem.Allocator, rows: []const Row) anyerror!void {
        const self: *Winget = @ptrCast(@alignCast(ctx));
        var failed = false;
        for (rows) |row| {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{ "winget", "install", "--id", row.name });
            if (stringField(row, "source")) |v| try argv.appendSlice(arena, &.{ "--source", v });
            if (stringField(row, "scope")) |v| try argv.appendSlice(arena, &.{ "--scope", v });
            if (stringField(row, "override")) |v| try argv.appendSlice(arena, &.{ "--override", v });
            // Without both, winget stops on a prompt no unattended apply can
            // answer.
            try argv.appendSlice(arena, &.{ "--accept-package-agreements", "--accept-source-agreements" });

            const res = try self.runner.stream(arena, argv.items);
            try exec.checkTimedOut(res);
            if (!res.ok) failed = true;
        }
        if (failed) return Error.WingetInstallFailed;
    }

    fn declareImpl(_: *anyopaque, _: std.mem.Allocator, id: []const u8) anyerror!Backend.Declaration {
        // An export reports the identifier and nothing that distinguishes one
        // install from another, so a recorded row carries the id alone.
        return .{ .name = id };
    }
};

fn stringField(row: Row, key: []const u8) ?[]const u8 {
    const f = row.field(key) orelse return null;
    return switch (f) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

/// Every `Sources[].Packages[].PackageIdentifier` of a `winget export`
/// document.
fn packageIdentifiers(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const v = json.parse(arena, text, .{}) catch return Error.UnreadableExport;
    if (v != .object) return Error.UnreadableExport;
    const sources = v.get("Sources") orelse return Error.UnreadableExport;
    if (sources != .array) return Error.UnreadableExport;

    var out: std.ArrayList([]const u8) = .empty;
    for (sources.array) |src| {
        if (src != .object) continue;
        const pkgs = src.get("Packages") orelse continue;
        if (pkgs != .array) continue;
        for (pkgs.array) |pkg| {
            if (pkg != .object) continue;
            const id = pkg.get("PackageIdentifier") orelse continue;
            if (id != .string or id.string.len == 0) continue;
            try out.append(arena, id.string);
        }
    }
    return out.toOwnedSlice(arena);
}

const testing = std.testing;

fn scoopRow(name: []const u8, fields: []const manifest_mod.Pair) Row {
    return .{
        .name = name,
        .backend = "scoop",
        .when = null,
        .fields = fields,
        .origin = "/tmp/x.toml",
        .label = "data/packages/windows.toml",
        .index = 0,
    };
}

fn wingetRow(name: []const u8, fields: []const manifest_mod.Pair) Row {
    return .{
        .name = name,
        .backend = "winget",
        .when = null,
        .fields = fields,
        .origin = "/tmp/x.toml",
        .label = "data/packages/windows.toml",
        .index = 0,
    };
}

const scoop_export =
    \\{
    \\  "buckets": [ { "Name": "main", "Source": "https://github.com/ScoopInstaller/Main" } ],
    \\  "apps": [
    \\    { "Info": "", "Name": "7zip", "Source": "main", "Version": "23.01" },
    \\    { "Info": "", "Name": "firefox", "Source": "extras", "Version": "122.0" }
    \\  ]
    \\}
;

const winget_export =
    \\{
    \\  "$schema": "https://aka.ms/winget-packages.schema.2.0.json",
    \\  "CreationDate": "2026-09-13T00:00:00.000-00:00",
    \\  "Sources": [
    \\    {
    \\      "Packages": [
    \\        { "PackageIdentifier": "Microsoft.PowerShell" },
    \\        { "PackageIdentifier": "Git.Git" }
    \\      ],
    \\      "SourceDetails": { "Argument": "https://cdn.winget.microsoft.com/cache", "Name": "winget" }
    \\    }
    \\  ],
    \\  "WinGetVersion": "1.7.10661"
    \\}
;

test "scoop: an export yields every app name, bucket-independent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "scoop export", .stdout = scoop_export },
    } };
    var s: Scoop = .{ .runner = fake.runner() };

    const got = try s.backend().installedExplicit(a);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("7zip", got[0]);
    // From the `extras` bucket, but reported bare: the bucket is provenance,
    // not identity.
    try testing.expectEqualStrings("firefox", got[1]);
}

test "scoop: a bucket row matches the bare name it installs as" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    var s: Scoop = .{ .runner = fake.runner() };

    const row = scoopRow("firefox", &.{.{ .key = "bucket", .value = .{ .string = "extras" } }});
    // Were the id bucket-qualified, an installed `firefox` would never match
    // this row and apply would try to install it on every run.
    try testing.expectEqualStrings("firefox", try s.backend().idOf(a, row));
}

test "scoop: install adds the bucket first, then installs qualified" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "scoop bucket add extras" },
        .{ .argv = "scoop install extras/firefox" },
    } };
    var s: Scoop = .{ .runner = fake.runner() };

    try s.backend().install(a, &.{scoopRow("firefox", &.{.{ .key = "bucket", .value = .{ .string = "extras" } }})});
    try testing.expect(fake.called("scoop bucket add extras"));
    try testing.expect(fake.called("scoop install extras/firefox"));
}

test "scoop: a bucketless row installs bare and adds no bucket" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{.{ .argv = "scoop install 7zip" }} };
    var s: Scoop = .{ .runner = fake.runner() };

    // The Fake errors on anything unscripted, so a stray `bucket add` fails.
    try s.backend().install(a, &.{scoopRow("7zip", &.{})});
    try testing.expect(fake.called("scoop install 7zip"));
}

test "scoop: an unparseable export is an error, never an empty set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "scoop export", .stdout = "not json at all" },
    } };
    var s: Scoop = .{ .runner = fake.runner() };
    try testing.expectError(Error.UnreadableExport, s.backend().installedExplicit(a));
}

test "scoop: validate refuses a key meant for another manager" {
    var fake: exec.Fake = .{ .arena = undefined, .entries = &.{} };
    var s: Scoop = .{ .runner = fake.runner() };

    var d: Diag = .{};
    const row = scoopRow("firefox", &.{.{ .key = "kind", .value = .{ .string = "cask" } }});
    try testing.expectError(Error.UnknownScoopKey, s.backend().validate(row, &d));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "no key \"kind\"") != null);
}

test "winget: an export yields every PackageIdentifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try packageIdentifiers(a, winget_export);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("Microsoft.PowerShell", got[0]);
    try testing.expectEqualStrings("Git.Git", got[1]);
}

test "winget: the export is staged under a per-process name and removed after" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const scratch = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "state" });
    const name = try std.fmt.allocPrint(a, "winget-export-{d}.json", .{exec.processId()});
    const path = try std.fs.path.join(a, &.{ scratch, exec.tmp_subdir, name });
    const argv = try std.fmt.allocPrint(a, "winget export -o {s} --accept-source-agreements", .{path});

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = argv, .stdout = winget_export, .write_after = "-o", .io = io },
    } };
    var w: Winget = .{ .runner = fake.runner(), .io = io, .scratch_dir = scratch };

    const got = try w.backend().installedExplicit(a);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expect(fake.called(argv));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));
}

test "winget: an export missing Sources is an error, never an empty set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An empty set would read as "nothing installed" and make every declared
    // package look missing.
    try testing.expectError(Error.UnreadableExport, packageIdentifiers(a, "{\"WinGetVersion\":\"1.7\"}"));
}

test "winget: install carries source, scope and override, and both agreements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "winget install --id Microsoft.PowerShell --source winget --scope machine " ++
            "--override /SILENT --accept-package-agreements --accept-source-agreements" },
    } };
    var w: Winget = .{ .runner = fake.runner(), .io = std.testing.io, .scratch_dir = "/tmp" };

    try w.backend().install(a, &.{wingetRow("Microsoft.PowerShell", &.{
        .{ .key = "source", .value = .{ .string = "winget" } },
        .{ .key = "scope", .value = .{ .string = "machine" } },
        .{ .key = "override", .value = .{ .string = "/SILENT" } },
    })});
    try testing.expect(fake.calls.items.len == 1);
}

test "winget: a bare row installs with the agreements alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "winget install --id Git.Git --accept-package-agreements --accept-source-agreements" },
    } };
    var w: Winget = .{ .runner = fake.runner(), .io = std.testing.io, .scratch_dir = "/tmp" };

    try w.backend().install(a, &.{wingetRow("Git.Git", &.{})});
    try testing.expect(fake.called(
        "winget install --id Git.Git --accept-package-agreements --accept-source-agreements",
    ));
}

test "winget: validate refuses an unknown key and a scope outside the set" {
    var fake: exec.Fake = .{ .arena = undefined, .entries = &.{} };
    var w: Winget = .{ .runner = fake.runner(), .io = std.testing.io, .scratch_dir = "/tmp" };
    const be = w.backend();

    var d1: Diag = .{};
    try testing.expectError(Error.UnknownWingetKey, be.validate(
        wingetRow("Git.Git", &.{.{ .key = "bucket", .value = .{ .string = "extras" } }}),
        &d1,
    ));

    var d2: Diag = .{};
    try testing.expectError(Error.BadWingetValue, be.validate(
        wingetRow("Git.Git", &.{.{ .key = "scope", .value = .{ .string = "Machine" } }}),
        &d2,
    ));
    try testing.expect(std.mem.indexOf(u8, d2.capture().?, "not \"user\" or \"machine\"") != null);
}

test "winget: a valid row passes every field" {
    var fake: exec.Fake = .{ .arena = undefined, .entries = &.{} };
    var w: Winget = .{ .runner = fake.runner(), .io = std.testing.io, .scratch_dir = "/tmp" };

    try w.backend().validate(wingetRow("Microsoft.PowerShell", &.{
        .{ .key = "source", .value = .{ .string = "msstore" } },
        .{ .key = "scope", .value = .{ .string = "user" } },
        .{ .key = "override", .value = .{ .string = "/quiet" } },
    }), null);
}

test "scoop: the installer runs as a PowerShell script with -RunAsAdmin, and the shim is used after" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const shim = try std.fs.path.join(a, &.{ "C:\\Users\\x", "scoop", "shims", "scoop.ps1" });
    const shim_export = try std.fmt.allocPrint(a, "pwsh -NoProfile -ExecutionPolicy Bypass -File {s} export", .{shim});
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\\i.ps1 -RunAsAdmin" },
        .{ .argv = shim_export, .stdout = scoop_export },
    } };
    var s: Scoop = .{ .runner = fake.runner(), .home = "C:\\Users\\x" };

    const shims = (try s.backend().bootstrap(a, "C:\\i.ps1")).?;
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ "C:\\Users\\x", "scoop", "shims" }), shims);
    try testing.expect(fake.called("pwsh -NoProfile -ExecutionPolicy Bypass -File C:\\i.ps1 -RunAsAdmin"));

    const got = try s.backend().installedExplicit(a);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expect(fake.called(shim_export));
}

test "scoop: without pwsh, the installer and the shim run through powershell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const shim = try std.fs.path.join(a, &.{ "C:\\Users\\x", "scoop", "shims", "scoop.ps1" });
    const pwsh_probe = try std.fmt.allocPrint(a, "pwsh -NoProfile -ExecutionPolicy Bypass -File {s} --version", .{shim});
    const ps_probe = try std.fmt.allocPrint(a, "powershell -NoProfile -ExecutionPolicy Bypass -File {s} --version", .{shim});
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\\i.ps1 -RunAsAdmin", .fail = error.FileNotFound },
        .{ .argv = "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\i.ps1 -RunAsAdmin" },
        .{ .argv = pwsh_probe, .fail = error.FileNotFound },
        .{ .argv = ps_probe, .stdout = "v0.5.2\n" },
    } };
    var s: Scoop = .{ .runner = fake.runner(), .home = "C:\\Users\\x" };

    _ = try s.backend().bootstrap(a, "C:\\i.ps1");
    try testing.expect((try s.backend().available(a)) == .present);
    try testing.expectEqual(@as(usize, 4), fake.calls.items.len);
    try testing.expect(fake.called("powershell -NoProfile -ExecutionPolicy Bypass -File C:\\i.ps1 -RunAsAdmin"));
    try testing.expect(fake.called(ps_probe));
}

test "available: present, absent and broken on both managers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sf: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "scoop --version", .stdout = "v0.5.2\n", .once = true },
        .{ .argv = "scoop --version", .code = 1 },
    } };
    var s: Scoop = .{ .runner = sf.runner() };
    try testing.expect((try s.backend().available(a)) == .present);
    const sb = try s.backend().available(a);
    try testing.expectEqual(@as(u8, 1), sb.broken.code);
    try testing.expectEqualStrings("scoop", sb.broken.argv0);

    var wf: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "winget --version", .fail = error.FileNotFound, .once = true },
        .{ .argv = "winget --version", .code = 255 },
    } };
    var w: Winget = .{ .runner = wf.runner(), .io = std.testing.io, .scratch_dir = "/tmp" };
    try testing.expect((try w.backend().available(a)) == .absent);
    const wb = try w.backend().available(a);
    try testing.expectEqual(@as(u8, 255), wb.broken.code);
    try testing.expectEqualStrings("winget", wb.broken.argv0);
}

test "declare: an observed id round-trips on both managers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sf: exec.Fake = .{ .arena = a, .entries = &.{} };
    var s: Scoop = .{ .runner = sf.runner() };
    const sd = try s.backend().declare(a, "7zip");
    try testing.expectEqualStrings("7zip", sd.name);
    try testing.expectEqualStrings("7zip", try s.backend().idOf(a, scoopRow(sd.name, sd.fields)));

    var wf: exec.Fake = .{ .arena = a, .entries = &.{} };
    var w: Winget = .{ .runner = wf.runner(), .io = std.testing.io, .scratch_dir = "/tmp" };
    const wd = try w.backend().declare(a, "Git.Git");
    try testing.expectEqualStrings("Git.Git", wd.name);
    try testing.expectEqualStrings("Git.Git", try w.backend().idOf(a, wingetRow(wd.name, wd.fields)));
}

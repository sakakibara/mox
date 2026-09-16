//! The package subsystem through the CLI: `status` reports, `apply`
//! installs, `commit` reconciles.
//!
//! Hermetic. Every manager call goes through a scripted runner, so these run
//! with no package manager installed and never touch the machine running
//! them. The runner errors on any command it was not scripted for, so a
//! command the code should not have run fails the test rather than passing
//! unnoticed.

const std = @import("std");
const mox = @import("mox");

const Io = std.Io;

const testutil = @import("testutil.zig");
const Harness = testutil.Harness;

fn setup(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir, opts: testutil.SetupOpts) !Harness {
    var pinned = opts;
    if (pinned.os == null) pinned.os = "darwin";
    // These fixtures are about packages, not files, so the tree exists and is
    // empty rather than absent -- an absent `src/` is its own error path.
    pinned.create_repo_src = true;
    return testutil.setup(a, io, tmp, pinned);
}

fn writeManifest(io: Io, h: Harness, a: std.mem.Allocator, name: []const u8, body: []const u8) !void {
    const dir = try std.fs.path.join(a, &.{ h.repo, "data", "packages" });
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(a, &.{ dir, name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
}

fn readManifest(io: Io, h: Harness, a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ h.repo, "data", "packages", name });
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
}

/// The Linux managers reporting themselves absent, as they are on a mac and
/// on every runner these fixtures target. Registered adapters are probed
/// whether or not a fixture cares about them.
fn absentLinuxManagers(a: std.mem.Allocator, entries: *std.ArrayList(mox.packages.exec.Fake.Entry)) !void {
    for ([_][]const u8{
        "apt-get --version",
        "dnf --version",
        "pacman --version",
        "scoop --version",
        "winget --version",
    }) |argv| {
        try entries.append(a, .{ .argv = argv, .fail = error.FileNotFound });
    }
}

/// A machine whose only usable manager is brew, carrying `formulae` and
/// `casks` and answering `extra` for anything else.
fn brewWith(
    a: std.mem.Allocator,
    formulae: []const u8,
    casks: []const u8,
    extra: []const mox.packages.exec.Fake.Entry,
) !*mox.packages.exec.Fake {
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "brew --version", .stdout = "Homebrew 6.0.0\n" });
    try entries.append(a, .{ .argv = "brew leaves --installed-on-request", .stdout = formulae });
    try entries.append(a, .{ .argv = "brew list --cask", .stdout = casks });
    try absentLinuxManagers(a, &entries);
    for (extra) |e| try entries.append(a, e);

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    return fake;
}

fn useFake(fake: *mox.packages.exec.Fake) void {
    mox.cli.app.package_runner_override = fake.runner();
}

test "status: an untracked package and a missing one are both reported" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml",
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
        \\[[packages]]
        \\name = "fd"
        \\
    );

    const fake = try brewWith(a, "ripgrep\nhtop\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "packages:") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "MISSING   brew fd") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "UNTRACKED brew htop") != null);
    // Declared and installed, so it is neither.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "brew ripgrep") == null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
}

test "status: a repo with no manifest never queries a package manager" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // No entries at all: any manager call errors, so a query here fails the
    // test instead of quietly working.
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "packages:") == null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "status --json: packages ride alongside files" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml",
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "ghostty"
        \\kind = "cask"
        \\
    );

    const fake = try brewWith(a, "", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status", "--json" });
    try std.testing.expect(std.mem.startsWith(u8, r.out, "{\"files\":["));
    // A missing cask carries the prefixed id it is compared by.
    try std.testing.expect(std.mem.indexOf(
        u8,
        r.out,
        "{\"backend\":\"brew\",\"state\":\"missing\",\"id\":\"cask:ghostty\",\"name\":\"ghostty\"}",
    ) != null);
}

test "apply: installs what is missing, and a cask through --cask" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml",
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "fd"
        \\
        \\[[packages]]
        \\name = "ghostty"
        \\kind = "cask"
        \\
    );

    const fake = try brewWith(a, "", "", &.{
        .{ .argv = "brew install fd" },
        .{ .argv = "brew install --cask ghostty" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(fake.called("brew install fd"));
    try std.testing.expect(fake.called("brew install --cask ghostty"));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 2 installed, 0 failed") != null);
}

test "apply --dry-run: reports what it would install and installs nothing" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml",
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "fd"
        \\
    );

    // No install entry is scripted, so an install attempt errors out.
    const fake = try brewWith(a, "", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply", "--dry-run" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "would install  brew fd") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 1 would be installed") != null);
    try std.testing.expect(!fake.called("brew install fd"));
}

test "apply: a tapped formula is tapped and trusted before install" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml",
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "d12frosted/emacs-plus/emacs-plus@30"
        \\
    );

    const fake = try brewWith(a, "", "", &.{
        .{ .argv = "brew tap d12frosted/emacs-plus" },
        .{ .argv = "brew trust --formula d12frosted/emacs-plus/emacs-plus@30" },
        .{ .argv = "brew install d12frosted/emacs-plus/emacs-plus@30" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    _ = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(fake.called("brew trust --formula d12frosted/emacs-plus/emacs-plus@30"));
}

test "commit: recording an untracked package appends a row and clears the drift" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml",
        \\backend = "brew"
        \\
        \\# a comment that must survive
        \\[[packages]]
        \\name = "ripgrep"
        \\
    );

    const fake = try brewWith(a, "ripgrep\nhtop\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.runWithInput(&.{ "mox", "commit" }, "y\n");
    try std.testing.expect(std.mem.indexOf(u8, r.out, "untracked package: brew htop") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "1 recorded") != null);

    const after = try readManifest(io, h, a, "darwin.toml");
    // Appended, with every existing byte intact.
    try std.testing.expect(std.mem.indexOf(u8, after, "# a comment that must survive") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "name = \"ripgrep\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, after, "[[packages]]\nname = \"htop\"\n"));

    // The loop closes: what commit wrote is what status now reads as clean.
    const fake2 = try brewWith(a, "ripgrep\nhtop\n", "", &.{});
    useFake(fake2);
    const s = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, s.out, "UNTRACKED") == null);
    try std.testing.expect(std.mem.indexOf(u8, s.out, "clean     brew") != null);
}

test "commit: blacklisting an untracked package stops it being offered" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n");

    const fake = try brewWith(a, "usage\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.runWithInput(&.{ "mox", "commit" }, "b\n");
    try std.testing.expect(std.mem.indexOf(u8, r.out, "1 blacklisted") != null);

    const after = try readManifest(io, h, a, "darwin.toml");
    try std.testing.expect(std.mem.endsWith(u8, after, "[[blacklist]]\nname = \"usage\"\n"));

    const fake2 = try brewWith(a, "usage\n", "", &.{});
    useFake(fake2);
    const s = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, s.out, "UNTRACKED") == null);
}

test "commit: a blacklisted cask is recorded with the field that identifies it" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n");

    const fake = try brewWith(a, "", "docker\n", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    _ = try h.runWithInput(&.{ "mox", "commit" }, "b\n");

    // Without `kind` this would name the FORMULA docker, not the cask.
    const after = try readManifest(io, h, a, "darwin.toml");
    try std.testing.expect(std.mem.indexOf(u8, after, "[[blacklist]]\nname = \"docker\"\nkind = \"cask\"") != null);
}

test "commit: skipping leaves the manifest untouched and the drift standing" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    const original = "backend = \"brew\"\n";
    try writeManifest(io, h, a, "darwin.toml", original);

    const fake = try brewWith(a, "htop\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.runWithInput(&.{ "mox", "commit" }, "s\n");
    try std.testing.expect(std.mem.indexOf(u8, r.out, "1 still untracked") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);

    const after = try readManifest(io, h, a, "darwin.toml");
    try std.testing.expectEqualStrings(original, after);
}

test "commit: a path-scoped commit never reaches the package manifest" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n");

    // Any manager call errors: naming a file must not reach out to packages.
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const live = try h.liveOf("nothing-here.conf");
    _ = try h.run(&.{ "mox", "commit", live });
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

/// A Fedora machine: dnf usable, brew and the other managers absent.
fn dnfWith(
    a: std.mem.Allocator,
    installed: []const u8,
    extra: []const mox.packages.exec.Fake.Entry,
) !*mox.packages.exec.Fake {
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "brew --version", .fail = error.FileNotFound });
    try entries.append(a, .{ .argv = "apt-get --version", .fail = error.FileNotFound });
    try entries.append(a, .{ .argv = "pacman --version", .fail = error.FileNotFound });
    try entries.append(a, .{ .argv = "scoop --version", .fail = error.FileNotFound });
    try entries.append(a, .{ .argv = "winget --version", .fail = error.FileNotFound });
    try entries.append(a, .{ .argv = "dnf --version", .stdout = "dnf 4.18.0\n" });
    try entries.append(a, .{
        .argv = "dnf repoquery --userinstalled --qf %{name}\n",
        .stdout = installed,
    });
    for (extra) |e| try entries.append(a, e);

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    return fake;
}

test "linux: a dnf machine reports and installs through the same core" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "fedora.toml",
        \\backend = "dnf"
        \\
        \\[[packages]]
        \\name = "bat"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    );

    // Both spellings are scripted: whether an install elevates depends on the
    // uid running this suite, and the fixture must not depend on that.
    const fake = try dnfWith(a, "bat\nhtop\n", &.{
        .{ .argv = "sudo dnf install -y ripgrep" },
        .{ .argv = "dnf install -y ripgrep" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const s = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, s.out, "MISSING   dnf ripgrep") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.out, "UNTRACKED dnf htop") != null);

    const fake2 = try dnfWith(a, "bat\nhtop\n", &.{
        .{ .argv = "sudo dnf install -y ripgrep" },
    });
    useFake(fake2);
    _ = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(fake2.called("sudo dnf install -y ripgrep"));
}

test "linux: a manifest for a manager this machine lacks is inert, not an error" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // A shared manifest carries every machine's rows; a mac reading the
    // fedora file must neither install nor complain.
    try writeManifest(io, h, a, "fedora.toml",
        \\backend = "dnf"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    );

    const fake = try brewWith(a, "", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "dnf ripgrep") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "clean     brew") != null);
}

test "linux: a row naming no registered backend is still a loud error" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "typo.toml",
        \\backend = "dnff"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    );

    const fake = try brewWith(a, "", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "no backend named \"dnff\"") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
}

/// A Windows machine: scoop and winget usable, the unix managers absent.
fn windowsWith(
    a: std.mem.Allocator,
    scoop_export: []const u8,
    extra: []const mox.packages.exec.Fake.Entry,
) !*mox.packages.exec.Fake {
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    for ([_][]const u8{ "brew --version", "apt-get --version", "dnf --version", "pacman --version" }) |argv| {
        try entries.append(a, .{ .argv = argv, .fail = error.FileNotFound });
    }
    try entries.append(a, .{ .argv = "scoop --version", .stdout = "v0.5.2\n" });
    try entries.append(a, .{ .argv = "scoop export", .stdout = scoop_export });
    try entries.append(a, .{ .argv = "winget --version", .fail = error.FileNotFound });
    for (extra) |e| try entries.append(a, e);

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    return fake;
}

test "windows: scoop drift and install run through the same core" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "windows.toml",
        \\backend = "scoop"
        \\
        \\[[packages]]
        \\name = "7zip"
        \\
        \\[[packages]]
        \\name = "firefox"
        \\bucket = "extras"
        \\
    );

    const export_json =
        \\{ "apps": [ { "Name": "7zip", "Source": "main" }, { "Name": "curl", "Source": "main" } ] }
    ;
    const fake = try windowsWith(a, export_json, &.{
        .{ .argv = "scoop bucket add extras" },
        .{ .argv = "scoop install extras/firefox" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const s = try h.run(&.{ "mox", "status" });
    // `7zip` is declared and installed; `firefox` is declared only; `curl` is
    // installed only.
    try std.testing.expect(std.mem.indexOf(u8, s.out, "MISSING   scoop firefox") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.out, "UNTRACKED scoop curl") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.out, "scoop 7zip") == null);

    const fake2 = try windowsWith(a, export_json, &.{
        .{ .argv = "scoop bucket add extras" },
        .{ .argv = "scoop install extras/firefox" },
    });
    useFake(fake2);
    _ = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(fake2.called("scoop bucket add extras"));
    try std.testing.expect(fake2.called("scoop install extras/firefox"));
}

test "windows: a winget row is validated even where winget cannot run" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // A shared manifest is read on every machine, so a bad winget row must
    // fail on a mac too rather than waiting for a Windows box to find it.
    try writeManifest(io, h, a, "windows.toml",
        \\backend = "winget"
        \\
        \\[[packages]]
        \\name = "Microsoft.PowerShell"
        \\scope = "Machine"
        \\
    );

    const fake = try brewWith(a, "", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "not \"user\" or \"machine\"") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
}

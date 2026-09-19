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
        "zypper --version",
    }) |argv| {
        try entries.append(a, .{ .argv = argv, .fail = error.FileNotFound });
    }
}

/// A machine whose only usable manager is brew, carrying `formulae` and
/// `casks` and answering `extra` for anything else. Nothing is installed
/// that was not asked for by name, which is the ordinary machine.
fn brewWith(
    a: std.mem.Allocator,
    formulae: []const u8,
    casks: []const u8,
    extra: []const mox.packages.exec.Fake.Entry,
) !*mox.packages.exec.Fake {
    return brewWithInstalled(a, formulae, formulae, casks, extra);
}

/// The same machine, with `installed` the formulae brew has whether or not
/// they were asked for by name -- a superset of `formulae`, since a formula
/// asked for is a formula installed.
fn brewWithInstalled(
    a: std.mem.Allocator,
    installed: []const u8,
    formulae: []const u8,
    casks: []const u8,
    extra: []const mox.packages.exec.Fake.Entry,
) !*mox.packages.exec.Fake {
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "brew --version", .stdout = "Homebrew 6.0.0\n" });
    try entries.append(a, .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 brew list --full-name --installed-on-request", .stdout = formulae });
    try entries.append(a, .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask --full-name", .stdout = casks });
    try entries.append(a, .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 brew list --formula --full-name", .stdout = installed });
    // What an install asks brew each row's name stands for. Answered with
    // nothing, so no row is refused as an alias: these fixtures are about the
    // install, and the alias refusal is exercised on its own elsewhere.
    try entries.append(a, .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 ", .match = .prefix, .code = 1 });
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
        .{ .argv = "brew install -- fd" },
        .{ .argv = "brew install --cask -- ghostty" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(fake.called("brew install -- fd"));
    try std.testing.expect(fake.called("brew install --cask -- ghostty"));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 2 installed, 0 failed") != null);
}

test "apply: the batch being installed is staged, so a run a signal ends can still name it" {
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
        \\name = "ripgrep"
        \\
    );

    const fake = try brewWith(a, "", "", &.{
        .{ .argv = "brew install -- fd" },
        .{ .argv = "brew install -- ripgrep" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(@as(u8, 0), r.rc);

    // An interrupt kills mox under the signal's default disposition, so
    // nothing deferred runs and the last thing said is `installing`. What the
    // install was part-way through has to be staged before the spawn or it is
    // never said at all -- and only for as long as that install is running.
    const want = "mox apply: interrupted installing brew: fd, ripgrep (row(s) in this batch may have landed)\n";
    var staged_at_install = false;
    for (fake.calls.items, fake.notes.items) |call, note| {
        if (!std.mem.endsWith(u8, call, "brew install -- ripgrep")) continue;
        try std.testing.expectEqualStrings(want, note);
        staged_at_install = true;
    }
    try std.testing.expect(staged_at_install);
    // The probe that runs before any row is chosen has nothing to name, and
    // the batch being over leaves nothing staged for the run that follows it.
    try std.testing.expectEqualStrings("", fake.notes.items[0]);
    try std.testing.expectEqualStrings("", mox.machine.job.stagedNote());
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
    try std.testing.expect(std.mem.indexOf(u8, r.out, "would install   brew fd") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 1 would be installed, 0 failed") != null);
    try std.testing.expect(!fake.called("brew install -- fd"));
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
        .{ .argv = "brew tap -- d12frosted/emacs-plus" },
        .{ .argv = "brew trust --formula -- d12frosted/emacs-plus/emacs-plus@30" },
        .{ .argv = "brew install -- d12frosted/emacs-plus/emacs-plus@30" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    // Tap, then trust, then install: each step needs the one before it.
    const tap = indexOfCall(fake, "brew tap -- d12frosted/emacs-plus").?;
    const trust = indexOfCall(fake, "brew trust --formula -- d12frosted/emacs-plus/emacs-plus@30").?;
    const install = indexOfCall(fake, "brew install -- d12frosted/emacs-plus/emacs-plus@30").?;
    try std.testing.expect(tap < trust);
    try std.testing.expect(trust < install);
}

test "apply: a formula installed as a dependency is marked on request, not reinstalled" {
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
        \\name = "brotli"
        \\
    );

    // brotli is in the Cellar but nothing asked for it by name, so the row is
    // missing. `brew install` on it exits 0 having done nothing, which would
    // leave the row missing after a run that called it installed.
    const fake = try brewWithInstalled(a, "brotli\n", "", "", &.{
        .{ .argv = "brew tab --installed-on-request --formula -- brotli" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(fake.called("brew tab --installed-on-request --formula -- brotli"));
    try std.testing.expect(!fake.called("brew install -- brotli"));
    // Said as what it was: the package was there before the run, so the
    // summary counts it apart from what mox put on the machine.
    try std.testing.expect(std.mem.indexOf(u8, r.err, "marking it as installed on request instead") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        r.out,
        "Packages: 0 installed, 0 failed, 1 already on the machine",
    ) != null);
    // What a mark leaves behind differs by manager -- brew and the distro
    // managers record who asked for the package, winget records nothing --
    // so the one summary every manager shares claims no record at all, and
    // the per-row message above says what this one did.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "recorded as asked for") == null);
}

test "apply: a formula that cannot be marked on request is a failure, not a clean run" {
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
        \\name = "brotli"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    );

    // A brew too old to have `brew tab` cannot converge the row at all, so
    // the run must say so rather than fall back to an install that does
    // nothing and report it as one that worked. The row beside it is absent
    // and installs cleanly: that one is not the failed row's to drag down,
    // and the summary must count it as installed rather than hedge over it.
    const fake = try brewWithInstalled(a, "brotli\n", "", "", &.{
        .{ .argv = "brew tab --installed-on-request --formula -- brotli", .code = 1 },
        .{ .argv = "brew install -- ripgrep" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(r.rc != 0);
    try std.testing.expect(!fake.called("brew install -- brotli"));
    try std.testing.expect(fake.called("brew install -- ripgrep"));
    try std.testing.expect(std.mem.indexOf(u8, r.err, "could not be marked as installed on request") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 1 installed, 1 failed\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "may have landed") == null);
}

/// The position of the first call matching `argv`, or null.
fn indexOfCall(fake: *const mox.packages.exec.Fake, argv: []const u8) ?usize {
    for (fake.calls.items, 0..) |c, i| {
        if (std.mem.eql(u8, c, argv)) return i;
    }
    return null;
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
    try entries.append(a, .{ .argv = "zypper --version", .fail = error.FileNotFound });
    try entries.append(a, .{ .argv = "dnf --version", .stdout = "4.18.0\n" });
    try entries.append(a, .{
        .argv = "dnf -q --assumeno repoquery --userinstalled --qf %{name}\n",
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
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n", .match = .prefix },
        .{ .argv = "sudo dnf install -y --setopt=assumeno=0 ripgrep" },
        .{ .argv = "dnf install -y --setopt=assumeno=0 ripgrep" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const s = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, s.out, "MISSING   dnf ripgrep") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.out, "UNTRACKED dnf htop") != null);

    // The install first asks dnf whether the name is a package at all: an
    // rpm virtual provide is spelled like one and would otherwise install a
    // package of another name.
    const fake2 = try dnfWith(a, "bat\nhtop\n", &.{
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n ripgrep", .stdout = "ripgrep\n" },
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n", .match = .prefix },
        .{ .argv = "sudo dnf install -y --setopt=assumeno=0 ripgrep" },
        .{ .argv = "dnf install -y --setopt=assumeno=0 ripgrep" },
    });
    useFake(fake2);
    _ = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(fake2.called("sudo dnf install -y --setopt=assumeno=0 ripgrep"));
}

test "apply: a row the manager already has is counted apart from the one it installed" {
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
        \\name = "groff-base"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    );

    // groff-base is on the machine as man-db's dependency, so nothing asked
    // for it and the row is missing; ripgrep is not there at all. Only the
    // second is something mox installs.
    const fake = try dnfWith(a, "bat\n", &.{
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n groff-base ripgrep", .stdout = "groff-base\n" },
        .{ .argv = "sudo dnf mark install --setopt=assumeno=0 groff-base" },
        .{ .argv = "dnf mark install --setopt=assumeno=0 groff-base" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n ripgrep", .stdout = "ripgrep\n" },
        .{ .argv = "sudo dnf install -y --setopt=assumeno=0 ripgrep" },
        .{ .argv = "dnf install -y --setopt=assumeno=0 ripgrep" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(
        u8,
        r.out,
        "Packages: 1 installed, 0 failed, 1 already on the machine",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "marking it user installed") != null);
}

test "apply: a check that could not run reports nothing landed" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "fedora.toml", "backend = \"dnf\"\n\n[[packages]]\nname = \"ripgrep\"\n");

    // The check that runs before the install fails. No install argv was ever
    // built, so the machine is exactly as it was, and a hedge about rows that
    // may have landed would send the user looking for a change nothing made.
    const fake = try dnfWith(a, "bat\n", &.{
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n ripgrep" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n ripgrep", .code = 1 },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 0 installed, 1 failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "may have landed") == null);
}

test "apply: a mark that fails is one row's failure, and the rows beside it are reported as they landed" {
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
        \\name = "groff-base"
        \\
        \\[[packages]]
        \\name = "less"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    );

    // groff-base and less are on the machine as dependencies; the mark takes
    // on less and not on groff-base, and ripgrep installs. Two rows converged
    // for certain, so the summary must say so, and only the failed mark is a
    // failure -- not the batch, and not "may have landed" over rows that did.
    const fake = try dnfWith(a, "bat\n", &.{
        .{ .argv = "dnf -q --assumeno repoquery --installed --qf %{name}\n groff-base less ripgrep", .stdout = "groff-base\nless\n" },
        .{ .argv = "sudo dnf mark install --setopt=assumeno=0 groff-base", .code = 1 },
        .{ .argv = "dnf mark install --setopt=assumeno=0 groff-base", .code = 1 },
        .{ .argv = "sudo dnf mark install --setopt=assumeno=0 less" },
        .{ .argv = "dnf mark install --setopt=assumeno=0 less" },
        .{ .argv = "dnf -q --assumeno repoquery --qf %{name}\n ripgrep", .stdout = "ripgrep\n" },
        .{ .argv = "sudo dnf install -y --setopt=assumeno=0 ripgrep" },
        .{ .argv = "dnf install -y --setopt=assumeno=0 ripgrep" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(r.rc != 0);
    try std.testing.expect(std.mem.indexOf(
        u8,
        r.out,
        "Packages: 1 installed, 1 failed, 1 already on the machine",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "may have landed") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "\"groff-base\" could not be marked user installed, so the row stays missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "install failed") == null);
}

test "apply --dry-run: says which rows it left unchecked" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "fedora.toml", "backend = \"dnf\"\n\n[[packages]]\nname = \"zlib-devel\"\n");

    // A row a real apply refuses -- an rpm capability, not a package -- is
    // still listed as one the run would install, because the check that
    // refuses it needs the manager. Nothing is scripted past the report, so a
    // dry run that asked dnf anything would error out here.
    const fake = try dnfWith(a, "bat\n", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply", "--dry-run" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "would install   dnf zlib-devel") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        r.out,
        "note            a dry run leaves these rows unchecked against what dnf already has installed, and the packages and provisions its repositories carry; a real apply checks them there, and marks or refuses a row those checks say not to install\n",
    ) != null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
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
    for ([_][]const u8{
        "brew --version",
        "apt-get --version",
        "dnf --version",
        "pacman --version",
        "zypper --version",
    }) |argv| {
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
        \\{ "apps": [ { "Name": "7zip", "Source": "main" }, { "Name": "Curl", "Source": "main" } ] }
    ;
    const fake = try windowsWith(a, export_json, &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const s = try h.run(&.{ "mox", "status" });
    // `7zip` is declared and installed; `firefox` is declared only; `curl` is
    // installed only, and under a spelling scoop treats as the same app.
    try std.testing.expect(std.mem.indexOf(u8, s.out, "MISSING   scoop firefox") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.out, "UNTRACKED scoop curl") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.out, "scoop 7zip") == null);

    const fake2 = try windowsWith(a, export_json, &.{
        .{ .argv = "scoop bucket list", .stdout = "main\n" },
        .{ .argv = "scoop bucket known", .stdout = "main\nextras\nversions\n" },
        .{ .argv = "scoop bucket add extras" },
        .{ .argv = "scoop install --no-update-scoop extras/firefox" },
    });
    useFake(fake2);
    _ = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(fake2.called("scoop bucket add extras"));
    try std.testing.expect(fake2.called("scoop install --no-update-scoop extras/firefox"));
}

test "windows: a scoop row spelled in another case is the app scoop has" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // The `nerd-fonts` bucket names its manifests `FiraCode-NF`, and scoop's
    // namespace is case-insensitive, so a row spelled either way is the app
    // scoop installed. Compared byte-exact the row is BOTH missing and
    // untracked, apply runs an install scoop exits 0 without doing, and the
    // next status says missing again -- for ever, at exit 0 each time.
    try writeManifest(io, h, a, "windows.toml",
        \\backend = "scoop"
        \\
        \\[[packages]]
        \\name = "firacode-nf"
        \\bucket = "nerd-fonts"
        \\
    );

    const fake = try windowsWith(a,
        \\{ "apps": [ { "Info": "", "Name": "FiraCode-NF", "Source": "nerd-fonts" } ] }
    , &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const s = try h.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 0), s.rc);
    try std.testing.expect(std.mem.indexOf(u8, s.out, "MISSING") == null);
    try std.testing.expect(std.mem.indexOf(u8, s.out, "UNTRACKED") == null);
}

test "windows: two scoop rows differing only in case are one duplicate" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // Two rows for one package: scoop installs one app, so whichever is
    // second could only ever be reported missing or reinstalled.
    try writeManifest(io, h, a, "windows.toml",
        \\backend = "scoop"
        \\
        \\[[packages]]
        \\name = "Ripgrep"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    );

    const fake = try windowsWith(a, "{ \"apps\": [] }", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const s = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(
        u8,
        s.err,
        "both declare \"ripgrep\" for backend \"scoop\" with the same gate",
    ) != null);
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

test "bootstrap: a manager that is absent is installed from the declared installer" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    const installer = "#!/bin/bash\necho installing brew\n";
    const hex = mox.apply.applied.contentHashHex(installer);
    const body = try std.fmt.allocPrint(a,
        \\backend = "brew"
        \\
        \\[[bootstrap]]
        \\url = "https://example.invalid/install.sh"
        \\sha256 = "{s}"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    , .{hex});
    try writeManifest(io, h, a, "darwin.toml", body);

    // brew is absent, so the run must install it before anything else. The
    // scripted curl writes the installer that the digest above covers, the
    // scripted interpreter stands in for running it, and brew answers from
    // then on (by whichever path the adapter now invokes it).
    // The scripted installer leaves `brew` where the adapter looks for it.
    const prefix_bin = try std.fs.path.join(a, &.{ h.state, "prefix", "bin" });
    try Io.Dir.cwd().createDirPath(io, prefix_bin);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ prefix_bin, "brew" }), .data = "" });
    mox.cli.app.brew_prefixes_override = &.{prefix_bin};
    defer mox.cli.app.brew_prefixes_override = null;
    const staged = try std.fs.path.join(a, &.{
        h.state,                                                                           "tmp",
        try std.fmt.allocPrint(a, "brew-installer-{d}", .{mox.packages.exec.processId()}),
    });
    const interpreter = try std.fmt.allocPrint(a, "env NONINTERACTIVE=1 /bin/bash {s}", .{staged});
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "brew --version", .fail = error.FileNotFound, .once = true });
    try absentLinuxManagers(a, &entries);
    try entries.append(a, .{ .argv = "curl -fsSL -o", .match = .prefix, .stdout = installer, .write_after = "-o", .io = io });
    try entries.append(a, .{ .argv = interpreter });
    try entries.append(a, .{ .argv = "brew --version", .match = .suffix, .stdout = "Homebrew 6.0.0\n" });
    try entries.append(a, .{ .argv = "brew list --full-name --installed-on-request", .match = .suffix, .stdout = "" });
    try entries.append(a, .{ .argv = "brew list --cask --full-name", .match = .suffix, .stdout = "" });
    try entries.append(a, .{ .argv = "brew list --formula --full-name", .match = .suffix, .stdout = "" });
    try entries.append(a, .{ .argv = "brew info --json=v2 --formula -- ripgrep", .match = .suffix, .code = 1 });
    try entries.append(a, .{ .argv = "brew install -- ripgrep", .match = .suffix });
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    mox.cli.app.package_runner_override = fake.runner();
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    // curl was asked for the declared URL, under the size cap.
    var fetched = false;
    for (fake.calls.items) |c| {
        if (std.mem.startsWith(u8, c, "curl ") and
            std.mem.indexOf(u8, c, " --max-filesize ") != null and
            std.mem.endsWith(u8, c, " https://example.invalid/install.sh")) fetched = true;
    }
    try std.testing.expect(fetched);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "bootstrapping   brew") != null);
    // The verified file is what the interpreter ran, and it is gone once the
    // install has ended.
    try std.testing.expect(fake.called(interpreter));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, staged, .{}));
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

test "status: an absent manager apply would bootstrap is not a clean machine" {
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
        \\[[bootstrap]]
        \\url = "https://example.invalid/install.sh"
        \\sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    );

    // brew is absent and nothing else is usable; no list is scripted, so a
    // query of the absent manager would fail the run with a different error.
    const fake = try noManagers(a);
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "note      brew: absent; apply will bootstrap it\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "MISSING   brew ripgrep\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "no package manager is usable") == null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);

    const j = try h.run(&.{ "mox", "status", "--json" });
    try std.testing.expect(std.mem.indexOf(
        u8,
        j.out,
        "{\"backend\":\"brew\",\"state\":\"missing\",\"id\":\"ripgrep\",\"name\":\"ripgrep\"}",
    ) != null);
    try std.testing.expectEqual(@as(u8, 1), j.rc);
}

test "apply: a batch refused before it ran is not reported as maybe landed" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // zypper refuses a selector row before asking zypper anything, so nothing
    // it named can have landed. Saying otherwise hedges about work that never
    // happened.
    try writeManifest(io, h, a, "suse.toml", "backend = \"zypper\"\n\n[[packages]]\nname = \"vim\"\nkind = \"nonsense\"\n");

    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "zypper --version", .stdout = "zypper 1.14.0\n" });
    try entries.append(a, .{ .argv = "rpm -qa --qf %{NAME}\\n", .stdout = "" });
    try entries.append(a, .{ .argv = "brew --version", .code = 127 });
    try entries.append(a, .{ .argv = "apt-get --version", .code = 127 });
    try entries.append(a, .{ .argv = "dnf --version", .code = 127 });
    try entries.append(a, .{ .argv = "pacman --version", .code = 127 });
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "may have landed") == null);
}

test "commit: a declared row its own backend would refuse is not written" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "debian.toml", "backend = \"apt\"\n");

    // The manager reports an installed package whose name an apt install
    // would read as a request to remove it. Writing that row would leave a
    // file every later command refuses, and no mox command could repair it.
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "apt-get --version", .stdout = "apt 2.6.1\n" });
    try entries.append(a, .{ .argv = "apt-mark showmanual", .stdout = "nano-\n" });
    try entries.append(a, .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" });
    try entries.append(a, .{ .argv = "apt-config dump APT::Architecture", .stdout = "APT::Architecture \"arm64\";\n" });
    try entries.append(a, .{ .argv = apt_installed_call, .stdout = "nano- arm64 install ok installed\n" });
    try entries.append(a, .{ .argv = "brew --version", .code = 127 });
    try entries.append(a, .{ .argv = "dnf --version", .code = 127 });
    try entries.append(a, .{ .argv = "pacman --version", .code = 127 });
    try entries.append(a, .{ .argv = "zypper --version", .code = 127 });
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.runWithInput(&.{ "mox", "commit" }, "y\n");
    try std.testing.expect(std.mem.indexOf(u8, r.err, "the row it declares would be refused") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "does not end with \"-\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "recorded in") == null);
    // The file is exactly what it was: no row, and nothing to repair.
    const after = try readManifest(io, h, a, "debian.toml");
    try std.testing.expectEqualStrings("backend = \"apt\"\n", after);
}

test "commit: a foreign-architecture package apt reports is recorded, not refused" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "debian.toml", "backend = \"apt\"\n");

    // `apt-mark showmanual` is mox's own explicit-install query, and on any
    // multiarch machine it answers with names like this one. A row it cannot
    // write is drift no command could ever clear.
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "apt-get --version", .stdout = "apt 2.6.1\n" });
    try entries.append(a, .{ .argv = "apt-mark showmanual", .stdout = "libc6:armhf\n" });
    try entries.append(a, .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" });
    try entries.append(a, .{ .argv = "apt-config dump APT::Architecture", .stdout = "APT::Architecture \"arm64\";\n" });
    try entries.append(a, .{ .argv = apt_installed_call, .stdout = "libc6 arm64 install ok installed\nlibc6 armhf install ok installed\n" });
    try entries.append(a, .{ .argv = "brew --version", .code = 127 });
    try entries.append(a, .{ .argv = "dnf --version", .code = 127 });
    try entries.append(a, .{ .argv = "pacman --version", .code = 127 });
    try entries.append(a, .{ .argv = "zypper --version", .code = 127 });
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.runWithInput(&.{ "mox", "commit" }, "y\n");
    try std.testing.expect(std.mem.indexOf(u8, r.err, "would be refused") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "recorded in") != null);
    const after = try readManifest(io, h, a, "debian.toml");
    try std.testing.expect(std.mem.indexOf(u8, after, "name = \"libc6:armhf\"") != null);
}

test "status: one backend failing a verb does not throw away what the others answered" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // Both backends are named, so both are this repo's business: a manager no
    // row asks anything of is a note, not drift, and would prove nothing here.
    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"ripgrep\"\n");
    try writeManifest(io, h, a, "debian.toml", "backend = \"apt\"\n\n[[packages]]\nname = \"ripgrep\"\n");

    // brew answers everything; a second manager answers its probe and then
    // fails the query. One manager that cannot answer is that manager's
    // problem: reporting it as a refusal of the whole pass would discard
    // every row brew just computed and describe a machine nobody looked at.
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "brew --version", .stdout = "Homebrew 4.0.0\n" });
    try entries.append(a, .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 brew list --full-name --installed-on-request", .stdout = "agg\n" });
    try entries.append(a, .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask --full-name", .stdout = "" });
    try entries.append(a, .{ .argv = "apt-get --version", .stdout = "apt 2.6.1\n" });
    try entries.append(a, .{ .argv = "apt-mark showmanual", .code = 7 });
    try entries.append(a, .{ .argv = "dnf --version", .code = 127 });
    try entries.append(a, .{ .argv = "pacman --version", .code = 127 });
    try entries.append(a, .{ .argv = "zypper --version", .code = 127 });
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    // brew's own drift survives, and apt says what it could not do.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "MISSING   brew ripgrep") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "UNTRACKED brew agg") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "BROKEN    apt (list: the manager's own listing exited nonzero, saying why above)") != null);
    // Not a refusal: the pass reached every backend and reported each one.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "was refused") == null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);

    const pw = try h.run(&.{ "mox", "status", "--porcelain" });
    try expectPorcelain(pw.out);
    try std.testing.expect(std.mem.indexOf(u8, pw.out, "package_missing\tbrew\tripgrep\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pw.out, "package_untracked\tbrew\tagg\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pw.out, "package_refused") == null);
    try std.testing.expect(std.mem.indexOf(u8, pw.out, "package_broken\tapt\t-\tlist\tthe manager's own listing exited nonzero, saying why above\n") != null);
}

test "status: a broken manager is BROKEN drift in every format, and no usable manager is said" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"ripgrep\"\n");

    // brew is there, but its own version query fails.
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "brew --version", .code = 1 });
    try absentLinuxManagers(a, &entries);
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    // A broken manager is not a clean machine: a row, and the exit code.
    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  BROKEN    brew (brew --version exited 1)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "note      no package manager is usable on this machine\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "treated as absent") == null);
    try std.testing.expect(!fake.called("env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 brew list --full-name --installed-on-request"));
    try std.testing.expectEqual(@as(u8, 1), r.rc);

    // Machine formats carry it as a record, keep stdout pure, and put the
    // notes on stderr.
    const p = try h.run(&.{ "mox", "status", "--porcelain" });
    try expectPorcelain(p.out);
    try std.testing.expect(std.mem.indexOf(u8, p.out, "package_broken\tbrew\t1\tbrew --version\t\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.out, "note") == null);
    try std.testing.expect(std.mem.indexOf(u8, p.err, "mox status: note: no package manager is usable on this machine\n") != null);
    try std.testing.expectEqual(@as(u8, 1), p.rc);

    const j = try h.run(&.{ "mox", "status", "--json" });
    try std.testing.expect(std.mem.indexOf(u8, j.out, "{\"backend\":\"brew\",\"state\":\"broken\",\"exit\":1,\"probe\":\"brew --version\"}") != null);
    try std.testing.expectEqual(@as(u8, 1), j.rc);
}

test "bootstrap: a manager already present is left alone" {
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
        \\[[bootstrap]]
        \\url = "https://example.invalid/install.sh"
        \\sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    );

    // brew answers, so nothing should be fetched; the Fake has no curl entry,
    // so an attempt would error rather than pass unnoticed.
    const fake = try brewWith(a, "ripgrep\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    for (fake.calls.items) |c| {
        try std.testing.expect(std.mem.indexOf(u8, c, "example.invalid") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, r.out, "bootstrapping") == null);
    // The package pass still ran over the manager that was already there.
    try std.testing.expect(fake.called("env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 brew list --full-name --installed-on-request"));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 0 installed, 0 failed") != null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

test "bootstrap: a bad digest refuses and the installer never runs" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // The digest names something other than what the fetch produces.
    try writeManifest(io, h, a, "darwin.toml",
        \\backend = "brew"
        \\
        \\[[bootstrap]]
        \\url = "https://example.invalid/install.sh"
        \\sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    );

    // The scripted curl delivers something else entirely.
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "brew --version", .fail = error.FileNotFound });
    try absentLinuxManagers(a, &entries);
    try entries.append(a, .{ .argv = "curl -fsSL -o", .match = .prefix, .stdout = "#!/bin/bash\necho substituted\n", .write_after = "-o", .io = io });
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    mox.cli.app.package_runner_override = fake.runner();
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    var fetched = false;
    for (fake.calls.items) |c| {
        if (std.mem.startsWith(u8, c, "curl ")) fetched = true;
        // Nothing was executed: no interpreter was ever invoked on the staged file.
        try std.testing.expect(std.mem.indexOf(u8, c, "/bin/bash") == null);
    }
    try std.testing.expect(fetched);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mox apply: brew: bootstrap failed: the installer that came back is not the one the manifest's sha256 names") != null);
    // The substituted file is not left where a later run could find it.
    const staged = try std.fs.path.join(a, &.{
        h.state,                                                                           "tmp",
        try std.fmt.allocPrint(a, "brew-installer-{d}", .{mox.packages.exec.processId()}),
    });
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, staged, .{}));
    try std.testing.expectEqual(@as(u8, 2), r.rc);
}

/// A real plugin, a POSIX sh script, exercised through the real process
/// runner: discovery, the protocol, drift, install and reconcile, with no
/// scripted stand-in anywhere. Its "manager" is a file beside it, so the
/// round trip is observable and nothing on the host is touched.
const fakeports_sh =
    \\#!/bin/sh
    \\set -eu
    \\state="$(dirname "$0")/../../.fakeports-state"
    \\cmd=${1:-}; shift || true
    \\idof() { n=$(printf '%s' "$1" | sed -n 's/.*name = "\([^"]*\)".*/\1/p'); case "$1" in *'kind = "cask"'*) echo "cask:$n";; *) echo "$n";; esac; }
    \\case "$cmd" in
    \\available) exit 0 ;;
    \\id) while IFS= read -r l; do [ -n "$l" ] || continue; case "$l" in *'kind = "keg"'*) echo "fakeports: kind keg is not a thing" >&2; exit 1;; esac; idof "$l"; done ;;
    \\list) [ -f "$state" ] && cat "$state" || true ;;
    \\install) while IFS= read -r l; do [ -n "$l" ] || continue; idof "$l" >> "$state"; done ;;
    \\declare) case "$1" in cask:*) printf 'name = "%s"\nkind = "cask"\n' "${1#cask:}";; *) printf 'name = "%s"\n' "$1";; esac ;;
    \\limitation) echo "variants are not tracked" ;;
    \\*) exit 64 ;;
    \\esac
    \\
;

/// An executable `scripts/backends/<name>` holding `body`.
fn writePlugin(io: Io, h: Harness, a: std.mem.Allocator, name: []const u8, body: []const u8) !void {
    const dir = try std.fs.path.join(a, &.{ h.repo, "scripts", "backends" });
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(a, &.{ dir, name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
    try Io.Dir.cwd().setFilePermissions(io, path, Io.File.Permissions.fromMode(0o755), .{});
}

fn installPlugin(io: Io, h: Harness, a: std.mem.Allocator) !void {
    try writePlugin(io, h, a, "fakeports", fakeports_sh);
}

/// A run whose plugins really execute, with every shipped manager stubbed
/// absent: a directory of `brew`, `apt-get`, ... that each exit 1 leads a
/// PATH holding only the system tools a plugin's `sh` needs beside them. A
/// child's argv[0] resolves against the environment of the Io that spawns
/// it, not the environment the child is handed, so the stubs reach mox
/// through an Io built around that PATH; the same PATH goes to the child, so
/// a plugin sees the machine mox saw.
const Hermetic = struct {
    threaded: *Io.Threaded,
    io: Io,
    /// The PATH entry for `SetupOpts.extra_env`.
    env: []const testutil.EnvPair,

    fn deinit(self: *Hermetic) void {
        self.threaded.deinit();
    }
};

fn hermetic(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir) !Hermetic {
    const cwd = try std.process.currentPathAlloc(io, a);
    const bin = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "bin" });
    try Io.Dir.cwd().createDirPath(io, bin);
    for ([_][]const u8{ "brew", "apt-get", "dnf", "pacman", "zypper", "scoop", "winget" }) |name| {
        const path = try std.fs.path.join(a, &.{ bin, name });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "#!/bin/sh\nexit 1\n" });
        try Io.Dir.cwd().setFilePermissions(io, path, Io.File.Permissions.fromMode(0o755), .{});
    }
    const path_value = try std.fmt.allocPrint(a, "{s}:/usr/bin:/bin", .{bin});
    const entry = try std.fmt.allocPrintSentinel(a, "PATH={s}", .{path_value}, 0);
    const block = try a.allocSentinel(?[*:0]const u8, 1, null);
    block[0] = entry.ptr;
    const environ: std.process.Environ = if (@import("builtin").os.tag == .windows) .empty else .{ .block = .{ .slice = block } };
    const threaded = try a.create(Io.Threaded);
    threaded.* = .init(std.testing.allocator, .{ .environ = environ });
    const env = try a.dupe(testutil.EnvPair, &.{.{ .name = "PATH", .value = path_value }});
    return .{ .threaded = threaded, .io = threaded.io(), .env = env };
}

test "plugin: a repo executable is a first-class backend through the whole loop" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });
    try installPlugin(io, h, a);

    // No runner override: the plugin really runs.
    try writeManifest(io, h, a, "ports.toml",
        \\backend = "fakeports"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
        \\[[packages]]
        \\name = "ghostty"
        \\kind = "cask"
        \\
    );

    // Declared, nothing installed: both MISSING, the limitation printed.
    const s1 = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, s1.out, "MISSING   fakeports ripgrep") != null);
    try std.testing.expect(std.mem.indexOf(u8, s1.out, "MISSING   fakeports ghostty") != null);
    try std.testing.expect(std.mem.indexOf(u8, s1.out, "variants are not tracked") != null);

    // apply hands both rows to `install`; the cask reaches it as a cask.
    const ap = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(std.mem.indexOf(u8, ap.out, "Packages: 2 installed, 0 failed") != null);
    const state_path = try std.fs.path.join(a, &.{ h.repo, ".fakeports-state" });
    const state = try Io.Dir.cwd().readFileAlloc(io, state_path, a, .limited(1 << 20));
    try std.testing.expectEqualStrings("ripgrep\ncask:ghostty\n", state);

    // The loop closes: what install recorded is what list reports, and that
    // matches the rows through `id`.
    const s2 = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, s2.out, "clean     fakeports") != null);

    // Something installed by hand shows as untracked; commit records it
    // through `declare`, and the round trip must hold for a cask.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = state_path, .data = "ripgrep\ncask:ghostty\ncask:zed\n" });
    const s3 = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, s3.out, "UNTRACKED fakeports cask:zed") != null);

    const c = try h.runWithInput(&.{ "mox", "commit" }, "y\n");
    try std.testing.expect(std.mem.indexOf(u8, c.out, "1 recorded") != null);
    const after = try readManifest(io, h, a, "ports.toml");
    try std.testing.expect(std.mem.endsWith(u8, after, "[[packages]]\nname = \"zed\"\nkind = \"cask\"\n"));

    const s4 = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, s4.out, "UNTRACKED") == null);
}

test "plugin: a row the plugin refuses is refused on every machine, in its own words" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });
    try installPlugin(io, h, a);

    try writeManifest(io, h, a, "ports.toml",
        \\backend = "fakeports"
        \\
        \\[[packages]]
        \\name = "ghostty"
        \\kind = "keg"
        \\
    );

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "refused by plugin fakeports") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
}

test "plugin: a name shadowing a shipped backend is announced, not silent" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });

    // The same script, named `brew`: it now stands in for the built-in.
    try writePlugin(io, h, a, "brew", fakeports_sh);
    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n");
    // Its "manager" already holds something, so the override answering is
    // visible as an untracked row the stubbed built-in could never report.
    const state = try std.fs.path.join(a, &.{ h.repo, ".fakeports-state" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = state, .data = "sbcl\n" });

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "overrides the built-in") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "UNTRACKED brew sbcl") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
}

test "bootstrap: an absent manager is installed and used by the same apply" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    const installer = "#!/bin/bash\necho installing brew\n";
    const hex = mox.apply.applied.contentHashHex(installer);
    try writeManifest(io, h, a, "darwin.toml", try std.fmt.allocPrint(a,
        \\backend = "brew"
        \\
        \\[[bootstrap]]
        \\url = "https://example.invalid/install.sh"
        \\sha256 = "{s}"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    , .{hex}));

    // The scripted installer leaves `brew` where the adapter looks for it.
    const prefix_bin = try std.fs.path.join(a, &.{ h.state, "prefix", "bin" });
    try Io.Dir.cwd().createDirPath(io, prefix_bin);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ prefix_bin, "brew" }), .data = "" });
    mox.cli.app.brew_prefixes_override = &.{prefix_bin};
    defer mox.cli.app.brew_prefixes_override = null;
    // brew is absent exactly once; the fetch writes the installer the digest
    // covers; the installer runs; then brew answers, by whichever path the
    // adapter now invokes it, and the run installs the package.
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "brew --version", .fail = error.FileNotFound, .once = true });
    try absentLinuxManagers(a, &entries);
    try entries.append(a, .{ .argv = "curl -fsSL -o", .match = .prefix, .stdout = installer, .write_after = "-o", .io = io });
    try entries.append(a, .{ .argv = "env NONINTERACTIVE=1 /bin/bash", .match = .prefix });
    try entries.append(a, .{ .argv = "brew --version", .match = .suffix, .stdout = "Homebrew 6.0.0\n" });
    try entries.append(a, .{ .argv = "brew list --full-name --installed-on-request", .match = .suffix, .stdout = "" });
    try entries.append(a, .{ .argv = "brew list --cask --full-name", .match = .suffix, .stdout = "" });
    try entries.append(a, .{ .argv = "brew list --formula --full-name", .match = .suffix, .stdout = "" });
    try entries.append(a, .{ .argv = "brew info --json=v2 --formula -- ripgrep", .match = .suffix, .code = 1 });
    try entries.append(a, .{ .argv = "brew install -- ripgrep", .match = .suffix });
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    mox.cli.app.package_runner_override = fake.runner();
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "bootstrapping   brew") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 1 installed, 0 failed") != null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

test "apply: a gate on a tool a pre-script published holds for the packages of the same run" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });
    try installPlugin(io, h, a);

    // The pre stage installs a tool and publishes its directory; a row
    // gated on that tool must be installed by this same apply, not the next.
    const pre_dir = try std.fs.path.join(a, &.{ h.repo, "scripts", "pre" });
    try Io.Dir.cwd().createDirPath(io, pre_dir);
    const pre = try std.fs.path.join(a, &.{ pre_dir, "00-tool.sh" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = pre, .data =
        \\#!/bin/sh
        \\set -eu
        \\mkdir -p "$MOX_STATE_DIR/tools"
        \\printf '#!/bin/sh\n' > "$MOX_STATE_DIR/tools/zzfoo"
        \\chmod +x "$MOX_STATE_DIR/tools/zzfoo"
        \\printf '%s\n' "$MOX_STATE_DIR/tools" >> "$MOX_PATH"
        \\
    });
    try Io.Dir.cwd().setFilePermissions(io, pre, Io.File.Permissions.fromMode(0o755), .{});
    try writeManifest(io, h, a, "ports.toml",
        \\backend = "fakeports"
        \\
        \\[[packages]]
        \\name = "plain"
        \\
        \\[[packages]]
        \\name = "needs-foo"
        \\when = "tool=zzfoo"
        \\
    );

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "installing      fakeports needs-foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 2 installed, 0 failed") != null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

test "apply: a batch that failed after landing a row says so, and the landed row is seen after" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });

    // `install` lands the first row as a tool on PATH and then fails, so the
    // batch is a failure that changed the machine.
    try writePlugin(io, h, a, "halfway",
        \\#!/bin/sh
        \\case "${1:-}" in
        \\available) exit 0 ;;
        \\id) while IFS= read -r l; do [ -n "$l" ] || continue; printf '%s\n' "$l" | sed -n 's/.*name = "\([^"]*\)".*/\1/p'; done ;;
        \\list) ;;
        \\install) mkdir -p "$MOX_STATE_DIR/tools"; printf '#!/bin/sh\n' > "$MOX_STATE_DIR/tools/zzlanded"; chmod +x "$MOX_STATE_DIR/tools/zzlanded"; printf '%s\n' "$MOX_STATE_DIR/tools" >> "$MOX_PATH"; exit 1 ;;
        \\*) exit 64 ;;
        \\esac
        \\
    );
    try writeManifest(io, h, a, "h.toml", "backend = \"halfway\"\n\n[[packages]]\nname = \"one\"\n\n[[packages]]\nname = \"two\"\n");
    const seen = try std.fs.path.join(a, &.{ h.state, "seen.txt" });
    const post_dir = try std.fs.path.join(a, &.{ h.repo, "scripts", "post" });
    try Io.Dir.cwd().createDirPath(io, post_dir);
    const post = try std.fs.path.join(a, &.{ post_dir, "00-record.sh" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = post, .data = try std.fmt.allocPrint(
        a,
        "#!/bin/sh\ncommand -v zzlanded > \"{s}\" || echo missing > \"{s}\"\n",
        .{ seen, seen },
    ) });
    try Io.Dir.cwd().setFilePermissions(io, post, Io.File.Permissions.fromMode(0o755), .{});

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 0 installed, 1 failed (2 row(s) in failed batches may have landed)") != null);
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    const got = try Io.Dir.cwd().readFileAlloc(io, seen, a, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, got, "zzlanded") != null);
}

test "apply: --skip-scripts and a path-scoped apply install nothing" {
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

    // Nothing is scripted: any manager call at all errors the run.
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    _ = try h.run(&.{ "mox", "apply", "--skip-scripts" });
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);

    const live = try h.liveOf("nothing-here.conf");
    _ = try h.run(&.{ "mox", "apply", live });
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "plugin: one that crashes on available is a named error, not an inert backend" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });

    // A syntax error: sh exits 2 before any verb is handled.
    try writePlugin(io, h, a, "broken", "#!/bin/sh\ncase x in\n");
    try writeManifest(io, h, a, "b.toml", "backend = \"broken\"\n\n[[packages]]\nname = \"x\"\n");

    // Whichever verb it dies on first, the error names the plugin.
    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "broken: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "failed") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    // What was about to execute is on the record before it ran and died.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "note      backend broken: scripts/backends/broken") != null);
}

test "commit: a plugin whose declare exits 64 is reported by name, and the run does not crash" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });

    try writePlugin(io, h, a, "nodeclare",
        \\#!/bin/sh
        \\case "${1:-}" in
        \\available) exit 0 ;;
        \\id) sed -n 's/.*name = "\([^"]*\)".*/\1/p' ;;
        \\list) echo stray ;;
        \\*) exit 64 ;;
        \\esac
        \\
    );
    try writeManifest(io, h, a, "n.toml", "backend = \"nodeclare\"\n");

    const r = try h.runWithInput(&.{ "mox", "commit" }, "y\n");
    try std.testing.expect(std.mem.indexOf(u8, r.err, "nodeclare stray: declare failed: PluginFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "internal error") == null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
}

test "commit --abort-on-prompt: an untracked package is a prompt, so rc 2 and the manifest is untouched" {
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

    const r = try h.run(&.{ "mox", "commit", "--abort-on-prompt" });
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "--abort-on-prompt: a package prompt was required") != null);

    const after = try readManifest(io, h, a, "darwin.toml");
    try std.testing.expectEqualStrings(original, after);
}

test "commit: q at a package prompt stops there, keeping the row already recorded and saying so" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n");

    // Offered in the order the manager lists them: htop first, then fd.
    const fake = try brewWith(a, "htop\nfd\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.runWithInput(&.{ "mox", "commit" }, "y\nq\n");
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "aborted; 1 package row(s) already recorded, no file changes written") != null);

    // The first answer was appended the moment it was given; the abort
    // reached the second before anything was written for it.
    const after = try readManifest(io, h, a, "darwin.toml");
    try std.testing.expect(std.mem.endsWith(u8, after, "[[packages]]\nname = \"htop\"\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, after, "[[packages]]"));
    try std.testing.expect(std.mem.indexOf(u8, after, "fd") == null);
}

test "plugin: a windows-only kind on unix is an inert backend with a note, not an error" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // A shared repo's Windows plugin: present here, runnable only there.
    const dir = try std.fs.path.join(a, &.{ h.repo, "scripts", "backends" });
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(a, &.{ dir, "scoopish.ps1" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "exit 0\n" });
    try writeManifest(io, h, a, "windows.toml",
        \\backend = "scoopish"
        \\
        \\[[packages]]
        \\name = "7zip"
        \\
    );

    const fake = try brewWith(a, "", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "scripts/backends/scoopish.ps1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "not runnable") != null);
    // Neither a typo nor a refusal: its row is not this machine's.
    try std.testing.expect(std.mem.indexOf(u8, r.err, "refused") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "scoopish:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "MISSING") == null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

test "plugin: finder junk beside a plugin is ignored, not read as an unexecutable backend" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });
    try installPlugin(io, h, a);

    const junk = try std.fs.path.join(a, &.{ h.repo, "scripts", "backends", ".DS_Store" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = junk, .data = "\x00\x00\x00\x01Bud1\x00" });
    try writeManifest(io, h, a, "ports.toml", "backend = \"fakeports\"\n");

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, ".DS_Store") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "NotExecutable") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "packages:") != null);
}

test "status: a repo with no manifest never discovers a plugin, let alone runs one" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // Would fail loudly if run; the repo has not adopted packages, so it
    // must not be.
    const dir = try std.fs.path.join(a, &.{ h.repo, "scripts", "backends" });
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(a, &.{ dir, "broken" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "#!/bin/sh\ncase x in\n" });
    try Io.Dir.cwd().setFilePermissions(io, path, Io.File.Permissions.fromMode(0o755), .{});

    // Any manager call errors the run too.
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "packages:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "broken") == null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "apply --dry-run: an absent manager is planned as a bootstrap, with nothing fetched, staged or installed" {
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
        \\[[bootstrap]]
        \\url = "https://example.invalid/install.sh"
        \\sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
        \\
        \\[[packages]]
        \\name = "fd"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    );

    // brew is absent; no curl and no install is scripted, so either errors.
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "brew --version", .fail = error.FileNotFound });
    try absentLinuxManagers(a, &entries);
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply", "--dry-run" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "would bootstrap brew") != null);
    // Planned as though the bootstrap had happened: every row is listed.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "would install   brew fd") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "would install   brew ripgrep") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 2 would be installed, 0 failed, after bootstrapping 1 manager(s)") != null);
    for (fake.calls.items) |c| {
        try std.testing.expect(std.mem.indexOf(u8, c, "install") == null);
        try std.testing.expect(std.mem.indexOf(u8, c, "https://example.invalid") == null);
    }
    // Nothing was staged where a real bootstrap would put the installer.
    const staged = try std.fs.path.join(a, &.{
        h.state,                                                                           "tmp",
        try std.fmt.allocPrint(a, "brew-installer-{d}", .{mox.packages.exec.processId()}),
    });
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, staged, .{}));
}

test "plugin: a verb a signal killed is not reported as one that exited nonzero" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });

    // What the out-of-memory killer does to a manager, and what a `kill` from
    // another terminal does: the verb ends without exiting and without
    // printing a word. Reported as an exit, it reads exactly like a plugin
    // that refused the query in a message above -- and there is no message.
    try writePlugin(io, h, a, "brew",
        \\#!/bin/sh
        \\case "${1:-}" in
        \\available) exit 0 ;;
        \\id) while IFS= read -r l; do case "$l" in *'name = "'*) n=${l#*name = \"}; printf '%s\n' "${n%%\"*}" ;; esac; done ;;
        \\list) kill -KILL $$ ;;
        \\*) exit 64 ;;
        \\esac
        \\exit 0
        \\
    );
    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"fd\"\n");

    const r = try h.run(&.{ "mox", "status" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "BROKEN    brew (list: it was killed by a signal rather than exiting, so it named no reason of its own") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "exited nonzero") == null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
}

test "plugin: a captured verb that stops for a terminal is ended with no bound armed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    // The bound is off, so nothing but seeing the stop can end this run. mox
    // reads a captured verb rather than waiting on it, so the stop has to be
    // noticed between reads or it is never noticed at all.
    const h = try setup(a, io, &tmp, .{
        .extra_env = &.{ herm.env[0], .{ .name = "MOX_SCRIPT_TIMEOUT_MS", .value = "0" } },
    });

    try writePlugin(io, h, a, "brew",
        \\#!/bin/sh
        \\case "${1:-}" in
        \\available) exit 0 ;;
        \\id) while IFS= read -r l; do case "$l" in *'name = "'*) n=${l#*name = \"}; printf '%s\n' "${n%%\"*}" ;; esac; done ;;
        \\list) kill -STOP $$ ;;
        \\*) exit 64 ;;
        \\esac
        \\exit 0
        \\
    );
    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"fd\"\n");

    const started = Io.Timestamp.now(io, .awake);
    const r = try h.run(&.{ "mox", "status" });
    const elapsed_ms = started.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();

    // The backend that could not answer is BROKEN, with the reason in the row
    // rather than an error that throws away every other backend's result.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "BROKEN    brew (list: stopped, and this run has no terminal that could resume it; killed)") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    // Ended on the stop itself, with nothing armed that could have ended it
    // otherwise. A regression waits forever here rather than failing, which
    // is the one case the suite cannot bound: a stop is not a resource the
    // child will ever give back.
    try std.testing.expect(elapsed_ms < 60_000);
}

test "plugin: one that hangs on available is killed at the bound, and the timeout is named" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{
        // Generous next to the sleep below: the bound must outlast a cold
        // machine's first spawn of the plugin (`id` runs before the probe),
        // and still end the hang long before it would finish on its own.
        .extra_env = &.{ herm.env[0], .{ .name = "MOX_SCRIPT_TIMEOUT_MS", .value = "1000" } },
    });

    // Named `brew` so it shadows the built-in: the first backend probed is
    // this one. `exec` so the sleeping process is the plugin itself, and the
    // kill ends it rather than orphaning a sleep holding the pipe.
    try writePlugin(io, h, a, "brew",
        \\#!/bin/sh
        \\case "${1:-}" in
        \\available) exec sleep 300 ;;
        \\id) while IFS= read -r l; do case "$l" in *'name = "'*) n=${l#*name = \"}; printf '%s\n' "${n%%\"*}" ;; esac; done ;;
        \\list) ;;
        \\*) exit 64 ;;
        \\esac
        \\exit 0
        \\
    );
    // A row names the backend, so a probe that cannot answer is the run's
    // error: the rows it governs can be neither judged nor installed.
    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"fd\"\n");

    const started = Io.Timestamp.now(io, .awake);
    const r = try h.run(&.{ "mox", "status" });
    const elapsed_ms = started.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();

    try std.testing.expect(std.mem.indexOf(u8, r.err, "brew: available failed: timed out, killed") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    // Killed at the bound, not waited out.
    try std.testing.expect(elapsed_ms < 60_000);
}

test "commit: a malformed manifest is named, and no manager is asked anything" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n[[packages]\nname = \"x\"\n");

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.runWithInput(&.{ "mox", "commit" }, "");
    try std.testing.expect(std.mem.indexOf(u8, r.err, "darwin.toml") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

/// Every shipped manager absent, and nothing else scripted: any other call
/// errors the run.
fn noManagers(a: std.mem.Allocator) !*mox.packages.exec.Fake {
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "brew --version", .fail = error.FileNotFound });
    try absentLinuxManagers(a, &entries);
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    return fake;
}

/// Every line of a porcelain report is one record -- a kind token and its
/// tab-separated fields, four for a file, three for a package and five for a
/// broken manager -- so a note or heading on stdout would break a
/// consumer's split.
fn expectPorcelain(out: []const u8) !void {
    try std.testing.expect(out.len > 0);
    try std.testing.expect(out[out.len - 1] == '\n');
    var lines = std.mem.splitScalar(u8, out[0 .. out.len - 1], '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.first();
        var n: usize = 1;
        while (fields.next()) |_| n += 1;
        const known = for ([_][]const u8{
            "whole_file",      "owned_key",         "symlink_target", "generated_set",   "vanished",
            "package_missing", "package_untracked", "package_broken", "package_refused",
        }) |k| {
            if (std.mem.eql(u8, k, kind)) break true;
        } else false;
        try std.testing.expect(known);
        // A refused pass reached no backend and no package, so the kind is the
        // whole record. A broken manager carries what it was asked and why it
        // could not answer beside the exit code, neither of which the code
        // alone can say.
        const want: usize = if (std.mem.eql(u8, kind, "package_refused"))
            1
        else if (std.mem.eql(u8, kind, "package_broken"))
            5
        else if (std.mem.startsWith(u8, kind, "package_")) 3 else 4;
        try std.testing.expectEqual(want, n);
    }
}

test "status --json / --porcelain: a plugin's note goes to stderr, and stdout stays machine-readable" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });
    try installPlugin(io, h, a);
    try writeManifest(io, h, a, "ports.toml", "backend = \"fakeports\"\n\n[[packages]]\nname = \"ripgrep\"\n");

    const note = "mox status: note: backend fakeports: scripts/backends/fakeports\n";

    const j = try h.run(&.{ "mox", "status", "--json" });
    try std.testing.expect(std.mem.startsWith(u8, j.out, "{"));
    try std.testing.expect(std.mem.indexOf(u8, j.out, "{\"backend\":\"fakeports\",\"state\":\"missing\",\"id\":\"ripgrep\",\"name\":\"ripgrep\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, j.out, "note") == null);
    try std.testing.expect(std.mem.indexOf(u8, j.out, "variants are not tracked") == null);
    try std.testing.expect(std.mem.indexOf(u8, j.err, note) != null);
    try std.testing.expectEqual(@as(u8, 1), j.rc);

    const p = try h.run(&.{ "mox", "status", "--porcelain" });
    try expectPorcelain(p.out);
    try std.testing.expect(std.mem.indexOf(u8, p.out, "package_missing\tfakeports\tripgrep\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.err, note) != null);
    try std.testing.expectEqual(@as(u8, 1), p.rc);
}

test "bootstrap: an installer declared for a plugin this machine cannot run is left to the machine that can" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    const dir = try std.fs.path.join(a, &.{ h.repo, "scripts", "backends" });
    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "scoopish.ps1" }), .data = "exit 0\n" });
    try writeManifest(io, h, a, "windows.toml",
        \\backend = "scoopish"
        \\
        \\[[bootstrap]]
        \\url = "https://example.invalid/install.ps1"
        \\sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
        \\
        \\[[packages]]
        \\name = "7zip"
        \\
    );

    // No curl is scripted: a fetch would error the run with a different
    // message than the refusal asserted here.
    const fake = try noManagers(a);
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const dry = try h.run(&.{ "mox", "apply", "--dry-run" });
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "would bootstrap") == null);
    try std.testing.expect(std.mem.indexOf(u8, dry.out, "would install") == null);
    try std.testing.expect(std.mem.indexOf(u8, dry.err, "cannot bootstrap") == null);
    try std.testing.expectEqual(@as(u8, 0), dry.rc);

    const real = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(std.mem.indexOf(u8, real.out, "bootstrapping") == null);
    try std.testing.expect(std.mem.indexOf(u8, real.out, "installing") == null);
    try std.testing.expect(std.mem.indexOf(u8, real.err, "cannot bootstrap") == null);
    try std.testing.expectEqual(@as(u8, 0), real.rc);

    for (fake.calls.items) |c| {
        try std.testing.expect(std.mem.indexOf(u8, c, "curl") == null);
        try std.testing.expect(std.mem.indexOf(u8, c, "example.invalid") == null);
    }
}

test "plugin: a not-runnable plugin's declared and blacklisted rows are not judged here" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // On the OS that can run it, the formula `x` and the cask `x` are two
    // packages; here nothing can say so, and the shared manifest must load.
    const dir = try std.fs.path.join(a, &.{ h.repo, "scripts", "backends" });
    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "fakeports.ps1" }), .data = "exit 0\n" });
    try writeManifest(io, h, a, "fake.toml",
        \\backend = "fakeports"
        \\
        \\[[packages]]
        \\name = "x"
        \\
        \\[[blacklist]]
        \\name = "x"
        \\kind = "cask"
        \\
    );

    const fake = try brewWith(a, "", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "blacklists") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "not runnable") != null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

test "status: a bootstrap row for a manager that ships with its OS is refused on every machine" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "debian.toml",
        \\backend = "apt"
        \\
        \\[[bootstrap]]
        \\url = "https://example.invalid/apt.sh"
        \\sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
        \\
    );

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "debian.toml: bootstrap row 0: backend \"apt\" cannot be bootstrapped") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "status: a path-scoped status names files and reaches no package" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"fd\"\n");
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const live = try h.liveOf("nothing-here.conf");
    const r = try h.run(&.{ "mox", "status", live });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "packages:") == null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    const p = try h.run(&.{ "mox", "status", "--porcelain", live });
    try std.testing.expect(std.mem.indexOf(u8, p.out, "package_") == null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "plugin: a not-runnable twin of a built-in is noted, and the built-in stays in use" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    const dir = try std.fs.path.join(a, &.{ h.repo, "scripts", "backends" });
    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ dir, "brew.ps1" }), .data = "exit 0\n" });
    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"htop\"\n");

    const fake = try brewWith(a, "htop\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(
        u8,
        r.out,
        "note      backend brew: scripts/backends/brew.ps1: a windows-only kind; not runnable here; the built-in stays\n",
    ) != null);
    // The built-in answered: the row is neither inert nor missing.
    try std.testing.expect(fake.called("env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 brew list --full-name --installed-on-request"));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "clean     brew") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "MISSING") == null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

test "status: an empty data/packages directory opts in, so an installed package is untracked" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ h.repo, "data", "packages" }));

    const fake = try brewWith(a, "htop\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "UNTRACKED brew htop") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
}

test "commit: an empty data/packages directory records nothing until a file declares the backend" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    const dir = try std.fs.path.join(a, &.{ h.repo, "data", "packages" });
    try Io.Dir.cwd().createDirPath(io, dir);

    const fake = try brewWith(a, "htop\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.runWithInput(&.{ "mox", "commit" }, "y\n");
    try std.testing.expect(std.mem.indexOf(u8, r.err, "no data/packages file that holds on this machine declares backend \"brew\"; add one to record its 1 untracked package(s)") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    // Nothing was created on the user's behalf.
    var d = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    try std.testing.expect((try it.next(io)) == null);
}

test "status: a bootstrap row naming no registered backend is refused before any manager is asked" {
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
        \\[[bootstrap]]
        \\backend = "brw"
        \\url = "https://example.invalid/install.sh"
        \\sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
        \\
        \\[[packages]]
        \\name = "fd"
        \\
    );

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "darwin.toml: bootstrap row 0: no backend named \"brw\"") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);

    const d = try h.run(&.{ "mox", "apply", "--dry-run" });
    try std.testing.expect(std.mem.indexOf(u8, d.err, "no backend named \"brw\"") != null);
    try std.testing.expectEqual(@as(u8, 2), d.rc);
}

test "status: a data/packages that is a file is named as not a directory, and no manager is asked" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ h.repo, "data" }));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(a, &.{ h.repo, "data", "packages" }),
        .data = "backend = \"brew\"\n",
    });

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "data/packages: not a directory") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "plugin: a row key outside the bare charset reaches the plugin quoted, as TOML reads it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });

    // `id` keeps a copy of every row it was handed.
    try writePlugin(io, h, a, "quoted",
        \\#!/bin/sh
        \\seen="$(dirname "$0")/../../.seen"
        \\case "${1:-}" in
        \\available) exit 0 ;;
        \\id) tee -a "$seen" | sed -n 's/.*name = "\([^"]*\)".*/\1/p' ;;
        \\list) ;;
        \\*) exit 64 ;;
        \\esac
        \\
    );
    try writeManifest(io, h, a, "q.toml",
        \\backend = "quoted"
        \\
        \\[[packages]]
        \\name = "x"
        \\"my key" = "v"
        \\
    );

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "id failed") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "refused") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "MISSING   quoted x") != null);

    const seen = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ h.repo, ".seen" }), a, .limited(1 << 20));
    try std.testing.expectEqualStrings("{ name = \"x\", \"my key\" = \"v\" }\n", seen);
}

test "commit: a file whose gate excludes this machine is never appended to" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // The only brew file is for another OS: a row appended there would be
    // inert on the very machine that recorded it.
    const original = "backend = \"brew\"\nwhen = \"os=linux\"\n";
    try writeManifest(io, h, a, "a.toml", original);

    const fake = try brewWith(a, "htop\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.runWithInput(&.{ "mox", "commit" }, "y\n");
    try std.testing.expect(std.mem.indexOf(u8, r.err, "no data/packages file that holds on this machine declares backend \"brew\"; add one to record its 1 untracked package(s)") != null);
    try std.testing.expectEqualStrings(original, try readManifest(io, h, a, "a.toml"));
    try std.testing.expectEqual(@as(u8, 1), r.rc);
}

test "commit: a file whose gate holds here takes the row" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    const original = "backend = \"brew\"\nwhen = \"os=darwin\"\n";
    try writeManifest(io, h, a, "a.toml", original);

    const fake = try brewWith(a, "htop\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.runWithInput(&.{ "mox", "commit" }, "y\n");
    try std.testing.expect(std.mem.indexOf(u8, r.out, "1 recorded") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "declares backend") == null);
    const after = try readManifest(io, h, a, "a.toml");
    try std.testing.expect(std.mem.startsWith(u8, after, original));
    try std.testing.expect(std.mem.endsWith(u8, after, "[[packages]]\nname = \"htop\"\n"));
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

/// A plugin whose manager exists once its home directory does: absent until
/// `bootstrap` creates it, present from then on. Nothing is ever installed
/// through it here.
const bootstrappable_sh =
    \\#!/bin/sh
    \\set -eu
    \\home="$(dirname "$0")/../../.fakemgr-home"
    \\cmd=${1:-}; shift || true
    \\case "$cmd" in
    \\available) [ -d "$home" ] ;;
    \\bootstrap) mkdir -p "$home/bin"; (cd "$home/bin" && pwd) > "$2" ;;
    \\list) ;;
    \\id) while IFS= read -r l; do [ -n "$l" ] || continue; printf '%s\n' "$l" | sed -n 's/.*name = "\([^"]*\)".*/\1/p'; done ;;
    \\declare) printf 'name = "%s"\n' "$1" ;;
    \\*) exit 64 ;;
    \\esac
    \\
;

test "bootstrap: a manager installed with no row to install still re-captures the machine" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });

    try writePlugin(io, h, a, "fakemgr", bootstrappable_sh);

    // The "download" is a curl on the hermetic PATH that writes the installer
    // the digest below covers to the `-o` path it is handed.
    const installer = "#!/bin/sh\necho installed\n";
    const hex = mox.apply.applied.contentHashHex(installer);
    const cwd = try std.process.currentPathAlloc(io, a);
    const curl = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "bin", "curl" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = curl, .data =
        \\#!/bin/sh
        \\out=
        \\while [ $# -gt 0 ]; do
        \\  if [ "$1" = "-o" ]; then out=$2; shift; fi
        \\  shift
        \\done
        \\printf '#!/bin/sh\necho installed\n' > "$out"
        \\
    });
    try Io.Dir.cwd().setFilePermissions(io, curl, Io.File.Permissions.fromMode(0o755), .{});

    try writeManifest(io, h, a, "fakemgr.toml", try std.fmt.allocPrint(a,
        \\backend = "fakemgr"
        \\
        \\[[bootstrap]]
        \\url = "https://example.invalid/install.sh"
        \\sha256 = "{s}"
        \\
    , .{hex}));

    // A fact bound by the directory the bootstrap creates, and a post script
    // that records what it was handed: only a re-capture after the bootstrap
    // can put the fresh value in the script's environment. The script's
    // reference to the fact is a contract mox checks, so a stale environment
    // blocks the script (rc 2) rather than running it with the old value.
    const home = try std.fs.path.join(a, &.{ h.repo, ".fakemgr-home" });
    const facts = try std.fs.path.join(a, &.{ h.repo, "data", "facts.toml" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = facts, .data = try std.fmt.allocPrint(
        a,
        "[[facts]]\nname = \"fakemgrhome\"\ncandidates = [\"{s}\"]\n",
        .{home},
    ) });
    const seen = try std.fs.path.join(a, &.{ h.state, "seen.txt" });
    const post_dir = try std.fs.path.join(a, &.{ h.repo, "scripts", "post" });
    try Io.Dir.cwd().createDirPath(io, post_dir);
    const post = try std.fs.path.join(a, &.{ post_dir, "00-record.sh" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = post, .data = try std.fmt.allocPrint(
        a,
        "#!/bin/sh\nprintf '%s\\n%s\\n' \"${{MOX_FACT_FAKEMGRHOME:-unset}}\" \"$PATH\" > \"{s}\"\n",
        .{seen},
    ) });
    try Io.Dir.cwd().setFilePermissions(io, post, Io.File.Permissions.fromMode(0o755), .{});

    const r = try h.run(&.{ "mox", "apply" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "bootstrapping   fakemgr") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 0 installed, 0 failed") != null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    const got = try Io.Dir.cwd().readFileAlloc(io, seen, a, .limited(1 << 20));
    var lines = std.mem.splitScalar(u8, got, '\n');
    try std.testing.expectEqualStrings(home, lines.next().?);
    // The bin dir the bootstrap reported is still on the post script's PATH
    // after the re-capture rebuilt the script environment.
    const path_line = lines.next().?;
    const bin = try std.fs.path.join(a, &.{ home, "bin" });
    try std.testing.expect(std.mem.indexOf(u8, path_line, bin) != null);
}

test "commit: a file whose only row for the backend is a blacklist entry is where its next row goes" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    const original = "[[blacklist]]\nname = \"a\"\nbackend = \"brew\"\n";
    try writeManifest(io, h, a, "x.toml", original);

    const fake = try brewWith(a, "htop\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.runWithInput(&.{ "mox", "commit" }, "y\n");
    try std.testing.expect(std.mem.indexOf(u8, r.out, "1 recorded") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "declares backend") == null);

    // Appended there, naming the backend the file does not declare.
    const after = try readManifest(io, h, a, "x.toml");
    try std.testing.expect(std.mem.startsWith(u8, after, original));
    try std.testing.expect(std.mem.endsWith(u8, after, "[[packages]]\nname = \"htop\"\nbackend = \"brew\"\n"));
}

test "plugin: a failed limitation costs its remark, not the manager's whole report" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = &.{herm.env[0]} });

    // `limitation` says what a manager cannot see and nothing is judged by
    // it, so a plugin that gets its exit code wrong there must not cost the
    // reader what is missing -- which is already computable.
    try writePlugin(io, h, a, "good",
        \\#!/bin/sh
        \\case "${1:-}" in
        \\available) exit 0 ;;
        \\id) while IFS= read -r l; do [ -n "$l" ] || continue; printf '%s\n' "$l" | sed -n 's/.*name = "\([^"]*\)".*/\1/p'; done ;;
        \\list) printf 'stray\n' ;;
        \\limitation) exit 7 ;;
        \\esac
        \\exit 0
        \\
    );
    try writeManifest(io, h, a, "g.toml", "backend = \"good\"\n\n[[packages]]\nname = \"wanted\"\n");

    const r = try h.run(&.{ "mox", "status" });
    // Judged as usual, and the failed remark is said rather than swallowed.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "MISSING   good wanted") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "UNTRACKED good stray") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "BROKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "good: limitation failed") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
}

test "plugin: a helper left holding the pipe dies with the plugin at the bound" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{
        .extra_env = &.{ herm.env[0], .{ .name = "MOX_SCRIPT_TIMEOUT_MS", .value = "3000" } },
    });

    // `sleep` keeps the pipe's write end after `sh` would have exited; a
    // kill that reached only `sh` would leave the read blocked for 12s. The
    // bound leaves room for every stub probed before this plugin: the first
    // run of a freshly written script is slow on a loaded host.
    try writePlugin(io, h, a, "pipes",
        \\#!/bin/sh
        \\case "${1:-}" in
        \\available) exit 0 ;;
        \\id) while IFS= read -r l; do [ -n "$l" ] || continue; printf '%s\n' "$l" | sed -n 's/.*name = "\([^"]*\)".*/\1/p'; done ;;
        \\list) sleep 300 | cat ;;
        \\esac
        \\exit 0
        \\
    );
    // A row names it, so what it cannot do is this repo's business: a backend
    // nothing asks anything of is a note instead.
    try writeManifest(io, h, a, "p.toml", "backend = \"pipes\"\n\n[[packages]]\nname = \"anything\"\n");

    const started = Io.Timestamp.now(io, .awake);
    const r = try h.run(&.{ "mox", "status" });
    const elapsed_ms = started.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();

    errdefer std.debug.print("stderr was:\n{s}\n", .{r.err});
    try std.testing.expect(std.mem.indexOf(u8, r.out, "BROKEN    pipes (list: timed out, killed)") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(elapsed_ms < 60_000);
}

/// `Harness.run` with the caller's own writers, for a test that needs mox's
/// stdout somewhere a child process can read it.
fn runWith(h: Harness, argv: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    const saved = mox.cli.app.environ_override;
    mox.cli.app.environ_override = h.env;
    defer mox.cli.app.environ_override = saved;

    const saved_cwd = mox.cli.app.cwd_override;
    mox.cli.app.cwd_override = h.home;
    defer mox.cli.app.cwd_override = saved_cwd;

    return mox.cli.app.run(h.a, h.io, argv, &mox.cli.app.command_table, out, err);
}

test "status: a plugin's note reaches the terminal before the plugin runs" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });

    // mox's stdout is a file here, and the plugin's first verb copies what
    // that file holds at the moment the plugin was spawned.
    const out_path = try std.fs.path.join(a, &.{ h.root, "mox-stdout.txt" });
    const copy_path = try std.fs.path.join(a, &.{ h.root, "seen-by-plugin.txt" });
    try writePlugin(io, h, a, "copier", try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\case "${{1:-}}" in
        \\available) cat "{s}" > "{s}"; exit 0 ;;
        \\list) exit 0 ;;
        \\esac
        \\exit 64
        \\
    , .{ out_path, copy_path }));
    try writeManifest(io, h, a, "c.toml", "backend = \"copier\"\n");

    const out_file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);
    // Wide enough that nothing reaches the file by overflow: only a flush
    // before the spawn can put the note there.
    var out_buf: [64 * 1024]u8 = undefined;
    var out_w = out_file.writer(io, &out_buf);
    var err_aw: Io.Writer.Allocating = .init(a);
    const rc = try runWith(h, &.{ "mox", "status" }, &out_w.interface, &err_aw.writer);
    try out_w.interface.flush();
    // The hermetic stubs are managers whose `--version` exits 1, but no row
    // names them, so they are notes rather than this repo's drift.
    try std.testing.expectEqual(@as(u8, 0), rc);

    const seen = try Io.Dir.cwd().readFileAlloc(io, copy_path, a, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, seen, "note      backend copier: scripts/backends/copier\n") != null);
}

test "commit: a row recorded into the private layer is data there, never a managed file" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // The repo opted in but declares no brew file; the private layer does,
    // so that is where commit records the row.
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ h.repo, "data", "packages" }));
    const private_pkgs = try std.fs.path.join(a, &.{ h.state, "private", "data", "packages" });
    try Io.Dir.cwd().createDirPath(io, private_pkgs);
    const private_manifest = try std.fs.path.join(a, &.{ private_pkgs, "local.toml" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = private_manifest, .data = "backend = \"brew\"\n" });

    const fake = try brewWith(a, "htop\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const c = try h.runWithInput(&.{ "mox", "commit" }, "y\n");
    try std.testing.expect(std.mem.indexOf(u8, c.out, "(private layer)") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.out, "1 recorded") != null);
    const after = try Io.Dir.cwd().readFileAlloc(io, private_manifest, a, .limited(1 << 20));
    try std.testing.expect(std.mem.endsWith(u8, after, "[[packages]]\nname = \"htop\"\n"));

    // The private root's data/ is not source: nothing under ~/data is
    // planned, and the manifest reads as clean.
    const fake2 = try brewWith(a, "htop\n", "", &.{});
    useFake(fake2);
    const s = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, s.out, "data/packages") == null);
    try std.testing.expect(std.mem.indexOf(u8, s.out, "MISSING") == null);
    try std.testing.expect(std.mem.indexOf(u8, s.out, "clean     brew") != null);
    try std.testing.expectEqual(@as(u8, 0), s.rc);

    const fake3 = try brewWith(a, "htop\n", "", &.{});
    useFake(fake3);
    const d = try h.run(&.{ "mox", "apply", "--dry-run" });
    try std.testing.expect(std.mem.indexOf(u8, d.out, "data/packages") == null);
    try std.testing.expect(std.mem.indexOf(u8, d.out, "would write") == null);
    try std.testing.expectEqual(@as(u8, 0), d.rc);

    // A symlinked private manifest is read as a manifest, not refused as a
    // symlink in the source tree.
    if (@import("builtin").os.tag == .windows) return;
    const elsewhere = try std.fs.path.join(a, &.{ h.state, "elsewhere.toml" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = elsewhere, .data = after });
    try Io.Dir.cwd().deleteFile(io, private_manifest);
    try Io.Dir.cwd().symLink(io, elsewhere, private_manifest, .{});
    const fake4 = try brewWith(a, "htop\n", "", &.{});
    useFake(fake4);
    const l = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, l.err, "SymlinkInSource") == null);
    try std.testing.expect(std.mem.indexOf(u8, l.out, "clean     brew") != null);
    try std.testing.expectEqual(@as(u8, 0), l.rc);
}

test "status: a plugin no row names failing its probe is a note, and the rest still reports" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });
    try installPlugin(io, h, a);

    // `available` exits 3: a broken plugin, which no manifest row names.
    try writePlugin(io, h, a, "crashy", "#!/bin/sh\ncase \"${1:-}\" in\navailable) exit 3 ;;\nesac\nexit 64\n");
    try writeManifest(io, h, a, "ports.toml", "backend = \"fakeports\"\n\n[[packages]]\nname = \"ripgrep\"\n");

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "note      crashy: crashy available exited 3; no row asks it to install anything, so nothing here needs it\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "crashy") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "MISSING   fakeports ripgrep") != null);
}

test "status: a manifest with [[package]] is refused rather than read as an empty one" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n\n[[package]]\nname = \"ripgrep\"\n");

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mox status: packages: data/packages/darwin.toml: unknown top-level key \"package\"") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "status --drift: a backend's limitation reaches stderr even when nothing drifted" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });
    try installPlugin(io, h, a);

    // Nothing declared and nothing installed: no package drift at all, so no
    // section opens -- and what the backend cannot see still has to be said.
    try writeManifest(io, h, a, "ports.toml", "backend = \"fakeports\"\n");

    const r = try h.run(&.{ "mox", "status", "--drift" });
    try std.testing.expectEqualStrings("", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mox status: note: fakeports: variants are not tracked\n") != null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

test "status: a manifest that will not load prints the packages section, not silence" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // Unterminated array-of-tables header: the parser cannot read it, so the
    // load fails before any row exists to blame.
    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n\n[[packages]\nname = \"ripgrep\"\n");

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    // Without the section, a refused manifest reads on stdout exactly like a
    // repo that never opted in.
    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\npackages:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  ERROR     the package pass was refused; the reason is the mox status: packages: line\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mox status: packages: data/packages/darwin.toml") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);

    // `--drift` opens the section for it too: the refusal is the problem.
    const d = try h.run(&.{ "mox", "status", "--drift" });
    try std.testing.expect(std.mem.indexOf(u8, d.out, "\npackages:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.out, "  ERROR     the package pass was refused; the reason is the mox status: packages: line\n") != null);
    try std.testing.expectEqual(@as(u8, 1), d.rc);
}

test "status: a manifest that will not validate prints the same ERROR row" {
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
        \\backend = "brw"
        \\
    );

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\npackages:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  ERROR     the package pass was refused; the reason is the mox status: packages: line\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mox status: packages: data/packages/darwin.toml: row \"ripgrep\": no backend named \"brw\"") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
}

test "status --json / --porcelain: a refused manifest is a record, not a clean machine" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // A blacklist row in a gated file: refused, so no backend is ever reached
    // and the drift set says nothing about this machine's packages.
    try writeManifest(io, h, a, "darwin.toml",
        \\backend = "brew"
        \\when = "os=darwin"
        \\
        \\[[blacklist]]
        \\name = "usage"
        \\
    );

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const j = try h.run(&.{ "mox", "status", "--json" });
    try std.testing.expectEqualStrings("{\"files\":[],\"packages\":[{\"state\":\"refused\"}]}\n", j.out);
    try std.testing.expect(std.mem.indexOf(u8, j.err, "mox status: packages: data/packages/darwin.toml") != null);
    try std.testing.expectEqual(@as(u8, 1), j.rc);

    const p = try h.run(&.{ "mox", "status", "--porcelain" });
    try expectPorcelain(p.out);
    try std.testing.expectEqualStrings("package_refused\n", p.out);
    try std.testing.expectEqual(@as(u8, 1), p.rc);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "status: a file-level backend naming no adapter is refused, and the file is what it names" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // The onboarding file the docs describe, with the backend misspelled: no
    // row to blame, and nothing that would ever install.
    try writeManifest(io, h, a, "darwin.toml", "backend = \"brw\"\n");

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mox status: packages: data/packages/darwin.toml: file-level \"backend\": no backend named \"brw\"") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "status: a blacklist row in a file with a top-level when is refused, naming the file" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml",
        \\backend = "brew"
        \\when = "os=darwin"
        \\
        \\[[blacklist]]
        \\name = "usage"
        \\
    );

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mox status: packages: data/packages/darwin.toml: blacklist row 0: this file has a top-level \"when\"") != null);
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "status: an editor lock beside a manifest does not break every package command" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
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
    );
    // The manifest is open in an editor while status runs.
    const dir = try std.fs.path.join(a, &.{ h.repo, "data", "packages" });
    try Io.Dir.cwd().symLink(io, "user@host.4242:1", try std.fs.path.join(a, &.{ dir, ".#darwin.toml" }), .{});
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(a, &.{ dir, "._darwin.toml" }),
        .data = "\x00\x05\x16\x07\x00\x02\x00\x00Mac OS X",
    });

    const fake = try brewWith(a, "ripgrep\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "unreadable") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "TOML parse failed") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "clean     brew") != null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

/// Whether any call ended with `tail`. Suffix, because an install elevates
/// through `sudo` unless the test process is already root, which a container
/// runner is and a workstation is not.
fn calledEndingWith(fake: *const mox.packages.exec.Fake, tail: []const u8) bool {
    for (fake.calls.items) |c| {
        if (std.mem.endsWith(u8, c, tail)) return true;
    }
    return false;
}

/// A machine whose only usable manager is apt, whose `apt-mark` reports
/// `manual` and which answers `extra` for anything else.
fn aptWith(
    a: std.mem.Allocator,
    manual: []const u8,
    extra: []const mox.packages.exec.Fake.Entry,
) !*mox.packages.exec.Fake {
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    // A fixture's own entries answer first, so one can stand in for any of
    // the defaults below.
    for (extra) |e| try entries.append(a, e);
    try entries.append(a, .{ .argv = "apt-get --version", .stdout = "apt 3.0.3 (arm64)\n" });
    try entries.append(a, .{ .argv = "apt-mark showmanual", .stdout = manual });
    try entries.append(a, .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" });
    try entries.append(a, .{ .argv = "apt-config dump APT::Architecture", .stdout = "APT::Architecture \"arm64\";\n" });
    // dpkg has every package apt-mark reports configured, under the
    // architecture the name carries or the native one.
    var dpkg: std.Io.Writer.Allocating = .init(a);
    var names = std.mem.splitScalar(u8, manual, '\n');
    while (names.next()) |name| {
        if (name.len == 0) continue;
        const arch = mox.packages.backend.archOf(name) orelse "arm64";
        try dpkg.writer.print("{s} {s} install ok installed\n", .{ mox.packages.backend.bareName(name), arch });
    }
    try entries.append(a, .{ .argv = apt_installed_call, .stdout = dpkg.written() });
    // A machine with neither a hold nor a pin, which is what these fixtures
    // are about: the checks are exercised on their own elsewhere.
    try entries.append(a, .{ .argv = "apt-mark showhold" });
    try entries.append(a, .{ .argv = "apt-cache policy", .match = .prefix });
    for ([_][]const u8{
        "brew --version",
        "dnf --version",
        "pacman --version",
        "scoop --version",
        "winget --version",
        "zypper --version",
    }) |argv| {
        try entries.append(a, .{ .argv = argv, .fail = error.FileNotFound });
    }

    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    return fake;
}

const apt_installed_call = "dpkg-query -W -f ${Package} ${Architecture} ${Status}\\n";

/// The stanza `apt-cache policy` prints for a package it has a version of,
/// in the shape apt 2.6.1 and 3.0.3 print it.
fn aptStanza(comptime name: []const u8) []const u8 {
    return name ++ ":\n  Installed: (none)\n  Candidate: 1.0\n  Version table:\n     1.0 500\n        500 http://deb.debian.org/debian trixie/main arm64 Packages\n";
}

test "apply: a row no manager has fails alone, and the rows beside it install" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "debian.toml",
        \\backend = "apt"
        \\
        \\[[packages]]
        \\name = "ruby.dev"
        \\
        \\[[packages]]
        \\name = "sl"
        \\
    );

    const fake = try aptWith(a, "", &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update", .match = .suffix },
        .{ .argv = "apt-cache -o APT::Architectures=arm64 -o Dir::State::status=/dev/null -o APT::Cache::AllNames=false --generate pkgnames", .stdout = "sl\nbat\n" },
        .{ .argv = apt_installed_call, .stdout = "sl arm64 install ok installed\n" },
        .{ .argv = "apt-cache madison ruby.dev", .stdout = "" },
        .{ .argv = "apt-cache showpkg ruby.dev", .stdout = "" },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "apt-cache policy sl", .stdout = aptStanza("sl") },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- sl", .match = .suffix },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    // The good row landed, the bad one is its own failure, and the run still
    // exits non-zero over it.
    try std.testing.expect(calledEndingWith(fake, "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- sl"));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 1 installed, 1 failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "row \"ruby.dev\" names no apt package") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "may have landed") == null);
    try std.testing.expectEqual(@as(u8, 2), r.rc);
}

test "apply: a foreign-architecture row apt's listing omits still installs" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "debian.toml",
        \\backend = "apt"
        \\
        \\[[packages]]
        \\name = "wine32:armhf"
        \\
    );

    // The listing omits `wine32` entirely -- measured on Debian trixie arm64
    // with armhf added -- so the row can only be judged by asking about the
    // name as written.
    const fake = try aptWith(a, "", &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update", .match = .suffix },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = "apt-config dump APT::Architecture", .stdout = "APT::Architecture \"arm64\";\n" },
        .{ .argv = "dpkg --print-foreign-architectures", .stdout = "armhf\n" },
        .{
            .argv = "apt-cache madison wine32:armhf",
            .stdout = "wine32:armhf | 10.0~repack-6 | http://deb.debian.org/debian trixie/main armhf Packages\n",
        },
        .{ .argv = "apt-cache policy wine32:armhf", .stdout = aptStanza("wine32:armhf") },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- wine32:armhf", .match = .suffix },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 1 installed, 0 failed") != null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

test "apply: an install that never ran says so, and claims no row may have landed" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "debian.toml",
        \\backend = "apt"
        \\
        \\[[packages]]
        \\name = "sl"
        \\
    );

    // The index refresh is not the install: reporting it as one sends the
    // reader looking for an apt-get that was never asked to install anything.
    const fake = try aptWith(a, "", &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update", .code = 100, .match = .suffix },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mox apply: apt: install did not run: the index or database refresh the install resolves against did not complete, so nothing was installed") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 0 installed, 1 failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "may have landed") == null);
}

test "apply: an install that could not elevate names sudo, and why it was needed" {
    // The elevated argv is only built for a process that is not root.
    if (mox.packages.exec.isRoot()) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "debian.toml",
        \\backend = "apt"
        \\
        \\[[packages]]
        \\name = "sl"
        \\
    );

    // Measured on debian:stable as a user with no `sudo` on the machine: the
    // apply said `install did not run: FileNotFound`, naming neither the
    // program nor that elevation was what the install lacked.
    const fake = try aptWith(a, "", &.{
        .{ .argv = "sudo env DEBIAN_FRONTEND=noninteractive apt-get update", .fail = error.FileNotFound },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mox apply: apt: install did not run: sudo was not found; mox is not running as root, so the install needed it to elevate\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "FileNotFound") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 0 installed, 1 failed") != null);
}

test "apply: a pacman install that fails is reported as the whole-system upgrade it is" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "arch.toml",
        \\backend = "pacman"
        \\
        \\[[packages]]
        \\name = "foo"
        \\
    );

    // A `-Syu` that fails at commit is the install failing, and the install
    // is the whole-system upgrade, so the words say both and no refresh is
    // blamed. The elevated calls are matched by suffix, so the test does
    // not depend on the uid it runs under.
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "pacman --version", .stdout = "Pacman v7.1.0 - libalpm v16.0.1\n" });
    try entries.append(a, .{ .argv = "pacman -Qeq", .stdout = "" });
    for ([_][]const u8{ "brew --version", "apt-get --version", "dnf --version", "scoop --version", "winget --version", "zypper --version" }) |argv| {
        try entries.append(a, .{ .argv = argv, .fail = error.FileNotFound });
    }
    try entries.append(a, .{ .argv = "pacman -Qdq", .code = 1 });
    try entries.append(a, .{ .argv = "pacman-conf DBPath", .stdout = "/var/lib/pacman/\n" });
    try entries.append(a, .{ .argv = "stat -L -c %n %a %F /var/cache/mox /var/cache/mox/pacman-db", .code = 1 });
    try entries.append(a, .{ .argv = " sh /var/cache/mox /var/cache/mox/pacman-db /var/lib/pacman/local /var/cache/mox/pacman-db/local", .match = .suffix });
    try entries.append(a, .{ .argv = "pacman -Sy --dbpath /var/cache/mox/pacman-db --logfile /dev/null", .match = .suffix });
    try entries.append(a, .{ .argv = "pacman -Sl --dbpath /var/cache/mox/pacman-db", .stdout = "core foo 1-1\n" });
    try entries.append(a, .{ .argv = "pacman -Si --dbpath /var/cache/mox/pacman-db --", .match = .prefix });
    try entries.append(a, .{ .argv = "pacman -Qi" });
    try entries.append(a, .{ .argv = "pacman -Qu --dbpath /var/cache/mox/pacman-db", .code = 1 });
    try entries.append(a, .{ .argv = "pacman -Su --print --print-format %n --dbpath /var/cache/mox/pacman-db" });
    try entries.append(a, .{ .argv = "pacman -S --print --print-format %n --dbpath /var/cache/mox/pacman-db -- foo", .stdout = "foo\n" });
    try entries.append(a, .{ .argv = "pacman -Syu --needed --noconfirm -- foo", .code = 1, .match = .suffix });
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mox apply: pacman: install failed: the install did not complete, and on pacman an install is the whole-system upgrade pacman requires of one, so pacman's own message above may name a package no row declares\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "DistroUpgradeInstallFailed") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "RefreshFailed") == null);
    // The transaction ran, so its row may have landed: the hedge stands.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 0 installed, 1 failed (1 row(s) in failed batches may have landed)") != null);
}

fn zypperWith(a: std.mem.Allocator, extra: []const mox.packages.exec.Fake.Entry) !*mox.packages.exec.Fake {
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "zypper --version", .stdout = "zypper 1.14.101\n" });
    for ([_][]const u8{ "brew --version", "apt-get --version", "dnf --version", "pacman --version", "scoop --version", "winget --version" }) |argv| {
        try entries.append(a, .{ .argv = argv, .fail = error.FileNotFound });
    }
    try entries.append(a, .{ .argv = "zypper --non-interactive refresh", .match = .suffix });
    try entries.append(a, .{
        .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep bat",
        .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | bat | a package | package\n",
    });
    try entries.append(a, .{ .argv = "zypper --non-interactive install -- ripgrep bat", .code = 4, .match = .suffix });
    for (extra) |e| try entries.append(a, e);
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    return fake;
}

const zypper_two_rows =
    \\backend = "zypper"
    \\
    \\[[packages]]
    \\name = "ripgrep"
    \\
    \\[[packages]]
    \\name = "bat"
    \\
;

test "apply: a zypper batch whose read-back found nothing landed is not hedged about" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});
    try writeManifest(io, h, a, "suse.toml", zypper_two_rows);

    // Measured on Tumbleweed with `zypper addlock ripgrep` and the staged
    // adapter: the batch exited 4, rpm reported neither row, and the apply
    // still printed "(2 row(s) in failed batches may have landed)" -- a
    // hedge over a fact the read-back had just established.
    const fake = try zypperWith(a, &.{
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 0 installed, 1 failed\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "landed") == null);
}

test "apply: a zypper batch whose read-back found a row landed says how many" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});
    try writeManifest(io, h, a, "suse.toml", zypper_two_rows);

    const fake = try zypperWith(a, &.{
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n", .once = true },
        .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\nbat\n" },
    });
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 0 installed, 1 failed (1 row(s) in failed batches landed)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "may have landed") == null);
}

test "apply: a failed batch that landed a row has the machine re-read, so a fact it bound reaches the post scripts" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});
    try writeManifest(io, h, a, "suse.toml", zypper_two_rows);

    // The batch fails having landed `bat`, and what that install left is a
    // directory a fact is bound by: only a re-capture after the batch puts
    // it in the post script's environment. The read-back said what landed,
    // so nothing is `attempted` here; the re-read rides on `landed` alone.
    const home = try std.fs.path.join(a, &.{ h.repo, ".landed-home" });
    const facts = try std.fs.path.join(a, &.{ h.repo, "data", "facts.toml" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = facts, .data = try std.fmt.allocPrint(
        a,
        "[[facts]]\nname = \"landedhome\"\ncandidates = [\"{s}\"]\n",
        .{home},
    ) });
    const seen = try std.fs.path.join(a, &.{ h.state, "seen.txt" });
    const post_dir = try std.fs.path.join(a, &.{ h.repo, "scripts", "post" });
    try Io.Dir.cwd().createDirPath(io, post_dir);
    const post = try std.fs.path.join(a, &.{ post_dir, "00-record.sh" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = post, .data = try std.fmt.allocPrint(
        a,
        "#!/bin/sh\nprintf '%s\\n' \"${{MOX_FACT_LANDEDHOME:-unset}}\" > \"{s}\"\n",
        .{seen},
    ) });
    try Io.Dir.cwd().setFilePermissions(io, post, Io.File.Permissions.fromMode(0o755), .{});

    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "zypper --version", .stdout = "zypper 1.14.101\n" });
    for ([_][]const u8{ "brew --version", "apt-get --version", "dnf --version", "pacman --version", "scoop --version", "winget --version" }) |argv| {
        try entries.append(a, .{ .argv = argv, .fail = error.FileNotFound });
    }
    try entries.append(a, .{ .argv = "zypper --non-interactive refresh", .match = .suffix });
    try entries.append(a, .{
        .argv = "zypper --non-interactive --quiet --no-color search --match-exact --type package -- ripgrep bat",
        .stdout = "S  | Name | Summary | Type\n---+------+---------+--------\n   | ripgrep | a package | package\n   | bat | a package | package\n",
    });
    try entries.append(a, .{ .argv = "zypper --non-interactive install -- ripgrep bat", .code = 4, .match = .suffix, .makes_dir = home, .io = io });
    try entries.append(a, .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\n", .once = true });
    try entries.append(a, .{ .argv = "rpm -qa --qf %{NAME}\n", .stdout = "bash\nbat\n" });
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 0 installed, 1 failed (1 row(s) in failed batches landed)") != null);
    const got = try Io.Dir.cwd().readFileAlloc(io, seen, a, .limited(1 << 20));
    try std.testing.expectEqualStrings(home, std.mem.trimEnd(u8, got, "\n"));
}

test "commit then apply: a row commit records is a row apply installs, architecture and all" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "debian.toml", "backend = \"apt\"\n");

    // A foreign-architecture package installed by hand: `apt-mark showmanual`
    // reports it qualified, which is the name commit records.
    const fake = try aptWith(a, "wine32:armhf\n", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const c = try h.runWithInput(&.{ "mox", "commit" }, "y\n");
    try std.testing.expect(std.mem.indexOf(u8, c.out, "untracked package: apt wine32:armhf") != null);
    const after = try readManifest(io, h, a, "debian.toml");
    try std.testing.expect(std.mem.indexOf(u8, after, "name = \"wine32:armhf\"") != null);

    // The loop must close: a row mox wrote is a row mox installs. It is the
    // same package name on a machine that has not got it yet, so apply must
    // install it rather than refuse what commit had just recorded.
    const fake2 = try aptWith(a, "", &.{
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get update", .match = .suffix },
        .{ .argv = "dpkg --print-architecture", .stdout = "arm64\n" },
        .{ .argv = "apt-config dump APT::Architecture", .stdout = "APT::Architecture \"arm64\";\n" },
        .{ .argv = "dpkg --print-foreign-architectures", .stdout = "armhf\n" },
        .{
            .argv = "apt-cache madison wine32:armhf",
            .stdout = "wine32:armhf | 10.0~repack-6 | http://deb.debian.org/debian trixie/main armhf Packages\n",
        },
        .{ .argv = "apt-cache policy wine32:armhf", .stdout = aptStanza("wine32:armhf") },
        .{ .argv = "apt-mark showauto" },
        .{ .argv = "env DEBIAN_FRONTEND=noninteractive apt-get install -y -- wine32:armhf", .match = .suffix },
    });
    useFake(fake2);
    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 1 installed, 0 failed") != null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
}

test "plugin: every command puts the recursion marker in what a plugin receives" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    const h = try setup(a, io, &tmp, .{ .extra_env = herm.env });

    // The marker is what stops a plugin that calls `mox` from having that mox
    // discover and run the same plugins again, so it has to be there whatever
    // command reached the plugin -- a guard only some commands set is one no
    // plugin can rely on.
    const log = try std.fs.path.join(a, &.{ h.root, "depth-seen.txt" });
    try writePlugin(io, h, a, "logger", try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\echo "${{1:-none}} ${{MOX_PACKAGES_DEPTH:-unset}}" >> "{s}"
        \\case "${{1:-}}" in
        \\available) exit 0 ;;
        \\id) while IFS= read -r l; do [ -n "$l" ] || continue; printf '%s\n' "$l" | sed -n 's/.*name = "\([^"]*\)".*/\1/p'; done ;;
        \\list) exit 0 ;;
        \\install) exit 0 ;;
        \\esac
        \\exit 0
        \\
    , .{log}));
    try writeManifest(io, h, a, "p.toml", "backend = \"logger\"\n\n[[packages]]\nname = \"ripgrep\"\n");

    _ = try h.run(&.{ "mox", "status" });
    _ = try h.run(&.{ "mox", "apply", "--dry-run" });
    _ = try h.run(&.{ "mox", "apply" });
    _ = try h.runWithInput(&.{ "mox", "commit" }, "");

    const seen = try Io.Dir.cwd().readFileAlloc(io, log, a, .limited(1 << 20));
    errdefer std.debug.print("plugin saw:\n{s}\n", .{seen});
    // Every verb of every command, the install included.
    try std.testing.expect(std.mem.indexOf(u8, seen, "unset") == null);
    for ([_][]const u8{ "available 1", "id 1", "list 1", "install 1" }) |want| {
        try std.testing.expect(std.mem.indexOf(u8, seen, want) != null);
    }
}

test "bootstrap: an installer that exits 0 without installing its manager is a failed run" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    const installer = "#!/bin/sh\nexit 0\n";
    const hex = mox.apply.applied.contentHashHex(installer);
    try writePlugin(io, h, a, "fakeports", "#!/bin/sh\nexit 0\n");
    try writeManifest(io, h, a, "ports.toml", try std.fmt.allocPrint(a,
        \\backend = "fakeports"
        \\
        \\[[bootstrap]]
        \\url = "https://example.invalid/install.sh"
        \\sha256 = "{s}"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    , .{hex}));

    const plugin = try std.fs.path.join(a, &.{ h.repo, "scripts", "backends", "fakeports" });
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    // The manager is absent before the installer and absent after it: the
    // installer exits 0 and leaves nothing behind, which is what an installer
    // whose download silently no-ops does.
    try entries.append(a, .{ .argv = try std.fmt.allocPrint(a, "{s} available", .{plugin}), .code = 1 });
    try entries.append(a, .{ .argv = try std.fmt.allocPrint(a, "{s} id", .{plugin}), .stdout = "ripgrep\n" });
    try entries.append(a, .{ .argv = "curl -fsSL -o", .match = .prefix, .stdout = installer, .write_after = "-o", .io = io });
    // The installer runs and leaves a directory behind, as a half-finished
    // one does: it changed the machine without landing the manager.
    const made = try std.fs.path.join(a, &.{ h.repo, ".fakeports-home" });
    try entries.append(a, .{ .argv = try std.fmt.allocPrint(a, "{s} bootstrap ", .{plugin}), .match = .prefix, .makes_dir = made, .io = io });
    try entries.append(a, .{ .argv = "brew --version", .fail = error.FileNotFound });
    try absentLinuxManagers(a, &entries);
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    // A fact bound by that directory, and a post script that records what it
    // was handed: only a machine re-read after the installer ran can put the
    // fresh value there.
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(a, &.{ h.repo, "data", "facts.toml" }),
        .data = try std.fmt.allocPrint(a, "[[facts]]\nname = \"fakeportshome\"\ncandidates = [\"{s}\"]\n", .{made}),
    });
    const seen = try std.fs.path.join(a, &.{ h.state, "seen.txt" });
    const post_dir = try std.fs.path.join(a, &.{ h.repo, "scripts", "post" });
    try Io.Dir.cwd().createDirPath(io, post_dir);
    const post = try std.fs.path.join(a, &.{ post_dir, "00-record.sh" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = post, .data = try std.fmt.allocPrint(
        a,
        "#!/bin/sh\nprintf '%s\\n' \"${{MOX_FACT_FAKEPORTSHOME:-unset}}\" > \"{s}\"\n",
        .{seen},
    ) });
    try Io.Dir.cwd().setFilePermissions(io, post, Io.File.Permissions.fromMode(0o755), .{});

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(
        u8,
        r.err,
        "mox apply: fakeports: its installer exited 0 but the manager is still absent; run the installer by hand to see why nothing landed\n",
    ) != null);
    // The installer ran, so the machine was re-read whether or not it left
    // the manager behind.
    const recaptured = try Io.Dir.cwd().readFileAlloc(io, seen, a, .limited(1 << 20));
    try std.testing.expectEqualStrings(made, std.mem.trimEnd(u8, recaptured, "\n"));
    // Not a success, and no row handed to a manager that just answered absent:
    // the scripted runner has no `install` entry, so one would fail the run
    // with a different message than this.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 1 installed") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "installing       fakeports") == null);
    try std.testing.expectEqual(@as(u8, 2), r.rc);
    for (fake.calls.items) |c| {
        try std.testing.expect(std.mem.indexOf(u8, c, "fakeports install") == null);
    }
}

test "plugin: a captured verb ends when the plugin does, whatever it left running" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var herm = try hermetic(a, std.testing.io, &tmp);
    defer herm.deinit();
    const io = herm.io;
    // Generous, so that waiting the bound out is unmistakable next to a run
    // that ends when the plugin does.
    const bound_ms = 20_000;
    const h = try setup(a, io, &tmp, .{
        .extra_env = &.{ herm.env[0], .{ .name = "MOX_SCRIPT_TIMEOUT_MS", .value = "20000" } },
    });

    // The plugin answers and exits at once; what it backgrounded inherits the
    // pipe mox reads and holds it for ten minutes. The answer is the
    // plugin's, and the run must not be held for what it left behind.
    try writePlugin(io, h, a, "backgrounder",
        \\#!/bin/sh
        \\case "${1:-}" in
        \\available) exit 0 ;;
        \\id) while IFS= read -r l; do [ -n "$l" ] || continue; printf '%s\n' "$l" | sed -n 's/.*name = "\([^"]*\)".*/\1/p'; done ;;
        \\list) ( sleep 600 ) & echo ripgrep ;;
        \\esac
        \\exit 0
        \\
    );
    try writeManifest(io, h, a, "p.toml", "backend = \"backgrounder\"\n\n[[packages]]\nname = \"ripgrep\"\n");

    const started = Io.Timestamp.now(io, .awake);
    const r = try h.run(&.{ "mox", "status" });
    const elapsed_ms = started.durationTo(Io.Timestamp.now(io, .awake)).toMilliseconds();
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });

    // What the plugin itself wrote before exiting is the answer, and the
    // backend is neither broken nor timed out.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "clean     backgrounder") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "BROKEN") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "timed out") == null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    // Ended with the plugin, not at the bound the plugin never reached.
    try std.testing.expect(elapsed_ms < bound_ms);
}

test "status: a package row this machine's gate excludes is named, not silently absent" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // A `when` that lands under the wrong table header attaches to one row and
    // excludes it everywhere else. With nothing printed for it, that reads
    // exactly like a manifest that never carried the row at all.
    try writeManifest(io, h, a, "darwin.toml",
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
        \\[[packages]]
        \\name = "steam"
        \\when = "os=linux"
        \\
    );

    const fake = try brewWith(a, "ripgrep\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    errdefer std.debug.print("stdout was:\n{s}\n", .{r.out});
    try std.testing.expect(std.mem.indexOf(u8, r.out, "GATED     brew steam (when os=linux)\n") != null);
    // Not drift: the backend is clean and the run says so.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "clean     brew\n") != null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);

    // A gated row is not in the drift set, exactly as a gated file is not.
    const d = try h.run(&.{ "mox", "status", "--drift" });
    try std.testing.expect(std.mem.indexOf(u8, d.out, "GATED") == null);
    const p = try h.run(&.{ "mox", "status", "--porcelain" });
    try std.testing.expectEqualStrings("", p.out);
    const j = try h.run(&.{ "mox", "status", "--json" });
    try std.testing.expectEqualStrings("{\"files\":[],\"packages\":[]}\n", j.out);
}

test "status: a backend this machine cannot use contributes no rows at all, gated ones included" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // pacman is not on this machine, so neither of its rows is judged here.
    // Naming the gated one alone would say the row beside it is fine, when
    // nothing looked at either.
    try writeManifest(io, h, a, "arch.toml",
        \\backend = "pacman"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
        \\[[packages]]
        \\name = "steam"
        \\when = "os=linux"
        \\
    );

    const fake = try brewWith(a, "", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    errdefer std.debug.print("stdout was:\n{s}\n", .{r.out});
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "GATED") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "pacman") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "steam") == null);
}

test "status: a control byte in a manifest filename cannot break the diagnostic framing" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    // The label is interpolated into every message about the file, and each
    // is one line: a newline in the name would split them, and a wrapper
    // keeping only the first line would lose the reason.
    try writeManifest(io, h, a, "dar\nwin.toml", "backend = \"brew\"\n[[packages]\nname = \"x\"\n");

    const fake = try noManagers(a);
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    errdefer std.debug.print("stderr was:\n{s}\n", .{r.err});
    try std.testing.expect(std.mem.indexOf(
        u8,
        r.err,
        "mox status: packages: data/packages/dar\\x0awin.toml: TOML parse failed:",
    ) != null);
    // One line, with the reason on it: nothing about this file wrapped.
    var lines = std.mem.splitScalar(u8, r.err, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "data/packages/dar") == null) continue;
        try std.testing.expect(std.mem.indexOf(u8, line, "TOML parse failed") != null);
    }
    try std.testing.expectEqual(@as(u8, 1), r.rc);
}

test "plugin: a manifest for a manager not installed yet is checked through id, then bootstrapped" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    const installer = "#!/bin/sh\nexit 0\n";
    const hex = mox.apply.applied.contentHashHex(installer);
    try writePlugin(io, h, a, "fakeports", "#!/bin/sh\nexit 0\n");
    try writeManifest(io, h, a, "ports.toml", try std.fmt.allocPrint(a,
        \\backend = "fakeports"
        \\
        \\[[bootstrap]]
        \\url = "https://example.invalid/install.sh"
        \\sha256 = "{s}"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    , .{hex}));

    const plugin = try std.fs.path.join(a, &.{ h.repo, "scripts", "backends", "fakeports" });
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    // `id` answers with the manager absent, which is what the protocol
    // requires of it: the manifest is checked ungated and before any probe,
    // so a plugin whose `id` needed its manager would refuse the very
    // manifest whose `[[bootstrap]]` row exists to install it.
    try entries.append(a, .{ .argv = try std.fmt.allocPrint(a, "{s} id", .{plugin}), .stdout = "ripgrep\n" });
    try entries.append(a, .{ .argv = try std.fmt.allocPrint(a, "{s} available", .{plugin}), .code = 1, .once = true });
    try entries.append(a, .{ .argv = "curl -fsSL -o", .match = .prefix, .stdout = installer, .write_after = "-o", .io = io });
    try entries.append(a, .{ .argv = try std.fmt.allocPrint(a, "{s} bootstrap ", .{plugin}), .match = .prefix });
    try entries.append(a, .{ .argv = try std.fmt.allocPrint(a, "{s} available", .{plugin}) });
    try entries.append(a, .{ .argv = try std.fmt.allocPrint(a, "{s} list", .{plugin}), .stdout = "" });
    try entries.append(a, .{ .argv = try std.fmt.allocPrint(a, "{s} install", .{plugin}) });
    try entries.append(a, .{ .argv = try std.fmt.allocPrint(a, "{s} limitation", .{plugin}), .code = 64 });
    try entries.append(a, .{ .argv = "brew --version", .fail = error.FileNotFound });
    try absentLinuxManagers(a, &entries);
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stdout was:\n{s}\nstderr was:\n{s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "bootstrapping   fakeports") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "Packages: 1 installed, 0 failed") != null);
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    // The row was named through `id` before the installer ran at all.
    const asked_id = for (fake.calls.items, 0..) |c, i| {
        if (std.mem.endsWith(u8, c, "fakeports id")) break i;
    } else fake.calls.items.len;
    const ran_installer = for (fake.calls.items, 0..) |c, i| {
        if (std.mem.indexOf(u8, c, "fakeports bootstrap ") != null) break i;
    } else fake.calls.items.len;
    try std.testing.expect(asked_id < ran_installer);
}

test "apply: a manager whose verb failed says why, not that it exited" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"ripgrep\"\n");

    // brew answers its probe and then fails the listing: the call never
    // reached an exit of its own, so there is no code to print and the reason
    // is the only thing that says what happened.
    var entries: std.ArrayList(mox.packages.exec.Fake.Entry) = .empty;
    try entries.append(a, .{ .argv = "brew --version", .stdout = "Homebrew 6.0.0\n" });
    try entries.append(a, .{ .argv = "env -u HOMEBREW_NO_INSTALL_FROM_API HOMEBREW_NO_AUTO_UPDATE=1 brew list --full-name --installed-on-request", .code = 3 });
    try absentLinuxManagers(a, &entries);
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = try entries.toOwnedSlice(a) };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "apply" });
    errdefer std.debug.print("stderr was:\n{s}\n", .{r.err});
    try std.testing.expect(std.mem.indexOf(
        u8,
        r.err,
        "mox apply: brew: list: the manager's own listing exited nonzero, saying why above; its packages were left alone\n",
    ) != null);
    // Never an exit code it never had.
    try std.testing.expect(std.mem.indexOf(u8, r.err, "exited 255") == null);
    try std.testing.expectEqual(@as(u8, 2), r.rc);

    // status says the same thing of the same machine.
    const s = try h.run(&.{ "mox", "status" });
    try std.testing.expect(std.mem.indexOf(
        u8,
        s.out,
        "BROKEN    brew (list: the manager's own listing exited nonzero, saying why above)\n",
    ) != null);
}

// The packages summary line: what the section above it adds up to.

test "status: the packages summary names every category the section printed" {
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
        \\[[packages]]
        \\name = "steam"
        \\when = "os=linux"
        \\
    );

    // ripgrep is there, fd is not, htop is there and declared nowhere, steam
    // is gated out: one of each category the line can name.
    const fake = try brewWith(a, "ripgrep\nhtop\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    errdefer std.debug.print("stdout was:\n{s}\n", .{r.out});
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  Packages: 1 missing, 1 untracked, 1 gated.\n") != null);

    // --drift never printed the gated row, so the line does not claim it.
    const d = try h.run(&.{ "mox", "status", "--drift" });
    try std.testing.expect(std.mem.indexOf(u8, d.out, "  Packages: 1 missing, 1 untracked.\n") != null);

    // Neither machine format carries it.
    const j = try h.run(&.{ "mox", "status", "--json" });
    try std.testing.expect(std.mem.indexOf(u8, j.out, "Packages:") == null);
    const p = try h.run(&.{ "mox", "status", "--porcelain" });
    try std.testing.expect(std.mem.indexOf(u8, p.out, "Packages:") == null);
}

test "status: a machine with nothing outstanding says so rather than closing the section in silence" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"ripgrep\"\n");
    const fake = try brewWith(a, "ripgrep\n", "", &.{});
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 0), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  Packages: nothing to do.\n") != null);
}

test "status: a refused pass has no counts to give, and says which line says why" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try setup(a, io, &tmp, .{});

    try writeManifest(io, h, a, "darwin.toml", "backend = \"brew\"\n\n[[packages]\nname = \"ripgrep\"\n");
    const fake = try a.create(mox.packages.exec.Fake);
    fake.* = .{ .arena = a, .entries = &.{} };
    useFake(fake);
    defer mox.cli.app.package_runner_override = null;

    const r = try h.run(&.{ "mox", "status" });
    try std.testing.expectEqual(@as(u8, 1), r.rc);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  Packages: the pass was refused; see the mox status: packages: line above.\n") != null);
    // Never "nothing to do": a refusal that read as a clean machine is the
    // whole reason this line exists.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "nothing to do") == null);
}

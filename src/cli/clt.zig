//! The Xcode Command Line Tools on a fresh Mac, where `git` is only a shim
//! that opens an install dialog and exits 1. `mox init --clone` installs
//! them first, headlessly, the way Homebrew's installer does: a marker file
//! makes `softwareupdate` list them, and the newest label is installed.

const std = @import("std");
const mox = @import("../root.zig");

const exec = mox.packages.exec;
const admin = mox.packages.admin;
const Elevation = admin.Elevation;
const Io = std.Io;

/// While this exists, `softwareupdate -l` lists the Command Line Tools.
pub const marker = "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress";

pub const install_dir = "/Library/Developer/CommandLineTools";

pub const unattended_message = "the Xcode Command Line Tools are not installed; mox needs git to clone -- install them (xcode-select --install) and re-run";

/// What keeps the credential the first `sudo` cached fresh, so a long
/// install and the steps after it do not ask again.
pub const Hold = struct {
    io: Io,
    keepalive: *admin.Keepalive,
    refresh: admin.Refresh,
};

/// Install the Command Line Tools when `xcode-select -p` finds no developer
/// directory; with one, nothing else runs. Returns null when they are there
/// afterwards, else the failure in words, naming the step. Each elevated step
/// is streamed, so `sudo` asks on the terminal; without one (`unattended`)
/// nothing is attempted. Once the first `sudo` succeeds, `hold.keepalive` is
/// started; the caller stops it.
pub fn ensure(arena: std.mem.Allocator, runner: exec.Runner, out: *Io.Writer, how: Elevation, hold: Hold) !?[]const u8 {
    const probe = runner.runBoth(arena, &.{ "xcode-select", "-p" }) catch |e| return try spawnFailure(arena, "checking for them with xcode-select -p", e);
    if (probe.ok) return null;
    if (how == .unattended) return unattended_message;

    try out.writeAll("Installing the Xcode Command Line Tools, which git needs; sudo may ask for your administrator password\n");
    try out.flush();

    if (try streamed(arena, runner, how, &.{ "/usr/bin/touch", marker }, "creating the install-on-demand marker")) |why| return why;
    if (how == .prompt) hold.keepalive.start(hold.io, admin.refresh_interval_ms, hold.refresh);
    const why = try installListed(arena, runner, how);
    const removed = try streamed(arena, runner, how, &.{ "/bin/rm", "-f", marker }, "removing the install-on-demand marker");
    if (why) |w| return w;
    if (removed) |w| return w;

    if (try streamed(arena, runner, how, &.{ "xcode-select", "--switch", install_dir }, "selecting them with xcode-select --switch")) |w| return w;
    const after = runner.runBoth(arena, &.{ "xcode-select", "-p" }) catch |e| return try spawnFailure(arena, "verifying with xcode-select -p", e);
    if (!after.ok) return try exitFailure(arena, "verifying with xcode-select -p", "xcode-select -p", after);
    return null;
}

/// The list-and-install half, run while the marker exists.
fn installListed(arena: std.mem.Allocator, runner: exec.Runner, how: Elevation) !?[]const u8 {
    const step = "listing them with softwareupdate -l";
    const listed = runner.runBoth(arena, &.{ "softwareupdate", "-l" }) catch |e| return try spawnFailure(arena, step, e);
    if (!listed.ok) return try exitFailure(arena, step, "softwareupdate -l", listed);
    const label = latestLabel(listed.stdout) orelse
        return "the Command Line Tools install failed at finding their label: softwareupdate -l listed no Command Line Tools; install them with xcode-select --install and re-run";
    const what = try std.fmt.allocPrint(arena, "installing \"{s}\" with softwareupdate -i", .{label});
    return streamed(arena, runner, how, &.{ "softwareupdate", "-i", label }, what);
}

/// `argv` under `sudo` unless mox is root, streamed so sudo can prompt.
fn streamed(arena: std.mem.Allocator, runner: exec.Runner, how: Elevation, argv: []const []const u8, step: []const u8) !?[]const u8 {
    var full: std.ArrayList([]const u8) = .empty;
    if (how != .root) try full.append(arena, "sudo");
    try full.appendSlice(arena, argv);
    const res = runner.stream(arena, full.items) catch |e| return try spawnFailure(arena, step, e);
    if (res.ok) return null;
    return try exitFailure(arena, step, try std.mem.join(arena, " ", full.items), res);
}

fn spawnFailure(arena: std.mem.Allocator, step: []const u8, e: anyerror) ![]const u8 {
    if (e == error.OutOfMemory) return e;
    return std.fmt.allocPrint(arena, "the Command Line Tools install failed at {s}: {s}", .{ step, exec.errorText(e) });
}

/// A streamed step's stderr went to the terminal; a captured one's is kept.
fn exitFailure(arena: std.mem.Allocator, step: []const u8, cmd: []const u8, res: exec.Result) ![]const u8 {
    if (res.timed_out) return std.fmt.allocPrint(arena, "the Command Line Tools install failed at {s}: {s} timed out, killed", .{ step, cmd });
    const stderr = std.mem.trim(u8, res.stderr, " \t\r\n");
    if (stderr.len == 0) return std.fmt.allocPrint(arena, "the Command Line Tools install failed at {s}: {s} exited {d}", .{ step, cmd, res.code });
    return std.fmt.allocPrint(arena, "the Command Line Tools install failed at {s}: {s} exited {d}: {s}", .{ step, cmd, res.code, stderr });
}

/// The newest `* Label: Command Line Tools...` in `softwareupdate -l`'s
/// listing, by version order (Homebrew's `sort -V | tail -n1`).
pub fn latestLabel(listing: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] != '*') continue;
        var label = std.mem.trim(u8, line[1..], " \t");
        if (std.mem.startsWith(u8, label, "Label:")) label = std.mem.trim(u8, label["Label:".len..], " \t");
        if (std.mem.indexOf(u8, label, "Command Line Tools") == null) continue;
        if (best == null or versionLess(best.?, label)) best = label;
    }
    return best;
}

/// `sort -V` order: digit runs compare as numbers, everything else bytewise.
fn versionLess(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const ia = i;
            const jb = j;
            while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
            while (j < b.len and std.ascii.isDigit(b[j])) j += 1;
            const na = std.mem.trimStart(u8, a[ia..i], "0");
            const nb = std.mem.trimStart(u8, b[jb..j], "0");
            if (na.len != nb.len) return na.len < nb.len;
            switch (std.mem.order(u8, na, nb)) {
                .lt => return true,
                .gt => return false,
                .eq => continue,
            }
        }
        if (a[i] != b[j]) return a[i] < b[j];
        i += 1;
        j += 1;
    }
    return a.len - i < b.len - j;
}

const testing = std.testing;

const sample_listing = "Software Update Tool\n" ++
    "\n" ++
    "Finding available software\n" ++
    "Software Update found the following new or updated software:\n" ++
    "* Label: Command Line Tools for Xcode-9.4\n" ++
    "\tTitle: Command Line Tools for Xcode, Version: 9.4, Size: 100KiB, Recommended: YES,\n" ++
    "* Label: Command Line Tools for Xcode-16.0\n" ++
    "\tTitle: Command Line Tools for Xcode, Version: 16.0, Size: 751657KiB, Recommended: YES,\n" ++
    "* Label: macOS Sequoia 15.1-24B83\n" ++
    "\tTitle: macOS Sequoia 15.1, Version: 15.1, Size: 3000000KiB, Recommended: YES, Action: restart,\n";

test "latestLabel: the newest Command Line Tools label by version, not bytes" {
    try testing.expectEqualStrings("Command Line Tools for Xcode-16.0", latestLabel(sample_listing).?);
    try testing.expectEqual(@as(?[]const u8, null), latestLabel("Software Update Tool\n\nNo new software available.\n"));
}

test "versionLess: digit runs compare as numbers" {
    try testing.expect(versionLess("Xcode-9.4", "Xcode-16.0"));
    try testing.expect(!versionLess("Xcode-16.0", "Xcode-9.4"));
    try testing.expect(versionLess("Xcode-16.0", "Xcode-16.1"));
    try testing.expect(versionLess("Xcode-16", "Xcode-16.0"));
    try testing.expect(!versionLess("Xcode-16.0", "Xcode-16.0"));
}

fn noRefresh(_: ?*anyopaque, _: Io) void {}

fn testHold(keepalive: *admin.Keepalive) Hold {
    return .{ .io = testing.io, .keepalive = keepalive, .refresh = .{ .run = noRefresh } };
}

fn fakeOf(a: std.mem.Allocator, entries: []const exec.Fake.Entry) !*exec.Fake {
    const fake = try a.create(exec.Fake);
    fake.* = .{ .arena = a, .entries = entries };
    return fake;
}

test "ensure: present tools run nothing past the probe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var keepalive: admin.Keepalive = .{};
    defer keepalive.stop();
    const hold = testHold(&keepalive);
    const fake = try fakeOf(a, &.{.{ .argv = "xcode-select -p", .stdout = "/Library/Developer/CommandLineTools\n" }});

    try testing.expectEqual(@as(?[]const u8, null), try ensure(a, fake.runner(), &out.writer, .prompt, hold));
    try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try testing.expectEqualStrings("", out.written());
    try testing.expect(!keepalive.active());
}

test "ensure: absent tools install through sudo in Homebrew's order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var keepalive: admin.Keepalive = .{};
    defer keepalive.stop();
    const hold = testHold(&keepalive);
    const fake = try fakeOf(a, &.{
        .{ .argv = "xcode-select -p", .code = 2, .stderr = "xcode-select: error: unable to get active developer directory\n", .once = true },
        .{ .argv = "sudo /usr/bin/touch " ++ marker },
        .{ .argv = "softwareupdate -l", .stdout = sample_listing },
        .{ .argv = "sudo softwareupdate -i Command Line Tools for Xcode-16.0" },
        .{ .argv = "sudo /bin/rm -f " ++ marker },
        .{ .argv = "sudo xcode-select --switch " ++ install_dir },
        .{ .argv = "xcode-select -p", .stdout = install_dir ++ "\n" },
    });

    try testing.expectEqual(@as(?[]const u8, null), try ensure(a, fake.runner(), &out.writer, .prompt, hold));
    const want = [_][]const u8{
        "xcode-select -p",
        "sudo /usr/bin/touch " ++ marker,
        "softwareupdate -l",
        "sudo softwareupdate -i Command Line Tools for Xcode-16.0",
        "sudo /bin/rm -f " ++ marker,
        "sudo xcode-select --switch " ++ install_dir,
        "xcode-select -p",
    };
    try testing.expectEqual(want.len, fake.calls.items.len);
    for (want, fake.calls.items) |w, got| try testing.expectEqualStrings(w, got);
    // Every elevated step is streamed, so sudo can ask on the terminal.
    for (fake.calls.items, fake.streamed.items) |c, s| try testing.expectEqual(std.mem.startsWith(u8, c, "sudo "), s);
    try testing.expectEqualStrings("Installing the Xcode Command Line Tools, which git needs; sudo may ask for your administrator password\n", out.written());
    // The credential the first sudo cached is kept for the steps after.
    try testing.expect(keepalive.active());
}

test "ensure: as root the same steps run without sudo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var keepalive: admin.Keepalive = .{};
    defer keepalive.stop();
    const hold = testHold(&keepalive);
    const fake = try fakeOf(a, &.{
        .{ .argv = "xcode-select -p", .code = 2, .once = true },
        .{ .argv = "/usr/bin/touch " ++ marker },
        .{ .argv = "softwareupdate -l", .stdout = sample_listing },
        .{ .argv = "softwareupdate -i Command Line Tools for Xcode-16.0" },
        .{ .argv = "/bin/rm -f " ++ marker },
        .{ .argv = "xcode-select --switch " ++ install_dir },
        .{ .argv = "xcode-select -p" },
    });
    try testing.expectEqual(@as(?[]const u8, null), try ensure(a, fake.runner(), &out.writer, .root, hold));
    for (fake.calls.items) |c| try testing.expect(!std.mem.startsWith(u8, c, "sudo"));
    try testing.expect(!keepalive.active());
}

test "ensure: without a terminal nothing is attempted and the message names the fix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var keepalive: admin.Keepalive = .{};
    defer keepalive.stop();
    const hold = testHold(&keepalive);
    const fake = try fakeOf(a, &.{.{ .argv = "xcode-select -p", .code = 2 }});

    try testing.expectEqualStrings(unattended_message, (try ensure(a, fake.runner(), &out.writer, .unattended, hold)).?);
    try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
}

test "ensure: a failed listing names its step, keeps softwareupdate's stderr, and removes the marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var keepalive: admin.Keepalive = .{};
    defer keepalive.stop();
    const hold = testHold(&keepalive);
    const fake = try fakeOf(a, &.{
        .{ .argv = "xcode-select -p", .code = 2 },
        .{ .argv = "sudo /usr/bin/touch " ++ marker },
        .{ .argv = "softwareupdate -l", .code = 1, .stderr = "Can't connect to the Apple Software Update server.\n" },
        .{ .argv = "sudo /bin/rm -f " ++ marker },
    });

    try testing.expectEqualStrings(
        "the Command Line Tools install failed at listing them with softwareupdate -l: softwareupdate -l exited 1: Can't connect to the Apple Software Update server.",
        (try ensure(a, fake.runner(), &out.writer, .prompt, hold)).?,
    );
    try testing.expect(fake.called("sudo /bin/rm -f " ++ marker));
}

test "ensure: a refused sudo stops at the marker with sudo's exit code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var keepalive: admin.Keepalive = .{};
    defer keepalive.stop();
    const hold = testHold(&keepalive);
    const fake = try fakeOf(a, &.{
        .{ .argv = "xcode-select -p", .code = 2 },
        .{ .argv = "sudo /usr/bin/touch " ++ marker, .code = 1 },
    });

    try testing.expectEqualStrings(
        "the Command Line Tools install failed at creating the install-on-demand marker: sudo /usr/bin/touch " ++ marker ++ " exited 1",
        (try ensure(a, fake.runner(), &out.writer, .prompt, hold)).?,
    );
    try testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    try testing.expect(!keepalive.active());
}

test "ensure: no label listed is named as such" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var keepalive: admin.Keepalive = .{};
    defer keepalive.stop();
    const hold = testHold(&keepalive);
    const fake = try fakeOf(a, &.{
        .{ .argv = "xcode-select -p", .code = 2 },
        .{ .argv = "sudo /usr/bin/touch " ++ marker },
        .{ .argv = "softwareupdate -l", .stdout = "Software Update Tool\n\nNo new software available.\n" },
        .{ .argv = "sudo /bin/rm -f " ++ marker },
    });

    try testing.expectEqualStrings(
        "the Command Line Tools install failed at finding their label: softwareupdate -l listed no Command Line Tools; install them with xcode-select --install and re-run",
        (try ensure(a, fake.runner(), &out.writer, .prompt, hold)).?,
    );
}

test "ensure: tools still unselected afterwards fail the verification step" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var keepalive: admin.Keepalive = .{};
    defer keepalive.stop();
    const hold = testHold(&keepalive);
    const fake = try fakeOf(a, &.{
        .{ .argv = "xcode-select -p", .code = 2, .stderr = "xcode-select: error: unable to get active developer directory\n" },
        .{ .argv = "sudo /usr/bin/touch " ++ marker },
        .{ .argv = "softwareupdate -l", .stdout = sample_listing },
        .{ .argv = "sudo softwareupdate -i Command Line Tools for Xcode-16.0" },
        .{ .argv = "sudo /bin/rm -f " ++ marker },
        .{ .argv = "sudo xcode-select --switch " ++ install_dir },
    });

    try testing.expectEqualStrings(
        "the Command Line Tools install failed at verifying with xcode-select -p: xcode-select -p exited 2: xcode-select: error: unable to get active developer directory",
        (try ensure(a, fake.runner(), &out.writer, .prompt, hold)).?,
    );
}

//! Installing a package manager that is not there yet.
//!
//! Five of the seven managers ship with the OS and need none of this. brew and
//! scoop do not: on a fresh machine their adapters are inert, every row that
//! names them is inert with them, and nothing mox declares can come true. So
//! the package subsystem installs its own prerequisite rather than leaving a
//! shell script to do it -- mox owns the concern or it does not.
//!
//! What is fetched is DATA, not code baked into mox: the installer URL and its
//! digest are `[[bootstrap]]` rows in the manifest, so bumping a pin is a repo
//! edit rather than a mox release. Nothing runs until its sha256 matches the
//! declared one, which is a stronger guarantee than the package installs that
//! follow -- a brew formula runs whatever upstream ships today.

const std = @import("std");

const applied = @import("../apply/applied.zig");
const exec = @import("exec.zig");

const Io = std.Io;

pub const Error = error{
    BootstrapDownloadFailed,
    BootstrapDigestMismatch,
    BootstrapInstallerTooLarge,
    BootstrapFailed,
};

/// The most an installer may be; larger is refused by name rather than read
/// as a failed download.
pub const max_installer_bytes: usize = 64 << 20;

/// A declared installer: where to get it and what it must hash to.
pub const Spec = struct {
    url: []const u8,
    sha256: []const u8,
};

/// Fetch `spec` into `scratch_dir` and return its path, refusing to leave a
/// file behind unless the digest matches. Verification happens before the
/// caller can run anything, so a substituted installer never executes.
pub fn fetchVerified(
    arena: std.mem.Allocator,
    io: Io,
    runner: exec.Runner,
    scratch_dir: []const u8,
    name: []const u8,
    spec: Spec,
) ![]const u8 {
    try Io.Dir.cwd().createDirPath(io, scratch_dir);
    const path = try std.fs.path.join(arena, &.{ scratch_dir, name });
    // A leftover from an interrupted run would otherwise be re-verified and
    // re-used without ever fetching.
    Io.Dir.cwd().deleteFile(io, path) catch {};
    // Whatever the failure -- a partial download, an oversize one, a digest
    // that does not match -- nothing runnable may be left where the next
    // step expects a verified file.
    errdefer Io.Dir.cwd().deleteFile(io, path) catch {};

    // `--` ends the options: a URL is data even when it starts with `-`.
    const limit = try std.fmt.allocPrint(arena, "{d}", .{max_installer_bytes});
    const res = runner.run(arena, &.{ "curl", "-fsSL", "-o", path, "--max-filesize", limit, "--", spec.url }) catch |e| switch (e) {
        error.FileNotFound => try runner.run(arena, &.{ "wget", "-qO", path, "--", spec.url }),
        else => return e,
    };
    if (!res.ok) return Error.BootstrapDownloadFailed;

    // The read's limit is refused when reached, so one past the cap lets an
    // installer of exactly the cap through, as curl's own cap does.
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_installer_bytes + 1)) catch |e| switch (e) {
        error.StreamTooLong => return Error.BootstrapInstallerTooLarge,
        else => return Error.BootstrapDownloadFailed,
    };
    const got = applied.contentHashHex(bytes);
    if (!std.ascii.eqlIgnoreCase(&got, spec.sha256)) return Error.BootstrapDigestMismatch;
    return path;
}

const testing = std.testing;

fn tmpDir(a: std.mem.Allocator, io: Io, sub: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", sub, "scratch" });
}

/// A runner that "downloads" by writing fixed bytes to the `-o` path.
const Downloader = struct {
    io: Io,
    body: []const u8,
    calls: usize = 0,

    fn runner(self: *Downloader) exec.Runner {
        return .{ .ctx = self, .runFn = run, .streamFn = run };
    }

    fn run(ctx: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: ?[]const u8) anyerror!exec.Result {
        const self: *Downloader = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const out = for (argv, 0..) |a, i| {
            if (std.mem.eql(u8, a, "-o")) break argv[i + 1];
        } else return error.UnexpectedCommand;
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = out, .data = self.body });
        return .{ .code = 0, .ok = true, .stdout = "" };
    }
};

test "fetchVerified: curl is told the size cap, and a partial download is not left behind" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmpDir(a, io, &tmp.sub_path);
    const path = try std.fs.path.join(a, &.{ dir, "install.sh" });

    // curl writes part of the file, then reports failure (a cut connection).
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "curl -fsSL -o", .match = .prefix, .stdout = "#!/bin/sh\necho par", .code = 23, .write_after = "-o", .io = io },
    } };
    try testing.expectError(Error.BootstrapDownloadFailed, fetchVerified(a, io, fake.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = "00",
    }));
    try testing.expect(std.mem.indexOf(u8, fake.calls.items[0], " --max-filesize 67108864 ") != null);
    try testing.expect(std.mem.endsWith(u8, fake.calls.items[0], " -- https://example.invalid/install.sh"));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));
}

test "fetchVerified: the URL follows an end of options for curl and wget alike" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmpDir(a, io, &tmp.sub_path);

    // curl is absent, so wget is tried; both are handed the URL as data.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "curl -fsSL -o", .match = .prefix, .fail = error.FileNotFound },
        .{ .argv = "wget -qO", .match = .prefix, .code = 4 },
    } };
    try testing.expectError(Error.BootstrapDownloadFailed, fetchVerified(a, io, fake.runner(), dir, "install.sh", .{
        .url = "-o/etc/passwd",
        .sha256 = "00",
    }));
    try testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    try testing.expect(std.mem.endsWith(u8, fake.calls.items[0], " -- -o/etc/passwd"));
    try testing.expect(std.mem.endsWith(u8, fake.calls.items[1], " -- -o/etc/passwd"));
}

test "fetchVerified: an installer of exactly the cap is accepted, one byte over is refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmpDir(a, io, &tmp.sub_path);

    const body = try a.alloc(u8, max_installer_bytes + 1);
    @memset(body, 'x');

    const exact = body[0..max_installer_bytes];
    const hex = applied.contentHashHex(exact);
    var at_cap: Downloader = .{ .io = io, .body = exact };
    _ = try fetchVerified(a, io, at_cap.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = &hex,
    });

    var over: Downloader = .{ .io = io, .body = body };
    try testing.expectError(Error.BootstrapInstallerTooLarge, fetchVerified(a, io, over.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = &hex,
    }));
    const path = try std.fs.path.join(a, &.{ dir, "install.sh" });
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));
}

test "fetchVerified: a matching digest yields the staged file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = "#!/bin/sh\necho installed\n";
    const hex = applied.contentHashHex(body);
    var dl: Downloader = .{ .io = io, .body = body };

    const dir = try tmpDir(a, io, &tmp.sub_path);
    const path = try fetchVerified(a, io, dl.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = &hex,
    });

    const staged = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    try testing.expectEqualStrings(body, staged);
}

test "fetchVerified: a mismatched digest refuses and leaves nothing runnable" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dl: Downloader = .{ .io = io, .body = "#!/bin/sh\nrm -rf /\n" };
    const dir = try tmpDir(a, io, &tmp.sub_path);

    try testing.expectError(Error.BootstrapDigestMismatch, fetchVerified(a, io, dl.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
    }));

    // The substituted file must not be sitting there for anything to run.
    const path = try std.fs.path.join(a, &.{ dir, "install.sh" });
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));
}

test "fetchVerified: digest comparison is case-insensitive hex" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const body = "echo hi\n";
    const hex = applied.contentHashHex(body);
    const upper = try std.ascii.allocUpperString(a, &hex);
    var dl: Downloader = .{ .io = io, .body = body };

    const dir = try tmpDir(a, io, &tmp.sub_path);
    _ = try fetchVerified(a, io, dl.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = upper,
    });
}

test "fetchVerified: a failed download is an error, not an empty file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
    const dir = try tmpDir(a, io, &tmp.sub_path);

    // The Fake errors on the unscripted curl; wget is tried and errors too.
    try testing.expectError(error.UnexpectedCommand, fetchVerified(a, io, fake.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = "00",
    }));
}

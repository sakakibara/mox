//! Installing a package manager that is not there yet.
//!
//! Four of the seven managers ship with the OS and need none of this. brew and
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
    BootstrapFailed,
};

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

    const res = runner.run(arena, &.{ "curl", "-fsSL", "-o", path, spec.url }) catch |e| switch (e) {
        error.FileNotFound => try runner.run(arena, &.{ "wget", "-qO", path, spec.url }),
        else => return e,
    };
    if (!res.ok) return Error.BootstrapDownloadFailed;

    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 << 20)) catch
        return Error.BootstrapDownloadFailed;
    const got = applied.contentHashHex(bytes);
    if (!std.ascii.eqlIgnoreCase(&got, spec.sha256)) {
        // Removed, so a failed verification cannot leave something runnable
        // where the next step expects a verified file.
        Io.Dir.cwd().deleteFile(io, path) catch {};
        return Error.BootstrapDigestMismatch;
    }
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
        // `curl -fsSL -o <path> <url>`
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = argv[3], .data = self.body });
        return .{ .code = 0, .ok = true, .stdout = "", .stderr = "" };
    }
};

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

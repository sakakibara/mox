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

/// `CURLE_FILESIZE_EXCEEDED`: what curl exits with when `--max-filesize`
/// refuses the body. wget has no code in this range, so the mapping is only
/// ever applied to curl's own answer.
pub const curl_filesize_exceeded: u8 = 63;

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
    if (runner.run(arena, &.{ "curl", "-fsSL", "-o", path, "--max-filesize", limit, "--", spec.url })) |res| {
        // A download killed at its bound left no code worth reading, so a kill
        // is named before any code is.
        try exec.checkTimedOut(res);
        // curl enforces the cap it was handed and says so with its own exit
        // code, which is the size refusal by name -- not one more way for a
        // download to have failed.
        if (res.code == curl_filesize_exceeded) return Error.BootstrapInstallerTooLarge;
        if (!res.ok) return Error.BootstrapDownloadFailed;
    } else |e| switch (e) {
        // wget has no size cap of its own, so it writes to mox's own pipe,
        // where the runner's capture bound stops an endless body on the
        // wire rather than after it has filled the disk.
        error.FileNotFound => {
            const got = runner.runCapped(arena, &.{ "wget", "-qO-", "--", spec.url }, max_installer_bytes + 1) catch |e2| switch (e2) {
                // The runner's capture bound is this cap: one body too big
                // for it is the oversize installer, named as such.
                error.StreamTooLong => return Error.BootstrapInstallerTooLarge,
                else => return e2,
            };
            try exec.checkTimedOut(got);
            if (!got.ok) return Error.BootstrapDownloadFailed;
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = got.stdout });
        },
        else => return e,
    }

    // The read's limit is refused when reached, so one past the cap lets an
    // installer of exactly the cap through, as curl's own cap does.
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_installer_bytes + 1)) catch |e| switch (e) {
        error.StreamTooLong => return Error.BootstrapInstallerTooLarge,
        // The allocator running out is not a download that failed, and
        // naming it one would send the user looking at the network.
        error.OutOfMemory => return e,
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

/// A runner that "downloads" by writing fixed bytes to the `-o` path, and
/// that obeys `--max-filesize` the way curl does: a body over the cap is
/// refused with curl's own exit code and no file is written. A fake that
/// ignored the flag would let a test assert an outcome production cannot
/// reach.
const Downloader = struct {
    io: Io,
    body: []const u8,
    calls: usize = 0,
    /// A curl that writes the oversize body anyway: what an old curl, or a
    /// body whose size the server never declared, does. The read-back is then
    /// the only thing standing between it and the digest check.
    ignores_cap: bool = false,

    fn runner(self: *Downloader) exec.Runner {
        return .{ .ctx = self, .runFn = run, .streamFn = stream };
    }

    fn stream(ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8, stdin: ?[]const u8) anyerror!exec.Result {
        return run(ctx, a, argv, stdin, exec.max_query_bytes, .stdout);
    }

    fn valueAfter(argv: []const []const u8, flag: []const u8) ?[]const u8 {
        for (argv, 0..) |a, i| {
            if (std.mem.eql(u8, a, flag) and i + 1 < argv.len) return argv[i + 1];
        }
        return null;
    }

    fn run(ctx: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: ?[]const u8, _: usize, _: exec.Capture) anyerror!exec.Result {
        const self: *Downloader = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (!self.ignores_cap) {
            const cap = valueAfter(argv, "--max-filesize") orelse return error.UnexpectedCommand;
            const max = std.fmt.parseInt(usize, cap, 10) catch return error.UnexpectedCommand;
            if (self.body.len > max) return .{ .code = curl_filesize_exceeded, .ok = false, .stdout = "" };
        }
        const out = valueAfter(argv, "-o") orelse return error.UnexpectedCommand;
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

test "fetchVerified: an allocator that ran out is not a download that failed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmpDir(a, io, &tmp.sub_path);

    // The download succeeded and the bytes are on disk; only reading them
    // back runs out of memory, which is nothing the network did.
    const body = "#" ** 8192;
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "curl -fsSL -o", .match = .prefix, .stdout = body, .write_after = "-o", .io = io },
    } };

    // Room for the argv and the staged path, none for the installer itself.
    var buf: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    try testing.expectError(error.OutOfMemory, fetchVerified(fba.allocator(), io, fake.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = "00",
    }));
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

test "fetchVerified: an installer of exactly the cap is accepted, one byte over is refused by curl" {
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

    // curl refuses the body itself and exits 63. Read as a failed download,
    // that would name the wrong problem: nothing was wrong with the fetch.
    var over: Downloader = .{ .io = io, .body = body };
    try testing.expectError(Error.BootstrapInstallerTooLarge, fetchVerified(a, io, over.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = &hex,
    }));
    const path = try std.fs.path.join(a, &.{ dir, "install.sh" });
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));
}

test "fetchVerified: an oversize body a curl let through is still refused by name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmpDir(a, io, &tmp.sub_path);

    const body = try a.alloc(u8, max_installer_bytes + 1);
    @memset(body, 'x');
    const hex = applied.contentHashHex(body);

    // The read-back is the second line: a curl that did not enforce the cap
    // it was handed leaves the oversize file on disk, and it must not reach
    // the digest check as a normal download.
    var through: Downloader = .{ .io = io, .body = body, .ignores_cap = true };
    try testing.expectError(Error.BootstrapInstallerTooLarge, fetchVerified(a, io, through.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = &hex,
    }));
    const path = try std.fs.path.join(a, &.{ dir, "install.sh" });
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));
}

test "fetchVerified: without curl, an oversize body is refused by name on the wget path too" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmpDir(a, io, &tmp.sub_path);

    // wget takes no size cap, so the runner's capture bound is the cap, and
    // the body that overruns it is the oversize installer -- the same refusal
    // curl's exit 63 earns, reached a different way.
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "curl -fsSL -o", .match = .prefix, .fail = error.FileNotFound },
        .{ .argv = "wget -qO-", .match = .prefix, .fail = error.StreamTooLong },
    } };
    try testing.expectError(Error.BootstrapInstallerTooLarge, fetchVerified(a, io, fake.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = "00",
    }));
    const path = try std.fs.path.join(a, &.{ dir, "install.sh" });
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));
}

test "fetchVerified: a download killed at its bound is a timeout, not a failed download" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmpDir(a, io, &tmp.sub_path);
    const path = try std.fs.path.join(a, &.{ dir, "install.sh" });

    // A killed curl comes back `code = 255, ok = false`: read by the code
    // alone, a bound mox itself imposed would be reported as the server's or
    // the network's failure.
    var curl: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "curl -fsSL -o", .match = .prefix, .timed_out = true },
    } };
    try testing.expectError(error.TimedOut, fetchVerified(a, io, curl.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = "00",
    }));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));

    // The same on the wget path, which mox reaches with no curl installed.
    var wget: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "curl -fsSL -o", .match = .prefix, .fail = error.FileNotFound },
        .{ .argv = "wget -qO-", .match = .prefix, .timed_out = true },
    } };
    try testing.expectError(error.TimedOut, fetchVerified(a, io, wget.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = "00",
    }));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));
}

test "fetchVerified: a wget that succeeds stages the body it captured" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmpDir(a, io, &tmp.sub_path);

    const body = "#!/bin/sh\necho installed\n";
    const hex = applied.contentHashHex(body);
    var fake: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "curl -fsSL -o", .match = .prefix, .fail = error.FileNotFound },
        .{ .argv = "wget -qO-", .match = .prefix, .stdout = body },
    } };

    const path = try fetchVerified(a, io, fake.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = &hex,
    });
    const staged = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    try testing.expectEqualStrings(body, staged);
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

    const dir = try tmpDir(a, io, &tmp.sub_path);
    const path = try std.fs.path.join(a, &.{ dir, "install.sh" });

    // curl exits nonzero. The leftover an earlier interrupted run left at the
    // same path must not survive it as a "downloaded" installer.
    var partial: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "curl -fsSL -o", .match = .prefix, .code = 22 },
    } };
    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "half a scr" });
    try testing.expectError(Error.BootstrapDownloadFailed, fetchVerified(a, io, partial.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = "00",
    }));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));

    // No curl at all: wget is tried, and its failure is the same refusal.
    var no_curl: exec.Fake = .{ .arena = a, .entries = &.{
        .{ .argv = "curl -fsSL -o", .match = .prefix, .fail = error.FileNotFound },
        .{ .argv = "wget -qO-", .match = .prefix, .code = 4 },
    } };
    try testing.expectError(Error.BootstrapDownloadFailed, fetchVerified(a, io, no_curl.runner(), dir, "install.sh", .{
        .url = "https://example.invalid/install.sh",
        .sha256 = "00",
    }));
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, path, .{}));
}

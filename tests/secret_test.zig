const std = @import("std");
const builtin = @import("builtin");
const mox = @import("mox");

test "secret integration: cache + resolver work together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var c = mox.secret.cache.Cache.init(arena.allocator());

    const a = arena.allocator();
    const env = try envWith(a, &.{.{ "MOX_TEST_SECRET", "hunter2" }});

    const cached = c.get("env:MOX_TEST_SECRET");
    try std.testing.expect(cached == null);

    const u = try mox.secret.uri.parse("env:MOX_TEST_SECRET");
    const resolved = try mox.secret.resolver.resolve(a, std.testing.io, env, u);
    try c.put("env:MOX_TEST_SECRET", resolved);

    const cached2 = c.get("env:MOX_TEST_SECRET");
    try std.testing.expect(cached2 != null);
    try std.testing.expectEqualStrings(resolved, cached2.?);
}

/// Two lines through the platform's own shell; only the first is the secret.
const two_line_payload = if (builtin.os.tag == .windows)
    "echo hunter2& echo ignored"
else
    "printf 'hunter2\\nignored\\n'";

test "secret integration: cmd scheme runs a shell command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const uri_text = try std.fmt.allocPrint(a, "cmd:{s}", .{two_line_payload});
    const u = try mox.secret.uri.parse(uri_text);
    const v = try mox.secret.resolver.resolve(a, std.testing.io, .{ .process = std.testing.environ }, u);
    try std.testing.expectEqualStrings("hunter2", v);
}

/// A cmd: payload whose URI carries `"`; only inline `<secret:...>` allows the
/// quote (the whole-line directive forbids it). cmd.exe keeps the quotes it
/// echoes, so the expected result differs per platform.
const quoted_payload = if (builtin.os.tag == .windows) "echo \"quoted-secret\"" else "printf '%s\\n' \"quoted-secret\"";
const quoted_expected = if (builtin.os.tag == .windows) "TOKEN=\"quoted-secret\"" else "TOKEN=quoted-secret";

test "inline secret: cmd: URI containing a double quote resolves mid-line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cache = mox.secret.cache.Cache.init(a);
    const tmpl = try std.fmt.allocPrint(a, "TOKEN=<secret:cmd:{s}>", .{quoted_payload});
    const out = try mox.compose.interp.expand(a, tmpl, null, .{
        .io = std.testing.io,
        .secrets = .{ .env = .{ .process = std.testing.environ }, .cache = &cache },
    });
    try std.testing.expectEqualStrings(quoted_expected, out);
}

/// A backend that prints a would-be secret and then FAILS: the resolver takes a
/// nonzero exit as SecretNotFound and never surfaces the stdout, so the value
/// cannot leak through the error path.
const leaking_failure_payload = if (builtin.os.tag == .windows)
    "echo LEAKED-abc& exit 1"
else
    "printf 'LEAKED-abc\\n'; exit 1";

test "inline secret: a backend that prints then fails leaks no value through the error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cache = mox.secret.cache.Cache.init(a);
    const tmpl = try std.fmt.allocPrint(a, "X=<secret:cmd:{s}>", .{leaking_failure_payload});
    const uri = try std.fmt.allocPrint(a, "cmd:{s}", .{leaking_failure_payload});
    try std.testing.expectError(error.SecretNotFound, mox.compose.interp.expand(a, tmpl, null, .{
        .io = std.testing.io,
        .secrets = .{ .env = .{ .process = std.testing.environ }, .cache = &cache },
    }));
    // Nothing was cached, so the failed value is nowhere in memory.
    try std.testing.expect(cache.get(uri) == null);
}

/// A cmd: payload carrying a shell redirect via `\>`. mox unescapes `\>` -> `>`
/// (platform-independently) before handing the payload to the shell, so the
/// first command's stdout is redirected away and only the second line is the
/// secret. If the redirect did not survive, the first line would be the secret.
const redirect_payload = if (builtin.os.tag == .windows)
    "echo first 1\\>nul & echo second"
else
    "echo first 1\\>/dev/null; echo second";

test "inline secret: an escaped '>' survives as a real shell redirect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cache = mox.secret.cache.Cache.init(a);
    const tmpl = try std.fmt.allocPrint(a, "V=<secret:cmd:{s}>", .{redirect_payload});
    const out = try mox.compose.interp.expand(a, tmpl, null, .{
        .io = std.testing.io,
        .secrets = .{ .env = .{ .process = std.testing.environ }, .cache = &cache },
    });
    try std.testing.expectEqualStrings("V=second", out);
}

/// A synthetic environment carrying only what a test names -- plus, on
/// Windows, the entries a spawned shell cannot start without. The resolver
/// runs a backend under the environment mox was handed, so an environment
/// missing SystemRoot or ComSpec makes `cmd.exe` exit immediately rather than
/// run the payload, and a test about timeouts or output caps would be
/// measuring the wrong failure.
fn envWith(a: std.mem.Allocator, pairs: []const [2][]const u8) !mox.env.Env {
    const map = try a.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(a);
    // PATH on every platform: without it a POSIX shell falls back to its
    // compiled-in default, which ends in `.` -- so a payload's commands would
    // resolve against the test's own working directory.
    if (std.testing.environ.getAlloc(a, "PATH") catch null) |v| try map.put("PATH", v);
    if (builtin.os.tag == .windows) {
        for ([_][]const u8{ "SystemRoot", "ComSpec", "PATHEXT" }) |k| {
            if (std.testing.environ.getAlloc(a, k) catch null) |v| try map.put(k, v);
        }
    }
    for (pairs) |p| try map.put(p[0], p[1]);
    return .{ .map = map };
}

/// A backend that blocks for ~3s, spelled for the platform's own shell. Every
/// payload here is bounded on purpose: if the guard under test regresses, the
/// backend still terminates and the test fails, rather than wedging the run.
const sleeping_payload = if (builtin.os.tag == .windows)
    "ping -n 4 127.0.0.1 >nul" // cmd's `timeout` wants a console CI does not give it
else
    "sleep 3";

/// A backend whose output overruns the cap. `yes` streams forever -- the real
/// shape of the hazard, and safe on POSIX, where the reader tears the child
/// down once the cap trips.
///
/// Windows cannot be asked for that: `Io.Threaded` waits on a child with an
/// infinite timeout and leaves cancellation a TODO, so a child still writing
/// when the reader stops blocks on a full pipe and neither side moves again.
/// The Windows payload therefore writes a small finite burst -- several times
/// the cap, but well under any pipe buffer -- so the child can always finish
/// writing and exit. The cap must still trip; it just cannot wedge the run
/// when it does not.
const flooding_payload = if (builtin.os.tag == .windows)
    "for /l %i in (1,1,64) do @echo yyyyyyyy"
else
    "yes";

/// The cap the flood must overrun. The Windows burst above is ~640 bytes.
const flood_cap = "64";

test "secret resolver: a blocking backend times out within the configured bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A short timeout; the backend blocks well past it. Bounded by the block's
    // own duration, so a regression fails (returns after it) rather than
    // hanging forever.
    const env = try envWith(a, &.{.{ "MOX_SECRET_TIMEOUT_MS", "200" }});
    const uri_text = try std.fmt.allocPrint(a, "cmd:{s}", .{sleeping_payload});
    const u = try mox.secret.uri.parse(uri_text);
    try std.testing.expectError(
        error.BackendTimeout,
        mox.secret.resolver.resolve(a, std.testing.io, env, u),
    );
}

test "secret resolver: the backend sees the supplied environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Nothing else pins the environ hand-off, so a refactor that drops it
    // would resolve every secret under the wrong environment in silence.
    const env = try envWith(a, &.{.{ "MOX_TEST_MARKER", "seen" }});
    const payload = if (builtin.os.tag == .windows)
        "cmd:echo %MOX_TEST_MARKER%"
    else
        "cmd:printf '%s' \"$MOX_TEST_MARKER\"";
    const u = try mox.secret.uri.parse(payload);
    const got = try mox.secret.resolver.resolve(a, std.testing.io, env, u);
    try std.testing.expectEqualStrings("seen", std.mem.trim(u8, got, " \r\n"));
}

test "secret resolver: an unbounded-output backend is capped, not OOMed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A tiny output cap against a flood far larger than it. The cap must trip.
    const env = try envWith(a, &.{.{ "MOX_SECRET_MAX_BYTES", flood_cap }});
    const uri_text = try std.fmt.allocPrint(a, "cmd:{s}", .{flooding_payload});
    const u = try mox.secret.uri.parse(uri_text);
    try std.testing.expectError(
        error.BackendOutputTooLarge,
        mox.secret.resolver.resolve(a, std.testing.io, env, u),
    );
}

test "secret resolver: the backend program is found on the supplied PATH, not the process's" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const bin = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "bin" });
    try tmp.dir.createDirPath(io, "bin");
    if (builtin.os.tag == .windows) {
        try tmp.dir.writeFile(io, .{ .sub_path = "bin/pass.cmd", .data = "@echo stubbed-secret\r\n" });
    } else {
        try tmp.dir.writeFile(io, .{ .sub_path = "bin/pass", .data = "#!/bin/sh\necho stubbed-secret\n" });
        const abs = try std.fs.path.join(a, &.{ bin, "pass" });
        var zbuf: [4096]u8 = undefined;
        @memcpy(zbuf[0..abs.len], abs);
        zbuf[abs.len] = 0;
        _ = std.c.chmod(@ptrCast(&zbuf), 0o755);
    }
    // The stub directory is on the supplied PATH only; the process's PATH
    // does not hold it, so a lookup there would report the backend missing.
    var pairs = [_][2][]const u8{.{ "PATH", bin }};
    if (builtin.os.tag == .windows) pairs[0][1] = bin;
    const env = try envWith(a, &pairs);
    const got = try mox.secret.resolver.resolve(a, io, env, try mox.secret.uri.parse("pass://probe"));
    try std.testing.expectEqualStrings("stubbed-secret", got);
}

test "secret resolver: a directory or an unrunnable file named like the backend is passed over on PATH" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no exec bit
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    try tmp.dir.createDirPath(io, "asdir/pass");
    try tmp.dir.createDirPath(io, "plain");
    try tmp.dir.writeFile(io, .{ .sub_path = "plain/pass", .data = "not a program\n" });
    try tmp.dir.createDirPath(io, "real");
    try tmp.dir.writeFile(io, .{ .sub_path = "real/pass", .data = "#!/bin/sh\necho real-secret\n" });
    const real = try std.fs.path.join(a, &.{ root, "real", "pass" });
    var zbuf: [4096]u8 = undefined;
    @memcpy(zbuf[0..real.len], real);
    zbuf[real.len] = 0;
    _ = std.c.chmod(@ptrCast(&zbuf), 0o755);
    const path = try std.fmt.allocPrint(a, "{s}/asdir:{s}/plain:{s}/real", .{ root, root, root });
    var pairs = [_][2][]const u8{.{ "PATH", path }};
    const env = try envWith(a, &pairs);
    const got = try mox.secret.resolver.resolve(a, io, env, try mox.secret.uri.parse("pass://probe"));
    try std.testing.expectEqualStrings("real-secret", got);
}

const std = @import("std");
const builtin = @import("builtin");
const Env = @import("env").Env;
const uri_mod = @import("uri.zig");
const cache_mod = @import("cache.zig");

pub const ResolveError = error{
    SecretNotFound,
    BackendUnavailable,
    BackendFailed,
    BackendTimeout,
    BackendOutputTooLarge,
    OutOfMemory,
};

/// Wall-clock bound on a secret backend subprocess. A backend blocked on
/// interactive input (Touch ID, a pinentry prompt) or a hung network call
/// must not stall apply forever. Override with `MOX_SECRET_TIMEOUT_MS`.
const default_timeout_ms: i64 = 30_000;

/// Cap on a backend's stdout so a runaway producer (`cmd:yes`, `cat /dev/zero`)
/// cannot exhaust memory. Override with `MOX_SECRET_MAX_BYTES`.
const default_stdout_cap: usize = 8 * 1024 * 1024;

/// Resolve a parsed secret URI to its plaintext value.
/// `env:` and `file://` are pure-Zig; `op://` shells out to the 1Password
/// CLI, `pass://` to password-store, and `cmd:` to an arbitrary shell command.
pub fn resolve(
    arena: std.mem.Allocator,
    io: std.Io,
    env: Env,
    u: uri_mod.Uri,
) ![]u8 {
    return switch (u.scheme) {
        .env => resolveEnv(arena, env, u.payload),
        .file => resolveFile(arena, io, u.payload),
        .op => resolveOp(arena, io, env, u.payload),
        .pass => resolvePass(arena, io, env, u.payload),
        .cmd => resolveCmd(arena, io, env, u.payload),
    };
}

/// Resolve a secret URI string through `cache`: a hit returns the stored
/// plaintext, a miss parses + resolves it and stores the result. The single
/// resolution point shared by the whole-line `secret` directive and the inline
/// `<secret:URI>` capture, so both consult one apply-wide cache and inherit the
/// resolver's first-line-of-output rule without duplicating it.
pub fn resolveCached(
    arena: std.mem.Allocator,
    io: std.Io,
    env: Env,
    cache: *cache_mod.Cache,
    uri_str: []const u8,
) (ResolveError || uri_mod.ParseError)![]const u8 {
    if (cache.get(uri_str)) |cached| return cached;
    const u = try uri_mod.parse(uri_str);
    const resolved = try resolve(arena, io, env, u);
    try cache.put(uri_str, resolved);
    return resolved;
}

fn resolveEnv(arena: std.mem.Allocator, env: Env, name: []const u8) ![]u8 {
    return env.getAlloc(arena, name) catch |e| switch (e) {
        error.EnvironmentVariableMissing => error.SecretNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.BackendFailed,
    };
}

fn resolveFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => error.SecretNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.BackendFailed,
    };
}

fn resolveOp(arena: std.mem.Allocator, io: std.Io, env: Env, payload: []const u8) ![]u8 {
    const full_uri = try std.fmt.allocPrint(arena, "op://{s}", .{payload});
    return runBackend(arena, io, env, &.{ "op", "read", "--no-newline", full_uri });
}

/// password-store entries hold the secret on the first line (metadata may
/// follow below); only that line is the secret.
fn resolvePass(arena: std.mem.Allocator, io: std.Io, env: Env, name: []const u8) ![]u8 {
    const out = try runBackend(arena, io, env, &.{ "pass", "show", name });
    return firstLine(out);
}

/// The system shell that runs a `cmd:` payload: `/bin/sh -c` on POSIX, and
/// `cmd.exe /c` on Windows -- its shell, and the one the payload's quoting is
/// written against there.
pub fn shellArgv(payload: []const u8) [3][]const u8 {
    if (builtin.os.tag == .windows) return .{ "cmd.exe", "/c", payload };
    return .{ "/bin/sh", "-c", payload };
}

/// The generic password-manager escape hatch: run the payload through the
/// system shell and take its first stdout line as the secret. A missing shell
/// is BackendUnavailable; a nonzero exit is SecretNotFound.
fn resolveCmd(arena: std.mem.Allocator, io: std.Io, env: Env, payload: []const u8) ![]u8 {
    // A payload containing `"` cannot reach cmd.exe verbatim as an argv element:
    // Zig quotes an arg CRT-style, turning an embedded `"` into `\"`, which
    // cmd.exe does not unescape -- so `echo "x"` would run as `echo \"x\"`. Route
    // such a payload through a temp script file, which cmd.exe reads verbatim. A
    // quote-free payload needs no escaping (its `&`/`>`/`%i` are for cmd.exe and
    // arrive intact) and runs inline, unchanged. POSIX `/bin/sh` handles quotes,
    // so this only applies on Windows.
    if (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, payload, '"') != null) {
        return resolveCmdViaScript(arena, io, env, payload);
    }
    const argv = shellArgv(payload);
    const out = try runBackend(arena, io, env, &argv);
    return firstLine(out);
}

/// Run a `cmd:` payload by writing it to a temp `.cmd` file and executing that,
/// so cmd.exe reads the command verbatim rather than through Zig's argv quoting.
/// `@echo off` keeps the batch file from echoing the command onto stdout.
fn resolveCmdViaScript(arena: std.mem.Allocator, io: std.Io, env: Env, payload: []const u8) ResolveError![]u8 {
    const dir: []const u8 = blk: {
        if (env.getAlloc(arena, "TEMP")) |t| {
            if (t.len > 0) break :blk t;
        } else |_| {}
        if (env.getAlloc(arena, "TMP")) |t| {
            if (t.len > 0) break :blk t;
        } else |_| {}
        break :blk ".";
    };
    // The secret cache resolves each URI once and apply holds the single-writer
    // lock, so a payload-derived name cannot collide with a concurrent resolve;
    // a stale file from a crash is simply overwritten and then deleted.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const name = try std.fmt.allocPrint(arena, "mox-secret-{s}.cmd", .{std.fmt.bytesToHex(digest[0..8].*, .lower)});
    const path = try std.fs.path.join(arena, &.{ dir, name });
    const script = try std.fmt.allocPrint(arena, "@echo off\r\n{s}\r\n", .{payload});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = script }) catch return error.BackendUnavailable;
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const argv = [_][]const u8{ "cmd.exe", "/c", path };
    const out = try runBackend(arena, io, env, &argv);
    return firstLine(out);
}

/// The first line of a backend's output, with any carriage return dropped: a
/// Windows backend emits CRLF, and a secret is not the place to leave a stray
/// \r that would travel into a token or a key file.
fn firstLine(out: []u8) []u8 {
    const nl = std.mem.indexOfScalar(u8, out, '\n') orelse out.len;
    return @constCast(std.mem.trimEnd(u8, out[0..nl], "\r"));
}

fn envInt(arena: std.mem.Allocator, env: Env, name: []const u8, fallback: i64) i64 {
    const v = env.getAlloc(arena, name) catch return fallback;
    if (v.len == 0) return fallback;
    return std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t\r\n"), 10) catch fallback;
}

/// Run a secret backend under a wall-clock timeout and a stdout size cap. A
/// timeout or an over-cap producer kills the child (std.process.run kills on
/// error return) and surfaces a clear error, so a blocking/runaway backend can
/// never hang or OOM an apply.
fn runBackend(arena: std.mem.Allocator, io: std.Io, env: Env, argv: []const []const u8) ResolveError![]u8 {
    const timeout_ms = envInt(arena, env, "MOX_SECRET_TIMEOUT_MS", default_timeout_ms);
    const cap: usize = blk: {
        const v = envInt(arena, env, "MOX_SECRET_MAX_BYTES", @intCast(default_stdout_cap));
        break :blk if (v > 0) @intCast(v) else default_stdout_cap;
    };
    const timeout: std.Io.Timeout = if (timeout_ms > 0)
        .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } }
    else
        .none;

    const result = std.process.run(arena, io, .{
        .argv = argv,
        .timeout = timeout,
        .stdout_limit = std.Io.Limit.limited(cap),
    }) catch |e| switch (e) {
        error.FileNotFound => return error.BackendUnavailable,
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return error.BackendTimeout,
        error.StreamTooLong => return error.BackendOutputTooLarge,
        else => return error.BackendFailed,
    };
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SecretNotFound,
        else => return error.BackendFailed,
    }
    return @constCast(std.mem.trimEnd(u8, result.stdout, "\r\n"));
}

/// A payload printing two lines, spelled for the platform's own shell.
const two_line_payload = if (builtin.os.tag == .windows) "echo first& echo second" else "printf 'first\\nsecond\\n'";

test "resolveEnv reads the variable from the environment it was given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var map = std.process.Environ.Map.init(a);
    try map.put("MOX_TEST_SECRET_HOME", "/home/tester");

    const u = uri_mod.Uri{ .scheme = .env, .payload = "MOX_TEST_SECRET_HOME" };
    const v = try resolve(a, std.testing.io, Env{ .map = &map }, u);
    try std.testing.expectEqualStrings("/home/tester", v);
}

test "resolveEnv missing var errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const u = uri_mod.Uri{ .scheme = .env, .payload = "DEFINITELY_NOT_SET_XYZ" };
    try std.testing.expectError(error.SecretNotFound, resolve(arena.allocator(), std.testing.io, Env{ .process = std.testing.environ }, u));
}

test "runBackend: missing binary is BackendUnavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.BackendUnavailable,
        runBackend(arena.allocator(), std.testing.io, Env{ .process = std.testing.environ }, &.{"mox-test-no-such-binary-xyz"}),
    );
}

test "runBackend: captures stdout and strips the trailing newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = shellArgv("echo hello");
    const out = try runBackend(arena.allocator(), std.testing.io, Env{ .process = std.testing.environ }, &argv);
    // cmd.exe emits CRLF; the trailing carriage return must not survive.
    try std.testing.expectEqualStrings("hello", out);
}

test "runBackend: nonzero exit is SecretNotFound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = shellArgv("exit 3");
    try std.testing.expectError(
        error.SecretNotFound,
        runBackend(arena.allocator(), std.testing.io, Env{ .process = std.testing.environ }, &argv),
    );
}

test "resolveCmd: takes the first stdout line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const uri_text = try std.fmt.allocPrint(a, "cmd:{s}", .{two_line_payload});
    const u = try uri_mod.parse(uri_text);
    const v = try resolve(a, std.testing.io, Env{ .process = std.testing.environ }, u);
    try std.testing.expectEqualStrings("first", v);
}

test "resolveCmd: nonzero exit is SecretNotFound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const u = try uri_mod.parse("cmd:exit 3");
    try std.testing.expectError(
        error.SecretNotFound,
        resolve(arena.allocator(), std.testing.io, Env{ .process = std.testing.environ }, u),
    );
}

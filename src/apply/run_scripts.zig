//! Run user scripts from scripts/pre/ and scripts/post/ at apply time.
//!
//! - scripts/pre/  runs BEFORE the file-compose+write pass (e.g.
//!   bootstrap installers - package managers, mise, brew).
//! - scripts/post/ runs AFTER the write pass (e.g. service reloads,
//!   theme cache rebuilds).
//!
//! Every active script runs on every apply - the idempotence contract.
//! Scripts that want to skip expensive work guard themselves with the
//! `mox trigger hash|seen-version|every` primitives; that keeps skip
//! conditions inside the script where they can reference data files,
//! versions, or clocks, instead of a stage-level content hash that could
//! never see those inputs change.
//!
//! Each stage runs the top-level scripts in lexicographic order (so users
//! can prefix with `01-`, `02-`), then the scripts inside any first-level
//! `<axis>=<value>` subdirectory whose tuple matches the machine bindings
//! (e.g. `scripts/post/os=windows/`), those subdirs also in lexicographic
//! order. Subdirectories that are not axis-named, or whose tuple does not
//! match, are ignored.
//!
//! A script may additionally gate itself on an axis expression by declaring a
//! `# mox: when <axis-expr>` comment line among its leading lines (scanned to
//! the first content line, at most 16 lines in; `#` is the marker for both
//! shell and `.ps1`). The expression is the same language catB `when`
//! directives use; it is evaluated against the machine bindings and the script
//! runs only when it is true, counting `skipped` otherwise. This composes with
//! the directory tuple: a script inside a matching `<axis>=<value>` subdir with
//! its own `when` header runs only when BOTH hold. A malformed expression is a
//! hard per-script failure (counted `failed`, reported to stderr), never a
//! silent run or skip.
//!
//! A script ending in `.ps1` runs under PowerShell (`pwsh -NoProfile -File`,
//! falling back to `powershell.exe`); anything else is executed directly and
//! must carry its own shebang and executable bit.
//!
//! Subprocesses inherit mox's environment. Exit code != 0 increments the
//! fail counter and is reported to stderr but doesn't abort the stage -
//! independent setup steps shouldn't cascade-fail on a single bad script.

const std = @import("std");
const builtin = @import("builtin");
const tuple_mod = @import("../source/tuple.zig");
const match_mod = @import("../compose/match.zig");
const dsl = @import("../dsl/root.zig");
const dirent = @import("../source/dirent.zig");

const Io = std.Io;
const Environ = @import("env").Env;
const EnvironMap = std.process.Environ.Map;

const ps_pwsh = "pwsh";
const ps_powershell = "powershell.exe";

const windows = std.os.windows;
// std has no wrapper for TerminateProcess; declare the one we need to bound a
// hung script on Windows (the timeout killer's Windows half).
extern "kernel32" fn TerminateProcess(hProcess: windows.HANDLE, uExitCode: windows.UINT) callconv(.winapi) windows.BOOL;

/// Generous wall-clock bound on a single setup script so a hung pre-script
/// (waiting on stdin, a lock, or a stalled network call) cannot block apply
/// forever. Override per-run with MOX_SCRIPT_TIMEOUT_MS; <= 0 disables it.
const default_script_timeout_ms: i64 = 600_000;

pub const Result = struct {
    ran: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
};

/// A machine fact exposed to scripts as `MOX_FACT_<UPPERCASE_NAME>`.
pub const Fact = struct { name: []const u8, value: []const u8 };

/// `buildScriptEnv`'s result: the child environment plus the names of any
/// facts left out of it.
pub const ScriptEnv = struct {
    map: EnvironMap,
    /// Fact names not exposed as MOX_FACT_* because their name cannot be
    /// turned into a distinct env name: a non-ASCII byte can only sanitize to
    /// `_`, destroying the name, and two names that sanitize to the SAME
    /// MOX_FACT_* would otherwise silently collide (last write wins). Named
    /// here so a caller can warn instead of leaving either failure silent.
    skipped: []const []const u8 = &.{},
};

/// Build the child environment for setup scripts: the parent environment
/// augmented with MOX_REPO, MOX_STATE_DIR, MOX_HOME (the live root), and every
/// fact as MOX_FACT_<UPPERCASE_NAME>. Characters outside [A-Z0-9_] in a fact
/// name become '_'. All storage is arena-owned.
pub fn buildScriptEnv(
    arena: std.mem.Allocator,
    parent: Environ,
    repo: []const u8,
    state_dir: []const u8,
    home: []const u8,
    facts: []const Fact,
) !ScriptEnv {
    var map = try parent.createMap(arena);
    try map.put("MOX_REPO", repo);
    try map.put("MOX_STATE_DIR", state_dir);
    try map.put("MOX_HOME", home);

    // First pass: tally how many facts each sanitized name would collect. A
    // non-ASCII name never reaches the tally (it is unencodable on its own,
    // regardless of what else is present); an ASCII name's tally exceeding 1
    // means a genuine collision with some OTHER fact's sanitized form.
    var counts = std.StringHashMap(usize).init(arena);
    const encoded = try arena.alloc(?[]const u8, facts.len);
    for (facts, 0..) |f, i| {
        if (!isAsciiName(f.name)) {
            encoded[i] = null;
            continue;
        }
        const enc = try factEnvName(arena, f.name);
        encoded[i] = enc;
        const gop = try counts.getOrPut(enc);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var skipped: std.ArrayList([]const u8) = .empty;
    for (facts, 0..) |f, i| {
        const enc = encoded[i] orelse {
            try skipped.append(arena, f.name);
            continue;
        };
        if (counts.get(enc).? > 1) {
            try skipped.append(arena, f.name);
            continue;
        }
        try map.put(enc, f.value);
    }
    return .{ .map = map, .skipped = try skipped.toOwnedSlice(arena) };
}

fn isAsciiName(name: []const u8) bool {
    for (name) |c| {
        if (c >= 0x80) return false;
    }
    return true;
}

fn factEnvName(arena: std.mem.Allocator, name: []const u8) ![]u8 {
    const prefix = "MOX_FACT_";
    const out = try arena.alloc(u8, prefix.len + name.len);
    @memcpy(out[0..prefix.len], prefix);
    for (name, 0..) |c, i| {
        out[prefix.len + i] = if (std.ascii.isAlphanumeric(c)) std.ascii.toUpper(c) else '_';
    }
    return out;
}

/// Run every top-level regular file in `scripts_dir` lexicographically, then
/// the scripts inside each matching `<axis>=<value>` subdirectory. A missing
/// scripts dir is not an error (no scripts to run). When `environ_map` is
/// non-null, scripts inherit it instead of mox's own environment.
pub fn runStage(
    arena: std.mem.Allocator,
    io: Io,
    scripts_dir: []const u8,
    bindings: *const dsl.resolver.Resolver,
    environ_map: ?*const EnvironMap,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !Result {
    var dir = Io.Dir.cwd().openDir(io, scripts_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return e,
    };
    defer dir.close(io);

    var file_names: std.ArrayList([]const u8) = .empty;
    var gated_dirs: std.ArrayList([]const u8) = .empty;
    for (try dirent.sorted(arena, io, dir)) |entry| {
        if (entry.kind == .file) {
            try file_names.append(arena, entry.name);
        } else if (entry.kind == .directory) {
            if (try axisDirMatches(arena, entry.name, bindings)) {
                try gated_dirs.append(arena, entry.name);
            }
        }
    }

    // Resolved once per stage (not per script): an unparseable override would
    // otherwise warn once per script in the stage.
    const timeout_ms = scriptTimeoutMs(environ_map, stderr);

    var result: Result = .{};
    for (file_names.items) |name| {
        const path = try std.fs.path.join(arena, &.{ scripts_dir, name });
        runOne(arena, io, path, bindings, environ_map, timeout_ms, stdout, stderr, &result);
    }
    for (gated_dirs.items) |dname| {
        const sub_path = try std.fs.path.join(arena, &.{ scripts_dir, dname });
        try runGatedDir(arena, io, sub_path, bindings, environ_map, timeout_ms, stdout, stderr, &result);
    }
    return result;
}

/// True when `name` is an axis tuple (`<axis>=<value>[+...]`) that matches the
/// bindings. Non-axis directory names (no `=`, malformed) are not gated dirs.
fn axisDirMatches(
    arena: std.mem.Allocator,
    name: []const u8,
    bindings: *const dsl.resolver.Resolver,
) !bool {
    const tuple = tuple_mod.parseFilename(arena, name) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return match_mod.matches(tuple, bindings);
}

fn runGatedDir(
    arena: std.mem.Allocator,
    io: Io,
    dir_path: []const u8,
    bindings: *const dsl.resolver.Resolver,
    environ_map: ?*const EnvironMap,
    timeout_ms: i64,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    result: *Result,
) !void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    for (try dirent.sorted(arena, io, dir)) |entry| {
        if (entry.kind != .file) continue;
        try names.append(arena, entry.name);
    }
    for (names.items) |name| {
        const path = try std.fs.path.join(arena, &.{ dir_path, name });
        runOne(arena, io, path, bindings, environ_map, timeout_ms, stdout, stderr, result);
    }
}

/// Read the per-script timeout (ms) from the child environment, or the
/// default. A present but unparseable override warns once and falls back to
/// the default, rather than silently ignoring the typo.
fn scriptTimeoutMs(environ_map: ?*const EnvironMap, stderr: *std.Io.Writer) i64 {
    const m = environ_map orelse return default_script_timeout_ms;
    const v = m.get("MOX_SCRIPT_TIMEOUT_MS") orelse return default_script_timeout_ms;
    if (v.len == 0) return default_script_timeout_ms;
    const trimmed = std.mem.trim(u8, v, " \t\r\n");
    return std.fmt.parseInt(i64, trimmed, 10) catch {
        stderr.print("mox apply: MOX_SCRIPT_TIMEOUT_MS={s}: not an integer; using default ({d}ms)\n", .{ trimmed, default_script_timeout_ms }) catch {};
        return default_script_timeout_ms;
    };
}

/// Forcibly terminate the child after the timeout elapses (never reaps): the
/// caller's `child.wait` reaps, so there is no double-wait race. Cross-platform
/// so a hung script cannot block apply forever on any OS.
/// A canceled sleep (the script finished first) returns without killing.
fn killAfter(io: Io, timeout: Io.Timeout, id: std.process.Child.Id, fired: *bool) void {
    timeout.sleep(io) catch return;
    fired.* = true;
    // Operates on a COPY of the OS handle/pid, never the shared Child, so it
    // races safely alongside `child.wait` (which reaps). POSIX sends SIGKILL;
    // Windows forcibly terminates via TerminateProcess.
    if (builtin.os.tag == .windows) {
        _ = TerminateProcess(id, 1);
    } else {
        std.posix.kill(id, .KILL) catch {};
    }
}

/// Wall-clock bound on a partial file's `check` hook. Tighter than the setup-
/// script default: a checker validates one file and runs on every apply.
/// Override per-run with MOX_CHECK_TIMEOUT_MS; <= 0 disables it.
pub const default_check_timeout_ms: i64 = 30_000;

/// Read the check-hook timeout (ms) from the child environment, or the
/// default. A present but unparseable override warns once and falls back to
/// the default, rather than silently ignoring the typo.
pub fn checkTimeoutMs(environ_map: ?*const EnvironMap, stderr: *std.Io.Writer) i64 {
    const m = environ_map orelse return default_check_timeout_ms;
    const v = m.get("MOX_CHECK_TIMEOUT_MS") orelse return default_check_timeout_ms;
    if (v.len == 0) return default_check_timeout_ms;
    const trimmed = std.mem.trim(u8, v, " \t\r\n");
    return std.fmt.parseInt(i64, trimmed, 10) catch {
        stderr.print("mox apply: MOX_CHECK_TIMEOUT_MS={s}: not an integer; using default ({d}ms)\n", .{ trimmed, default_check_timeout_ms }) catch {};
        return default_check_timeout_ms;
    };
}

/// Bytes of the child's combined output kept for the refusal report.
const check_tail_bytes: usize = 4096;

/// Remove leftover check-hook staging from the state dir: `check-*` dirs
/// (they hold candidate cleartext, possibly with a resolved secret) and
/// their `check-*.out` captures. A crash between materializing a candidate
/// and the deferred cleanup would otherwise leave the cleartext on disk
/// indefinitely; apply sweeps before composing, so a leftover never
/// survives past the next run. Best-effort: an unreadable state dir is not
/// this sweep's problem.
pub fn sweepCheckDirs(arena: std.mem.Allocator, io: Io, state_dir: []const u8) void {
    var dir = Io.Dir.cwd().openDir(io, state_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const Entry = struct { name: []const u8, is_dir: bool };
    var stale: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "check-")) continue;
        const is_dir = entry.kind == .directory;
        if (!is_dir and !std.mem.endsWith(u8, entry.name, ".out")) continue;
        const name = arena.dupe(u8, entry.name) catch return;
        stale.append(arena, .{ .name = name, .is_dir = is_dir }) catch return;
    }
    for (stale.items) |e| {
        if (e.is_dir) {
            dir.deleteTree(io, e.name) catch {};
        } else {
            dir.deleteFile(io, e.name) catch {};
        }
    }
}

/// Outcome of one check-hook run. `refusal` is null on acceptance (exit 0)
/// and names the reason otherwise; `tail` is the end of the child's combined
/// stdout+stderr, for the refusal report.
pub const CheckResult = struct {
    refusal: ?[]const u8,
    tail: []const u8,
};

/// Spawn one `check` argv directly (no shell) and wait for it, bounded.
/// `check_argv[0]` is repo-relative; it is resolved against `repo_dir`, which
/// is also the child's cwd. A `.ps1` checker runs under PowerShell with the
/// same dispatch setup scripts use. The child's stdout and stderr both land
/// in the file at `output_path` (created here), read back as the tail.
///
/// On POSIX the child leads its own process group (pgid 0 at spawn) and a
/// timeout kills the whole group, so a checker that launches a server cannot
/// orphan it. On Windows the intent is job-object termination of the tree;
/// std exposes only per-process termination today, so the direct child is
/// terminated.
pub fn runCheck(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    check_argv: []const []const u8,
    environ_map: *const EnvironMap,
    output_path: []const u8,
    timeout_ms: i64,
) !CheckResult {
    const exe = try std.fs.path.join(arena, &.{ repo_dir, check_argv[0] });
    const out_file = try Io.Dir.cwd().createFile(io, output_path, .{});
    var out_open = true;
    defer if (out_open) out_file.close(io);

    var child = blk: {
        if (std.mem.endsWith(u8, exe, ".ps1")) {
            const first = try checkArgv(arena, try psArgv(arena, exe, ps_pwsh), check_argv[1..]);
            break :blk std.process.spawn(io, checkSpawnOpts(first, environ_map, repo_dir, out_file)) catch |e| switch (e) {
                error.FileNotFound => try std.process.spawn(
                    io,
                    checkSpawnOpts(try checkArgv(arena, try psArgv(arena, exe, ps_powershell), check_argv[1..]), environ_map, repo_dir, out_file),
                ),
                else => return e,
            };
        }
        break :blk try std.process.spawn(io, checkSpawnOpts(try checkArgv(arena, &.{exe}, check_argv[1..]), environ_map, repo_dir, out_file));
    };

    var timed_out = false;
    var killer: ?Io.Future(void) = null;
    if (timeout_ms > 0) {
        if (child.id) |id| {
            const t: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } };
            killer = io.async(killGroupAfter, .{ io, t, id, &timed_out });
        }
    }
    const term = child.wait(io) catch |e| {
        if (killer) |*k| _ = k.cancel(io);
        return e;
    };
    if (killer) |*k| _ = k.cancel(io);

    out_file.close(io);
    out_open = false;
    const tail = readTail(arena, io, output_path);

    if (timed_out) {
        return .{ .refusal = try std.fmt.allocPrint(arena, "timed out after {d}ms, killed", .{timeout_ms}), .tail = tail };
    }
    return switch (term) {
        .exited => |code| .{
            .refusal = if (code == 0) null else try std.fmt.allocPrint(arena, "exit {d}", .{code}),
            .tail = tail,
        },
        else => .{ .refusal = "terminated abnormally", .tail = tail },
    };
}

fn checkArgv(arena: std.mem.Allocator, head: []const []const u8, rest: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, head.len + rest.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..], rest);
    return out;
}

fn checkSpawnOpts(argv: []const []const u8, environ_map: *const EnvironMap, repo_dir: []const u8, out_file: Io.File) std.process.SpawnOptions {
    var opts: std.process.SpawnOptions = .{
        .argv = argv,
        .cwd = .{ .path = repo_dir },
        .environ_map = environ_map,
        .stdin = .close,
        .stdout = .{ .file = out_file },
        .stderr = .{ .file = out_file },
    };
    if (builtin.os.tag != .windows) opts.pgid = 0;
    return opts;
}

/// The group-kill counterpart of `killAfter`: same never-reaps contract, but
/// the signal goes to the child's whole process group (its pgid equals its
/// pid, set at spawn). Windows terminates the direct child; see `runCheck`.
fn killGroupAfter(io: Io, timeout: Io.Timeout, id: std.process.Child.Id, fired: *bool) void {
    timeout.sleep(io) catch return;
    fired.* = true;
    if (builtin.os.tag == .windows) {
        _ = TerminateProcess(id, 1);
    } else {
        std.posix.kill(-id, .KILL) catch {};
    }
}

/// The last `check_tail_bytes` of the file at `path`; empty when unreadable.
fn readTail(arena: std.mem.Allocator, io: Io, path: []const u8) []const u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch return "";
    if (bytes.len <= check_tail_bytes) return bytes;
    return bytes[bytes.len - check_tail_bytes ..];
}

fn runOne(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
    bindings: *const dsl.resolver.Resolver,
    environ_map: ?*const EnvironMap,
    timeout_ms: i64,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    result: *Result,
) void {
    // Optional `# mox: when <axis-expr>` header gates the script on the machine
    // bindings. A read failure here is left for the spawn below to surface; a
    // malformed expression is a hard failure, never a silent run.
    if (whenHeaderExpr(arena, io, path) catch null) |expr_src| {
        const expr = dsl.axis.parseString(arena, expr_src) catch |e| {
            stderr.print("mox apply: {s}: cannot parse `# mox: when {s}`: {s}\n", .{ path, expr_src, @errorName(e) }) catch {};
            result.failed += 1;
            return;
        };
        if (!dsl.axis.evaluate(expr, bindings)) {
            result.skipped += 1;
            stdout.print("  skipped {s}\n", .{path}) catch {};
            return;
        }
    }

    var child = spawnScript(arena, io, path, environ_map) catch |e| {
        stderr.print("mox apply: {s}: spawn failed: {s}\n", .{ path, @errorName(e) }) catch {};
        result.failed += 1;
        return;
    };

    // Bound the wait: a background task terminates the child once the timeout
    // elapses, unblocking child.wait; cancel it if the script finishes first.
    var timed_out = false;
    var killer: ?Io.Future(void) = null;
    if (timeout_ms > 0) {
        if (child.id) |id| {
            const t: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } };
            killer = io.async(killAfter, .{ io, t, id, &timed_out });
        } else {
            // No process id to signal: the timeout cannot be armed, so the wait
            // below would be unbounded. Spawn always yields an id on the
            // supported platforms, so this is defensive -- but say so if it ever
            // happens rather than hang silently.
            stderr.print("mox apply: {s}: warning: no process id; script timeout not enforced\n", .{path}) catch {};
        }
    }

    const term = child.wait(io) catch |e| {
        if (killer) |*k| _ = k.cancel(io);
        stderr.print("mox apply: {s}: wait failed: {s}\n", .{ path, @errorName(e) }) catch {};
        result.failed += 1;
        return;
    };
    if (killer) |*k| _ = k.cancel(io);

    if (timed_out) {
        result.failed += 1;
        stderr.print("mox apply: {s}: timed out after {d}ms, killed\n", .{ path, timeout_ms }) catch {};
        return;
    }
    switch (term) {
        .exited => |code| {
            if (code == 0) {
                result.ran += 1;
                stdout.print("  ran {s}\n", .{path}) catch {};
            } else {
                result.failed += 1;
                stderr.print("mox apply: {s}: exit {d}\n", .{ path, code }) catch {};
            }
        },
        else => {
            result.failed += 1;
            stderr.print("mox apply: {s}: terminated abnormally\n", .{path}) catch {};
        },
    }
}

/// Lines scanned from a script's head for a `# mox: when` header. The scan also
/// stops at the first content line, so a header must sit among the leading
/// shebang/comment/blank lines.
const header_scan_lines: usize = 16;

/// Bytes read from a script's head to find its header. Sixteen short comment
/// lines fit well within this; content past it is irrelevant to the gate.
const header_peek_bytes: usize = 16 * 1024;

/// Read the head of `path` (up to `header_peek_bytes`) into arena memory.
fn readHead(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const buf = try arena.alloc(u8, header_peek_bytes);
    var reader_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buf);
    const n = try reader.interface.readSliceShort(buf);
    return buf[0..n];
}

/// The raw expression text of a script's `# mox: when <expr>` header, or null
/// when the script has none. Reads only the file's head.
fn whenHeaderExpr(arena: std.mem.Allocator, io: Io, path: []const u8) !?[]const u8 {
    return findWhenHeader(try readHead(arena, io, path));
}

/// Scan `head` for a `# mox: when <expr>` gate line and return its expression
/// text, or null when there is none. Inspects at most the first
/// `header_scan_lines` lines and stops at the first line that is neither blank
/// nor a `#` comment (a shebang counts as a comment, so it does not stop the
/// scan). The comment marker is `#`, shared by shell and PowerShell.
fn findWhenHeader(head: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, head, '\n');
    var scanned: usize = 0;
    while (lines.next()) |raw| {
        if (scanned >= header_scan_lines) break;
        scanned += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue; // blank
        if (line[0] != '#') break; // first content line ends the scan
        var rest = std.mem.trimStart(u8, line[1..], " \t");
        if (!std.mem.startsWith(u8, rest, "mox:")) continue;
        rest = std.mem.trimStart(u8, rest[4..], " \t");
        if (!std.mem.startsWith(u8, rest, "when")) continue;
        const after = rest[4..];
        // `when` must end at a word boundary. A following identifier char means a
        // different word (`whenever...`) and is not a gate. Space/tab/`(` opens
        // the expression. Any OTHER following char (`=`, punctuation) is a
        // MALFORMED gate, not an ordinary comment: fall through so it parses and
        // fails CLOSED, rather than letting `# mox: when=darwin` run ungated.
        if (after.len != 0 and (std.ascii.isAlphanumeric(after[0]) or after[0] == '_')) continue;
        return std.mem.trim(u8, after, " \t");
    }
    return null;
}

/// Spawn one script. A `.ps1` runs under `pwsh -NoProfile -File`, falling back
/// to `powershell.exe` if pwsh is not on PATH; everything else is executed
/// directly.
fn spawnScript(arena: std.mem.Allocator, io: Io, path: []const u8, environ_map: ?*const EnvironMap) !std.process.Child {
    if (std.mem.endsWith(u8, path, ".ps1")) {
        return std.process.spawn(io, spawnOpts(try psArgv(arena, path, ps_pwsh), environ_map)) catch |e| switch (e) {
            error.FileNotFound => std.process.spawn(io, spawnOpts(try psArgv(arena, path, ps_powershell), environ_map)),
            else => e,
        };
    }
    return std.process.spawn(io, spawnOpts(try directArgv(arena, path), environ_map));
}

fn spawnOpts(argv: []const []const u8, environ_map: ?*const EnvironMap) std.process.SpawnOptions {
    return .{ .argv = argv, .environ_map = environ_map, .stdin = .close, .stdout = .inherit, .stderr = .inherit };
}

/// PowerShell invocation argv for `path`: `<exe> -NoProfile -File <path>`.
fn psArgv(arena: std.mem.Allocator, path: []const u8, exe: []const u8) ![]const []const u8 {
    const argv = try arena.alloc([]const u8, 4);
    argv[0] = exe;
    argv[1] = "-NoProfile";
    argv[2] = "-File";
    argv[3] = path;
    return argv;
}

fn directArgv(arena: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const argv = try arena.alloc([]const u8, 1);
    argv[0] = path;
    return argv;
}

const testing = std.testing;

test "psArgv: pwsh invocation shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = try psArgv(arena.allocator(), "/scripts/post/os=windows/reload.ps1", ps_pwsh);
    try testing.expectEqual(@as(usize, 4), argv.len);
    try testing.expectEqualStrings("pwsh", argv[0]);
    try testing.expectEqualStrings("-NoProfile", argv[1]);
    try testing.expectEqualStrings("-File", argv[2]);
    try testing.expectEqualStrings("/scripts/post/os=windows/reload.ps1", argv[3]);

    const fallback = try psArgv(arena.allocator(), "/x/y.ps1", ps_powershell);
    try testing.expectEqualStrings("powershell.exe", fallback[0]);
}

test "buildScriptEnv: injects mox vars and uppercased facts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const facts = [_]Fact{
        .{ .name = "profile", .value = "work" },
        .{ .name = "cloud_backend", .value = "gdrive" },
    };
    const a = arena.allocator();

    // An injected parent, so the assertion that it survives does not depend on
    // which variables the host defines (HOME is a POSIX spelling).
    var parent = EnvironMap.init(a);
    try parent.put("MOX_TEST_PARENT", "kept");

    var result = try buildScriptEnv(a, Environ{ .map = &parent }, "/repo", "/state", "/home/me", &facts);
    try testing.expectEqualStrings("/repo", result.map.get("MOX_REPO").?);
    try testing.expectEqualStrings("/state", result.map.get("MOX_STATE_DIR").?);
    try testing.expectEqualStrings("/home/me", result.map.get("MOX_HOME").?);
    try testing.expectEqualStrings("work", result.map.get("MOX_FACT_PROFILE").?);
    try testing.expectEqualStrings("gdrive", result.map.get("MOX_FACT_CLOUD_BACKEND").?);
    // Parent environment is preserved.
    try testing.expectEqualStrings("kept", result.map.get("MOX_TEST_PARENT").?);
    try testing.expectEqual(@as(usize, 0), result.skipped.len);
}

test "factEnvName: non-identifier characters become underscores" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("MOX_FACT_GDRIVE_ACCOUNT", try factEnvName(arena.allocator(), "gdrive.account"));
}

test "buildScriptEnv: a non-ASCII fact name is skipped, not garbled into underscores" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parent = EnvironMap.init(a);
    // "nihongo" (Japanese for "Japanese language") as raw UTF-8 bytes.
    const facts = [_]Fact{
        .{ .name = "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", .value = "x" },
        .{ .name = "profile", .value = "work" },
    };
    var result = try buildScriptEnv(a, Environ{ .map = &parent }, "/repo", "/state", "/home/me", &facts);
    try testing.expectEqualStrings("work", result.map.get("MOX_FACT_PROFILE").?);
    try testing.expectEqual(@as(usize, 1), result.skipped.len);
    try testing.expectEqualStrings("\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", result.skipped[0]);
}

test "buildScriptEnv: two names that sanitize identically are both skipped, neither silently wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parent = EnvironMap.init(a);
    const facts = [_]Fact{
        .{ .name = "cloud.backend", .value = "gdrive" },
        .{ .name = "cloud-backend", .value = "dropbox" },
        .{ .name = "profile", .value = "work" },
    };
    var result = try buildScriptEnv(a, Environ{ .map = &parent }, "/repo", "/state", "/home/me", &facts);
    try testing.expect(result.map.get("MOX_FACT_CLOUD_BACKEND") == null);
    try testing.expectEqualStrings("work", result.map.get("MOX_FACT_PROFILE").?);
    try testing.expectEqual(@as(usize, 2), result.skipped.len);
    try testing.expectEqualStrings("cloud.backend", result.skipped[0]);
    try testing.expectEqualStrings("cloud-backend", result.skipped[1]);
}

test "directArgv: single-element argv" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = try directArgv(arena.allocator(), "/scripts/pre/00-boot.sh");
    try testing.expectEqual(@as(usize, 1), argv.len);
    try testing.expectEqualStrings("/scripts/pre/00-boot.sh", argv[0]);
}

test "findWhenHeader: shell header after shebang and blank, stops past content" {
    // Shebang is a comment (kept scanning), blank line skipped, header found.
    // A later `when` line after the first content line must not be reached.
    const src = "#!/bin/sh\n\n# mox: when os=darwin or os=linux\necho hi\n# mox: when os=windows\n";
    try testing.expectEqualStrings("os=darwin or os=linux", findWhenHeader(src).?);
}

test "findWhenHeader: PowerShell-style leading comment with CRLF" {
    const src = "# mox: when profile=work\r\nWrite-Host hi\r\n";
    try testing.expectEqualStrings("profile=work", findWhenHeader(src).?);
}

test "findWhenHeader: a content line before the header ends the scan" {
    const src = "#!/bin/sh\necho hi\n# mox: when os=darwin\n";
    try testing.expect(findWhenHeader(src) == null);
}

test "findWhenHeader: a paren right after `when` is a boundary, not a miss" {
    // `when(a or b)` must gate; silently treating it as an ordinary comment
    // would run the script unconditionally.
    const src = "#!/bin/sh\n# mox: when(os=darwin or os=linux)\necho hi\n";
    try testing.expectEqualStrings("(os=darwin or os=linux)", findWhenHeader(src).?);
}

test "findWhenHeader: `whenever` is not a gate, but a malformed `when=` is (fails closed)" {
    // A real different word must NOT be read as a gate...
    try testing.expect(findWhenHeader("#!/bin/sh\n# mox: whenever you like\n") == null);
    // ...but `when` glued to punctuation is a malformed gate, returned so it
    // parses and fails closed rather than running the script ungated.
    try testing.expectEqualStrings("=darwin", findWhenHeader("#!/bin/sh\n# mox: when=darwin\n").?);
}

test "findWhenHeader: header on the 16th line is still found" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 15) : (i += 1) try buf.appendSlice(testing.allocator, "#\n");
    try buf.appendSlice(testing.allocator, "# mox: when os=darwin\n");
    try testing.expectEqualStrings("os=darwin", findWhenHeader(buf.items).?);
}

test "findWhenHeader: a header past the 16-line window is not seen" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "#!/bin/sh\n");
    var i: usize = 0;
    while (i < 16) : (i += 1) try buf.appendSlice(testing.allocator, "#\n");
    try buf.appendSlice(testing.allocator, "# mox: when os=darwin\n");
    try testing.expect(findWhenHeader(buf.items) == null);
}

test "findWhenHeader: absent, non-when directive, and near-miss keyword" {
    try testing.expect(findWhenHeader("#!/bin/sh\necho hi\n") == null);
    try testing.expect(findWhenHeader("#!/bin/sh\n# just a comment\necho hi\n") == null);
    // `mox:` without `when`, and a `whenever` near-miss, are both non-headers.
    try testing.expect(findWhenHeader("# mox: hash foo\necho hi\n") == null);
    try testing.expect(findWhenHeader("# mox: whenever os=darwin\necho hi\n") == null);
}

test "axisDirMatches: gated by binding; non-axis dirs ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "windows");
    try bindings.put("profile", "work");
    var bindings_r: dsl.resolver.Resolver = .{ .live = &bindings };

    try testing.expect(try axisDirMatches(a, "os=windows", &bindings_r));
    try testing.expect(try axisDirMatches(a, "os=windows+profile=work", &bindings_r));
    try testing.expect(!try axisDirMatches(a, "os=darwin", &bindings_r));
    // A plain directory name is not an axis tuple: ignored, not an error.
    try testing.expect(!try axisDirMatches(a, "windows", &bindings_r));
    try testing.expect(!try axisDirMatches(a, "helpers", &bindings_r));
}

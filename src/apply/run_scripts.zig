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
const fact_env = @import("../source/fact_env.zig");
const path_mod = @import("../source/path.zig");
const dimensions = @import("../machine/dimensions.zig");
const derived_facts = @import("../machine/derived_facts.zig");
const state = @import("../machine/state.zig");

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
    /// A script whose fact contract could not be resolved this stage:
    /// counts into the failing exit exactly like `failed`, but under its own
    /// summary label -- a broken contract is a distinct defect class from a
    /// nonzero exit code.
    blocked: usize = 0,
    /// A script that did not run because a fact it needs was bound but
    /// explicitly declined: green, does not fail the run.
    declined: usize = 0,
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

// Script fact contracts

/// Everything a stage needs to judge a script's fact contract against this
/// stage's ACTUAL projected environment, never an abstract name set: the
/// discovered config space (which names are interviewable dimensions),
/// `data/facts.toml`'s declared rows (for a derived fact's remediation), the
/// facts this stage's environment was built from, which of those a
/// projection collision dropped, and the environment itself. Rebuild this
/// (via `buildContracts`) after every re-capture, same as `buildScriptEnv` --
/// a fact a pre-script just persisted must be visible to a post-script's
/// availability check, not just its environment.
pub const Contracts = struct {
    dims: []const dimensions.Dimension,
    scripts: []const dimensions.ScriptRecord,
    derived: []const derived_facts.DeclaredRow,
    custom: []const Fact,
    skipped: []const []const u8,
    env: *const EnvironMap,
    /// Reverse of `fact_env.project` over every name discovery, `data/
    /// facts.toml`, and the currently bound facts know about (deduped): a
    /// scanned `MOX_FACT_*` token maps back to the one name that would
    /// produce it, when the mapping is unambiguous.
    token_to_name: std.StringHashMap([]const u8),
};

/// Build `Contracts` for one stage: `dims`/`scripts` come from `dimensions.
/// discover` (stable for the whole apply run, a pure function of the repo
/// tree); `derived` from `data/facts.toml`'s declared rows (also stable);
/// `custom`/`skipped`/`env` are THIS stage's actual bound facts and the
/// environment `buildScriptEnv` projected them into -- the caller rebuilds
/// this after every re-capture.
pub fn buildContracts(
    arena: std.mem.Allocator,
    dims: []const dimensions.Dimension,
    scripts: []const dimensions.ScriptRecord,
    derived: []const derived_facts.DeclaredRow,
    custom: []const Fact,
    skipped: []const []const u8,
    env: *const EnvironMap,
) !Contracts {
    var names_set = std.StringHashMap(void).init(arena);
    for (dims) |d| try names_set.put(d.name, {});
    for (derived) |r| try names_set.put(r.name, {});
    for (custom) |f| try names_set.put(f.name, {});
    var names: std.ArrayList([]const u8) = .empty;
    var name_it = names_set.keyIterator();
    while (name_it.next()) |k| try names.append(arena, k.*);

    const projected = try fact_env.project(arena, try names.toOwnedSlice(arena));
    var token_to_name = std.StringHashMap([]const u8).init(arena);
    var proj_it = projected.iterator();
    while (proj_it.next()) |e| try token_to_name.put(e.value_ptr.*, e.key_ptr.*);

    return .{
        .dims = dims,
        .scripts = scripts,
        .derived = derived,
        .custom = custom,
        .skipped = skipped,
        .env = env,
        .token_to_name = token_to_name,
    };
}

/// One needed fact's classification against `c`'s actual environment.
const NeedVerdict = union(enum) {
    runs,
    /// The fact name, bound but explicitly empty (a persisted decline).
    declined: []const u8,
    /// A fully worded, ready-to-print reason this fact cannot be resolved.
    blocked: []const u8,
};

/// A whole script's contract outcome: the worst lane across every needed
/// fact (`blocked` if any is blocked, else `declined` if any is declined,
/// else `runs`), with the message(s) to print for it.
pub const ScriptVerdict = struct {
    lane: enum { runs, declined, blocked } = .runs,
    /// One aggregated line when `lane == .declined` (one notice line per
    /// script, however many declined facts contributed to it); one line per
    /// blocking needed fact when `lane == .blocked`, each its own loud
    /// diagnostic. Empty when `lane == .runs`.
    messages: []const []const u8 = &.{},
};

fn findFactValue(facts: []const Fact, name: []const u8) ?[]const u8 {
    for (facts) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
    return null;
}

fn findDerivedRow(rows: []const derived_facts.DeclaredRow, name: []const u8) ?derived_facts.DeclaredRow {
    for (rows) |r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

fn isDimensionName(dims: []const dimensions.Dimension, name: []const u8) bool {
    for (dims) |d| if (std.mem.eql(u8, d.name, name)) return true;
    return false;
}

fn findScriptRecord(scripts: []const dimensions.ScriptRecord, rel_path: []const u8) ?dimensions.ScriptRecord {
    for (scripts) |s| if (std.mem.eql(u8, s.path, rel_path)) return s;
    return null;
}

fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, s)) return true;
    return false;
}

fn singleton(arena: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, 1);
    out[0] = s;
    return out;
}

/// A derived fact's remediation text: its env override, its candidate
/// directories, both, or (a row declaring neither, a degenerate repo
/// mistake) a fallback that still names the row.
fn derivedRemediation(arena: std.mem.Allocator, row: derived_facts.DeclaredRow) ![]const u8 {
    if (row.env != null and row.candidates.len > 0) {
        return std.fmt.allocPrint(arena, "set ${s}, or create one of: {s}", .{
            row.env.?, try std.mem.join(arena, ", ", row.candidates),
        });
    }
    if (row.env) |e| return std.fmt.allocPrint(arena, "set ${s}", .{e});
    if (row.candidates.len > 0) {
        return std.fmt.allocPrint(arena, "create one of: {s}", .{try std.mem.join(arena, ", ", row.candidates)});
    }
    return std.fmt.allocPrint(arena, "its data/facts.toml row declares no env override or candidates", .{});
}

/// Classify one needed FACT NAME (from an explicit `# mox: needs` list, or a
/// scanned token `classifyToken` already resolved to a name) against `c`'s
/// actual environment -- the availability predicate is the projected env
/// itself, not an abstract name set, so this always checks `c.env` first.
fn classifyName(arena: std.mem.Allocator, name: []const u8, c: *const Contracts) !NeedVerdict {
    const token = try fact_env.envName(arena, name);
    if (c.env.get(token)) |v| {
        if (v.len > 0) return .runs;
        return .{ .declined = name };
    }

    // Not in the environment: bound but dropped by a projection collision
    // (the existing skip-both behavior) is unavailable, not "never bound".
    if (containsStr(c.skipped, name)) {
        return .{ .blocked = try std.fmt.allocPrint(
            arena,
            "needs \"{s}\", which never reaches this script's environment (its MOX_FACT_* name collides with another fact's -- see the notice above)",
            .{name},
        ) };
    }
    // Defensive: `buildScriptEnv` puts every bound, non-skipped fact into
    // `env` (declines included), so a bound name absent from both `env` and
    // `skipped` should not occur -- if it somehow does, treat its own
    // recorded value as authoritative rather than misreporting "never
    // bound".
    if (findFactValue(c.custom, name)) |v| {
        return if (v.len == 0) .{ .declined = name } else .runs;
    }

    if (findDerivedRow(c.derived, name)) |row| {
        return .{ .blocked = try std.fmt.allocPrint(
            arena,
            "needs \"{s}\" (a derived fact), unresolved on this machine ({s})",
            .{ name, try derivedRemediation(arena, row) },
        ) };
    }
    if (isDimensionName(c.dims, name)) {
        return .{ .blocked = try std.fmt.allocPrint(
            arena,
            "needs \"{s}\", never bound (mox facts set {s} <value>, or answer the interview)",
            .{ name, name },
        ) };
    }
    // A built-in (os, arch, machine, hostname, username) is never projected
    // as MOX_FACT_* -- a script cannot consume it through the env, so a
    // `# mox: needs` line naming one can never be honored; the script's
    // real dependency is expressed as a gate or a directory tuple instead.
    if (state.isBuiltinField(name)) {
        return .{ .blocked = try std.fmt.allocPrint(
            arena,
            "needs \"{s}\", a built-in that is never projected as {s} -- gate the script with `# mox: when {s}=...` or place it under an {s}=<value>/ script directory instead",
            .{ name, try fact_env.envName(arena, name), name, name },
        ) };
    }
    // Names nothing mox knows how to bind or derive at all -- a `# mox:
    // needs` line naming this cannot be honored.
    return .{ .blocked = try std.fmt.allocPrint(
        arena,
        "needs \"{s}\", which names no fact mox can bind or derive",
        .{name},
    ) };
}

/// Every name in `skipped` whose own projection lands on `token` -- the
/// names a projection collision dropped `token` for (`buildScriptEnv`'s
/// skip-both behavior; usually exactly the colliding pair).
fn collidingOnToken(arena: std.mem.Allocator, skipped: []const []const u8, token: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (skipped) |name| {
        if (std.mem.eql(u8, try fact_env.envName(arena, name), token)) try out.append(arena, name);
    }
    return out.toOwnedSlice(arena);
}

/// Classify one scanned `MOX_FACT_*` token (used only when a script has no
/// explicit `# mox: needs` line) against `c`'s actual environment. A token
/// mapping to no known fact at all fails closed: a stale or typo'd token
/// must never silently run unguarded.
fn classifyToken(arena: std.mem.Allocator, token: []const u8, c: *const Contracts) !NeedVerdict {
    if (c.env.get(token)) |v| {
        if (v.len > 0) return .runs;
        return .{ .declined = c.token_to_name.get(token) orelse token };
    }
    if (c.token_to_name.get(token)) |name| return classifyName(arena, name, c);
    // Absent from both `env` (nothing ever projects to it) and `token_to_name`
    // (unambiguous projection only) still leaves the collision case: two
    // names whose projections both land on `token` are excluded from
    // `token_to_name` on purpose (it is ambiguous), so without this check the
    // token would misreport as "matches no known fact" though it IS
    // bound -- just dropped by the collision, same as the needs-name path
    // already reports via `c.skipped`.
    const colliding = try collidingOnToken(arena, c.skipped, token);
    if (colliding.len > 0) {
        var names_buf: std.ArrayList(u8) = .empty;
        for (colliding, 0..) |n, i| {
            if (i > 0) try names_buf.appendSlice(arena, " and ");
            try names_buf.print(arena, "\"{s}\"", .{n});
        }
        return .{ .blocked = try std.fmt.allocPrint(
            arena,
            "{s} matches no single fact -- {s} both collide onto it (see the notice above); bind one explicitly with 'mox facts set <name> <value>' and rename or drop the other, or declare this script's real contract with '# mox: needs <name>'",
            .{ token, names_buf.items },
        ) };
    }
    return .{ .blocked = try std.fmt.allocPrint(
        arena,
        "{s} matches no known fact; bind it with 'mox facts set <name> <value>' so it projects onto this token, or declare this script's real contract with '# mox: needs <name>'",
        .{token},
    ) };
}

/// A whole script's verdict: `record` is its `dimensions.ScriptRecord` (null
/// when discovery has no matching entry -- a defensive fallback, since
/// `dimensions.discover`'s script scan mirrors this module's own runnable
/// shape exactly, so this should not happen in practice; treated as "no
/// contract declared", same as an ordinary script with no needs and no
/// MOX_FACT_* tokens). `needs_unparseable` is checked first: an unparseable
/// `# mox: needs` line makes the whole contract unknowable, regardless of
/// what the token scan would otherwise have found.
pub fn verdictForScript(arena: std.mem.Allocator, record: ?dimensions.ScriptRecord, c: *const Contracts) !ScriptVerdict {
    const rec = record orelse return .{};
    if (rec.needs_unparseable) {
        return .{ .lane = .blocked, .messages = try singleton(
            arena,
            "`# mox: needs` could not be parsed; this script's fact contract is unknowable",
        ) };
    }

    var blocked: std.ArrayList([]const u8) = .empty;
    var declined: std.ArrayList([]const u8) = .empty;

    if (rec.needs) |names| {
        for (names) |n| switch (try classifyName(arena, n, c)) {
            .runs => {},
            .declined => |name| try declined.append(arena, name),
            .blocked => |msg| try blocked.append(arena, msg),
        };
    } else {
        for (rec.scanned_tokens) |t| switch (try classifyToken(arena, t, c)) {
            .runs => {},
            .declined => |name| try declined.append(arena, name),
            .blocked => |msg| try blocked.append(arena, msg),
        };
    }

    if (blocked.items.len > 0) return .{ .lane = .blocked, .messages = try blocked.toOwnedSlice(arena) };
    if (declined.items.len > 0) {
        const joined = try std.mem.join(arena, ", ", declined.items);
        return .{ .lane = .declined, .messages = try singleton(arena, joined) };
    }
    return .{};
}

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

    const names = try arena.alloc([]const u8, facts.len);
    for (facts, 0..) |f, i| names[i] = f.name;
    const projected = try fact_env.project(arena, names);

    var skipped: std.ArrayList([]const u8) = .empty;
    for (facts) |f| {
        const enc = projected.get(f.name) orelse {
            try skipped.append(arena, f.name);
            continue;
        };
        try map.put(enc, f.value);
    }
    return .{ .map = map, .skipped = try skipped.toOwnedSlice(arena) };
}

/// Run every top-level regular file in `scripts_dir` lexicographically, then
/// the scripts inside each matching `<axis>=<value>` subdirectory. A missing
/// scripts dir is not an error (no scripts to run). When `environ_map` is
/// non-null, scripts inherit it instead of mox's own environment.
/// `rel_prefix` (`"scripts/pre"` or `"scripts/post"`) locates each script's
/// `dimensions.ScriptRecord` in `contracts` by its repo-relative path;
/// `contracts` is null only when the caller has none to check against
/// (`--skip-scripts` never reaches here at all, so in practice this is
/// always non-null in `apply`).
pub fn runStage(
    arena: std.mem.Allocator,
    io: Io,
    scripts_dir: []const u8,
    rel_prefix: []const u8,
    bindings: *const dsl.resolver.Resolver,
    environ_map: ?*const EnvironMap,
    contracts: ?*const Contracts,
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
        const rel = try path_mod.joinKey(arena, &.{ rel_prefix, name });
        try runOne(arena, io, path, rel, bindings, environ_map, contracts, timeout_ms, stdout, stderr, &result);
    }
    for (gated_dirs.items) |dname| {
        const sub_path = try std.fs.path.join(arena, &.{ scripts_dir, dname });
        const sub_rel = try path_mod.joinKey(arena, &.{ rel_prefix, dname });
        try runGatedDir(arena, io, sub_path, sub_rel, bindings, environ_map, contracts, timeout_ms, stdout, stderr, &result);
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
    rel_prefix: []const u8,
    bindings: *const dsl.resolver.Resolver,
    environ_map: ?*const EnvironMap,
    contracts: ?*const Contracts,
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
        const rel = try path_mod.joinKey(arena, &.{ rel_prefix, name });
        try runOne(arena, io, path, rel, bindings, environ_map, contracts, timeout_ms, stdout, stderr, result);
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
    rel_path: []const u8,
    bindings: *const dsl.resolver.Resolver,
    environ_map: ?*const EnvironMap,
    contracts: ?*const Contracts,
    timeout_ms: i64,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    result: *Result,
) !void {
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

    // Only a script whose when-gate and directory tuple already matched this
    // machine (both checked above/by the caller) is ever evaluated for its
    // fact contract -- a gate-mismatched script is never blocked for a fact
    // it will never actually need.
    if (contracts) |c| {
        const record = findScriptRecord(c.scripts, rel_path);
        const verdict = try verdictForScript(arena, record, c);
        switch (verdict.lane) {
            .runs => {},
            .declined => {
                result.declined += 1;
                stdout.print("  skipped (declined) {s}: {s}\n", .{ path, verdict.messages[0] }) catch {};
                return;
            },
            .blocked => {
                result.blocked += 1;
                for (verdict.messages) |m| stderr.print("mox apply: {s}: blocked: {s}\n", .{ path, m }) catch {};
                return;
            },
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
    var bindings_r: dsl.resolver.Resolver = .{ .live = &.{ .bindings = &bindings } };

    try testing.expect(try axisDirMatches(a, "os=windows", &bindings_r));
    try testing.expect(try axisDirMatches(a, "os=windows+profile=work", &bindings_r));
    try testing.expect(!try axisDirMatches(a, "os=darwin", &bindings_r));
    // A plain directory name is not an axis tuple: ignored, not an error.
    try testing.expect(!try axisDirMatches(a, "windows", &bindings_r));
    try testing.expect(!try axisDirMatches(a, "helpers", &bindings_r));
}

// Script fact contract lane tests

fn testDim(name: []const u8) dimensions.Dimension {
    return .{
        .name = name,
        .roles = .{},
        .observed_values = &.{},
        .capture_defaults = &.{},
        .declared_defaults = &.{},
        .asking_condition = null,
        .provenance = .{ .source_count = 0, .needing_scripts = &.{} },
    };
}

fn testRecord(path: []const u8, needs: ?[]const []const u8, scanned_tokens: []const []const u8) dimensions.ScriptRecord {
    return .{
        .path = path,
        .when_head = null,
        .scanned_tokens = scanned_tokens,
        .needs = needs,
        .needs_unparseable = false,
    };
}

test "verdictForScript: needed fact present non-empty -> runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = EnvironMap.init(a);
    try env.put("MOX_FACT_PROFILE", "work");
    const dims = [_]dimensions.Dimension{testDim("profile")};
    const custom = [_]Fact{.{ .name = "profile", .value = "work" }};
    const c = try buildContracts(a, &dims, &.{}, &.{}, &custom, &.{}, &env);

    const rec = testRecord("scripts/pre/x.sh", &.{"profile"}, &.{});
    const v = try verdictForScript(a, rec, &c);
    try testing.expectEqual(.runs, v.lane);
    try testing.expectEqual(@as(usize, 0), v.messages.len);
}

test "verdictForScript: needed fact bound empty -> skipped (declined), green, one aggregated line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = EnvironMap.init(a);
    try env.put("MOX_FACT_PROFILE", "");
    const dims = [_]dimensions.Dimension{testDim("profile")};
    const custom = [_]Fact{.{ .name = "profile", .value = "" }};
    const c = try buildContracts(a, &dims, &.{}, &.{}, &custom, &.{}, &env);

    const rec = testRecord("scripts/pre/x.sh", &.{"profile"}, &.{});
    const v = try verdictForScript(a, rec, &c);
    try testing.expectEqual(.declined, v.lane);
    try testing.expectEqual(@as(usize, 1), v.messages.len);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "profile") != null);
}

test "verdictForScript: needed fact never bound, interviewable dimension -> blocked naming `mox facts set`" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = EnvironMap.init(a);
    const dims = [_]dimensions.Dimension{testDim("profile")};
    const c = try buildContracts(a, &dims, &.{}, &.{}, &.{}, &.{}, &env);

    const rec = testRecord("scripts/pre/x.sh", &.{"profile"}, &.{});
    const v = try verdictForScript(a, rec, &c);
    try testing.expectEqual(.blocked, v.lane);
    try testing.expectEqual(@as(usize, 1), v.messages.len);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "profile") != null);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "mox facts set profile") != null);
}

test "verdictForScript: needs names a built-in -> blocked, names the gate/directory-tuple remedy, not the generic unknown-fact message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = EnvironMap.init(a);
    const c = try buildContracts(a, &.{}, &.{}, &.{}, &.{}, &.{}, &env);

    const rec = testRecord("scripts/pre/x.sh", &.{"os"}, &.{});
    const v = try verdictForScript(a, rec, &c);
    try testing.expectEqual(.blocked, v.lane);
    try testing.expectEqual(@as(usize, 1), v.messages.len);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "MOX_FACT_OS") != null);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "# mox: when os=") != null);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "os=<value>/") != null);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "names no fact mox can bind or derive") == null);
}

test "verdictForScript: needed fact is an unresolved derived fact -> blocked naming its env/candidates remediation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = EnvironMap.init(a);
    const derived = [_]derived_facts.DeclaredRow{.{
        .name = "brew_prefix",
        .env = "HOMEBREW_PREFIX",
        .candidates = &.{ "/opt/homebrew", "/usr/local" },
    }};
    const c = try buildContracts(a, &.{}, &.{}, &derived, &.{}, &.{}, &env);

    const rec = testRecord("scripts/pre/x.sh", &.{"brew_prefix"}, &.{});
    const v = try verdictForScript(a, rec, &c);
    try testing.expectEqual(.blocked, v.lane);
    try testing.expectEqual(@as(usize, 1), v.messages.len);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "brew_prefix") != null);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "HOMEBREW_PREFIX") != null);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "/opt/homebrew") != null);
}

test "verdictForScript: a scanned token mapping to no known fact -> blocked, fail-closed, names the token and both remedies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = EnvironMap.init(a);
    const c = try buildContracts(a, &.{}, &.{}, &.{}, &.{}, &.{}, &env);

    // No `needs` line: falls to the scanned-token path.
    const rec = testRecord("scripts/pre/x.sh", null, &.{"MOX_FACT_NONSENSE"});
    const v = try verdictForScript(a, rec, &c);
    try testing.expectEqual(.blocked, v.lane);
    try testing.expectEqual(@as(usize, 1), v.messages.len);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "MOX_FACT_NONSENSE") != null);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "mox facts set") != null);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "# mox: needs") != null);
}

test "verdictForScript: needs_unparseable is blocked regardless of tokens, contract unknowable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = EnvironMap.init(a);
    const c = try buildContracts(a, &.{}, &.{}, &.{}, &.{}, &.{}, &env);

    const rec: dimensions.ScriptRecord = .{
        .path = "scripts/pre/x.sh",
        .when_head = null,
        .scanned_tokens = &.{},
        .needs = null,
        .needs_unparseable = true,
    };
    const v = try verdictForScript(a, rec, &c);
    try testing.expectEqual(.blocked, v.lane);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "unknowable") != null);
}

test "verdictForScript: a projection-collision-dropped bound fact is unavailable -> blocked naming the collision" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `cloud.backend` and `cloud-backend` both sanitize to
    // MOX_FACT_CLOUD_BACKEND: buildScriptEnv drops both (existing skip-both
    // behavior), so a script needing either is blocked, not silently run
    // unguarded.
    var parent = EnvironMap.init(a);
    const facts = [_]Fact{
        .{ .name = "cloud.backend", .value = "gdrive" },
        .{ .name = "cloud-backend", .value = "dropbox" },
    };
    var env_result = try buildScriptEnv(a, Environ{ .map = &parent }, "/repo", "/state", "/home/me", &facts);
    const dims = [_]dimensions.Dimension{testDim("cloud.backend")};
    const c = try buildContracts(a, &dims, &.{}, &.{}, &facts, env_result.skipped, &env_result.map);

    const rec = testRecord("scripts/pre/x.sh", &.{"cloud.backend"}, &.{});
    const v = try verdictForScript(a, rec, &c);
    try testing.expectEqual(.blocked, v.lane);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "cloud.backend") != null);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "collide") != null);
}

test "verdictForScript: a scanned token landing on a projection collision -> blocked naming both colliding facts, not the generic unknown-token message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Same collision as the needs-path test above, but reached via the
    // scanned-token path (no `# mox: needs` line): `token_to_name` has no
    // entry for MOX_FACT_CLOUD_BACKEND either (ambiguous on purpose), so
    // without consulting `c.skipped` this would misreport as "matches no
    // known fact" though the fact IS bound, just collision-dropped.
    var parent = EnvironMap.init(a);
    const facts = [_]Fact{
        .{ .name = "cloud.backend", .value = "gdrive" },
        .{ .name = "cloud-backend", .value = "dropbox" },
    };
    var env_result = try buildScriptEnv(a, Environ{ .map = &parent }, "/repo", "/state", "/home/me", &facts);
    const c = try buildContracts(a, &.{}, &.{}, &.{}, &facts, env_result.skipped, &env_result.map);

    const rec = testRecord("scripts/pre/x.sh", null, &.{"MOX_FACT_CLOUD_BACKEND"});
    const v = try verdictForScript(a, rec, &c);
    try testing.expectEqual(.blocked, v.lane);
    try testing.expectEqual(@as(usize, 1), v.messages.len);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "cloud.backend") != null);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "cloud-backend") != null);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "collide") != null);
    try testing.expect(std.mem.indexOf(u8, v.messages[0], "matches no known fact") == null);
}

test "verdictForScript: empty needs (explicit none) always runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = EnvironMap.init(a);
    const c = try buildContracts(a, &.{}, &.{}, &.{}, &.{}, &.{}, &env);
    const rec = testRecord("scripts/pre/x.sh", &.{}, &.{"MOX_FACT_ANYTHING"});
    const v = try verdictForScript(a, rec, &c);
    try testing.expectEqual(.runs, v.lane);
}

test "verdictForScript: no matching discovery record is treated as no contract, runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var env = EnvironMap.init(a);
    const c = try buildContracts(a, &.{}, &.{}, &.{}, &.{}, &.{}, &env);
    const v = try verdictForScript(a, null, &c);
    try testing.expectEqual(.runs, v.lane);
}

const std = @import("std");

const Io = std.Io;
const Environ = @import("env").Env;
const EnvironMap = std.process.Environ.Map;
const path_lookup = @import("path_lookup.zig");
const source_path = @import("../source/path.zig");
const facts_mod = @import("facts.zig");
const dsl = @import("../dsl/root.zig");

/// A user-supplied machine fact loaded from `$XDG_CONFIG_HOME/mox/facts.toml`.
/// Facts extend the built-in MachineState fields with values mox can't auto-
/// detect (email, profile, locale, signing keys, etc.) so they're available
/// for axis matching and `<machine.X>` interpolation.
pub const Fact = struct {
    name: []const u8,
    value: []const u8,
};

/// Snapshot of machine state captured at the start of `mox apply`.
/// All strings are arena-owned. The arena must outlive the MachineState.
pub const MachineState = struct {
    os: []const u8,
    arch: []const u8,
    hostname: []const u8,
    /// True when `hostname` could not be determined (gethostname failure on
    /// POSIX, unset COMPUTERNAME on Windows) and fell back to the literal
    /// "unknown": a `machine=` gate silently never matches and "unknown"
    /// silently interpolates unless a caller warns on this.
    hostname_fallback: bool = false,
    username: []const u8,
    /// True when `username` could not be determined (USER/USERNAME both
    /// unset) and fell back to the literal "unknown", same caveat as
    /// `hostname_fallback`.
    username_fallback: bool = false,
    home: []const u8,
    /// The `tool=`/`<machine.tool_path.X>` resolution layer: probes and
    /// memoizes against this machine's `$PATH` (plus tool-home bin
    /// directories, D2b) for any name, on first ask. Null only for a
    /// MachineState built by hand (every test fixture); `capture` always
    /// supplies one. Also the probe layer a `Resolver.Live` built from this
    /// snapshot's bindings falls through to for `tool=`.
    tool_probe: ?*path_lookup.ToolProbe = null,
    /// The `env=`/`<env.NAME>` resolution layer: reads this machine's
    /// captured environ directly for any name, on first ask. Null only for a
    /// MachineState built by hand (every test fixture); `capture` always
    /// supplies one. Also the probe layer a `Resolver.Live` built from this
    /// snapshot's bindings falls through to for `env=`.
    env_probe: ?*EnvProbe = null,
    brew_prefix: []const u8,
    cargo_home: []const u8,
    gopath: []const u8,
    pnpm_home: []const u8,
    xdg_config_home: []const u8,
    xdg_cache_home: []const u8,
    xdg_data_home: []const u8,
    xdg_state_home: []const u8,
    /// User-supplied facts from `$XDG_CONFIG_HOME/mox/facts.toml`. Empty when
    /// the file is absent. A built-in field with the same name takes priority.
    custom_facts: []const Fact = &.{},
    /// Top-level `facts.toml` keys dropped for a non-string value. Loud on
    /// capture use (a gate naming the key just never matches); named here so
    /// a caller can warn instead of leaving the drop silent too.
    skipped_fact_keys: []const []const u8 = &.{},

    /// This snapshot's lazy tool-probe layer, ready to hand to
    /// `dsl.resolver.Resolver.Live.probe`. Null only when `tool_probe` itself
    /// is null (a hand-built MachineState in a test, never one `capture`
    /// returned).
    pub fn probe(self: MachineState) ?dsl.resolver.Resolver.Probe {
        const tp = self.tool_probe orelse return null;
        return tp.probe();
    }

    /// This snapshot's lazy env-probe layer, ready to hand to
    /// `dsl.resolver.Resolver.Live.env`. Null only when `env_probe` itself is
    /// null (a hand-built MachineState in a test, never one `capture`
    /// returned).
    pub fn envProbe(self: MachineState) ?dsl.resolver.Resolver.EnvProbe {
        const ep = self.env_probe orelse return null;
        return ep.probe();
    }
};

/// Lazy, on-demand `env=NAME` / `<env.NAME>` answer for any name: reads this
/// machine's captured environ directly rather than a process-global lookup.
/// No memoization -- `Env.get` is already an O(1) map/syscall-free read,
/// unlike the PATH scan `ToolProbe` exists to batch. Empty-is-unset by
/// construction (`Env.get`'s own contract).
pub const EnvProbe = struct {
    arena: std.mem.Allocator,
    environ: Environ,

    pub fn init(arena: std.mem.Allocator, environ: Environ) EnvProbe {
        return .{ .arena = arena, .environ = environ };
    }

    /// The value of `name`, or null when unset or set-but-empty.
    pub fn get(self: *EnvProbe, name: []const u8) ?[]const u8 {
        return self.environ.get(self.arena, name);
    }

    /// Adapt this reader to `dsl.resolver.Resolver.EnvProbe`, so a `Resolver`
    /// built over this machine's bindings can fall through to it for any
    /// `env=` name (or `<env.NAME>` interpolation member).
    pub fn probe(self: *EnvProbe) dsl.resolver.Resolver.EnvProbe {
        return .{ .ctx = self, .getFn = getTrampoline };
    }

    fn getTrampoline(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *EnvProbe = @ptrCast(@alignCast(ctx));
        return self.get(name);
    }
};

/// One-line notice for a legacy `<xdg_config_home>/mox/extras.toml` still on
/// disk: 0.5.0 no longer reads it (tools/envs now resolve on demand for any
/// name, so the extension list it existed to hand-patch has no reason to
/// exist), so a caller that captures prints this once rather than leaving an
/// unread file's silence unexplained. Null when no file is there.
pub fn extrasNotice(arena: std.mem.Allocator, io: Io, xdg_config_home: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(arena, &.{ xdg_config_home, "mox", "extras.toml" });
    Io.Dir.cwd().access(io, path, .{}) catch return null;
    return try std.fmt.allocPrint(
        arena,
        "{s} exists but is no longer read (tools and envs now resolve on demand for any name); delete it to silence this notice",
        .{path},
    );
}

/// Capture a snapshot of the current machine state.
///
/// Reads OS/arch from the build (overridable via `MOX_OS`/`MOX_ARCH`, so the
/// os/arch axes are injectable), hostname from the OS, identity and named
/// paths from `environ`, and probes tool availability against `$PATH`.
/// All returned strings are owned by `arena`.
pub fn capture(arena: std.mem.Allocator, io: Io, environ: Environ) !MachineState {
    const builtin = @import("builtin");

    const os_str = envOr(arena, environ, "MOX_OS") orelse osAxisValue(builtin.os.tag);
    const arch_str = envOr(arena, environ, "MOX_ARCH") orelse @tagName(builtin.cpu.arch);

    // Windows has no gethostname/HOST_NAME_MAX under std.posix; the machine
    // name comes from the environment there, as the username and home do.
    var hostname_buf: [if (builtin.os.tag == .windows) 0 else std.posix.HOST_NAME_MAX]u8 = undefined;
    var hostname_fallback = false;
    const hostname_slice: []const u8 = if (builtin.os.tag == .windows)
        (envOr(arena, environ, "COMPUTERNAME") orelse blk: {
            hostname_fallback = true;
            break :blk "unknown";
        })
    else
        (std.posix.gethostname(&hostname_buf) catch blk: {
            hostname_fallback = true;
            break :blk "unknown";
        });

    var username_fallback = false;
    const username = envOr(arena, environ, "USER") orelse
        envOr(arena, environ, "USERNAME") orelse blk: {
        username_fallback = true;
        break :blk try arena.dupe(u8, "unknown");
    };

    const home = envOr(arena, environ, "HOME") orelse
        envOr(arena, environ, "USERPROFILE") orelse
        return error.HomeNotSet;

    // Tool-home detection runs ahead of the `$PATH` scan (D2b) so their bin
    // directories can join the very same `Listing` build: a fresh Homebrew
    // (or cargo/go/pnpm) install is visible to `tool=` the moment its home
    // exists, not just once its shellenv line is itself applied and PATH
    // grows on some LATER process's re-exec.
    const brew_prefix = try detectBrewPrefix(arena, io, environ, builtin.os.tag, home);
    const cargo_home = try resolveToolHome(arena, io, environ, "CARGO_HOME", home, ".cargo");
    const gopath = try resolveToolHome(arena, io, environ, "GOPATH", home, "go");
    const pnpm_home = envOr(arena, environ, "PNPM_HOME") orelse try arena.dupe(u8, "");
    const tool_home_bin_dirs = try toolHomeBinDirs(arena, brew_prefix, cargo_home, gopath, pnpm_home);

    // One `$PATH` (+ tool-home) enumeration for the whole capture, seeding the
    // lazy tool probe's listing cache so its first per-name lookup never
    // rebuilds it.
    const path_listing = try path_lookup.buildListing(arena, io, environ, tool_home_bin_dirs);

    // A fresh probe every capture, so a re-capture (facts interview, the
    // post-pre-script re-capture) starts with an empty memo instead of
    // carrying one over from before whatever just changed.
    const tool_probe = try arena.create(path_lookup.ToolProbe);
    tool_probe.* = path_lookup.ToolProbe.init(arena, io, environ);
    tool_probe.seedListing(path_listing);

    // A fresh env probe every capture, mirroring the tool probe: no state to
    // reset here (no memo), but a stable arena-owned pointer is still needed
    // since `EnvProbe.probe()` hands out a `ctx` pointer into it.
    const env_probe = try arena.create(EnvProbe);
    env_probe.* = EnvProbe.init(arena, environ);

    const xdg_config_home = try resolveXdg(arena, environ, "XDG_CONFIG_HOME", home, ".config");
    const xdg_cache_home = try resolveXdg(arena, environ, "XDG_CACHE_HOME", home, ".cache");
    const xdg_data_home = try resolveXdg(arena, environ, "XDG_DATA_HOME", home, ".local/share");
    const xdg_state_home = try resolveXdg(arena, environ, "XDG_STATE_HOME", home, ".local/state");

    const facts_path = try std.fs.path.join(arena, &.{ xdg_config_home, "mox", "facts.toml" });
    const facts_result = try facts_mod.load(arena, io, facts_path, null);

    return .{
        .os = os_str,
        .arch = arch_str,
        .hostname = try arena.dupe(u8, hostname_slice),
        .hostname_fallback = hostname_fallback,
        .username = username,
        .username_fallback = username_fallback,
        .home = home,
        .tool_probe = tool_probe,
        .env_probe = env_probe,
        .brew_prefix = brew_prefix,
        .cargo_home = cargo_home,
        .gopath = gopath,
        .pnpm_home = pnpm_home,
        .xdg_config_home = xdg_config_home,
        .xdg_cache_home = xdg_cache_home,
        .xdg_data_home = xdg_data_home,
        .xdg_state_home = xdg_state_home,
        .custom_facts = facts_result.facts,
        .skipped_fact_keys = facts_result.skipped,
    };
}

/// Fetch an env var, or null when absent OR present-but-empty. An empty value
/// is treated as unset so an empty HOME/XDG_* never yields a cwd-relative path.
fn envOr(arena: std.mem.Allocator, environ: Environ, key: []const u8) ?[]const u8 {
    const v = environ.getAlloc(arena, key) catch return null;
    return if (v.len == 0) null else v;
}

/// Canonical `os` axis value. Zig names macOS `.macos`, but the dotfiles
/// ecosystem (uname, chezmoi, Go GOOS) calls it `darwin`; use that so overlays
/// and `when os=...` expressions match what users already write.
pub fn osAxisValue(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .macos => "darwin",
        else => @tagName(os_tag),
    };
}

/// True when `v` is `osAxisValue` of some real zig `Os.Tag` (macOS spelled
/// `darwin`, per `osAxisValue`). The closed set an `os=` literal is ever
/// actually compared against; shared by `mox doctor`'s repo-wide sweep and
/// `mox apply`'s whole-file-gate advisory.
pub fn isValidOsValue(v: []const u8) bool {
    inline for (@typeInfo(std.Target.Os.Tag).@"enum".fields) |f| {
        if (std.mem.eql(u8, v, osAxisValue(@enumFromInt(f.value)))) return true;
    }
    return false;
}

/// True when `v` names a real zig `Cpu.Arch` tag: the closed set an `arch=`
/// literal is ever actually compared against.
pub fn isValidArchValue(v: []const u8) bool {
    inline for (@typeInfo(std.Target.Cpu.Arch).@"enum".fields) |f| {
        if (std.mem.eql(u8, v, f.name)) return true;
    }
    return false;
}

test "isValidOsValue/isValidArchValue: accept the real zig tags, reject typos" {
    try std.testing.expect(isValidOsValue("darwin"));
    try std.testing.expect(isValidOsValue("linux"));
    try std.testing.expect(isValidOsValue("windows"));
    try std.testing.expect(!isValidOsValue("macos"));
    try std.testing.expect(!isValidOsValue("osx"));

    try std.testing.expect(isValidArchValue("aarch64"));
    try std.testing.expect(isValidArchValue("x86_64"));
    try std.testing.expect(!isValidArchValue("arm64"));
}

test "capture: both HOME and USERPROFILE unset or empty errors instead of defaulting to cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var map = EnvironMap.init(a);
    try std.testing.expectError(error.HomeNotSet, capture(a, std.testing.io, Environ{ .map = &map }));

    // An empty value is unset too, same as absent.
    try map.put("HOME", "");
    try std.testing.expectError(error.HomeNotSet, capture(a, std.testing.io, Environ{ .map = &map }));
}

test "capture: USER and USERNAME unset falls back to \"unknown\" and flags username_fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var map = EnvironMap.init(a);
    try map.put("HOME", "/home/whoever");

    const m = try capture(a, std.testing.io, Environ{ .map = &map });
    try std.testing.expectEqualStrings("unknown", m.username);
    try std.testing.expect(m.username_fallback);
    // The real hostname resolves on every CI/dev machine; only the flag is
    // asserted false here, since forcing a real gethostname failure needs no
    // portable seam.
    try std.testing.expect(!m.hostname_fallback);
}

test "capture: a defined USER is used verbatim, username_fallback stays false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var map = EnvironMap.init(a);
    try map.put("HOME", "/home/whoever");
    try map.put("USER", "tester");

    const m = try capture(a, std.testing.io, Environ{ .map = &map });
    try std.testing.expectEqualStrings("tester", m.username);
    try std.testing.expect(!m.username_fallback);
}

test "resolveXdg: an empty env value falls back to the home default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var map = EnvironMap.init(a);
    // Present but empty: must be treated as unset, not as a cwd-relative "".
    try map.put("XDG_STATE_HOME", "");
    const env = Environ{ .map = &map };
    const got = try resolveXdg(a, env, "XDG_STATE_HOME", "/home/x", ".local/state");
    const want = try std.fs.path.join(a, &.{ "/home/x", ".local", "state" });
    try std.testing.expectEqualStrings(want, got);
}

test "osAxisValue: macOS reports darwin, others pass through" {
    try std.testing.expectEqualStrings("darwin", osAxisValue(.macos));
    try std.testing.expectEqualStrings("linux", osAxisValue(.linux));
    try std.testing.expectEqualStrings("windows", osAxisValue(.windows));
}

/// Absolute path to `<tmp>/sub` via the canonical `<cwd>/.zig-cache/tmp/<id>`
/// location, matching the pattern used across the other source-tree tests.
fn tmpAbsPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, sub: []const u8) ![]u8 {
    const io = std.testing.io;
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    if (sub.len == 0) return std.fs.path.join(allocator, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path });
    return std.fs.path.join(allocator, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path, sub });
}

test "detectBrewPrefix: HOMEBREW_PREFIX is consulted ahead of the hardcoded candidates" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "custom/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "custom/bin/brew", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = try tmpAbsPath(a, &tmp, "custom");

    var map = EnvironMap.init(a);
    try map.put("HOMEBREW_PREFIX", prefix);
    const got = try detectBrewPrefix(a, io, Environ{ .map = &map }, .macos, "/home/x");
    try std.testing.expectEqualStrings(prefix, got);
}

test "detectBrewPrefix: HOMEBREW_PREFIX pointing nowhere falls back to hardcoded candidates" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var map = EnvironMap.init(a);
    try map.put("HOMEBREW_PREFIX", "/definitely/does/not/exist");
    const got = try detectBrewPrefix(a, io, Environ{ .map = &map }, .linux, "/home/x");
    try std.testing.expectEqualStrings("", got);
}

test "detectBrewPrefix: a non-root <home>/.linuxbrew install is found on Linux" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".linuxbrew/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = ".linuxbrew/bin/brew", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try tmpAbsPath(a, &tmp, "");
    const want = try std.fs.path.join(a, &.{ home, ".linuxbrew" });

    var map = EnvironMap.init(a);
    const got = try detectBrewPrefix(a, io, Environ{ .map = &map }, .linux, home);
    try std.testing.expectEqualStrings(want, got);
}

test "detectBrewPrefix: empty home skips the <home>/.linuxbrew candidate without erroring" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var map = EnvironMap.init(a);
    const got = try detectBrewPrefix(a, io, Environ{ .map = &map }, .linux, "");
    try std.testing.expectEqualStrings("", got);
}

/// Detect the active Homebrew/Linuxbrew prefix. A caller-set `HOMEBREW_PREFIX`
/// (brew's own `shellenv` export) names the install brew itself picked, so it
/// is tried before any hardcoded guess -- an override of the default install
/// location would otherwise never be found. Falls back to the conventional
/// per-OS locations, including the non-root `<home>/.linuxbrew` install
/// alongside the system-wide `/home/linuxbrew/.linuxbrew` one.
fn detectBrewPrefix(
    arena: std.mem.Allocator,
    io: Io,
    environ: Environ,
    os_tag: std.Target.Os.Tag,
    home: []const u8,
) ![]const u8 {
    if (envOr(arena, environ, "HOMEBREW_PREFIX")) |prefix| {
        if (hasBrewBin(arena, io, prefix)) return try arena.dupe(u8, prefix);
    }

    var candidates: std.ArrayList([]const u8) = .empty;
    if (os_tag == .macos) {
        try candidates.appendSlice(arena, &.{ "/opt/homebrew", "/usr/local" });
    } else {
        try candidates.append(arena, "/home/linuxbrew/.linuxbrew");
        if (home.len > 0) {
            try candidates.append(arena, try std.fs.path.join(arena, &.{ home, ".linuxbrew" }));
        }
        try candidates.append(arena, "/usr/local");
    }

    for (candidates.items) |dir| {
        if (hasBrewBin(arena, io, dir)) return try arena.dupe(u8, dir);
    }
    return try arena.dupe(u8, "");
}

fn hasBrewBin(arena: std.mem.Allocator, io: Io, dir: []const u8) bool {
    const brew_bin = std.fs.path.join(arena, &.{ dir, "bin", "brew" }) catch return false;
    Io.Dir.cwd().access(io, brew_bin, .{}) catch return false;
    return true;
}

fn resolveXdg(
    arena: std.mem.Allocator,
    environ: Environ,
    env_name: []const u8,
    home: []const u8,
    fallback_subdir: []const u8,
) ![]const u8 {
    if (envOr(arena, environ, env_name)) |v| return v;
    if (home.len == 0) return try arena.dupe(u8, "");
    // The fallback is written `.local/state`, so joining it whole would leave
    // the separators mixed where the platform's is not `/`.
    return try source_path.joinKeyOnto(arena, home, fallback_subdir);
}

fn resolveToolHome(
    arena: std.mem.Allocator,
    io: Io,
    environ: Environ,
    env_name: []const u8,
    home: []const u8,
    fallback_subdir: []const u8,
) ![]const u8 {
    const path = if (envOr(arena, environ, env_name)) |v|
        v
    else if (home.len == 0)
        try arena.dupe(u8, "")
    else
        try std.fs.path.join(arena, &.{ home, fallback_subdir });

    if (path.len == 0) return path;
    Io.Dir.cwd().access(io, path, .{}) catch return arena.dupe(u8, "");
    return path;
}

/// This machine's tool-home bin directories, in the fixed order D2b
/// specifies: `<brew_prefix>/bin`, `<cargo_home>/bin`, `<gopath>/bin`,
/// `<pnpm_home>` (already a bin dir, unlike the other three). A fact that
/// resolved empty (unset, or its detection rule found nothing) contributes
/// no directory rather than joining "" into a bogus root-relative path.
fn toolHomeBinDirs(
    arena: std.mem.Allocator,
    brew_prefix: []const u8,
    cargo_home: []const u8,
    gopath: []const u8,
    pnpm_home: []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (brew_prefix.len > 0) try out.append(arena, try std.fs.path.join(arena, &.{ brew_prefix, "bin" }));
    if (cargo_home.len > 0) try out.append(arena, try std.fs.path.join(arena, &.{ cargo_home, "bin" }));
    if (gopath.len > 0) try out.append(arena, try std.fs.path.join(arena, &.{ gopath, "bin" }));
    if (pnpm_home.len > 0) try out.append(arena, pnpm_home);
    return out.toOwnedSlice(arena);
}

test "MachineState type is constructible" {
    const m = MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "test",
        .username = "tester",
        .home = "/home/tester",
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };
    try std.testing.expectEqualStrings("linux", m.os);
}

test "capture returns nonempty hostname" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try capture(arena.allocator(), std.testing.io, Environ{ .process = std.testing.environ });
    try std.testing.expect(m.hostname.len > 0);
}

test "capture: a tool that exists only in cargo_home/bin, never on PATH, still resolves via tool_probe" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "cargo/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "cargo/bin/only-in-cargo-home", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try tmpAbsPath(a, &tmp, "");
    const cargo_home = try tmpAbsPath(a, &tmp, "cargo");

    var map = EnvironMap.init(a);
    try map.put("HOME", home);
    try map.put("CARGO_HOME", cargo_home);
    // No PATH at all: the only way to reach the binary is the tool-home layer.

    const m = try capture(a, io, Environ{ .map = &map });
    try std.testing.expectEqualStrings(cargo_home, m.cargo_home);
    // Resolves only through the widened `Listing` (D2b): the tool probe is
    // the sole resolution path for `tool=`, so a name never on `$PATH`
    // proper still resolves via the tool-home bin directory.
    try std.testing.expect(m.tool_probe.?.present("only-in-cargo-home"));
}

test "capture: a facts.toml key named for a multi-value axis errors loudly" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "config/mox");
    try tmp.dir.writeFile(io, .{ .sub_path = "config/mox/facts.toml", .data = "tool = \"x\"\n" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try tmpAbsPath(a, &tmp, "");
    const xdg_config_home = try tmpAbsPath(a, &tmp, "config");

    var map = EnvironMap.init(a);
    try map.put("HOME", home);
    try map.put("XDG_CONFIG_HOME", xdg_config_home);

    try std.testing.expectError(error.ReservedFactName, capture(a, io, Environ{ .map = &map }));
}

test "extrasNotice: names the path and that it is no longer read, when the file exists" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "config/mox");
    try tmp.dir.writeFile(io, .{ .sub_path = "config/mox/extras.toml", .data = "tools = [\"zk\"]\n" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const xdg_config_home = try tmpAbsPath(a, &tmp, "config");

    const notice = (try extrasNotice(a, io, xdg_config_home)).?;
    try std.testing.expect(std.mem.indexOf(u8, notice, "extras.toml") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "no longer read") != null);
}

test "extrasNotice: null when no file is there" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const xdg_config_home = try tmpAbsPath(a, &tmp, "config");

    try std.testing.expect(try extrasNotice(a, io, xdg_config_home) == null);
}

test "capture: an extras.toml present does not fail capture, and its tools still resolve lazily" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "config/mox");
    try tmp.dir.writeFile(io, .{ .sub_path = "config/mox/extras.toml", .data = "tools = [\"zk\"]\n" });
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/zk", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try tmpAbsPath(a, &tmp, "");
    const xdg_config_home = try tmpAbsPath(a, &tmp, "config");
    const bin_dir = try tmpAbsPath(a, &tmp, "bin");

    var map = EnvironMap.init(a);
    try map.put("HOME", home);
    try map.put("XDG_CONFIG_HOME", xdg_config_home);
    try map.put("PATH", bin_dir);

    const m = try capture(a, io, Environ{ .map = &map });
    // "zk" was never a watched name; it resolves purely because it is on
    // PATH, the same as any other unlisted name -- extras.toml being present
    // (and unread) changes nothing.
    try std.testing.expect(m.tool_probe.?.present("zk"));
}

test "EnvProbe.get: an unwatched name reads from the captured environ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var map = EnvironMap.init(a);
    try map.put("MOX_UNWATCHED_SET_VAR", "hello");
    var probe = EnvProbe.init(a, Environ{ .map = &map });

    try std.testing.expectEqualStrings("hello", probe.get("MOX_UNWATCHED_SET_VAR").?);
    try std.testing.expect(probe.get("MOX_UNWATCHED_UNSET_VAR") == null);
}

test "EnvProbe.get: a set-but-empty value reads as unset, same as env_values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var map = EnvironMap.init(a);
    try map.put("MOX_UNWATCHED_EMPTY_VAR", "");
    var probe = EnvProbe.init(a, Environ{ .map = &map });

    try std.testing.expect(probe.get("MOX_UNWATCHED_EMPTY_VAR") == null);
}

test "Resolver via EnvProbe.probe(): fixed variant never consults the environ, even for a name confirmed set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var map = EnvironMap.init(a);
    try map.put("MOX_REALLY_SET_VAR", "1");
    var probe = EnvProbe.init(a, Environ{ .map = &map });
    // Confirm the name really is set by probing directly -- the point being
    // disproven is that `fixed` would ever do this itself.
    try std.testing.expectEqualStrings("1", probe.get("MOX_REALLY_SET_VAR").?);

    var empty = std.StringHashMap([]const u8).init(a);
    const fixed: dsl.resolver.Resolver = .{ .fixed = &empty };
    try std.testing.expect(!fixed.has("env", "MOX_REALLY_SET_VAR"));

    // Contrast: the live variant, wired to the very same probe, DOES resolve
    // it -- proving the difference is `fixed` never touching the environ at
    // all, not some incidental miss.
    var bindings = std.StringHashMap([]const u8).init(a);
    const live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings, .env = probe.probe() };
    const live_r: dsl.resolver.Resolver = .{ .live = &live };
    try std.testing.expect(live_r.has("env", "MOX_REALLY_SET_VAR"));
}

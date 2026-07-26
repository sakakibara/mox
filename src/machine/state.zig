const std = @import("std");

const Io = std.Io;
const Environ = @import("env").Env;
const EnvironMap = std.process.Environ.Map;
const path_lookup = @import("path_lookup.zig");
const source_path = @import("../source/path.zig");
const facts_mod = @import("facts.zig");
const extras_mod = @import("extras.zig");

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
    tools_on_path: []const []const u8,
    /// Same set as `tools_on_path` but with the first-hit absolute path
    /// alongside each name. Used for `<machine.tool_path.X>` interpolation
    /// (chezmoi's `lookPath` equivalent).
    tool_paths: []const path_lookup.Found = &.{},
    defined_envs: []const []const u8,
    /// Map from env-var name to value, for the subset of vars in
    /// ENV_WATCH_LIST that were defined and non-empty. Used by
    /// `<env.NAME>` interpolation.
    env_values: []const Fact = &.{},
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
};

/// Tools to probe via `$PATH` lookup. The presence of a name in
/// `MachineState.tools_on_path` lets policies condition on tooling without
/// running each binary.
const TOOL_WATCH_LIST = [_][]const u8{
    "fd",           "fdfind",  "rg",        "bat",        "batcat",
    "eza",          "exa",     "lazygit",   "lazydocker", "starship",
    "zoxide",       "atuin",   "fzf",       "skim",       "delta",
    "git-delta",    "yazi",    "broot",     "navi",       "tldr",
    "duf",          "dust",    "btm",       "btop",       "htop",
    "hyperfine",    "sd",      "watchexec", "tokei",      "topiary",
    "ast-grep",     "grex",    "gum",       "glow",       "frum",
    "mise",         "asdf",    "pnpm",      "yarn",       "deno",
    "bun",          "uv",      "ruff",      "pyright",    "nvim",
    "vim",          "tmux",    "zellij",    "fish",       "zsh",
    "bash",         "git",     "gh",        "gpg",        "ssh",
    "op",           "doppler", "brew",      "apt",        "dnf",
    "yum",          "pacman",  "go",        "rustc",      "cargo",
    "node",         "python",  "python3",   "ruby",       "erl",
    "elixir",       "lua",     "k9s",       "kubectl",    "helm",
    "docker",       "podman",  "task",      "make",       "just",
    // Windows binaries that may appear on a WSL `$PATH`. The `.exe`
    // suffix matters: `lookPath "starship.exe"` is the chezmoi-side
    // signal for "running under WSL with a Windows starship binary."
    "starship.exe",
};

/// Environment variables to record (by name) when defined and non-empty.
/// Captures session/runtime context like WSL, container indicators, secret
/// managers, and orchestrator selectors.
///
/// Both presence (for `env=NAME` axis matching) and value (for `<env.NAME>`
/// interpolation) are captured.
const ENV_WATCH_LIST = [_][]const u8{
    "WSL_DISTRO_NAME",   "WSLENV",            "CODESPACES",
    "REMOTE_CONTAINERS", "DEVCONTAINER",      "TERM_PROGRAM",
    "SSH_CONNECTION",    "SSH_CLIENT",        "TMUX",
    "ZELLIJ",            "STY",               "DISPLAY",
    "WAYLAND_DISPLAY",   "DOCKER_HOST",       "KUBECONFIG",
    "AWS_PROFILE",       "GCP_PROJECT",       "AZURE_SUBSCRIPTION_ID",
    "VIRTUAL_ENV",       "CONDA_DEFAULT_ENV",
    // Proxy envs — captured for `<env.http_proxy>`-style interp in
    // user templates that conditionally include proxy settings.
    "http_proxy",
    "https_proxy",       "HTTP_PROXY",        "HTTPS_PROXY",
    "no_proxy",          "NO_PROXY",
};

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

    // Load user-supplied extras early so we can extend the watch lists
    // before scanning. Extras file lives at the same XDG path as facts.
    const xdg_config_home_pre = try resolveXdg(arena, environ, "XDG_CONFIG_HOME", home, ".config");
    const extras_path = try std.fs.path.join(arena, &.{ xdg_config_home_pre, "mox", "extras.toml" });
    const extras = try extras_mod.load(arena, io, extras_path);

    // Built-in TOOL_WATCH_LIST + user extras.
    var tool_watch: std.ArrayList([]const u8) = .empty;
    for (TOOL_WATCH_LIST) |t| try tool_watch.append(arena, t);
    for (extras.tools) |t| try tool_watch.append(arena, t);
    const tool_paths = try path_lookup.findOnPathFull(arena, io, environ, tool_watch.items);
    var tool_names_buf = try arena.alloc([]const u8, tool_paths.len);
    for (tool_paths, 0..) |tp, i| tool_names_buf[i] = tp.name;
    const tools: []const []const u8 = tool_names_buf;

    // Built-in ENV_WATCH_LIST + user extras.
    var env_watch: std.ArrayList([]const u8) = .empty;
    for (ENV_WATCH_LIST) |e| try env_watch.append(arena, e);
    for (extras.envs) |e| try env_watch.append(arena, e);

    var envs: std.ArrayList([]const u8) = .empty;
    var env_vals: std.ArrayList(Fact) = .empty;
    for (env_watch.items) |name| {
        const val = environ.getAlloc(arena, name) catch continue;
        if (val.len > 0) {
            try envs.append(arena, try arena.dupe(u8, name));
            try env_vals.append(arena, .{
                .name = try arena.dupe(u8, name),
                .value = val,
            });
        }
    }
    const defined_envs = try envs.toOwnedSlice(arena);
    const env_values = try env_vals.toOwnedSlice(arena);

    const brew_prefix = try detectBrewPrefix(arena, io, environ, builtin.os.tag, home);

    const xdg_config_home = try resolveXdg(arena, environ, "XDG_CONFIG_HOME", home, ".config");
    const xdg_cache_home = try resolveXdg(arena, environ, "XDG_CACHE_HOME", home, ".cache");
    const xdg_data_home = try resolveXdg(arena, environ, "XDG_DATA_HOME", home, ".local/share");
    const xdg_state_home = try resolveXdg(arena, environ, "XDG_STATE_HOME", home, ".local/state");

    const cargo_home = try resolveToolHome(arena, io, environ, "CARGO_HOME", home, ".cargo");
    const gopath = try resolveToolHome(arena, io, environ, "GOPATH", home, "go");
    const pnpm_home = envOr(arena, environ, "PNPM_HOME") orelse try arena.dupe(u8, "");

    const facts_path = try std.fs.path.join(arena, &.{ xdg_config_home, "mox", "facts.toml" });
    const facts_result = try facts_mod.load(arena, io, facts_path);

    return .{
        .os = os_str,
        .arch = arch_str,
        .hostname = try arena.dupe(u8, hostname_slice),
        .hostname_fallback = hostname_fallback,
        .username = username,
        .username_fallback = username_fallback,
        .home = home,
        .tools_on_path = tools,
        .tool_paths = tool_paths,
        .defined_envs = defined_envs,
        .env_values = env_values,
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

test "MachineState type is constructible" {
    const m = MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "test",
        .username = "tester",
        .home = "/home/tester",
        .tools_on_path = &.{},
        .defined_envs = &.{},
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

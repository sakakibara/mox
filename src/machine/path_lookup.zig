const std = @import("std");
const builtin = @import("builtin");
const Env = @import("env").Env;
const dirent = @import("../source/dirent.zig");
const dsl = @import("../dsl/root.zig");

const Io = std.Io;
const Environ = Env;

pub const Found = struct {
    name: []const u8,
    path: []const u8,
};

/// Find which of `candidates` exist on `$PATH`. Returns sorted list of names
/// that exist. All returned strings are arena-owned (duplicated).
///
/// Uses the supplied `environ` to read `$PATH`; an empty or absent `$PATH`
/// produces an empty result.
pub fn findOnPath(
    arena: std.mem.Allocator,
    io: Io,
    environ: Environ,
    candidates: []const []const u8,
) ![]const []const u8 {
    const full = try findOnPathFull(arena, io, environ, candidates);
    var names = try arena.alloc([]const u8, full.len);
    for (full, 0..) |f, i| names[i] = f.name;
    return names;
}

/// Same as `findOnPath` but also returns the absolute path of the first hit.
/// Used to populate `MachineState.tool_paths` for `<machine.tool_path.X>`
/// interpolation (mirrors chezmoi's `lookPath` template function).
pub fn findOnPathFull(
    arena: std.mem.Allocator,
    io: Io,
    environ: Environ,
    candidates: []const []const u8,
) ![]const Found {
    const listing = try buildListing(arena, io, environ);
    var found: std.ArrayList(Found) = .empty;
    for (candidates) |name| {
        if (try listing.lookup(arena, name)) |path| {
            try found.append(arena, .{ .name = try arena.dupe(u8, name), .path = path });
        }
    }

    const slice = try found.toOwnedSlice(arena);
    std.mem.sort(Found, slice, {}, struct {
        fn lessThan(_: void, a: Found, b: Found) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return slice;
}

/// A one-time scan of every `$PATH` directory, indexed so any later lookup
/// -- not just a name known ahead of the scan -- is a single hashmap `get`.
/// Built by `buildListing`; queried by `lookup`.
pub const Listing = struct {
    /// Folded on-disk name (`foldName`) -> absolute path of its first `$PATH`
    /// hit, in directory-then-alphabetical order. On Windows this also
    /// carries an entry for the extension-stripped stem (`git` from
    /// `git.exe`), so a lookup for either form resolves the same file.
    entries: std.StringHashMap([]const u8),

    /// Absolute path of `name` if this listing saw it on `$PATH`, or null.
    /// `name` is folded the same way the listing's keys were built, so
    /// Windows case-insensitivity (`Git` matching `git.exe`) applies without
    /// the caller doing anything; POSIX compares as written.
    pub fn lookup(self: Listing, arena: std.mem.Allocator, name: []const u8) !?[]const u8 {
        const folded = try foldName(arena, name);
        return self.entries.get(folded);
    }
};

/// Scan every `$PATH` directory once and index every entry found, keyed for
/// `Listing.lookup`. Kept as a single full enumeration rather than probing
/// per name: the watch list is ~75 names and a Windows PATH carries a
/// PATHEXT of ~8, so per-name probing would be tens of thousands of stats per
/// capture -- fast enough on POSIX to hide, slow enough on Windows to look
/// like a hang. An empty or absent `$PATH` produces an empty listing.
pub fn buildListing(arena: std.mem.Allocator, io: Io, environ: Environ) !Listing {
    var entries = std.StringHashMap([]const u8).init(arena);
    const path_env = environ.getAlloc(arena, "PATH") catch |e| switch (e) {
        error.EnvironmentVariableMissing => return .{ .entries = entries },
        else => return e,
    };
    const exts = try executableExts(arena, environ);

    var dirs = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (dirs.next()) |dir_path| {
        if (dir_path.len == 0) continue;
        // Best-effort: a PATH dir that will not enumerate is skipped, not
        // fatal. Sorted so a tie between two names folding to the same key
        // (`git` and `git.exe`) resolves the same way on every machine,
        // rather than by filesystem order.
        const dir_entries = dirent.sortedPath(arena, io, dir_path, .{ .iterate = true }) catch continue;
        for (dir_entries) |entry| {
            if (entry.kind == .directory) continue;
            const folded = try foldName(arena, entry.name);
            if (!entries.contains(folded)) {
                try entries.put(folded, try std.fs.path.join(arena, &.{ dir_path, entry.name }));
            }
            // On Windows, `git` is on disk as `git.exe`: index the stem too,
            // when the extension is one the shell would have run, so a
            // lookup for the bare name finds it.
            if (try stemForExecutable(arena, folded, exts)) |stem| {
                if (!entries.contains(stem)) {
                    try entries.put(stem, try std.fs.path.join(arena, &.{ dir_path, entry.name }));
                }
            }
        }
    }
    return .{ .entries = entries };
}

/// Lazy, memoized `tool=` answers layered over `Listing`: the first probe of
/// ANY name builds one `Listing` (one full `$PATH` enumeration); every probe
/// after that, of any name, is a memo lookup or a `Listing.lookup`. Memo and
/// listing keys are the name exactly as asked (verbatim) -- Windows case
/// folding happens inside `Listing.lookup`, not here, so `present("Git")` and
/// `present("git")` memoize as two independent entries that both resolve to
/// the same on-disk file on Windows.
pub const ToolProbe = struct {
    arena: std.mem.Allocator,
    io: Io,
    environ: Environ,
    listing: ?Listing = null,
    memo: std.StringHashMap(?[]const u8),

    pub fn init(arena: std.mem.Allocator, io: Io, environ: Environ) ToolProbe {
        return .{ .arena = arena, .io = io, .environ = environ, .memo = std.StringHashMap(?[]const u8).init(arena) };
    }

    /// Absolute path of `name` on `$PATH`, probing and memoizing on first ask.
    /// A memoization failure (out of memory) just means the next ask probes
    /// again; the answer returned this time is still correct.
    pub fn path(self: *ToolProbe, name: []const u8) ?[]const u8 {
        if (self.memo.get(name)) |cached| return cached;
        const listing = self.ensureListing();
        const found = listing.lookup(self.arena, name) catch null;
        self.memo.put(name, found) catch {};
        return found;
    }

    /// True when `name` resolves on `$PATH`.
    pub fn present(self: *ToolProbe, name: []const u8) bool {
        return self.path(name) != null;
    }

    /// Drop the memo and the listing cache: the next probe re-scans `$PATH`
    /// from scratch. Used after a pre-script may have installed something
    /// (or a facts interview answer may have changed `$PATH` indirectly),
    /// so the very next gate that asks sees it in the same run.
    pub fn reset(self: *ToolProbe) void {
        self.memo.clearRetainingCapacity();
        self.listing = null;
    }

    /// Adapt this prober to `dsl.resolver.Resolver.Probe`, so a `Resolver`
    /// built over this machine's bindings can fall through to it for a
    /// `tool=` name the bindings do not already answer.
    pub fn probe(self: *ToolProbe) dsl.resolver.Resolver.Probe {
        return .{ .ctx = self, .presentFn = presentTrampoline };
    }

    fn presentTrampoline(ctx: *anyopaque, name: []const u8) bool {
        const self: *ToolProbe = @ptrCast(@alignCast(ctx));
        return self.present(name);
    }

    fn ensureListing(self: *ToolProbe) Listing {
        if (self.listing == null) {
            self.listing = buildListing(self.arena, self.io, self.environ) catch .{ .entries = std.StringHashMap([]const u8).init(self.arena) };
        }
        return self.listing.?;
    }
};

/// The extensions an executable may carry, in the order the shell would try
/// them. Empty on POSIX, where a program is its own name. On Windows a bare
/// `git` lives on disk as `git.exe`, so a lookup that only tried the name
/// verbatim would find nothing and quietly report the tool as absent -- taking
/// every `tool=` axis gated on it down with it. PATHEXT names the extensions;
/// its documented default stands in when it is unset.
fn executableExts(arena: std.mem.Allocator, environ: Environ) ![]const []const u8 {
    if (builtin.os.tag != .windows) return &.{};

    const raw = environ.getAlloc(arena, "PATHEXT") catch "";
    const spec = if (raw.len > 0) raw else ".COM;.EXE;.BAT;.CMD";

    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, spec, ';');
    while (it.next()) |ext| {
        const trimmed = std.mem.trim(u8, ext, " \t\r\n");
        if (trimmed.len == 0) continue;
        try out.append(arena, trimmed);
    }
    return out.toOwnedSlice(arena);
}

/// A name in the form both sides of a comparison agree on. Windows filenames
/// are case-insensitive, so `Git.EXE` must match a `git` the watch list asked
/// for; POSIX names are compared as written.
fn foldName(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (builtin.os.tag != .windows) return name;
    const out = try arena.dupe(u8, name);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// The name with its executable extension removed, or null when it carries
/// none that the shell would have run. Always null on POSIX, where a program
/// is its own name.
fn stemForExecutable(arena: std.mem.Allocator, folded: []const u8, exts: []const []const u8) !?[]const u8 {
    _ = arena;
    for (exts) |ext| {
        if (ext.len < folded.len and std.ascii.endsWithIgnoreCase(folded, ext)) {
            return folded[0 .. folded.len - ext.len];
        }
    }
    return null;
}

test "findOnPath: empty candidate list returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try findOnPath(
        arena.allocator(),
        std.testing.io,
        Env{ .process = std.testing.environ },
        &.{},
    );
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "findOnPath: nonexistent name not in result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const candidates = [_][]const u8{"definitely-not-a-real-binary-xyz"};
    const found = try findOnPath(
        arena.allocator(),
        std.testing.io,
        Env{ .process = std.testing.environ },
        &candidates,
    );
    try std.testing.expectEqual(@as(usize, 0), found.len);
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

test "ToolProbe.present: an unwatched name is found on PATH and memoized" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/herdr", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin_dir = try tmpAbsPath(a, &tmp, "bin");

    var map = std.process.Environ.Map.init(a);
    try map.put("PATH", bin_dir);
    var probe = ToolProbe.init(a, io, Env{ .map = &map });

    try std.testing.expect(probe.present("herdr"));
    // Memoized: asking again answers from the memo, not a re-scan.
    try std.testing.expect(probe.present("herdr"));
    try std.testing.expect(!probe.present("definitely-not-installed-xyz"));
}

test "ToolProbe.reset: a tool created after the first probe is invisible until reset" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin_dir = try tmpAbsPath(a, &tmp, "bin");

    var map = std.process.Environ.Map.init(a);
    try map.put("PATH", bin_dir);
    var probe = ToolProbe.init(a, io, Env{ .map = &map });

    try std.testing.expect(!probe.present("latecomer"));

    // A "pre-script" drops the binary in after the listing cache was built.
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/latecomer", .data = "" });
    try std.testing.expect(!probe.present("latecomer")); // still stale, memoized absent

    probe.reset();
    try std.testing.expect(probe.present("latecomer"));
}

test "ToolProbe: verbatim memo/listing keys, Windows folds case inside lookup, POSIX stays case-sensitive" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/git", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin_dir = try tmpAbsPath(a, &tmp, "bin");

    var map = std.process.Environ.Map.init(a);
    try map.put("PATH", bin_dir);
    var probe = ToolProbe.init(a, io, Env{ .map = &map });

    if (builtin.os.tag == .windows) {
        try std.testing.expect(probe.present("Git"));
    } else {
        try std.testing.expect(!probe.present("Git"));
        try std.testing.expect(probe.present("git"));
    }
}

test "Resolver via ToolProbe.probe(): fixed variant never probes, even for a name confirmed present" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/reallyinstalled", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin_dir = try tmpAbsPath(a, &tmp, "bin");

    var map = std.process.Environ.Map.init(a);
    try map.put("PATH", bin_dir);
    var probe = ToolProbe.init(a, io, Env{ .map = &map });
    // Confirm the name really is reachable by probing -- the point being
    // disproven is that `fixed` would ever do this itself.
    try std.testing.expect(probe.present("reallyinstalled"));

    var empty = std.StringHashMap([]const u8).init(a);
    const fixed: dsl.resolver.Resolver = .{ .fixed = &empty };
    try std.testing.expect(!fixed.has("tool", "reallyinstalled"));

    // Contrast: the live variant, wired to the very same probe, DOES resolve
    // it -- proving the difference is `fixed` never touching the machine at
    // all, not some incidental miss.
    var bindings = std.StringHashMap([]const u8).init(a);
    const live: dsl.resolver.Resolver.Live = .{ .bindings = &bindings, .probe = probe.probe() };
    const live_r: dsl.resolver.Resolver = .{ .live = &live };
    try std.testing.expect(live_r.has("tool", "reallyinstalled"));
}

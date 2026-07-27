const std = @import("std");
const builtin = @import("builtin");
const Env = @import("env").Env;
const dirent = @import("../source/dirent.zig");
const dsl = @import("../dsl/root.zig");

const Io = std.Io;
const Environ = Env;

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

/// Scan every `$PATH` directory once, then `extra_dirs` in order, and index
/// every entry found, keyed for `Listing.lookup`. Kept as a single full
/// enumeration, built once per capture and shared by every later per-name
/// probe: naive per-name scanning against a Windows PATH (carrying a PATHEXT
/// of ~8) would be a full directory listing per name, tens of thousands of
/// stats across a source tree's worth of `tool=` gates -- fast enough on
/// POSIX to hide, slow enough on Windows to look like a hang. An empty or
/// absent `$PATH` scans no PATH directories but still scans `extra_dirs`.
///
/// `extra_dirs` -- this machine's tool-home bin directories (D2b) -- are
/// scanned strictly after every `$PATH` directory: `scanDirInto` only ever
/// inserts a name it has not already seen, so a `$PATH` hit always wins over
/// a tool-home hit for the same name, unchanged from PATH-only behavior.
pub fn buildListing(arena: std.mem.Allocator, io: Io, environ: Environ, extra_dirs: []const []const u8) !Listing {
    var entries = std.StringHashMap([]const u8).init(arena);
    const exts = try executableExts(arena, environ);

    const path_env = environ.getAlloc(arena, "PATH") catch |e| switch (e) {
        error.EnvironmentVariableMissing => "",
        else => return e,
    };
    var dirs = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (dirs.next()) |dir_path| {
        if (dir_path.len == 0) continue;
        try scanDirInto(arena, io, &entries, dir_path, exts);
    }
    for (extra_dirs) |dir_path| {
        try scanDirInto(arena, io, &entries, dir_path, exts);
    }
    return .{ .entries = entries };
}

/// Index every regular file directly inside `dir_path` into `entries`,
/// keyed for `Listing.lookup`. Best-effort: a directory that does not exist
/// or will not enumerate is silently skipped, not fatal -- shared by every
/// PATH/tool-home/`$MOX_PATH` directory a `Listing` ever scans. Sorted so a
/// tie between two names folding to the same key (`git` and `git.exe`)
/// resolves the same way on every machine, rather than by filesystem order.
fn scanDirInto(
    arena: std.mem.Allocator,
    io: Io,
    entries: *std.StringHashMap([]const u8),
    dir_path: []const u8,
    exts: []const []const u8,
) !void {
    const dir_entries = dirent.sortedPath(arena, io, dir_path, .{ .iterate = true }) catch return;
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

/// Scan `dirs` into an already-built `listing` in place, same precedence
/// rule as `buildListing` (a name already present -- from `$PATH`, a tool
/// home, or an earlier `extendListing` call -- is never overwritten). Used
/// for the `$MOX_PATH` channel (D2b): directories a setup script names after
/// this run's `Listing` already exists join the search space without
/// rebuilding it.
pub fn extendListing(arena: std.mem.Allocator, io: Io, environ: Environ, listing: *Listing, dirs: []const []const u8) !void {
    if (dirs.len == 0) return;
    const exts = try executableExts(arena, environ);
    for (dirs) |dir_path| {
        try scanDirInto(arena, io, &listing.entries, dir_path, exts);
    }
}

/// One name a probe was asked to resolve this run, and whether it resolved.
/// `mox status`'s probe-log section and `mox facts probe` (D6) share this
/// shape across `ToolProbe` (tool=) and `machine.state.EnvProbe` (env=).
pub const ProbedName = struct {
    name: []const u8,
    present: bool,
};

/// Every key in `memo` (`ToolProbe`'s or `EnvProbe`'s -- both are `name ->
/// ?value`), sorted by name. Shared so the two probers' `probedNames`
/// methods agree on ordering and shape.
pub fn sortedProbedNames(arena: std.mem.Allocator, memo: *const std.StringHashMap(?[]const u8)) ![]const ProbedName {
    var out: std.ArrayList(ProbedName) = .empty;
    var it = memo.iterator();
    while (it.next()) |entry| {
        try out.append(arena, .{ .name = entry.key_ptr.*, .present = entry.value_ptr.* != null });
    }
    const slice = try out.toOwnedSlice(arena);
    std.mem.sort(ProbedName, slice, {}, struct {
        fn lessThan(_: void, a: ProbedName, b: ProbedName) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return slice;
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

    /// Seed this probe with a `Listing` the caller already built (`capture`'s
    /// own `$PATH` enumeration), so the first `path`/`present` call reuses it
    /// instead of triggering its own -- one enumeration per run, not two.
    pub fn seedListing(self: *ToolProbe, listing: Listing) void {
        self.listing = listing;
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

    /// Every name asked of `path`/`present` so far this run, sorted by name
    /// so the result is independent of ask order and of `memo`'s hash-map
    /// iteration order (both unspecified). Powers `mox status`'s probe-log
    /// section and `mox facts probe` (D6): the typo-visibility surface for
    /// `tool=` -- a name asked and not found stays in the log as `present =
    /// false`, distinct from a name never asked at all (absent from the log
    /// entirely).
    pub fn probedNames(self: *ToolProbe, arena: std.mem.Allocator) ![]const ProbedName {
        return sortedProbedNames(arena, &self.memo);
    }

    /// Widen the search space with `dirs` (the `$MOX_PATH` channel, D2b):
    /// scanned into the existing `Listing` in place -- a name already found
    /// via `$PATH` or a tool home is never overwritten, so this can only add
    /// names, never change an existing answer. Building the listing first
    /// (if this is the first call) rather than deferring to the next
    /// `path`/`present` keeps the memo and the listing consistent: any
    /// `dirs` name looked up right after this call sees it. Best-effort,
    /// same as every other listing scan.
    pub fn extend(self: *ToolProbe, dirs: []const []const u8) void {
        if (dirs.len == 0) return;
        _ = self.ensureListing();
        if (self.listing) |*l| {
            extendListing(self.arena, self.io, self.environ, l, dirs) catch {};
        }
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
            self.listing = buildListing(self.arena, self.io, self.environ, &.{}) catch .{ .entries = std.StringHashMap([]const u8).init(self.arena) };
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
/// are case-insensitive, so `Git.EXE` must match a `tool=git` probe; POSIX
/// names are compared as written.
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

test "ToolProbe.present: detects the platform's shell on the real PATH" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `cmd` resolves via PATHEXT to cmd.exe, which is the lookup being tested.
    const shell = if (builtin.os.tag == .windows) "cmd" else "sh";
    var probe = ToolProbe.init(arena.allocator(), std.testing.io, Env{ .process = std.testing.environ });
    try std.testing.expect(probe.present(shell));
    try std.testing.expect(!probe.present("definitely-does-not-exist-9876"));
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

test "ToolProbe.probedNames: every name asked so far, sorted, with its outcome" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/fd", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bin_dir = try tmpAbsPath(a, &tmp, "bin");

    var map = std.process.Environ.Map.init(a);
    try map.put("PATH", bin_dir);
    var probe = ToolProbe.init(a, io, Env{ .map = &map });

    // Nothing asked yet: the log is empty, not "everything absent".
    try std.testing.expectEqual(@as(usize, 0), (try probe.probedNames(a)).len);

    try std.testing.expect(probe.present("fd"));
    try std.testing.expect(!probe.present("hedrr"));

    const names = try probe.probedNames(a);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("fd", names[0].name);
    try std.testing.expect(names[0].present);
    try std.testing.expectEqualStrings("hedrr", names[1].name);
    try std.testing.expect(!names[1].present);
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

test "buildListing: extra_dirs are searched too, but PATH wins a name collision" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pathbin");
    try tmp.dir.createDirPath(io, "toolhome/bin");
    // Same name in both: PATH's copy must be the one the listing indexes.
    try tmp.dir.writeFile(io, .{ .sub_path = "pathbin/shared", .data = "from-path" });
    try tmp.dir.writeFile(io, .{ .sub_path = "toolhome/bin/shared", .data = "from-toolhome" });
    try tmp.dir.writeFile(io, .{ .sub_path = "toolhome/bin/onlyhome", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path_bin = try tmpAbsPath(a, &tmp, "pathbin");
    const tool_bin = try tmpAbsPath(a, &tmp, "toolhome/bin");

    var map = std.process.Environ.Map.init(a);
    try map.put("PATH", path_bin);
    const listing = try buildListing(a, io, Env{ .map = &map }, &.{tool_bin});

    const shared_path = (try listing.lookup(a, "shared")).?;
    try std.testing.expect(std.mem.indexOf(u8, shared_path, "pathbin") != null);
    const only_home_path = (try listing.lookup(a, "onlyhome")).?;
    try std.testing.expect(std.mem.indexOf(u8, only_home_path, "toolhome") != null);
}

test "buildListing: an empty PATH still searches extra_dirs" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "toolhome/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "toolhome/bin/onlyhome", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tool_bin = try tmpAbsPath(a, &tmp, "toolhome/bin");

    var map = std.process.Environ.Map.init(a);
    const listing = try buildListing(a, io, Env{ .map = &map }, &.{tool_bin});

    try std.testing.expect((try listing.lookup(a, "onlyhome")) != null);
}

test "ToolProbe.extend: a directory named after construction joins the search space" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pathbin");
    try tmp.dir.createDirPath(io, "later");
    try tmp.dir.writeFile(io, .{ .sub_path = "later/latecomer", .data = "" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path_bin = try tmpAbsPath(a, &tmp, "pathbin");
    const later_dir = try tmpAbsPath(a, &tmp, "later");

    var map = std.process.Environ.Map.init(a);
    try map.put("PATH", path_bin);
    var probe = ToolProbe.init(a, io, Env{ .map = &map });

    // "latecomer" lives only in `later_dir`, which is not on PATH: reachable
    // only once `extend` widens the search space.
    probe.extend(&.{later_dir});
    try std.testing.expect(probe.present("latecomer"));
}

test "ToolProbe.extend: a name already resolved via PATH is unaffected by a colliding extra dir" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pathbin");
    try tmp.dir.createDirPath(io, "later");
    try tmp.dir.writeFile(io, .{ .sub_path = "pathbin/shared", .data = "from-path" });
    try tmp.dir.writeFile(io, .{ .sub_path = "later/shared", .data = "from-later" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path_bin = try tmpAbsPath(a, &tmp, "pathbin");
    const later_dir = try tmpAbsPath(a, &tmp, "later");

    var map = std.process.Environ.Map.init(a);
    try map.put("PATH", path_bin);
    var probe = ToolProbe.init(a, io, Env{ .map = &map });

    const before = probe.path("shared").?;
    probe.extend(&.{later_dir});
    const after = probe.path("shared").?;
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expect(std.mem.indexOf(u8, after, "pathbin") != null);
}

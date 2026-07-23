const std = @import("std");

const tuple_mod = @import("tuple.zig");
const path_mod = @import("path.zig");
const junk = @import("junk.zig");
const dirent = @import("dirent.zig");
const attributes = @import("attributes.zig");

const Io = std.Io;

/// An axis tuple like `os=darwin+profile=work`. Each entry is a (name, value) pair.
pub const AxisTuple = struct {
    /// Sorted by axis name for stable comparison.
    pairs: []const Pair,

    pub const Pair = struct {
        name: []const u8,
        value: []const u8,
    };

    /// True if this tuple is empty (universal -- no axis constraints).
    pub fn isUniversal(self: AxisTuple) bool {
        return self.pairs.len == 0;
    }

    /// Canonical total order: lexicographic on the (name, value) pair sequence
    /// (pairs are already name-sorted), then by pair count. Distinct tuples
    /// never compare equal, so overlay selection and structured-merge folding
    /// are a function of the source tree, not of filesystem iteration order.
    pub fn canonicalLess(a: AxisTuple, b: AxisTuple) bool {
        const n = @min(a.pairs.len, b.pairs.len);
        for (0..n) |i| {
            switch (std.mem.order(u8, a.pairs[i].name, b.pairs[i].name)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            switch (std.mem.order(u8, a.pairs[i].value, b.pairs[i].value)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
        }
        return a.pairs.len < b.pairs.len;
    }
};

/// One overlay file in a Category A/C `.d/` directory, named by axis tuple.
pub const Overlay = struct {
    /// Filesystem path to the overlay file.
    path: []const u8,
    /// Parsed axis tuple from the filename, with a trailing extension stripped
    /// (`os=darwin.toml` -> `os=darwin`).
    tuple: AxisTuple,
    /// Tuple from the VERBATIM filename, set only when the filename carries
    /// something the extension heuristic treats as an extension. An axis value
    /// may itself contain a dot (a `machine` value is a hostname, and every
    /// macOS hostname ends in `.local`), so the filename is also a candidate
    /// tuple in its own right -- and the one that wins, since it is what was
    /// actually written.
    exact_tuple: ?AxisTuple = null,
};

/// One fragment file inside a region directory (Category B).
pub const Fragment = struct {
    /// Filesystem path to the fragment file.
    path: []const u8,
    /// Parsed axis tuple from the filename, with a trailing extension stripped
    /// (`darwin.sh` -> `os=darwin`).
    tuple: AxisTuple,
    /// Tuple from the VERBATIM filename, set only when the filename carries
    /// something `fragmentStem` treats as an extension. An axis value may
    /// itself contain a dot (a `machine` value is a hostname, and every macOS
    /// hostname ends in `.local`), so the filename is also a candidate value in
    /// its own right -- and the one that wins, since it is what the value was
    /// written as.
    exact_tuple: ?AxisTuple = null,
};

/// One region directory inside a `.d/` (Category B).
pub const Region = struct {
    /// Region name (the directory's basename).
    name: []const u8,
    /// Filesystem path to the region directory.
    path: []const u8,
    /// Fragments inside this region.
    fragments: []const Fragment,
};

/// One managed file in the source tree.
pub const ManagedFile = struct {
    /// Path within `src/`, e.g. `src/.zshrc` or `src/.config/nvim/init.lua`.
    source_base_path: []const u8,
    /// Absolute on-disk path of the base file. Empty when `has_base` is false.
    source_base_abs: []const u8,
    /// Resolved live path, e.g. `/home/me/.zshrc`.
    live_path: []const u8,
    /// True if a base file exists at `source_base_path`. False indicates
    /// whole-file axis gating (only overlays in `.d/`).
    has_base: bool,
    /// Direct axis-named overlays inside `.d/` (Cat A/C).
    overlays: []const Overlay,
    /// Region subdirectories inside `.d/` (Cat B).
    regions: []const Region,
    /// Mox repo root (parent of the walked `src/` dir). Used to resolve
    /// repo-relative paths in directives like `# mox: for entry in
    /// "data/abbreviations.toml"`. Empty when the file was constructed
    /// directly (not via `walk`).
    repo_dir: []const u8 = "",
    /// Root of the private layer, stamped by `private.layer.merge` on every
    /// merged file. Non-empty means repo-relative loop data sources are
    /// looked up here first (private shadows repo), matching `mox data get`.
    /// Empty when there is no private layer.
    private_dir: []const u8 = "",
    /// Unix file mode to apply to the materialized live file. The native
    /// on-disk mode of the source file (git round-trips 0o755/0o644 across a
    /// clone), overridden by `.mox/attributes.toml` for the modes git cannot
    /// carry (0o600/0o444). Default 0o644.
    mode: u32 = 0o644,
    /// True when `mode` came from an explicit `.mox/attributes.toml` entry
    /// rather than the source's on-disk bits. Only an explicit mode is enforced
    /// on an already-current live file; a default (stat-derived) mode is not, so
    /// apply never re-loosens a file the user hardened by hand.
    mode_explicit: bool = false,
    /// True when this is a regular source file whose composed content is a
    /// symlink target. Apply creates a symlink at `live_path` pointing to that
    /// target instead of writing the content. The intent is recorded as
    /// `symlink = true` in `.mox/attributes.toml`, not a filename prefix.
    is_symlink: bool = false,
    /// True when the target is recorded as seed-once in `.mox/attributes.toml`.
    /// Apply writes the composed content only when the live path does not yet
    /// exist; an existing live file is left untouched and never becomes a drift
    /// candidate. Seed-once semantics for files the user edits after first
    /// creation (e.g. a machine-local config skeleton).
    create_once: bool = false,
};

/// The complete scanned source tree.
pub const ManagedTree = struct {
    files: []const ManagedFile,
    /// Live directories marked exact by a `.mox-exact` marker file in the
    /// corresponding source directory. After apply writes every managed file,
    /// live entries in these directories that mox does not produce are removed
    /// (snapshotted first). The marker itself is never materialized.
    exact_dirs: []const []const u8 = &.{},
};

/// Marker filename that makes its containing directory exact.
pub const exact_marker = ".mox-exact";

test "ManagedTree types are constructible" {
    const f = ManagedFile{
        .source_base_path = "src/.zshrc",
        .source_base_abs = "/abs/src/.zshrc",
        .live_path = "/home/me/.zshrc",
        .has_base = true,
        .overlays = &.{},
        .regions = &.{},
    };
    try std.testing.expectEqualStrings("src/.zshrc", f.source_base_path);
}

test "AxisTuple isUniversal" {
    const t = AxisTuple{ .pairs = &.{} };
    try std.testing.expect(t.isUniversal());
}

test "overlayLess is a total order: equal tuples tiebreak on path" {
    // `os=darwin.toml` and `os=darwin.yaml` strip to the SAME tuple. Without a
    // path tiebreak the unstable sort leaves them in filesystem order; with it,
    // both enumeration orders sort identically.
    const t = AxisTuple{ .pairs = &.{.{ .name = "os", .value = "darwin" }} };
    var forward = [_]Overlay{
        .{ .path = "/src/x.d/os=darwin.toml", .tuple = t },
        .{ .path = "/src/x.d/os=darwin.yaml", .tuple = t },
    };
    var reverse = [_]Overlay{
        .{ .path = "/src/x.d/os=darwin.yaml", .tuple = t },
        .{ .path = "/src/x.d/os=darwin.toml", .tuple = t },
    };
    std.mem.sort(Overlay, &forward, {}, overlayLess);
    std.mem.sort(Overlay, &reverse, {}, overlayLess);
    try std.testing.expectEqualStrings("/src/x.d/os=darwin.toml", forward[0].path);
    try std.testing.expectEqualStrings(forward[0].path, reverse[0].path);
    try std.testing.expectEqualStrings(forward[1].path, reverse[1].path);
}

test "fragmentLess is a total order: equal tuples tiebreak on path" {
    const t = AxisTuple{ .pairs = &.{.{ .name = "os", .value = "darwin" }} };
    var forward = [_]Fragment{
        .{ .path = "/r/darwin.sh", .tuple = t },
        .{ .path = "/r/darwin.bash", .tuple = t },
    };
    var reverse = [_]Fragment{
        .{ .path = "/r/darwin.bash", .tuple = t },
        .{ .path = "/r/darwin.sh", .tuple = t },
    };
    std.mem.sort(Fragment, &forward, {}, fragmentLess);
    std.mem.sort(Fragment, &reverse, {}, fragmentLess);
    try std.testing.expectEqualStrings("/r/darwin.bash", forward[0].path);
    try std.testing.expectEqualStrings(forward[0].path, reverse[0].path);
    try std.testing.expectEqualStrings(forward[1].path, reverse[1].path);
}

/// Walk a source tree rooted at `src_dir` (an absolute path), producing a `ManagedTree`.
///
/// `home_dir` is used to compute live paths. All returned strings are arena-owned;
/// the arena must outlive the returned tree.
fn livePathLess(_: void, a: ManagedFile, b: ManagedFile) bool {
    return std.mem.lessThan(u8, a.live_path, b.live_path);
}

pub fn walk(
    arena: std.mem.Allocator,
    io: Io,
    src_dir: []const u8,
    home_dir: []const u8,
) !ManagedTree {
    var files: std.ArrayList(ManagedFile) = .empty;
    errdefer files.deinit(arena);
    var exact: std.ArrayList([]const u8) = .empty;
    errdefer exact.deinit(arena);

    var dir = try Io.Dir.cwd().openDir(io, src_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer dir.close(io);

    // Repo root is the parent of `src/`; `.mox/attributes.toml` there records
    // the modes git cannot carry (0o600/0o444). It is authoritative for those.
    const repo_dir = std.fs.path.dirname(src_dir) orelse "";
    const attrs = try attributes.load(arena, io, repo_dir);

    try walkDir(arena, io, &files, &exact, dir, "src", src_dir, home_dir, &attrs);

    // Stamp every walked file with the repo root (parent of `src/`).
    const out = try files.toOwnedSlice(arena);
    // Directory iteration order is the filesystem's, not the tree's: APFS and
    // ext4 hand back the same directory in different orders. Every command
    // walks this slice, so without a total order `status` and `diff` would list
    // files differently per machine and `commit` would prompt for them in a
    // different sequence -- on a tool whose whole point is that machines agree.
    // Live paths are unique, so ordering by them is total and stable.
    std.mem.sort(ManagedFile, out, {}, livePathLess);
    for (out) |*f| f.repo_dir = repo_dir;
    return .{ .files = out, .exact_dirs = try exact.toOwnedSlice(arena) };
}

fn walkDir(
    arena: std.mem.Allocator,
    io: Io,
    files: *std.ArrayList(ManagedFile),
    exact: *std.ArrayList([]const u8),
    dir: Io.Dir,
    rel_prefix: []const u8,
    abs_prefix: []const u8,
    home_dir: []const u8,
    attrs: *const attributes.Attributes,
) !void {
    var file_names: std.ArrayList([]const u8) = .empty;
    var dir_names: std.ArrayList([]const u8) = .empty;
    defer file_names.deinit(arena);
    defer dir_names.deinit(arena);

    for (try dirent.sorted(arena, io, dir)) |entry| {
        if (junk.isJunk(entry.name)) continue;
        if (entry.kind == .sym_link) return error.SymlinkInSource;
        // The exact marker gates its own directory and is never materialized.
        if (entry.kind == .file and std.mem.eql(u8, entry.name, exact_marker)) {
            if (liveDirForRel(arena, rel_prefix, home_dir)) |live_dir| {
                try exact.append(arena, live_dir);
            }
            continue;
        }
        if (entry.kind == .file) {
            try file_names.append(arena, try arena.dupe(u8, entry.name));
        } else if (entry.kind == .directory) {
            try dir_names.append(arena, try arena.dupe(u8, entry.name));
        }
    }

    var paired = std.StringHashMap(void).init(arena);
    defer paired.deinit();

    // Regular files become managed bases. If a paired `<name>.d/` exists,
    // enumerate its overlays/regions.
    for (file_names.items) |name| {
        const rel = try path_mod.joinKey(arena, &.{ rel_prefix, name });
        const dot_d_name = try std.mem.concat(arena, u8, &.{ name, ".d" });

        var overlays: []const Overlay = &.{};
        var regions: []const Region = &.{};
        var has_dot_d = false;
        for (dir_names.items) |dname| {
            if (std.mem.eql(u8, dname, dot_d_name)) {
                has_dot_d = true;
                break;
            }
        }
        if (has_dot_d) {
            try paired.put(dot_d_name, {});
            var dot_d_dir = try dir.openDir(io, dot_d_name, .{
                .iterate = true,
                .follow_symlinks = false,
            });
            defer dot_d_dir.close(io);
            const dot_d_abs = try std.fs.path.join(arena, &.{ abs_prefix, dot_d_name });
            try enumerateDotD(arena, io, dot_d_dir, dot_d_abs, &overlays, &regions);
        }

        // The applied file takes the source filename verbatim; no prefix is
        // stripped. Mode/symlink/seed-once intent lives in
        // `.mox/attributes.toml`, keyed by the portable target key.
        const live = try path_mod.toLivePath(arena, rel, home_dir);
        const abs = try std.fs.path.join(arena, &.{ abs_prefix, name });
        // Mode resolution: `.mox/attributes.toml` is authoritative for the
        // modes git cannot carry; otherwise honor the source file's on-disk
        // mode (git round-trips 0o755/0o644 across a clone).
        const target_key = if (std.mem.startsWith(u8, rel, "src/"))
            rel["src/".len..]
        else
            rel;
        const explicit_mode = attrs.mode(target_key);
        try files.append(arena, .{
            .source_base_path = rel,
            .source_base_abs = abs,
            .live_path = live,
            .has_base = true,
            .overlays = overlays,
            .regions = regions,
            .mode = explicit_mode orelse modeFromStat(io, dir, name),
            .mode_explicit = explicit_mode != null,
            .is_symlink = attrs.symlink(target_key),
            .create_once = attrs.seedOnce(target_key),
        });
    }

    // Subdirectories: orphan `.d/` becomes a `has_base=false` managed file;
    // anything else is a plain subdirectory to recurse into.
    for (dir_names.items) |name| {
        if (!std.mem.endsWith(u8, name, ".d")) {
            const sub_rel = try path_mod.joinKey(arena, &.{ rel_prefix, name });
            const sub_abs = try std.fs.path.join(arena, &.{ abs_prefix, name });
            var sub = try dir.openDir(io, name, .{
                .iterate = true,
                .follow_symlinks = false,
            });
            defer sub.close(io);
            try walkDir(arena, io, files, exact, sub, sub_rel, sub_abs, home_dir, attrs);
            continue;
        }
        if (paired.contains(name)) continue;
        const base_name = name[0 .. name.len - 2];
        const rel = try path_mod.joinKey(arena, &.{ rel_prefix, base_name });

        var overlays: []const Overlay = &.{};
        var regions: []const Region = &.{};
        var dot_d_dir = try dir.openDir(io, name, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        const dot_d_abs = try std.fs.path.join(arena, &.{ abs_prefix, name });
        try enumerateDotD(arena, io, dot_d_dir, dot_d_abs, &overlays, &regions);

        // Gap 6: an orphan `.d/` is treated as the overlay-dir of a phantom
        // managed file ONLY if it actually contains axis-named overlays.
        // Without that signal, treat the dir as a regular subdirectory and
        // recurse — otherwise legitimate convention-named dirs like
        // `~/.config/fish/conf.d/` get hijacked, hiding their real contents.
        if (overlays.len == 0) {
            const sub_rel = try path_mod.joinKey(arena, &.{ rel_prefix, name });
            const sub_abs = try std.fs.path.join(arena, &.{ abs_prefix, name });
            // Recurse, then close. We can't use `defer .close()` here because
            // we need to release the handle before the recursive walk also
            // opens the same dir — Zig's Dir.openDir doesn't reuse handles.
            try walkDir(arena, io, files, exact, dot_d_dir, sub_rel, sub_abs, home_dir, attrs);
            dot_d_dir.close(io);
            continue;
        }
        defer dot_d_dir.close(io);

        const live = try path_mod.toLivePath(arena, rel, home_dir);
        try files.append(arena, .{
            .source_base_path = rel,
            .source_base_abs = "",
            .live_path = live,
            .has_base = false,
            .overlays = overlays,
            .regions = regions,
        });
    }
}

/// Inspect the source file's on-disk permissions and return a sensible mode.
/// Currently we only care about the user-executable bit: present -> 0o755,
/// absent -> 0o644. Errors fall back to 0o644.
///
/// A filesystem with no executable bit (Windows) exposes no mode, so every
/// file stats as 0o644 there; a restrictive mode still comes from the
/// `.mox/attributes.toml` record.
fn modeFromStat(io: Io, dir: Io.Dir, name: []const u8) u32 {
    if (Io.File.Permissions.has_executable_bit) {
        const st = dir.statFile(io, name, .{}) catch return 0o644;
        const m = st.permissions.toMode();
        // Check user-execute bit (S_IXUSR = 0o100).
        if ((m & 0o100) != 0) return 0o755;
        return 0o644;
    }
    return 0o644;
}

/// Live directory for a walked source directory's `rel_prefix`, or null for
/// the source root. An exact marker at the repo root would make the whole
/// home directory exact -- far too destructive -- so it is ignored there.
fn liveDirForRel(arena: std.mem.Allocator, rel_prefix: []const u8, home_dir: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, rel_prefix, "src")) return null;
    return path_mod.toLivePath(arena, rel_prefix, home_dir) catch null;
}

/// Strip a single trailing extension from a fragment filename. Mirrors the
/// extension-detection rule in `tuple.parseFilename`: the part after the LAST
/// `.` is treated as an extension only when it contains no `+`/`=` and isn't
/// purely numeric (so version suffixes like `tool-2.0` stay intact).
fn fragmentStem(filename: []const u8) []const u8 {
    const last_dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return filename;
    const ext_part = filename[last_dot + 1 ..];
    if (ext_part.len == 0) return filename;
    if (std.mem.indexOfAny(u8, ext_part, "+=") != null) return filename;
    var all_digit = true;
    for (ext_part) |c| {
        if (!std.ascii.isDigit(c)) {
            all_digit = false;
            break;
        }
    }
    if (all_digit) return filename;
    return filename[0..last_dot];
}

fn overlayLess(_: void, a: Overlay, b: Overlay) bool {
    if (a.tuple.canonicalLess(b.tuple)) return true;
    if (b.tuple.canonicalLess(a.tuple)) return false;
    // Equal canonical tuples (e.g. `os=darwin.toml` and `os=darwin.yaml`):
    // tiebreak on the unique path so the order is total and machine-independent.
    return std.mem.lessThan(u8, a.path, b.path);
}

fn fragmentLess(_: void, a: Fragment, b: Fragment) bool {
    if (a.tuple.canonicalLess(b.tuple)) return true;
    if (b.tuple.canonicalLess(a.tuple)) return false;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn enumerateDotD(
    arena: std.mem.Allocator,
    io: Io,
    dot_d_dir: Io.Dir,
    dot_d_abs: []const u8,
    overlays_out: *[]const Overlay,
    regions_out: *[]const Region,
) !void {
    var overlays: std.ArrayList(Overlay) = .empty;
    errdefer overlays.deinit(arena);
    var regions: std.ArrayList(Region) = .empty;
    errdefer regions.deinit(arena);

    for (try dirent.sorted(arena, io, dot_d_dir)) |entry| {
        if (junk.isJunk(entry.name)) continue;
        if (entry.kind == .sym_link) return error.SymlinkInSource;

        const abs = try std.fs.path.join(arena, &.{ dot_d_abs, entry.name });

        if (entry.kind == .file) {
            // Files without `=` in the stem aren't axis-named overlays.
            // They're data sources (TOML for for-loops) or other auxiliary
            // files; skip them here -- catB resolves them by explicit path.
            if (std.mem.indexOfScalar(u8, fragmentStem(entry.name), '=') == null) continue;
            const t = tuple_mod.parseFilename(arena, entry.name) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidEntry,
            };
            // A value may itself contain a dot the extension heuristic strips
            // (a `machine` value is a hostname, and every macOS hostname ends
            // in `.local`); when it does, also parse the filename verbatim so
            // the exact reading -- what was actually written -- is a
            // candidate too.
            var exact: ?AxisTuple = null;
            if (!std.mem.eql(u8, tuple_mod.stripExtension(entry.name), entry.name)) {
                exact = tuple_mod.parseFilenameVerbatim(arena, entry.name) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => null,
                };
            }
            try overlays.append(arena, .{ .path = abs, .tuple = t, .exact_tuple = exact });
        } else if (entry.kind == .directory) {
            var region_dir = try dot_d_dir.openDir(io, entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            });
            defer region_dir.close(io);
            const region_name = try arena.dupe(u8, entry.name);

            var fragments: std.ArrayList(Fragment) = .empty;
            errdefer fragments.deinit(arena);
            for (try dirent.sorted(arena, io, region_dir)) |f_entry| {
                if (junk.isJunk(f_entry.name)) continue;
                if (f_entry.kind == .sym_link) return error.SymlinkInSource;
                if (f_entry.kind != .file) continue;
                const f_abs = try std.fs.path.join(arena, &.{ abs, f_entry.name });
                // Cat-B fragment: filename is `<value>[.<ext>]`. Construct the
                // single-pair tuple from (region_name, stem-of-filename), and a
                // second from the whole filename when a suffix was stripped --
                // the value may BE the whole filename.
                const stem = fragmentStem(f_entry.name);
                const pairs = try arena.alloc(AxisTuple.Pair, 1);
                pairs[0] = .{ .name = region_name, .value = try arena.dupe(u8, stem) };
                var exact: ?AxisTuple = null;
                if (stem.len != f_entry.name.len) {
                    const exact_pairs = try arena.alloc(AxisTuple.Pair, 1);
                    exact_pairs[0] = .{ .name = region_name, .value = try arena.dupe(u8, f_entry.name) };
                    exact = .{ .pairs = exact_pairs };
                }
                try fragments.append(arena, .{
                    .path = f_abs,
                    .tuple = .{ .pairs = pairs },
                    .exact_tuple = exact,
                });
            }
            std.mem.sort(Fragment, fragments.items, {}, fragmentLess);
            try regions.append(arena, .{
                .name = region_name,
                .path = abs,
                .fragments = try fragments.toOwnedSlice(arena),
            });
        }
    }

    // Canonical order so composition never depends on filesystem iteration
    // order: catA folds and catB/catC selection see overlays and fragments in
    // the same order on every machine.
    std.mem.sort(Overlay, overlays.items, {}, overlayLess);
    overlays_out.* = try overlays.toOwnedSlice(arena);
    regions_out.* = try regions.toOwnedSlice(arena);
}

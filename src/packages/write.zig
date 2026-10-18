//! Writing reconciled rows to a manifest file.
//!
//! A new row is an append, never an edit: the block goes at the end of the
//! file, so every existing byte -- comments, ordering, spacing, a row someone
//! is mid-thought on -- is preserved exactly. toml-zig's document editors
//! refuse array-of-tables paths anyway, and a whole-array rewrite would
//! re-emit the list canonically and drop its comments.
//!
//! Removing a row, or gating it off one machine, splices only that row's own
//! lines, found through the lossless item scan. The edited bytes are loaded
//! back and must equal the original but for that one change before anything
//! is written.

const std = @import("std");
const builtin = @import("builtin");
const toml = @import("toml");

const apply_write = @import("../apply/write.zig");
const partial = @import("../apply/partial.zig");
const axis = @import("../dsl/axis.zig");
const resolver_mod = @import("../dsl/resolver.zig");
const backend_mod = @import("backend.zig");
const manifest_mod = @import("manifest.zig");

const Io = std.Io;

pub const Declaration = backend_mod.Backend.Declaration;
pub const Manifest = manifest_mod.Manifest;
pub const Source = manifest_mod.Source;
pub const Resolver = resolver_mod.Resolver;

pub const Array = enum {
    packages,
    blacklist,

    fn header(self: Array) []const u8 {
        return switch (self) {
            .packages => "[[packages]]",
            .blacklist => "[[blacklist]]",
        };
    }
};

pub const Error = error{ NoManifestFileForBackend, TooManySymlinkHops };

/// The file a row of `array` for `backend` belongs in. Every repo file is
/// preferred over every private one -- a package belongs in the shared
/// manifest unless the user says otherwise -- and within a layer, one whose
/// own default backend matches before one that merely carries a row for it.
/// Basename order breaks ties so the same machine always picks the same file.
///
/// When no repo file is eligible -- for a blacklist row, every one of them
/// gated -- an ungated private file takes it. That is narrower than the gate
/// `eligible` refuses, and narrower is what the private layer means: the row
/// holds on this machine and is in no other machine's manifest to be inert in.
pub fn targetFor(arena: std.mem.Allocator, m: Manifest, backend: []const u8, r: *const Resolver, array: Array) !?Source {
    for ([_]bool{ false, true }) |private| {
        for (m.sources) |src| {
            if (src.private != private) continue;
            if (!try eligible(arena, src, r, array)) continue;
            if (src.default_backend) |d| {
                if (std.mem.eql(u8, d, backend)) return src;
            }
        }
        for (m.sources) |src| {
            if (src.private != private) continue;
            if (!try eligible(arena, src, r, array)) continue;
            if (carriesRow(m, src, backend)) return src;
        }
    }
    return null;
}

/// Whether a row of `array` may be written into `src` on this machine. A
/// package row belongs only in a file whose gate holds here: one recorded
/// elsewhere would not be wanted on the machine that just recorded it. A
/// blacklist holds regardless of which machine asks, so its file carries no
/// gate at all -- `manifest.load` refuses one that does, which would make the
/// row mox just wrote refuse the whole manifest on the next command.
///
/// An ungated file in the private layer is eligible for a blacklist row, and
/// is where one lands when every repo file is gated. The gate is refused
/// because a repo file is SHARED: the row would hold here and sit inert in
/// every other machine's copy of it. A private file is this machine's alone,
/// so the same narrowing is what the layer already is, and `mox commit` prints
/// the layer it wrote to, leaving nothing to discover later.
fn eligible(arena: std.mem.Allocator, src: Source, r: *const Resolver, array: Array) !bool {
    return switch (array) {
        .packages => try gateHolds(arena, src, r),
        .blacklist => src.when == null,
    };
}

/// A file with no `when` is unconditional. `manifest.load` rejected a
/// malformed gate, so a failure here is allocation, and is propagated rather
/// than read as "excluded".
fn gateHolds(arena: std.mem.Allocator, src: Source, r: *const Resolver) !bool {
    const expr_src = src.when orelse return true;
    const expr = try axis.parseString(arena, expr_src);
    return axis.evaluate(expr, r);
}

/// Whether `src` already holds a row for `backend`: a package or a blacklist
/// entry, either one saying the file speaks that backend.
fn carriesRow(m: Manifest, src: Source, backend: []const u8) bool {
    for (m.packages) |row| {
        if (std.mem.eql(u8, row.backend, backend) and std.mem.eql(u8, row.origin, src.path)) return true;
    }
    for (m.blacklist) |row| {
        if (std.mem.eql(u8, row.backend, backend) and std.mem.eql(u8, row.origin, src.path)) return true;
    }
    return false;
}

/// Render the block `append` would write, without touching the filesystem.
/// `backend` is written only when the target file declares no matching
/// default, so a row never restates what its file already says.
pub fn render(
    arena: std.mem.Allocator,
    array: Array,
    decl: Declaration,
    backend: ?[]const u8,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("\n{s}\n", .{array.header()});
    try out.writer.print("name = {f}\n", .{Quoted{ .s = decl.name }});
    if (backend) |b| try out.writer.print("backend = {f}\n", .{Quoted{ .s = b }});
    for (decl.fields) |p| {
        const key = Key{ .s = p.key };
        switch (p.value) {
            .string => |v| try out.writer.print("{f} = {f}\n", .{ key, Quoted{ .s = v } }),
            .int => |v| try out.writer.print("{f} = {d}\n", .{ key, v }),
            .boolean => |v| try out.writer.print("{f} = {s}\n", .{ key, if (v) "true" else "false" }),
            .strings => |vs| {
                try out.writer.print("{f} = [", .{key});
                for (vs, 0..) |v, i| {
                    if (i > 0) try out.writer.writeAll(", ");
                    try out.writer.print("{f}", .{Quoted{ .s = v }});
                }
                try out.writer.writeAll("]\n");
            },
        }
    }
    return out.written();
}

/// The file-level lines `src` declares, for `append` to write should it have
/// to recreate the file. Empty when the file declares neither.
pub fn renderHeader(arena: std.mem.Allocator, src: Source) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    if (src.default_backend) |b| try out.writer.print("backend = {f}\n", .{Quoted{ .s = b }});
    if (src.when) |w| try out.writer.print("when = {f}\n", .{Quoted{ .s = w }});
    return out.written();
}

/// One row as a single-line TOML inline table, the form a plugin reads from
/// its stdin one row per line: `{ name = "ghostty", kind = "cask" }`.
pub fn inlineRow(arena: std.mem.Allocator, name: []const u8, fields: []const manifest_mod.Pair) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("{{ name = {f}", .{Quoted{ .s = name }});
    for (fields) |p| {
        const key = Key{ .s = p.key };
        switch (p.value) {
            .string => |v| try out.writer.print(", {f} = {f}", .{ key, Quoted{ .s = v } }),
            .int => |v| try out.writer.print(", {f} = {d}", .{ key, v }),
            .boolean => |v| try out.writer.print(", {f} = {s}", .{ key, if (v) "true" else "false" }),
            .strings => |vs| {
                try out.writer.print(", {f} = [", .{key});
                for (vs, 0..) |v, i| {
                    if (i > 0) try out.writer.writeAll(", ");
                    try out.writer.print("{f}", .{Quoted{ .s = v }});
                }
                try out.writer.writeAll("]");
            },
        }
    }
    try out.writer.writeAll(" }");
    return out.written();
}

/// Append the block to `path`, creating the file when it does not exist.
/// `header` is what the file declared when `block` was rendered against it --
/// the block omits whatever the file already says -- so a file that vanished
/// between the two comes back declaring it, rather than as a file `commit`
/// wrote and `load` refuses. The rewrite is atomic: a manifest in the private
/// layer lives in no git repo, and a crash mid-write must not leave it empty.
/// A manifest that is a symlink is rewritten where the link points, so the
/// link survives. The read and the rewrite are one critical section, held
/// against every other writer of that file by `DirLock`.
pub fn append(arena: std.mem.Allocator, io: Io, link_path: []const u8, header: []const u8, block: []const u8) !void {
    const path = try resolveLinks(arena, io, link_path);
    const guard = DirLock.acquire(io, std.fs.path.dirname(path) orelse ".");
    defer guard.release(io);
    const existing = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20)) catch |e| switch (e) {
        error.FileNotFound => {
            const body = if (header.len == 0)
                std.mem.trimStart(u8, block, "\n")
            else
                try std.fmt.allocPrint(arena, "{s}{s}", .{ header, block });
            try apply_write.writeAtomic(io, path, body, 0o644);
            return;
        },
        else => return e,
    };

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, existing);
    // A file not ending in a newline would otherwise glue its last line to
    // the new header.
    if (existing.len > 0 and existing[existing.len - 1] != '\n') {
        try buf.append(arena, '\n');
    }
    // An empty file gets the block the way a missing one does: the leading
    // newline separates a block from what precedes it, and nothing does.
    try buf.appendSlice(arena, if (existing.len == 0) std.mem.trimStart(u8, block, "\n") else block);
    try apply_write.writeAtomic(io, path, buf.items, try modeOf(io, path));
}

/// Exclusive access to the directory a manifest file lives in, held across an
/// append's read and rewrite so that two of them cannot both read the file
/// before either writes it, which drops whichever row was written first.
///
/// The state lock does not reach this far: it keys on the state directory,
/// and two runs sharing one MOX_REPO have a state directory each -- `mox
/// commit` beside `sudo mox commit`, or either under a `MOX_STATE` of its
/// own. What is locked is the directory rather than the manifest, because the
/// rewrite renames a new inode over the old one: a lock on the file excludes
/// nobody once the first writer has swapped it, while the directory is one
/// inode every writer of every file in it opens. Appending in place under the
/// lock would keep the file's inode but give up the atomic replace, and a
/// crash would then leave a half-written trailing block that no later command
/// can parse.
///
/// Advisory and best effort. A directory is not lockable on Windows, and a
/// filesystem may refuse the lock anywhere; the append then runs as it would
/// with no lock at all, where the per-writer staging path still keeps the two
/// rewrites out of one inode and leaves at most a dropped row.
pub const DirLock = struct {
    file: ?Io.File,

    pub fn acquire(io: Io, dir_path: []const u8) DirLock {
        if (builtin.os.tag == .windows) return .{ .file = null };
        Io.Dir.cwd().createDirPath(io, dir_path) catch {};
        const f = Io.Dir.cwd().openFile(io, dir_path, .{}) catch return .{ .file = null };
        f.lock(io, .exclusive) catch {
            f.close(io);
            return .{ .file = null };
        };
        return .{ .file = f };
    }

    pub fn release(self: DirLock, io: Io) void {
        const f = self.file orelse return;
        f.unlock(io);
        f.close(io);
    }
};

/// What came of editing a row in place.
pub const Edit = union(enum) {
    /// The file holds the change.
    written,
    /// The file was left as it was, and why, for the user to act on.
    left: []const u8,
};

const RowChange = union(enum) {
    remove,
    /// Gate the row off the machine of this `machine` axis value.
    keep_off: []const u8,
};

/// Delete `row`'s `[[packages]]` element from the file it came from, for
/// every machine: its header through its last key, comments between its keys
/// included. Lines before the header and after the last key stay; where that
/// leaves two blank lines meeting, one goes.
pub fn removeRow(arena: std.mem.Allocator, io: Io, row: manifest_mod.Row) !Edit {
    return editRow(arena, io, row, .remove);
}

/// Gate `row` off the machine whose `machine` axis value is `machine`, on
/// the element's own `when`: `not machine="<m>"`, or `(<W>) and not
/// machine="<m>"` around the `when` it has. A new `when` line goes directly
/// after the `name` line, in that line's line ending; an existing one is
/// replaced in place, keeping its trailing comment.
pub fn setWhen(arena: std.mem.Allocator, io: Io, row: manifest_mod.Row, machine: []const u8) !Edit {
    return editRow(arena, io, row, .{ .keep_off = machine });
}

/// `row`'s element in `row.origin`, located by content in the file as it is
/// now, changed in memory, loaded back and compared, then written atomically
/// through any symlink, all under the manifest directory's lock so that no
/// other writer's change is lost between the read and the write.
fn editRow(arena: std.mem.Allocator, io: Io, row: manifest_mod.Row, change: RowChange) !Edit {
    const path = try resolveLinks(arena, io, row.origin);
    const guard = DirLock.acquire(io, std.fs.path.dirname(path) orelse ".");
    defer guard.release(io);
    const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(manifest_mod.max_file_bytes)) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .left = try std.fmt.allocPrint(arena, "it could not be read ({s})", .{@errorName(e)}) },
    };

    var diag: manifest_mod.Diag = .{};
    const original = manifest_mod.loadFile(arena, row.origin, row.label, false, content, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .left = try std.fmt.allocPrint(arena, "it no longer loads: {s}", .{diag.capture() orelse @errorName(e)}) },
    };
    const scan = partial.tomlScan(arena, content) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .left = "it could not be scanned line by line; edit it by hand" },
    };
    const items = scan.doc.items.items;

    var headers: std.ArrayList(usize) = .empty;
    for (items, 0..) |item, i| switch (item) {
        .header => |h| if (h.is_array and isPackagesPath(h.path_segments)) try headers.append(arena, i),
        .kv => |kv| if (scan.encl[i] == null and isPackagesPath(kv.full_path_segments))
            return .{ .left = "its rows are written inline (packages = [...]), which mox does not edit; edit it by hand" },
        else => {},
    };
    if (headers.items.len != original.packages.len)
        return .{ .left = "its [[packages]] rows could not be told apart line by line; edit it by hand" };

    var target: ?usize = null;
    var matches: usize = 0;
    for (original.packages, 0..) |r, k| {
        if (!sameRow(r, row)) continue;
        matches += 1;
        target = k;
    }
    if (matches == 0) return .{ .left = "no row in it is the one reported any more" };
    if (matches > 1) return .{ .left = try std.fmt.allocPrint(arena, "{d} rows in it match the one reported", .{matches}) };
    const k = target.?;

    const head = headers.items[k];
    var past = head + 1;
    while (past < items.len and items[past] != .header) past += 1;
    var last: ?usize = null;
    var name_at: ?usize = null;
    var when_at: ?usize = null;
    for (head + 1..past) |i| {
        const kv = switch (items[i]) {
            .kv => |kv| kv,
            else => continue,
        };
        last = i;
        if (isRowKey(kv.full_path_segments, "name")) name_at = i;
        if (isRowKey(kv.full_path_segments, "when")) when_at = i;
    }
    // The loader refused an element without a name.
    const end = last orelse return .{ .left = "its row has no keys to edit; edit it by hand" };

    var out: std.ArrayList(u8) = .empty;
    var new_when: ?[]const u8 = null;
    switch (change) {
        .remove => {
            var resume_at = end + 1;
            if (head > 0 and items[head - 1] == .blank and resume_at < items.len and items[resume_at] == .blank) resume_at += 1;
            try out.appendSlice(arena, content[0..scan.offs[head]]);
            if (resume_at < items.len) try out.appendSlice(arena, content[scan.offs[resume_at]..]);
        },
        .keep_off => |machine| {
            const gate = try std.fmt.allocPrint(arena, "not machine=\"{s}\"", .{machine});
            if (when_at) |w| {
                const kv = items[w].kv;
                const value = kv.raw[kv.value_offset..][0..kv.value_len];
                if (std.mem.startsWith(u8, value, "\"\"\"") or std.mem.startsWith(u8, value, "'"))
                    return .{ .left = "its \"when\" is a multi-line or literal string, which mox does not edit; edit it by hand" };
                const own = ownWhen(scan.doc.parsed, k) orelse
                    return .{ .left = "its \"when\" could not be read line by line; edit it by hand" };
                const raw = try std.fmt.allocPrint(arena, "({s}) and {s}", .{ own, gate });
                new_when = raw;
                try out.appendSlice(arena, content[0..scan.offs[w]]);
                try out.appendSlice(arena, kv.raw[0..kv.value_offset]);
                try out.print(arena, "{f}", .{Quoted{ .s = raw }});
                try out.appendSlice(arena, kv.raw[kv.value_offset + kv.value_len ..]);
                try out.appendSlice(arena, content[scan.ends[w]..]);
            } else {
                const n = name_at orelse return .{ .left = "its row has no name line to follow; edit it by hand" };
                new_when = gate;
                const name_raw = items[n].rawBytes();
                const ending = lineEnding(name_raw) orelse lineEnding(items[head].rawBytes()) orelse "\n";
                try out.appendSlice(arena, content[0..scan.ends[n]]);
                // A name line that ends the file gets its newline first; the
                // new line then ends the file as the name line did, without one.
                const at_eof = lineEnding(name_raw) == null;
                if (at_eof) try out.appendSlice(arena, ending);
                try out.print(arena, "when = {f}", .{Quoted{ .s = gate }});
                if (!at_eof) try out.appendSlice(arena, ending);
                try out.appendSlice(arena, content[scan.ends[n]..]);
            }
        },
    }

    var cand_diag: manifest_mod.Diag = .{};
    const candidate = manifest_mod.loadFile(arena, row.origin, row.label, false, out.items, &cand_diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .left = try std.fmt.allocPrint(arena, "the edited file would not load ({s}); edit it by hand", .{cand_diag.capture() orelse @errorName(e)}) },
    };
    const expected_when: ?[]const u8 = if (new_when) |w|
        manifest_mod.combineWhen(arena, original.sources[0].when, w) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return .{ .left = "the gate would be too deeply nested; edit it by hand" },
        }
    else
        null;
    if (!onlyChange(original, candidate, k, change, expected_when))
        return .{ .left = "the edited file would change more than this row; edit it by hand" };

    try apply_write.writeAtomic(io, path, out.items, try modeOf(io, path));
    return .written;
}

fn isPackagesPath(segs: []const []const u8) bool {
    return segs.len == 1 and std.mem.eql(u8, segs[0], "packages");
}

fn isRowKey(segs: []const []const u8, key: []const u8) bool {
    return segs.len == 2 and std.mem.eql(u8, segs[0], "packages") and std.mem.eql(u8, segs[1], key);
}

/// The line ending `raw` closes with, or null when it ends the file.
fn lineEnding(raw: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, raw, "\r\n")) return "\r\n";
    if (std.mem.endsWith(u8, raw, "\n")) return "\n";
    return null;
}

/// Element `k`'s own `when`, decoded, before the file gate is combined in.
fn ownWhen(parsed: toml.Value, k: usize) ?[]const u8 {
    if (parsed != .table) return null;
    const arr = parsed.table.get("packages") orelse return null;
    if (arr != .array or k >= arr.array.items.len) return null;
    const el = arr.array.items[k];
    if (el != .table) return null;
    const w = el.table.get("when") orelse return null;
    return if (w == .string) w.string else null;
}

/// The same package row as the loader reads it: name, backend, merged gate
/// and adapter fields, in any key order. Where it sits is not compared, so a
/// row moved by an edit between prompts is still found.
fn sameRow(a: manifest_mod.Row, b: manifest_mod.Row) bool {
    if (!std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.backend, b.backend)) return false;
    if (!optEql(a.when, b.when)) return false;
    return sameFields(a.fields, b.fields);
}

fn sameFields(a: []const manifest_mod.Pair, b: []const manifest_mod.Pair) bool {
    if (a.len != b.len) return false;
    outer: for (a) |p| {
        for (b) |q| {
            if (std.mem.eql(u8, p.key, q.key)) {
                if (!fieldEql(p.value, q.value)) return false;
                continue :outer;
            }
        }
        return false;
    }
    return true;
}

fn fieldEql(a: manifest_mod.Field, b: manifest_mod.Field) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .string => |v| std.mem.eql(u8, v, b.string),
        .int => |v| v == b.int,
        .boolean => |v| v == b.boolean,
        .strings => |vs| blk: {
            if (vs.len != b.strings.len) break :blk false;
            for (vs, b.strings) |x, y| if (!std.mem.eql(u8, x, y)) break :blk false;
            break :blk true;
        },
    };
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Whether `candidate` is `original` with exactly `change` made to package
/// row `k`: the file-level keys, every blacklist and bootstrap row, and every
/// other package row equal, and row `k` gone or carrying `expected_when`.
fn onlyChange(original: Manifest, candidate: Manifest, k: usize, change: RowChange, expected_when: ?[]const u8) bool {
    const so = original.sources[0];
    const sc = candidate.sources[0];
    if (!optEql(so.default_backend, sc.default_backend) or !optEql(so.when, sc.when)) return false;

    if (original.blacklist.len != candidate.blacklist.len) return false;
    for (original.blacklist, candidate.blacklist) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name) or !std.mem.eql(u8, x.backend, y.backend) or !sameFields(x.fields, y.fields)) return false;
    }
    if (original.bootstrap.len != candidate.bootstrap.len) return false;
    for (original.bootstrap, candidate.bootstrap) |x, y| {
        if (!std.mem.eql(u8, x.backend, y.backend) or !std.mem.eql(u8, x.url, y.url) or
            !std.mem.eql(u8, x.sha256, y.sha256) or !optEql(x.when, y.when)) return false;
    }

    switch (change) {
        .remove => {
            if (candidate.packages.len + 1 != original.packages.len) return false;
            for (candidate.packages, 0..) |c, j| {
                if (!sameRow(c, original.packages[if (j < k) j else j + 1])) return false;
            }
        },
        .keep_off => {
            if (candidate.packages.len != original.packages.len) return false;
            for (original.packages, candidate.packages, 0..) |o, c, j| {
                if (j != k) {
                    if (!sameRow(o, c)) return false;
                    continue;
                }
                var want = o;
                want.when = expected_when;
                if (!sameRow(want, c)) return false;
            }
        },
    }
    return true;
}

const max_link_hops: usize = 8;

/// The file `path` finally names, following a symlink chain with each
/// relative target read against the directory of the link that holds it. A
/// dangling link resolves to its missing target, which the caller then
/// creates, making the link good rather than replacing it.
fn resolveLinks(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    var cur = path;
    var hops: usize = 0;
    while (true) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().readLink(io, cur, &buf) catch |e| switch (e) {
            error.NotLink, error.FileNotFound => return cur,
            else => return e,
        };
        if (hops == max_link_hops) return Error.TooManySymlinkHops;
        hops += 1;
        const target = buf[0..n];
        cur = if (std.fs.path.isAbsolute(target))
            try arena.dupe(u8, target)
        else
            try std.fs.path.resolve(arena, &.{ std.fs.path.dirname(cur) orelse ".", target });
    }
}

/// The mode the rewrite keeps: a private manifest the user made 0600 must
/// not come back 0644 for having a row appended.
fn modeOf(io: Io, path: []const u8) !u32 {
    if (!Io.File.Permissions.has_executable_bit) return 0o644;
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    return st.permissions.toMode();
}

/// Whether a key can be written bare: `[A-Za-z0-9_-]+`, the TOML bare-key
/// charset.
pub fn keyOk(k: []const u8) bool {
    if (k.len == 0) return false;
    for (k) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

/// A TOML key: bare when it can be, a basic string otherwise. The manifest
/// accepts any key, so what is handed to a plugin or written back must spell
/// it the way TOML reads it, not lose the quotes it needed.
const Key = struct {
    s: []const u8,

    pub fn format(self: Key, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (keyOk(self.s)) return w.writeAll(self.s);
        return (Quoted{ .s = self.s }).format(w);
    }
};

/// A TOML basic string. A package name is normally plain, but a manager is
/// free to use any bytes, and an unescaped quote or backslash would produce a
/// manifest that no longer parses.
const Quoted = struct {
    s: []const u8,

    pub fn format(self: Quoted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('"');
        for (self.s) |c| switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (c < 0x20 or c == 0x7f) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        };
        try w.writeByte('"');
    }
};

const testing = std.testing;

fn sourceOf(label: []const u8, path: []const u8, default_backend: ?[]const u8, private: bool) Source {
    return .{ .path = path, .label = label, .default_backend = default_backend, .private = private };
}

fn gatedSource(label: []const u8, path: []const u8, default_backend: ?[]const u8, when: []const u8) Source {
    return .{ .path = path, .label = label, .default_backend = default_backend, .when = when, .private = false };
}

/// A machine with no bindings at all: every gated file is excluded, every
/// ungated one is in.
const no_bindings: std.StringHashMap([]const u8) = .init(testing.allocator);
const unbound: Resolver = .{ .live = &.{ .bindings = &no_bindings } };

test "render: a bare formula is name only when the file declares the backend" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a, .packages, .{ .name = "htop" }, null);
    try testing.expectEqualStrings("\n[[packages]]\nname = \"htop\"\n", got);
}

test "render: a cask carries its identifying field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a, .packages, .{
        .name = "ghostty",
        .fields = &.{.{ .key = "kind", .value = .{ .string = "cask" } }},
    }, null);
    try testing.expectEqualStrings("\n[[packages]]\nname = \"ghostty\"\nkind = \"cask\"\n", got);
}

test "render: backend is written only when the file does not already say it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a, .blacklist, .{ .name = "usage" }, "brew");
    try testing.expectEqualStrings("\n[[blacklist]]\nname = \"usage\"\nbackend = \"brew\"\n", got);
}

test "render: a quote or backslash in a name cannot break the manifest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a, .packages, .{ .name = "we\"ird\\name" }, null);
    try testing.expectEqualStrings("\n[[packages]]\nname = \"we\\\"ird\\\\name\"\n", got);
}

test "render: int, bool and string-array fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a, .packages, .{
        .name = "Xcode",
        .fields = &.{
            .{ .key = "id", .value = .{ .int = 497799835 } },
            .{ .key = "pin", .value = .{ .boolean = true } },
            .{ .key = "args", .value = .{ .strings = &.{ "--a", "--b" } } },
        },
    }, null);
    try testing.expectEqualStrings(
        "\n[[packages]]\nname = \"Xcode\"\nid = 497799835\npin = true\nargs = [\"--a\", \"--b\"]\n",
        got,
    );
}

test "inlineRow: a row renders as one inline table on one line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try inlineRow(a, "ghostty", &.{.{ .key = "kind", .value = .{ .string = "cask" } }});
    try testing.expectEqualStrings("{ name = \"ghostty\", kind = \"cask\" }", got);
    try testing.expect(std.mem.indexOfScalar(u8, got, '\n') == null);
}

test "inlineRow: a key outside the bare charset is quoted, never misparsed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try inlineRow(a, "x", &.{
        .{ .key = "my key", .value = .{ .int = 1 } },
        .{ .key = "a.b", .value = .{ .string = "v" } },
    });
    try testing.expectEqualStrings("{ name = \"x\", \"my key\" = 1, \"a.b\" = \"v\" }", got);
}

test "inlineRow: an underscore or a hyphen in a key is written bare, not quoted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try inlineRow(a, "x", &.{
        .{ .key = "auto_update", .value = .{ .boolean = false } },
        .{ .key = "no-quarantine", .value = .{ .boolean = true } },
        .{ .key = "x86_64", .value = .{ .int = 1 } },
    });
    try testing.expectEqualStrings(
        "{ name = \"x\", auto_update = false, no-quarantine = true, x86_64 = 1 }",
        got,
    );
}

test "inlineRow: a string-array field renders as a bracketed list, comma-separated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try inlineRow(a, "nginx", &.{
        .{ .key = "args", .value = .{ .strings = &.{ "--with-http_v2", "--with-debug" } } },
        .{ .key = "kind", .value = .{ .string = "formula" } },
    });
    try testing.expectEqualStrings(
        "{ name = \"nginx\", args = [\"--with-http_v2\", \"--with-debug\"], kind = \"formula\" }",
        got,
    );
}

test "render: an underscore or a hyphen in a key is written bare, not quoted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a, .packages, .{
        .name = "ghostty",
        .fields = &.{
            .{ .key = "auto_update", .value = .{ .boolean = false } },
            .{ .key = "no-quarantine", .value = .{ .boolean = true } },
        },
    }, null);
    try testing.expectEqualStrings(
        "\n[[packages]]\nname = \"ghostty\"\nauto_update = false\nno-quarantine = true\n",
        got,
    );
}

test "targetFor: a file carrying only a blacklist row for the backend speaks it" {
    const row: manifest_mod.BlacklistRow = .{
        .name = "usage",
        .backend = "brew",
        .fields = &.{},
        .origin = "/r/mixed.toml",
        .label = "data/packages/mixed.toml",
        .index = 0,
    };
    const m: Manifest = .{
        .blacklist = &.{row},
        .sources = &.{
            sourceOf("data/packages/a.toml", "/r/a.toml", "dnf", false),
            sourceOf("data/packages/mixed.toml", "/r/mixed.toml", null, false),
        },
    };
    try testing.expectEqualStrings("/r/mixed.toml", (try targetFor(testing.allocator, m, "brew", &unbound, .packages)).?.path);
}

test "targetFor: prefers a file whose own default names the backend" {
    const m: Manifest = .{ .sources = &.{
        sourceOf("data/packages/a.toml", "/r/a.toml", "dnf", false),
        sourceOf("data/packages/b.toml", "/r/b.toml", "brew", false),
    } };
    try testing.expectEqualStrings("/r/b.toml", (try targetFor(testing.allocator, m, "brew", &unbound, .packages)).?.path);
}

test "targetFor: prefers the repo layer over the private one" {
    const m: Manifest = .{ .sources = &.{
        sourceOf("data/packages/local.toml", "/p/local.toml", "brew", true),
        sourceOf("data/packages/darwin.toml", "/r/darwin.toml", "brew", false),
    } };
    try testing.expectEqualStrings("/r/darwin.toml", (try targetFor(testing.allocator, m, "brew", &unbound, .packages)).?.path);
}

test "targetFor: a repo file merely carrying a row beats a private file declaring the default" {
    const row: manifest_mod.Row = .{
        .name = "ripgrep",
        .backend = "brew",
        .when = null,
        .fields = &.{},
        .origin = "/r/mixed.toml",
        .label = "data/packages/mixed.toml",
        .index = 0,
    };
    const m: Manifest = .{
        .packages = &.{row},
        .sources = &.{
            sourceOf("data/packages/local.toml", "/p/local.toml", "brew", true),
            sourceOf("data/packages/mixed.toml", "/r/mixed.toml", null, false),
        },
    };
    try testing.expectEqualStrings("/r/mixed.toml", (try targetFor(testing.allocator, m, "brew", &unbound, .packages)).?.path);
}

test "targetFor: falls back to a file already carrying a row for the backend" {
    const row: manifest_mod.Row = .{
        .name = "ripgrep",
        .backend = "brew",
        .when = null,
        .fields = &.{},
        .origin = "/r/mixed.toml",
        .label = "data/packages/mixed.toml",
        .index = 0,
    };
    const m: Manifest = .{
        .packages = &.{row},
        .sources = &.{sourceOf("data/packages/mixed.toml", "/r/mixed.toml", null, false)},
    };
    try testing.expectEqualStrings("/r/mixed.toml", (try targetFor(testing.allocator, m, "brew", &unbound, .packages)).?.path);
}

test "targetFor: a row for another backend, or one belonging to another file, is not a file speaking the backend" {
    const foreign: manifest_mod.Row = .{
        .name = "bat",
        .backend = "dnf",
        .when = null,
        .fields = &.{},
        .origin = "/r/a.toml",
        .label = "data/packages/a.toml",
        .index = 0,
    };
    const mine: manifest_mod.Row = .{
        .name = "htop",
        .backend = "brew",
        .when = null,
        .fields = &.{},
        .origin = "/r/b.toml",
        .label = "data/packages/b.toml",
        .index = 1,
    };
    // Neither file declares a default, so a.toml is reached first and holds
    // a row of its own; only b.toml holds one for brew.
    const m: Manifest = .{
        .packages = &.{ foreign, mine },
        .sources = &.{
            sourceOf("data/packages/a.toml", "/r/a.toml", null, false),
            sourceOf("data/packages/b.toml", "/r/b.toml", null, false),
        },
    };
    try testing.expectEqualStrings("/r/b.toml", (try targetFor(testing.allocator, m, "brew", &unbound, .packages)).?.path);
}

test "targetFor: a repo file carrying a row beats a private file carrying one, whatever their order" {
    const priv_row: manifest_mod.Row = .{
        .name = "ripgrep",
        .backend = "brew",
        .when = null,
        .fields = &.{},
        .origin = "/p/local.toml",
        .label = "data/packages/local.toml (private layer)",
        .index = 0,
    };
    const repo_row: manifest_mod.Row = .{
        .name = "htop",
        .backend = "brew",
        .when = null,
        .fields = &.{},
        .origin = "/r/mixed.toml",
        .label = "data/packages/mixed.toml",
        .index = 0,
    };
    // Neither file declares a default, so both are reached by the same arm,
    // and the private one comes first.
    const m: Manifest = .{
        .packages = &.{ priv_row, repo_row },
        .sources = &.{
            sourceOf("data/packages/local.toml", "/p/local.toml", null, true),
            sourceOf("data/packages/mixed.toml", "/r/mixed.toml", null, false),
        },
    };
    try testing.expectEqualStrings("/r/mixed.toml", (try targetFor(testing.allocator, m, "brew", &unbound, .packages)).?.path);
}

test "targetFor: a file already carrying a row for the backend is still refused when its gate excludes it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "darwin");
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    const row: manifest_mod.Row = .{
        .name = "ripgrep",
        .backend = "brew",
        .when = null,
        .fields = &.{},
        .origin = "/r/linux.toml",
        .label = "data/packages/linux.toml",
        .index = 0,
    };
    const listed: manifest_mod.BlacklistRow = .{
        .name = "usage",
        .backend = "brew",
        .fields = &.{},
        .origin = "/r/linux.toml",
        .label = "data/packages/linux.toml",
        .index = 0,
    };
    const m: Manifest = .{
        .packages = &.{row},
        .blacklist = &.{listed},
        .sources = &.{gatedSource("data/packages/linux.toml", "/r/linux.toml", null, "os=linux")},
    };
    try testing.expect((try targetFor(a, m, "brew", &r, .packages)) == null);
    try testing.expect((try targetFor(a, m, "brew", &r, .blacklist)) == null);
}

test "targetFor: no file speaks the backend" {
    const m: Manifest = .{ .sources = &.{sourceOf("data/packages/a.toml", "/r/a.toml", "dnf", false)} };
    try testing.expect((try targetFor(testing.allocator, m, "brew", &unbound, .packages)) == null);
}

test "targetFor: a file whose gate excludes this machine is never the target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "darwin");
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    const excluded: Manifest = .{ .sources = &.{
        gatedSource("data/packages/linux.toml", "/r/linux.toml", "brew", "os=linux"),
    } };
    try testing.expect((try targetFor(a, excluded, "brew", &r, .packages)) == null);

    // The same file, gated to this machine, is the target as before.
    const included: Manifest = .{ .sources = &.{
        gatedSource("data/packages/darwin.toml", "/r/darwin.toml", "brew", "os=darwin"),
    } };
    try testing.expectEqualStrings("/r/darwin.toml", (try targetFor(a, included, "brew", &r, .packages)).?.path);
}

test "targetFor: an excluded file is passed over for one that holds here" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "darwin");
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    // Basename order would pick a.toml; its gate hands the row to b.toml.
    const m: Manifest = .{ .sources = &.{
        gatedSource("data/packages/a.toml", "/r/a.toml", "brew", "os=linux"),
        sourceOf("data/packages/b.toml", "/r/b.toml", "brew", false),
    } };
    try testing.expectEqualStrings("/r/b.toml", (try targetFor(a, m, "brew", &r, .packages)).?.path);
}

test "targetFor: a blacklist row never goes in a gated file, which would refuse the manifest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "darwin");
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    // The gate holds here, so a package row belongs in it; a blacklist row
    // in the same file is what `manifest.load` refuses.
    const only_gated: Manifest = .{ .sources = &.{
        gatedSource("data/packages/darwin.toml", "/r/darwin.toml", "brew", "os=darwin"),
    } };
    try testing.expectEqualStrings("/r/darwin.toml", (try targetFor(a, only_gated, "brew", &r, .packages)).?.path);
    try testing.expect((try targetFor(a, only_gated, "brew", &r, .blacklist)) == null);

    // With an ungated file beside it, the blacklist row goes there and the
    // package row still prefers the gated one's own default.
    const both: Manifest = .{ .sources = &.{
        gatedSource("data/packages/darwin.toml", "/r/darwin.toml", "brew", "os=darwin"),
        sourceOf("data/packages/shared.toml", "/r/shared.toml", "brew", false),
    } };
    try testing.expectEqualStrings("/r/darwin.toml", (try targetFor(a, both, "brew", &r, .packages)).?.path);
    try testing.expectEqualStrings("/r/shared.toml", (try targetFor(a, both, "brew", &r, .blacklist)).?.path);
}

test "targetFor: with every repo file gated, a blacklist row goes to the ungated private file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "darwin");
    const r: Resolver = .{ .live = &.{ .bindings = &bindings } };

    const m: Manifest = .{ .sources = &.{
        gatedSource("data/packages/darwin.toml", "/r/darwin.toml", "brew", "os=darwin"),
        sourceOf("data/packages/local.toml", "/p/local.toml", "brew", true),
    } };
    // The package row still prefers the repo layer, whose gate holds here.
    try testing.expectEqualStrings("/r/darwin.toml", (try targetFor(a, m, "brew", &r, .packages)).?.path);
    // The blacklist row takes the private file: machine-local by construction,
    // which is narrower than the gate on the shared file and is the layer's
    // own meaning rather than a row inert everywhere else.
    try testing.expectEqualStrings("/p/local.toml", (try targetFor(a, m, "brew", &r, .blacklist)).?.path);

    // The gate itself is what is refused, in either layer.
    const gated_private: Manifest = .{ .sources = &.{
        gatedSource("data/packages/darwin.toml", "/r/darwin.toml", "brew", "os=darwin"),
        .{ .path = "/p/local.toml", .label = "data/packages/local.toml", .default_backend = "brew", .when = "os=darwin", .private = true },
    } };
    try testing.expect((try targetFor(a, gated_private, "brew", &r, .blacklist)) == null);
}

test "render: DEL is escaped, as a TOML basic string requires" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try render(a, .packages, .{ .name = "a\x7fb\x01c" }, null);
    try testing.expectEqualStrings("\n[[packages]]\nname = \"a\\u007fb\\u0001c\"\n", got);
}

test "append: adds a block and leaves every existing byte alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original =
        \\# a comment someone wrote
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "ripgrep"  # trailing note
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "p.toml", .data = original });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "p.toml" });

    try append(a, io, path, "", "\n[[packages]]\nname = \"htop\"\n");

    const after = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    try testing.expect(std.mem.startsWith(u8, after, original));
    try testing.expect(std.mem.indexOf(u8, after, "# a comment someone wrote") != null);
    try testing.expect(std.mem.indexOf(u8, after, "# trailing note") != null);
    try testing.expect(std.mem.endsWith(u8, after, "[[packages]]\nname = \"htop\"\n"));
}

test "append: a file not ending in a newline does not glue its last line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "p.toml", .data = "backend = \"brew\"" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "p.toml" });

    try append(a, io, path, "", "\n[[packages]]\nname = \"htop\"\n");

    const after = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    try testing.expectEqualStrings("backend = \"brew\"\n\n[[packages]]\nname = \"htop\"\n", after);
}

test "append: an existing file keeps its mode" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "p.toml", .data = "backend = \"brew\"\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "p.toml" });
    try Io.Dir.cwd().setFilePermissions(io, path, Io.File.Permissions.fromMode(0o600), .{});

    try append(a, io, path, "", "\n[[packages]]\nname = \"htop\"\n");

    const st = try Io.Dir.cwd().statFile(io, path, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, st.permissions.toMode() & 0o777));
}

test "append: a symlinked manifest is rewritten through the link, which survives" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "real");
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.writeFile(io, .{ .sub_path = "real/p.toml", .data = "backend = \"brew\"\n" });
    try tmp.dir.symLink(io, "../real/p.toml", "repo/mid.toml", .{});
    try tmp.dir.symLink(io, "mid.toml", "repo/p.toml", .{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const link = try std.fs.path.join(a, &.{ root, "repo", "p.toml" });
    const real = try std.fs.path.join(a, &.{ root, "real", "p.toml" });

    try append(a, io, link, "", "\n[[packages]]\nname = \"htop\"\n");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("mid.toml", buf[0..try Io.Dir.cwd().readLink(io, link, &buf)]);
    const after = try Io.Dir.cwd().readFileAlloc(io, real, a, .limited(1 << 20));
    try testing.expectEqualStrings("backend = \"brew\"\n\n[[packages]]\nname = \"htop\"\n", after);
}

test "append: each hop of a symlink chain resolves against its own directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "one");
    try tmp.dir.createDirPath(io, "two");
    try tmp.dir.writeFile(io, .{ .sub_path = "two/real.toml", .data = "backend = \"brew\"\n" });
    // The second hop's target is bare, so it names two/real.toml only when
    // it is read against two/, the directory holding the link that spells
    // it -- against one/, the first link's, it names a file that is not
    // there and the append creates that instead.
    try tmp.dir.symLink(io, "../two/mid.toml", "one/p.toml", .{});
    try tmp.dir.symLink(io, "real.toml", "two/mid.toml", .{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const link = try std.fs.path.join(a, &.{ root, "one", "p.toml" });
    const real = try std.fs.path.join(a, &.{ root, "two", "real.toml" });

    try append(a, io, link, "", "\n[[packages]]\nname = \"htop\"\n");

    const after = try Io.Dir.cwd().readFileAlloc(io, real, a, .limited(1 << 20));
    try testing.expectEqualStrings("backend = \"brew\"\n\n[[packages]]\nname = \"htop\"\n", after);
    const stray = try std.fs.path.join(a, &.{ root, "one", "real.toml" });
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, stray, .{}));
}

test "append: a symlink chain past the hop bound is refused by name" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(io, "l0", "l0", .{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const link = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "l0" });

    try testing.expectError(Error.TooManySymlinkHops, append(a, io, link, "", "\n[[packages]]\nname = \"htop\"\n"));
}

test "append: a missing file is created without a leading blank line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "new.toml" });

    try append(a, io, path, "", "\n[[packages]]\nname = \"htop\"\n");

    const after = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    try testing.expectEqualStrings("[[packages]]\nname = \"htop\"\n", after);
}

test "append: a manifest created because it had vanished is created 0644" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "new.toml" });

    try append(a, io, path, "backend = \"brew\"\n", "\n[[packages]]\nname = \"htop\"\n");

    const st = try Io.Dir.cwd().statFile(io, path, .{});
    try testing.expectEqual(@as(u32, 0o644), @as(u32, st.permissions.toMode() & 0o777));
}

test "append: a zero-length manifest takes the block with no leading blank line, and the row loads back" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    // A file the user made and left empty: `readFileAlloc` answers with no
    // bytes, and the last-byte look the append takes has none to read.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/darwin.toml", .data = "" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    const path = try std.fs.path.join(a, &.{ repo, "data", "packages", "darwin.toml" });

    try append(a, io, path, "", "\n[[packages]]\nbackend = \"brew\"\nname = \"htop\"\n");

    const after = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    try testing.expectEqualStrings("[[packages]]\nbackend = \"brew\"\nname = \"htop\"\n", after);

    const m = try manifest_mod.load(a, io, repo, "", null);
    try testing.expectEqual(@as(usize, 1), m.packages.len);
    try testing.expectEqualStrings("htop", m.packages[0].name);
}

test "append: a file that vanished comes back declaring what the block left out" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    const path = try std.fs.path.join(a, &.{ repo, "data", "packages", "darwin.toml" });

    // The file `load` saw declared the backend and a gate, so the block omits
    // both; it is gone by the time the row is written. Recreating it without
    // them would be a file `commit` wrote and `load` refuses.
    const src: Source = .{
        .path = path,
        .label = "data/packages/darwin.toml",
        .default_backend = "brew",
        .when = "os=darwin",
        .private = false,
    };
    const block = try render(a, .packages, .{ .name = "ghostty" }, null);
    try append(a, io, path, try renderHeader(a, src), block);

    const after = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    try testing.expectEqualStrings(
        "backend = \"brew\"\nwhen = \"os=darwin\"\n\n[[packages]]\nname = \"ghostty\"\n",
        after,
    );

    const m = try manifest_mod.load(a, io, repo, "", null);
    try testing.expectEqual(@as(usize, 1), m.packages.len);
    try testing.expectEqualStrings("brew", m.packages[0].backend);
    try testing.expectEqualStrings("os=darwin", m.packages[0].when.?);
}

test "append then load: the appended row parses back as written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/data/packages/darwin.toml",
        .data = "backend = \"brew\"\n",
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    const path = try std.fs.path.join(a, &.{ repo, "data", "packages", "darwin.toml" });

    const block = try render(a, .packages, .{
        .name = "ghostty",
        .fields = &.{.{ .key = "kind", .value = .{ .string = "cask" } }},
    }, null);
    try append(a, io, path, "", block);

    // The round trip that matters: what was written is what loads.
    const m = try manifest_mod.load(a, io, repo, "", null);
    try testing.expectEqual(@as(usize, 1), m.packages.len);
    try testing.expectEqualStrings("ghostty", m.packages[0].name);
    try testing.expectEqualStrings("brew", m.packages[0].backend);
    try testing.expectEqualStrings("cask", m.packages[0].field("kind").?.string);
}

/// One writer of `path`, run concurrently with the others by the two tests
/// below: the whole of what `mox commit` does to a manifest, repeated.
const Appender = struct {
    io: Io,
    path: []const u8,
    name: []const u8,
    rounds: usize,
    started: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *Appender) void {
        self.started.store(true, .release);
        var round: usize = 0;
        while (round < self.rounds) : (round += 1) {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const block = std.fmt.allocPrint(a, "\n[[packages]]\nname = \"{s}-{d}\"\n", .{ self.name, round }) catch {
                self.failed.store(true, .release);
                break;
            };
            append(a, self.io, self.path, "", block) catch {
                self.failed.store(true, .release);
                break;
            };
        }
        self.done.store(true, .release);
    }
};

fn seededManifest(a: std.mem.Allocator, io: Io, sub_path: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    const dir = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", sub_path, "data", "packages" });
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(a, &.{ dir, "shared.toml" });
    try apply_write.writeAtomic(io, path, "backend = \"brew\"\n", 0o644);
    return path;
}

fn countRows(content: []const u8) usize {
    var n: usize = 0;
    var rest = content;
    while (std.mem.indexOf(u8, rest, "[[packages]]")) |i| {
        n += 1;
        rest = rest[i + "[[packages]]".len ..];
    }
    return n;
}

test "append: a writer waits for whoever holds the manifest directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // a directory takes no lock there
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = try seededManifest(a, io, &tmp.sub_path);
    const held = try Io.Dir.cwd().openFile(io, std.fs.path.dirname(path).?, .{});
    defer held.close(io);
    try held.lock(io, .exclusive);

    var appender: Appender = .{ .io = io, .path = path, .name = "waiter", .rounds = 1 };
    var fut = io.concurrent(Appender.run, .{&appender}) catch |e| switch (e) {
        error.ConcurrencyUnavailable => {
            held.unlock(io);
            return error.SkipZigTest;
        },
    };
    while (!appender.started.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);

    // Longer than an append that took no lock would take, so that what is
    // measured is the lock and not the scheduler.
    var waited: usize = 0;
    while (waited < 500 and !appender.done.load(.acquire)) : (waited += 10) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    const waiting = !appender.done.load(.acquire);

    // The holder's own read-modify-write: the second process's half of the
    // race, whose row the waiter's rewrite must not drop.
    const existing = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    const merged = try std.fmt.allocPrint(a, "{s}\n[[packages]]\nname = \"holder\"\n", .{existing});
    try apply_write.writeAtomic(io, path, merged, 0o644);
    held.unlock(io);

    fut.await(io);
    const final = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    try testing.expect(waiting);
    try testing.expect(!appender.failed.load(.acquire));
    try testing.expect(std.mem.indexOf(u8, final, "\"holder\"") != null);
    try testing.expect(std.mem.indexOf(u8, final, "\"waiter-0\"") != null);
}

test "append: concurrent writers of one manifest lose no row" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // a directory takes no lock there
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = try seededManifest(a, io, &tmp.sub_path);
    const names = [_][]const u8{ "one", "two", "three", "four" };
    const rounds: usize = 15;

    var appenders: [names.len]Appender = undefined;
    var futs: [names.len]Io.Future(void) = undefined;
    var spawned: usize = 0;
    for (&appenders, names) |*ap, name| {
        ap.* = .{ .io = io, .path = path, .name = name, .rounds = rounds };
        futs[spawned] = io.concurrent(Appender.run, .{ap}) catch break;
        spawned += 1;
    }
    for (futs[0..spawned]) |*f| f.await(io);
    if (spawned < 2) return error.SkipZigTest;

    const final = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    for (appenders[0..spawned]) |*ap| try testing.expect(!ap.failed.load(.acquire));
    try testing.expectEqual(spawned * rounds, countRows(final));
    for (names[0..spawned]) |name| {
        var round: usize = 0;
        while (round < rounds) : (round += 1) {
            const row = try std.fmt.allocPrint(a, "name = \"{s}-{d}\"\n", .{ name, round });
            try testing.expect(std.mem.indexOf(u8, final, row) != null);
        }
    }
}

const EditFixture = struct {
    a: std.mem.Allocator,
    io: Io,
    root: []const u8,
    repo: []const u8,
    private: []const u8,

    fn init(a: std.mem.Allocator, io: Io, tmp: *std.testing.TmpDir) !EditFixture {
        try tmp.dir.createDirPath(io, "repo/data/packages");
        try tmp.dir.createDirPath(io, "private/data/packages");
        const cwd = try std.process.currentPathAlloc(io, a);
        const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
        return .{
            .a = a,
            .io = io,
            .root = root,
            .repo = try std.fs.path.join(a, &.{ root, "repo" }),
            .private = try std.fs.path.join(a, &.{ root, "private" }),
        };
    }

    fn pathOf(self: EditFixture, layer: []const u8, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.a, &.{ self.root, layer, "data", "packages", name });
    }

    fn put(self: EditFixture, name: []const u8, content: []const u8) !void {
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = try self.pathOf("repo", name), .data = content });
    }

    fn read(self: EditFixture, name: []const u8) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(self.io, try self.pathOf("repo", name), self.a, .limited(1 << 20));
    }

    fn load(self: EditFixture) !Manifest {
        return manifest_mod.load(self.a, self.io, self.repo, self.private, null);
    }

    /// The loaded row named `name`, as commit holds it when it asks.
    fn row(self: EditFixture, name: []const u8) !manifest_mod.Row {
        for ((try self.load()).packages) |r| if (std.mem.eql(u8, r.name, name)) return r;
        return error.TestUnexpectedResult;
    }
};

fn expectLeft(got: Edit, why: []const u8) !void {
    try testing.expect(got == .left);
    try testing.expect(std.mem.indexOf(u8, got.left, why) != null);
}

test "removeRow: the row's own lines go, comments between its keys included; comments above its header and after its last key stay" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try fx.put("darwin.toml",
        \\backend = "brew"
        \\
        \\# formulae
        \\[[packages]]
        \\name = "fd"
        \\
        \\# about ripgrep
        \\[[packages]]
        \\name = "ripgrep"
        \\# why it is pinned
        \\pin = true
        \\# after the last key
        \\
        \\[[packages]]
        \\name = "bat"
        \\
    );
    try testing.expectEqual(Edit.written, try removeRow(fx.a, io, try fx.row("ripgrep")));
    try testing.expectEqualStrings(
        \\backend = "brew"
        \\
        \\# formulae
        \\[[packages]]
        \\name = "fd"
        \\
        \\# about ripgrep
        \\# after the last key
        \\
        \\[[packages]]
        \\name = "bat"
        \\
    , try fx.read("darwin.toml"));
}

test "removeRow: two blank lines meeting where the row was collapse to one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try fx.put("darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"a\"\n\n[[packages]]\nname = \"b\"\n\n[[packages]]\nname = \"c\"\n");
    try testing.expectEqual(Edit.written, try removeRow(fx.a, io, try fx.row("b")));
    try testing.expectEqualStrings("backend = \"brew\"\n\n[[packages]]\nname = \"a\"\n\n[[packages]]\nname = \"c\"\n", try fx.read("darwin.toml"));
}

test "removeRow: a last row with no final newline goes, and what came before it stays byte for byte" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try fx.put("darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"a\"\n\n[[packages]]\nname = \"b\"");
    try testing.expectEqual(Edit.written, try removeRow(fx.a, io, try fx.row("b")));
    try testing.expectEqualStrings("backend = \"brew\"\n\n[[packages]]\nname = \"a\"\n\n", try fx.read("darwin.toml"));
}

test "removeRow: CRLF line endings are kept" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try fx.put("darwin.toml", "backend = \"brew\"\r\n\r\n[[packages]]\r\nname = \"a\"\r\n\r\n[[packages]]\r\nname = \"b\"\r\n");
    try testing.expectEqual(Edit.written, try removeRow(fx.a, io, try fx.row("a")));
    try testing.expectEqualStrings("backend = \"brew\"\r\n\r\n[[packages]]\r\nname = \"b\"\r\n", try fx.read("darwin.toml"));
}

test "removeRow and setWhen: a [[blacklist]] row between package rows is left alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try fx.put("darwin.toml",
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "a"
        \\
        \\[[blacklist]]
        \\name = "usage"
        \\
        \\[[packages]]
        \\name = "b"
        \\
    );
    try testing.expectEqual(Edit.written, try removeRow(fx.a, io, try fx.row("a")));
    try testing.expectEqual(Edit.written, try setWhen(fx.a, io, try fx.row("b"), "work"));
    try testing.expectEqualStrings(
        \\backend = "brew"
        \\
        \\[[blacklist]]
        \\name = "usage"
        \\
        \\[[packages]]
        \\name = "b"
        \\when = "not machine=\"work\""
        \\
    , try fx.read("darwin.toml"));
    const m = try fx.load();
    try testing.expectEqual(@as(usize, 1), m.blacklist.len);
    try testing.expectEqualStrings("not machine=\"work\"", m.packages[0].when.?);
}

test "removeRow: two removals from one file, each from the rows as first loaded" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try fx.put("darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"a\"\n\n[[packages]]\nname = \"b\"\n\n[[packages]]\nname = \"c\"\n");
    const a_row = try fx.row("a");
    const c_row = try fx.row("c");
    try testing.expectEqual(Edit.written, try removeRow(fx.a, io, a_row));
    try testing.expectEqual(Edit.written, try removeRow(fx.a, io, c_row));
    try testing.expectEqualStrings("backend = \"brew\"\n\n[[packages]]\nname = \"b\"\n\n", try fx.read("darwin.toml"));
}

test "removeRow: a file edited after the row was reported is searched by content, and a row that changed is left" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try fx.put("darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"a\"\n\n[[packages]]\nname = \"b\"\n");
    const b_row = try fx.row("b");
    const a_row = try fx.row("a");
    // Someone adds a row ahead of both and gives a another field, between
    // the prompt that reported them and the answers.
    try fx.put("darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"new\"\n\n[[packages]]\nname = \"a\"\npin = true\n\n[[packages]]\nname = \"b\"\n");

    try testing.expectEqual(Edit.written, try removeRow(fx.a, io, b_row));
    try expectLeft(try removeRow(fx.a, io, a_row), "no row in it is the one reported any more");
    try testing.expectEqualStrings("backend = \"brew\"\n\n[[packages]]\nname = \"new\"\n\n[[packages]]\nname = \"a\"\npin = true\n\n", try fx.read("darwin.toml"));
}

test "removeRow: a symlinked manifest is edited where the link points, and the link survives" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try tmp.dir.createDirPath(io, "real");
    try tmp.dir.writeFile(io, .{ .sub_path = "real/darwin.toml", .data = "backend = \"brew\"\n\n[[packages]]\nname = \"a\"\n\n[[packages]]\nname = \"b\"\n" });
    try tmp.dir.symLink(io, "../../../real/darwin.toml", "repo/data/packages/darwin.toml", .{});

    try testing.expectEqual(Edit.written, try removeRow(fx.a, io, try fx.row("a")));
    const link = try fx.pathOf("repo", "darwin.toml");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("../../../real/darwin.toml", buf[0..try Io.Dir.cwd().readLink(io, link, &buf)]);
    const real = try std.fs.path.join(fx.a, &.{ fx.root, "real", "darwin.toml" });
    try testing.expectEqualStrings("backend = \"brew\"\n\n[[packages]]\nname = \"b\"\n", try Io.Dir.cwd().readFileAlloc(io, real, fx.a, .limited(1 << 20)));
}

test "removeRow and setWhen: a file in the private layer is edited there" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    const path = try fx.pathOf("private", "local.toml");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "backend = \"brew\"\n\n[[packages]]\nname = \"a\"\n\n[[packages]]\nname = \"b\"\n" });
    const a_row = try fx.row("a");
    try testing.expectEqualStrings("data/packages/local.toml (private layer)", a_row.label);
    try testing.expectEqual(Edit.written, try removeRow(fx.a, io, a_row));
    try testing.expectEqual(Edit.written, try setWhen(fx.a, io, try fx.row("b"), "work"));
    try testing.expectEqualStrings(
        "backend = \"brew\"\n\n[[packages]]\nname = \"b\"\nwhen = \"not machine=\\\"work\\\"\"\n",
        try Io.Dir.cwd().readFileAlloc(io, path, fx.a, .limited(1 << 20)),
    );
}

test "removeRow and setWhen: rows written inline are refused, to be edited by hand" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    const original = "backend = \"brew\"\npackages = [{ name = \"a\" }, { name = \"b\" }]\n";
    try fx.put("darwin.toml", original);
    try expectLeft(try removeRow(fx.a, io, try fx.row("a")), "written inline");
    try expectLeft(try setWhen(fx.a, io, try fx.row("b"), "work"), "edit it by hand");
    try testing.expectEqualStrings(original, try fx.read("darwin.toml"));
}

test "setWhen: a row without a when gains one directly after its name line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try fx.put("darwin.toml", "backend = \"brew\"\n\n[[packages]]\n# the terminal\nname = \"ghostty\"\nkind = \"cask\"\n");
    try testing.expectEqual(Edit.written, try setWhen(fx.a, io, try fx.row("ghostty"), "work"));
    try testing.expectEqualStrings(
        "backend = \"brew\"\n\n[[packages]]\n# the terminal\nname = \"ghostty\"\nwhen = \"not machine=\\\"work\\\"\"\nkind = \"cask\"\n",
        try fx.read("darwin.toml"),
    );
}

test "setWhen: a when there already is wrapped in place, keeping its trailing comment" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try fx.put("darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"a\"\nwhen = \"os=darwin\"  # laptops only\npin = true\n");
    try testing.expectEqual(Edit.written, try setWhen(fx.a, io, try fx.row("a"), "work"));
    try testing.expectEqualStrings(
        "backend = \"brew\"\n\n[[packages]]\nname = \"a\"\nwhen = \"(os=darwin) and not machine=\\\"work\\\"\"  # laptops only\npin = true\n",
        try fx.read("darwin.toml"),
    );
    try testing.expectEqualStrings("(os=darwin) and not machine=\"work\"", (try fx.row("a")).when.?);
}

test "setWhen: a name line that ends the file gets its newline first, and the file still ends without one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try fx.put("darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"a\"");
    try testing.expectEqual(Edit.written, try setWhen(fx.a, io, try fx.row("a"), "work"));
    try testing.expectEqualStrings("backend = \"brew\"\n\n[[packages]]\nname = \"a\"\nwhen = \"not machine=\\\"work\\\"\"", try fx.read("darwin.toml"));
}

test "setWhen: CRLF line endings are kept, the new line taking the name line's" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try fx.put("darwin.toml", "backend = \"brew\"\r\n\r\n[[packages]]\r\nname = \"a\"\r\npin = true\r\n");
    try testing.expectEqual(Edit.written, try setWhen(fx.a, io, try fx.row("a"), "work"));
    try testing.expectEqualStrings("backend = \"brew\"\r\n\r\n[[packages]]\r\nname = \"a\"\r\nwhen = \"not machine=\\\"work\\\"\"\r\npin = true\r\n", try fx.read("darwin.toml"));
}

test "setWhen: under a file-level when the row's own when is written, and the merged gate is the two combined" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try fx.put("darwin.toml", "backend = \"brew\"\nwhen = \"os=darwin\"\n\n[[packages]]\nname = \"a\"\n");
    try testing.expectEqual(Edit.written, try setWhen(fx.a, io, try fx.row("a"), "work"));
    try testing.expectEqualStrings("backend = \"brew\"\nwhen = \"os=darwin\"\n\n[[packages]]\nname = \"a\"\nwhen = \"not machine=\\\"work\\\"\"\n", try fx.read("darwin.toml"));
    const want = (try manifest_mod.combineWhen(fx.a, "os=darwin", "not machine=\"work\"")).?;
    try testing.expectEqualStrings(want, (try fx.row("a")).when.?);
    try testing.expectEqualStrings("os=darwin", (try fx.load()).sources[0].when.?);
}

test "setWhen: a when written as a multi-line or literal string is refused, to be edited by hand" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    for ([_][]const u8{
        "backend = \"brew\"\n\n[[packages]]\nname = \"a\"\nwhen = \"\"\"\nos=darwin\"\"\"\n",
        "backend = \"brew\"\n\n[[packages]]\nname = \"a\"\nwhen = 'os=darwin'\n",
    }) |original| {
        try fx.put("darwin.toml", original);
        try expectLeft(try setWhen(fx.a, io, try fx.row("a"), "work"), "multi-line or literal string");
        try testing.expectEqualStrings(original, try fx.read("darwin.toml"));
    }
}

test "setWhen: a machine name outside ASCII is written quoted, and gates as written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fx = try EditFixture.init(arena.allocator(), io, &tmp);

    try fx.put("darwin.toml", "backend = \"brew\"\n\n[[packages]]\nname = \"a\"\n");
    try testing.expectEqual(Edit.written, try setWhen(fx.a, io, try fx.row("a"), "caf\xc3\xa9"));
    try testing.expectEqualStrings("backend = \"brew\"\n\n[[packages]]\nname = \"a\"\nwhen = \"not machine=\\\"caf\xc3\xa9\\\"\"\n", try fx.read("darwin.toml"));
    const when = (try fx.row("a")).when.?;
    try testing.expectEqualStrings("not machine=\"caf\xc3\xa9\"", when);

    var here = std.StringHashMap([]const u8).init(fx.a);
    try here.put("machine", "caf\xc3\xa9");
    const r: Resolver = .{ .live = &.{ .bindings = &here } };
    try testing.expect(!axis.evaluate(try axis.parseString(fx.a, when), &r));
}

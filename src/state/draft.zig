//! A run's draft: the loaded generation, every change the run makes to it,
//! and the commit that makes them the new current generation.
//!
//! Judgment code reads the draft, so a run sees its own changes. Each change
//! is journalled as it is made; the journal is claimed at the first one.

const std = @import("std");
const Io = std.Io;
const json = @import("json");
const applied = @import("../apply/applied.zig");
const prov_map = @import("../provenance/map.zig");
const source_path = @import("../source/path.zig");
const generation = @import("generation.zig");
const blob = @import("blob.zig");
const journal = @import("journal.zig");
const id_mod = @import("id.zig");
const durable = @import("durable.zig");
const lock = @import("lock.zig");
const write_mod = @import("../apply/write.zig");

const Generation = generation.Generation;
pub const Hex = generation.Hex;
const PathEntry = generation.PathEntry;

/// Where the store keeps everything, under `<state>/v2/`.
/// The directory under the state directory that holds the store.
pub const store_dir_name = "v2";

pub const Store = struct {
    state_dir: []const u8,
    v2: []const u8,
    gen: []const u8,
    blobs: []const u8,
    pending: []const u8,
    quarantine: []const u8,
    trash: []const u8,
    current: []const u8,

    pub fn init(arena: std.mem.Allocator, state_dir: []const u8) !Store {
        const v2 = try std.fs.path.join(arena, &.{ state_dir, store_dir_name });
        return .{
            .state_dir = state_dir,
            .v2 = v2,
            .gen = try std.fs.path.join(arena, &.{ v2, "gen" }),
            .blobs = try std.fs.path.join(arena, &.{ v2, "blobs" }),
            .pending = try std.fs.path.join(arena, &.{ v2, "pending" }),
            .quarantine = try std.fs.path.join(arena, &.{ v2, "quarantine" }),
            .trash = try std.fs.path.join(arena, &.{ state_dir, "trash" }),
            .current = try std.fs.path.join(arena, &.{ v2, "current" }),
        };
    }

    pub fn genPath(s: Store, arena: std.mem.Allocator, id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}{c}{s}.json", .{ s.gen, std.fs.path.sep, id });
    }

    pub fn journalPath(s: Store, arena: std.mem.Allocator, id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}{c}{s}.jsonl", .{ s.pending, std.fs.path.sep, id });
    }

    pub fn idDirs(s: Store) id_mod.Dirs {
        return .{ .gen = s.gen, .pending = s.pending, .quarantine = s.quarantine, .trash = s.trash };
    }
};

/// The part a repo and HOME make: the hash of `repo NUL home`, each its real
/// path where it resolves.
pub fn partOf(arena: std.mem.Allocator, io: Io, repo_dir: []const u8, home: []const u8) !struct { hex: Hex, info: generation.PartInfo } {
    const tag = try applied.repoTag(arena, io, repo_dir, home);
    const nul = std.mem.indexOfScalar(u8, tag, 0).?;
    return .{ .hex = applied.contentHashHex(tag), .info = .{ .repo = tag[0..nul], .home = tag[nul + 1 ..] } };
}

pub const Error = error{ ReadOnlyState, StateExhausted };

pub const Draft = struct {
    arena: std.mem.Allocator,
    io: Io,
    store: Store,
    writable: bool,
    gen: Generation,
    /// The bytes of `current` when the draft was loaded; empty when absent.
    base: []const u8,
    /// The generation actually loaded.
    loaded: ?[]const u8,
    run_kind: generation.Kind,
    undoes: ?[]const u8 = null,
    part: Hex,
    part_info: generation.PartInfo,
    /// The run notes that this part expects a private layer.
    note_private: bool = false,
    /// Every generation whose chain fell back, or no generation could be
    /// read: writes refuse.
    exhausted: bool = false,
    jnl: ?journal.Journal = null,
    /// Generations recovery folded in memory only, with writes off.
    unwritten: []const Generation = &.{},
    run_id: ?[]const u8 = null,
    changed: bool = false,
    committed: bool = false,
    /// A reader re-read `current` after finding a blob gone.
    reread: bool = false,

    // Reads.

    pub fn entry(d: *const Draft, live: []const u8) ?PathEntry {
        return d.gen.paths.get(live);
    }

    pub fn fileRecord(d: *const Draft, live: []const u8) ?generation.FileRec {
        return (d.entry(live) orelse return null).file;
    }

    fn ownedRec(d: *const Draft, live: []const u8) ?generation.OwnedRec {
        return (d.entry(live) orelse return null).owned;
    }

    fn linkRec(d: *const Draft, live: []const u8) ?generation.LinkRec {
        return (d.entry(live) orelse return null).link;
    }

    /// The content hash of the whole file mox last wrote at `live`.
    pub fn read(d: *const Draft, live: []const u8) ?Hex {
        return (d.fileRecord(live) orelse return null).sha256;
    }

    /// The last-applied content cached for `live`.
    pub fn readContent(d: *Draft, live: []const u8) !?[]const u8 {
        const f = d.fileRecord(live) orelse return null;
        const h = f.cache_blob orelse return null;
        if (try blob.get(d.arena, d.io, d.store.blobs, h)) |bytes| return bytes;
        if (try d.reloadOnce()) return d.readContent(live);
        return null;
    }

    /// For a reader that found a blob gone: when `current` moved since the
    /// load, a commit may have collected it, so load `current` again, once.
    fn reloadOnce(d: *Draft) !bool {
        if (d.writable or d.reread) return false;
        d.reread = true;
        const recovery = @import("recovery.zig");
        if (std.mem.eql(u8, try recovery.readCurrent(d.arena, d.io, d.store), d.base)) return false;
        var report: recovery.Report = .{};
        const start = try recovery.loadCurrent(d.arena, d.io, d.store, &report);
        if (report.newer != null or report.exhausted) return false;
        const at = try recovery.recover(d.arena, d.io, d.store, start, .{ .writes = false, .unlocked = true }, &report);
        var gen: Generation = if (at.gen) |g| try g.clone(d.arena) else .{ .id = "", .kind = d.run_kind, .run_kind = d.run_kind };
        gen.displaced = .empty;
        d.gen = gen;
        d.base = at.base;
        d.loaded = if (at.gen) |g| g.id else null;
        d.unwritten = report.unwritten.items;
        return true;
    }

    pub fn readOwned(d: *const Draft, live: []const u8) !?applied.OwnedRecord {
        const o = d.ownedRec(live) orelse return null;
        var canonical: ?[]const u8 = null;
        if (!o.secret) canonical = (try blob.get(d.arena, d.io, d.store.blobs, o.canonical_blob orelse return null)) orelse return null;
        return .{
            .mode = o.mode,
            .canonical = canonical,
            .canonical_hash = o.canonical_sha256,
            .secret = o.secret,
            .own_paths = o.own_paths,
            .secret_paths = o.secret_paths,
            .live_path = live,
        };
    }

    /// The symlink record for `live`, rolled back or not.
    pub fn readSymlinkRecord(d: *const Draft, live: []const u8) ?applied.SymlinkRecord {
        const e = d.entry(live) orelse return null;
        const l = d.linkRec(live) orelse return null;
        return .{ .target = l.target, .rolled_back = l.rolled_back, .part = e.part };
    }

    /// The target mox last applied at `live`; a link rollback put back is not
    /// one it applied.
    pub fn readSymlink(d: *const Draft, live: []const u8) ?[]const u8 {
        const r = d.readSymlinkRecord(live) orelse return null;
        return if (r.rolled_back) null else r.target;
    }

    /// The target of the symlink at `live` when mox planted it.
    pub fn plantedLink(d: *const Draft, live: []const u8) !?[]const u8 {
        const recorded = d.readSymlink(live) orelse return null;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().readLink(d.io, live, &buf) catch return null;
        if (!applied.sameSymlinkTarget(buf[0..n], recorded)) return null;
        return try d.arena.dupe(u8, buf[0..n]);
    }

    /// The target of the symlink at `live` when it is one mox planted that
    /// rollback put back.
    pub fn rolledBackLink(d: *const Draft, live: []const u8) !?[]const u8 {
        const rec = d.readSymlinkRecord(live) orelse return null;
        if (!rec.rolled_back) return null;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().readLink(d.io, live, &buf) catch return null;
        if (!applied.sameSymlinkTarget(buf[0..n], rec.target)) return null;
        return try d.arena.dupe(u8, buf[0..n]);
    }

    /// The provenance blob kept for `live`: its file record's, else residue.
    pub fn provenanceBlob(d: *const Draft, live: []const u8) ?Hex {
        if (d.fileRecord(live)) |f| if (f.provenance_blob) |h| return h;
        return d.gen.residue.get(live);
    }

    /// The provenance kept for `live`, or null when none or malformed.
    pub fn provenance(d: *Draft, live: []const u8) !?prov_map.Map {
        const h = d.provenanceBlob(live) orelse return null;
        const bytes = (try blob.get(d.arena, d.io, d.store.blobs, h)) orelse {
            if (try d.reloadOnce()) return d.provenance(live);
            return null;
        };
        return prov_map.deserialize(d.arena, bytes) catch null;
    }

    /// The generator at `gen_live`'s produced set.
    pub fn produced(d: *const Draft, gen_live: []const u8) []const []const u8 {
        const g = d.generator(gen_live) orelse return &.{};
        return g.produced;
    }

    pub fn generator(d: *const Draft, gen_live: []const u8) ?generation.GeneratorEntry {
        return d.gen.generators.get(gen_live);
    }

    /// Every produced file of every generator, whatever part.
    pub fn allLeaves(d: *const Draft) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (d.gen.generators.values()) |g| try out.appendSlice(d.arena, g.produced);
        return out.items;
    }

    pub fn expectsPrivate(d: *const Draft) bool {
        const f = d.gen.flags.get(&d.part) orelse return false;
        return f.expects_private;
    }

    /// True when an apply of this part has seen the tombstone `folded`.
    pub fn tombstoneSeen(d: *const Draft, folded: []const u8) bool {
        const f = d.gen.flags.get(&d.part) orelse return false;
        for (f.tombstones_seen) |t| if (std.mem.eql(u8, t, folded)) return true;
        return false;
    }

    // Changes.

    /// Claim the run's id and its journal, if not done yet.
    pub fn claim(d: *Draft) ![]const u8 {
        if (d.run_id) |i| return i;
        if (!d.writable) return error.ReadOnlyState;
        if (d.exhausted) return error.StateExhausted;
        try durable.makeDir(d.io, d.store.v2);
        const new_id = try id_mod.claim(d.arena, d.io, d.store.idDirs(), .journal);
        const path = try d.store.journalPath(d.arena, new_id);
        d.jnl = try journal.begin(d.arena, d.io, path, .{
            .holder = try lock.holderStamp(d.arena, d.io, lock.selfPid()),
            .base = d.base,
            .run_kind = d.run_kind,
            .undoes = d.undoes,
            .part = d.part,
            .part_info = d.part_info,
            .expects_private = d.note_private,
        });
        d.run_id = new_id;
        if (d.note_private) d.changed = true;
        return new_id;
    }

    fn log(d: *Draft, map: journal.MapName, key: []const u8, value: ?json.Value, sync: bool) !void {
        _ = try d.claim();
        try journal.append(d.arena, d.io, d.jnl.?, .{ .map = map, .key = key, .value = value }, sync);
        d.changed = true;
    }

    fn same(arena: std.mem.Allocator, a: json.Value, b: json.Value) bool {
        var x: Io.Writer.Allocating = .init(arena);
        var y: Io.Writer.Allocating = .init(arena);
        json.encode(&x.writer, a, .{ .sort_keys = true }) catch return false;
        json.encode(&y.writer, b, .{ .sort_keys = true }) catch return false;
        return std.mem.eql(u8, x.written(), y.written());
    }

    pub fn setPath(d: *Draft, key: []const u8, e: PathEntry) !void {
        const v = try generation.pathEntryValue(d.arena, e);
        if (d.gen.paths.get(key)) |old| if (same(d.arena, try generation.pathEntryValue(d.arena, old), v)) return;
        try d.log(.paths, key, v, false);
        try d.gen.paths.put(d.arena, key, e);
    }

    fn deletePath(d: *Draft, key: []const u8) !void {
        if (!d.gen.paths.contains(key)) return;
        try d.log(.paths, key, null, false);
        _ = d.gen.paths.orderedRemove(key);
    }

    fn setResidue(d: *Draft, live: []const u8, h: Hex) !void {
        if (d.gen.residue.get(live)) |old| if (std.mem.eql(u8, &old, &h)) return;
        try d.log(.residue, live, .{ .string = try d.arena.dupe(u8, &h) }, false);
        try d.gen.residue.put(d.arena, live, h);
    }

    fn clearResidue(d: *Draft, live: []const u8) !void {
        if (!d.gen.residue.contains(live)) return;
        try d.log(.residue, live, null, false);
        _ = d.gen.residue.orderedRemove(live);
    }

    fn setGenerator(d: *Draft, key: []const u8, g: generation.GeneratorEntry) !void {
        const v = try generation.generatorValue(d.arena, g);
        if (d.gen.generators.get(key)) |old| if (same(d.arena, try generation.generatorValue(d.arena, old), v)) return;
        try d.log(.generators, key, v, false);
        try d.gen.generators.put(d.arena, key, g);
    }

    fn deleteGenerator(d: *Draft, key: []const u8) !void {
        if (!d.gen.generators.contains(key)) return;
        try d.log(.generators, key, null, false);
        _ = d.gen.generators.orderedRemove(key);
    }

    fn setFlags(d: *Draft, f: generation.Flags) !void {
        const v = try generation.flagsValue(d.arena, f);
        if (d.gen.flags.get(&d.part)) |old| if (same(d.arena, try generation.flagsValue(d.arena, old), v)) return;
        const key = try d.arena.dupe(u8, &d.part);
        try d.log(.flags, key, v, false);
        try d.gen.flags.put(d.arena, key, f);
    }

    /// A file record's provenance moves to residue as the record goes.
    fn keepProvenance(d: *Draft, live: []const u8, f: ?generation.FileRec) !void {
        const rec = f orelse return;
        if (rec.provenance_blob) |h| try d.setResidue(live, h);
    }

    /// Record `content` as the bytes mox just wrote to `live`, from the
    /// source keyed `source_key`. The content cache is set apart.
    pub fn record(d: *Draft, live: []const u8, content: []const u8, source_key: ?[]const u8) !void {
        if (std.mem.indexOfScalar(u8, live, '\n') != null) return error.NewlineInLivePath;
        const keep_prov = if (d.fileRecord(live)) |f| f.provenance_blob else null;
        try d.setPath(live, .{
            .part = d.part,
            .source_key = source_key,
            .kind = .file,
            .file = .{ .sha256 = applied.contentHashHex(content), .provenance_blob = keep_prov },
        });
    }

    /// Keep the exact composed bytes mox wrote to `live` for commit's diff.
    pub fn recordContent(d: *Draft, live: []const u8, content: []const u8) !void {
        var e = d.entry(live) orelse return;
        if (e.kind != .file) return;
        e.file.?.cache_blob = try blob.put(d.arena, d.io, d.store.blobs, content);
        try d.setPath(live, e);
    }

    /// Keep `segments` as where each line of `live` came from.
    pub fn persistProvenance(d: *Draft, live: []const u8, segments: []const prov_map.Segment) !void {
        const h = try blob.put(d.arena, d.io, d.store.blobs, try prov_map.serialize(d.arena, live, segments));
        try d.persistProvenanceBlob(live, h);
    }

    pub fn persistProvenanceBlob(d: *Draft, live: []const u8, h: Hex) !void {
        if (d.entry(live)) |found| if (found.kind == .file) {
            var e = found;
            e.file.?.provenance_blob = h;
            try d.setPath(live, e);
            try d.clearResidue(live);
            return;
        };
        try d.clearResidue(live);
        try d.setResidue(live, h);
    }

    /// Re-record the provenance and content cache of `live`'s file record.
    /// A secret-bearing composition keeps no cache.
    pub fn rebuildFile(d: *Draft, live: []const u8, content: []const u8, segments: []const prov_map.Segment, secret: bool) !void {
        var e = d.entry(live) orelse return;
        if (e.kind != .file) return;
        e.file.?.cache_blob = if (secret) null else try blob.put(d.arena, d.io, d.store.blobs, content);
        e.file.?.provenance_blob = try blob.put(d.arena, d.io, d.store.blobs, try prov_map.serialize(d.arena, live, segments));
        try d.setPath(live, e);
        try d.clearResidue(live);
    }

    /// Forget every record, residue, generator and flag.
    pub fn forgetEverything(d: *Draft) !void {
        for (try d.arena.dupe([]const u8, d.gen.paths.keys())) |k| try d.deletePath(k);
        for (try d.arena.dupe([]const u8, d.gen.residue.keys())) |k| {
            try d.log(.residue, k, null, false);
            _ = d.gen.residue.orderedRemove(k);
        }
        for (try d.arena.dupe([]const u8, d.gen.generators.keys())) |k| try d.deleteGenerator(k);
        for (try d.arena.dupe([]const u8, d.gen.flags.keys())) |k| {
            try d.log(.flags, k, null, false);
            _ = d.gen.flags.orderedRemove(k);
        }
    }

    /// Commit a generation even when nothing changed: `doctor --fix` starting
    /// over from an empty state.
    pub fn forceCommit(d: *Draft) !void {
        _ = try d.claim();
        d.changed = true;
    }

    pub fn recordOwned(d: *Draft, live: []const u8, rec: applied.OwnedRecord, source_key: ?[]const u8) !void {
        try d.keepProvenance(live, d.fileRecord(live));
        var o: generation.OwnedRec = .{ .mode = rec.mode, .secret = rec.secret, .own_paths = rec.own_paths, .secret_paths = rec.secret_paths };
        if (rec.secret) {
            o.canonical_sha256 = rec.canonical_hash orelse return error.MissingCanonicalHash;
        } else {
            o.canonical_blob = try blob.put(d.arena, d.io, d.store.blobs, rec.canonical orelse return error.MissingCanonical);
        }
        try d.setPath(live, .{ .part = d.part, .source_key = source_key, .kind = .owned, .owned = o });
    }

    pub fn recordSymlink(d: *Draft, live: []const u8, target: []const u8, source_key: ?[]const u8) !void {
        return d.writeLink(live, target, false, d.part, source_key, false);
    }

    /// Record that rollback put back, at `live`, a link to `target` mox had
    /// planted, under the part its planting named. Drift until applied again.
    pub fn recordRolledBackLink(d: *Draft, live: []const u8, target: []const u8, part: Hex) !void {
        return d.writeLink(live, target, true, part, null, true);
    }

    fn writeLink(d: *Draft, live: []const u8, target: []const u8, rolled_back: bool, part: Hex, source_key: ?[]const u8, keep_key: bool) !void {
        if (std.mem.indexOfScalar(u8, live, '\n') != null) return error.NewlineInLivePath;
        try d.keepProvenance(live, d.fileRecord(live));
        try d.setPath(live, .{
            .part = part,
            .source_key = if (keep_key) (if (d.entry(live)) |e| e.source_key else null) else source_key,
            .kind = .link,
            .link = .{ .target = target, .rolled_back = rolled_back },
        });
    }

    /// Drop the record of `live`; its provenance moves to residue.
    pub fn forget(d: *Draft, live: []const u8) !void {
        if (d.entry(live) == null) return;
        try d.keepProvenance(live, d.fileRecord(live));
        try d.deletePath(live);
    }

    pub fn forgetSymlink(d: *Draft, live: []const u8) !void {
        return d.forgetKind(live, .link);
    }

    pub fn forgetOwned(d: *Draft, live: []const u8) !void {
        return d.forgetKind(live, .owned);
    }

    /// Drop the whole-file record of `live`; its provenance moves to residue.
    pub fn forgetWholeFile(d: *Draft, live: []const u8) !void {
        return d.forgetKind(live, .file);
    }

    /// Drop the record of `live` when it is of `kind`.
    fn forgetKind(d: *Draft, live: []const u8, kind: generation.RecordKind) !void {
        const e = d.entry(live) orelse return;
        if (e.kind == kind) try d.forget(live);
    }

    /// Forget the provenance of `live`, wherever it is kept.
    pub fn forgetProvenance(d: *Draft, live: []const u8) !void {
        try d.clearResidue(live);
        if (d.entry(live)) |found| if (found.kind == .file and found.file.?.provenance_blob != null) {
            var e = found;
            e.file.?.provenance_blob = null;
            try d.setPath(live, e);
        };
    }

    /// Record `leaves` as the generator at `gen_live`'s produced set.
    pub fn setProduced(d: *Draft, gen_live: []const u8, leaves: []const []const u8, source_key: ?[]const u8) !void {
        try d.setGenerator(gen_live, .{ .part = d.part, .source_key = source_key, .produced = leaves });
    }

    /// Drop the generator stored under `key`, its produced set and all.
    pub fn dropGenerator(d: *Draft, key: []const u8) !void {
        return d.deleteGenerator(key);
    }

    /// Drop the generator at `gen_live`.
    pub fn forgetGenerator(d: *Draft, gen_live: []const u8) !void {
        return d.deleteGenerator(gen_live);
    }

    /// Drop `leaf` from the produced set of the generator stored under
    /// `key`, and the generator when nothing is left in it.
    pub fn dropLeaf(d: *Draft, key: []const u8, leaf: []const u8) !void {
        var g = d.gen.generators.get(key) orelse return;
        var kept: std.ArrayList([]const u8) = .empty;
        for (g.produced) |l| if (!std.mem.eql(u8, l, leaf)) try kept.append(d.arena, l);
        if (kept.items.len == 0) return d.deleteGenerator(key);
        g.produced = kept.items;
        try d.setGenerator(key, g);
    }

    /// Note that an apply of this part has seen every tombstone in
    /// `released`.
    pub fn markTombstones(d: *Draft, released: []const []const u8, fold: *const fn (std.mem.Allocator, []const u8) anyerror![]const u8) !void {
        var f = d.gen.flags.get(&d.part) orelse generation.Flags{};
        var seen: std.ArrayList([]const u8) = .empty;
        try seen.appendSlice(d.arena, f.tombstones_seen);
        for (released) |p| {
            const folded = try fold(d.arena, p);
            if (!contains(seen.items, folded)) try seen.append(d.arena, folded);
        }
        std.mem.sort([]const u8, seen.items, {}, lessStr);
        f.tombstones_seen = seen.items;
        try d.setFlags(f);
    }

    /// Note that this part expects a private layer; recorded in the journal's
    /// header, which this claims.
    pub fn notePrivate(d: *Draft) !void {
        if (d.expectsPrivate()) return;
        d.note_private = true;
        var f = d.gen.flags.get(&d.part) orelse generation.Flags{};
        f.expects_private = true;
        if (d.jnl != null) return d.setFlags(f);
        try d.gen.flags.put(d.arena, try d.arena.dupe(u8, &d.part), f);
        _ = try d.claim();
    }

    /// Stop expecting a private layer for this part: true when there was an
    /// expectation.
    pub fn retirePrivate(d: *Draft) !bool {
        var f = d.gen.flags.get(&d.part) orelse return false;
        if (!f.expects_private) return false;
        f.expects_private = false;
        try d.setFlags(f);
        return true;
    }

    // Displaced content.

    fn setDisplaced(d: *Draft, key: []const u8, entry_in: generation.Displaced) !void {
        var e = entry_in;
        if (d.gen.displaced.get(key)) |old| {
            if (e.planted == null) e.planted = old.planted;
            // A tree's members follow its directory: on their own when it is
            // replaced by something else, into the enclosing tree when a
            // later save captures it as a member.
            if (old.type == .dir and old.root == null) {
                if (e.type != .dir) {
                    try d.rerootMembers(key, null);
                } else if (e.root) |r| try d.rerootMembers(key, r);
            }
        }
        const v = try generation.flatDisplacedValue(d.arena, e);
        try d.log(.displaced, key, v, true);
        try d.gen.displaced.put(d.arena, key, e);
    }

    fn rerootMembers(d: *Draft, from: []const u8, to: ?[]const u8) !void {
        for (d.gen.displaced.keys(), d.gen.displaced.values()) |k, *m| {
            const r = m.root orelse continue;
            if (!std.mem.eql(u8, r, from)) continue;
            m.root = to;
            try d.log(.displaced, k, try generation.flatDisplacedValue(d.arena, m.*), true);
        }
    }

    fn displacedKey(d: *Draft, home: []const u8, live: []const u8) ![]const u8 {
        return (try source_path.liveKeyUnderHome(d.arena, home, live)) orelse error.LiveFileOutsideHome;
    }

    /// Keep `content`, what `live` holds now, before the run replaces it.
    pub fn save(d: *Draft, home: []const u8, live: []const u8, content: []const u8) !void {
        const key = try d.displacedKey(home, live);
        const st = try Io.Dir.cwd().statFile(d.io, live, .{});
        const h = try blob.put(d.arena, d.io, d.store.blobs, content);
        try d.setDisplaced(key, .{ .type = .file, .blob = h, .mode = write_mod.modeOf(st.permissions) });
    }

    /// `save` for `content` with the mode a re-patch keeps.
    pub fn saveWithMode(d: *Draft, home: []const u8, live: []const u8, content: []const u8, mode: u32) !void {
        const key = try d.displacedKey(home, live);
        const h = try blob.put(d.arena, d.io, d.store.blobs, content);
        try d.setDisplaced(key, .{ .type = .file, .blob = h, .mode = mode });
    }

    /// Keep the symlink at `live`, a link to `target`.
    pub fn saveSymlink(d: *Draft, home: []const u8, live: []const u8, target: []const u8) !void {
        const key = try d.displacedKey(home, live);
        try d.setDisplaced(key, .{ .type = .link, .target = target });
    }

    /// Note that the link kept for `live` is one mox planted, at `target`.
    pub fn notePlanted(d: *Draft, home: []const u8, live: []const u8, target: []const u8, part: Hex) !void {
        const key = try d.displacedKey(home, live);
        var e = d.gen.displaced.get(key) orelse return;
        e.planted = .{ .live = live, .target = target, .part = part };
        try d.log(.displaced, key, try generation.flatDisplacedValue(d.arena, e), true);
        try d.gen.displaced.put(d.arena, key, e);
    }

    /// Keep a captured directory tree: its root `dir_live`, and every member
    /// by its full key.
    pub fn saveTree(d: *Draft, home: []const u8, dir_live: []const u8, captured: Captured) !void {
        const root = try d.displacedKey(home, dir_live);
        for (captured.dirs) |c| {
            const key = try d.displacedKey(home, c.live);
            try d.setDisplaced(key, .{ .type = .dir, .mode = c.mode, .root = if (std.mem.eql(u8, key, root)) null else root });
        }
        for (captured.files) |c| {
            const key = try d.displacedKey(home, c.live);
            const h = try blob.put(d.arena, d.io, d.store.blobs, c.content);
            try d.setDisplaced(key, .{ .type = .file, .blob = h, .mode = c.mode, .root = root });
        }
        for (captured.symlinks) |c| {
            const key = try d.displacedKey(home, c.live);
            try d.setDisplaced(key, .{ .type = .link, .target = c.target, .root = root });
        }
    }

    pub fn readBlob(d: *const Draft, h: Hex) !?[]const u8 {
        return blob.get(d.arena, d.io, d.store.blobs, h);
    }

    pub fn blobPath(d: *const Draft, h: Hex) ![]const u8 {
        return blob.pathOf(d.arena, d.store.blobs, h);
    }

    /// Every generation that displaced something, oldest first, the ones
    /// recovery folded in memory included.
    pub fn listed(d: *const Draft) ![]const @import("retention.zig").Listed {
        const retention = @import("retention.zig");
        const inv = try retention.inventory(d.arena, d.io, d.store);
        var out: std.ArrayList(retention.Listed) = .empty;
        for (inv.gens) |l| if (l.gen.displaced.count() > 0) try out.append(d.arena, l);
        for (d.unwritten) |g| if (g.displaced.count() > 0) try out.append(d.arena, .{ .id = g.id, .gen = g });
        std.mem.sort(retention.Listed, out.items, {}, struct {
            fn lt(_: void, a: retention.Listed, b: retention.Listed) bool {
                return id_mod.older({}, a.id, b.id);
            }
        }.lt);
        return out.items;
    }

    /// Generation `gen_id`, when it displaced something.
    pub fn displacedOf(d: *const Draft, gen_id: []const u8) !?Generation {
        for (d.unwritten) |g| if (std.mem.eql(u8, g.id, gen_id)) return if (g.displaced.count() > 0) g else null;
        const g = (try @import("recovery.zig").readGeneration(d.arena, d.io, d.store, gen_id, null)) orelse return null;
        return if (g.displaced.count() > 0) g else null;
    }

    pub fn hasDisplaced(d: *const Draft) bool {
        return d.gen.displaced.count() > 0;
    }
};

/// A writable draft over an empty store at `state_dir`, for unit tests.
pub fn testDraft(arena: std.mem.Allocator, io: Io, state_dir: []const u8) !*Draft {
    const d = try arena.create(Draft);
    const part = applied.contentHashHex("test-part");
    d.* = .{
        .arena = arena,
        .io = io,
        .store = try Store.init(arena, state_dir),
        .writable = true,
        .gen = .{ .id = "", .kind = .apply, .run_kind = .apply },
        .base = "",
        .loaded = null,
        .run_kind = .apply,
        .part = part,
        .part_info = .{ .repo = "/repo", .home = "/home" },
    };
    return d;
}

/// A directory tree captured whole, before it is removed.
pub const Captured = struct {
    files: []const TreeFile,
    symlinks: []const TreeLink,
    dirs: []const TreeDir,
};

pub const TreeFile = struct { live: []const u8, content: []const u8, mode: u32 };
pub const TreeLink = struct { live: []const u8, target: []const u8 };
pub const TreeDir = struct { live: []const u8, mode: u32 };

fn contains(items: []const []const u8, s: []const u8) bool {
    for (items) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;

fn testStore(a: std.mem.Allocator, io: Io, tmp: *testing.TmpDir) !*Draft {
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    return testDraft(a, io, try std.fs.path.join(a, &.{ root, "state" }));
}

fn ownedRecord(canonical: []const u8) applied.OwnedRecord {
    return .{ .mode = .own, .canonical = canonical, .canonical_hash = null, .secret = false, .own_paths = &.{}, .secret_paths = &.{}, .live_path = "" };
}

test "draft: a kind change in every direction leaves one kind, and forgetting another kind leaves it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = try testStore(a, io, &tmp);
    const P = "/h/p";
    const writes = [_]generation.RecordKind{ .file, .owned, .link, .file, .link, .owned, .file };
    for (writes) |k| {
        switch (k) {
            .file => try d.record(P, "x\n", "src/p"),
            .owned => try d.recordOwned(P, ownedRecord("{}"), "src/p"),
            .link => try d.recordSymlink(P, "/t", "src/p"),
        }
        const e = d.entry(P).?;
        try testing.expectEqual(k, e.kind);
        try testing.expectEqual(k == .file, e.file != null);
        try testing.expectEqual(k == .owned, e.owned != null);
        try testing.expectEqual(k == .link, e.link != null);
    }
    try d.forgetSymlink(P);
    try d.forgetOwned(P);
    try testing.expectEqual(generation.RecordKind.file, d.entry(P).?.kind);
    try d.forgetWholeFile(P);
    try testing.expect(d.entry(P) == null);
}

test "draft: provenance outlives its record in residue, and forgetting provenance clears both places" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = try testStore(a, io, &tmp);
    const P = "/h/p";
    const prov = try blob.put(a, io, d.store.blobs, "{}");

    try d.persistProvenanceBlob(P, prov);
    try testing.expectEqual(prov, d.gen.residue.get(P).?);
    try d.record(P, "x\n", null);
    try testing.expect(d.entry(P).?.file.?.provenance_blob == null);
    try testing.expectEqual(prov, d.provenanceBlob(P).?);
    try d.persistProvenanceBlob(P, prov);
    try testing.expect(!d.gen.residue.contains(P));
    try d.record(P, "y\n", null);
    try testing.expectEqual(prov, d.entry(P).?.file.?.provenance_blob.?);
    for ([_]enum { forget, whole, owned, link }{ .forget, .whole, .owned, .link }) |how| {
        try d.record(P, "y\n", null);
        try d.persistProvenanceBlob(P, prov);
        switch (how) {
            .forget => try d.forget(P),
            .whole => try d.forgetWholeFile(P),
            .owned => try d.recordOwned(P, ownedRecord("{}"), null),
            .link => try d.recordSymlink(P, "/t", null),
        }
        try testing.expectEqual(prov, d.gen.residue.get(P).?);
        try testing.expectEqual(prov, d.provenanceBlob(P).?);
        try d.forget(P);
    }
    try d.record(P, "y\n", null);
    try d.persistProvenanceBlob(P, prov);
    try d.forgetProvenance(P);
    try testing.expect(d.provenanceBlob(P) == null);
    try d.forget(P);
    try testing.expect(d.provenanceBlob(P) == null);
}

test "draft: a provenance rebuild updates a file record in place, and leaves a record of another kind as it is" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = try testStore(a, io, &tmp);
    try d.record("/h/f", "x\n", null);
    try d.rebuildFile("/h/f", "x\n", &.{}, false);
    const f = d.entry("/h/f").?.file.?;
    try testing.expect(f.cache_blob != null and f.provenance_blob != null);
    try testing.expect(!d.gen.residue.contains("/h/f"));
    try d.rebuildFile("/h/f", "x\n", &.{}, true);
    try testing.expect(d.entry("/h/f").?.file.?.cache_blob == null);

    try d.recordSymlink("/h/l", "/t", null);
    try d.rebuildFile("/h/l", "x\n", &.{}, false);
    const e = d.entry("/h/l").?;
    try testing.expect(e.kind == .link and e.file == null);
    try testing.expect(!d.gen.residue.contains("/h/l"));
}

test "draft: a record write with a composed file sets source_key, and a rolled-back link keeps it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = try testStore(a, io, &tmp);
    try d.record("/h/f", "x\n", "src/f");
    try testing.expectEqualStrings("src/f", d.entry("/h/f").?.source_key.?);
    try d.recordOwned("/h/o", ownedRecord("{}"), "src/o");
    try testing.expectEqualStrings("src/o", d.entry("/h/o").?.source_key.?);
    try d.setProduced("/h/g", &.{"/h/g/a"}, "src/g");
    try testing.expectEqualStrings("src/g", d.generator("/h/g").?.source_key.?);
    try d.recordSymlink("/h/l", "/t", "src/l");
    const other = applied.contentHashHex("other part");
    try d.recordRolledBackLink("/h/l", "/t", other);
    const e = d.entry("/h/l").?;
    try testing.expectEqualStrings("src/l", e.source_key.?);
    try testing.expect(e.link.?.rolled_back and std.mem.eql(u8, &e.part, &other));
    try testing.expect(d.readSymlink("/h/l") == null);
}

test "draft: a tree saved inside a later tree save keeps every member it holds, written and folded alike" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = try testStore(a, io, &tmp);
    const home = "/h";
    try d.saveTree(home, "/h/A/B", .{
        .dirs = &.{.{ .live = "/h/A/B", .mode = 0o755 }},
        .files = &.{.{ .live = "/h/A/B/x", .content = "x\n", .mode = 0o644 }},
        .symlinks = &.{},
    });
    try d.saveTree(home, "/h/A", .{
        .dirs = &.{ .{ .live = "/h/A", .mode = 0o700 }, .{ .live = "/h/A/B", .mode = 0o750 } },
        .files = &.{.{ .live = "/h/A/y", .content = "y\n", .mode = 0o600 }},
        .symlinks = &.{},
    });
    const want = [_][]const u8{ "A", "A/B", "A/B/x", "A/y" };
    var g = d.gen;
    g.id = "20260101T000000Z";
    const back = try generation.parse(a, try generation.serialize(a, g), null);
    for (want) |k| try testing.expect(back.displaced.contains(k));
    try testing.expectEqual(want.len, back.displaced.count());
    try testing.expectEqual(@as(u32, 0o750), back.displaced.get("A/B").?.mode.?);

    const j = try Io.Dir.cwd().readFileAlloc(io, d.jnl.?.path, a, .unlimited);
    const parsed = (try journal.parse(a, j)).?;
    var folded: Generation = .{ .id = "20260101T000000Z", .kind = .recovered, .run_kind = .apply };
    for (parsed.ops) |op| if (op.map == .displaced) try folded.displaced.put(a, op.key, try generation.parseFlatDisplaced(a, op.value.?));
    const refolded = try generation.parse(a, try generation.serialize(a, folded), null);
    for (want) |k| try testing.expect(refolded.displaced.contains(k));
    try testing.expectEqual(want.len, refolded.displaced.count());
}

test "draft: a change equal to what is held is not a change, and the journal is claimed at the first one" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = try testStore(a, io, &tmp);
    try d.forget("/h/none");
    try testing.expect(d.run_id == null and !d.changed);
    try d.record("/h/f", "x\n", null);
    try testing.expect(d.run_id != null);
    d.changed = false;
    try d.record("/h/f", "x\n", null);
    try testing.expect(!d.changed);
    try d.notePrivate();
    try testing.expect(d.changed);
    const j = try Io.Dir.cwd().readFileAlloc(io, d.jnl.?.path, a, .unlimited);
    try testing.expect(std.mem.indexOf(u8, j, "expects_private") != null);
}

test "draft: a reader whose blob a later commit collected re-reads current once" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const recovery = @import("recovery.zig");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const store = try Store.init(a, try std.fs.path.join(a, &.{ root, "state" }));
    var g1: Generation = .{ .id = "20260101T000000Z", .kind = .apply, .run_kind = .apply };
    try g1.paths.put(a, "/h/f", .{ .part = applied.contentHashHex("part"), .kind = .file, .file = .{ .sha256 = applied.contentHashHex("one\n"), .cache_blob = try blob.put(a, io, store.blobs, "one\n") } });
    try recovery.writeGeneration(a, io, store, g1);
    try durable.writeFile(io, store.current, "20260101T000000Z\n");
    const d = try testDraft(a, io, store.state_dir);
    d.writable = false;
    d.gen = try g1.clone(a);
    d.base = "20260101T000000Z\n";
    d.loaded = g1.id;

    var g2: Generation = .{ .id = "20260101T000001Z", .parent = g1.id, .kind = .apply, .run_kind = .apply };
    try g2.paths.put(a, "/h/f", .{ .part = applied.contentHashHex("part"), .kind = .file, .file = .{ .sha256 = applied.contentHashHex("two\n"), .cache_blob = try blob.put(a, io, store.blobs, "two\n") } });
    try recovery.writeGeneration(a, io, store, g2);
    try durable.writeFile(io, store.current, "20260101T000001Z 20260101T000000Z\n");
    try Io.Dir.cwd().deleteFile(io, try blob.pathOf(a, store.blobs, applied.contentHashHex("one\n")));
    try testing.expectEqualStrings("two\n", (try d.readContent("/h/f")).?);
}

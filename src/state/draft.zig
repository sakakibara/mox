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
const prov_shapes = @import("../provenance/shapes.zig");
const source_path = @import("../source/path.zig");
const generation = @import("generation.zig");
const blob = @import("blob.zig");
const journal = @import("journal.zig");
const id_mod = @import("id.zig");
const durable = @import("durable.zig");
const lock = @import("lock.zig");
const write_mod = @import("../apply/write.zig");
const secret_cache = @import("../secret/cache.zig");

const Generation = generation.Generation;
pub const Hex = generation.Hex;
const PathEntry = generation.PathEntry;

/// The directory under the state directory that holds the store.
pub const store_dir_name = "v2";

/// The most a provenance blob holds, half the blob read limit, so every
/// one written is read back.
pub const max_provenance_bytes: usize = 32 * 1024 * 1024;

/// The provenance of a secret-bearing `content`, or, when that would be
/// longer than `cap`, one that names every line a secret line, with an
/// outline of the one whole-line shape: diff then masks every live line,
/// and a snapshot every line, of the file.
pub fn boundedProvenance(arena: std.mem.Allocator, live: []const u8, content: []const u8, segments: []const prov_map.Segment, outline: []const prov_map.Entry, cap: usize) ![]u8 {
    const full = try prov_map.serialize(arena, live, segments, outline);
    if (full.len <= cap) return full;
    const n = prov_map.lineCount(content);
    const coarse = [_]prov_map.Segment{.{ .out_start = 0, .out_len = @max(n, 1), .origin = .secret }};
    return prov_map.serialize(arena, live, &coarse, &.{.{ .shape = prov_shapes.whole_line }});
}

/// A file as this run composed it: its bytes and their provenance.
pub const Render = struct {
    bytes: []const u8,
    segments: []const prov_map.Segment,
};

pub const Store = struct {
    state_dir: []const u8,
    v2: []const u8,
    gen: []const u8,
    blobs: []const u8,
    pending: []const u8,
    quarantine: []const u8,
    trash: []const u8,
    current: []const u8,
    readers: []const u8,
    /// What a commit's cleanup a reader kept from running would have done.
    deferred: []const u8,

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
            .readers = try std.fs.path.join(arena, &.{ state_dir, lock.readers_name }),
            .deferred = try std.fs.path.join(arena, &.{ v2, "cleanup-deferred" }),
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

/// Claim a run's id, past every id the store holds and the ones `current`
/// names, whose generation files may be gone.
pub fn claimId(arena: std.mem.Allocator, io: Io, store: Store, how: id_mod.Claim) ![]const u8 {
    var dirs = store.idDirs();
    if (@import("recovery.zig").parseCurrent(try @import("recovery.zig").readCurrent(arena, io, store))) |c| {
        dirs.taken = if (c.parent) |p| try arena.dupe([]const u8, &.{ c.id, p }) else try arena.dupe([]const u8, &.{c.id});
    }
    return id_mod.claim(arena, io, dirs, how);
}

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
    /// The secret values this run resolved: a provenance with a secret
    /// segment finds its slots by them, and stored prior content is masked
    /// with them.
    secrets: ?*const secret_cache.Cache = null,
    /// Why the commit deleted nothing old, when that is not a reader's doing.
    cleanup_warning: ?[]const u8 = null,
    /// What a step that waits for the readers says first.
    wait: ?lock.Wait = null,

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
        return blob.get(d.arena, d.io, d.store.blobs, h);
    }

    /// The owned record of `live`. One whose canonical text is missing or
    /// damaged is still a record: `canonical_missing` names where it was.
    pub fn readOwned(d: *Draft, live: []const u8) !?applied.OwnedRecord {
        const o = d.ownedRec(live) orelse return null;
        var rec: applied.OwnedRecord = .{
            .mode = o.mode,
            .canonical = null,
            .canonical_hash = o.canonical_sha256,
            .secret = o.secret,
            .own_paths = o.own_paths,
            .secret_paths = o.secret_paths,
            .live_path = live,
        };
        if (o.secret) return rec;
        const h = o.canonical_blob orelse {
            rec.canonical_missing = .unrecorded;
            return rec;
        };
        if (try blob.get(d.arena, d.io, d.store.blobs, h)) |bytes| {
            rec.canonical = bytes;
        } else rec.canonical_missing = .{ .blob = try blob.pathOf(d.arena, d.store.blobs, h) };
        return rec;
    }

    /// Every owned record that keeps no readable canonical text, by its live
    /// path, with why.
    pub fn missingCanonicals(d: *Draft) ![]const MissingCanonical {
        var out: std.ArrayList(MissingCanonical) = .empty;
        for (d.gen.paths.keys()) |k| {
            const rec = (try d.readOwned(k)) orelse continue;
            if (rec.canonical_missing) |m| try out.append(d.arena, .{ .key = k, .missing = m });
        }
        return out.items;
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
        const bytes = (try blob.get(d.arena, d.io, d.store.blobs, h)) orelse return null;
        return prov_map.deserialize(d.arena, bytes) catch null;
    }

    /// `content`, what was at `live` before this run replaces it, as a
    /// snapshot keeps it. Paired with the outline the last apply wrote the
    /// file with, each line that pairs with a secret line's shape is masked at
    /// its slots, and, when a secret line pairs with none, every line paired
    /// with nothing is replaced whole. Every value this run resolved that sits
    /// in a paired slot, and, when this run rendered the file anew (`render`),
    /// every value that render wrote, is masked wherever it occurs. When the
    /// provenance names secret lines but holds no outline, the lines at the
    /// positions it names are replaced whole; when it is missing for a record
    /// written for a secret, every line is: the values the file was written
    /// with are not known.
    pub fn redactPrior(d: *Draft, live: []const u8, content: []const u8, render: ?Render) ![]const u8 {
        const all = if (d.secrets) |c| try c.values(d.arena) else &.{};
        const values = if (render) |r| try prov_shapes.renderValues(d.arena, r.bytes, r.segments, all) else &.{};
        if (try d.provenance(live)) |m| {
            if (m.secretOutline()) |outline| return prov_shapes.redactStored(d.arena, content, outline, all, values);
            return prov_shapes.redactAt(d.arena, content, m.segments, try prov_shapes.writtenForms(d.arena, values));
        }
        if (d.fileRecord(live)) |f| if (f.cache_blob == null) {
            const whole = [_]prov_map.Segment{.{ .out_start = 0, .out_len = std.math.maxInt(u32), .origin = .secret }};
            return prov_shapes.redactAt(d.arena, content, &whole, .none);
        };
        return prov_shapes.redactStored(d.arena, content, &.{}, &.{}, values);
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
        const new_id = try claimId(d.arena, d.io, d.store, .journal);
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

    /// Keep `segments` as where each line of `content`, the bytes written
    /// to `live`, came from, with its outline when a segment is a secret.
    /// A provenance with no secret segment that would be longer than
    /// `max_provenance_bytes` is not kept: `live` then has none.
    pub fn persistProvenance(d: *Draft, live: []const u8, content: []const u8, segments: []const prov_map.Segment) !void {
        const bytes = (try d.serializeProvenance(live, content, segments)) orelse return d.forgetProvenance(live);
        try d.persistProvenanceBlob(live, try blob.put(d.arena, d.io, d.store.blobs, bytes));
    }

    fn serializeProvenance(d: *Draft, live: []const u8, content: []const u8, segments: []const prov_map.Segment) !?[]u8 {
        if (!prov_map.hasSecret(segments)) {
            const bytes = try prov_map.serialize(d.arena, live, segments, null);
            return if (bytes.len <= max_provenance_bytes) bytes else null;
        }
        const values = try (d.secrets orelse return error.SecretValuesUnknown).values(d.arena);
        return try boundedProvenance(d.arena, live, content, segments, try prov_shapes.outlineOf(d.arena, content, segments, values), max_provenance_bytes);
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
        const bytes = try d.serializeProvenance(live, content, segments);
        e.file.?.cache_blob = if (secret) null else try blob.put(d.arena, d.io, d.store.blobs, content);
        e.file.?.provenance_blob = if (bytes) |b| try blob.put(d.arena, d.io, d.store.blobs, b) else null;
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
    /// by its full key, each file as `redactPrior` keeps it.
    pub fn saveTree(d: *Draft, home: []const u8, dir_live: []const u8, captured: Captured) !void {
        const root = try d.displacedKey(home, dir_live);
        for (captured.dirs) |c| {
            const key = try d.displacedKey(home, c.live);
            try d.setDisplaced(key, .{ .type = .dir, .mode = c.mode, .root = if (std.mem.eql(u8, key, root)) null else root });
        }
        for (captured.files) |c| {
            const key = try d.displacedKey(home, c.live);
            const h = try blob.put(d.arena, d.io, d.store.blobs, try d.redactPrior(c.live, c.content, null));
            try d.setDisplaced(key, .{ .type = .file, .blob = h, .mode = c.mode, .root = root });
        }
        for (captured.symlinks) |c| {
            const key = try d.displacedKey(home, c.live);
            try d.setDisplaced(key, .{ .type = .link, .target = c.target, .root = root });
        }
    }

    /// Keep `bytes` as a blob, returning its name.
    pub fn putBlob(d: *const Draft, bytes: []const u8) !Hex {
        return blob.put(d.arena, d.io, d.store.blobs, bytes);
    }

    /// Every generation under `gen/`, oldest first, and every one that
    /// cannot be read.
    pub fn generations(d: *const Draft) !@import("retention.zig").Inventory {
        return @import("retention.zig").inventory(d.arena, d.io, d.store);
    }

    /// Where files that could not be recovered or read are kept.
    pub fn quarantineDir(d: *const Draft) []const u8 {
        return d.store.quarantine;
    }

    /// Where generation `gen_id` is kept.
    pub fn generationPath(d: *const Draft, gen_id: []const u8) ![]const u8 {
        return d.store.genPath(d.arena, gen_id);
    }

    /// Move generation `gen_id`, one that cannot be read, into quarantine;
    /// returns where it went.
    pub fn quarantineGeneration(d: *const Draft, gen_id: []const u8) ![]const u8 {
        const recovery = @import("recovery.zig");
        var r: recovery.Report = .{};
        const excl = try lock.waitExclusive(d.io, d.store.readers, d.store.v2, d.wait);
        defer if (excl) |x| x.release();
        try recovery.quarantine(d.arena, d.io, d.store, try d.store.genPath(d.arena, gen_id), &r);
        return r.quarantined.items[0];
    }

    /// What a commit's cleanup would delete now, pruning past `keep`.
    pub fn leftover(d: *const Draft) !@import("retention.zig").Leftover {
        return @import("retention.zig").leftover(d.arena, d.io, d.store);
    }

    /// Every file in quarantine, oldest name first, with what a quarantined
    /// journal displaced.
    pub fn quarantined(d: *const Draft) ![]const Quarantined {
        var out: std.ArrayList(Quarantined) = .empty;
        for (try @import("../source/dirent.zig").sortedPath(d.arena, d.io, d.store.quarantine, .{ .iterate = true })) |e| {
            const path = try std.fs.path.join(d.arena, &.{ d.store.quarantine, e.name });
            var entries: std.ArrayList(QuarantinedEntry) = .empty;
            if (std.mem.endsWith(u8, e.name, ".jsonl")) parsed: {
                const bytes = Io.Dir.cwd().readFileAlloc(d.io, path, d.arena, .limited(256 * 1024 * 1024)) catch break :parsed;
                const j = (try journal.parse(d.arena, bytes)) orelse break :parsed;
                for (j.ops) |op| {
                    if (op.map != .displaced) continue;
                    const v = op.value orelse continue;
                    const x = generation.parseFlatDisplaced(d.arena, v) catch continue;
                    try entries.append(d.arena, .{ .key = op.key, .type = x.type, .where = switch (x.type) {
                        .file => try blob.pathOf(d.arena, d.store.blobs, x.blob orelse continue),
                        .link => x.target orelse "",
                        .dir => "",
                    } });
                }
            }
            try out.append(d.arena, .{ .path = path, .displaced = entries.items });
        }
        return out.items;
    }

    /// Strip every retained generation down to its displaced history, then
    /// collect the blobs only the records named.
    pub fn stripHistory(d: *const Draft) !void {
        return @import("retention.zig").stripRecords(d.arena, d.io, d.store, d.wait);
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

pub const MissingCanonical = struct { key: []const u8, missing: applied.CanonicalMissing };

/// A file in quarantine, and for a journal what it displaced: a file's
/// blob path, a link's target.
pub const Quarantined = struct { path: []const u8, displaced: []const QuarantinedEntry };
pub const QuarantinedEntry = struct { key: []const u8, type: generation.EntryType, where: []const u8 };

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

test "boundedProvenance: one longer than the cap becomes a whole-file secret of the whole-line shape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var segs: std.ArrayList(prov_map.Segment) = .empty;
    var content: std.ArrayList(u8) = .empty;
    var i: u32 = 0;
    while (i < 2000) : (i += 1) {
        try segs.append(a, .{ .out_start = i, .out_len = 1, .origin = if (i % 2 == 0) .secret else .{ .base = .{ .line = i + 1 } } });
        try content.appendSlice(a, if (i % 2 == 0) "token=v\n" else "plain\n");
    }
    const outline = try prov_shapes.outlineOf(a, content.items, segs.items, &.{"v"});
    const full = try prov_map.serialize(a, "/h/f", segs.items, outline);
    const cap = full.len - 1;
    const bounded = try boundedProvenance(a, "/h/f", content.items, segs.items, outline, cap);
    try std.testing.expect(bounded.len <= cap);
    const m = try prov_map.deserialize(a, bounded);
    try std.testing.expectEqual(@as(usize, 1), m.segments.len);
    try std.testing.expectEqual(@as(u32, 2000), m.segments[0].out_len);
    try std.testing.expect(m.segments[0].origin == .secret);
    try std.testing.expectEqual(@as(usize, 1), m.secretOutline().?.len);
    try std.testing.expect(m.secretOutline().?[0].shape.wholeLine());
    const kept = try prov_shapes.redactStored(a, content.items, m.secretOutline().?, &.{}, &.{});
    try std.testing.expect(std.mem.indexOf(u8, kept, "plain") == null);
    try std.testing.expect(std.mem.indexOf(u8, kept, "token") == null);
    try std.testing.expectEqualStrings(full, try boundedProvenance(a, "/h/f", content.items, segs.items, outline, full.len));
}

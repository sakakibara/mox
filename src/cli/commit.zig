//! `mox commit`: route user edits of live files back into their sources.
//!
//! A live file that no longer matches what mox last wrote to it (true drift)
//! is diffed against the last-applied content. Each changed hunk is mapped,
//! through the provenance recorded at apply time, back to the source that
//! produced it: a base line to `src/`, a fragment line to its fragment file,
//! a private-layer line to the private file (NEVER repo src), a loop row to
//! its data source. Secret, interpolated, and structural-merge hunks have no
//! safe automatic route and are reported as manual. A hunk spanning more than
//! one of these origins (a straddle) is also reported manual, unless the user
//! `split`s it at the per-hunk prompt: each resulting piece lies within one
//! origin and routes on its own.
//!
//! On a TTY a routed line/row hunk is confirmed `[y/s]`, an unroutable
//! hunk `[s/x]`, an interpolated hunk `[f/d/s]`, and a structured key
//! change `[y/p/s]`; `--yes` takes the defaults, except on first contact,
//! where a baseline mox never wrote leaves no default to take; `--dry-run`
//! and a non-TTY without `--yes` only report; every mode exits 1 while
//! anything is left undone; `--abort-on-prompt` exits 2 for a prompt that
//! would have been needed, terminal or not. All writes happen after every
//! prompt, so aborting writes
//! nothing. After the sources are written, every unit -- a routed file, the
//! target of a coupled update, a generator leaf, a symlink -- is verified. A
//! unit's applied record advances only when its recompose equals live by its
//! own equality -- exact bytes for a whole file, the canonical owned form for
//! a partial file, the target for a symlink, the content for a leaf -- and no
//! configuration the user did not choose changed. A coupling-only target is
//! never compared with live: it must still compose and change no
//! configuration the user did not choose, and it records nothing. A unit that
//! fails a check is not committed. A unit not committed has every path
//! holding one of its own edits restored to its pre-run bytes -- including a
//! fragment and region directory a narrowing synthesized -- unless that edit
//! is also owned by a passing unit. A unit fails in turn when a path holding
//! one of its own edits is restored because another unit failed, or when it
//! no longer verifies once a fact it reads is reverted because the unit that
//! routed it failed; this settles until no unit fails anew. A coupled update
//! never fails the units whose rename produced it: when its path is restored
//! it is reported undone. One that changes nothing its target's own edit did
//! not already write is no edit, and is never undone.
//!
//! A manual hunk, and a hunk the user skips, are differences the recompose
//! is EXPECTED to keep: skip is `s` in the per-hunk `[y/s]` prompt
//! (decline the route outright), `s` at the candidate prompt (decline
//! only the candidate picked), `s` in a structured file's per-key prompt, or
//! the trailing `s` in its layer-pick menu (including declining that menu's
//! cross-configuration confirm) -- all stay in the live file by design, so a
//! file that has one can never recompose to live however well its other
//! hunks routed. Those routed edits stand, the applied
//! record does not advance (the rest is still real drift), and the report
//! says what is left. A hunk the tool could not route to the candidate the
//! user picked (no automatic path, a hazard) is not something the user asked
//! for: its unit is not committed whatever else holds, a coupling target
//! included.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const app = @import("app.zig");
const lock_mod = @import("lock.zig");
const tty = @import("tty.zig");
const prompt = @import("prompt.zig");
const scope = @import("scope.zig");
const display = @import("display.zig");
const style = @import("style.zig");
const mox = @import("../root.zig");
const commit_struct = @import("commit_struct.zig");
const edit_mod = @import("edit.zig");
const toml_statements = mox.data.toml_statements;
const interp = mox.compose.interp;

const Io = std.Io;
const Segment = mox.provenance.map.Segment;
const Hunk = mox.diff.lines.Hunk;
const candidates = mox.classify.candidates;
const impact = mox.classify.impact;
const config_space = mox.classify.config_space;
const Configuration = config_space.Configuration;

const max_file_bytes: usize = 64 * 1024 * 1024;

/// A line-level edit to one physical source file (base / fragment / private).
/// `private` marks an edit routed to a private-layer source: the coupling graph
/// only indexes shared base sources, so a private edit's rename could only ever
/// sync a private-authored token INTO the shared repo -- never allowed.
const LineEdit = struct {
    path: []const u8,
    start: u32,
    del: u32,
    new_lines: []const []const u8,
    private: bool = false,
};

/// A write of one row of a TOML data source, from a loop or a generator
/// leaf: one whole-line splice of the data file per field it changes, over
/// that field's value. The loop it was routed through -- body template,
/// variable, `where`, and a leaf's `into` path -- names the row fields it
/// reads; none of it is part of the write.
const RowEdit = struct {
    data_source: []const u8,
    stem: []const u8,
    row: u32,
    splices: []const LineEdit,
    template: []const u8,
    variable: []const u8,
    where: ?*const mox.dsl.ast.RowExpr,
    into: ?[]const u8 = null,
};

/// A pending literal sync of a symlink source's recorded target to the live
/// target. Only ever built for a plain-literal source (no capture, no
/// secret): a capture-bearing target is reported manual instead, never
/// collected here, so this route can never clobber one.
const SymSync = struct {
    live_path: []const u8,
    source_abs: []const u8,
    new_target: []const u8,
};

/// A generator leaf whose keep wrote at least one field into its data-source
/// row this run: enough to re-expand the generator afterward, find this leaf
/// in the fresh output, and verify it reproduces live before advancing its
/// applied record.
const GenLeafCommit = struct {
    fidx: usize,
    gen_file: mox.source.tree.ManagedFile,
    leaf_live_path: []const u8,
};

/// The generator row edits accepted this run, each with the index in
/// `leaves` of the leaf it was routed from.
const LeafRowEdits = struct {
    row_edits: std.ArrayList(RowEdit) = .empty,
    row_leaves: std.ArrayList(usize) = .empty,
    leaves: std.ArrayList(GenLeafCommit) = .empty,
};

/// A pending structured key-path edit to one source layer of a Cat-A file.
/// Planned via `commit_struct.layerBytes` and written in the write phase
/// (deferred like every other route, so abort writes nothing); its `layer_abs`
/// is journaled so it can be restored.
const StructEdit = struct {
    format: commit_struct.Format,
    layer_abs: []const u8,
    change: commit_struct.KeyPathChange,
};

/// Result of `simulateStructImpact`: which repo-wide configurations a placement
/// changes, plus the pre/post-edit compose of every configuration (index-
/// aligned with the `configs` slice) so the pick confirm can show the key's
/// value before and after.
const StructImpact = struct {
    affected: []const []const u8,
    before: impact.Snapshot,
    after: impact.Snapshot,
};

/// Outcome of simulating a placement: its impact, or the layer refusing the
/// edit. A refusal is a routing outcome the user is told about, kept distinct
/// from a real error so neither is reported as the other.
const StructSim = union(enum) {
    ok: StructImpact,
    rejected,
};

/// The routing decision for a single hunk. `shared` on a line route marks a
/// base-file or universal-fragment origin (subject to impact classification);
/// an axis-gated fragment or private-layer origin is not shared.
const Route = union(enum) {
    line: struct { edit: LineEdit, desc: []const u8, shared: bool },
    row: struct { edit: RowEdit, desc: []const u8 },
    /// A single unambiguous `<machine.X>` capture accounts for the whole
    /// hunk: `default_edit` is the alternative write, into the source's `|
    /// default` clause, that `[d]` chooses instead of the fact.
    fact: struct {
        name: []const u8,
        new_value: []const u8,
        old_value: ?[]const u8,
        default_edit: LineEdit,
        default_desc: []const u8,
    },
    manual: []const u8,
};

/// A pending write to the machine-local facts file (never repo `src`),
/// routed from an interpolated hunk's `[f]` choice. `old_value` is what the
/// fact resolved to before this run (null when it was unset, i.e. the
/// source's default was in effect), so a rejected routing can restore
/// exactly that prior state.
const FactEdit = struct { name: []const u8, new_value: []const u8, old_value: ?[]const u8 };

/// Everything the per-hunk classifier needs. Grouped so the shared-origin
/// pipeline (impact analysis, candidate prompt, verification allowlist) can be
/// factored out of the main routing loop.
const ClassCtx = struct {
    arena: std.mem.Allocator,
    io: Io,
    this_bindings: *const std.StringHashMap([]const u8),
    /// Same underlying bindings as `this_bindings`, wrapped for the
    /// evaluation surfaces (compose, overlay/fragment matching) that take a
    /// resolver rather than a raw map. `this_bindings` itself stays raw for
    /// `config_space.enumerate`/`candidates.compute`, which manipulate the
    /// map directly (clone, remove, iterate) and are not evaluation surfaces.
    resolver: *const mox.dsl.resolver.Resolver,
    m_state: *const mox.machine.state.MachineState,
    secrets: mox.compose.catB.SecretCtx,
    /// This machine's `machine`-axis value (the hostname's first label, same
    /// as `bindings.fromMachineState` binds) -- what a machine-local
    /// narrowing's synthesized `machine=` region must match, not the raw
    /// hostname.
    machine: []const u8,
    stdout: *Io.Writer,
    err: *Io.Writer,
    input: *Io.Reader,
    ask_mode: prompt.Mode,
    report_mode: bool,
    /// True when a prompt would actually read from a terminal (or scripted
    /// stdin), OR under `--abort-on-prompt` (which prints it right before the
    /// strict abort). Gates the per-hunk header; `--yes` alone suppresses it
    /// as noise.
    interactive: bool,
    sty: style.Style,
    /// What the narrowings accepted earlier in this run will create.
    claims: *Claims,
};

/// Mutable per-run tallies and output collectors the per-hunk pipeline
/// (`processHunk`) updates. Grouped into one struct, rather than threaded as
/// individual parameters, so a split hunk's sub-hunks can recurse back into
/// the SAME pipeline instead of a stripped-down copy of it.
const RunAccum = struct {
    line_edits: *std.ArrayList(LineEdit),
    line_owners: *std.ArrayList(usize),
    row_edits: *std.ArrayList(RowEdit),
    row_owners: *std.ArrayList(usize),
    fact_edits: *std.ArrayList(FactEdit),
    fact_owners: *std.ArrayList(usize),
    synth_plans: *std.ArrayList(SynthDecision),
    synth_owners: *std.ArrayList(usize),
    struct_edits: *std.ArrayList(StructEdit),
    struct_owners: *std.ArrayList(usize),
    affected: []bool,
    allowed: []std.StringHashMap(void),
    manual_hunks: []usize,
    declined_hunks: []usize,
    unrouted_hunks: []usize,
    manual_count: *usize,
    routed_count: *usize,
    pending: *bool,
};

/// What the caller of `processHunk` does next: keep going, or unwind the
/// whole file loop because the user aborted (plain or strict).
const HunkOutcome = enum { cont, abort, abort_strict };

/// A region synthesis to materialize after all prompts.
const SynthDecision = struct {
    plan: mox.classify.synth.Plan,
    base_abs: []const u8,
    /// Configuration labels this narrowing is allowed to change.
    allowed: []const []const u8,
};

/// The regions and fragments the narrowings ACCEPTED SO FAR IN THIS RUN will
/// create. `synth.hazardOf` sees only what predates the run, so it is blind to
/// them: without this, a second narrowing of the same file to the same axis
/// passes every check and then overwrites the first one's region and fragment
/// -- two regions of one name are unrepresentable, which is exactly what the
/// region hazard exists to prevent.
const Claims = struct {
    regions: std.ArrayList(Region),
    fragments: std.ArrayList([]const u8),

    const Region = struct { base_abs: []const u8, name: []const u8 };

    const empty: Claims = .{ .regions = .empty, .fragments = .empty };

    fn add(c: *Claims, arena: std.mem.Allocator, base_abs: []const u8, name: []const u8, fragment: []const u8) !void {
        try c.regions.append(arena, .{ .base_abs = base_abs, .name = name });
        try c.fragments.append(arena, fragment);
    }

    /// Why narrowing `base_abs` to a `name` region writing `fragment` collides
    /// with a narrowing this run already accepted, or null when it is free.
    fn hazard(c: Claims, arena: std.mem.Allocator, base_abs: []const u8, name: []const u8, fragment: []const u8) !?[]const u8 {
        for (c.regions.items) |r| {
            if (!std.mem.eql(u8, r.base_abs, base_abs)) continue;
            if (!std.mem.eql(u8, r.name, name)) continue;
            return try std.fmt.allocPrint(
                arena,
                "another edit in this commit already narrows this file to a region named \"{s}\", which would pick up the new fragment too",
                .{name},
            );
        }
        for (c.fragments.items) |f| {
            if (!std.mem.eql(u8, f, fragment)) continue;
            return try std.fmt.allocPrint(
                arena,
                "another edit in this commit already writes the fragment \"{s}\"; synthesizing here would overwrite it",
                .{f},
            );
        }
        return null;
    }
};

/// Pre-write bytes of one source path a routed edit will rewrite. `content` is
/// null when the path did not exist yet (a synthesized fragment), and
/// `created_dir` is the topmost directory the write has to create for it, so a
/// restore can also remove the directories the write created.
const Backup = struct {
    path: []const u8,
    content: ?[]const u8,
    created_dir: ?[]const u8,
};

/// Pre-run state of every source path the write phase writes, and of the
/// facts file when a fact is routed, one entry per path, recorded before the
/// first write.
const Journal = struct {
    entries: std.StringHashMap(Backup),

    fn init(arena: std.mem.Allocator) Journal {
        return .{ .entries = .init(arena) };
    }

    fn record(j: *Journal, arena: std.mem.Allocator, io: Io, path: []const u8) !void {
        if (j.entries.contains(path)) return;
        const content: ?[]const u8 = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        try j.entries.put(path, .{ .path = path, .content = content, .created_dir = mox.classify.synth.missingAncestor(io, path) });
    }

    /// Put `path` back to its pre-run bytes. A path that did not exist is
    /// deleted, and then each directory its write created, innermost first,
    /// only while it is empty.
    fn restore(j: *const Journal, io: Io, path: []const u8) !void {
        const b = j.entries.get(path).?;
        if (b.content) |bytes| return Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        Io.Dir.cwd().deleteFile(io, path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        const top = b.created_dir orelse return;
        var dir = std.fs.path.dirname(path);
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            Io.Dir.cwd().deleteDir(io, d) catch return;
            if (std.mem.eql(u8, d, top)) return;
        }
    }
};

/// `path` by the file it names, so two spellings of one file are one path: an
/// existing path as the OS resolves it (symlinks, `.` and `..`, the on-disk
/// spelling on a case-insensitive file system); an absent one as its nearest
/// existing ancestor's real path joined with the rest. A path the OS cannot
/// resolve for another reason stays as given.
fn canonicalPath(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    var ancestor = path;
    while (true) {
        if (Io.Dir.cwd().realPathFileAlloc(io, ancestor, arena)) |real| {
            if (ancestor.len == path.len) return real;
            var rest = path[ancestor.len..];
            while (rest.len > 0 and std.fs.path.isSep(rest[0])) rest = rest[1..];
            return std.fs.path.resolve(arena, &.{ real, rest });
        } else |e| switch (e) {
            error.OutOfMemory => return e,
            error.FileNotFound, error.NotDir => ancestor = std.fs.path.dirname(ancestor) orelse return path,
            else => return path,
        }
    }
}

/// What makes two paths one file: its device and inode, or on Windows its
/// volume serial number and 128-bit file id. Every hard link to a file has it.
const FileIdentity = struct { device: u64, inode: u128 };

/// The identity of the existing file at `path`, or null when it cannot be
/// read for any reason (an absent file, a refused open, no call the system
/// allows); the caller then keys the file by its canonical real path. POSIX
/// reads it without opening the file, so a FIFO never blocks.
fn fileIdentity(io: Io, path: []const u8) ?FileIdentity {
    switch (builtin.os.tag) {
        .windows => {
            const file = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
            defer file.close(io);
            return windowsFileId(file.handle) orelse windowsIndexIdentity(io, file);
        },
        .linux => {
            const linux = std.os.linux;
            const z = std.posix.toPosixPath(path) catch return null;
            var stx: linux.Statx = undefined;
            switch (linux.errno(linux.statx(linux.AT.FDCWD, &z, 0, .{ .INO = true }, &stx))) {
                .SUCCESS => return .{ .device = (@as(u64, stx.dev_major) << 32) | stx.dev_minor, .inode = stx.ino },
                // statx refused by a seccomp filter or missing from the kernel.
                .NOSYS, .PERM => return linuxStatIdentity(&z),
                else => return null,
            }
        },
        else => {
            const z = std.posix.toPosixPath(path) catch return null;
            var st: std.c.Stat = undefined;
            if (std.c.fstatat(std.c.AT.FDCWD, &z, &st, 0) != 0) return null;
            const dev = st.dev;
            const device: u64 = if (@typeInfo(@TypeOf(dev)).int.signedness == .signed) @bitCast(@as(i64, dev)) else dev;
            return .{ .device = device, .inode = st.ino };
        },
    }
}

/// FILE_ID_INFORMATION: the volume serial number and the 128-bit file id
/// ReFS needs, which NTFS fills from its 64-bit index.
const WindowsFileIdInfo = extern struct {
    VolumeSerialNumber: u64,
    FileId: [16]u8,
};

/// A file's identity from its 128-bit id, or null when the file system does
/// not report one (FAT and some network redirectors).
fn windowsFileId(handle: std.os.windows.HANDLE) ?FileIdentity {
    const windows = std.os.windows;
    var info: WindowsFileIdInfo = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    if (windows.ntdll.NtQueryInformationFile(handle, &iosb, &info, @sizeOf(WindowsFileIdInfo), .Id) != .SUCCESS) return null;
    return .{ .device = info.VolumeSerialNumber, .inode = std.mem.readInt(u128, &info.FileId, .little) };
}

/// A file's identity from its volume's 32-bit serial number and its 64-bit
/// index, where no 128-bit id is available.
fn windowsIndexIdentity(io: Io, file: Io.File) ?FileIdentity {
    const windows = std.os.windows;
    const st = file.stat(io) catch return null;
    const Info = windows.FILE.FS_VOLUME_INFORMATION;
    // The volume label follows the fixed fields; only the serial number is
    // wanted, so a label that does not fit is fine.
    var buf: [@sizeOf(Info) + 64]u8 align(@alignOf(Info)) = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    switch (windows.ntdll.NtQueryVolumeInformationFile(file.handle, &iosb, &buf, buf.len, .Volume)) {
        .SUCCESS, .BUFFER_OVERFLOW => {},
        else => return null,
    }
    const info: *const Info = @ptrCast(&buf);
    return .{ .device = info.VolumeSerialNumber, .inode = @as(u64, @bitCast(st.inode)) };
}

/// A file's identity from `fstatat`, in the device numbering statx uses.
/// Only 64-bit targets whose kernel `struct stat` opens with the 64-bit
/// `st_dev` and `st_ino` are read; elsewhere the caller keys by path.
fn linuxStatIdentity(z: [*:0]const u8) ?FileIdentity {
    const linux = std.os.linux;
    switch (builtin.cpu.arch) {
        .x86_64, .aarch64, .aarch64_be, .riscv64, .loongarch64, .powerpc64, .powerpc64le, .s390x => {},
        else => return null,
    }
    // Larger than any of those targets' `struct stat`.
    var buf: [256]u8 align(8) = undefined;
    const rc = linux.syscall4(.fstatat64, @as(usize, @bitCast(@as(isize, linux.AT.FDCWD))), @intFromPtr(z), @intFromPtr(&buf), 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const words: *const [2]u64 = @ptrCast(&buf);
    return .{ .device = linuxDevice(words[0]), .inode = words[1] };
}

/// A `dev_t` as the major and minor numbers statx reports, each in its own
/// 32-bit half.
fn linuxDevice(dev: u64) u64 {
    const major: u32 = @truncate(((dev >> 8) & 0xfff) | ((dev >> 32) & ~@as(u64, 0xfff)));
    const minor: u32 = @truncate((dev & 0xff) | ((dev >> 12) & ~@as(u64, 0xff)));
    return (@as(u64, major) << 32) | minor;
}

/// Canonical source paths, each with the spelling it was first reached by,
/// which is how messages name it. An existing file is one path whatever
/// hard link reaches it: the real path first seen for its identity.
const PathIds = struct {
    arena: std.mem.Allocator,
    io: Io,
    spelling: std.StringHashMap([]const u8),
    by_identity: std.AutoHashMap(FileIdentity, []const u8),

    fn init(arena: std.mem.Allocator, io: Io) PathIds {
        return .{ .arena = arena, .io = io, .spelling = .init(arena), .by_identity = .init(arena) };
    }

    /// `path`'s canonical path, without recording how it was spelled.
    fn canonical(ids: *PathIds, path: []const u8) ![]const u8 {
        const real = try canonicalPath(ids.arena, ids.io, path);
        const id = fileIdentity(ids.io, real) orelse return real;
        const gop = try ids.by_identity.getOrPut(id);
        if (!gop.found_existing) gop.value_ptr.* = real;
        return gop.value_ptr.*;
    }

    fn of(ids: *PathIds, path: []const u8) ![]const u8 {
        const canonical_path = try ids.canonical(path);
        const gop = try ids.spelling.getOrPut(canonical_path);
        if (!gop.found_existing) gop.value_ptr.* = path;
        return canonical_path;
    }

    fn shown(ids: *const PathIds, path: []const u8) []const u8 {
        return ids.spelling.get(path) orelse path;
    }
};

/// What is verified and recorded on its own: a managed file by index (routed,
/// or the target of a coupled update only), an accepted symlink target sync,
/// or a generator leaf with an accepted row edit, each by its index in its
/// own list.
const Unit = union(enum) {
    file: usize,
    symlink: usize,
    leaf: usize,
};

/// One planned edit and every unit whose change produced it. Identical edits
/// are collected once, their owners unioned.
fn Owned(comptime T: type) type {
    return struct {
        edit: T,
        owners: std.ArrayList(Unit),

        fn ownedBy(o: @This(), owner: Unit) bool {
            for (o.owners.items) |x| {
                if (std.meta.eql(x, owner)) return true;
            }
            return false;
        }
    };
}

fn addOwned(
    comptime T: type,
    arena: std.mem.Allocator,
    list: *std.ArrayList(Owned(T)),
    edit: T,
    owners: []const Unit,
    comptime eql: fn (T, T) bool,
) !void {
    const slot = for (list.items) |*o| {
        if (eql(o.edit, edit)) break o;
    } else blk: {
        try list.append(arena, .{ .edit = edit, .owners = .empty });
        break :blk &list.items[list.items.len - 1];
    };
    for (owners) |owner| {
        if (!slot.ownedBy(owner)) try slot.owners.append(arena, owner);
    }
}

fn lineEditEql(a: LineEdit, b: LineEdit) bool {
    return std.mem.eql(u8, a.path, b.path) and sameSplice(a, b);
}

/// Whether two splices replace the same lines with the same lines.
fn sameSplice(a: LineEdit, b: LineEdit) bool {
    if (a.start != b.start or a.del != b.del) return false;
    if (a.new_lines.len != b.new_lines.len) return false;
    for (a.new_lines, b.new_lines) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn couplingEditEql(a: CouplingEdit, b: CouplingEdit) bool {
    return std.mem.eql(u8, a.path, b.path) and std.mem.eql(u8, a.old, b.old) and std.mem.eql(u8, a.new, b.new);
}

fn structEditEql(a: StructEdit, b: StructEdit) bool {
    return a.format == b.format and std.mem.eql(u8, a.layer_abs, b.layer_abs) and commit_struct.changeEql(a.change, b.change);
}

/// One source path's bytes as the plan leaves it: null while it is absent.
/// `make_parent` marks a path a struct edit writes, whose directory may not
/// exist yet.
const PlannedPath = struct {
    path: []const u8,
    bytes: ?[]const u8,
    make_parent: bool = false,
};

/// Every written path's final bytes, in the order today's write sequence
/// first touches each, threaded from its journaled pre-run bytes.
const WritePlan = struct {
    paths: std.ArrayList(PlannedPath),
    journal: *const Journal,

    fn slot(p: *WritePlan, arena: std.mem.Allocator, path: []const u8) !*PlannedPath {
        for (p.paths.items) |*pp| {
            if (std.mem.eql(u8, pp.path, path)) return pp;
        }
        try p.paths.append(arena, .{ .path = path, .bytes = p.journal.entries.get(path).?.content });
        return &p.paths.items[p.paths.items.len - 1];
    }

    /// The path's current planned bytes; an absent path fails the way
    /// reading it from disk would.
    fn bytesOf(p: *WritePlan, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
        return (try p.slot(arena, path)).bytes orelse error.FileNotFound;
    }

    fn set(p: *WritePlan, arena: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
        (try p.slot(arena, path)).bytes = bytes;
    }

    fn get(p: *const WritePlan, path: []const u8) ?[]const u8 {
        for (p.paths.items) |pp| {
            if (std.mem.eql(u8, pp.path, path)) return pp.bytes;
        }
        return null;
    }
};

/// Result of classifying one shared-origin hunk.
const Decision = union(enum) {
    /// Keep the edit at its origin. Payload: labels of the configurations the
    /// edit changes (allowed to differ from their prior compose in
    /// verification).
    origin: []const []const u8,
    /// Narrow the edit to an axis via region synthesis.
    synth: SynthDecision,
    /// Report-only: the analysis was printed; nothing to write.
    report,
    /// User explicitly skipped this hunk at the candidate prompt (`s`): a
    /// deliberate decline, ordinary as declining at the plain `[y/s]`
    /// prompt.
    skip,
    /// The candidate the user picked has no automatic route (private layer,
    /// an unknown comment marker, or a hazard that would corrupt or collide
    /// with another region/fragment). Unlike `skip`, this is not what the
    /// user asked for -- the tool could not honor the choice.
    unroutable,
    /// Hunk downgraded to manual.
    manual,
    abort,
    abort_strict,
};

/// Per-hunk routing prompt for a routable line/row hunk: accept the route, skip
/// it (leave the drift; the file stays uncommitted), or split a straddling hunk
/// into per-segment pieces (a no-op once a hunk resolved to `.line`/`.row`).
const ys_choices = [_]prompt.Choice{
    .{ .key = "y", .label = "yes", .help = "route this edit into its source" },
    .{ .key = "s", .label = "skip", .help = "skip -- leave the drift" },
};

/// A hunk `routeHunk` could not resolve to any source: skip it (handle by hand,
/// leaving the drift), or split it at its provenance-segment boundaries so each
/// piece routes on its own.
///
/// Split is offered ONLY here. `routeHunk` resolves a hunk to a real route only
/// when `covering()` finds it inside a SINGLE segment, so every other prompt's
/// hunk has nothing to split by construction -- offering it there advertised an
/// operation that could not happen, and the arms behind it silently disagreed
/// (two routed the hunk, one reported it manual).
const sx_choices = [_]prompt.Choice{
    .{ .key = "s", .label = "skip", .help = "skip -- handle by hand, leave the drift" },
    .{ .key = "x", .label = "split", .help = "split -- break this hunk into per-source pieces" },
};

/// Interpolated-value prompt: `f` writes the new value into the fact, `d` writes
/// it into the source's `| default` instead, `s` skips (leave the drift).
const fact_choices = [_]prompt.Choice{
    .{ .key = "f", .label = "fact", .help = "set the fact to the new value" },
    .{ .key = "d", .label = "default", .help = "change the source default instead" },
    .{ .key = "s", .label = "skip", .help = "skip -- leave the drift" },
};

/// Structured key-change prompt: accept the winning layer, pick which layer to
/// place the key in, or skip (leave the key only in the live file).
const struct_choices = [_]prompt.Choice{
    .{ .key = "y", .label = "yes", .help = "write to the winning layer" },
    .{ .key = "p", .label = "pick", .help = "choose which layer to place the key in" },
    .{ .key = "s", .label = "skip", .help = "skip -- leave the key in the live file only" },
};

/// F-coupling prompt: `y` updates the other consumer, `d` declines this
/// (token, file-pair), `D` declines the token everywhere.
const yndd_choices = [_]prompt.Choice{
    .{ .key = "y", .label = "yes" },
    .{ .key = "n", .label = "no" },
    .{ .key = "d", .label = "decline pair" },
    .{ .key = "D", .label = "decline globally" },
};

/// A pending update to a coupled source file: replace `old` with `new`.
const CouplingEdit = struct {
    path: []const u8,
    old: []const u8,
    new: []const u8,
};

/// A single token that a routed edit renamed (old -> new).
const Rename = struct {
    old: []const u8,
    new: []const u8,
};

const Spec = struct {
    dry_run: cli.Flag(.{ .help = "report only, exit 1 if edits remain" }),
    yes: cli.Flag(.{ .help = "take defaults without prompting" }),
    abort_on_prompt: cli.Flag(.{ .help = "strict CI: rc 2 on the first prompt" }),
    color: cli.Opt(style.ColorFlag, .{ .default = "auto", .value_name = "color", .help = "auto|always|never" }),
    paths: cli.Rest(.{ .help = "limit to these files (default: all)", .complete = .{ .dynamic = "managed-file" } }),
};

/// A file's own configuration space, built once from its source and reused
/// across every hunk classification and verification step for that file.
const FileSpace = struct {
    ax: mox.source.axes.Axes,
    configs: []const Configuration,
};

/// Configuration space for `file`: the axes ITS OWN directives express,
/// simulated against this machine's bindings. Building this from the file
/// itself (never a published census) is the whole point of this module: the
/// source is never stale, so every configuration it can express is covered.
fn fileSpace(
    arena: std.mem.Allocator,
    io: Io,
    this_bindings: *const std.StringHashMap([]const u8),
    file: mox.source.tree.ManagedFile,
) !FileSpace {
    const ax = try mox.source.axes.ofFile(arena, io, file);
    // A base line edit reaches every machine with no override of that line,
    // including one whose os/arch/machine value no source names -- the same
    // blast radius the structured route enumerates. Without this a file that
    // composes verbatim from its base reports "changes 0 configurations" for
    // an edit that changes every unnamed machine.
    const configs = try config_space.enumerate(arena, this_bindings, ax, &.{}, &derived_axes);
    return .{ .ax = ax, .configs = configs };
}

/// What one commit did to the package manifest.
const PackageReconcile = struct {
    added: usize = 0,
    blacklisted: usize = 0,
    skipped: usize = 0,
    /// The manifest could not be read or checked: an error, counted as
    /// pending so the run cannot exit clean past it.
    broken: bool = false,
    /// `q` at a package prompt, or `--abort-on-prompt` meeting one.
    aborted: bool = false,
    strict_abort: bool = false,

    fn touched(self: PackageReconcile) bool {
        return self.added > 0 or self.blacklisted > 0;
    }

    fn pending(self: PackageReconcile) bool {
        return self.skipped > 0 or self.broken;
    }
};

/// Offer every untracked package: record it in the manifest, blacklist it so
/// it is never offered again, or skip it for now. This is the package analog
/// of routing a live edit back to its source -- reality is the truth, and the
/// manifest is what gets updated to match.
///
/// Never uninstalls: the three answers all leave the machine exactly as it
/// is, and only the manifest changes. A path-scoped commit names files, so it
/// skips this entirely.
fn reconcilePackages(
    ctx: *app.Ctx,
    context: app.Context,
    bindings: *const mox.dsl.resolver.Resolver,
    m_state: mox.machine.state.MachineState,
    ask_mode: prompt.Mode,
    input: *Io.Reader,
    report_only: bool,
) !PackageReconcile {
    const env = try app.packageEnv(ctx, context, m_state);
    var diag: mox.packages.manifest.Diag = .{};
    const m = mox.packages.manifest.load(
        ctx.alloc,
        ctx.io,
        context.paths.repo_dir,
        context.paths.private_dir,
        &diag,
    ) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            if (diag.capture()) |cap| {
                try ctx.err.print("mox commit: packages: {s}\n", .{cap});
            } else {
                try ctx.err.print("mox commit: packages: {s}\n", .{@errorName(e)});
            }
            return .{ .broken = true };
        },
    };
    if (!m.inUse()) return .{};

    var pkg_backends: app.PackageBackends = .{};
    const registry = pkg_backends.registry(
        ctx.alloc,
        ctx.io,
        context.paths.state_dir,
        context.paths.home,
        env,
        context.paths.repo_dir,
        true,
        ctx.out,
        ctx.err,
        &diag,
    ) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            if (diag.capture()) |cap| {
                try ctx.err.print("mox commit: packages: {s}\n", .{cap});
            } else {
                try ctx.err.print("mox commit: packages: {s}\n", .{@errorName(e)});
            }
            return .{ .broken = true };
        },
    };
    for (pkg_backends.notes) |note| try ctx.out.print("  note       {s}\n", .{note});

    const rep = mox.packages.report.fromManifest(ctx.alloc, m, registry, bindings, &.{}, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            if (diag.capture()) |cap| {
                try ctx.err.print("mox commit: packages: {s}\n", .{cap});
            } else {
                try ctx.err.print("mox commit: packages: {s}\n", .{@errorName(e)});
            }
            return .{ .broken = true };
        },
    };
    for (rep.notes) |note| try ctx.out.print("  note       {s}\n", .{note});
    // A manager that cannot answer has nothing to reconcile: it can neither
    // list what is installed nor be asked to record it.
    for (rep.broken) |b| {
        if (b.code) |code| {
            try ctx.out.print(
                "  note       {s}: {s} exited {d}; nothing to reconcile for it\n",
                .{ b.backend, b.probe, code },
            );
        } else {
            try ctx.out.print(
                "  note       {s}: {s}: {s}; nothing to reconcile for it\n",
                .{ b.backend, b.probe, b.why },
            );
        }
    }

    var res: PackageReconcile = .{};
    const choices = [_]prompt.Choice{
        .{ .key = "y", .label = "add", .help = "record it in the manifest so every machine installs it" },
        .{ .key = "b", .label = "blacklist", .help = "never offer this package again" },
        .{ .key = "s", .label = "skip", .help = "leave it untracked for now" },
    };

    for (rep.backends) |b| {
        if (b.drift.untracked.len == 0) continue;
        const backend = registry.find(b.backend) orelse continue;
        var no_file_said = false;

        for (b.drift.untracked) |id| {
            if (report_only) {
                try ctx.out.print("  untracked  {s} {s}\n", .{ b.backend, id });
                res.skipped += 1;
                continue;
            }

            const target = (try mox.packages.write.targetFor(ctx.alloc, m, b.backend, bindings, .packages)) orelse {
                // Said once per backend: every untracked package of that
                // backend has the same missing file.
                if (!no_file_said) {
                    // In program order on the terminal: the reason before
                    // the summary that counts these as skipped.
                    try ctx.out.flush();
                    try ctx.err.print(
                        "mox commit: no data/packages file that holds on this machine declares backend \"{s}\"; add one to record its {d} untracked package(s)\n",
                        .{ b.backend, b.drift.untracked.len },
                    );
                    try ctx.err.flush();
                    no_file_said = true;
                }
                res.skipped += 1;
                continue;
            };

            try ctx.out.print("\nuntracked package: {s} {s}\n", .{ b.backend, id });
            const question = try prompt.renderChoices(ctx.alloc, &choices);
            const outcome = try prompt.ask(ask_mode, &choices, 2, question, input, ctx.out);
            const chosen = switch (outcome) {
                .chosen => |i| i,
                .report_only => {
                    res.skipped += 1;
                    continue;
                },
                .abort => {
                    res.aborted = true;
                    res.skipped += 1;
                    return res;
                },
                .abort_strict => {
                    res.aborted = true;
                    res.strict_abort = true;
                    res.skipped += 1;
                    return res;
                },
            };
            if (chosen == 2) {
                res.skipped += 1;
                continue;
            }

            const decl = backend.declare(ctx.alloc, id) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => {
                    // In program order on the terminal: the reason before
                    // the summary that counts this as skipped.
                    try ctx.out.flush();
                    try ctx.err.print(
                        "mox commit: {s} {s}: declare failed: {s}; record the row by hand\n",
                        .{ b.backend, id, mox.packages.exec.errorText(e) },
                    );
                    try ctx.err.flush();
                    res.skipped += 1;
                    continue;
                },
            };
            const array: mox.packages.write.Array = if (chosen == 0) .packages else .blacklist;
            // A blacklist holds on every machine, so it may not go in a gated
            // file: the row would refuse the manifest on the next command.
            const dest = if (array == .packages) target else (try mox.packages.write.targetFor(ctx.alloc, m, b.backend, bindings, .blacklist)) orelse {
                try ctx.out.flush();
                try ctx.err.print(
                    "mox commit: no ungated data/packages file declares backend \"{s}\"; a blacklist holds on every machine, so it needs a file with no top-level \"when\"\n",
                    .{b.backend},
                );
                try ctx.err.flush();
                res.skipped += 1;
                continue;
            };
            // The row about to be written is put through the same check the
            // loader applies to one already written: an adapter that answers
            // with a name its own rules refuse would have mox write a file
            // every later command rejects, and no mox command could repair
            // it.
            {
                var row_diag: mox.packages.manifest.Diag = .{};
                const candidate: mox.packages.manifest.Row = .{
                    .name = decl.name,
                    .backend = b.backend,
                    .fields = decl.fields,
                    .origin = dest.path,
                    .label = dest.label,
                    .index = 0,
                };
                backend.validate(candidate, &row_diag) catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    else => {
                        try ctx.out.flush();
                        const why = row_diag.capture() orelse @errorName(e);
                        try ctx.err.print(
                            "mox commit: {s} {s}: the row it declares would be refused: {s}\n",
                            .{ b.backend, id, why },
                        );
                        try ctx.err.flush();
                        res.skipped += 1;
                        continue;
                    },
                };
            }
            // The file's own default already names the backend; repeating it
            // on the row would be a second spelling of one fact.
            const needs_backend = dest.default_backend == null or
                !std.mem.eql(u8, dest.default_backend.?, b.backend);
            const block = try mox.packages.write.render(
                ctx.alloc,
                array,
                decl,
                if (needs_backend) b.backend else null,
            );
            try mox.packages.write.append(
                ctx.alloc,
                ctx.io,
                dest.path,
                try mox.packages.write.renderHeader(ctx.alloc, dest),
                block,
            );
            // The label already names the layer; saying it twice reads as a
            // stutter rather than as emphasis.
            if (chosen == 0) {
                res.added += 1;
                try ctx.out.print("  recorded in {s}\n", .{dest.label});
            } else {
                res.blacklisted += 1;
                try ctx.out.print("  blacklisted in {s}\n", .{dest.label});
            }
        }
    }
    return res;
}

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    return commitImpl(ctx, a.dry_run, a.yes, a.abort_on_prompt, a.color orelse .auto, a.paths);
}

/// The whole of `mox commit`, callable without an argv. Acquires the state
/// lock itself, exactly as the command does.
pub fn commitImpl(
    ctx: *app.Ctx,
    dry_run: bool,
    yes: bool,
    abort_on_prompt: bool,
    color: style.ColorFlag,
    paths: []const []const u8,
) anyerror!u8 {
    const context = ctx.context.?;
    const sty = style.Style{ .on = style.enabled(
        tty.isInteractive(1),
        context.env.get(ctx.alloc, "NO_COLOR") != null,
        color,
    ) };

    const lk = (try lock_mod.acquireForCommand(ctx, "commit")) orelse return 1;
    defer lk.release();

    // Routing a live edit back into a source that is itself mid-merge would
    // write over half-resolved content, so the same refusal apply makes.
    if (try mox.source.vcs.inProgress(ctx.alloc, ctx.io, context.paths.repo_dir)) |operation| {
        try ctx.err.print(
            "mox commit: {s} is part-way through a {s}; finish or abort it first (its sources are half-resolved)\n",
            .{ context.paths.repo_dir, operation },
        );
        return 1;
    }

    // A fact write in the write phase re-captures this, so a routed file's
    // recompose (later in this same run) sees the new value.
    var m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env, context.paths.repo_dir, context.paths.private_dir);
    var bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
    var live_ctx: mox.dsl.resolver.Resolver.Live = m_state.liveResolver(&bindings);
    var axis_resolver: mox.dsl.resolver.Resolver = .{ .live = &live_ctx };

    var secret_cache = mox.secret.cache.Cache.init(ctx.alloc);
    const secrets: mox.compose.catB.SecretCtx = .{ .env = context.env, .cache = &secret_cache };

    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    var walk_diag: mox.source.tree.Diag = .{};
    const base_tree = mox.source.tree.walkDiag(ctx.alloc, ctx.io, src_dir, m_state.home, &walk_diag) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.err.print("mox commit: source tree not found at {s}\n", .{src_dir});
            return 1;
        },
        error.OwnOnSymlink,
        error.OwnOnSeedOnce,
        error.OwnOnGenerator,
        error.OwnAndDisown,
        error.OwnPathOverlap,
        error.InvalidOwnPath,
        error.InvalidCheckDirective,
        error.CheckWithoutOwnership,
        => {
            try ctx.err.print("mox commit: ownership declaration: {s}: {s}\n", .{
                walk_diag.capture() orelse "?", mox.apply.owned.ownDiagText(e),
            });
            return 1;
        },
        error.UnknownAttributeKey,
        error.InvalidAttributeValue,
        => {
            try ctx.err.print("mox commit: attributes.toml: {s}: {s}\n", .{
                walk_diag.capture() orelse "?", mox.source.attributes.diagText(e),
            });
            return 1;
        },
        else => return e,
    };
    const tree = try mox.private.layer.merge(ctx.alloc, ctx.io, base_tree, context.paths.private_dir, m_state.home);

    // `bindings` is what every hypothetical configuration below clones
    // (cross-configuration verification, impact analysis); seed its static
    // tool=/env= literals now so those fixed clones see the same answer this
    // machine's live resolver does, instead of reading every one as unbound.
    const repo_ax = try mox.source.axes.ofManagedTree(ctx.alloc, ctx.io, tree);
    try mox.machine.bindings.seedStaticMultiValue(&bindings, repo_ax, axis_resolver);

    // A scoped commit routes only the named files: everything else is left
    // for a later `mox commit`, so `scoped_live` gates the main routing loop
    // rather than shrinking `tree.files` (which every fidx-indexed array
    // below is still sized against). A generator's OWN live path -- naming the
    // generator source itself in a scoped commit, rather than one of its
    // produced leaves -- resolves here like any other managed file; a
    // produced LEAF path does not (it is not in `tree.files` at all), so it is
    // tried separately below, against every generator's re-expanded output --
    // `scoped_leaves` then restricts that generator's keep to just the named
    // leaves instead of its whole set.
    var scoped_live: ?std.StringHashMap(void) = null;
    var scoped_leaves: ?std.StringHashMap(std.StringHashMap(void)) = null;
    if (paths.len > 0) {
        var direct: std.ArrayList([]const u8) = .empty;
        var leaf_targets: std.ArrayList([]const u8) = .empty;
        for (paths) |p| {
            const live = edit_mod.liveTarget(ctx.alloc, m_state.home, context.cwd, p) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => |f| return edit_mod.reportTarget(ctx.err, "mox commit", p, f),
            };
            if (findByLive(tree, live) != null) {
                try direct.append(ctx.alloc, p);
            } else {
                try leaf_targets.append(ctx.alloc, live);
            }
        }

        var diag: scope.Diag = .{};
        const scoped_files = scope.filterTree(ctx.alloc, ctx.io, tree.files, m_state.home, context.cwd, direct.items, &diag) catch |e| switch (e) {
            error.NotManaged => {
                try ctx.err.print("mox commit: {s}: not managed\n", .{diag.capture().?});
                if (diag.captureResolved()) |r|
                    try ctx.err.print("mox commit:   looked for {f}\n", .{display.of(r, m_state.home)});
                return 1;
            },
            error.OutOfMemory => return e,
            else => |f| return edit_mod.reportTarget(ctx.err, "mox commit", diag.capture().?, f),
        };
        var set: std.StringHashMap(void) = .init(ctx.alloc);
        for (scoped_files) |f| try set.put(f.live_path, {});

        if (leaf_targets.items.len > 0) {
            var leaves: std.StringHashMap(std.StringHashMap(void)) = .init(ctx.alloc);
            for (leaf_targets.items) |lp| {
                const gen = (try findGeneratorLeaf(ctx.alloc, ctx.io, tree.files, &axis_resolver, &m_state, secrets, lp)) orelse {
                    try ctx.err.print("mox commit: {f}: not managed\n", .{display.of(lp, m_state.home)});
                    return 1;
                };
                try set.put(gen.live_path, {});
                const gop = try leaves.getOrPut(gen.live_path);
                if (!gop.found_existing) gop.value_ptr.* = .init(ctx.alloc);
                // Store in key form so the membership check against a produced
                // leaf's `joinKeyOnto` path agrees on Windows (mixed separators).
                try gop.value_ptr.put(try mox.source.path.toKey(ctx.alloc, lp), {});
            }
            scoped_leaves = leaves;
        }
        scoped_live = set;
    }

    const scripted_input = app.stdin_override;
    // Strict CI: rc 2 for a prompt that WOULD have been needed. That is a fact
    // about the hunks, not about the terminal, so strict mode walks the
    // prompting path off a TTY too (`prompt.ask` aborts there instead of
    // reading) rather than short-circuiting into the report. `--dry-run` asks
    // nothing at all, so it stays a pure report.
    const strict = abort_on_prompt and !dry_run;
    const interactive = ((scripted_input != null or tty.isInteractive(0)) and !dry_run and !yes) or strict;
    const report_mode = dry_run or (!interactive and !yes);
    // `--yes` takes every default without reading input.
    const ask_mode: prompt.Mode = if (abort_on_prompt)
        .abort_on_prompt
    else if (yes)
        .assume_default
    else
        .interactive;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), ctx.io, &stdin_buf);
    const input: *Io.Reader = scripted_input orelse &stdin_reader.interface;

    // Packages are reconciled before the file pass and only for an unscoped
    // commit: `mox commit <path>` names files, and reaching past them to the
    // package manifest would be scope the user did not ask for.
    const pkgs = if (paths.len == 0)
        try reconcilePackages(ctx, context, &axis_resolver, m_state, ask_mode, input, report_mode)
    else
        PackageReconcile{};
    // A package row is appended the moment it is chosen, so an abort here
    // ends the run before the file pass and says exactly what was written.
    if (pkgs.strict_abort) {
        try ctx.err.print(
            "mox commit: --abort-on-prompt: a package prompt was required; {d} row(s) already recorded, no file changes written\n",
            .{pkgs.added + pkgs.blacklisted},
        );
        return 2;
    }
    if (pkgs.aborted) {
        try ctx.out.print(
            "mox commit: aborted; {d} package row(s) already recorded, no file changes written\n",
            .{pkgs.added + pkgs.blacklisted},
        );
        return 1;
    }

    var claims: Claims = .empty;

    const cc: ClassCtx = .{
        .arena = ctx.alloc,
        .io = ctx.io,
        .this_bindings = &bindings,
        .resolver = &axis_resolver,
        .m_state = &m_state,
        .secrets = secrets,
        .machine = mox.machine.bindings.firstLabel(m_state.hostname),
        .stdout = ctx.out,
        .err = ctx.err,
        .input = input,
        .ask_mode = ask_mode,
        .report_mode = report_mode,
        .interactive = interactive,
        .sty = sty,
        .claims = &claims,
    };

    var line_edits: std.ArrayList(LineEdit) = .empty;
    var row_edits: std.ArrayList(RowEdit) = .empty;
    var fact_edits: std.ArrayList(FactEdit) = .empty;
    var synth_plans: std.ArrayList(SynthDecision) = .empty;
    var struct_edits: std.ArrayList(StructEdit) = .empty;
    // Symlink-target and generator-leaf keep bypass the whole-file
    // affected[]/spaces[] machinery below: a symlink's source and a
    // generator's data source do not compose the way an ordinary managed file
    // does (composing a generator's own directive file the normal way is an
    // error, and a symlink's live path is not readable as a regular file's
    // content), so each accepted sync and each leaf is a unit of its own.
    var sym_syncs: std.ArrayList(SymSync) = .empty;
    var generated: LeafRowEdits = .{};
    // Index of the managed file each pending edit was routed from: the unit
    // that owns it.
    var line_owners: std.ArrayList(usize) = .empty;
    var row_owners: std.ArrayList(usize) = .empty;
    var fact_owners: std.ArrayList(usize) = .empty;
    var synth_owners: std.ArrayList(usize) = .empty;
    var struct_owners: std.ArrayList(usize) = .empty;
    const affected = try ctx.alloc.alloc(bool, tree.files.len);
    @memset(affected, false);
    // Per-file set of configuration labels the user chose to affect;
    // verification lets exactly these compose differently after the write.
    const allowed = try ctx.alloc.alloc(std.StringHashMap(void), tree.files.len);
    for (allowed) |*s| s.* = std.StringHashMap(void).init(ctx.alloc);
    // Per-file configuration space, built once (when first needed) and
    // reused for that file's own classification and verification.
    const spaces = try ctx.alloc.alloc(?FileSpace, tree.files.len);
    @memset(spaces, null);

    // Per-file tallies of the hunks that did NOT reach a source, which is what
    // tells an EXPECTED recompose mismatch from a broken routing. A manual hunk
    // is a designed outcome (a secret, an interpolation, a structural merge);
    // `declined_hunks` counts hunks the user deliberately left out this run (`n`
    // at the plain prompt, `s` at the candidate prompt) -- an equally ordinary,
    // designed outcome. A file with either cannot recompose to live no matter
    // how well its other hunks routed, and that is expected. `unrouted_hunks`
    // counts hunks the TOOL could not route to the candidate the user picked (no
    // automatic path, a hazard) -- not something the user asked for, so a file
    // with one is not committed whatever else holds. The diagnostics name
    // whichever caused it.
    const manual_hunks = try ctx.alloc.alloc(usize, tree.files.len);
    @memset(manual_hunks, 0);
    const declined_hunks = try ctx.alloc.alloc(usize, tree.files.len);
    @memset(declined_hunks, 0);
    const unrouted_hunks = try ctx.alloc.alloc(usize, tree.files.len);
    @memset(unrouted_hunks, 0);

    var pending = false;
    var manual_count: usize = 0;
    var routed_count: usize = 0;
    var skipped_secret: usize = 0;
    var aborted = false;
    var strict_abort = false;

    const ra: RunAccum = .{
        .line_edits = &line_edits,
        .line_owners = &line_owners,
        .row_edits = &row_edits,
        .row_owners = &row_owners,
        .fact_edits = &fact_edits,
        .fact_owners = &fact_owners,
        .synth_plans = &synth_plans,
        .synth_owners = &synth_owners,
        .struct_edits = &struct_edits,
        .struct_owners = &struct_owners,
        .affected = affected,
        .allowed = allowed,
        .manual_hunks = manual_hunks,
        .declined_hunks = declined_hunks,
        .unrouted_hunks = unrouted_hunks,
        .manual_count = &manual_count,
        .routed_count = &routed_count,
        .pending = &pending,
    };

    files: for (tree.files, 0..) |file, fidx| {
        if (scoped_live) |set| {
            if (!set.contains(file.live_path)) continue;
        }
        // A head declaration the walk could not honor: nothing of this file
        // can be routed; skip it with the diagnosis and keep committing.
        if (file.head_error.len > 0) {
            try ctx.err.print("mox commit: {f}: skipped ({s})\n", .{ display.of(file.live_path, m_state.home), file.head_error });
            continue;
        }

        // A generator (`for ... into`, or `completions`) fans out to a
        // produced LEAF SET instead of writing its own live path -- recognized
        // the same way apply recognizes it (composeGenerator's directive-shape
        // check), tried before any of the ordinary single-file gates below,
        // none of which apply to it.
        {
            var gdiag: mox.compose.interp.Diag = .{};
            const gen = mox.compose.catB.composeGenerator(ctx.alloc, ctx.io, file, &axis_resolver, &m_state, secrets, &gdiag) catch |e| {
                try ctx.err.print("mox commit: {f}: generator failed to re-expand: {s}\n", .{ display.of(file.live_path, m_state.home), @errorName(e) });
                continue;
            };
            if (gen) |outputs| {
                const only_leaves = if (scoped_leaves) |*m| m.getPtr(file.live_path) else null;
                switch (try processGeneratorFile(&cc, &ra, file, fidx, outputs, only_leaves, context.paths.state_dir, &generated)) {
                    .cont => {},
                    .abort => {
                        aborted = true;
                        break :files;
                    },
                    .abort_strict => {
                        strict_abort = true;
                        break :files;
                    },
                }
                continue;
            }
        }

        if (file.is_symlink) {
            switch (try processSymlinkFile(&cc, &ra, file, fidx, context.paths.state_dir, &sym_syncs)) {
                .cont => {},
                .abort => {
                    aborted = true;
                    break :files;
                },
                .abort_strict => {
                    strict_abort = true;
                    break :files;
                },
            }
            continue;
        }
        // Seed-once files carry no applied record and are user-owned after
        // creation; there is nothing to route back to their source.
        if (file.create_once) continue;

        // A partially owned file takes its own gate BEFORE the whole-file
        // applied-record gates: those records never exist for it, and partial
        // implies per-key routing -- the line route never applies.
        if (file.own_paths.len > 0) {
            switch (try processPartialFile(&cc, &ra, file, fidx, spaces, context.paths.repo_dir, context.paths.state_dir, &skipped_secret)) {
                .cont => {},
                .abort => {
                    aborted = true;
                    break :files;
                },
                .abort_strict => {
                    strict_abort = true;
                    break :files;
                },
            }
            continue;
        }

        const recorded = try mox.apply.applied.read(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path);
        // Kind guard BEFORE the open: a FIFO here would block the read and
        // brick the whole commit.
        if (mox.apply.write.guardLiveRead(ctx.io, file.live_path) == .special) {
            try ctx.err.print("mox commit: {f}: skipped (not a regular file)\n", .{display.of(file.live_path, m_state.home)});
            continue;
        }
        const live = Io.Dir.cwd().readFileAlloc(ctx.io, file.live_path, ctx.alloc, .limited(max_file_bytes)) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };

        if (recorded == null) {
            // No stored baseline at all: the repo has a source for this file,
            // but mox never wrote it here (first contact -- e.g. inherited
            // from another tool during a migration). `keep` is universal, so
            // this recomposes a fresh baseline instead of skipping outright.
            switch (try processFallbackFile(&cc, &ra, file, fidx, spaces, context.paths.repo_dir, live, .first_contact)) {
                .cont => {},
                .abort => {
                    aborted = true;
                    break :files;
                },
                .abort_strict => {
                    strict_abort = true;
                    break :files;
                },
            }
            continue;
        }

        const last_content = (try mox.apply.applied.readContent(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path)) orelse {
            // A record (content hash) exists, but a secret-bearing
            // composition's cleartext is deliberately never cached: recompose
            // to rebuild a verifiable baseline instead of skipping outright.
            switch (try processFallbackFile(&cc, &ra, file, fidx, spaces, context.paths.repo_dir, live, .{ .secret = recorded.? })) {
                .cont => {},
                .abort => {
                    aborted = true;
                    break :files;
                },
                .abort_strict => {
                    strict_abort = true;
                    break :files;
                },
            }
            continue;
        };
        // Only true drift (live != last-applied) is committable.
        if (std.mem.eql(u8, live, last_content)) continue;

        // A whole-file source that now composes to nothing (an emptied loop, a
        // gated-off region) has no file to route this edit into. The live copy
        // is the user's alone: say how to resolve it rather than routing bytes
        // nowhere, only for the recompose to reject them and roll back.
        if (file.own_paths.len == 0 and (mox.compose.composeFileTracked(ctx.alloc, ctx.io, file, &axis_resolver, &m_state, secrets, null, null) catch null) == null) {
            try ctx.err.print("mox commit: {f}: source yields no file; remove the live copy or add the data that filled it; not committed\n", .{display.of(file.live_path, m_state.home)});
            pending = true;
            continue;
        }

        var prov = (try mox.provenance.map.read(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path)) orelse {
            try ctx.out.print("  manual: {f} (no provenance recorded)\n", .{display.of(file.live_path, m_state.home)});
            manual_count += 1;
            manual_hunks[fidx] += 1;
            pending = true;
            continue;
        };
        // A structured file's persisted stamp may predate the current origin
        // rule (a base whose overlays never matched used to be stamped
        // `.overlay`), and routing by a stale stamp strands the file as manual
        // until its next apply. Recompose the current source: when it
        // reproduces the last-applied bytes exactly, the fresh stamp describes
        // the same content the persisted one does, provably -- so prefer it.
        // Any mismatch (source changed since the apply) keeps the persisted
        // stamp, which is the only honest description of what live came from.
        if (commit_struct.formatOfPath(file.source_base_path) != null) {
            var fresh: std.ArrayList(Segment) = .empty;
            if (mox.compose.composeFileTracked(ctx.alloc, ctx.io, file, &axis_resolver, &m_state, secrets, &fresh, null) catch null) |now| {
                if (std.mem.eql(u8, now, last_content)) prov.segments = fresh.items;
            }
        }

        const a_lines = try mox.diff.lines.splitLines(ctx.alloc, last_content);
        const b_lines = try mox.diff.lines.splitLines(ctx.alloc, live);
        const hunks = mox.diff.lines.diff(ctx.alloc, a_lines, b_lines) catch |e| switch (e) {
            error.TooManyLines => {
                try ctx.out.print("  manual: {f} (too large to diff)\n", .{display.of(file.live_path, m_state.home)});
                manual_count += 1;
                manual_hunks[fidx] += 1;
                pending = true;
                continue;
            },
            else => return e,
        };

        // A Cat-A file that merged overlays routes by key path over the
        // REPO-WIDE configuration space (a fall-through machine another file's
        // overlay reveals must be seen), so its FileSpace carries the repo-wide
        // configs. Stashing it in spaces[fidx] means baseline, snapshot, and the
        // guard all verify this file over that space with no guard-loop change.
        if (commit_struct.formatOfPath(file.source_base_path)) |sf| {
            if (containsOverlayOrigin(prov.segments)) {
                spaces[fidx] = try structFileSpace(ctx.alloc, ctx.io, &bindings, file, context.paths.repo_dir);
                switch (try processStructFile(&cc, &ra, file, fidx, spaces[fidx].?, sf, last_content, live, false)) {
                    .cont => {},
                    .abort => {
                        aborted = true;
                        break :files;
                    },
                    .abort_strict => {
                        strict_abort = true;
                        break :files;
                    },
                }
                continue;
            }
        }

        // Built once per file (from ITS OWN source, never a published
        // census) and reused across every hunk below.
        if (spaces[fidx] == null) spaces[fidx] = try fileSpace(ctx.alloc, ctx.io, &bindings, file);
        const space = spaces[fidx].?;

        var lf: LoopFile = .{ .file = file, .stored = true, .segments = prov.segments, .a_lines = a_lines, .b_lines = b_lines, .hunks = hunks };
        for (hunks, 0..) |hunk, hi| {
            // The stored-baseline path never carries a `.secret` segment (its
            // cleartext is never cached in the first place, so a secret-
            // bearing file never reaches here with a `last_content` to diff
            // against); `null` is inert.
            switch (try processHunk(&cc, &ra, file, fidx, space, prov.segments, a_lines, b_lines, hunk, hi + 1, hunks.len, null, false, &lf)) {
                .cont => {},
                .abort => {
                    aborted = true;
                    break :files;
                },
                .abort_strict => {
                    strict_abort = true;
                    break :files;
                },
            }
        }
    }

    if (strict_abort) {
        try ctx.err.writeAll("mox commit: --abort-on-prompt: a prompt was required; nothing written\n");
        return 2;
    }
    if (aborted) {
        try ctx.out.writeAll("mox commit: aborted; no changes written\n");
        return 1;
    }

    const coupling_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.state_dir, "coupling" });
    // Source paths by the file they name; see the canonicalization below.
    var ids: PathIds = .init(ctx.alloc, ctx.io);
    const protected = try protectedSourceSet(ctx.alloc, tree.files);
    const bases = try managedBases(ctx.alloc, tree.files);
    // Whether routed renames are offered to other sources; see F-coupling.
    const couples = scoped_live == null and line_edits.items.len > 0;
    const accepted: AcceptedTexts = if (couples)
        try acceptedTexts(ctx.alloc, ctx.io, &ids, tree.files, line_edits.items, row_edits.items, row_owners.items, &generated, synth_plans.items)
    else
        .init(ctx.alloc, &ids);

    if (report_mode) {
        // Report the coupling updates a real commit would offer for the routed
        // renames, honoring declines. Nothing is written; each pending update
        // counts toward the "edits remain" exit code.
        const coupled = if (couples) try reportCoupling(ctx.alloc, ctx.io, coupling_dir, line_edits.items, &accepted, bases, &protected, ctx.out, ctx.err) else 0;
        if (coupled > 0) pending = true;
        if (pkgs.pending()) pending = true;
        if (routed_count == 0 and manual_count == 0 and coupled == 0 and skipped_secret == 0 and !pkgs.pending()) {
            try ctx.out.writeAll("mox commit: nothing to commit\n");
        } else if (skipped_secret > 0) {
            try ctx.out.print(
                "\nmox commit: {d} routable, {d} coupled, {d} manual, {d} skipped (report only; run without --dry-run on a terminal to apply)\n",
                .{ routed_count, coupled, manual_count, skipped_secret },
            );
        } else {
            try ctx.out.print(
                "\nmox commit: {d} routable, {d} coupled, {d} manual (report only; run without --dry-run on a terminal to apply)\n",
                .{ routed_count, coupled, manual_count },
            );
        }
        return if (pending) 1 else 0;
    }

    // F-coupling: a token a routed edit changed may live in other managed
    // sources; offer to update them in the same write pass. Runs after routing
    // (final edits known) and before any write (abort still writes nothing). A
    // path-scoped commit routes only the named files and must not reach out to
    // couple other sources, so the whole pass is skipped when scoped.
    var coupling_edits: []const CouplingEdit = &.{};
    var coupling_origins: []const usize = &.{};
    if (couples) {
        const cres = try resolveCoupling(ctx.alloc, ctx.io, coupling_dir, line_edits.items, line_owners.items, &accepted, bases, &protected, ask_mode, input, ctx.out, ctx.err);
        if (cres.abort) aborted = true;
        if (cres.abort_strict) strict_abort = true;
        // A q-abort (or strict-mode prompt) must persist nothing: the decline
        // list is saved only when the command did not abort.
        if (cres.save_declines) try mox.coupling.store.saveDeclines(ctx.alloc, ctx.io, coupling_dir, &cres.declines);
        coupling_edits = cres.edits;
        coupling_origins = cres.origins;
    }

    if (strict_abort) {
        try ctx.err.writeAll("mox commit: --abort-on-prompt: a prompt was required; nothing written\n");
        return 2;
    }
    if (aborted) {
        try ctx.out.writeAll("mox commit: aborted; no changes written\n");
        return 1;
    }

    // Every edit's path by the file it names, so the journal, the plan, the
    // restores and the ownership rule see two spellings of one file as one
    // path. A coupled update's target is found by the path it was offered
    // for, which is a managed file's base as the tree spells it.
    for (line_edits.items) |*e| e.path = try ids.of(e.path);
    for ([_][]RowEdit{ row_edits.items, generated.row_edits.items }) |list| for (list) |*e| {
        e.data_source = try ids.of(e.data_source);
        const splices = try ctx.alloc.dupe(LineEdit, e.splices);
        for (splices) |*sp| sp.path = e.data_source;
        e.splices = splices;
    };
    for (sym_syncs.items) |*e| e.source_abs = try ids.of(e.source_abs);
    for (synth_plans.items) |*sd| {
        sd.base_abs = try ids.of(sd.base_abs);
        sd.plan.fragment_path = try ids.of(sd.plan.fragment_path);
    }
    for (struct_edits.items) |*e| e.layer_abs = try ids.of(e.layer_abs);
    // Each coupled update's targets, by its canonical path, and back: every
    // managed file whose base is that file, however it is linked.
    var coupling_targets = std.StringHashMap([]const usize).init(ctx.alloc);
    const target_path = try ctx.alloc.alloc(?[]const u8, tree.files.len);
    @memset(target_path, null);
    if (coupling_edits.len > 0) {
        const canonical = try ctx.alloc.alloc(CouplingEdit, coupling_edits.len);
        const coupled_paths = try ctx.alloc.alloc([]const u8, coupling_edits.len);
        for (coupling_edits, canonical, coupled_paths) |e, *c, *p| {
            c.* = .{ .path = try ids.of(e.path), .old = e.old, .new = e.new };
            p.* = c.path;
        }
        coupling_edits = canonical;
        for (tree.files, target_path) |f, *tp| {
            if (!f.has_base or f.source_base_abs.len == 0) continue;
            const base = try ids.canonical(f.source_base_abs);
            if (isOneOf(base, coupled_paths)) tp.* = base;
        }
        for (coupled_paths) |path| {
            const gop = try coupling_targets.getOrPut(path);
            if (gop.found_existing) continue;
            var targets: std.ArrayList(usize) = .empty;
            for (target_path, 0..) |tp, fidx| {
                if (tp != null and std.mem.eql(u8, tp.?, path)) try targets.append(ctx.alloc, fidx);
            }
            gop.value_ptr.* = targets.items;
        }
    }

    // Coupling edits rewrite other managed sources. Each target is composed
    // with the accepted renames alone, in every configuration, before anything
    // is planned: renames that leave it unable to compose on this machine, or
    // whose source cannot be read or transiently written, are dropped and
    // reported undone. A target that routed nothing of its own is
    // a unit of its own: its recompose need not equal live (apply refreshes
    // it), but its source must still compose and the sync must not diverge a
    // configuration the user did not choose, so the configurations a universal
    // token sync changes are allowed and a subset divergence is caught.
    var journal: Journal = .init(ctx.alloc);
    const coupling_only = try ctx.alloc.alloc(bool, tree.files.len);
    @memset(coupling_only, false);
    const coupling_into = try ctx.alloc.alloc(bool, tree.files.len);
    @memset(coupling_into, false);
    const coupling_baseline = try ctx.alloc.alloc([]const impact.ConfigOutput, tree.files.len);
    // Why each target's simulation failed, if it did.
    const sim_failed = try ctx.alloc.alloc(?[]const u8, tree.files.len);
    @memset(sim_failed, null);
    var dropped_paths: std.ArrayList([]const u8) = .empty;
    for (tree.files, 0..) |file, fidx| {
        const path = target_path[fidx] orelse continue;
        const file_edits = try couplingEditsForPath(ctx.alloc, coupling_edits, path);
        if (spaces[fidx] == null) spaces[fidx] = try fileSpace(ctx.alloc, ctx.io, &bindings, file);
        const space = spaces[fidx].?;
        const sim = switch (try simulateCouplingImpact(&cc, file, file.source_base_abs, file_edits, space.configs)) {
            .uncomposable, .unwritable => |e, tag| {
                const what = if (tag == .uncomposable) "recompose failed: " else "";
                sim_failed[fidx] = try std.fmt.allocPrint(ctx.alloc, "{s}{s}", .{ what, @errorName(e) });
                if (!isOneOf(path, dropped_paths.items)) try dropped_paths.append(ctx.alloc, path);
                continue;
            },
            .impact => |sim| sim,
        };
        coupling_into[fidx] = true;
        if (affected[fidx]) continue;
        coupling_only[fidx] = true;
        coupling_baseline[fidx] = sim.before;
        // A sibling where the file composes to nothing before and after
        // cannot change.
        if (sim.impact.affected.len >= sim.present_siblings) {
            for (sim.impact.affected) |label| try allowed[fidx].put(label, {});
        }
    }
    const coupling_dropped = try droppedCouplingLines(ctx.alloc, tree.files, target_path, sim_failed, dropped_paths.items, m_state.home);
    if (dropped_paths.items.len > 0) {
        var kept_edits: std.ArrayList(CouplingEdit) = .empty;
        var kept_origins: std.ArrayList(usize) = .empty;
        for (coupling_edits, coupling_origins) |e, origin| {
            if (isOneOf(e.path, dropped_paths.items)) continue;
            try kept_edits.append(ctx.alloc, e);
            try kept_origins.append(ctx.alloc, origin);
        }
        coupling_edits = kept_edits.items;
        coupling_origins = kept_origins.items;
    }

    // Every planned edit with the units that produced it; identical edits
    // are one. A coupled update is owned by the files whose line edits
    // produced its rename; the file whose base it rewrites is its target.
    // A row write is its field splices, planned with the line splices, so an
    // identical write from two loops, a loop and a leaf, or a loop and the
    // data file's own line edit is one edit owned by both.
    var planned_lines: std.ArrayList(Owned(LineEdit)) = .empty;
    for (line_edits.items, line_owners.items) |e, owner| try addOwned(LineEdit, ctx.alloc, &planned_lines, e, &.{.{ .file = owner }}, lineEditEql);
    for (row_edits.items, row_owners.items) |e, owner| for (e.splices) |sp| {
        try addOwned(LineEdit, ctx.alloc, &planned_lines, sp, &.{.{ .file = owner }}, lineEditEql);
    };
    for (generated.row_edits.items, generated.row_leaves.items) |e, li| for (e.splices) |sp| {
        try addOwned(LineEdit, ctx.alloc, &planned_lines, sp, &.{.{ .leaf = li }}, lineEditEql);
    };
    var planned_structs: std.ArrayList(Owned(StructEdit)) = .empty;
    for (struct_edits.items, struct_owners.items) |e, owner| try addOwned(StructEdit, ctx.alloc, &planned_structs, e, &.{.{ .file = owner }}, structEditEql);
    var planned_couplings: std.ArrayList(Owned(CouplingEdit)) = .empty;
    for (coupling_edits, coupling_origins) |e, origin| try addOwned(CouplingEdit, ctx.alloc, &planned_couplings, e, &.{.{ .file = origin }}, couplingEditEql);
    // Syncs are not merged: each symlink's sync writes its own source.
    var planned_syms: std.ArrayList(Owned(SymSync)) = .empty;
    for (sym_syncs.items, 0..) |e, i| {
        var owners: std.ArrayList(Unit) = .empty;
        try owners.append(ctx.alloc, .{ .symlink = i });
        try planned_syms.append(ctx.alloc, .{ .edit = e, .owners = owners });
    }

    // Whether a file's own changes wrote anything (a source or a fact), as
    // distinct from a coupled update another file's edit made to it.
    const wrote_own = try ctx.alloc.alloc(bool, tree.files.len);
    @memset(wrote_own, false);
    for (planned_lines.items) |o| for (o.owners.items) |u| switch (u) {
        .file => |i| wrote_own[i] = true,
        else => {},
    };
    for (planned_structs.items) |o| for (o.owners.items) |u| {
        wrote_own[u.file] = true;
    };
    for (synth_owners.items) |owner| wrote_own[owner] = true;
    for (fact_owners.items) |owner| wrote_own[owner] = true;

    // Every written path, journaled before any write.
    for (planned_lines.items) |o| try journal.record(ctx.alloc, ctx.io, o.edit.path);
    for (planned_syms.items) |o| try journal.record(ctx.alloc, ctx.io, o.edit.source_abs);
    for (synth_plans.items) |sd| {
        try journal.record(ctx.alloc, ctx.io, sd.base_abs);
        try journal.record(ctx.alloc, ctx.io, sd.plan.fragment_path);
    }
    for (planned_structs.items) |o| try journal.record(ctx.alloc, ctx.io, o.edit.layer_abs);
    if (fact_edits.items.len > 0) try journal.record(ctx.alloc, ctx.io, context.paths.facts_path);

    // Plan: every prompt is done, so each written path's final bytes are
    // computed in memory from its journaled pre-run bytes, threading its
    // edits in write order: line splices and row writes in one pass, symlink
    // targets, narrowings, coupling renames, struct keys.
    //
    // A narrowing's region block is a line SPLICE of the base like any other
    // edit, so a base with narrowings takes its ordinary line edits and every
    // region block together, in one splice. A universal hunk and a narrowed
    // hunk in one file therefore both land, and neither reverts the other.
    var plan: WritePlan = .{ .paths = .empty, .journal = &journal };
    const synth_bases = try synthBases(ctx.alloc, synth_plans.items);
    var spliced: std.ArrayList([]const u8) = .empty;
    for (planned_lines.items) |o| {
        const path = o.edit.path;
        if (isOneOf(path, synth_bases) or isOneOf(path, spliced.items)) continue;
        try spliced.append(ctx.alloc, path);
        var file_edits: std.ArrayList(LineEdit) = .empty;
        for (planned_lines.items) |fe| {
            if (std.mem.eql(u8, fe.edit.path, path)) try file_edits.append(ctx.alloc, fe.edit);
        }
        try plan.set(ctx.alloc, path, try splicedContent(ctx.alloc, try plan.bytesOf(ctx.alloc, path), file_edits.items));
    }
    for (planned_syms.items) |o| try plan.set(ctx.alloc, o.edit.source_abs, try std.fmt.allocPrint(ctx.alloc, "{s}\n", .{o.edit.new_target}));
    for (synth_bases) |base_abs| {
        var splices: std.ArrayList(LineEdit) = .empty;
        for (planned_lines.items) |o| {
            if (std.mem.eql(u8, o.edit.path, base_abs)) try splices.append(ctx.alloc, o.edit);
        }
        for (synth_plans.items) |sd| {
            if (!std.mem.eql(u8, sd.base_abs, base_abs)) continue;
            try splices.append(ctx.alloc, .{
                .path = base_abs,
                .start = sd.plan.start,
                .del = sd.plan.del,
                .new_lines = sd.plan.base_lines,
            });
        }
        try plan.set(ctx.alloc, base_abs, try splicedContent(ctx.alloc, try plan.bytesOf(ctx.alloc, base_abs), splices.items));
        for (synth_plans.items) |sd| {
            if (std.mem.eql(u8, sd.base_abs, base_abs)) try plan.set(ctx.alloc, sd.plan.fragment_path, sd.plan.fragment_content);
        }
    }

    // A coupled update that changes nothing in its path's bytes as planned so
    // far (the target's own edit already made it) is not an edit: it has no
    // owners, is journaled and written by nothing, and is never undone.
    for (planned_couplings.items) |*o| {
        const path = o.edit.path;
        const bytes: ?[]const u8 = plan.get(path) orelse if (journal.entries.get(path)) |b|
            b.content
        else
            Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .limited(max_file_bytes)) catch null;
        if (bytes) |b| {
            if (std.mem.eql(u8, b, try replaceTokens(ctx.alloc, b, &.{o.edit}))) {
                o.owners.clearRetainingCapacity();
                continue;
            }
        }
        try journal.record(ctx.alloc, ctx.io, path);
    }
    // A file no update reaches, or only no-op ones (its renames dropped
    // before planning included), is no coupling target.
    for (target_path, coupling_into, coupling_only) |tp, *into, *only| {
        const path = tp orelse continue;
        const reached = for (planned_couplings.items) |o| {
            if (o.owners.items.len > 0 and std.mem.eql(u8, o.edit.path, path)) break true;
        } else false;
        if (reached) continue;
        into.* = false;
        only.* = false;
    }

    // Whether each coupling target composed to nothing on this machine before
    // anything was written: a source gated off here composes to nothing after
    // a coupled update too, and that is not the update's doing.
    const null_before = try ctx.alloc.alloc(bool, tree.files.len);
    @memset(null_before, false);
    for (tree.files, 0..) |file, fidx| {
        if (!coupling_into[fidx]) continue;
        const before = impact.composeAsApply(ctx.alloc, ctx.io, file, &axis_resolver, &m_state, secrets) catch continue;
        null_before[fidx] = before == null;
    }

    // Baseline: each touched file's per-configuration compose BEFORE writing,
    // so verification can prove routing changed only the configurations the
    // user chose. Each file's configuration space was built once, from its
    // own source, when it was first classified above.
    const baseline = try ctx.alloc.alloc([]const impact.ConfigOutput, tree.files.len);
    for (tree.files, 0..) |file, fidx| {
        if (!affected[fidx] and !coupling_only[fidx]) continue;
        const space = spaces[fidx].?;
        baseline[fidx] = if (coupling_only[fidx])
            coupling_baseline[fidx]
        else
            (try impact.snapshot(ctx.alloc, ctx.io, file, space.configs, &m_state, secrets)).per_config;
        // A partial file's per-configuration snapshot is the CANONICAL OWNED
        // serialization of that configuration's compose, so the guard compares
        // owned content, never text layout. Pre-existing own-declaration
        // violations are ignored here; only the post-write pass acts on them.
        if (file.own_paths.len > 0) {
            baseline[fidx] = (try partialPerConfig(ctx.alloc, space.configs, baseline[fidx], file)).per;
        }
        // A sibling configuration whose source will not compose cannot be
        // verified against. Name it, the file, and why -- the guard then holds
        // it harmless (it was already broken) instead of the run dying on a
        // bare error that identifies neither the file nor the layer.
        for (space.configs, baseline[fidx]) |cfg, out| {
            if (out != .uncomposable) continue;
            try ctx.err.print(
                "mox commit: {s}: configuration {s} does not compose ({s}); it cannot be verified -- fix that layer, then re-run\n",
                .{ file.live_path, cfg.label, out.uncomposable },
            );
        }
    }

    // Every rename into one path is applied in one pass over its tokens, so
    // one rename never renames another's result.
    var coupled: std.ArrayList([]const u8) = .empty;
    for (planned_couplings.items) |o| {
        const path = o.edit.path;
        if (o.owners.items.len == 0 or isOneOf(path, coupled.items)) continue;
        try coupled.append(ctx.alloc, path);
        var renames: std.ArrayList(CouplingEdit) = .empty;
        for (planned_couplings.items) |fo| {
            if (fo.owners.items.len > 0 and std.mem.eql(u8, fo.edit.path, path)) try renames.append(ctx.alloc, fo.edit);
        }
        try plan.set(ctx.alloc, path, try replaceTokens(ctx.alloc, try plan.bytesOf(ctx.alloc, path), renames.items));
    }
    // A layer that refuses its key fails the files that edit was routed from,
    // and the edit is left out; settling below restores their sources.
    //
    // A backstop, not the usual path: `recordStructPlacement` simulates each
    // placement by applying it for real and restoring, so a layer that will not
    // take the edit is normally caught at prompt time and reported per key.
    // Reaching here means the source changed under the run, which no test can
    // trigger deterministically.
    const struct_failed = try ctx.alloc.alloc(?[]const u8, tree.files.len);
    @memset(struct_failed, null);
    for (planned_structs.items) |o| {
        const live_owner = for (o.owners.items) |owner| {
            if (struct_failed[owner.file] == null) break true;
        } else false;
        if (!live_owner) continue;
        const pp = try plan.slot(ctx.alloc, o.edit.layer_abs);
        pp.make_parent = true;
        pp.bytes = commit_struct.layerBytes(ctx.alloc, o.edit.format, pp.bytes, o.edit.change) catch |err| {
            for (o.owners.items) |owner| {
                if (struct_failed[owner.file] == null) struct_failed[owner.file] = @errorName(err);
            }
            continue;
        };
    }

    // Write phase: each planned path once. A base with narrowings is written
    // by `synth.materialize`, together with the fragments it creates.
    for (plan.paths.items) |pp| {
        if (isOneOf(pp.path, synth_bases)) {
            var plans: std.ArrayList(mox.classify.synth.Plan) = .empty;
            for (synth_plans.items) |sd| {
                if (!std.mem.eql(u8, sd.base_abs, pp.path)) continue;
                var fp = sd.plan;
                fp.fragment_content = plan.get(fp.fragment_path).?;
                try plans.append(ctx.alloc, fp);
            }
            try mox.classify.synth.materialize(ctx.alloc, ctx.io, pp.path, pp.bytes.?, plans.items, ctx.err);
            continue;
        }
        if (isSynthFragment(pp.path, synth_plans.items)) continue;
        const bytes = pp.bytes orelse continue;
        if (pp.make_parent) {
            if (std.fs.path.dirname(pp.path)) |parent| try Io.Dir.cwd().createDirPath(ctx.io, parent);
        }
        try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = pp.path, .data = bytes });
    }
    try applyFactEdits(ctx.alloc, ctx.io, context.paths.facts_path, fact_edits.items);
    // A fact write changes what `<machine.X>` interpolation resolves to for
    // EVERY file recomposed below, this routed file included: re-capture so
    // verification sees the new value instead of the one this run started
    // with.
    if (fact_edits.items.len > 0) {
        m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env, context.paths.repo_dir, context.paths.private_dir);
        bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
        live_ctx = m_state.liveResolver(&bindings);
        // The fresh `bindings` map above starts unseeded again.
        try mox.machine.bindings.seedStaticMultiValue(&bindings, repo_ax, axis_resolver);
    }

    // Verify every unit against the disk as it now stands. Rewalk first so
    // region synthesis (new fragments/regions) is reflected.
    var v: Verifier = .{
        .arena = ctx.alloc,
        .io = ctx.io,
        .err = ctx.err,
        .files = tree.files,
        .tree_now = try walkMerged(ctx.alloc, ctx.io, src_dir, context.paths.private_dir, m_state.home),
        .m_state = &m_state,
        .resolver = &axis_resolver,
        .secrets = secrets,
        .spaces = spaces,
        .baseline = baseline,
        .allowed = allowed,
        .coupling_only = coupling_only,
        .coupling_into = coupling_into,
        .null_before = null_before,
        .wrote_own = wrote_own,
        .manual_hunks = manual_hunks,
        .declined_hunks = declined_hunks,
        .unrouted_hunks = unrouted_hunks,
        .struct_failed = struct_failed,
        .struct_edits = struct_edits.items,
        .struct_owners = struct_owners.items,
        .sym_syncs = sym_syncs.items,
        .leaves = generated.leaves.items,
        .file_unit = try ctx.alloc.alloc(bool, tree.files.len),
        .file_failed = try ctx.alloc.alloc(bool, tree.files.len),
        .sym_failed = try ctx.alloc.alloc(bool, sym_syncs.items.len),
        .leaf_failed = try ctx.alloc.alloc(bool, generated.leaves.items.len),
        .file_reason = try ctx.alloc.alloc([]const u8, tree.files.len),
        .file_res = try ctx.alloc.alloc(FileResult, tree.files.len),
        .leaf_res = try ctx.alloc.alloc(LeafResult, generated.leaves.items.len),
    };
    for (v.file_unit, affected, coupling_only) |*u, r, c| u.* = r or c;
    @memset(v.file_failed, false);
    @memset(v.sym_failed, false);
    @memset(v.leaf_failed, false);
    @memset(v.file_reason, "");
    @memset(v.file_res, .{});
    @memset(v.leaf_res, .{});
    // Each planned coupled update's undone lines, one per target, once its
    // path is restored.
    const coupling_undone = try ctx.alloc.alloc(?[]const []const u8, planned_couplings.items.len);
    @memset(coupling_undone, null);
    const undone_by: UndoneBy = .{
        .couplings = planned_couplings.items,
        .targets = &coupling_targets,
        .unrouted = unrouted_hunks,
    };
    // Each coupling target failing its first verification whose own line
    // was held back for its coupled update's undone line.
    const quiet_fail = try ctx.alloc.alloc(bool, tree.files.len);
    @memset(quiet_fail, false);
    for (try v.verifyPassing()) |f| {
        if (undone_by.reports(f.unit)) {
            quiet_fail[f.unit.file] = true;
        } else {
            try ctx.err.writeAll(f.diag);
        }
    }

    // Settle. An edit none of whose owners passes, or a coupled update whose
    // target fails, is dead: the path it wrote is restored whole, and every
    // unit owning a non-coupling edit to that path fails with it. Facts no
    // passing unit routed are reverted. Every unit still passing is then
    // verified again, since it may read what was restored; repeat until a
    // round fails nothing new.
    const writes = try ownedWrites(ctx.alloc, planned_lines.items, planned_structs.items, synth_plans.items, synth_owners.items, planned_syms.items);
    // Each restored path, with the unit whose failure restored it.
    var restore_cause = std.StringHashMap(Unit).init(ctx.alloc);
    // Each journaled path already back at its pre-run bytes.
    var at_pre_run = std.StringHashMap(void).init(ctx.alloc);
    var reverted = std.StringHashMap(void).init(ctx.alloc);
    while (true) {
        var batch: std.ArrayList([]const u8) = .empty;
        for (writes) |w| try markDead(ctx.alloc, &v, &batch, &restore_cause, w.path, w.owners);
        for (planned_couplings.items) |o| {
            if (o.owners.items.len == 0) continue;
            if (failedTarget(&v, coupling_targets.get(o.edit.path).?)) |target| {
                try markDead(ctx.alloc, &v, &batch, &restore_cause, o.edit.path, &.{.{ .file = target }});
            } else {
                try markDead(ctx.alloc, &v, &batch, &restore_cause, o.edit.path, o.owners.items);
            }
        }
        // Each coupled update into a path restored now is undone, for the
        // cause that holds at this point.
        for (planned_couplings.items, coupling_undone) |o, *undone| {
            if (o.owners.items.len == 0 or undone.* != null or !isOneOf(o.edit.path, batch.items)) continue;
            const targets = coupling_targets.get(o.edit.path).?;
            const failed_target = failedTarget(&v, targets);
            var lines: std.ArrayList([]const u8) = .empty;
            for (targets) |target| {
                const t_live = display.of(tree.files[target].live_path, m_state.home);
                // A failed target's reason is given here only when its own
                // line was held back for it; a target with routed edits of its
                // own is named as not committed too. A target that passed
                // lost the update to the one that failed.
                try lines.append(ctx.alloc, if (v.file_failed[target] and !quiet_fail[target])
                    try std.fmt.allocPrint(ctx.alloc, "coupled update to {f} undone: {f} was not committed", .{ t_live, t_live })
                else if (v.file_failed[target])
                    try std.fmt.allocPrint(ctx.alloc, "coupled update to {f} undone: {f} could not take it ({s}){s}", .{
                        t_live,
                        t_live,
                        v.file_reason[target],
                        if (wrote_own[target]) try std.fmt.allocPrint(ctx.alloc, "; {f} not committed", .{t_live}) else "",
                    })
                else if (failed_target) |ft|
                    try std.fmt.allocPrint(ctx.alloc, "coupled update to {f} undone: {f} was not committed", .{ t_live, display.of(tree.files[ft].live_path, m_state.home) })
                else if (v.allFailed(o.owners.items))
                    try std.fmt.allocPrint(ctx.alloc, "coupled update to {f} undone: {f} was not committed", .{ t_live, display.of(v.unitLive(o.owners.items[0]), m_state.home) })
                else
                    try std.fmt.allocPrint(ctx.alloc, "coupled update to {f} undone: {f} was restored because {f} was not committed", .{
                        t_live,
                        display.of(ids.shown(o.edit.path), m_state.home),
                        display.of(v.unitLive(restore_cause.get(o.edit.path).?), m_state.home),
                    }));
            }
            undone.* = lines.items;
        }

        // Every restore due is attempted, even after one fails.
        var any_deleted = false;
        var failures: std.ArrayList(RestoreFailure) = .empty;
        for (batch.items) |p| {
            journal.restore(ctx.io, p) catch |e| {
                try failures.append(ctx.alloc, .{ .path = p, .cause = e });
                continue;
            };
            try at_pre_run.put(p, {});
            if (journal.entries.get(p).?.content == null) any_deleted = true;
        }
        // A unit owning a non-coupling edit to a restored path fails with it.
        // After a failed restore nothing is recorded, so no line is printed,
        // but the facts due this round are still settled.
        var new_fail = false;
        for (batch.items) |p| {
            const cause = restore_cause.get(p).?;
            for (writes) |w| {
                if (!std.mem.eql(u8, w.path, p)) continue;
                for (w.owners) |u| {
                    if (v.failed(u)) continue;
                    const reason = try std.fmt.allocPrint(ctx.alloc, "{f} was restored because {f} was not committed", .{
                        display.of(ids.shown(p), m_state.home),
                        display.of(v.unitLive(cause), m_state.home),
                    });
                    if (failures.items.len == 0) try printNotCommitted(ctx.err, v.unitLive(u), reason, m_state.home);
                    v.fail(u, reason);
                    new_fail = true;
                }
            }
        }

        // Facts: with no passing unit routing any fact, the facts file goes
        // back to its pre-run bytes; otherwise each fact no passing unit
        // routed is reverted by name.
        var fact_causes: std.ArrayList([]const u8) = .empty;
        var fact_names: std.ArrayList([]const u8) = .empty;
        if (fact_edits.items.len > 0 and !at_pre_run.contains(context.paths.facts_path)) {
            const any_kept = for (fact_edits.items) |fe| {
                if (factKept(&v, fact_edits.items, fact_owners.items, fe.name)) break true;
            } else false;
            for (fact_edits.items, 0..) |fe, fi| {
                if (reverted.contains(fe.name) or factKept(&v, fact_edits.items, fact_owners.items, fe.name)) continue;
                try reverted.put(fe.name, {});
                if (any_kept) {
                    revertFact(ctx.alloc, ctx.io, context.paths.facts_path, fe) catch |e| {
                        try failures.append(ctx.alloc, .{ .path = context.paths.facts_path, .cause = e });
                        break;
                    };
                }
                try fact_names.append(ctx.alloc, fe.name);
                try fact_causes.append(ctx.alloc, try std.fmt.allocPrint(ctx.alloc, "fact {s} was reverted because {f} was not committed", .{
                    fe.name,
                    display.of(tree.files[fact_owners.items[fi]].live_path, m_state.home),
                }));
            }
            if (!any_kept) restored: {
                journal.restore(ctx.io, context.paths.facts_path) catch |e| {
                    try failures.append(ctx.alloc, .{ .path = context.paths.facts_path, .cause = e });
                    break :restored;
                };
                try at_pre_run.put(context.paths.facts_path, {});
            }
        }
        if (failures.items.len > 0) {
            try saveRecovery(ctx, &journal, &ids, &at_pre_run, failures.items, m_state.home);
            return 2;
        }
        const fact_changed = fact_causes.items.len > 0;

        if (any_deleted) v.tree_now = try walkMerged(ctx.alloc, ctx.io, src_dir, context.paths.private_dir, m_state.home);
        // What facts resolved to before this round's reverts, to tell a unit
        // the reverts failed from one that failed for a restored path.
        var prev_state = m_state;
        var prev_bindings = bindings;
        var prev_live = prev_state.liveResolver(&prev_bindings);
        const prev_resolver: mox.dsl.resolver.Resolver = .{ .live = &prev_live };
        if (fact_changed) {
            m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env, context.paths.repo_dir, context.paths.private_dir);
            bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
            live_ctx = m_state.liveResolver(&bindings);
            try mox.machine.bindings.seedStaticMultiValue(&bindings, repo_ax, axis_resolver);
        }
        // A unit failing now prints one line: the reverted facts it reads,
        // when it passes under the facts as they were before this round's
        // reverts, or else its own diagnostic. A coupling target failing
        // here failed for what settling undid, so its own line prints too.
        if (batch.items.len > 0 or fact_changed) {
            for (try v.verifyPassing()) |f| {
                new_fail = true;
                if (fact_changed and try v.passesUnder(f.unit, &prev_state, &prev_resolver)) {
                    // Compose tracks no fact reads, so a fact counts as read
                    // when reverting it alone, from the facts before this
                    // round, fails the unit. When no single revert does, every
                    // one reverted this round is named.
                    var read: std.ArrayList([]const u8) = .empty;
                    if (fact_names.items.len > 1) for (fact_names.items, fact_causes.items) |name, cause| {
                        var one = try withFactOf(ctx.alloc, prev_state, name, m_state);
                        var one_bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, one);
                        try mox.machine.bindings.seedStaticMultiValue(&one_bindings, repo_ax, axis_resolver);
                        var one_live = one.liveResolver(&one_bindings);
                        const one_resolver: mox.dsl.resolver.Resolver = .{ .live = &one_live };
                        if (!try v.passesUnder(f.unit, &one, &one_resolver)) try read.append(ctx.alloc, cause);
                    };
                    const reason = try std.mem.join(ctx.alloc, "; ", if (read.items.len > 0) read.items else fact_causes.items);
                    try printNotCommitted(ctx.err, v.unitLive(f.unit), reason, m_state.home);
                    v.fail(f.unit, reason);
                } else {
                    try ctx.err.writeAll(f.diag);
                }
            }
        }
        if (!new_fail) break;
    }

    // Record every unit still passing, in order: symlinks, generator leaves,
    // then files by index. No source is written from here on.
    var mismatch = false;
    var committed_count: usize = 0;
    for (sym_syncs.items, v.sym_failed) |s, failed| {
        if (failed) {
            mismatch = true;
            continue;
        }
        try mox.apply.applied.recordSymlink(ctx.alloc, ctx.io, context.paths.state_dir, s.live_path, s.new_target);
        try ctx.out.print("  committed {f}\n", .{display.of(s.live_path, m_state.home)});
        committed_count += 1;
    }
    for (generated.leaves.items, v.leaf_failed, v.leaf_res) |gc, failed, r| {
        if (failed) {
            mismatch = true;
            continue;
        }
        try mox.apply.applied.record(ctx.alloc, ctx.io, context.paths.state_dir, gc.leaf_live_path, r.live);
        if (!r.secret) try mox.apply.applied.recordContent(ctx.alloc, ctx.io, context.paths.state_dir, gc.leaf_live_path, r.live);
        try mox.provenance.map.persist(ctx.alloc, ctx.io, context.paths.state_dir, gc.leaf_live_path, r.prov);
        try ctx.out.print("  committed {f}\n", .{display.of(gc.leaf_live_path, m_state.home)});
        committed_count += 1;
    }
    for (tree.files, 0..) |file, fidx| {
        if (!v.file_unit[fidx]) continue;
        if (v.file_failed[fidx]) {
            mismatch = true;
            continue;
        }
        // A coupling-only target synced safely; its applied record advances
        // at the next apply.
        if (coupling_only[fidx]) continue;
        const r = v.file_res[fidx];
        switch (r.check) {
            // A file whose every change stayed manual or declined wrote
            // nothing, so its source composing to nothing here is how it
            // already stood, not something the routing did.
            .composes_to_nothing => {
                mismatch = true;
                try reportUnrouted(ctx.err, file.live_path, manual_hunks[fidx], declined_hunks[fidx], false);
            },
            // The held hunks stay only in live, so the applied record does
            // not advance; the routed edits stand. A `[f]` route writes a
            // fact rather than a source, and it counts as routed here too.
            .held => {
                mismatch = true;
                try reportUnrouted(ctx.err, file.live_path, manual_hunks[fidx], declined_hunks[fidx], wrote_own[fidx]);
                if (wrote_own[fidx]) {
                    try ctx.out.print("  committed {f}\n", .{display.of(file.live_path, m_state.home)});
                    committed_count += 1;
                }
            },
            .exact => {
                if (file.own_paths.len > 0) {
                    // The OWNED record advances; whole-file records never
                    // exist for a partial target, and partial files persist
                    // no line provenance.
                    try advanceOwnedRecord(ctx, file, r.composed, r.prov);
                } else {
                    try mox.apply.applied.record(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path, r.live);
                    // Never cache the cleartext of a secret-bearing composition.
                    if (!mox.provenance.map.hasSecret(r.prov)) {
                        try mox.apply.applied.recordContent(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path, r.live);
                    }
                    try mox.provenance.map.persist(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path, r.prov);
                }
                try ctx.out.print("  committed {f}\n", .{display.of(file.live_path, m_state.home)});
                committed_count += 1;
            },
        }
    }
    for (coupling_dropped) |m| {
        mismatch = true;
        try ctx.err.print("mox commit: {s}\n", .{m});
    }
    // An undone line is printed once, however many renames it covers.
    var undone_said = std.StringHashMap(void).init(ctx.alloc);
    for (coupling_undone) |lines| {
        for (lines orelse continue) |m| {
            mismatch = true;
            if ((try undone_said.getOrPut(m)).found_existing) continue;
            try ctx.err.print("mox commit: {s}\n", .{m});
        }
    }

    // Re-index the coupling graph from the final sources so a later commit
    // sees the current token layout. A failure never undoes the commit that
    // already succeeded, but must not be silent: a stale graph means a later
    // rename prompts forever for a file that no longer needs it.
    mox.coupling.store.saveGraph(ctx.alloc, ctx.io, coupling_dir, &(try buildCouplingGraph(ctx.alloc, ctx.io, v.tree_now))) catch |e| {
        try ctx.err.print("mox commit: coupling graph not updated: {s}\n", .{@errorName(e)});
    };

    // The counts are what SURVIVED settling, never what was attempted: an
    // accepted coupled update whose path was restored was not committed.
    var coupled_count: usize = 0;
    for (coupling_edits) |ce| {
        if (!restore_cause.contains(ce.path)) coupled_count += 1;
    }
    if (skipped_secret > 0) {
        try ctx.out.print(
            "\nmox commit: {d} routed, {d} coupled, {d} manual, {d} skipped\n",
            .{ committed_count, coupled_count, manual_count, skipped_secret },
        );
    } else {
        try ctx.out.print(
            "\nmox commit: {d} routed, {d} coupled, {d} manual\n",
            .{ committed_count, coupled_count, manual_count },
        );
    }
    // A manifest that never loaded has nothing to summarize; the failure
    // was printed where it happened.
    if (!pkgs.broken and (pkgs.touched() or pkgs.pending())) {
        try ctx.out.print(
            "mox commit: packages: {d} recorded, {d} blacklisted, {d} still untracked\n",
            .{ pkgs.added, pkgs.blacklisted, pkgs.skipped },
        );
    }
    // A manual hunk is work this run did not do, exactly like a skipped secret
    // or an untracked package: without it here a wholly-manual file exits 0
    // while the same state under `--dry-run` exits 1, and while `mox status`
    // still reports the drift the commit left behind.
    return if (mismatch or manual_count > 0 or skipped_secret > 0 or pkgs.pending()) 1 else 0;
}

/// Per-configuration guard outputs for a partial file: each composed text is
/// parsed and replaced by its canonical owned serialization, so the guard's
/// comparisons are canonical-byte. `violation` carries the first
/// configuration whose composed document defines a leaf outside the declared
/// own paths, with the offending leaf spelled.
const PartialPerConfig = struct {
    per: []const impact.ConfigOutput,
    violation: ?struct { label: []const u8, leaf: []const u8 },
};

fn partialPerConfig(
    arena: std.mem.Allocator,
    configs: []const Configuration,
    per: []const impact.ConfigOutput,
    file: mox.source.tree.ManagedFile,
) !PartialPerConfig {
    const partial_mod = mox.apply.partial;
    const format = commit_struct.formatOfPath(file.source_base_path).?;
    const out = try arena.alloc(impact.ConfigOutput, per.len);
    var result: PartialPerConfig = .{ .per = out, .violation = null };
    for (per, configs, out) |src, cfg, *o| {
        switch (src) {
            .bytes => |b| {
                const doc = partial_mod.OwnedDoc.parse(arena, format, b) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.OwnedUnparseable => {
                        o.* = .{ .uncomposable = "composed output does not parse" };
                        continue;
                    },
                };
                if (result.violation == null) {
                    if (file.ownership == .disown) {
                        if (try partial_mod.populatedDisownPath(arena, &doc, file.own_paths)) |spelled| {
                            result.violation = .{ .label = cfg.label, .leaf = spelled };
                        }
                    } else if (try partial_mod.undeclaredLeaf(arena, &doc, file.own_paths)) |leaf| {
                        result.violation = .{ .label = cfg.label, .leaf = leaf };
                    }
                }
                o.* = .{ .bytes = try partialExtract(arena, file, &doc) };
            },
            else => o.* = src,
        }
    }
    return result;
}

/// The partial this-machine identity check: canonical live-owned equals
/// canonical recomposed-owned over the current own paths. An unparseable
/// side reads as a mismatch (the conservative direction).
fn partialLiveMatches(arena: std.mem.Allocator, file: mox.source.tree.ManagedFile, composed: []const u8, live: []const u8) bool {
    const partial_mod = mox.apply.partial;
    const format = commit_struct.formatOfPath(file.source_base_path).?;
    const owned = partial_mod.OwnedDoc.parse(arena, format, composed) catch return false;
    const live_doc = partial_mod.OwnedDoc.parse(arena, format, live) catch return false;
    const composed_canon = partialExtract(arena, file, &owned) catch return false;
    const live_canon = partialExtract(arena, file, &live_doc) catch return false;
    return std.mem.eql(u8, live_canon, composed_canon);
}

/// The file's canonical extraction in its declared mode: the owned subtrees
/// (own), or the whole document minus the disowned ones (disown).
fn partialExtract(arena: std.mem.Allocator, file: mox.source.tree.ManagedFile, doc: *const mox.apply.partial.OwnedDoc) error{OutOfMemory}![]u8 {
    return if (file.ownership == .disown)
        mox.apply.canonical.canonicalComplement(arena, doc, file.own_paths)
    else
        mox.apply.canonical.canonicalOwned(arena, doc, file.own_paths);
}

/// Advance a partial file's OWNED record after a verified commit: canonical
/// serialization (its hash when a secret resolved), the current own path
/// list, and the secret path set, derived exactly as apply derives them.
fn advanceOwnedRecord(ctx: *app.Ctx, file: mox.source.tree.ManagedFile, composed: []const u8, prov_items: []const Segment) !void {
    const context = ctx.context.?;
    const partial_mod = mox.apply.partial;
    const mode: mox.apply.applied.Mode = if (file.ownership == .disown) .disown else .own;
    const format = commit_struct.formatOfPath(file.source_base_path).?;
    const owned = try partial_mod.OwnedDoc.parse(ctx.alloc, format, composed);
    const canon = try partialExtract(ctx.alloc, file, &owned);
    var pdiag: partial_mod.Diag = .{};
    const secret_scope: []const mox.source.tree.OwnPath = switch (mode) {
        .own => file.own_paths,
        .disown => try mox.apply.canonical.topLevelPaths(ctx.alloc, &owned),
    };
    const flags = try partial_mod.secretPathFlags(ctx.alloc, format, composed, secret_scope, prov_items, &pdiag);
    var any_secret = false;
    var secret_raws: std.ArrayList([]const u8) = .empty;
    for (secret_scope, flags) |p, flagged| {
        if (flagged) {
            any_secret = true;
            try secret_raws.append(ctx.alloc, p.raw);
        }
    }
    const raws = try ctx.alloc.alloc([]const u8, file.own_paths.len);
    for (file.own_paths, raws) |p, *o| o.* = p.raw;
    try mox.apply.applied.recordOwned(ctx.alloc, ctx.io, context.paths.state_dir, file.live_path, .{
        .mode = mode,
        .canonical = if (any_secret) null else canon,
        .canonical_hash = if (any_secret) mox.apply.applied.contentHashHex(canon) else null,
        .secret = any_secret,
        .own_paths = raws,
        .secret_paths = secret_raws.items,
    });
}

/// How a routed file that passes verification stands: its recompose equals
/// live; it differs from live only by the hunks it holds (manual or
/// declined); or it holds a hunk and its source composes to nothing here,
/// while it wrote nothing of its own and no coupled update was written into a
/// source of it that composed to something before the write.
const FileCheck = enum { exact, held, composes_to_nothing };

/// What a passing routed file's last verification saw, for its record.
const FileResult = struct {
    check: FileCheck = .exact,
    composed: []const u8 = "",
    live: []const u8 = "",
    prov: []const Segment = &.{},
};

/// What a passing leaf's last verification saw, for its record.
const LeafResult = struct {
    live: []const u8 = "",
    prov: []const Segment = &.{},
    secret: bool = false,
};

/// Every unit's verification against the disk as it stands, and its outcome.
/// Verifying writes nothing and prints only the diagnostic of a unit that
/// fails. A failed unit stays failed: `verifyPassing` skips it, and
/// `passesUnder` checks it again only on a copy, changing nothing.
const Verifier = struct {
    arena: std.mem.Allocator,
    io: Io,
    err: *Io.Writer,
    /// Indexed like every per-file array below.
    files: []const mox.source.tree.ManagedFile,
    /// The source tree as it now stands: walked after the write, and again
    /// after a restore deletes a path.
    tree_now: mox.source.tree.ManagedTree,
    m_state: *const mox.machine.state.MachineState,
    resolver: *const mox.dsl.resolver.Resolver,
    secrets: mox.compose.catB.SecretCtx,
    spaces: []const ?FileSpace,
    baseline: []const []const impact.ConfigOutput,
    allowed: []const std.StringHashMap(void),
    coupling_only: []const bool,
    coupling_into: []const bool,
    null_before: []const bool,
    wrote_own: []const bool,
    manual_hunks: []const usize,
    declined_hunks: []const usize,
    unrouted_hunks: []const usize,
    struct_failed: []const ?[]const u8,
    struct_edits: []const StructEdit,
    struct_owners: []const usize,
    sym_syncs: []const SymSync,
    leaves: []const GenLeafCommit,

    /// Which files are units: routed, or the target of a coupled update.
    file_unit: []bool,
    file_failed: []bool,
    sym_failed: []bool,
    leaf_failed: []bool,
    /// Why a failed file was not committed, for a coupled update into it.
    file_reason: [][]const u8,
    file_res: []FileResult,
    leaf_res: []LeafResult,

    fn failed(v: *const Verifier, u: Unit) bool {
        return switch (u) {
            .file => |i| v.file_failed[i],
            .symlink => |i| v.sym_failed[i],
            .leaf => |i| v.leaf_failed[i],
        };
    }

    fn allFailed(v: *const Verifier, owners: []const Unit) bool {
        for (owners) |u| {
            if (!v.failed(u)) return false;
        }
        return owners.len > 0;
    }

    fn fail(v: *Verifier, u: Unit, reason: []const u8) void {
        switch (u) {
            .file => |i| {
                v.file_failed[i] = true;
                v.file_reason[i] = reason;
            },
            .symlink => |i| v.sym_failed[i] = true,
            .leaf => |i| v.leaf_failed[i] = true,
        }
    }

    fn unitLive(v: *const Verifier, u: Unit) []const u8 {
        return switch (u) {
            .file => |i| v.files[i].live_path,
            .symlink => |i| v.sym_syncs[i].live_path,
            .leaf => |i| v.leaves[i].leaf_live_path,
        };
    }

    /// Whether failed unit `u` passes against the disk as it stands with
    /// facts resolved from `m_state`. Records, prints and fails nothing.
    fn passesUnder(v: *const Verifier, u: Unit, m_state: *const mox.machine.state.MachineState, resolver: *const mox.dsl.resolver.Resolver) !bool {
        var discard_buf: [256]u8 = undefined;
        var discard: Io.Writer.Discarding = .init(&discard_buf);
        var p = v.*;
        p.err = &discard.writer;
        p.m_state = m_state;
        p.resolver = resolver;
        p.file_failed = try v.arena.dupe(bool, v.file_failed);
        p.sym_failed = try v.arena.dupe(bool, v.sym_failed);
        p.leaf_failed = try v.arena.dupe(bool, v.leaf_failed);
        p.file_reason = try v.arena.dupe([]const u8, v.file_reason);
        p.file_res = try v.arena.dupe(FileResult, v.file_res);
        p.leaf_res = try v.arena.dupe(LeafResult, v.leaf_res);
        return switch (u) {
            .file => |i| p.verifyFile(i),
            .symlink => |i| p.verifySymlink(i),
            .leaf => |i| blk: {
                var gen_cache: std.AutoHashMap(usize, ?[]const mox.compose.catB.GeneratedFile) = .init(v.arena);
                break :blk p.verifyLeaf(i, &gen_cache);
            },
        };
    }

    /// A unit that failed verification, and the diagnostic it would print.
    const Failure = struct { unit: Unit, diag: []const u8 };

    /// Verify every unit still passing, holding back each failure's
    /// diagnostic for the caller to print or replace.
    fn verifyPassing(v: *Verifier) ![]const Failure {
        var out: std.ArrayList(Failure) = .empty;
        const err = v.err;
        defer v.err = err;
        // One re-expansion per generator per pass, shared by its leaves.
        var gen_cache: std.AutoHashMap(usize, ?[]const mox.compose.catB.GeneratedFile) = .init(v.arena);
        for (v.sym_failed, 0..) |f, i| {
            if (f) continue;
            var diag: Io.Writer.Allocating = .init(v.arena);
            v.err = &diag.writer;
            if (!try v.verifySymlink(i)) try out.append(v.arena, .{ .unit = .{ .symlink = i }, .diag = diag.written() });
        }
        for (v.leaf_failed, 0..) |f, i| {
            if (f) continue;
            var diag: Io.Writer.Allocating = .init(v.arena);
            v.err = &diag.writer;
            if (!try v.verifyLeaf(i, &gen_cache)) try out.append(v.arena, .{ .unit = .{ .leaf = i }, .diag = diag.written() });
        }
        for (v.file_unit, v.file_failed, 0..) |unit, f, fidx| {
            if (!unit or f) continue;
            var diag: Io.Writer.Allocating = .init(v.arena);
            v.err = &diag.writer;
            if (!try v.verifyFile(fidx)) try out.append(v.arena, .{ .unit = .{ .file = fidx }, .diag = diag.written() });
        }
        return out.toOwnedSlice(v.arena);
    }

    /// A symlink sync passes when its source recomposes to exactly the live
    /// target it was set to.
    fn verifySymlink(v: *Verifier, i: usize) !bool {
        const s = v.sym_syncs[i];
        const file = findByLive(v.tree_now, s.live_path) orelse findByLive(.{ .files = v.files }, s.live_path);
        const ok = if (file) |f| blk: {
            const recomposed = mox.compose.composeFileTracked(v.arena, v.io, f, v.resolver, v.m_state, v.secrets, null, null) catch null;
            const bytes = recomposed orelse break :blk false;
            break :blk mox.apply.applied.sameSymlinkTarget(std.mem.trim(u8, bytes, " \t\r\n"), s.new_target);
        } else false;
        if (ok) return true;
        try v.err.print("mox commit: {f}: recomposed symlink target does not match; not committed\n", .{display.of(s.live_path, v.m_state.home)});
        v.fail(.{ .symlink = i }, "");
        return false;
    }

    /// A leaf passes when its generator, re-expanded, reproduces it exactly
    /// as it is live.
    fn verifyLeaf(v: *Verifier, i: usize, gen_cache: *std.AutoHashMap(usize, ?[]const mox.compose.catB.GeneratedFile)) !bool {
        const gc = v.leaves[i];
        const outputs = gen_cache.get(gc.fidx) orelse blk: {
            const gen_file = findByLive(v.tree_now, gc.gen_file.live_path) orelse gc.gen_file;
            var vdiag: mox.compose.interp.Diag = .{};
            const out = mox.compose.catB.composeGenerator(v.arena, v.io, gen_file, v.resolver, v.m_state, v.secrets, &vdiag) catch null;
            try gen_cache.put(gc.fidx, out);
            break :blk out;
        };
        const produced = findGeneratedByLive(outputs, gc.leaf_live_path);
        const now = Io.Dir.cwd().readFileAlloc(v.io, gc.leaf_live_path, v.arena, .limited(max_file_bytes)) catch null;
        if (produced != null and now != null and std.mem.eql(u8, produced.?.content, now.?)) {
            v.leaf_res[i] = .{ .live = now.?, .prov = produced.?.prov, .secret = produced.?.contains_secret };
            return true;
        }
        try v.err.print("mox commit: {f}: recomposed generator output does not match; not committed\n", .{display.of(gc.leaf_live_path, v.m_state.home)});
        v.fail(.{ .leaf = i }, "");
        return false;
    }

    fn failFile(v: *Verifier, fidx: usize, reason: []const u8) bool {
        v.fail(.{ .file = fidx }, reason);
        return false;
    }

    /// A routed file passes when its recompose equals live, or differs only
    /// by the hunks it holds, and no configuration the user did not choose
    /// changed. A coupling-only target passes when its source still composes
    /// and the sync changed no configuration the user did not choose; a
    /// generator source is composed as its leaves, and never has a leaf
    /// routed this run, since no rename reaches one that does. A file with an
    /// unrouted hunk never passes.
    fn verifyFile(v: *Verifier, fidx: usize) !bool {
        const arena = v.arena;
        const file = v.files[fidx];
        const home = v.m_state.home;
        // A hunk the tool could not route to the candidate the user picked is
        // not something the user asked for: whatever else holds, the unit is
        // not committed.
        if (v.unrouted_hunks[fidx] > 0) return v.leftUncommitted(fidx);
        if (v.struct_failed[fidx]) |ename| {
            try v.err.print("mox commit: {s}: a source layer rejected the edit ({s}); not committed\n", .{ file.live_path, ename });
            return v.failFile(fidx, try std.fmt.allocPrint(arena, "a source layer rejected the edit ({s})", .{ename}));
        }
        const configs = v.spaces[fidx].?.configs;
        const file2 = findByLive(v.tree_now, file.live_path) orelse file;

        if (v.coupling_only[fidx]) {
            const composed = impact.composeAsApply(arena, v.io, file2, v.resolver, v.m_state, v.secrets) catch |e|
                return v.recomposeFailed(fidx, e);
            if (composed == null and !v.null_before[fidx]) {
                try v.err.print("mox commit: {f}: coupled update made the source uncomposable; not committed\n", .{display.of(file.source_base_abs, home)});
                return v.failFile(fidx, "the source no longer composes");
            }
            return v.configsHold(fidx, file2, configs, file.source_base_abs, "coupled token update");
        }

        var prov2: std.ArrayList(Segment) = .empty;
        const composed = mox.compose.composeFileTracked(arena, v.io, file2, v.resolver, v.m_state, v.secrets, &prov2, null) catch |e|
            return v.recomposeFailed(fidx, e);

        const live = v.readLive(fidx);
        const held = v.manual_hunks[fidx] + v.declined_hunks[fidx];
        const composed_bytes = composed orelse {
            // Composing to nothing is the routing's doing when the file's own
            // edits were written, or a coupled update was written into a
            // source that composed to something before.
            const blamed = v.wrote_own[fidx] or (v.coupling_into[fidx] and !v.null_before[fidx]);
            if (!blamed and held > 0) {
                v.file_res[fidx] = .{ .check = .composes_to_nothing };
                return true;
            }
            try v.err.print("mox commit: {s}: the edited sources no longer compose; not committed\n", .{file.live_path});
            return v.failFile(fidx, "its sources no longer compose");
        };
        // A partial file's this-machine identity check is canonical: the
        // extracted live-owned document must equal the recomposed owned
        // document byte-wise in canonical form. The live remainder belongs to
        // the program and never participates.
        if (!v.matchesLive(fidx, composed_bytes, live)) {
            // A manual hunk and a hunk the user deliberately declined (`n`) or
            // skipped (`s`) are both DESIGNED outcomes -- the first has no safe
            // route at all, the second is the user choosing not to commit it
            // this run -- and either stays only in the live file, so the
            // recompose is EXPECTED to still differ. Rolling the file back for
            // that would make the most ordinary mixed edit (one hunk committed,
            // one left alone) uncommittable forever. The routed hunks stand;
            // the applied record does not advance, so the rest still shows as
            // drift.
            if (held == 0) {
                try v.err.print("mox commit: {s}: recomposed output still differs from live; not committed\n", .{file.live_path});
                return v.failFile(fidx, "its recomposed output differs from live");
            }
            // An explained mismatch excuses the file from matching live -- it
            // does NOT excuse it from the cross-configuration check. The
            // routed edits still stand, so a sibling they change that the
            // user never chose to affect fails the file here just as it
            // would on the exact-match path below.
            if (!try v.configsHold(fidx, file2, configs, file.live_path, "routing")) return false;
            // Excused from matching live as a whole, each key routed from
            // this file must still recompose to its live value: a route that
            // landed anywhere else has baked text the recompose does not
            // reproduce.
            if (try unmatchedRoutedKey(arena, v.struct_edits, v.struct_owners, fidx, composed_bytes, live)) |path| {
                const label = try keyPathLabel(arena, path);
                try v.err.print("mox commit: {s}: routed key {s} does not recompose to its live value; not committed\n", .{ file.live_path, label });
                return v.failFile(fidx, try std.fmt.allocPrint(arena, "routed key {s} does not recompose to its live value", .{label}));
            }
            v.file_res[fidx] = .{ .check = .held };
            return true;
        }
        // No classification choice may silently change another configuration:
        // every sibling must recompose to its prior output unless allowed.
        if (!try v.configsHold(fidx, file2, configs, file.live_path, "routing")) return false;
        v.file_res[fidx] = .{ .check = .exact, .composed = composed_bytes, .live = live, .prov = prov2.items };
        return true;
    }

    /// Fail a file whose sources no longer compose.
    fn recomposeFailed(v: *Verifier, fidx: usize, e: anyerror) !bool {
        try v.err.print("mox commit: {f}: recompose failed; not committed: {s}\n", .{ display.of(v.files[fidx].live_path, v.m_state.home), @errorName(e) });
        return v.failFile(fidx, try std.fmt.allocPrint(v.arena, "recompose failed: {s}", .{@errorName(e)}));
    }

    /// Fail a unit with unrouted hunks, saying whether its recompose still
    /// differs from live.
    fn leftUncommitted(v: *Verifier, fidx: usize) !bool {
        const file = v.files[fidx];
        const file2 = findByLive(v.tree_now, file.live_path) orelse file;
        const composed = mox.compose.composeFileTracked(v.arena, v.io, file2, v.resolver, v.m_state, v.secrets, null, null) catch null;
        const n = v.unrouted_hunks[fidx];
        if (composed != null and v.matchesLive(fidx, composed.?, v.readLive(fidx))) {
            try v.err.print("mox commit: {s}: {d} hunk(s) were left uncommitted; not committed\n", .{ file.live_path, n });
        } else {
            try v.err.print(
                "mox commit: {s}: {d} hunk(s) were left uncommitted, so the recomposed output still differs from live; not committed\n",
                .{ file.live_path, n },
            );
        }
        return v.failFile(fidx, try std.fmt.allocPrint(v.arena, "{d} hunk(s) were left uncommitted", .{n}));
    }

    /// The file's live bytes. Kind guard: a live path that became a special
    /// inode mid-commit reads as empty (a mismatch) without the blocking open
    /// a FIFO would force.
    fn readLive(v: *const Verifier, fidx: usize) []const u8 {
        const path = v.files[fidx].live_path;
        return switch (mox.apply.write.guardLiveRead(v.io, path)) {
            .special => "",
            .readable, .absent => Io.Dir.cwd().readFileAlloc(v.io, path, v.arena, .limited(max_file_bytes)) catch "",
        };
    }

    /// Unit equality for a file: exact bytes, or the canonical owned form
    /// for a partial file.
    fn matchesLive(v: *const Verifier, fidx: usize, composed: []const u8, live: []const u8) bool {
        const file = v.files[fidx];
        if (file.own_paths.len == 0) return std.mem.eql(u8, composed, live);
        return partialLiveMatches(v.arena, file, composed, live);
    }

    /// The cross-configuration check: every configuration recomposes to its
    /// prior output unless the user chose to affect it, and a partial file
    /// defines no leaf outside its declared own paths.
    fn configsHold(v: *Verifier, fidx: usize, file2: mox.source.tree.ManagedFile, configs: []const Configuration, name: []const u8, what: []const u8) !bool {
        const file = v.files[fidx];
        var after_per = (try impact.snapshot(v.arena, v.io, file2, configs, v.m_state, v.secrets)).per_config;
        if (file.own_paths.len > 0) {
            const pc = try partialPerConfig(v.arena, configs, after_per, file);
            if (pc.violation) |viol| {
                try v.err.print(
                    "mox commit: {s}: configuration {s}: composed leaf {s} is outside the declared own paths; not committed\n",
                    .{ file.live_path, viol.label, viol.leaf },
                );
                return v.failFile(fidx, try std.fmt.allocPrint(v.arena, "configuration {s}: composed leaf {s} is outside the declared own paths", .{ viol.label, viol.leaf }));
            }
            after_per = pc.per;
        }
        if (candidates.firstViolation(configs, v.baseline[fidx], after_per, &v.allowed[fidx])) |vi| {
            const uncomposable = after_per[vi].isUncomposable();
            try reportViolation(v.err, name, what, configs[vi].label, uncomposable);
            const reason = if (uncomposable)
                try std.fmt.allocPrint(v.arena, "configuration {s} would be unable to compose", .{configs[vi].label})
            else
                try std.fmt.allocPrint(v.arena, "configuration {s} would change", .{configs[vi].label});
            return v.failFile(fidx, reason);
        }
        return true;
    }
};

/// The first of a coupled update's targets that failed.
fn failedTarget(v: *const Verifier, targets: []const usize) ?usize {
    for (targets) |t| {
        if (v.file_failed[t]) return t;
    }
    return null;
}

/// Names a unit not committed for `reason`, something other than its own
/// verification, and how to commit it on its own.
fn printNotCommitted(err: *Io.Writer, unit_live: []const u8, reason: []const u8, home: []const u8) !void {
    const live = display.of(unit_live, home);
    try err.print("mox commit: {f}: not committed: {s}; commit it on its own with 'mox commit {f}'\n", .{ live, reason, live });
}

/// Which units failing their first verification a coupled-update undone
/// line reports: a coupling target of an update, since settling undoes it
/// next with the target's own reason. Its unrouted hunks are still named on
/// their own line, as for any unit. A no-op update, owned by nothing, is
/// never undone.
const UndoneBy = struct {
    couplings: []const Owned(CouplingEdit),
    targets: *const std.StringHashMap([]const usize),
    unrouted: []const usize,

    fn reports(u: UndoneBy, unit: Unit) bool {
        const fidx = switch (unit) {
            .file => |i| i,
            else => return false,
        };
        if (u.unrouted[fidx] > 0) return false;
        for (u.couplings) |o| {
            if (o.owners.items.len > 0 and std.mem.indexOfScalar(usize, u.targets.get(o.edit.path).?, fidx) != null) return true;
        }
        return false;
    }
};

/// One planned write to a source path and the units that own it: every
/// planned edit other than coupled updates, as settling sees it.
const OwnedWrite = struct {
    path: []const u8,
    owners: []const Unit,
};

fn ownedWrites(
    arena: std.mem.Allocator,
    lines: []const Owned(LineEdit),
    structs: []const Owned(StructEdit),
    synths: []const SynthDecision,
    synth_owners: []const usize,
    syms: []const Owned(SymSync),
) ![]const OwnedWrite {
    var out: std.ArrayList(OwnedWrite) = .empty;
    for (lines) |o| try out.append(arena, .{ .path = o.edit.path, .owners = o.owners.items });
    for (syms) |o| try out.append(arena, .{ .path = o.edit.source_abs, .owners = o.owners.items });
    for (synths, synth_owners) |sd, owner| {
        const owners = try arena.dupe(Unit, &.{.{ .file = owner }});
        try out.append(arena, .{ .path = sd.base_abs, .owners = owners });
        try out.append(arena, .{ .path = sd.plan.fragment_path, .owners = owners });
    }
    for (structs) |o| try out.append(arena, .{ .path = o.edit.layer_abs, .owners = o.owners.items });
    return out.toOwnedSlice(arena);
}

/// Add `path` to this round's restores when the edit to it that `owners`
/// produced is dead, naming the first owner as the unit whose failure
/// restored it. A path already restored is not restored again.
fn markDead(
    arena: std.mem.Allocator,
    v: *const Verifier,
    batch: *std.ArrayList([]const u8),
    restore_cause: *std.StringHashMap(Unit),
    path: []const u8,
    owners: []const Unit,
) !void {
    if (!v.allFailed(owners)) return;
    const gop = try restore_cause.getOrPut(path);
    if (gop.found_existing) return;
    gop.value_ptr.* = owners[0];
    try batch.append(arena, path);
}

const RestoreFailure = struct {
    path: []const u8,
    cause: anyerror,
};

/// After a restore did not succeed: name each failure, then copy the pre-run
/// bytes of every journaled path not yet put back that still differs from
/// them, or cannot be read -- the facts file included -- into a fresh
/// `<state>/commit-recovery/<timestamp>[-N]/`, named by root (`repo/<path>`,
/// `private/<path>`, `facts`, or `other/<N>` for a path under neither), and
/// name each such path, as one that still holds this run's edits, with its
/// copy. A path that did not exist before is named for deletion instead; a
/// copy that cannot be written is printed to stderr in full.
fn saveRecovery(
    ctx: *app.Ctx,
    journal: *const Journal,
    ids: *const PathIds,
    at_pre_run: *const std.StringHashMap(void),
    failures: []const RestoreFailure,
    home: []const u8,
) !void {
    const paths = ctx.context.?.paths;
    try ctx.out.flush();
    for (failures) |f| try ctx.err.print("mox commit: could not restore {f} ({s})\n", .{ display.of(ids.shown(f.path), home), @errorName(f.cause) });
    try ctx.err.writeAll("mox commit: nothing was recorded; each path below still holds this run's edits\n");

    var pending: std.ArrayList([]const u8) = .empty;
    var it = journal.entries.iterator();
    while (it.next()) |entry| {
        const p = entry.key_ptr.*;
        if (at_pre_run.contains(p)) continue;
        const now: PathNow = if (Io.Dir.cwd().readFileAlloc(ctx.io, p, ctx.alloc, .limited(max_file_bytes))) |bytes|
            .{ .bytes = bytes }
        else |e| switch (e) {
            error.FileNotFound => .absent,
            error.OutOfMemory => return e,
            else => .unreadable,
        };
        if (!atPreRun(entry.value_ptr.content, now)) try pending.append(ctx.alloc, p);
    }
    std.mem.sort([]const u8, pending.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    const root = try std.fs.path.join(ctx.alloc, &.{ paths.state_dir, "commit-recovery" });
    const roots: RecoveryRoots = .{
        .repo = try canonicalPath(ctx.alloc, ctx.io, paths.repo_dir),
        .private = if (paths.private_dir.len == 0) "" else try canonicalPath(ctx.alloc, ctx.io, paths.private_dir),
        .facts = paths.facts_path,
    };
    var dir: ?[]const u8 = null;
    var others: usize = 0;
    for (pending.items) |p| {
        const name = recoveryName(p, roots) orelse blk: {
            others += 1;
            break :blk RecoveryName{ .root = "other", .rel = try std.fmt.allocPrint(ctx.alloc, "{d}", .{others}) };
        };
        // A path outside both roots is named by its full canonical path.
        const shown = if (std.mem.eql(u8, name.root, "other")) display.of(p, "") else display.of(ids.shown(p), home);
        const bytes = journal.entries.get(p).?.content orelse {
            try ctx.err.print("mox commit: {f} did not exist before this commit; delete it to restore it\n", .{shown});
            continue;
        };
        const copy: ?[]const u8 = blk: {
            if (dir == null) dir = freshRecoveryDir(ctx.alloc, ctx.io, root) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => break :blk null,
            };
            const dest = if (name.rel.len == 0)
                try std.fs.path.join(ctx.alloc, &.{ dir.?, name.root })
            else
                try std.fs.path.join(ctx.alloc, &.{ dir.?, name.root, name.rel });
            if (std.fs.path.dirname(dest)) |parent| Io.Dir.cwd().createDirPath(ctx.io, parent) catch break :blk null;
            Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = dest, .data = bytes }) catch break :blk null;
            break :blk dest;
        };
        if (copy) |c| {
            try ctx.err.print("mox commit: {f}: its pre-run bytes are saved in {f}\n", .{ shown, display.of(c, home) });
        } else {
            try ctx.err.print("mox commit: {f}: its pre-run bytes could not be saved; they follow in full:\n{s}", .{ shown, bytes });
            if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') try ctx.err.writeAll("\n");
        }
    }
    try ctx.err.flush();
}

/// What a journaled path holds when a recovery copy is considered.
const PathNow = union(enum) { absent, bytes: []const u8, unreadable };

/// Whether a path is known to hold its pre-run state `before` (null: it did
/// not exist). A path that cannot be read is not known to.
fn atPreRun(before: ?[]const u8, now: PathNow) bool {
    return switch (now) {
        .unreadable => false,
        .absent => before == null,
        .bytes => |bytes| if (before) |b| std.mem.eql(u8, bytes, b) else false,
    };
}

/// A recovery directory under `root` that did not exist before: the UTC
/// timestamp, with a `-N` suffix when that one is taken.
fn freshRecoveryDir(arena: std.mem.Allocator, io: Io, root: []const u8) ![]const u8 {
    try Io.Dir.cwd().createDirPath(io, root);
    const base = mox.apply.snapshot.idNow(io);
    var n: usize = 1;
    while (true) : (n += 1) {
        const name = if (n == 1) try arena.dupe(u8, &base) else try std.fmt.allocPrint(arena, "{s}-{d}", .{ &base, n });
        const path = try std.fs.path.join(arena, &.{ root, name });
        Io.Dir.cwd().createDir(io, path, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => return e,
        };
        return path;
    }
}

/// The roots a recovery copy is named by, the repo and private layer
/// canonical like every journaled path.
const RecoveryRoots = struct { repo: []const u8, private: []const u8, facts: []const u8 };

const RecoveryName = struct { root: []const u8, rel: []const u8 };

/// Where the recovery copy of canonical path `path` goes, by the root it
/// lives under, or null for a path under neither root or one whose relative
/// form would leave its root.
fn recoveryName(path: []const u8, roots: RecoveryRoots) ?RecoveryName {
    if (std.mem.eql(u8, path, roots.facts)) return .{ .root = "facts", .rel = "" };
    for ([_]struct { root: []const u8, dir: []const u8 }{
        .{ .root = "private", .dir = roots.private },
        .{ .root = "repo", .dir = roots.repo },
    }) |r| {
        if (r.dir.len == 0 or !mox.source.path.isUnderDir(path, r.dir) or path.len == r.dir.len) continue;
        const rel = std.mem.trimStart(u8, path[r.dir.len..], "/\\");
        var it = std.mem.tokenizeAny(u8, rel, "/\\");
        while (it.next()) |part| {
            if (std.mem.eql(u8, part, "..")) return null;
        }
        return .{ .root = r.root, .rel = rel };
    }
    return null;
}

/// Whether a passing unit routed fact `name`.
fn factKept(v: *const Verifier, edits: []const FactEdit, owners: []const usize, name: []const u8) bool {
    for (edits, owners) |e, owner| {
        if (std.mem.eql(u8, e.name, name) and !v.file_failed[owner]) return true;
    }
    return false;
}

/// Put one routed fact back to its value before this run: rewritten, or
/// removed when it was unset.
fn revertFact(arena: std.mem.Allocator, io: Io, facts_path: []const u8, e: FactEdit) !void {
    if (e.old_value) |value| {
        try mox.machine.interview.persist(arena, io, facts_path, &.{.{ .name = e.name, .value = value }});
    } else {
        try mox.machine.interview.remove(arena, io, facts_path, e.name);
    }
}

/// The merged source tree as it stands on disk.
fn walkMerged(arena: std.mem.Allocator, io: Io, src_dir: []const u8, private_dir: []const u8, home: []const u8) !mox.source.tree.ManagedTree {
    const base_tree = try mox.source.tree.walk(arena, io, src_dir, home);
    return mox.private.layer.merge(arena, io, base_tree, private_dir, home);
}

/// Outcome of F-coupling resolution over the routed edits.
const CouplingOutcome = struct {
    /// Updates to apply to other managed sources in the write pass.
    edits: []const CouplingEdit,
    /// Index-aligned with `edits`: the file whose line edit produced each
    /// update's rename.
    origins: []const usize,
    /// The (possibly amended) decline list.
    declines: mox.coupling.decline.DeclineList,
    /// True only when a decline was recorded AND the command did not abort. A
    /// `q`-abort must persist nothing -- including declines -- so this is false
    /// whenever `abort`/`abort_strict` is set.
    save_declines: bool,
    abort: bool = false,
    abort_strict: bool = false,
};

/// One coupled update a routed rename could make: `origin` is the file whose
/// line edit, into `origin_path`, produced the rename, when owners were given.
const CouplingCandidate = struct {
    edit: CouplingEdit,
    origin: ?usize,
    origin_path: []const u8,
};

/// For each routed rename, find other managed sources still holding the old
/// token and prompt to update them. Runs after routing and before any write, so
/// an abort here writes nothing: on `q` (or a strict-mode prompt) no coupling
/// edit is applied and no decline is persisted (`save_declines` stays false).
fn resolveCoupling(
    arena: std.mem.Allocator,
    io: Io,
    coupling_dir: []const u8,
    line_edits: []const LineEdit,
    line_owners: []const usize,
    accepted: *const AcceptedTexts,
    bases: []const []const u8,
    protected: *const std.StringHashMap(void),
    ask_mode: prompt.Mode,
    input: *Io.Reader,
    stdout: *Io.Writer,
    err: *Io.Writer,
) !CouplingOutcome {
    var edits: std.ArrayList(CouplingEdit) = .empty;
    var origins: std.ArrayList(usize) = .empty;
    var graph = try mox.coupling.store.loadGraph(arena, io, coupling_dir);
    var declines = try mox.coupling.store.loadDeclines(arena, io, coupling_dir);
    var declines_changed = false;
    var aborted = false;
    var strict = false;

    const cands = try couplingCandidates(arena, io, &graph, &declines, line_edits, line_owners, accepted, bases, protected, stdout, err);
    for (cands) |c| {
        // An earlier answer in this run may have declined this pair.
        if (declines.isPairDeclined(c.edit.old, c.origin_path, c.edit.path)) continue;
        const q = try std.fmt.allocPrint(arena, "  \"{s}\" -> \"{s}\": also in {s}. Update? [Y/n/d/D/q] ", .{ c.edit.old, c.edit.new, c.edit.path });
        switch (try prompt.ask(ask_mode, &yndd_choices, 0, q, input, stdout)) {
            .chosen => |i| switch (i) {
                0 => {
                    try edits.append(arena, c.edit);
                    try origins.append(arena, c.origin.?);
                    try stdout.print("  update {s}: \"{s}\" -> \"{s}\"\n", .{ c.edit.path, c.edit.old, c.edit.new });
                },
                1 => {},
                2 => {
                    try declines.declinePair(c.edit.old, c.origin_path, c.edit.path);
                    declines_changed = true;
                },
                else => {
                    try declines.declineGlobal(c.edit.old);
                    declines_changed = true;
                },
            },
            .abort => {
                aborted = true;
                break;
            },
            .abort_strict => {
                strict = true;
                break;
            },
            .report_only => {},
        }
    }

    return .{
        .edits = try edits.toOwnedSlice(arena),
        .origins = try origins.toOwnedSlice(arena),
        .declines = declines,
        .save_declines = declines_changed and !aborted and !strict,
        .abort = aborted,
        .abort_strict = strict,
    };
}

/// Report-only counterpart of `resolveCoupling`: count and print the coupling
/// updates a real commit would offer for the routed renames, honoring declines.
/// Prompts nothing and writes nothing (report / non-TTY / dry-run mode).
fn reportCoupling(
    arena: std.mem.Allocator,
    io: Io,
    coupling_dir: []const u8,
    line_edits: []const LineEdit,
    accepted: *const AcceptedTexts,
    bases: []const []const u8,
    protected: *const std.StringHashMap(void),
    stdout: *Io.Writer,
    err: *Io.Writer,
) !usize {
    var graph = try mox.coupling.store.loadGraph(arena, io, coupling_dir);
    var declines = try mox.coupling.store.loadDeclines(arena, io, coupling_dir);
    const cands = try couplingCandidates(arena, io, &graph, &declines, line_edits, null, accepted, bases, protected, stdout, err);
    for (cands) |c| try stdout.print("  would update {s}: \"{s}\" -> \"{s}\"\n", .{ c.edit.path, c.edit.old, c.edit.new });
    return cands.len;
}

/// Every coupled update the routed renames could make, in prompt order, each
/// with the file its rename came from when `line_owners` is given.
/// Dropped with a warning, before any prompt: an update into a path that is
/// no managed file's base (a stale graph entry); every update of a token that
/// this run renames to two different names; and an update into a path an
/// accepted edit already writes new text holding the old token into, which
/// the rename would rewrite.
fn couplingCandidates(
    arena: std.mem.Allocator,
    io: Io,
    graph: *const mox.coupling.graph.Graph,
    declines: *const mox.coupling.decline.DeclineList,
    line_edits: []const LineEdit,
    line_owners: ?[]const usize,
    accepted: *const AcceptedTexts,
    bases: []const []const u8,
    protected: *const std.StringHashMap(void),
    stdout: *Io.Writer,
    err: *Io.Writer,
) ![]const CouplingCandidate {
    var found: std.ArrayList(CouplingCandidate) = .empty;
    var renames: std.ArrayList(Rename) = .empty;
    var stale = std.StringHashMap(void).init(arena);
    // The graph may spell a file otherwise than the tree (MOX_REPO through a
    // symlink, hard links), so files are compared by identity. An update is
    // offered for the file's first base in tree order, and a decline under
    // any spelling of it applies.
    const ids = accepted.ids;
    var base_of = std.StringHashMap([]const u8).init(arena);
    var spellings = std.StringHashMap(std.ArrayList([]const u8)).init(arena);
    for (bases) |b| {
        const id = try ids.canonical(b);
        const first = try base_of.getOrPut(id);
        if (!first.found_existing) first.value_ptr.* = b;
        const all = try spellings.getOrPut(id);
        if (!all.found_existing) all.value_ptr.* = .empty;
        try all.value_ptr.append(arena, b);
    }
    var protected_ids = std.StringHashMap(void).init(arena);
    var pit = protected.keyIterator();
    while (pit.next()) |p| try protected_ids.put(try ids.canonical(p.*), {});
    for (line_edits, 0..) |e, ei| {
        const owner: ?usize = if (line_owners) |o| o[ei] else null;
        // A private-layer edit must never sync a token into the shared repo:
        // the graph is rebuilt over the merged tree and does index private-only
        // files, so `e.private` (set from the edit's source LOCATION, not its
        // provenance tag) is what keeps a private rename out of shared sources.
        if (e.private) continue;
        const rename = (try detectRename(arena, io, e)) orelse continue;
        try renames.append(arena, rename);
        const occs = graph.lookup(rename.old) orelse continue;
        const origin_id = try ids.canonical(e.path);
        var seen = std.StringHashMap(void).init(arena);
        for (occs) |o| {
            const id = try ids.canonical(o.file_id);
            if (std.mem.eql(u8, id, origin_id)) continue;
            // A symlink target / seed-once body is never token-synced, so it is
            // never prompted, announced, or counted here.
            if (protected_ids.contains(id)) continue;
            if ((try seen.getOrPut(id)).found_existing) continue;
            const base = base_of.get(id);
            if (declines.isPairDeclined(rename.old, e.path, o.file_id)) continue;
            const declined = if (spellings.get(id)) |all| for (all.items) |b| {
                if (declines.isPairDeclined(rename.old, e.path, b)) break true;
            } else false else false;
            if (declined) continue;
            const content = Io.Dir.cwd().readFileAlloc(io, o.file_id, arena, .limited(max_file_bytes)) catch continue;
            if (std.mem.indexOf(u8, content, rename.old) == null) continue;
            const path = base orelse {
                if (!(try stale.getOrPut(id)).found_existing) {
                    try warnCoupling(stdout, err, "mox commit: coupling: {s} is no managed file's source; not updating it\n", .{o.file_id});
                }
                continue;
            };
            try found.append(arena, .{ .edit = .{ .path = path, .old = rename.old, .new = rename.new }, .origin = owner, .origin_path = e.path });
        }
    }

    var conflicted = std.StringHashMap(bool).init(arena);
    for (renames.items, 0..) |r, i| {
        for (renames.items[i + 1 ..]) |other| {
            if (std.mem.eql(u8, r.old, other.old) and !std.mem.eql(u8, r.new, other.new)) try conflicted.put(r.old, false);
        }
    }
    var warned = std.StringHashMap(void).init(arena);
    var out: std.ArrayList(CouplingCandidate) = .empty;
    for (found.items) |c| {
        if (conflicted.getPtr(c.edit.old)) |said| {
            if (!said.*) {
                try warnCoupling(stdout, err, "mox commit: coupling: \"{s}\" is renamed to different names in this commit; not updating it anywhere else\n", .{c.edit.old});
                said.* = true;
            }
            continue;
        }
        if (try acceptedHolder(arena, accepted, c.edit.path, c.edit.old, c.edit.new)) |holder| {
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ c.edit.path, c.edit.old });
            if (!(try warned.getOrPut(key)).found_existing) switch (holder) {
                .edit => try warnCoupling(stdout, err, "mox commit: coupling: an edit routed into {s} keeps \"{s}\"; not renaming it there\n", .{ c.edit.path, c.edit.old }),
                .directive => try warnCoupling(stdout, err, "mox commit: coupling: {s} holds \"{s}\" in a loop a row write was routed through; not renaming it there\n", .{ c.edit.path, c.edit.old }),
            };
            continue;
        }
        try out.append(arena, c);
    }
    return out.toOwnedSlice(arena);
}

fn warnCoupling(stdout: *Io.Writer, err: *Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    // In program order on the terminal: the warning before the prompts.
    try stdout.flush();
    try err.print(fmt, args);
    try err.flush();
}

/// The new text each edit accepted this run writes, by the canonical path it
/// writes: a line edit's new lines; a narrowing's region block and fragment;
/// for a row write, its row's header key path and each assignment statement
/// of its row, as planned, keyed by the assignment's key and carrying the row
/// fields the routed template, the loop's `where` and a leaf's `into` path
/// read. Under the path holding the loop or generator a row write was routed
/// through: its directive lines and the routed template.
const AcceptedTexts = struct {
    ids: *PathIds,
    by_path: std.StringHashMap(std.ArrayList(Accepted)),

    fn init(arena: std.mem.Allocator, ids: *PathIds) AcceptedTexts {
        return .{ .ids = ids, .by_path = .init(arena) };
    }
};

/// One accepted text. With a `key`, it is a row's assignment statement and
/// counts only when that key, before or after a rename, names one of `fields`.
/// A `directive` text is what a routed row write was checked against, not
/// text an edit writes.
const Accepted = struct {
    text: []const u8,
    key: ?[]const u8 = null,
    fields: []const []const u8 = &.{},
    directive: bool = false,
};

fn acceptedTexts(
    arena: std.mem.Allocator,
    io: Io,
    ids: *PathIds,
    files: []const mox.source.tree.ManagedFile,
    lines: []const LineEdit,
    rows: []const RowEdit,
    row_owners: []const usize,
    gen: *const LeafRowEdits,
    synths: []const SynthDecision,
) !AcceptedTexts {
    var m: AcceptedTexts = .init(arena, ids);
    for (lines) |e| try addAccepted(arena, &m, try ids.canonical(e.path), .{ .text = try std.mem.join(arena, "\n", e.new_lines) });
    // Each data source as its row writes leave it: every distinct splice in
    // one pass over its pre-run bytes, as the plan applies them.
    var splices = std.StringHashMap(std.ArrayList(LineEdit)).init(arena);
    var pre_run = std.StringHashMap([]const u8).init(arena);
    for ([_][]const RowEdit{ rows, gen.row_edits.items }) |list| for (list) |e| {
        const path = try ids.canonical(e.data_source);
        const gop = try splices.getOrPut(path);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
            try pre_run.put(path, Io.Dir.cwd().readFileAlloc(io, e.data_source, arena, .limited(max_file_bytes)) catch "");
        }
        for (e.splices) |sp| {
            const seen = for (gop.value_ptr.items) |x| {
                if (sameSplice(x, sp)) break true;
            } else false;
            if (!seen) try gop.value_ptr.append(arena, sp);
        }
    };
    var planned = std.StringHashMap([]const u8).init(arena);
    var it = splices.iterator();
    while (it.next()) |entry| {
        try planned.put(entry.key_ptr.*, try splicedContent(arena, pre_run.get(entry.key_ptr.*).?, entry.value_ptr.items));
    }
    for (rows, row_owners) |e, owner| {
        const path = try ids.canonical(e.data_source);
        const content = planned.get(path).?;
        try addRowStatements(arena, &m, path, e, content, try storedValueFields(arena, try rowReads(arena, e), e, content));
        try addDirectiveTexts(arena, io, &m, files[owner], e.template);
    }
    for (gen.row_edits.items, gen.row_leaves.items) |e, li| {
        const path = try ids.canonical(e.data_source);
        const content = planned.get(path).?;
        try addRowStatements(arena, &m, path, e, content, try storedValueFields(arena, try rowReads(arena, e), e, content));
        try addDirectiveTexts(arena, io, &m, gen.leaves.items[li].gen_file, e.template);
    }
    for (synths) |sd| {
        try addAccepted(arena, &m, try ids.canonical(sd.base_abs), .{ .text = try std.mem.join(arena, "\n", sd.plan.base_lines) });
        try addAccepted(arena, &m, try ids.canonical(sd.plan.fragment_path), .{ .text = sd.plan.fragment_content });
    }
    return m;
}

fn addAccepted(arena: std.mem.Allocator, m: *AcceptedTexts, path: []const u8, a: Accepted) !void {
    const gop = try m.by_path.getOrPut(path);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(arena, a);
}

/// What in `path` a rename of `old` to `new` would change under an accepted
/// edit: a text an edit writes holding `old` as a complete token, or else
/// the directive lines or template a routed row write was checked against
/// holding it. Null when neither does.
fn acceptedHolder(arena: std.mem.Allocator, accepted: *const AcceptedTexts, path: []const u8, old: []const u8, new: []const u8) !?enum { edit, directive } {
    const texts = accepted.by_path.get(try accepted.ids.canonical(path)) orelse return null;
    var in_directive = false;
    for (texts.items) |t| {
        if (t.key) |key| {
            const renamed = try replaceTokens(arena, key, &.{.{ .path = path, .old = old, .new = new }});
            if (!isOneOf(key, t.fields) and !isOneOf(renamed, t.fields)) continue;
        }
        if (!containsToken(try mox.coupling.tokens.extract(arena, t.text), old)) continue;
        if (!t.directive) return .edit;
        in_directive = true;
    }
    return if (in_directive) .directive else null;
}

/// Add, under the canonical path of `file`'s base, every `# mox:` directive
/// line of it and the routed `template`: what a row write routed through a
/// loop or generator there was checked against.
fn addDirectiveTexts(arena: std.mem.Allocator, io: Io, m: *AcceptedTexts, file: mox.source.tree.ManagedFile, template: []const u8) !void {
    if (!file.has_base or file.source_base_abs.len == 0) return;
    const path = try m.ids.canonical(file.source_base_abs);
    try addAccepted(arena, m, path, .{ .text = template, .directive = true });
    const content = Io.Dir.cwd().readFileAlloc(io, file.source_base_abs, arena, .limited(max_file_bytes)) catch return;
    const marker = mox.dsl.comment.markerForFile(file.source_base_path, content) orelse return;
    const events = mox.dsl.scanner.scan(arena, content, marker) catch |e| switch (e) {
        error.OutOfMemory => return e,
        // Too long to be a directive the parser accepts: every token counts.
        error.DirectiveTooLong => return addAccepted(arena, m, path, .{ .text = content, .directive = true }),
    };
    for (events) |ev| switch (ev) {
        .directive => |d| try addAccepted(arena, m, path, .{ .text = d.original_line, .directive = true }),
        .content => {},
    };
}

/// Add, under `path`, the key path of the target row's `[[stem]]` header in
/// `content` and each assignment statement of the table it opens, keyed by
/// its key's first segment: its key and its value, never a comment.
fn addRowStatements(arena: std.mem.Allocator, m: *AcceptedTexts, path: []const u8, e: RowEdit, content: []const u8, fields: []const []const u8) !void {
    const stmts = toml_statements.scan(arena, content) catch |err| switch (err) {
        // Too deep to tell statements apart: every token of it counts.
        error.NestingTooDeep => return addAccepted(arena, m, path, .{ .text = content }),
        error.OutOfMemory => return err,
    };
    const row = toml_statements.arrayTableRow(stmts, e.stem, e.row) orelse return;
    try addAccepted(arena, m, path, .{ .text = row.header.key_span.of(content) });
    for (row.body) |st| {
        const text = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ st.key_span.of(content), try st.valueText(arena, content) });
        try addAccepted(arena, m, path, .{ .text = text, .key = st.key[0], .fields = fields });
    }
}

/// The row fields a loop reads. `expanded` are those its body or `into`
/// path reads through a capture whose stored value the expander resolves
/// once more under `variable`.
const RowReads = struct {
    fields: []const []const u8,
    variable: []const u8,
    expanded: []const []const u8,
};

/// The row fields the loop a row write was routed through reads: every
/// capture of its template naming a field of the loop variable (defaults and
/// chains included) or a bare field, its `where` predicate's field
/// references, and a leaf's `into` path's captures.
fn rowReads(arena: std.mem.Allocator, e: RowEdit) !RowReads {
    var names: std.ArrayList([]const u8) = .empty;
    try appendCaptureFields(arena, &names, e.template, e.variable);
    if (e.where) |w| try appendWhereFields(arena, &names, w, e.variable);
    if (e.into) |into| try appendCaptureFields(arena, &names, into, e.variable);
    var expanded: std.ArrayList([]const u8) = .empty;
    try appendExpandedFields(arena, &expanded, e.template, e.variable);
    if (e.into) |into| try appendExpandedFields(arena, &expanded, into, e.variable);
    return .{ .fields = names.items, .variable = e.variable, .expanded = expanded.items };
}

/// The row fields whose stored values `interp.expandTrackedImpl` expands
/// again when it renders `text`: a single-member capture, with or without a
/// default, naming `variable.<field>` or `entry.<field>`. A chain member and
/// a bare field splice their stored values verbatim.
fn appendExpandedFields(arena: std.mem.Allocator, names: *std.ArrayList([]const u8), text: []const u8, variable: []const u8) !void {
    const capture = mox.compose.capture;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '<')) |open| {
        const close = capture.closeIndex(text, open) orelse break;
        i = close + 1;
        const inner = capture.splitDefault(text[open + 1 .. close]).field;
        if (capture.isChain(inner)) continue;
        for ([_][]const u8{ variable, "entry" }) |head| {
            if (inner.len <= head.len + 1 or !std.mem.startsWith(u8, inner, head) or inner[head.len] != '.') continue;
            if (isFieldName(inner[head.len + 1 ..])) try names.append(arena, inner[head.len + 1 ..]);
            break;
        }
    }
}

/// Every field `reads` names, plus each row field a capture in any form
/// reads inside the stored value, in `content`, of an expanded field of `e`'s
/// target row: the one level the expander resolves a row value. A `content`
/// that does not parse fails to compose anyway, so it adds nothing.
fn storedValueFields(arena: std.mem.Allocator, reads: RowReads, e: RowEdit, content: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(arena, reads.fields);
    const record = rowRecord(arena, content, e.stem, e.row) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    } orelse return names.toOwnedSlice(arena);
    for (reads.expanded) |f| {
        const v = record.get(f) orelse continue;
        try appendCaptureFields(arena, &names, try v.format(arena), reads.variable);
    }
    return names.toOwnedSlice(arena);
}

/// The row fields each `<...>` capture of `text` reads, in any capture form:
/// every member of a chain, with or without a default, naming
/// `variable.<field>` or `entry.<field>`, or a bare field name. A default is
/// literal text and reads nothing.
fn appendCaptureFields(arena: std.mem.Allocator, names: *std.ArrayList([]const u8), text: []const u8, variable: []const u8) !void {
    const capture = mox.compose.capture;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '<')) |open| {
        const close = capture.closeIndex(text, open) orelse break;
        i = close + 1;
        var members = capture.members(capture.splitDefault(text[open + 1 .. close]).field);
        while (members.next()) |member| {
            const field = fieldOfRef(member, variable) orelse fieldOfRef(member, "entry") orelse
                (if (isFieldName(member)) member else null);
            if (field) |f| try names.append(arena, f);
        }
    }
}

/// The row fields a `where` predicate reads through `variable`.
fn appendWhereFields(arena: std.mem.Allocator, names: *std.ArrayList([]const u8), expr: *const mox.dsl.ast.RowExpr, variable: []const u8) !void {
    const ref: []const u8 = switch (expr.*) {
        .present => |r| r,
        .has => |h| h.ref,
        .eq => |e| e.ref,
        .axis_with_field => |a| a.field_ref,
        .bound => |r| r,
        .not => |inner| return appendWhereFields(arena, names, inner, variable),
        .and_ => |b| {
            try appendWhereFields(arena, names, b.left, variable);
            return appendWhereFields(arena, names, b.right, variable);
        },
        .or_ => |b| {
            try appendWhereFields(arena, names, b.left, variable);
            return appendWhereFields(arena, names, b.right, variable);
        },
    };
    if (fieldOfRef(ref, variable)) |f| try names.append(arena, f);
}

/// The field `ref` names when it reads `variable.<field>`.
fn fieldOfRef(ref: []const u8, variable: []const u8) ?[]const u8 {
    if (ref.len <= variable.len + 1 or !std.mem.startsWith(u8, ref, variable) or ref[variable.len] != '.') return null;
    const rest = ref[variable.len + 1 ..];
    var end: usize = 0;
    while (end < rest.len and isFieldChar(rest[end])) end += 1;
    return if (end == 0) null else rest[0..end];
}

fn isFieldName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!isFieldChar(c)) return false;
    return true;
}

fn isFieldChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// Absolute base source path of every managed file, in tree order: what a
/// coupled update may rewrite.
fn managedBases(arena: std.mem.Allocator, files: []const mox.source.tree.ManagedFile) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        if (f.has_base and f.source_base_abs.len > 0) try out.append(arena, f.source_base_abs);
    }
    return out.toOwnedSlice(arena);
}

/// Detect a single-token rename in a line edit: the token present in the old
/// source lines but gone from the new, paired with the sole newly-introduced
/// token. Returns null unless exactly one token was removed and one added.
fn detectRename(arena: std.mem.Allocator, io: Io, edit: LineEdit) !?Rename {
    const content = Io.Dir.cwd().readFileAlloc(io, edit.path, arena, .limited(max_file_bytes)) catch return null;
    const lines = try mox.diff.lines.splitLines(arena, content);
    const start = @min(edit.start, lines.len);
    const end = @min(start + edit.del, lines.len);
    const old_text = try std.mem.join(arena, "\n", lines[start..end]);
    const new_text = try std.mem.join(arena, "\n", edit.new_lines);

    const old_toks = try mox.coupling.tokens.extract(arena, old_text);
    const new_toks = try mox.coupling.tokens.extract(arena, new_text);

    var removed: ?[]const u8 = null;
    var removed_count: usize = 0;
    for (old_toks) |t| {
        if (!containsToken(new_toks, t)) {
            removed = t;
            removed_count += 1;
        }
    }
    var added: ?[]const u8 = null;
    var added_count: usize = 0;
    for (new_toks) |t| {
        if (!containsToken(old_toks, t)) {
            added = t;
            added_count += 1;
        }
    }
    if (removed_count != 1 or added_count != 1) return null;
    return .{ .old = removed.?, .new = added.? };
}

fn containsToken(toks: []const []const u8, tok: []const u8) bool {
    for (toks) |t| {
        if (std.mem.eql(u8, t, tok)) return true;
    }
    return false;
}

/// Replace every occurrence in `content` of a rename's old token that is
/// itself a complete token -- bounded by a non-token char or a string edge,
/// matching how `coupling/tokens.zig` extracts tokens (a token is a maximal run
/// of token chars) -- with that rename's new token, in one pass: a replacement
/// is never matched again, so `a -> b` beside `b -> c` never turns `a` into
/// `c`. An occurrence embedded in a longer token is left intact, so renaming
/// one token never corrupts a superstring of it. Returns arena-owned bytes.
fn replaceTokens(arena: std.mem.Allocator, content: []const u8, renames: []const CouplingEdit) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    scan: while (i < content.len) {
        const before_ok = i == 0 or !mox.coupling.tokens.isTokenChar(content[i - 1]);
        if (before_ok) {
            for (renames) |r| {
                if (r.old.len == 0 or !std.mem.startsWith(u8, content[i..], r.old)) continue;
                const after = i + r.old.len;
                if (after < content.len and mox.coupling.tokens.isTokenChar(content[after])) continue;
                try out.appendSlice(arena, r.new);
                i = after;
                continue :scan;
            }
        }
        try out.append(arena, content[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Source files that must never receive a coupling token sync: a symlink
/// source's content is a link target, a seed-once source's is a one-time seed.
/// Keyed by absolute source path (the coupling graph's file id).
fn protectedSourceSet(arena: std.mem.Allocator, files: []const mox.source.tree.ManagedFile) !std.StringHashMap(void) {
    var protected = std.StringHashMap(void).init(arena);
    for (files) |f| {
        if ((f.is_symlink or f.create_once) and f.source_base_abs.len > 0) {
            try protected.put(f.source_base_abs, {});
        }
    }
    return protected;
}

/// Coupling edits targeting `path`, in order. Grouped so a target file's
/// combined token sync can be simulated and applied as a unit.
fn couplingEditsForPath(arena: std.mem.Allocator, edits: []const CouplingEdit, path: []const u8) ![]const CouplingEdit {
    var out: std.ArrayList(CouplingEdit) = .empty;
    for (edits) |e| {
        if (std.mem.eql(u8, e.path, path)) try out.append(arena, e);
    }
    return out.toOwnedSlice(arena);
}

/// The undone line of every target of a path whose renames are removed
/// before planning, in file order: a target whose own simulation failed
/// gives its own reason; any other names the first target of its path that
/// failed.
fn droppedCouplingLines(
    arena: std.mem.Allocator,
    files: []const mox.source.tree.ManagedFile,
    target_path: []const ?[]const u8,
    sim_failed: []const ?[]const u8,
    dropped: []const []const u8,
    home: []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (files, target_path, sim_failed) |f, tp, why| {
        const path = tp orelse continue;
        if (!isOneOf(path, dropped)) continue;
        const first = for (target_path, sim_failed, 0..) |other, other_why, i| {
            if (other != null and other_why != null and std.mem.eql(u8, other.?, path)) break i;
        } else unreachable;
        try out.append(arena, try std.fmt.allocPrint(arena, "coupled update to {f} undone: {f} could not take it ({s})", .{
            display.of(f.live_path, home),
            display.of(if (why != null) f.live_path else files[first].live_path, home),
            why orelse sim_failed[first].?,
        }));
    }
    return out.toOwnedSlice(arena);
}

/// Impact of a coupling target's token sync: snapshot every configuration's
/// compose, transiently apply the token replacements to the source, snapshot
/// again, then restore. A compose this machine cannot do, before or after, is
/// `.uncomposable`; a target that cannot be read or transiently written is
/// `.unwritable`. Only a failure to revert the transient write is an error.
fn simulateCouplingImpact(
    cc: *const ClassCtx,
    file: mox.source.tree.ManagedFile,
    path: []const u8,
    file_edits: []const CouplingEdit,
    configs: []const Configuration,
) !CouplingSim {
    const arena = cc.arena;
    const io = cc.io;
    const original = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .unwritable = e },
    };
    const before = impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .uncomposable = e },
    };

    const edited = try replaceTokens(arena, original, file_edits);
    // A failed write may have left part of it behind, so it is reverted too.
    const written = Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = edited });
    const after_or = if (written) impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets) else |_| undefined;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = original }) catch |e| {
        cc.err.print("mox commit: {s}: could not restore the transiently edited source; left edited\n", .{path}) catch {};
        // A snapshot failure is the error worth reporting over the write's.
        written catch return e;
        _ = after_or catch |se| return se;
        return e;
    };
    written catch |e| return .{ .unwritable = e };
    const after = after_or catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .uncomposable = e },
    };

    var present: usize = 0;
    for (configs, before.per_config, after.per_config) |c, b, a| {
        if (c.is_this_machine) continue;
        if (b == .absent and a == .absent) continue;
        if (b.isUncomposable() and a.isUncomposable()) continue;
        present += 1;
    }
    return .{ .impact = .{ .impact = try impact.impact(arena, configs, before, after), .present_siblings = present, .before = before.per_config } };
}

const CouplingSim = union(enum) {
    impact: CouplingImpact,
    uncomposable: anyerror,
    unwritable: anyerror,
};

/// A coupled update's `impact`, how many configurations other than this
/// machine's it could change -- those the file exists in before or after it,
/// less those it cannot compose in either way -- and every configuration's
/// compose before it.
const CouplingImpact = struct {
    impact: impact.Impact,
    present_siblings: usize,
    before: []const impact.ConfigOutput,
};

/// Build a coupling graph over the tree's base source files, keyed by absolute
/// source path so commit can resolve postings to files it can rewrite.
fn buildCouplingGraph(arena: std.mem.Allocator, io: Io, tree: mox.source.tree.ManagedTree) !mox.coupling.graph.Graph {
    var inputs: std.ArrayList(mox.coupling.index.FileInput) = .empty;
    for (tree.files) |file| {
        if (!file.has_base or file.source_base_abs.len == 0) continue;
        // A symlink target / seed-once body is never token-synced, so keep it
        // out of the coupling graph entirely (matches add/doctor builders).
        if (file.is_symlink or file.create_once) continue;
        const content = Io.Dir.cwd().readFileAlloc(io, file.source_base_abs, arena, .limited(max_file_bytes)) catch continue;
        try inputs.append(arena, .{ .id = file.source_base_abs, .content = content });
    }
    return mox.coupling.index.build(arena, inputs.items);
}

/// Whether any provenance segment came from a structural merge (`.overlay`).
/// This is the exact set that routes to manual today, and the set the
/// key-path flow takes over.
fn containsOverlayOrigin(segments: []const Segment) bool {
    for (segments) |s| {
        if (s.origin == .overlay) return true;
    }
    return false;
}

/// Axes every real machine always binds (`src/machine/bindings.zig`'s
/// `fromMachineState` sets os/arch/machine/hostname unconditionally, from
/// `MachineState` fields no machine lacks). Their UNBOUND configuration is a
/// phantom that must never be enumerated -- but a value the sources never
/// name is not: a machine running an os this repo has never mentioned is
/// real, and a promote reaches it. So a derived axis gets the `(other)`
/// representative instead of the unbound one. Every other compared axis is an
/// optional custom fact: a real sibling machine may leave it unset, and that
/// fall-through configuration is what must be enumerated for the
/// blast-radius check below to be sound.
const derived_axes = [_][]const u8{ "os", "arch", "machine", "hostname" };

fn isDerivedAxis(name: []const u8) bool {
    for (derived_axes) |d| if (std.mem.eql(u8, d, name)) return true;
    return false;
}

/// The configurations `file`'s edits can affect, over the REPO-WIDE value
/// space. `axes.ofFileOverTree` gives the file's own compared axis NAMES, each
/// carrying the repo-wide value SET (`axes.ofTree` unions every axis value
/// referenced across ALL source files -- every `.d/` overlay tuple and every
/// when/where expression). So a machine revealed only by another file's
/// overlay (an `os=linux` a sibling declares) is in this file's space, while an
/// axis no file references is not a phantom dimension. The per-file space
/// alone would miss such a fall-through machine, so a structured promote must
/// enumerate this way to be sound.
///
/// A non-derived compared axis also forces its unbound representative even
/// when THIS machine binds it: a sibling that leaves an optional fact
/// (`profile`, say) unset falls through to the base, and a promote that
/// silently changes what that sibling reads would violate the same soundness
/// invariant the repo-wide value set exists to uphold.
fn structConfigs(
    arena: std.mem.Allocator,
    io: Io,
    file: mox.source.tree.ManagedFile,
    this_bindings: *const std.StringHashMap([]const u8),
    repo_dir: []const u8,
) ![]const Configuration {
    const ax = try mox.source.axes.ofFileOverTree(arena, io, file, repo_dir);

    var force_unbound: std.ArrayList([]const u8) = .empty;
    var force_other: std.ArrayList([]const u8) = .empty;
    var it = ax.compared.keyIterator();
    while (it.next()) |name| {
        if (isDerivedAxis(name.*)) {
            try force_other.append(arena, name.*);
        } else {
            try force_unbound.append(arena, name.*);
        }
    }

    return config_space.enumerate(arena, this_bindings, ax, force_unbound.items, force_other.items);
}

/// A `FileSpace` for a structured file whose `.configs` is the REPO-WIDE set.
/// Stashed into `spaces[fidx]` so every guard step (`baseline`, the post-write
/// `snapshot`, `firstViolation`) verifies this file over the repo-wide space.
/// `.ax` is the file's own axes; the structured route never reads it (only the
/// line-hunk `candidates.compute` does), but it keeps the field well-formed.
fn structFileSpace(
    arena: std.mem.Allocator,
    io: Io,
    this_bindings: *const std.StringHashMap([]const u8),
    file: mox.source.tree.ManagedFile,
    repo_dir: []const u8,
) !FileSpace {
    return .{
        .ax = try mox.source.axes.ofFile(arena, io, file),
        .configs = try structConfigs(arena, io, file, this_bindings, repo_dir),
    };
}

/// The parsed source layers of a structured file, least-specific-first (the
/// composer's fold order), so `resolveLayer` sees base at index 0 then overlays
/// in increasing specificity. Re-reads exactly the layer set the composer
/// merged for this machine's bindings.
fn structLayers(
    arena: std.mem.Allocator,
    io: Io,
    file: mox.source.tree.ManagedFile,
    bindings: *const mox.dsl.resolver.Resolver,
    format: commit_struct.Format,
) ![]const commit_struct.StructLayer {
    const paths = try mox.compose.catA.matchingLayerPaths(arena, file, bindings);
    var out: std.ArrayList(commit_struct.StructLayer) = .empty;
    for (paths) |p| {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(max_file_bytes));
        try out.append(arena, .{
            .path = p,
            .is_base = file.has_base and std.mem.eql(u8, p, file.source_base_abs),
            .value = try commit_struct.parseLayer(arena, format, bytes),
        });
    }
    return out.toOwnedSlice(arena);
}

/// Restore a layer file to `original` (its pre-simulation bytes), or delete it
/// when it did not exist before. Used to revert `simulateStructImpact`'s
/// transient write.
fn restoreLayerBytes(io: Io, path: []const u8, original: ?[]const u8) !void {
    if (original) |bytes| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    } else {
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

/// One placement's full effect over the REPO-WIDE `configs`: transiently apply
/// every edit in `edits` (the write at the chosen layer plus its surgical
/// override deletions), snapshot each configuration's compose before and after,
/// then restore every touched layer to its pre-simulation bytes -- so the tree
/// is byte-identical afterward. Returns the changed configuration labels and
/// both snapshots (the pick confirm renders the key's before/after value from
/// them). Used for both `affected_winner` (the winner write alone) and
/// `affected_pick` (the full pick), whose set difference is the `extra` a pick
/// reaches beyond the plain `[y]`.
fn simulateStructImpact(
    cc: *const ClassCtx,
    file: mox.source.tree.ManagedFile,
    edits: []const StructEdit,
    configs: []const Configuration,
) !StructSim {
    const arena = cc.arena;
    const io = cc.io;

    // Each DISTINCT touched layer's pre-simulation bytes, captured once (null
    // when the layer did not exist: a fresh overlay the placement creates).
    // Several edits may touch one layer, so restore keys on the path, not on
    // the edit.
    var origs: std.StringHashMap(?[]const u8) = .init(arena);
    for (edits) |e| {
        if (origs.contains(e.layer_abs)) continue;
        const cur: ?[]const u8 = Io.Dir.cwd().readFileAlloc(io, e.layer_abs, arena, .limited(max_file_bytes)) catch |er| switch (er) {
            error.FileNotFound => null,
            else => return er,
        };
        try origs.put(e.layer_abs, cur);
    }

    const before = try impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets);

    // A layer refusing the edit is a routing outcome, reported to the user. Any
    // other failure -- a snapshot, a read, a restore -- is a real error and
    // must stay one: conflating them would blame the chosen layer for, say, an
    // unparseable sibling overlay it has nothing to do with.
    var rejected = false;
    for (edits) |e| {
        commit_struct.applyToLayer(arena, io, e.format, e.layer_abs, e.change) catch {
            rejected = true;
            break;
        };
    }
    var err: ?anyerror = null;
    const after = if (!rejected)
        impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets) catch |er| blk: {
            err = er;
            break :blk before;
        }
    else
        before;

    // Restore every touched layer even on error, so a failed simulation never
    // leaves a partial write behind. One restore failing must not abandon the
    // rest: finish the sweep, then report the first failure.
    var it = origs.iterator();
    while (it.next()) |kv| {
        restoreLayerBytes(io, kv.key_ptr.*, kv.value_ptr.*) catch |er| {
            if (err == null) err = er;
        };
    }

    if (err) |er| return er;
    if (rejected) return .rejected;

    const imp = try impact.impact(arena, configs, before, after);
    return .{ .ok = .{ .affected = imp.affected, .before = before, .after = after } };
}

/// Per-key-change diff lines for the prompt/report: the key path and its
/// resolved route label, then the old and new values as `-`/`+` lines in
/// canonical inline rendering, so the prompt shows what the answer trades.
fn printKeyChange(arena: std.mem.Allocator, sty: style.Style, out: *Io.Writer, change: commit_struct.KeyPathChange, label: []const u8) !void {
    try out.writeAll("    ");
    for (change.path, 0..) |seg, i| {
        if (i > 0) try out.writeAll(".");
        try out.writeAll(seg);
    }
    if (change.removed) {
        try sty.red(out);
        try out.writeAll("  (removed)");
        try sty.close(out);
    }
    try sty.dim(out);
    try out.print("  ->  {s}\n", .{label});
    try sty.close(out);
    if (change.old_text) |old| {
        try sty.red(out);
        try out.print("      - {s}\n", .{old});
        try sty.close(out);
    }
    if (change.new) |v| {
        try sty.green(out);
        try out.print("      + {s}\n", .{try commit_struct.valueInline(arena, v)});
        try sty.close(out);
    }
}

/// Route a structured (Cat-A merged) file's hand-edits back into their source
/// layers. Each changed key path is one prompt item: `[y]` writes it to the
/// winning layer, `[p]` picks a layer, `[s]` leaves it. An un-routable key
/// (interpolation/secret-derived, or a multi-layer removal) is reported and
/// left. Every accepted edit is deferred to the write phase and passes through
/// the recompose-verify guard.
fn processStructFile(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    file: mox.source.tree.ManagedFile,
    fidx: usize,
    space: FileSpace,
    format: commit_struct.Format,
    last_content: []const u8,
    live: []const u8,
    first_contact: bool,
) !HunkOutcome {
    // A manual (un-routable) key and a user `[s]` skip are both "explained"
    // mismatches (see `recordStructPlacement`'s doc comment): the file must
    // still pass through the recompose-verify guard so either one leaves it
    // correctly reported as uncommitted, rather than silently ignored the way
    // an unaffected file is. Set before any early return, so a file this
    // function gives up on reports the same way as one whose every key it
    // reported individually -- rather than exiting 0 as if nothing happened.
    ra.affected[fidx] = true;

    const changes = commit_struct.changedKeyPaths(cc.arena, format, last_content, live) catch |e| switch (e) {
        error.Unrepresentable => {
            // A same-length array reorder has no stable key-path identity.
            ra.manual_count.* += 1;
            ra.manual_hunks[fidx] += 1;
            ra.pending.* = true;
            try cc.stdout.print("  manual: {f} (a reordered array cannot be routed by key)\n", .{display.of(file.live_path, cc.m_state.home)});
            return .cont;
        },
        error.OutOfMemory => return e,
        // A live file the user has broken is that file's problem, not the
        // run's: report it and leave every other file's routing intact.
        else => {
            ra.manual_count.* += 1;
            ra.manual_hunks[fidx] += 1;
            ra.pending.* = true;
            try cc.stdout.print("  manual: {f} could not be parsed ({s}); edit its source directly\n", .{ display.of(file.live_path, cc.m_state.home), @errorName(e) });
            return .cont;
        },
    };
    if (changes.len == 0) {
        // Live differs from the composed output, but in no key's value: the
        // drift is a comment, a blank line, or key order, none of which a
        // structural fold can attribute to a layer. Report it -- dropping it
        // would claim a clean run while the drift persists and the next apply
        // discards the edit.
        ra.manual_count.* += 1;
        ra.manual_hunks[fidx] += 1;
        ra.pending.* = true;
        try cc.stdout.print("  manual: {f} (comment, blank-line, or ordering drift has no key path)\n", .{display.of(file.live_path, cc.m_state.home)});
        return .cont;
    }

    const composed: ?commit_struct.Baseline = if (commit_struct.parseLayer(cc.arena, format, last_content)) |v| .{ .value = v } else |e| switch (e) {
        error.OutOfMemory => return e,
        else => null,
    };
    return routeStructChanges(cc, ra, file, fidx, space, format, changes, composed, first_contact);
}

/// Route a set of changed key paths into their source layers: the shared
/// tail of the whole-file structured flow and the partial per-key flow.
/// Each change is one prompt item with the full `[y/p/s]`/pick machinery;
/// accepted edits are deferred to the write phase. `baseline` is what the
/// changes were diffed against, or null when it is unknown.
fn routeStructChanges(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    file: mox.source.tree.ManagedFile,
    fidx: usize,
    space: FileSpace,
    format: commit_struct.Format,
    changes: []const commit_struct.KeyPathChange,
    baseline: ?commit_struct.Baseline,
    first_contact: bool,
) !HunkOutcome {
    ra.affected[fidx] = true;

    const layers = structLayers(cc.arena, cc.io, file, cc.resolver, format) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            ra.manual_count.* += 1;
            ra.manual_hunks[fidx] += 1;
            ra.pending.* = true;
            try cc.stdout.print("  manual: {f}: a source layer could not be parsed ({s})\n", .{ display.of(file.live_path, cc.m_state.home), @errorName(e) });
            return .cont;
        },
    };
    const rel = try mox.source.path.liveKeyRelToHome(cc.arena, cc.m_state.home, file.live_path);

    for (changes, 0..) |change, ki| {
        const res = try commit_struct.resolveLayer(cc.arena, format, layers, change, baseline);
        if (res.action == .skip) {
            ra.manual_count.* += 1;
            ra.manual_hunks[fidx] += 1;
            ra.pending.* = true;
            try cc.stdout.print("  manual: {f} {s}: {s}\n", .{ display.of(file.live_path, cc.m_state.home), try keyPathLabel(cc.arena, change.path), res.skip_reason.? });
            continue;
        }
        if (first_contact and !cc.interactive) {
            try firstContactKeyManual(cc, ra, file, fidx, change);
            continue;
        }

        const winner_label = try structRouteLabel(cc.arena, file, layers, res, change);

        if (cc.report_mode) {
            ra.pending.* = true;
            ra.routed_count.* += 1;
            try cc.stdout.print("  would write {s} {s}\n", .{ rel, try keyPathLabel(cc.arena, change.path) });
            try printKeyChange(cc.arena, cc.sty, cc.stdout, change, winner_label);
            continue;
        }

        var chosen: ?usize = res.target;
        if (cc.interactive) {
            try printHunkHeader(cc.stdout, cc.sty, rel, "key", ki + 1, changes.len, winner_label);
            try printKeyChange(cc.arena, cc.sty, cc.stdout, change, winner_label);
            const legend_line = try legend(cc.arena, &struct_choices, 0, cc.sty);
            switch (try prompt.ask(cc.ask_mode, &struct_choices, 0, legend_line, cc.input, cc.stdout)) {
                .chosen => |i| switch (i) {
                    0 => chosen = res.target,
                    // `pickLayer` returns `.skip` when the user declines the
                    // pick's cross-configuration confirm (or the trailing
                    // skip) -- a deliberate decline like `[s]`. `.abort`/
                    // `.abort_strict` (real `q`/strict-abort inside the pick
                    // sub-menus) must quit the run exactly like everywhere
                    // else, not be swallowed as a per-key decline.
                    1 => switch (try pickLayer(cc, file, format, layers, res, change, space.configs)) {
                        .picked => |idx| chosen = idx,
                        .skip => chosen = null,
                        .abort => return .abort,
                        .abort_strict => return .abort_strict,
                    },
                    else => chosen = null, // skip
                },
                .abort => return .abort,
                .abort_strict => return .abort_strict,
                .report_only => unreachable,
            }
        }

        if (chosen) |chosen_idx| {
            switch (try recordStructPlacement(cc, ra, file, fidx, space, format, layers, res, chosen_idx, change)) {
                .placed => if (!cc.interactive)
                    try cc.stdout.print("  write {s} {s} -> {s}\n", .{ rel, try keyPathLabel(cc.arena, change.path), structLayerLabel(file, layers[chosen_idx]) }),
                .unroutable => {
                    ra.manual_count.* += 1;
                    ra.manual_hunks[fidx] += 1;
                    ra.pending.* = true;
                    try cc.stdout.print(
                        "  manual: {s} {s}: {s} cannot hold this key\n",
                        .{ file.live_path, try keyPathLabel(cc.arena, change.path), structLayerLabel(file, layers[chosen_idx]) },
                    );
                },
            }
        } else {
            ra.declined_hunks[fidx] += 1;
        }
    }
    return .cont;
}

/// Why `processFallbackFile` has no stored `last_content` to diff against:
/// mox never wrote this live path at all, or it did but the composition
/// resolved a secret whose cleartext is never cached. Either way a baseline
/// has to be recomposed fresh instead of read back.
const FallbackKind = union(enum) {
    first_contact,
    /// The applied record's content hash, checked against a fresh recompose
    /// before it is trusted as a baseline.
    secret: [mox.apply.applied.hash_hex_len]u8,
};

/// Route a live file that has NO stored baseline at all: recompose the
/// source fresh (resolving secrets, matching overlays) to build one, instead
/// of reading the applied-content cache the stored-baseline path uses. This
/// is a FALLBACK, used only here -- the stored `last_content` path above
/// (and its `sourceStillHolds` guard, which refuses a hunk whose source moved
/// on since the last apply) is untouched and still the one every edited
/// managed file with a stored baseline goes through.
///
/// `.first_contact`: the repo has a source for this file, but mox never
/// wrote it to this live path (no applied record at all) -- e.g. a file
/// inherited from another tool during a migration.
/// `.secret`: an applied record (content hash) exists, but a secret-bearing
/// composition's cleartext is never cached; the hash lets a mismatch (the
/// source changed since the apply, or the record is stale) be told apart
/// from a genuine live edit before the recompose is trusted as a baseline --
/// the same protection `sourceStillHolds` gives the stored path, applied here
/// because there is no stored baseline to check the recompose against
/// directly.
fn processFallbackFile(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    file: mox.source.tree.ManagedFile,
    fidx: usize,
    spaces: []?FileSpace,
    repo_dir: []const u8,
    live: []const u8,
    kind: FallbackKind,
) !HunkOutcome {
    if (kind == .secret and std.mem.eql(u8, &kind.secret, &mox.apply.applied.contentHashHex(live))) {
        // Unedited: live still holds exactly what mox last wrote. No need to
        // recompose (let alone resolve the secret) just to learn that.
        return .cont;
    }

    var prov: std.ArrayList(Segment) = .empty;
    const composed = mox.compose.composeFileTracked(cc.arena, cc.io, file, cc.resolver, cc.m_state, cc.secrets, &prov, null) catch |e| {
        if (kind == .secret) {
            try cc.stdout.print(
                "  cannot verify {s}: the secret-derived content could not be recomposed ({s}); overwrite or skip\n",
                .{ file.live_path, @errorName(e) },
            );
        } else {
            try cc.stdout.print("  manual: {f} (compose failed: {s})\n", .{ display.of(file.live_path, cc.m_state.home), @errorName(e) });
        }
        ra.manual_count.* += 1;
        ra.manual_hunks[fidx] += 1;
        ra.pending.* = true;
        return .cont;
    };
    // Null covers two distinct cases compose does not tell apart: a real
    // whole-file `when` gate evaluating false (nothing to route -- same as
    // the stored-baseline path's own gate-off treatment), and, for a
    // structured file, no layer at all -- not even a base -- matching this
    // machine (there is no existing target to route a key change to). A
    // first-contact structured file with zero matching layers is exactly the
    // second case: create one instead of silently doing nothing.
    const baseline = composed orelse {
        if (kind == .first_contact) {
            if (commit_struct.formatOfPath(file.source_base_path)) |format| {
                const layers = structLayers(cc.arena, cc.io, file, cc.resolver, format) catch &.{};
                if (layers.len == 0) return createFirstContactOverlay(cc, ra, file, fidx, spaces, format, live, repo_dir);
            }
        }
        return .cont;
    };

    if (kind == .secret and !std.mem.eql(u8, &kind.secret, &mox.apply.applied.contentHashHex(baseline))) {
        // The source moved on since the apply that recorded this hash (or the
        // record is stale): the fresh recompose is not provably what mox last
        // wrote, so it is not a safe baseline to diff a live edit against.
        try cc.stdout.print(
            "  cannot verify {s}: the secret-derived content no longer matches what mox last applied; overwrite or skip\n",
            .{file.live_path},
        );
        ra.manual_count.* += 1;
        ra.manual_hunks[fidx] += 1;
        ra.pending.* = true;
        return .cont;
    }
    if (std.mem.eql(u8, live, baseline)) return .cont;

    const has_secret = mox.provenance.map.hasSecret(prov.items);
    // A `.secret`-origin segment must never reach the structured key-diff
    // path: `printKeyChange` prints a changed key's OLD value with no
    // equivalent guard to the line-hunk path's `hunkTouchesSecret`, so a
    // changed secret key would leak its old resolved value there. The plain
    // line-hunk path below is the one path proven safe for a `.secret`
    // origin, so any secret-bearing file is routed through it regardless of
    // format -- a non-secret key elsewhere in the same overlaid file reports
    // manual ("came from a structural merge") rather than routing by key,
    // which is conservative, not unsafe.
    if (!has_secret) {
        if (commit_struct.formatOfPath(file.source_base_path)) |sf| {
            if (containsOverlayOrigin(prov.items)) {
                spaces[fidx] = try structFileSpace(cc.arena, cc.io, cc.this_bindings, file, repo_dir);
                return processStructFile(cc, ra, file, fidx, spaces[fidx].?, sf, baseline, live, kind == .first_contact);
            }
        }
    }

    // A placeholder recompose (no secrets context, so `<secret:URI>` stays
    // literal `<SECRET:uri>` text) index-aligned with `baseline`'s lines, so
    // a `.secret`-touching hunk can recover the store URI without ever
    // resolving or displaying the old cleartext.
    var secret_lines: ?[]const []const u8 = null;
    if (has_secret) {
        var placeholder_prov: std.ArrayList(Segment) = .empty;
        if (mox.compose.composeFileTracked(cc.arena, cc.io, file, cc.resolver, cc.m_state, null, &placeholder_prov, null) catch null) |placeholder| {
            secret_lines = mox.diff.lines.splitLines(cc.arena, placeholder) catch null;
        }
    }

    const a_lines = try mox.diff.lines.splitLines(cc.arena, baseline);
    const b_lines = try mox.diff.lines.splitLines(cc.arena, live);
    const hunks = mox.diff.lines.diff(cc.arena, a_lines, b_lines) catch |e| switch (e) {
        error.TooManyLines => {
            try cc.stdout.print("  manual: {f} (too large to diff)\n", .{display.of(file.live_path, cc.m_state.home)});
            ra.manual_count.* += 1;
            ra.manual_hunks[fidx] += 1;
            ra.pending.* = true;
            return .cont;
        },
        else => return e,
    };

    if (spaces[fidx] == null) spaces[fidx] = try fileSpace(cc.arena, cc.io, cc.this_bindings, file);
    const space = spaces[fidx].?;

    // First-contact keep is never a silent keep-all: every hunk goes through
    // the SAME per-hunk `processHunk` the stored-baseline path uses, which
    // already confirms `[y/s]` on a terminal -- a rendering difference from
    // another tool (whitespace, trailing newline, key order) shows up as a
    // spurious hunk the user skips there, exactly like any other hunk.
    var lf: LoopFile = .{ .file = file, .stored = false, .segments = prov.items, .a_lines = a_lines, .b_lines = b_lines, .hunks = hunks };
    for (hunks, 0..) |hunk, hi| {
        switch (try processHunk(cc, ra, file, fidx, space, prov.items, a_lines, b_lines, hunk, hi + 1, hunks.len, secret_lines, kind == .first_contact, &lf)) {
            .cont => {},
            .abort => return .abort,
            .abort_strict => return .abort_strict,
        }
    }
    return .cont;
}

/// A first-contact structured file for which NO layer -- not even a base --
/// matches this machine's bindings: there is no existing target to route a
/// key change to at all. Creates one, scoped to this machine's own values for
/// the axes the file's OTHER layers already vary on, at the same `.d/`+tuple
/// path `mox edit --axis` names, seeded with the live file's content -- every
/// key in it is new by definition, since nothing composes here yet.
fn createFirstContactOverlay(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    file: mox.source.tree.ManagedFile,
    fidx: usize,
    spaces: []?FileSpace,
    format: commit_struct.Format,
    live: []const u8,
    repo_dir: []const u8,
) !HunkOutcome {
    const ax = try mox.source.axes.ofFile(cc.arena, cc.io, file);
    var pairs: std.ArrayList(mox.source.tree.AxisTuple.Pair) = .empty;
    var it = ax.compared.keyIterator();
    while (it.next()) |name| {
        const value = cc.this_bindings.get(name.*) orelse {
            try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {f} (no source matches this machine; axis '{s}' is unbound here)\n", .{ display.of(file.live_path, cc.m_state.home), name.* });
            return .cont;
        };
        // A fact value is arbitrary text; this one is about to become a
        // filename. Without the check, a value holding `/` builds an overlay
        // path outside the source tree, and one holding `=` or `+` names a
        // tuple no later command can read back.
        if (!mox.source.tuple.isNameableAxisValue(value)) {
            try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {f} (axis '{s}' is bound to a value that cannot name an overlay)\n", .{ display.of(file.live_path, cc.m_state.home), name.* });
            return .cont;
        }
        try pairs.append(cc.arena, .{ .name = name.*, .value = value });
    }
    if (pairs.items.len == 0) {
        try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {f} (no source matches this machine)\n", .{display.of(file.live_path, cc.m_state.home)});
        return .cont;
    }
    std.mem.sort(mox.source.tree.AxisTuple.Pair, pairs.items, {}, lessPairName);
    const tuple: mox.source.tree.AxisTuple = .{ .pairs = pairs.items };
    const tuple_name = try edit_mod.tupleFilename(cc.arena, tuple);
    const base_abs = try std.fs.path.join(cc.arena, &.{ repo_dir, file.source_base_path });
    const overlay_dir = try std.fmt.allocPrint(cc.arena, "{s}.d", .{base_abs});
    const target_path = try mox.source.path.joinKeyOnto(cc.arena, overlay_dir, tuple_name);

    const changes = commit_struct.changedKeyPaths(cc.arena, format, emptyDocText(format), live) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {f} could not be parsed as {s}; edit its source directly\n", .{ display.of(file.live_path, cc.m_state.home), @tagName(format) });
            return .cont;
        },
    };
    if (changes.len == 0) return .cont;

    ra.affected[fidx] = true;
    if (spaces[fidx] == null) spaces[fidx] = try structFileSpace(cc.arena, cc.io, cc.this_bindings, file, repo_dir);
    if (!cc.interactive) {
        for (changes) |change| try firstContactKeyManual(cc, ra, file, fidx, change);
        return .cont;
    }
    const space = spaces[fidx].?;
    const rel = try mox.source.path.liveKeyRelToHome(cc.arena, cc.m_state.home, file.live_path);
    const overlay_name = std.fs.path.basename(target_path);

    for (changes, 0..) |change, ki| {
        const label = try std.fmt.allocPrint(cc.arena, "new overlay {s}", .{overlay_name});
        try printHunkHeader(cc.stdout, cc.sty, rel, "key", ki + 1, changes.len, label);
        try printKeyChange(cc.arena, cc.sty, cc.stdout, change, label);
        const legend_line = try legend(cc.arena, &ys_choices, 0, cc.sty);
        const accept = switch (try prompt.ask(cc.ask_mode, &ys_choices, 0, legend_line, cc.input, cc.stdout)) {
            .chosen => |i| i == 0,
            .abort => return .abort,
            .abort_strict => return .abort_strict,
            .report_only => unreachable,
        };
        if (accept) {
            const edits = [_]StructEdit{.{ .format = format, .layer_abs = target_path, .change = change }};
            if (space.configs.len > 1) {
                switch (try simulateStructImpact(cc, file, &edits, space.configs)) {
                    .ok => |imp| for (imp.affected) |l| try ra.allowed[fidx].put(l, {}),
                    .rejected => {
                        ra.manual_count.* += 1;
                        ra.manual_hunks[fidx] += 1;
                        ra.pending.* = true;
                        try cc.stdout.print("  manual: {f} {s}: the new overlay cannot hold this key\n", .{ display.of(file.live_path, cc.m_state.home), try keyPathLabel(cc.arena, change.path) });
                        continue;
                    },
                }
            }
            try ra.struct_edits.append(cc.arena, edits[0]);
            try ra.struct_owners.append(cc.arena, fidx);
            ra.routed_count.* += 1;
        } else {
            ra.declined_hunks[fidx] += 1;
        }
    }
    return .cont;
}

fn lessPairName(_: void, a: mox.source.tree.AxisTuple.Pair, b: mox.source.tree.AxisTuple.Pair) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// The empty-document text `changedKeyPaths` parses to mean "nothing composes
/// yet" for `format`, so every key in a live file diffed against it reads as
/// newly added.
fn emptyDocText(format: commit_struct.Format) []const u8 {
    return switch (format) {
        .toml, .ini, .gitconfig => "",
        .json, .yaml => "{}",
    };
}

/// Route a managed symlink whose live target no longer matches what mox last
/// recorded there. A symlink's source is a regular file whose composed,
/// trimmed content IS the target -- keep syncs the source to the live target,
/// but only when the recorded target is a plain literal. When the source
/// target holds a capture (`<machine.X>`) or a `<secret:...>`, the composed
/// and live targets differing is expected (they differ in the resolved
/// value), and literal-syncing would bake that resolved value into the
/// source, permanently discarding the capture -- so this always refuses, and
/// a secret-derived target is never even considered for a literal write.
fn processSymlinkFile(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    file: mox.source.tree.ManagedFile,
    fidx: usize,
    state_dir: []const u8,
    sym_syncs: *std.ArrayList(SymSync),
) !HunkOutcome {
    const site = mox.apply.applied.inspectSymSite(cc.io, cc.arena, file.live_path);
    // A directory, a plain file, or an absent path where a symlink belongs is
    // not something `keep` can route (no target string to compare against) --
    // `mox apply --overwrite` is the resolution for those, not commit.
    if (site != .symlink) return .cont;
    const live_target = site.symlink;

    const recorded_target = try mox.apply.applied.readSymlink(cc.arena, cc.io, state_dir, file.live_path);

    var prov: std.ArrayList(Segment) = .empty;
    const composed = mox.compose.composeFileTracked(cc.arena, cc.io, file, cc.resolver, cc.m_state, cc.secrets, &prov, null) catch |e| {
        try cc.stdout.print("  manual: {f} (compose failed: {s})\n", .{ display.of(file.live_path, cc.m_state.home), @errorName(e) });
        ra.manual_count.* += 1;
        ra.manual_hunks[fidx] += 1;
        ra.pending.* = true;
        return .cont;
    };
    // A whole-file `when` gate false for this machine: nothing composes here,
    // so there is no current target to compare the live one against.
    const bytes = composed orelse return .cont;
    const composed_target = std.mem.trim(u8, bytes, " \t\r\n");

    // The SAME disposition rule `mox apply`/`mox status` classify by: not
    // drift covers both an already-matching link and a "safe reassert" (the
    // live link is exactly what mox last wrote, and only a binding changed
    // since) -- neither needs `keep`.
    if (mox.apply.drift.symlinkDisposition(site, recorded_target, composed_target) != .drift) return .cont;

    const has_secret = mox.provenance.map.hasSecret(prov.items);
    const has_capture = has_secret or hasInterpolated(prov.items);
    if (has_capture) {
        const why = if (has_secret)
            "its target is derived from a secret"
        else
            "its target is derived from a capture (e.g. <machine.X>)";
        try cc.stdout.print(
            "  manual: {s} (symlink target changed, but {s}; keeping would discard it -- edit the source directly)\n",
            .{ file.live_path, why },
        );
        ra.manual_count.* += 1;
        ra.manual_hunks[fidx] += 1;
        ra.pending.* = true;
        return .cont;
    }

    // A literal write is safe only when the composed target came from a
    // plain, directiveless base passthrough -- one segment, `.base` origin.
    // Any other shape (a region gate, an included fragment, a loop row) means
    // the target varies by configuration; baking today's live target into the
    // source would collapse every other configuration's target into this
    // one, permanently. That structural loss carries no capture and no
    // secret, so `has_capture` above never sees it -- this check does.
    if (!isPlainLiteralTarget(prov.items)) {
        try cc.stdout.print(
            "  manual: {s} (symlink target changed, but its source varies by configuration; keeping would collapse that structure to one literal target -- edit the source directly)\n",
            .{file.live_path},
        );
        ra.manual_count.* += 1;
        ra.manual_hunks[fidx] += 1;
        ra.pending.* = true;
        return .cont;
    }

    // No recorded target: mox never wrote this link, so no non-interactive
    // mode adopts its target into the source.
    if (recorded_target == null and !cc.interactive) {
        ra.manual_count.* += 1;
        ra.manual_hunks[fidx] += 1;
        ra.pending.* = true;
        try cc.stdout.print("  manual: {f}: first contact, needs confirmation\n", .{display.of(file.live_path, cc.m_state.home)});
        return .cont;
    }

    var accept = !cc.report_mode and !cc.interactive;
    if (cc.report_mode) {
        ra.pending.* = true;
        ra.routed_count.* += 1;
        try cc.stdout.print("  would keep {f}: symlink target -> {s}\n", .{ display.of(file.live_path, cc.m_state.home), live_target });
        return .cont;
    }
    if (cc.interactive) {
        try printHunkHeader(cc.stdout, cc.sty, file.live_path, "symlink", 1, 1, "symlink target");
        try cc.sty.green(cc.stdout);
        try cc.stdout.print("    + {s}\n", .{live_target});
        try cc.sty.close(cc.stdout);
        const legend_line = try legend(cc.arena, &ys_choices, 0, cc.sty);
        switch (try prompt.ask(cc.ask_mode, &ys_choices, 0, legend_line, cc.input, cc.stdout)) {
            .chosen => |i| switch (i) {
                0 => accept = true,
                else => ra.declined_hunks[fidx] += 1,
            },
            .abort => return .abort,
            .abort_strict => return .abort_strict,
            .report_only => unreachable,
        }
    }
    if (accept) {
        ra.routed_count.* += 1;
        try sym_syncs.append(cc.arena, .{
            .live_path = file.live_path,
            .source_abs = file.source_base_abs,
            .new_target = try cc.arena.dupe(u8, live_target),
        });
        if (!cc.interactive) try cc.stdout.print("  write {s} -> new symlink target {s}\n", .{ file.source_base_path, live_target });
    }
    return .cont;
}

/// True when any segment in `segments` is `.interpolated`: the source held a
/// `<machine.X>` capture that machine interpolation rewrote to a resolved
/// value. Used the same way `hasSecret` is -- to decide a target is
/// capture-derived and must never be literal-synced.
fn hasInterpolated(segments: []const Segment) bool {
    for (segments) |s| {
        if (s.origin == .interpolated) return true;
    }
    return false;
}

/// True when `segments` is exactly one segment whose origin is a plain
/// base-file passthrough: the source is nothing but the target line, with no
/// region, fragment, or loop structure that could compose a different target
/// under a different configuration. Anything else -- a region gate and an
/// included fragment both land as `.overlay`, a loop row as `.loop`, a
/// private fragment as `.private` -- means literal-syncing would bake this
/// machine's target over structure another configuration depends on.
fn isPlainLiteralTarget(segments: []const Segment) bool {
    return segments.len == 1 and segments[0].origin == .base;
}

/// A generator (`for ... into`, or `completions`) has no single live path of
/// its own -- `outputs` is its already-re-expanded produced set (the SAME
/// `composeGenerator` call apply uses). Diff each produced leaf against its
/// live file and route hunks by origin; `only_leaves`, when set, restricts
/// this to the named leaves (a scoped `mox commit <leaf-path>`) instead of
/// the whole set (`mox commit` unscoped, or `mox commit <generator-path>`).
fn processGeneratorFile(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    gen_file: mox.source.tree.ManagedFile,
    fidx: usize,
    outputs: []const mox.compose.catB.GeneratedFile,
    only_leaves: ?*const std.StringHashMap(void),
    state_dir: []const u8,
    gen: *LeafRowEdits,
) !HunkOutcome {
    for (outputs) |leaf| {
        if (only_leaves) |set| {
            // The set holds key-form paths (see the scoped-leaves build); a
            // produced leaf's path can be `/`-joined even on Windows, so
            // normalize it the same way before the membership test.
            if (!set.contains(try mox.source.path.toKey(cc.arena, leaf.live_path))) continue;
        }
        switch (try processGeneratorLeaf(cc, ra, gen_file, fidx, leaf, state_dir, gen)) {
            .cont => {},
            .abort => return .abort,
            .abort_strict => return .abort_strict,
        }
    }
    return .cont;
}

/// Diff one produced leaf's composed baseline against its live file, routing
/// each hunk. A leaf whose live path is absent was pruned (or never written);
/// nothing to keep. A leaf with no applied record is first contact: mox never
/// wrote it, so no non-interactive mode routes its rows.
fn processGeneratorLeaf(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    gen_file: mox.source.tree.ManagedFile,
    fidx: usize,
    leaf: mox.compose.catB.GeneratedFile,
    state_dir: []const u8,
    gen: *LeafRowEdits,
) !HunkOutcome {
    const live = Io.Dir.cwd().readFileAlloc(cc.io, leaf.live_path, cc.arena, .limited(max_file_bytes)) catch |e| switch (e) {
        error.FileNotFound => return .cont,
        else => return e,
    };
    if (std.mem.eql(u8, live, leaf.content)) return .cont;
    const recorded = try mox.apply.applied.read(cc.arena, cc.io, state_dir, leaf.live_path);
    const first_contact = recorded == null;
    // Live as the last apply wrote it has no drift, whatever the data now
    // renders; edited over a data row that changed since, no hunk is that
    // row's.
    var stale = false;
    if (recorded) |hash| {
        if (std.mem.eql(u8, &hash, &mox.apply.applied.contentHashHex(live))) return .cont;
        stale = leaf.data_source.len > 0 and !std.mem.eql(u8, &hash, &mox.apply.applied.contentHashHex(leaf.content));
    }

    // A placeholder recompose of this SAME leaf (secrets unresolved, so a
    // `<secret:URI>` capture stays literal `<SECRET:uri>` text) lets a
    // secret-touching hunk recover the store URI without ever resolving or
    // displaying the old cleartext -- mirrors `processFallbackFile`.
    var secret_lines: ?[]const []const u8 = null;
    if (leaf.contains_secret) {
        var pdiag: mox.compose.interp.Diag = .{};
        if (mox.compose.catB.composeGenerator(cc.arena, cc.io, gen_file, cc.resolver, cc.m_state, null, &pdiag) catch null) |placeholder_outputs| {
            for (placeholder_outputs) |po| {
                if (!std.mem.eql(u8, po.live_path, leaf.live_path)) continue;
                secret_lines = mox.diff.lines.splitLines(cc.arena, po.content) catch null;
                break;
            }
        }
    }

    const a_lines = try mox.diff.lines.splitLines(cc.arena, leaf.content);
    const b_lines = try mox.diff.lines.splitLines(cc.arena, live);
    const hunks = mox.diff.lines.diff(cc.arena, a_lines, b_lines) catch |e| switch (e) {
        error.TooManyLines => {
            try cc.stdout.print("  manual: {f} (too large to diff)\n", .{display.of(leaf.live_path, cc.m_state.home)});
            ra.manual_count.* += 1;
            ra.manual_hunks[fidx] += 1;
            ra.pending.* = true;
            return .cont;
        },
        else => return e,
    };

    for (hunks, 0..) |hunk, hi| {
        switch (try processGeneratedHunk(cc, ra, gen_file, fidx, leaf, a_lines, b_lines, hunk, hi + 1, hunks.len, secret_lines, first_contact, stale, gen)) {
            .cont => {},
            .abort => return .abort,
            .abort_strict => return .abort_strict,
        }
    }
    return .cont;
}

/// Route one hunk of a generator leaf: a secret line is never routed (shown
/// safely, never written); nor is any hunk of a leaf edited over a row that
/// changed since the last apply, or of a leaf whose row renders several
/// lines. A single-line change the row's own template splits into row fields
/// routes to that DATA-SOURCE ROW when the row checks hold; anything else --
/// a multi-line change, a nested (directive-bearing) leaf body with no
/// tracked template, or a live edit the template cannot explain as a field
/// substitution -- comes from the generator's SHARED TEMPLATE, which every
/// leaf this generator produces shares, so it is surfaced and never silently
/// routed as though it were this leaf's own.
fn processGeneratedHunk(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    gen_file: mox.source.tree.ManagedFile,
    fidx: usize,
    leaf: mox.compose.catB.GeneratedFile,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
    hunk: Hunk,
    hunk_no: usize,
    hunk_total: usize,
    secret_lines: ?[]const []const u8,
    first_contact: bool,
    stale: bool,
    gen: *LeafRowEdits,
) !HunkOutcome {
    if (hunkTouchesSecret(leaf.prov, hunk)) {
        return reportGeneratedManual(cc, ra, fidx, leaf, hunk, hunk_no, hunk_total, secret_lines, a_lines, b_lines, "came from a secret", true);
    }
    if (stale) return reportGeneratedManual(cc, ra, fidx, leaf, hunk, hunk_no, hunk_total, null, a_lines, b_lines, "data row no longer matches what the last apply wrote", false);

    if (leaf.template.len > 0) {
        if (a_lines.len > 1) return reportGeneratedManual(cc, ra, fidx, leaf, hunk, hunk_no, hunk_total, null, a_lines, b_lines, "data row spans several lines", false);
        if (hunk.a_len == 1 and hunk.b_len == 1) {
            const site: RowSite = .{
                .data_source = leaf.data_source,
                .row = @intCast(leaf.row),
                .template = leaf.template,
                .variable = leaf.variable,
                .where = leaf.where,
                .leaf = .{ .into = leaf.into, .dir = std.fs.path.dirname(gen_file.live_path) orelse gen_file.live_path, .live_path = leaf.live_path },
            };
            switch (try planRowWrite(cc, gen_file, site, b_lines[hunk.b_start])) {
                .no_match => {},
                .manual => |reason| return reportGeneratedManual(cc, ra, fidx, leaf, hunk, hunk_no, hunk_total, null, a_lines, b_lines, reason, false),
                .write => |w| {
                    if (first_contact and !cc.interactive) return firstContactLeafManual(cc, ra, fidx, leaf, hunk);
                    return acceptGeneratedRow(cc, ra, gen_file, fidx, leaf, hunk, hunk_no, hunk_total, a_lines, b_lines, w.splices, gen);
                },
            }
        }
    }

    return reportGeneratedManual(
        cc,
        ra,
        fidx,
        leaf,
        hunk,
        hunk_no,
        hunk_total,
        null,
        a_lines,
        b_lines,
        try std.fmt.allocPrint(
            cc.arena,
            "comes from the generator's shared template -- this generator produces one file per row, and every one of them shares this text; edit the generator's source directly ({s})",
            .{gen_file.source_base_path},
        ),
        false,
    );
}

/// Accept (or prompt for) a leaf hunk routed to a data-source row write, and
/// collect it; report mode collects it too, never to be written. `[y/s]` on
/// a terminal; `--yes` (and any other non-interactive, non-report mode)
/// auto-accepts. A first-contact
/// leaf never reaches here unless a human is answering: `processGeneratedHunk`
/// reports it manual first.
fn acceptGeneratedRow(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    gen_file: mox.source.tree.ManagedFile,
    fidx: usize,
    leaf: mox.compose.catB.GeneratedFile,
    hunk: Hunk,
    hunk_no: usize,
    hunk_total: usize,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
    splices: []const LineEdit,
    gen: *LeafRowEdits,
) !HunkOutcome {
    ra.routed_count.* += 1;
    const desc = try std.fmt.allocPrint(cc.arena, "{s} row {d}", .{ leaf.data_source, leaf.row });
    var accept = !cc.report_mode and !cc.interactive;
    if (cc.report_mode) {
        ra.pending.* = true;
        try cc.stdout.print("  would update {s}\n", .{desc});
        try printMiniDiff(cc.sty, cc.stdout, hunk, a_lines, b_lines);
        // Collected so report mode predicts the coupling updates a real
        // commit would drop over it; never written.
        try collectLeafRow(cc, gen_file, fidx, leaf, splices, gen);
        return .cont;
    }
    if (cc.interactive) {
        try printHunkHeader(cc.stdout, cc.sty, leaf.live_path, "hunk", hunk_no, hunk_total, desc);
        try printMiniDiff(cc.sty, cc.stdout, hunk, a_lines, b_lines);
        const legend_line = try legend(cc.arena, &ys_choices, 0, cc.sty);
        switch (try prompt.ask(cc.ask_mode, &ys_choices, 0, legend_line, cc.input, cc.stdout)) {
            .chosen => |i| switch (i) {
                0 => accept = true,
                else => ra.declined_hunks[fidx] += 1,
            },
            .abort => return .abort,
            .abort_strict => return .abort_strict,
            .report_only => unreachable,
        }
    }
    if (accept) {
        try collectLeafRow(cc, gen_file, fidx, leaf, splices, gen);
        if (!cc.interactive) try cc.stdout.print("  update {s}\n", .{desc});
    }
    return .cont;
}

/// Collect a leaf's row write, with the leaf it was routed from.
fn collectLeafRow(
    cc: *const ClassCtx,
    gen_file: mox.source.tree.ManagedFile,
    fidx: usize,
    leaf: mox.compose.catB.GeneratedFile,
    splices: []const LineEdit,
    gen: *LeafRowEdits,
) !void {
    const li = for (gen.leaves.items, 0..) |gc, i| {
        if (std.mem.eql(u8, gc.leaf_live_path, leaf.live_path)) break i;
    } else blk: {
        try gen.leaves.append(cc.arena, .{ .fidx = fidx, .gen_file = gen_file, .leaf_live_path = leaf.live_path });
        break :blk gen.leaves.items.len - 1;
    };
    try gen.row_edits.append(cc.arena, .{
        .data_source = leaf.data_source,
        .stem = mox.data.source.arrayName(leaf.data_source),
        .row = @intCast(leaf.row),
        .splices = splices,
        .template = leaf.template,
        .variable = leaf.variable,
        .where = leaf.where,
        .into = leaf.into,
    });
    try gen.row_leaves.append(cc.arena, li);
}

/// Report one generator-leaf hunk as manual: same `[s/x]` shape as
/// `processHunk`'s own manual branch (secret-safe display when
/// `touches_secret`, plain mini-diff otherwise), because a generator leaf has
/// no sub-origin boundaries to split on -- `split` always falls through to
/// "nothing to split", exactly like an uncovered hunk in a regular file.
fn reportGeneratedManual(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    fidx: usize,
    leaf: mox.compose.catB.GeneratedFile,
    hunk: Hunk,
    hunk_no: usize,
    hunk_total: usize,
    secret_lines: ?[]const []const u8,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
    reason: []const u8,
    touches_secret: bool,
) !HunkOutcome {
    if (!cc.interactive) {
        ra.manual_count.* += 1;
        ra.manual_hunks[fidx] += 1;
        ra.pending.* = true;
        try cc.stdout.print("  manual: {f}:{d} {s}\n", .{ display.of(leaf.live_path, cc.m_state.home), hunk.a_start + 1, reason });
        return .cont;
    }
    try printHunkHeader(cc.stdout, cc.sty, leaf.live_path, "hunk", hunk_no, hunk_total, try std.fmt.allocPrint(cc.arena, "manual -- {s}", .{reason}));
    if (touches_secret) {
        try printSecretNotice(cc, secret_lines, hunk, b_lines);
    } else {
        try printMiniDiff(cc.sty, cc.stdout, hunk, a_lines, b_lines);
    }
    const legend_line = try legend(cc.arena, &sx_choices, 0, cc.sty);
    switch (try prompt.ask(cc.ask_mode, &sx_choices, 0, legend_line, cc.input, cc.stdout)) {
        .chosen => |i| switch (i) {
            0 => {
                ra.manual_count.* += 1;
                ra.manual_hunks[fidx] += 1;
                ra.pending.* = true;
                try cc.stdout.print("  manual: {f}:{d} {s}\n", .{ display.of(leaf.live_path, cc.m_state.home), hunk.a_start + 1, reason });
            },
            else => {
                ra.manual_count.* += 1;
                ra.manual_hunks[fidx] += 1;
                ra.pending.* = true;
                try cc.stdout.print("  nothing to split: {f}:{d} lies in no single source\n", .{ display.of(leaf.live_path, cc.m_state.home), hunk.a_start + 1 });
                try cc.stdout.print("  manual: {f}:{d} {s}\n", .{ display.of(leaf.live_path, cc.m_state.home), hunk.a_start + 1, reason });
            },
        },
        .abort => return .abort,
        .abort_strict => return .abort_strict,
        .report_only => unreachable,
    }
    return .cont;
}

/// The output in `outputs` (a fresh `composeGenerator` re-expansion) whose
/// live path is `live_path`, or null when it is absent (the row was removed,
/// `where` no longer matches it, or the re-expansion itself failed).
fn findGeneratedByLive(outputs: ?[]const mox.compose.catB.GeneratedFile, live_path: []const u8) ?mox.compose.catB.GeneratedFile {
    const outs = outputs orelse return null;
    for (outs) |o| {
        if (std.mem.eql(u8, o.live_path, live_path)) return o;
    }
    return null;
}

/// A partially owned file's commit gate: decide committability from the
/// owned record and the extracted live owned document, then hand the changed
/// keys to the structured per-key routing. `last` is the record's canonical
/// serialization and `live` the live document's, both restricted to the
/// record-scope paths, so program activity outside the owned paths can never
/// surface. A path newly added to `own` is per-path first contact: only
/// apply may take ownership of its live content, so a difference there is
/// reported, never routed.
fn processPartialFile(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    file: mox.source.tree.ManagedFile,
    fidx: usize,
    spaces: []?FileSpace,
    repo_dir: []const u8,
    state_dir: []const u8,
    skipped_secret: *usize,
) !HunkOutcome {
    const arena = cc.arena;
    const partial_mod = mox.apply.partial;
    const canon_mod = mox.apply.canonical;
    const owned_mod = mox.apply.owned;
    const live_path = file.live_path;
    const own_paths = file.own_paths;
    // The walk only attaches own_paths to structured targets.
    const format = commit_struct.formatOfPath(file.source_base_path).?;

    var prov: std.ArrayList(Segment) = .empty;
    var cdiag: mox.compose.interp.Diag = .{};
    const composed = mox.compose.composeFileTracked(arena, cc.io, file, cc.resolver, cc.m_state, cc.secrets, &prov, &cdiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} (compose failed: {s})\n", .{ live_path, @errorName(e) });
            return .cont;
        },
    };
    // A whole-file gate off for this machine leaves the live file untouched
    // by apply, so there is nothing to route back.
    const bytes = composed orelse return .cont;

    const mode: mox.apply.applied.Mode = if (file.ownership == .disown) .disown else .own;
    const owned = partial_mod.OwnedDoc.parse(arena, format, bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => {
            try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} (composed source does not parse as {s})\n", .{ live_path, @tagName(format) });
            return .cont;
        },
    };
    switch (mode) {
        .own => if (try partial_mod.undeclaredLeaf(arena, &owned, own_paths)) |leaf| {
            try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} (composed leaf {s} is outside the declared own paths)\n", .{ live_path, leaf });
            return .cont;
        },
        .disown => if (try partial_mod.populatedDisownPath(arena, &owned, own_paths)) |spelled| {
            try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} (composed source defines content under disowned path {s})\n", .{ live_path, spelled });
            return .cont;
        },
    }

    // Read through a symlinked live path exactly as apply patches it: via the
    // resolved target. A dangling link is the shape apply refuses.
    const live_target = mox.apply.write.resolvePartialLive(arena, cc.io, live_path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DanglingLink => {
            try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} (live path is a dangling symlink; fix or remove the link)\n", .{live_path});
            return .cont;
        },
    };
    // Kind guard BEFORE the open: a FIFO here would block the read and brick
    // the whole commit.
    if (mox.apply.write.guardLiveRead(cc.io, live_target) == .special) {
        try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} (not a regular file)\n", .{live_path});
        return .cont;
    }
    const live = Io.Dir.cwd().readFileAlloc(cc.io, live_target, arena, .limited(max_file_bytes)) catch |e| switch (e) {
        error.FileNotFound => return .cont,
        else => return e,
    };
    const live_doc = partial_mod.OwnedDoc.parse(arena, format, live) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnedUnparseable => {
            try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} could not be parsed as {s}; edit its source directly\n", .{ live_path, @tagName(format) });
            return .cont;
        },
    };

    const record = try mox.apply.applied.readOwned(arena, cc.io, state_dir, live_path);
    const record_paths: []const mox.source.tree.OwnPath = if (record) |r| try owned_mod.parseRawPaths(arena, r.own_paths) else &.{};

    // Only owned drift is committable: clean has nothing to route, and
    // outdated is the source moving on, resolved by apply.
    switch (try owned_mod.classifyMode(arena, mode, &owned, &live_doc, own_paths, record, record_paths)) {
        .clean, .outdated => return .cont,
        .drift => {},
    }

    const rec = record orelse {
        try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} (no owned record: first contact; 'mox apply' adopts matching live content, 'mox apply --overwrite' reasserts the source)\n", .{live_path});
        return .cont;
    };
    if (rec.secret) {
        // The record is a hash; there is no cleartext to diff against.
        try cc.stdout.print("  skipped {s} (contains a secret; edit its source directly)\n", .{live_path});
        skipped_secret.* += 1;
        ra.pending.* = true;
        return .cont;
    }

    // Record scope in the file's mode. Own: paths in both the record-time
    // and current lists take the per-key diff; a current-only path is
    // per-path first contact. Disown, inverted: a path REMOVED from the
    // disown list is first contact for its now-owned content, and the
    // comparable scope is the complement of the union of both lists.
    var last_blob_text: []const u8 = "";
    var live_blob: []const u8 = "";
    switch (mode) {
        .own => {
            var scope_paths: std.ArrayList(mox.source.tree.OwnPath) = .empty;
            for (own_paths) |p| {
                if (owned_mod.pathInList(p.segments, record_paths)) {
                    try scope_paths.append(arena, p);
                    continue;
                }
                const one = [_]mox.source.tree.OwnPath{p};
                const live_sec = try canon_mod.canonicalOwned(arena, &live_doc, &one);
                const composed_sec = try canon_mod.canonicalOwned(arena, &owned, &one);
                if (!std.mem.eql(u8, live_sec, composed_sec)) {
                    try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} {s}: first contact for this path; 'mox apply --overwrite' adopts or reasserts it\n", .{ live_path, try canon_mod.pathSpell(arena, p.segments) });
                }
            }
            var last_blob: std.ArrayList(u8) = .empty;
            for (scope_paths.items) |p| {
                const spelled = try canon_mod.pathSpell(arena, p.segments);
                if (canon_mod.sectionOf(rec.canonical.?, spelled)) |sec| try last_blob.appendSlice(arena, sec);
            }
            last_blob_text = try last_blob.toOwnedSlice(arena);
            live_blob = try canon_mod.canonicalOwned(arena, &live_doc, scope_paths.items);
        },
        .disown => {
            for (record_paths) |r| {
                if (owned_mod.pathInList(r.segments, own_paths)) continue;
                const one = [_]mox.source.tree.OwnPath{r};
                const live_sec = try canon_mod.canonicalOwned(arena, &live_doc, &one);
                const composed_sec = try canon_mod.canonicalOwned(arena, &owned, &one);
                if (!std.mem.eql(u8, live_sec, composed_sec)) {
                    try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} {s}: first contact for this path; 'mox apply --overwrite' adopts or reasserts it\n", .{ live_path, try canon_mod.pathSpell(arena, r.segments) });
                }
            }
            last_blob_text = owned_mod.recordComplement(arena, owned.format, rec, record_paths, own_paths) orelse {
                try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} (owned record unreadable; run 'mox apply' to refresh it)\n", .{live_path});
                return .cont;
            };
            const union_paths = try owned_mod.unionPaths(arena, own_paths, record_paths);
            live_blob = try canon_mod.canonicalComplement(arena, &live_doc, union_paths);
        },
    }
    // Drift confined to first-contact paths: nothing per-key to route.
    if (std.mem.eql(u8, last_blob_text, live_blob)) return .cont;

    const diffres = ownedKeyDiff(arena, last_blob_text, live_blob, &live_doc) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unrepresentable => {
            try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} (a reordered array cannot be routed by key)\n", .{live_path});
            return .cont;
        },
        error.Malformed => {
            try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} (owned record unreadable; run 'mox apply' to refresh it)\n", .{live_path});
            return .cont;
        },
    };
    for (diffres.unaddressable) |spelled| {
        try partialManual(cc, ra, file, fidx, spaces, repo_dir, "  manual: {s} {s}: key is not addressable by a string key path\n", .{ live_path, spelled });
    }
    if (diffres.changes.len == 0) return .cont;

    // Partial routing verifies over the repo-wide configuration space, like
    // every structured route.
    if (spaces[fidx] == null) spaces[fidx] = try structFileSpace(arena, cc.io, cc.this_bindings, file, repo_dir);
    // The changes were diffed against the owned record, not the fresh
    // compose, so the record is the baseline a key's resolved name is looked
    // up in.
    const record_baseline: ?commit_struct.Baseline = if (mox.apply.canonical.parseTree(arena, last_blob_text)) |t| .{ .record = t } else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => null,
    };
    return routeStructChanges(cc, ra, file, fidx, spaces[fidx].?, format, diffres.changes, record_baseline, false);
}

/// A partial file's manual (un-routable) outcome. Marks the file affected
/// -- and builds its configuration space -- so it flows through the
/// recompose-verify guard and is reported as uncommitted with a nonzero
/// exit, exactly like a whole-file structured manual hunk.
fn partialManual(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    file: mox.source.tree.ManagedFile,
    fidx: usize,
    spaces: []?FileSpace,
    repo_dir: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    ra.affected[fidx] = true;
    if (spaces[fidx] == null) spaces[fidx] = try structFileSpace(cc.arena, cc.io, cc.this_bindings, file, repo_dir);
    ra.manual_count.* += 1;
    ra.manual_hunks[fidx] += 1;
    ra.pending.* = true;
    try cc.stdout.print(fmt, args);
}

/// A partial file's per-key changes: the canonical trees of the recorded and
/// live owned serializations diffed key by key. Values for set changes come
/// from the LIVE document (real format values, never re-parsed text); a
/// changed entry that string segments cannot address (a non-string yaml key
/// inside an owned subtree) lands in `unaddressable` instead.
const OwnedKeyDiff = struct {
    changes: []const commit_struct.KeyPathChange,
    unaddressable: []const []const u8,
};

fn ownedKeyDiff(
    arena: std.mem.Allocator,
    last_blob: []const u8,
    live_blob: []const u8,
    live_doc: *const mox.apply.partial.OwnedDoc,
) error{ OutOfMemory, Malformed, Unrepresentable }!OwnedKeyDiff {
    const last_tree = try mox.apply.canonical.parseTree(arena, last_blob);
    const live_tree = try mox.apply.canonical.parseTree(arena, live_blob);
    var changes: std.ArrayList(commit_struct.KeyPathChange) = .empty;
    var unaddressable: std.ArrayList([]const u8) = .empty;
    try diffCanonNode(arena, &.{}, last_tree, live_tree, live_doc, &changes, &unaddressable);
    return .{
        .changes = try changes.toOwnedSlice(arena),
        .unaddressable = try unaddressable.toOwnedSlice(arena),
    };
}

fn diffCanonNode(
    arena: std.mem.Allocator,
    path: []const []const u8,
    last: mox.apply.canonical.Node,
    live: mox.apply.canonical.Node,
    live_doc: *const mox.apply.partial.OwnedDoc,
    changes: *std.ArrayList(commit_struct.KeyPathChange),
    unaddressable: *std.ArrayList([]const u8),
) error{ OutOfMemory, Malformed, Unrepresentable }!void {
    const last_leaf = last.leaf != null;
    const live_leaf = live.leaf != null;
    if (!last_leaf and !live_leaf) {
        for (last.entries) |le| {
            const sub = try keyPathAppend(arena, path, le.key);
            if (live.find(le.key)) |lv| {
                try diffCanonNode(arena, sub, le.node, lv, live_doc, changes, unaddressable);
            } else {
                try changes.append(arena, .{ .path = sub, .new = null, .removed = true, .old_text = try canonNodeInline(arena, le.node) });
            }
        }
        for (live.entries) |le| {
            if (last.find(le.key) != null) continue;
            try appendCanonSet(arena, try keyPathAppend(arena, path, le.key), live_doc, null, changes, unaddressable);
        }
        return;
    }
    if (last_leaf and live_leaf) {
        if (std.mem.eql(u8, last.leaf.?, live.leaf.?)) return;
        // A same-length array reorder has no stable key-path identity,
        // exactly as in `changedKeyPaths`.
        if (try canonArrayPermutation(arena, last.leaf.?, live.leaf.?)) return error.Unrepresentable;
    }
    // A shape change (leaf vs container) or a changed leaf: one whole-value
    // change at this path. The root is always a container on both sides.
    if (path.len == 0) return error.Malformed;
    try appendCanonSet(arena, path, live_doc, try canonNodeInline(arena, last), changes, unaddressable);
}

fn appendCanonSet(
    arena: std.mem.Allocator,
    path: []const []const u8,
    live_doc: *const mox.apply.partial.OwnedDoc,
    old_text: ?[]const u8,
    changes: *std.ArrayList(commit_struct.KeyPathChange),
    unaddressable: *std.ArrayList([]const u8),
) error{OutOfMemory}!void {
    const v = live_doc.subtreeAt(path) orelse {
        try unaddressable.append(arena, try mox.apply.canonical.pathSpell(arena, path));
        return;
    };
    try changes.append(arena, .{ .path = path, .new = anyToStructValue(v), .removed = false, .old_text = old_text });
}

/// Inline rendering of a canonical-tree node: a leaf's pinned text as-is, a
/// container as `{key = ..., ...}` -- the record side of a per-key prompt.
fn canonNodeInline(arena: std.mem.Allocator, node: mox.apply.canonical.Node) error{OutOfMemory}![]const u8 {
    if (node.leaf) |text| return text;
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '{');
    for (node.entries, 0..) |e, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        const seg = [_][]const u8{e.key};
        try out.appendSlice(arena, try mox.apply.canonical.pathSpell(arena, &seg));
        try out.appendSlice(arena, " = ");
        try out.appendSlice(arena, try canonNodeInline(arena, e.node));
    }
    try out.append(arena, '}');
    return out.toOwnedSlice(arena);
}

fn keyPathAppend(arena: std.mem.Allocator, prefix: []const []const u8, key: []const u8) error{OutOfMemory}![]const []const u8 {
    const p = try arena.alloc([]const u8, prefix.len + 1);
    @memcpy(p[0..prefix.len], prefix);
    p[prefix.len] = key;
    return p;
}

fn anyToStructValue(v: mox.apply.partial.AnyValue) commit_struct.Value {
    return switch (v) {
        .toml => |t| .{ .toml = t },
        .json => |j| .{ .json = j },
        .yaml => |y| .{ .yaml = y },
        .ini => |i| .{ .ini = i },
    };
}

/// True when both pinned inline texts are arrays holding the same element
/// multiset in a different order.
fn canonArrayPermutation(arena: std.mem.Allocator, a: []const u8, b: []const u8) error{OutOfMemory}!bool {
    if (a.len < 2 or b.len < 2) return false;
    if (a[0] != '[' or a[a.len - 1] != ']' or b[0] != '[' or b[b.len - 1] != ']') return false;
    const ae = try canonArrayElems(arena, a);
    const be = try canonArrayElems(arena, b);
    if (ae.len != be.len) return false;
    const used = try arena.alloc(bool, be.len);
    @memset(used, false);
    outer: for (ae) |x| {
        for (be, 0..) |y, i| {
            if (used[i]) continue;
            if (std.mem.eql(u8, x, y)) {
                used[i] = true;
                continue :outer;
            }
        }
        return false;
    }
    return true;
}

/// Split a pinned inline array rendering `[a, b, ...]` into its top-level
/// element texts. Strings carry escapes and never raw brackets, so a
/// depth/string scan is exact.
fn canonArrayElems(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const inner = text[1 .. text.len - 1];
    if (inner.len == 0) return out.toOwnedSlice(arena);
    var depth: usize = 0;
    var in_string = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '[', '{' => depth += 1,
            ']', '}' => depth -|= 1,
            ',' => if (depth == 0) {
                try out.append(arena, std.mem.trim(u8, inner[start..i], " "));
                start = i + 1;
            },
            else => {},
        }
    }
    try out.append(arena, std.mem.trim(u8, inner[start..], " "));
    return out.toOwnedSlice(arena);
}

/// The edits a placement of `change` at `layers[chosen]` performs: the write
/// (or removal) at `chosen`, then a deletion of the key from every layer MORE
/// SPECIFIC than `chosen` that defines it (the surgical shadow removals, from
/// `shadowers`). Both the winner simulation (`chosen == res.target`, no
/// shadowers) and the pick simulation build their edit set through this, so
/// `affected_winner` and `affected_pick` come from the same construction.
fn structPickEdits(
    arena: std.mem.Allocator,
    format: commit_struct.Format,
    layers: []const commit_struct.StructLayer,
    definers: []const usize,
    chosen: usize,
    change: commit_struct.KeyPathChange,
) ![]const StructEdit {
    var out: std.ArrayList(StructEdit) = .empty;
    try out.append(arena, .{ .format = format, .layer_abs = layers[chosen].path, .change = change });
    const shadow = try commit_struct.shadowers(arena, layers, definers, chosen);
    for (shadow) |sp| {
        try out.append(arena, .{
            .format = format,
            .layer_abs = sp,
            .change = .{ .path = change.path, .new = null, .removed = true },
        });
    }
    return out.toOwnedSlice(arena);
}

/// Record a placement of `change`'s key into `layers[chosen_idx]` (plus its
/// surgical override deletions) as deferred edits, and derive `allowed` from
/// the ACTUAL edits: `affected_pick` (the winner set plus any confirmed
/// `extra`) for a `[p]`, or `affected_winner` for a plain `[y]` (whose only
/// edit is the winner write). The confirm in `pickLayer` is what makes a
/// promote's `extra` part of what the user chose; the guard rolls back only a
/// change OUTSIDE this set (an unseen/unconfirmed one).
fn recordStructPlacement(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    file: mox.source.tree.ManagedFile,
    fidx: usize,
    space: FileSpace,
    format: commit_struct.Format,
    layers: []const commit_struct.StructLayer,
    res: commit_struct.Resolution,
    chosen_idx: usize,
    change: commit_struct.KeyPathChange,
) !enum { placed, unroutable } {
    const edits = try structPickEdits(cc.arena, format, layers, res.definers, chosen_idx, change);

    if (space.configs.len > 1) {
        // The simulation applies the real edits and restores every layer it
        // touched, so a layer that will not accept the edit is caught HERE,
        // before anything is written for keeps. Reporting it as un-routable
        // beats letting it reach the write phase, where the whole file rolls
        // back for one bad key.
        const imp = switch (try simulateStructImpact(cc, file, edits, space.configs)) {
            .ok => |i| i,
            .rejected => return .unroutable,
        };
        for (imp.affected) |l| try ra.allowed[fidx].put(l, {});
    }

    for (edits) |e| {
        try ra.struct_edits.append(cc.arena, e);
        try ra.struct_owners.append(cc.arena, fidx);
    }

    ra.affected[fidx] = true;
    ra.routed_count.* += 1;
    return .placed;
}

/// The labels in `pick` that are not in `winner`: the configurations a `[p]`
/// placement reaches BEYOND the plain `[y]` edit -- exactly what the confirm
/// must list. A configuration with its own override of the key recomposes
/// identically under both and never appears here.
fn labelDifference(
    arena: std.mem.Allocator,
    pick: []const []const u8,
    winner: []const []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (pick) |l| {
        var found = false;
        for (winner) |w| {
            if (std.mem.eql(u8, l, w)) {
                found = true;
                break;
            }
        }
        if (!found) try out.append(arena, l);
    }
    return out.toOwnedSlice(arena);
}

/// `foo.bar` label for a key path.
fn keyPathLabel(arena: std.mem.Allocator, path: []const []const u8) ![]const u8 {
    return std.mem.join(arena, ".", path);
}

/// Repo-relative label for a structured layer: the base's repo-relative
/// source path, or an overlay's filename (e.g. "os=darwin.toml"). Mirrors
/// `lineRouteLabel`'s repo-relative line-hunk labels -- never the layer's
/// absolute on-disk path, which would leak the home directory.
fn structLayerLabel(file: mox.source.tree.ManagedFile, layer: commit_struct.StructLayer) []const u8 {
    if (layer.is_base) return file.source_base_path;
    return std.fs.path.basename(layer.path);
}

/// Route label for a structured key change: the winning (default) layer, named
/// as base or its repo-relative filename.
fn structRouteLabel(
    arena: std.mem.Allocator,
    file: mox.source.tree.ManagedFile,
    layers: []const commit_struct.StructLayer,
    res: commit_struct.Resolution,
    change: commit_struct.KeyPathChange,
) ![]const u8 {
    const target = layers[res.target];
    const verb = if (change.removed) "remove from" else "write to";
    if (target.is_base) return std.fmt.allocPrint(arena, "{s} base {s}", .{ verb, file.source_base_path });
    return std.fmt.allocPrint(arena, "{s} {s}", .{ verb, structLayerLabel(file, target) });
}

/// A pick reaching configurations beyond the plain `[y]` edit takes one
/// confirm before it is placed; the default is `n` so an un-answered prompt
/// (or `--yes`, which never reaches here) does not promote.
const confirm_choices = [_]prompt.Choice{
    .{ .key = "y", .label = "yes", .help = "apply the pick, changing the configurations listed above" },
    .{ .key = "n", .label = "no", .help = "do not place this key" },
};

/// `pickLayer`'s outcome: a chosen layer, a deliberate skip/decline (the
/// trailing skip, `report_only`, or a declined confirm), or a real abort that
/// must propagate out of `processStructFile` and unwind the whole run --
/// `q`/strict-abort here quits exactly like everywhere else, and must not be
/// folded into a per-key decline.
const PickOutcome = union(enum) {
    picked: usize,
    skip,
    abort,
    abort_strict,
};

/// Present the layer picker for a structured key change: base and each
/// applicable overlay, the current winner marked, each shadowed candidate
/// annotated with the override entries a placement there deletes. When the
/// chosen layer changes configurations BEYOND the plain `[y]` edit, list those
/// with the key's before/after value and take one confirm.
fn pickLayer(
    cc: *const ClassCtx,
    file: mox.source.tree.ManagedFile,
    format: commit_struct.Format,
    layers: []const commit_struct.StructLayer,
    res: commit_struct.Resolution,
    change: commit_struct.KeyPathChange,
    configs: []const Configuration,
) !PickOutcome {
    try cc.stdout.print("  place {s} in...\n", .{try keyPathLabel(cc.arena, change.path)});

    var choices: std.ArrayList(prompt.Choice) = .empty;
    // Layer index behind each offered number: a layer that cannot take the
    // placement is reported as unavailable rather than offered, so the numbers
    // are not the layer indices.
    var cand: std.ArrayList(usize) = .empty;
    var refused: std.ArrayList([]const u8) = .empty;
    for (layers, 0..) |layer, i| {
        const name = if (layer.is_base)
            try std.fmt.allocPrint(cc.arena, "base {s}", .{file.source_base_path})
        else
            std.fs.path.basename(layer.path);
        // Removing at a layer that does not define the key deletes nothing --
        // the format either errors or silently no-ops, and the key survives.
        if (change.removed and !isDefiner(res.definers, i)) {
            try refused.append(cc.arena, try std.fmt.allocPrint(cc.arena, "{s} -- does not define it", .{name}));
            continue;
        }
        // Overwriting an interpolated entry would replace the template with
        // this machine's resolved value for every machine sharing the source.
        // A REMOVAL writes no value, so it bakes nothing and stays available --
        // and refusing it here would empty the menu, since a routable removal
        // has exactly one definer and every other layer is refused above.
        if (!change.removed and commit_struct.capturedAt(format, layer.value, change.path)) {
            try refused.append(cc.arena, try std.fmt.allocPrint(cc.arena, "{s} -- its entry is interpolated", .{name}));
            continue;
        }
        // A key no layer defines yet has no current home to mark, so the
        // default is named for what it is instead.
        const is_winner = res.definers.len > 0 and i == res.target;
        const shadow = try commit_struct.shadowers(cc.arena, layers, res.definers, i);
        const suffix = if (is_winner)
            try cc.arena.dupe(u8, "  (current)")
        else if (res.definers.len == 0 and i == res.target)
            try cc.arena.dupe(u8, "  (default)")
        else if (shadow.len > 0)
            try shadowNote(cc.arena, shadow)
        else
            try cc.arena.dupe(u8, "");
        const n = cand.items.len + 1;
        try cc.stdout.print("    [{d}] {s}{s}\n", .{ n, name, suffix });
        const key = try std.fmt.allocPrint(cc.arena, "{d}", .{n});
        try choices.append(cc.arena, .{ .key = key, .label = name });
        try cand.append(cc.arena, i);
    }
    for (refused.items) |r| try cc.stdout.print("    unavailable: {s}\n", .{r});
    // Trailing skip.
    try choices.append(cc.arena, .{ .key = "s", .label = "skip" });

    // The resolved target always defines the key (or, for a new key, is the
    // base), so it is never among the refused: it has a position here.
    var default_pos: usize = 0;
    for (cand.items, 0..) |li, p| {
        if (li == res.target) default_pos = p;
    }

    const legend_line = try legend(cc.arena, choices.items, default_pos, cc.sty);
    const picked: usize = switch (try prompt.ask(cc.ask_mode, choices.items, default_pos, legend_line, cc.input, cc.stdout)) {
        .chosen => |i| if (i < cand.items.len) cand.items[i] else return .skip, // trailing skip
        .abort => return .abort,
        .abort_strict => return .abort_strict,
        .report_only => return .skip,
    };

    // The winner is identical to `[y]`: no cross-configuration effect to
    // confirm. Single-config files (no repo-wide sibling) also skip the confirm
    // because `extra` is necessarily empty.
    if (picked == res.target or configs.len <= 1) return .{ .picked = picked };

    // `extra` = configs the actual pick changes that the plain `[y]` winner
    // edit does not. A config with its own override of the key is in neither.
    const winner_edits = try structPickEdits(cc.arena, format, layers, res.definers, res.target, change);
    const pick_edits = try structPickEdits(cc.arena, format, layers, res.definers, picked, change);
    // A layer that refuses the edit has no blast radius to confirm; the
    // placement is recorded anyway so `recordStructPlacement` reports the
    // refusal through the one path that reports it.
    const winner_imp = switch (try simulateStructImpact(cc, file, winner_edits, configs)) {
        .ok => |i| i,
        .rejected => return .{ .picked = picked },
    };
    const pick_imp = switch (try simulateStructImpact(cc, file, pick_edits, configs)) {
        .ok => |i| i,
        .rejected => return .{ .picked = picked },
    };
    const extra = try labelDifference(cc.arena, pick_imp.affected, winner_imp.affected);
    if (extra.len == 0) return .{ .picked = picked };

    try cc.stdout.writeAll("  placing here also changes:\n");
    for (extra) |label| {
        const ci = configIndex(configs, label) orelse continue;
        const before_v = try structValueText(cc.arena, format, pick_imp.before.per_config[ci], change.path);
        const after_v = try structValueText(cc.arena, format, pick_imp.after.per_config[ci], change.path);
        try cc.stdout.print("    {s}: {s} -> {s}\n", .{ label, before_v, after_v });
    }
    const cl = try legend(cc.arena, &confirm_choices, 1, cc.sty);
    return switch (try prompt.ask(cc.ask_mode, &confirm_choices, 1, cl, cc.input, cc.stdout)) {
        .chosen => |i| if (i == 0) .{ .picked = picked } else .skip,
        .abort => .abort,
        .abort_strict => .abort_strict,
        .report_only => .skip,
    };
}

fn isDefiner(definers: []const usize, i: usize) bool {
    for (definers) |d| {
        if (d == i) return true;
    }
    return false;
}

/// "(removes your override in a.toml, b.toml)" annotation for a shadowed
/// candidate: the overrides a placement there deletes on THIS machine. `shadow`
/// entries are always overlay layers more specific than the base (never the
/// base itself), so a bare filename always identifies one.
fn shadowNote(arena: std.mem.Allocator, shadow: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "  (removes your override in ");
    for (shadow, 0..) |p, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, std.fs.path.basename(p));
    }
    try out.append(arena, ')');
    return out.toOwnedSlice(arena);
}

/// Index of the configuration labelled `label`, or null when none matches.
fn configIndex(configs: []const Configuration, label: []const u8) ?usize {
    for (configs, 0..) |c, i| {
        if (std.mem.eql(u8, c.label, label)) return i;
    }
    return null;
}

/// The key's display value in one configuration's compose, or a marker when the
/// file is gated off there, the key is absent, or that configuration's source
/// will not compose at all.
fn structValueText(
    arena: std.mem.Allocator,
    format: commit_struct.Format,
    out: impact.ConfigOutput,
    path: []const []const u8,
) ![]const u8 {
    const b = switch (out) {
        .bytes => |b| b,
        .absent => return "(absent)",
        .uncomposable => return "(does not compose)",
    };
    return (try commit_struct.displayAt(arena, format, b, path)) orelse "(absent)";
}

/// Report one first-contact `.line`/`.row` hunk as manual. Every
/// non-interactive mode takes this same path, which is what makes
/// `--dry-run`'s "N routable" the count a later `--yes` run reproduces: a
/// report that modelled the route a terminal would offer would promise work
/// the run it predicts refuses to do.
fn firstContactManual(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    file: mox.source.tree.ManagedFile,
    fidx: usize,
    hunk: Hunk,
) !HunkOutcome {
    ra.manual_count.* += 1;
    ra.manual_hunks[fidx] += 1;
    ra.pending.* = true;
    try cc.stdout.print("  manual: {f}:{d} first contact, needs confirmation\n", .{ display.of(file.live_path, cc.m_state.home), hunk.a_start + 1 });
    return .cont;
}

/// The path of the first key routed from file `fidx` whose value differs
/// between `composed` and `live`, or that either side cannot be parsed to
/// compare -- a difference at the key, inside it, or at any table enclosing
/// it -- or null when every one recomposes to its live value.
fn unmatchedRoutedKey(
    arena: std.mem.Allocator,
    edits: []const StructEdit,
    owners: []const usize,
    fidx: usize,
    composed: []const u8,
    live: []const u8,
) !?[]const []const u8 {
    var diffs: ?[]const commit_struct.KeyPathChange = null;
    for (edits, owners) |e, owner| {
        if (owner != fidx) continue;
        const d = diffs orelse blk: {
            const got = commit_struct.changedKeyPaths(arena, e.format, live, composed) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return e.change.path,
            };
            diffs = got;
            break :blk got;
        };
        for (d) |c| {
            if (pathsNest(c.path, e.change.path)) return e.change.path;
        }
    }
    return null;
}

fn pathsNest(a: []const []const u8, b: []const []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// Report the configuration a write may not change: one it would leave unable
/// to compose, or one the user did not choose to affect.
fn reportViolation(err: *Io.Writer, path: []const u8, what: []const u8, label: []const u8, uncomposable: bool) !void {
    if (uncomposable) {
        try err.print("mox commit: {s}: {s} would leave configuration {s} unable to compose; not committed\n", .{ path, what, label });
    } else {
        try err.print("mox commit: {s}: {s} would change configuration {s}, which you did not choose to affect; not committed\n", .{ path, what, label });
    }
}

/// Name the hunks a file left only in its live copy, and whether the edits
/// that were routed stand.
fn reportUnrouted(err: *Io.Writer, live_path: []const u8, manual: usize, declined: usize, has_routed: bool) !void {
    if (manual > 0 and declined > 0) {
        if (has_routed) {
            try err.print(
                "mox commit: {s}: {d} hunk(s) could not be routed and {d} hunk(s) were declined; both remain only " ++
                    "in the live file; the routed edits were committed to the sources -- edit the rest in by hand, " ++
                    "then run 'mox apply'\n",
                .{ live_path, manual, declined },
            );
        } else {
            try err.print(
                "mox commit: {s}: {d} hunk(s) could not be routed and {d} hunk(s) were declined; both remain only " ++
                    "in the live file; not committed\n",
                .{ live_path, manual, declined },
            );
        }
    } else if (manual > 0) {
        if (has_routed) {
            try err.print(
                "mox commit: {s}: {d} hunk(s) could not be routed and remain only in the live file; " ++
                    "the routed edits were committed to the sources -- edit the rest in by hand, then run 'mox apply'\n",
                .{ live_path, manual },
            );
        } else {
            try err.print(
                "mox commit: {s}: {d} hunk(s) could not be routed and remain only in the live file; not committed\n",
                .{ live_path, manual },
            );
        }
    } else {
        if (has_routed) {
            try err.print(
                "mox commit: {s}: {d} hunk(s) were declined and remain only in the live file; " ++
                    "the routed edits were committed to the sources -- run 'mox apply' to discard them\n",
                .{ live_path, declined },
            );
        } else {
            try err.print(
                "mox commit: {s}: {d} hunk(s) were declined and remain only in the live file; not committed\n",
                .{ live_path, declined },
            );
        }
    }
}

/// `firstContactManual` for one hunk of a generator leaf.
fn firstContactLeafManual(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    fidx: usize,
    leaf: mox.compose.catB.GeneratedFile,
    hunk: Hunk,
) !HunkOutcome {
    ra.manual_count.* += 1;
    ra.manual_hunks[fidx] += 1;
    ra.pending.* = true;
    try cc.stdout.print("  manual: {f}:{d} first contact, needs confirmation\n", .{ display.of(leaf.live_path, cc.m_state.home), hunk.a_start + 1 });
    return .cont;
}

/// `firstContactManual` for one changed key of a structured file.
fn firstContactKeyManual(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    file: mox.source.tree.ManagedFile,
    fidx: usize,
    change: commit_struct.KeyPathChange,
) !void {
    ra.manual_count.* += 1;
    ra.manual_hunks[fidx] += 1;
    ra.pending.* = true;
    try cc.stdout.print("  manual: {f} {s}: first contact, needs confirmation\n", .{ display.of(file.live_path, cc.m_state.home), try keyPathLabel(cc.arena, change.path) });
}

/// Route, prompt for, and (when accepted) collect one hunk's edit. Sub-hunks
/// produced by a `split` re-enter this same function, so a straddling hunk's
/// pieces get the identical treatment a top-level hunk would: their own
/// route, their own header, their own prompt -- `[s/x]` manual, `[y/s]`
/// line/row, `[f/d/s]` interpolated.
fn processHunk(
    cc: *const ClassCtx,
    ra: *const RunAccum,
    file: mox.source.tree.ManagedFile,
    fidx: usize,
    space: FileSpace,
    segments: []const Segment,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
    hunk: Hunk,
    hunk_no: usize,
    hunk_total: usize,
    secret_lines: ?[]const []const u8,
    // True only on the first-contact fallback path (never the stored-baseline
    // or secret-fallback ones): the recomposed baseline this hunk diffs
    // against was never something mox itself wrote, so no non-interactive
    // mode may take a default on a `.line`/`.row` keep -- another tool's
    // rendering quirk would slip into source unseen.
    first_contact: bool,
    lf: *LoopFile,
) !HunkOutcome {
    const route = try routeHunk(cc, lf, hunk);
    switch (route) {
        .manual => |reason| {
            // A hunk covering (or straddling into) a `.secret` segment's
            // resolved output must never show its a-side: that is the old
            // resolved secret value. `printMiniDiff` is unconditionally unsafe
            // here, so it is never called for this reason -- a dedicated
            // display shows only the new live value and, when it can be
            // recovered from a placeholder recompose, the store URI.
            const touches_secret = hunkTouchesSecret(segments, hunk);
            if (!cc.interactive) {
                ra.manual_count.* += 1;
                ra.manual_hunks[fidx] += 1;
                ra.pending.* = true;
                try cc.stdout.print("  manual: {f}:{d} {s}\n", .{ display.of(file.live_path, cc.m_state.home), hunk.a_start + 1, reason });
                return .cont;
            }
            try printHunkHeader(cc.stdout, cc.sty, try mox.source.path.liveKeyRelToHome(cc.arena, cc.m_state.home, file.live_path), "hunk", hunk_no, hunk_total, try routeLabel(cc.arena, route, file));
            if (touches_secret) {
                try printSecretNotice(cc, secret_lines, hunk, b_lines);
            } else {
                try printMiniDiff(cc.sty, cc.stdout, hunk, a_lines, b_lines);
            }
            const legend_line = try legend(cc.arena, &sx_choices, 0, cc.sty);
            switch (try prompt.ask(cc.ask_mode, &sx_choices, 0, legend_line, cc.input, cc.stdout)) {
                .chosen => |i| switch (i) {
                    0 => {
                        ra.manual_count.* += 1;
                        ra.manual_hunks[fidx] += 1;
                        ra.pending.* = true;
                        try cc.stdout.print("  manual: {f}:{d} {s}\n", .{ display.of(file.live_path, cc.m_state.home), hunk.a_start + 1, reason });
                    },
                    else => {
                        const subs = try splitHunk(cc.arena, segments, hunk);
                        if (subs.len <= 1) {
                            // An UNCOVERED hunk reaches this prompt too, and it
                            // has no segment boundary to split at. Say so rather
                            // than reporting it as though `s` had been chosen:
                            // the user asked for something the hunk cannot do.
                            ra.manual_count.* += 1;
                            ra.manual_hunks[fidx] += 1;
                            ra.pending.* = true;
                            try cc.stdout.print("  nothing to split: {f}:{d} lies in no single source\n", .{ display.of(file.live_path, cc.m_state.home), hunk.a_start + 1 });
                            try cc.stdout.print("  manual: {f}:{d} {s}\n", .{ display.of(file.live_path, cc.m_state.home), hunk.a_start + 1, reason });
                        } else {
                            for (subs) |sub| {
                                const outcome = try processHunk(cc, ra, file, fidx, space, segments, a_lines, b_lines, sub, hunk_no, hunk_total, secret_lines, first_contact, lf);
                                if (outcome != .cont) return outcome;
                            }
                        }
                    },
                },
                .abort => return .abort,
                .abort_strict => return .abort_strict,
                .report_only => unreachable,
            }
            return .cont;
        },
        .line => |r| {
            if (first_contact and !cc.interactive) return firstContactManual(cc, ra, file, fidx, hunk);
            ra.routed_count.* += 1;
            // A shared-origin edit in a file whose OWN configuration space has
            // more than one member asks where the edit belongs; everything
            // else keeps the origin behind a plain [y/s] confirm (bootstrap
            // / axis-specific / private).
            if (r.shared and space.configs.len > 1) {
                switch (try classifyLine(cc, file, r.edit, r.desc, space, hunk_no, hunk_total)) {
                    .abort => return .abort,
                    .abort_strict => return .abort_strict,
                    .report => {
                        ra.pending.* = true;
                        // Report mode returns before the write phase; the edit
                        // is collected only so the coupling updates a real
                        // commit would offer are also surfaced.
                        try ra.line_edits.append(cc.arena, r.edit);
                        try ra.line_owners.append(cc.arena, fidx);
                    },
                    .skip => ra.declined_hunks[fidx] += 1,
                    .unroutable => ra.unrouted_hunks[fidx] += 1,
                    .manual => {
                        ra.manual_count.* += 1;
                        ra.manual_hunks[fidx] += 1;
                        ra.pending.* = true;
                    },
                    .origin => |labels| {
                        try ra.line_edits.append(cc.arena, r.edit);
                        try ra.line_owners.append(cc.arena, fidx);
                        ra.affected[fidx] = true;
                        for (labels) |l| try ra.allowed[fidx].put(l, {});
                        try cc.stdout.print("  edit {s}\n", .{r.desc});
                    },
                    .synth => |sd| {
                        try ra.synth_plans.append(cc.arena, sd);
                        try ra.synth_owners.append(cc.arena, fidx);
                        ra.affected[fidx] = true;
                        for (sd.allowed) |l| try ra.allowed[fidx].put(l, {});
                        // Preview the synthesized directive structure before
                        // any write.
                        try cc.stdout.print("  synthesize {s}={s} region in {s}\n", .{ sd.plan.region, sd.plan.value, r.desc });
                        try cc.stdout.print("    + {s}\n", .{sd.plan.directive_line});
                        try cc.stdout.print("    + fragment {s}\n", .{sd.plan.fragment_path});
                    },
                }
                return .cont;
            }

            var accept = !cc.report_mode and !cc.interactive;
            if (cc.report_mode) {
                ra.pending.* = true;
                try cc.stdout.print("  would edit {s}\n", .{r.desc});
                try printMiniDiff(cc.sty, cc.stdout, hunk, a_lines, b_lines);
                // Collected so report mode can also surface coupling
                // divergences; never written (report mode returns before the
                // write phase).
                try ra.line_edits.append(cc.arena, r.edit);
                try ra.line_owners.append(cc.arena, fidx);
            } else if (cc.interactive) {
                try printHunkHeader(cc.stdout, cc.sty, try mox.source.path.liveKeyRelToHome(cc.arena, cc.m_state.home, file.live_path), "hunk", hunk_no, hunk_total, try routeLabel(cc.arena, route, file));
                try printMiniDiff(cc.sty, cc.stdout, hunk, a_lines, b_lines);
                const legend_line = try legend(cc.arena, &ys_choices, 0, cc.sty);
                switch (try prompt.ask(cc.ask_mode, &ys_choices, 0, legend_line, cc.input, cc.stdout)) {
                    .chosen => |i| switch (i) {
                        0 => accept = true,
                        else => ra.declined_hunks[fidx] += 1,
                    },
                    .abort => return .abort,
                    .abort_strict => return .abort_strict,
                    .report_only => unreachable,
                }
            }
            if (accept) {
                try ra.line_edits.append(cc.arena, r.edit);
                try ra.line_owners.append(cc.arena, fidx);
                ra.affected[fidx] = true;
                // This route made no classification choice (axis-gated
                // fragment, private layer, or a file with a single
                // configuration): the configurations its origin feeds are
                // exactly the ones it is meant to change, so verification
                // must expect them to differ.
                if (space.configs.len > 1) {
                    const imp = try simulateImpact(cc, file, r.edit, space.configs);
                    for (imp.affected) |l| try ra.allowed[fidx].put(l, {});
                }
                if (!cc.interactive and !cc.report_mode)
                    try cc.stdout.print("  edit {s}\n", .{r.desc});
            }
            return .cont;
        },
        .row => |r| {
            if (first_contact and !cc.interactive) return firstContactManual(cc, ra, file, fidx, hunk);
            ra.routed_count.* += 1;
            var accept = !cc.report_mode and !cc.interactive;
            if (cc.report_mode) {
                ra.pending.* = true;
                try cc.stdout.print("  would update {s}\n", .{r.desc});
                try printMiniDiff(cc.sty, cc.stdout, hunk, a_lines, b_lines);
                // Collected so report mode predicts the coupling updates a
                // real commit would drop over it; never written.
                try ra.row_edits.append(cc.arena, r.edit);
                try ra.row_owners.append(cc.arena, fidx);
            } else if (cc.interactive) {
                try printHunkHeader(cc.stdout, cc.sty, try mox.source.path.liveKeyRelToHome(cc.arena, cc.m_state.home, file.live_path), "hunk", hunk_no, hunk_total, try routeLabel(cc.arena, route, file));
                try printMiniDiff(cc.sty, cc.stdout, hunk, a_lines, b_lines);
                const legend_line = try legend(cc.arena, &ys_choices, 0, cc.sty);
                switch (try prompt.ask(cc.ask_mode, &ys_choices, 0, legend_line, cc.input, cc.stdout)) {
                    .chosen => |i| switch (i) {
                        0 => accept = true,
                        else => ra.declined_hunks[fidx] += 1,
                    },
                    .abort => return .abort,
                    .abort_strict => return .abort_strict,
                    .report_only => unreachable,
                }
            }
            if (accept) {
                try ra.row_edits.append(cc.arena, r.edit);
                try ra.row_owners.append(cc.arena, fidx);
                ra.affected[fidx] = true;
                // A loop row belongs to its data source, not to any
                // configuration: like the non-shared line routes above, it
                // makes no classification choice, so the configurations it
                // feeds are the ones it may change.
                if (space.configs.len > 1) {
                    const imp = try simulateRowImpact(cc, file, r.edit, space.configs);
                    for (imp.affected) |l| try ra.allowed[fidx].put(l, {});
                }
                if (!cc.interactive and !cc.report_mode)
                    try cc.stdout.print("  update {s}\n", .{r.desc});
            }
            return .cont;
        },
        .fact => |r| {
            // Non-interactive modes (--yes, --dry-run, strict, plain non-TTY
            // without --yes) keep this hunk's PRE-existing outcome: manual.
            // Writing a fact -- machine identity data -- without an explicit
            // human decision is not something any of those modes should do
            // silently, exactly like the plain `.manual` case above.
            if (!cc.interactive) {
                ra.manual_count.* += 1;
                ra.manual_hunks[fidx] += 1;
                ra.pending.* = true;
                try cc.stdout.print("  manual: {f}:{d} came from a capture\n", .{ display.of(file.live_path, cc.m_state.home), hunk.a_start + 1 });
                return .cont;
            }
            try printHunkHeader(cc.stdout, cc.sty, try mox.source.path.liveKeyRelToHome(cc.arena, cc.m_state.home, file.live_path), "hunk", hunk_no, hunk_total, try routeLabel(cc.arena, route, file));
            try printMiniDiff(cc.sty, cc.stdout, hunk, a_lines, b_lines);
            try cc.stdout.print("  This value comes from machine.{s}.\n", .{r.name});
            const legend_line = try legend(cc.arena, &fact_choices, 0, cc.sty);
            switch (try prompt.ask(cc.ask_mode, &fact_choices, 0, legend_line, cc.input, cc.stdout)) {
                .chosen => |i| switch (i) {
                    0 => {
                        // [f]: the fact. Never touches repo src.
                        try ra.fact_edits.append(cc.arena, .{ .name = r.name, .new_value = r.new_value, .old_value = r.old_value });
                        try ra.fact_owners.append(cc.arena, fidx);
                        ra.affected[fidx] = true;
                        if (space.configs.len > 1) {
                            const imp = try simulateFactImpact(cc, file, r.name, r.new_value, space.configs);
                            for (imp.affected) |l| try ra.allowed[fidx].put(l, {});
                        }
                        try cc.stdout.print("  set fact machine.{s} = \"{s}\"\n", .{ r.name, r.new_value });
                    },
                    1 => {
                        // [d]: the source's default, via the ordinary LineEdit
                        // machinery (backup, apply, impact simulation).
                        try ra.line_edits.append(cc.arena, r.default_edit);
                        try ra.line_owners.append(cc.arena, fidx);
                        ra.affected[fidx] = true;
                        if (space.configs.len > 1) {
                            const imp = try simulateImpact(cc, file, r.default_edit, space.configs);
                            for (imp.affected) |l| try ra.allowed[fidx].put(l, {});
                        }
                        try cc.stdout.print("  edit {s}\n", .{r.default_desc});
                    },
                    // [s]: a deliberate decline, like `[s]` everywhere else --
                    // not an un-routable hunk. Counting it manual reported a
                    // routable hunk the user chose to leave as one that "could
                    // not be routed".
                    else => ra.declined_hunks[fidx] += 1,
                },
                .abort => return .abort,
                .abort_strict => return .abort_strict,
                .report_only => unreachable,
            }
            return .cont;
        },
    }
}

/// Map one diff hunk to a source edit, or report why it cannot be routed.
fn routeHunk(cc: *const ClassCtx, lf: *LoopFile, hunk: Hunk) !Route {
    const arena = cc.arena;
    const io = cc.io;
    const file = lf.file;
    const a_lines = lf.a_lines;
    const b_lines = lf.b_lines;
    const seg = mox.provenance.map.covering(lf.segments, hunk.a_start, hunk.a_len) orelse
        return .{ .manual = "hunk straddles origins or is uncovered" };
    const new_lines = b_lines[hunk.b_start .. hunk.b_start + hunk.b_len];
    const old_lines = a_lines[hunk.a_start .. hunk.a_start + hunk.a_len];

    switch (seg.origin) {
        .base => |o| {
            const start = (o.line - 1) + (hunk.a_start - seg.out_start);
            if (!try sourceStillHolds(arena, io, file.source_base_abs, seg, hunk, a_lines, start))
                return .{ .manual = "source no longer matches recorded provenance" };
            // A private-ONLY whole file composes as `.base` (it is a base file
            // of the private tree), so the provenance tag alone cannot flag it;
            // its location must. Any edit under the private root is
            // private-origin and must never couple into the shared repo.
            return lineRoute(arena, file.source_base_abs, file.source_base_path, start, hunk.a_len, new_lines, true, mox.source.path.isUnderDir(file.source_base_abs, file.private_dir));
        },
        .fragment => |o| {
            const start = (o.line - 1) + (hunk.a_start - seg.out_start);
            if (!try sourceStillHolds(arena, io, o.path, seg, hunk, a_lines, start))
                return .{ .manual = "source no longer matches recorded provenance" };
            // A region fragment is already axis-gated; an include/append/prepend
            // fragment is universal, so its edit is shared and gets classified.
            return lineRoute(arena, o.path, o.path, start, hunk.a_len, new_lines, !isRegionFragment(file, o.path), mox.source.path.isUnderDir(o.path, file.private_dir));
        },
        .private => |o| {
            const start = (o.line - 1) + (hunk.a_start - seg.out_start);
            if (!try sourceStillHolds(arena, io, o.path, seg, hunk, a_lines, start))
                return .{ .manual = "source no longer matches recorded provenance" };
            return lineRoute(arena, o.path, o.path, start, hunk.a_len, new_lines, false, true);
        },
        .loop => return loopRoute(cc, lf, seg, hunk),
        .secret => return .{ .manual = "came from a secret" },
        .interpolated => |o| {
            if (hunk.a_len != 1 or hunk.b_len != 1)
                return .{ .manual = "came from a capture" };
            const start = (o.origin_line - 1) + (hunk.a_start - seg.out_start);
            return interpolatedRoute(arena, io, file, start, old_lines[0], new_lines[0], cc.m_state);
        },
        .overlay => return .{ .manual = "came from a structural merge" },
    }
}

/// Route a single-line hunk over a `<machine.X>`-interpolated base line: read
/// the raw template at `start` (0-based, in the base source -- `.interpolated`
/// origins are only ever emitted for base-file lines, never fragments), and
/// see whether exactly one of its captures accounts for the whole live edit.
/// Manual for anything else -- a structural mismatch against the recorded
/// template, more than one capture changing at once, or the one that changed
/// not being a genuine user-settable fact -- so a fact is never guessed at.
fn interpolatedRoute(
    arena: std.mem.Allocator,
    io: Io,
    file: mox.source.tree.ManagedFile,
    start: u32,
    old_line: []const u8,
    new_line: []const u8,
    m_state: *const mox.machine.state.MachineState,
) !Route {
    const content = Io.Dir.cwd().readFileAlloc(io, file.source_base_abs, arena, .limited(max_file_bytes)) catch
        return .{ .manual = "came from a capture" };
    const lines = try mox.diff.lines.splitLines(arena, content);
    if (start >= lines.len) return .{ .manual = "came from a capture" };
    const template = lines[start];

    const before = (try matchCaptures(arena, template, old_line)) orelse return .{ .manual = "came from a capture" };
    const after = (try matchCaptures(arena, template, new_line)) orelse return .{ .manual = "came from a capture" };
    if (before.len != after.len) return .{ .manual = "came from a capture" };

    var changed: usize = 0;
    var changed_idx: usize = 0;
    for (before, 0..) |b, i| {
        if (!std.mem.eql(u8, b.value, after[i].value)) {
            changed += 1;
            changed_idx = i;
        }
    }
    // Not exactly one changed capture: either nothing moved (the literal
    // frame absorbed the whole diff, which matchCaptures would already have
    // rejected) or more than one did, and which one is responsible for the
    // live edit is genuinely ambiguous. Never guess.
    if (changed != 1) return .{ .manual = "came from a capture" };

    const cap = after[changed_idx];
    const fact = asMachineCapture(cap.name) orelse return .{ .manual = "came from a capture" };
    // A name or value `persist` would refuse (a control character, or a name
    // that is not a valid TOML bare key) must never reach the write phase:
    // caught here, before any [f]/[d] choice is offered, so the hunk can only
    // ever become an ordinary manual one -- never a write that starts, then
    // throws with other sources already rewritten.
    if (!mox.machine.interview.canPersist(fact, cap.value))
        return .{ .manual = "came from a capture; the new value cannot be saved as a fact" };

    var old_value: ?[]const u8 = null;
    for (m_state.custom_facts) |f| {
        if (std.mem.eql(u8, f.name, fact)) {
            old_value = f.value;
            break;
        }
    }

    const new_template_line = try spliceDefault(arena, template, cap.name, cap.open, cap.close, cap.value);
    const default_edit: LineEdit = .{
        .path = file.source_base_abs,
        .start = start,
        .del = 1,
        .new_lines = try arena.dupe([]const u8, &.{new_template_line}),
        .private = false,
    };
    const default_desc = try std.fmt.allocPrint(arena, "{s}:{d}", .{ file.source_base_path, start + 1 });

    return .{ .fact = .{
        .name = fact,
        .new_value = cap.value,
        .old_value = old_value,
        .default_edit = default_edit,
        .default_desc = default_desc,
    } };
}

fn lessU32(_: void, x: u32, y: u32) bool {
    return x < y;
}

/// Split `hunk` at provenance-segment boundaries so each returned sub-hunk's
/// a-range lies within a single segment (what lets `routeHunk` resolve it
/// instead of downgrading to manual for straddling). A hunk already within
/// one segment -- the common case, and always true once `routeHunk` has
/// already resolved a hunk to `.line`/`.row` -- returns as a single-element
/// slice equal to `hunk`.
///
/// `b`-side lines are apportioned to each piece in proportion to its share of
/// `a_len` (the last piece taking the remainder), so the sub-hunks' `b`-ranges
/// exactly tile the original: this is exact for the common straddle (adjacent
/// single-line edits, `a_len == b_len`) and a reasonable approximation
/// otherwise, but every sub-hunk's `a`-range is always exact.
fn splitHunk(arena: std.mem.Allocator, segments: []const Segment, hunk: Hunk) ![]const Hunk {
    if (hunk.a_len == 0) return &.{hunk};
    const a_end = hunk.a_start + hunk.a_len;

    var bounds: std.ArrayList(u32) = .empty;
    try bounds.append(arena, hunk.a_start);
    for (segments) |s| {
        if (s.out_start > hunk.a_start and s.out_start < a_end) try bounds.append(arena, s.out_start);
    }
    try bounds.append(arena, a_end);
    std.mem.sort(u32, bounds.items, {}, lessU32);

    var points: std.ArrayList(u32) = .empty;
    for (bounds.items) |v| {
        if (points.items.len == 0 or points.items[points.items.len - 1] != v) try points.append(arena, v);
    }
    if (points.items.len <= 2) return &.{hunk};

    var out: std.ArrayList(Hunk) = .empty;
    var b_done: u32 = 0;
    for (points.items[0 .. points.items.len - 1], points.items[1..], 0..) |lo, hi, i| {
        const is_last = i == points.items.len - 2;
        const b_len = if (is_last)
            hunk.b_len - b_done
        else
            @as(u32, @intCast(@as(u64, hunk.b_len) * (hi - hunk.a_start) / hunk.a_len)) - b_done;
        try out.append(arena, .{ .a_start = lo, .a_len = hi - lo, .b_start = hunk.b_start + b_done, .b_len = b_len });
        b_done += b_len;
    }
    return out.toOwnedSlice(arena);
}

/// Confirm, before routing, that the source file at `path` still holds what
/// the hunk was diffed against, with the hunk's source position at line index
/// `start` (0-based). An edit checks the lines it replaces verbatim. An
/// insertion replaces nothing, so it checks its neighbours within its span --
/// the line it follows and the line it precedes, each that the span holds --
/// matching a neighbour against its source line's capture frame, since an
/// insertion never writes a neighbour and so cannot bake an expanded value in.
/// A hunk that fails is manual. The recompose check after writing still
/// catches a mis-routing this cannot see; this names the cause and keeps the
/// source untouched rather than rolling it back.
fn sourceStillHolds(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
    seg: Segment,
    hunk: Hunk,
    a_lines: []const []const u8,
    start: u32,
) !bool {
    if (hunk.a_len > 0)
        return sourceLinesMatch(arena, io, path, start, a_lines[hunk.a_start .. hunk.a_start + hunk.a_len]);
    if (hunk.a_start > a_lines.len) return false;
    const follows = hunk.a_start > seg.out_start;
    const precedes = hunk.a_start < seg.out_start + seg.out_len and hunk.a_start < a_lines.len;
    if (!follows and !precedes) return false;
    const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch return false;
    const src_lines = try mox.diff.lines.splitLines(arena, content);
    if (follows and !try anchorHolds(arena, src_lines, start - 1, a_lines[hunk.a_start - 1])) return false;
    if (precedes and !try anchorHolds(arena, src_lines, start, a_lines[hunk.a_start])) return false;
    return true;
}

fn anchorHolds(arena: std.mem.Allocator, src_lines: []const []const u8, idx: u32, composed: []const u8) !bool {
    if (idx >= src_lines.len) return false;
    return composesTo(arena, src_lines[idx], composed);
}

/// Whether source line `template` could compose to `line` outside any loop:
/// equal, or equal once each capture compose expands there stands for any
/// text. Captures are found by `interp.CapturesOutsideLoop`, so any other
/// `<...>` is literal text that must match. Adjacent captures have no literal
/// between them to anchor the split, so they only match exactly.
fn composesTo(arena: std.mem.Allocator, template: []const u8, line: []const u8) !bool {
    if (std.mem.eql(u8, template, line)) return true;
    var literals: std.ArrayList([]const u8) = .empty;
    var lit_start: usize = 0;
    var it: mox.compose.interp.CapturesOutsideLoop = .{ .template = template };
    while (it.next()) |span| {
        try literals.append(arena, template[lit_start..span.open]);
        lit_start = span.close + 1;
    }
    if (literals.items.len == 0) return false;
    try literals.append(arena, template[lit_start..]);

    const first = literals.items[0];
    const last = literals.items[literals.items.len - 1];
    if (line.len < first.len + last.len) return false;
    if (!std.mem.startsWith(u8, line, first) or !std.mem.endsWith(u8, line, last)) return false;
    var pos = first.len;
    const end = line.len - last.len;
    for (literals.items[1 .. literals.items.len - 1]) |lit| {
        if (lit.len == 0) return false;
        const at = std.mem.indexOfPos(u8, line[0..end], pos, lit) orelse return false;
        pos = at + lit.len;
    }
    return pos <= end;
}

fn sourceLinesMatch(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
    start: u32,
    expected: []const []const u8,
) !bool {
    std.debug.assert(expected.len > 0);
    const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch return false;
    const lines = try mox.diff.lines.splitLines(arena, content);
    if (@as(usize, start) + expected.len > lines.len) return false;
    for (expected, 0..) |e, i| {
        if (!std.mem.eql(u8, e, lines[start + i])) return false;
    }
    return true;
}

fn lineRoute(
    arena: std.mem.Allocator,
    path: []const u8,
    label: []const u8,
    start: u32,
    del: u32,
    new_lines: []const []const u8,
    shared: bool,
    private: bool,
) !Route {
    const desc = try std.fmt.allocPrint(arena, "{s}:{d}", .{ label, start + 1 });
    return .{ .line = .{
        .edit = .{ .path = path, .start = start, .del = del, .new_lines = new_lines, .private = private },
        .desc = desc,
        .shared = shared,
    } };
}

/// True when `path` is one of `file`'s Cat B region fragments (axis-gated),
/// distinguishing it from a universal include/append/prepend fragment.
fn isRegionFragment(file: mox.source.tree.ManagedFile, path: []const u8) bool {
    for (file.regions) |region| {
        for (region.fragments) |frag| {
            if (std.mem.eql(u8, frag.path, path)) return true;
        }
    }
    return false;
}

/// Find the managed file with `live_path` in a walked tree, or null.
fn findByLive(tree: mox.source.tree.ManagedTree, live_path: []const u8) ?mox.source.tree.ManagedFile {
    for (tree.files) |f| {
        if (std.mem.eql(u8, f.live_path, live_path)) return f;
    }
    return null;
}

/// The generator (or `completions` set) whose current re-expansion produces
/// `live_path` as one of its leaves, or null when no managed file's expansion
/// does. Tried for a scoped `mox commit <path>` argument that named a leaf
/// directly rather than the generator's own path -- a leaf is not itself in
/// `tree_files`, so `scope.filterTree` cannot resolve it. Re-expands every
/// candidate (there is no cheaper index), which is fine at the scale a repo's
/// generator count runs at.
fn findGeneratorLeaf(
    arena: std.mem.Allocator,
    io: Io,
    tree_files: []const mox.source.tree.ManagedFile,
    resolver: *const mox.dsl.resolver.Resolver,
    m_state: *const mox.machine.state.MachineState,
    secrets: mox.compose.catB.SecretCtx,
    live_path: []const u8,
) !?mox.source.tree.ManagedFile {
    for (tree_files) |f| {
        var diag: mox.compose.interp.Diag = .{};
        const gen = mox.compose.catB.composeGenerator(arena, io, f, resolver, m_state, secrets, &diag) catch continue;
        const outputs = gen orelse continue;
        // A generator's produced path is `joinKeyOnto`'d, so it can carry `/`
        // separators even on Windows, while `live_path` comes from a native
        // path resolution. Compare in key form so the two agree on any OS.
        const want = try mox.source.path.toKey(arena, live_path);
        for (outputs) |o| {
            if (std.mem.eql(u8, try mox.source.path.toKey(arena, o.live_path), want)) return f;
        }
    }
    return null;
}

/// Ask where a shared-origin (base / universal-fragment) line edit belongs.
///
/// Narrowing is an INTENT, not an impact fact: whether `export EDITOR=nvim`
/// should hold everywhere or only on darwin is something only the user knows,
/// and it cannot be deduced from what the edit currently changes -- a routable
/// base line is top-level, so it composes into every configuration the file
/// composes into at all. So every such hunk is asked, with universal as the
/// default (`--yes` commits universally, `--abort-on-prompt` exits 2).
///
/// Impact analysis still runs, but for INFORMATION and for verification: the
/// notice names what else the edit reaches, and the labels a choice is allowed
/// to change seed the post-write guard.
fn classifyLine(cc: *const ClassCtx, file: mox.source.tree.ManagedFile, edit: LineEdit, desc: []const u8, space: FileSpace, hunk_no: usize, hunk_total: usize) !Decision {
    const imp = try simulateImpact(cc, file, edit, space.configs);
    const notice = try impactNotice(cc.arena, file.live_path, imp, space.configs.len - 1);
    const cands = try candidates.compute(cc.arena, cc.this_bindings, space.ax);

    if (cc.report_mode) {
        try cc.stdout.writeAll(notice);
        try writeCandidates(cc.arena, cc.stdout, cands, cc.machine);
        return .report;
    }

    if (cc.interactive) {
        const rel = try mox.source.path.liveKeyRelToHome(cc.arena, cc.m_state.home, file.live_path);
        const route_label = try std.fmt.allocPrint(cc.arena, "shared -- changes {d} configuration(s)", .{imp.affected.len});
        try printHunkHeader(cc.stdout, cc.sty, rel, "hunk", hunk_no, hunk_total, route_label);
    }

    var choices: std.ArrayList(prompt.Choice) = .empty;
    for (cands, 0..) |c, i| {
        try choices.append(cc.arena, .{
            .key = try std.fmt.allocPrint(cc.arena, "{d}", .{i + 1}),
            .label = try candidateLabel(cc.arena, c, cc.machine),
            .help = try candidateHelp(cc.arena, c),
        });
    }
    try choices.append(cc.arena, .{ .key = "m", .label = "manual", .help = "no automatic route; handle this hunk by hand" });
    try choices.append(cc.arena, .{ .key = "s", .label = "skip", .help = "leave this hunk as drift; ask again next commit" });

    var qw: Io.Writer.Allocating = .init(cc.arena);
    try qw.writer.writeAll(notice);
    try writeCandidates(cc.arena, &qw.writer, cands, cc.machine);
    try qw.writer.writeAll("  ");
    try cc.sty.bold(&qw.writer);
    try qw.writer.writeAll("choose>");
    try cc.sty.close(&qw.writer);
    try qw.writer.writeAll(" ");
    const question = try qw.toOwnedSlice();

    switch (try prompt.ask(cc.ask_mode, choices.items, 0, question, cc.input, cc.stdout)) {
        .chosen => |i| {
            if (i < cands.len) return classifyChoice(cc, file, edit, desc, imp, cands[i], space.configs);
            if (i == cands.len) return .manual;
            return .skip;
        },
        .abort => return .abort,
        .abort_strict => return .abort_strict,
        .report_only => return .report,
    }
}

/// The impact line that heads the intent question: what else, beyond this
/// machine's own configuration, the edit reaches as it stands.
fn impactNotice(arena: std.mem.Allocator, live_path: []const u8, imp: impact.Impact, n_other: usize) ![]const u8 {
    if (n_other > 0 and imp.affected.len >= n_other)
        return std.fmt.allocPrint(arena, "  {s} -- this edit changes every configuration. Keep it universal, or narrow it?\n", .{live_path});
    if (imp.affected.len == 0)
        return std.fmt.allocPrint(arena, "  {s} -- this edit changes no other configuration (of {d} known configurations).\n", .{ live_path, n_other });
    return std.fmt.allocPrint(
        arena,
        "  {s} -- this also changes {s} (of {d} known configurations).\n",
        .{ live_path, try joinLabels(arena, imp.affected), n_other },
    );
}

/// Comma-join configuration labels for a notice/question line.
fn joinLabels(arena: std.mem.Allocator, labels: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (labels, 0..) |l, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, l);
    }
    return out.toOwnedSlice(arena);
}

/// Materialize a chosen candidate into a decision. Universal keeps the origin;
/// an axis or machine-local choice narrows a BASE edit via region synthesis;
/// private and non-base narrowings have no automatic route yet.
fn classifyChoice(
    cc: *const ClassCtx,
    file: mox.source.tree.ManagedFile,
    edit: LineEdit,
    desc: []const u8,
    imp: impact.Impact,
    c: candidates.Candidate,
    configs: []const Configuration,
) !Decision {
    if (c.kind == .universal) return .{ .origin = imp.affected };

    const is_base = file.has_base and std.mem.eql(u8, edit.path, file.source_base_abs);
    if (c.kind == .private or !is_base) {
        try cc.stdout.print("  {s}: no automatic route to {s}; left uncommitted (edit the source manually)\n", .{ desc, try candidateLabel(cc.arena, c, cc.machine) });
        return .unroutable;
    }

    const base_content = try Io.Dir.cwd().readFileAlloc(cc.io, edit.path, cc.arena, .limited(max_file_bytes));
    const marker = mox.dsl.comment.markerForFile(file.source_base_path, base_content) orelse {
        try cc.stdout.print("  {s}: unknown comment marker; cannot synthesize a region; left uncommitted\n", .{desc});
        return .unroutable;
    };
    // A machine-local narrowing gates on this machine's own `machine`-axis
    // value (the hostname's first label), which Candidate no longer carries
    // (there is no machine axis to name).
    const axis_name = if (c.kind == .machine_local) "machine" else c.axis_name;
    const axis_value = if (c.kind == .machine_local) cc.machine else c.axis_value;
    if (!mox.source.tuple.isNameableAxisValue(axis_value)) {
        try cc.stdout.print("  {s}: {s}={s} cannot name a fragment file; left uncommitted (edit the source manually)\n", .{ desc, axis_name, axis_value });
        return .unroutable;
    }
    // Some narrowings cannot be synthesized without damaging or losing data:
    // one that wraps line 1 displaces a shebang or a whole-file gate, one
    // whose region name the file already uses hands its fragment to that
    // existing region as well, and one whose fragment path already holds a
    // leftover file would silently overwrite it. Refuse rather than corrupt
    // or destroy the source: the hunk stays uncommitted, like any other
    // unroutable narrowing.
    if (try mox.classify.synth.hazardOf(cc.arena, cc.io, edit.path, base_content, marker, edit.start, edit.del, axis_name, axis_value)) |hz| {
        try cc.stdout.print("  {s}: {s}; left uncommitted (edit the source manually)\n", .{ desc, try hz.message(cc.arena) });
        return .unroutable;
    }
    const plan = try mox.classify.synth.planRegion(
        cc.arena,
        edit.path,
        base_content,
        marker,
        edit.start,
        edit.del,
        edit.new_lines,
        axis_name,
        axis_value,
    );
    // A region or fragment an EARLIER hunk of this same commit will create is
    // as real as one already on disk: the second narrowing to it is refused the
    // same way, and its hunk stays uncommitted.
    if (try cc.claims.hazard(cc.arena, edit.path, plan.region, plan.fragment_path)) |msg| {
        try cc.stdout.print("  {s}: {s}; left uncommitted (edit the source manually)\n", .{ desc, msg });
        return .unroutable;
    }
    try cc.claims.add(cc.arena, edit.path, plan.region, plan.fragment_path);
    // Only an axis narrowing is allowed to change other configurations
    // (those sharing its value); a machine-local narrowing gates on this
    // machine alone, so no sibling configuration may change.
    const allowed: []const []const u8 = if (c.kind == .axis)
        try configsMatchingAxis(cc.arena, configs, c.axis_name, c.axis_value)
    else
        &.{};
    return .{ .synth = .{ .plan = plan, .base_abs = edit.path, .allowed = allowed } };
}

/// Labels of sibling configurations whose binding for `name` equals `value`,
/// so a chosen axis narrowing can scope which siblings it is expected to
/// change.
fn configsMatchingAxis(arena: std.mem.Allocator, configs: []const Configuration, name: []const u8, value: []const u8) ![]const []const u8 {
    var labels: std.ArrayList([]const u8) = .empty;
    for (configs) |cfg| {
        if (cfg.is_this_machine) continue;
        const v = cfg.bindings.get(name) orelse continue;
        if (std.mem.eql(u8, v, value)) try labels.append(arena, cfg.label);
    }
    return labels.toOwnedSlice(arena);
}

/// Run impact analysis for one line edit: snapshot every configuration's
/// compose, transiently write the edited source, snapshot again, then restore.
/// The transient write is always reverted, so the abort-writes-nothing contract
/// holds.
fn simulateImpact(cc: *const ClassCtx, file: mox.source.tree.ManagedFile, edit: LineEdit, configs: []const Configuration) !impact.Impact {
    const arena = cc.arena;
    const io = cc.io;
    const original = try Io.Dir.cwd().readFileAlloc(io, edit.path, arena, .limited(max_file_bytes));
    const before = try impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets);

    const edited = try editedContent(arena, original, edit);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edit.path, .data = edited });
    const after = impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets) catch |e| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = edit.path, .data = original }) catch {};
        return e;
    };
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edit.path, .data = original });

    return impact.impact(arena, configs, before, after);
}

/// Run impact analysis for one loop-row edit: snapshot every configuration's
/// compose, transiently rewrite the row in its data source, snapshot again, then
/// restore. The transient write is always reverted.
fn simulateRowImpact(cc: *const ClassCtx, file: mox.source.tree.ManagedFile, edit: RowEdit, configs: []const Configuration) !impact.Impact {
    const arena = cc.arena;
    const io = cc.io;
    const original = try Io.Dir.cwd().readFileAlloc(io, edit.data_source, arena, .limited(max_file_bytes));
    const before = try impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets);

    const edited = try splicedContent(arena, original, edit.splices);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edit.data_source, .data = edited });
    const after = impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets) catch |e| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = edit.data_source, .data = original }) catch {};
        return e;
    };
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edit.data_source, .data = original });

    return impact.impact(arena, configs, before, after);
}

/// Run impact analysis for a fact edit: snapshot every configuration's
/// compose under the CURRENT fact value, then again under `new_value` --
/// purely in memory (an in-place `MachineState` copy, never a facts.toml
/// write), so there is nothing to revert on error.
fn simulateFactImpact(cc: *const ClassCtx, file: mox.source.tree.ManagedFile, name: []const u8, new_value: []const u8, configs: []const Configuration) !impact.Impact {
    const arena = cc.arena;
    const io = cc.io;
    const before = try impact.snapshot(arena, io, file, configs, cc.m_state, cc.secrets);
    const edited_state = try withFact(arena, cc.m_state.*, name, new_value);
    const after = try impact.snapshot(arena, io, file, configs, &edited_state, cc.secrets);
    return impact.impact(arena, configs, before, after);
}

/// `base` with `name` set to `value` among its custom facts (replacing an
/// existing entry, or appending a new one). `base.custom_facts` is not
/// mutated; the returned state's is a fresh arena-owned slice.
fn withFact(arena: std.mem.Allocator, base: mox.machine.state.MachineState, name: []const u8, value: []const u8) !mox.machine.state.MachineState {
    var facts = try arena.alloc(mox.machine.state.Fact, base.custom_facts.len + 1);
    var n: usize = 0;
    var replaced = false;
    for (base.custom_facts) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            facts[n] = .{ .name = name, .value = value };
            replaced = true;
        } else {
            facts[n] = f;
        }
        n += 1;
    }
    if (!replaced) {
        facts[n] = .{ .name = name, .value = value };
        n += 1;
    }
    var out = base;
    out.custom_facts = facts[0..n];
    return out;
}

/// `base` with fact `name` as `from` has it: set to its value there, or
/// removed when `from` does not set it.
fn withFactOf(arena: std.mem.Allocator, base: mox.machine.state.MachineState, name: []const u8, from: mox.machine.state.MachineState) !mox.machine.state.MachineState {
    for (from.custom_facts) |f| {
        if (std.mem.eql(u8, f.name, name)) return withFact(arena, base, name, f.value);
    }
    var facts: std.ArrayList(mox.machine.state.Fact) = .empty;
    for (base.custom_facts) |f| {
        if (!std.mem.eql(u8, f.name, name)) try facts.append(arena, f);
    }
    var out = base;
    out.custom_facts = facts.items;
    return out;
}

/// Apply one line edit to `content` in memory, preserving its trailing-newline
/// shape. Mirrors `splicedContent` for a single splice.
fn editedContent(arena: std.mem.Allocator, content: []const u8, edit: LineEdit) ![]u8 {
    const had_trailing_nl = content.len > 0 and content[content.len - 1] == '\n';
    var lines: std.ArrayList([]const u8) = .empty;
    for (try mox.diff.lines.splitLines(arena, content)) |l| try lines.append(arena, l);
    const start = @min(edit.start, lines.items.len);
    const end = @min(start + edit.del, lines.items.len);
    try lines.replaceRange(arena, start, end - start, edit.new_lines);

    var out: std.ArrayList(u8) = .empty;
    for (lines.items, 0..) |l, idx| {
        if (idx > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, l);
    }
    if (had_trailing_nl and lines.items.len > 0) try out.append(arena, '\n');
    return out.toOwnedSlice(arena);
}

/// Render one prompt/report line per candidate plus the manual/skip/quit tail.
fn writeCandidates(arena: std.mem.Allocator, w: *Io.Writer, cands: []const candidates.Candidate, machine: []const u8) !void {
    for (cands, 0..) |c, i| {
        try w.print("    [{d}] {s}\n", .{ i + 1, try candidateLabel(arena, c, machine) });
    }
    try w.writeAll("    [m] manual  [s] skip  [q] quit  [?] help\n");
}

/// Human-readable label for a candidate.
fn candidateLabel(arena: std.mem.Allocator, c: candidates.Candidate, machine: []const u8) ![]const u8 {
    return switch (c.kind) {
        .universal => "universal",
        .axis => c.label,
        .machine_local => try std.fmt.allocPrint(arena, "machine={s} (only here)", .{machine}),
        .private => "private",
    };
}

/// `?`-help text for a candidate: what choosing it does to the edit.
fn candidateHelp(arena: std.mem.Allocator, c: candidates.Candidate) ![]const u8 {
    return switch (c.kind) {
        .universal => "keep the edit everywhere -- every configuration composes it",
        .axis => std.fmt.allocPrint(arena, "narrow the edit to configurations where {s}", .{c.label}),
        .machine_local => "narrow the edit to only this machine",
        .private => "narrow the edit to the private layer (no automatic route)",
    };
}

/// One `<...>` capture matched against a composed line by literal-position
/// splitting: `name` is the raw text between `<` and `>` (a ` | default "..."`
/// clause, if any, still attached), `value` is the substring of the matched
/// line it captured, and `open`/`close` are the byte indices of `<`/`>` in
/// `template` -- shared by every line matched against the SAME template
/// instance, so a caller can splice a replacement back into it.
const RawCapture = struct { name: []const u8, value: []const u8, open: usize, close: usize };

/// Match `line` against `template`'s literal frame, returning every `<...>`
/// capture's raw name, matched value, and template span, in template order --
/// or null when the non-capture text does not line up. A template with no
/// captures matches only by exact equality, yielding an empty (non-null)
/// slice. Templates are linted to forbid adjacent captures, so every interior
/// literal is non-empty, which makes the greedy match unambiguous.
fn matchCaptures(arena: std.mem.Allocator, template: []const u8, line: []const u8) !?[]const RawCapture {
    var literals: std.ArrayList([]const u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var opens: std.ArrayList(usize) = .empty;
    var closes: std.ArrayList(usize) = .empty;
    var i: usize = 0;
    var lit_start: usize = 0;
    while (i < template.len) {
        if (template[i] == '<') {
            const close = std.mem.indexOfScalarPos(u8, template, i + 1, '>') orelse {
                i += 1;
                continue;
            };
            try literals.append(arena, template[lit_start..i]);
            try names.append(arena, template[i + 1 .. close]);
            try opens.append(arena, i);
            try closes.append(arena, close);
            i = close + 1;
            lit_start = i;
            continue;
        }
        i += 1;
    }
    try literals.append(arena, template[lit_start..]);

    // No captures: a match is only a literal-equality check, yielding no
    // field updates.
    if (names.items.len == 0) {
        if (std.mem.eql(u8, template, line)) return &.{};
        return null;
    }

    var values = try arena.alloc([]const u8, names.items.len);
    var pos: usize = 0;
    if (!std.mem.startsWith(u8, line, literals.items[0])) return null;
    pos += literals.items[0].len;

    for (names.items, 0..) |_, ci| {
        const delim = literals.items[ci + 1];
        const is_last = ci == names.items.len - 1;
        if (is_last) {
            if (delim.len == 0) {
                values[ci] = line[pos..];
                pos = line.len;
            } else {
                if (line.len < pos + delim.len) return null;
                if (!std.mem.endsWith(u8, line, delim)) return null;
                values[ci] = line[pos .. line.len - delim.len];
                pos = line.len;
            }
        } else {
            if (delim.len == 0) return null;
            const idx = std.mem.indexOfPos(u8, line, pos, delim) orelse return null;
            values[ci] = line[pos..idx];
            pos = idx + delim.len;
        }
    }

    var caps = try arena.alloc(RawCapture, names.items.len);
    for (names.items, 0..) |name, ci| {
        caps[ci] = .{ .name = name, .value = values[ci], .open = opens.items[ci], .close = closes.items[ci] };
    }
    return caps;
}

/// A file's hunks as loop routing reads them: the baseline and its
/// provenance, the live lines and the diff, and a compose of the sources as
/// they stand, secrets as placeholders, made when a loop hunk first needs it.
const LoopFile = struct {
    file: mox.source.tree.ManagedFile,
    /// Routed against the baseline the last apply recorded, not a fresh
    /// compose: a row index there may be stale.
    stored: bool,
    segments: []const Segment,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
    hunks: []const Hunk,
    fresh: ?Fresh = null,
    fresh_tried: bool = false,

    const Fresh = struct {
        lines: []const []const u8,
        segments: []const Segment,
        sites: []const mox.compose.interp.LoopSite,
    };

    /// The fresh compose, or null when the sources do not compose here.
    fn freshCompose(lf: *LoopFile, cc: *const ClassCtx) !?Fresh {
        if (lf.fresh_tried) return lf.fresh;
        lf.fresh_tried = true;
        var prov: std.ArrayList(Segment) = .empty;
        var sites: std.ArrayList(mox.compose.interp.LoopSite) = .empty;
        var diag: mox.compose.interp.Diag = .{ .loops = &sites };
        const composed = mox.compose.composeFileTracked(cc.arena, cc.io, lf.file, cc.resolver, cc.m_state, null, &prov, &diag) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return null,
        };
        const bytes = composed orelse return null;
        lf.fresh = .{ .lines = try mox.diff.lines.splitLines(cc.arena, bytes), .segments = prov.items, .sites = sites.items };
        return lf.fresh;
    }

    /// The live line baseline line `i` stands at: the line the diff matched
    /// it with, or the line at its offset in a hunk replacing lines one for
    /// one -- any such hunk with `in_equal`, else only one replacing exactly
    /// that line. Null otherwise.
    fn liveLineAt(lf: *const LoopFile, i: u32, in_equal: bool) ?[]const u8 {
        var shift: i64 = 0;
        for (lf.hunks) |h| {
            if (i >= h.a_start and i < h.a_start + h.a_len) {
                if (h.a_len == h.b_len and (in_equal or h.a_len == 1)) return lf.b_lines[h.b_start + (i - h.a_start)];
                return null;
            }
            if (h.a_start + h.a_len <= i) shift += @as(i64, h.b_len) - @as(i64, h.a_len);
        }
        const j = @as(i64, i) + shift;
        if (j < 0 or j >= lf.b_lines.len) return null;
        return lf.b_lines[@intCast(j)];
    }

    /// The live text at every line of baseline segment `seg`, or null when
    /// a line of it has no live line (`liveLineAt`).
    fn liveText(lf: *const LoopFile, arena: std.mem.Allocator, seg: Segment, in_equal: bool) !?[]const u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        var j: u32 = 0;
        while (j < seg.out_len) : (j += 1) {
            try lines.append(arena, lf.liveLineAt(seg.out_start + j, in_equal) orelse return null);
        }
        return try std.mem.join(arena, "\n", lines.items);
    }
};

/// One `.loop` segment of a loop's block and the text it covers.
const LoopElem = struct { seg: Segment, text: []const u8 };

/// Every `.loop` segment of `segments` over `data_source` with `template`,
/// in output order, with the text of `lines` it covers.
fn loopBlock(arena: std.mem.Allocator, segments: []const Segment, lines: []const []const u8, data_source: []const u8, template: []const u8) ![]const LoopElem {
    var out: std.ArrayList(LoopElem) = .empty;
    for (segments) |sg| {
        const o = switch (sg.origin) {
            .loop => |o| o,
            else => continue,
        };
        if (!std.mem.eql(u8, o.data_source, data_source) or !std.mem.eql(u8, o.template, template)) continue;
        const end = @min(sg.out_start + sg.out_len, lines.len);
        const start = @min(sg.out_start, end);
        try out.append(arena, .{ .seg = sg, .text = try std.mem.join(arena, "\n", lines[start..end]) });
    }
    return out.toOwnedSlice(arena);
}

fn uniqueIn(block: []const LoopElem, text: []const u8) bool {
    var n: usize = 0;
    for (block) |e| {
        if (std.mem.eql(u8, e.text, text)) n += 1;
    }
    return n == 1;
}

/// Route a hunk covered by a loop row: to the covering segment's own row,
/// when the loop block up to it still renders what the last apply wrote, the
/// row's line is unique in its block, the live line splits into one changed
/// field set, every changed field can be written in its own type, and the
/// row as written renders the live line wherever the file renders it.
fn loopRoute(cc: *const ClassCtx, lf: *LoopFile, seg: Segment, hunk: Hunk) !Route {
    const arena = cc.arena;
    const o = seg.origin.loop;
    if (seg.out_len > 1) return .{ .manual = "data row spans several lines" };
    if (std.mem.indexOfScalar(u8, o.template, '\n') != null) return .{ .manual = "multi-line loop template" };
    if (hunk.a_len != 1 or hunk.b_len != 1) return .{ .manual = "loop row insertion or deletion" };
    const stale: Route = .{ .manual = "data row no longer matches what the last apply wrote" };
    const fresh = (try lf.freshCompose(cc)) orelse return stale;
    const recorded = try loopBlock(arena, lf.segments, lf.a_lines, o.data_source, o.template);
    const now = try loopBlock(arena, fresh.segments, fresh.lines, o.data_source, o.template);
    const k = for (recorded, 0..) |e, i| {
        if (e.seg.out_start == seg.out_start) break i;
    } else return stale;
    if (now.len <= k) return stale;
    if (lf.stored) {
        for (recorded[0 .. k + 1], now[0 .. k + 1], 0..) |r, n, i| {
            if (r.seg.origin.loop.row != n.seg.origin.loop.row) return stale;
            if (std.mem.eql(u8, r.text, n.text)) continue;
            // Already in the source and live, as after a commit beside a held
            // hunk; the covering row itself is re-offered against a source
            // that moved on, so it stays manual.
            if (i < k) {
                if (try lf.liveText(arena, r.seg, true)) |t| {
                    if (std.mem.eql(u8, t, n.text)) continue;
                }
            }
            return stale;
        }
        if (!uniqueIn(recorded, recorded[k].text) or !uniqueIn(now, now[k].text)) return .{ .manual = "data row is not unique in its loop" };
    }
    const fo = now[k].seg.origin.loop;
    const loop = fresh.sites[fo.site orelse return stale];
    const site: RowSite = .{ .data_source = fo.data_source, .row = fo.row, .template = loop.template, .variable = loop.variable, .where = loop.where };
    const planned = switch (try planRowWrite(cc, lf.file, site, lf.b_lines[hunk.b_start])) {
        .no_match => return .{ .manual = "live line does not match loop template" },
        .manual => |reason| return .{ .manual = reason },
        .write => |w| w,
    };
    if (try elsewhereRefusal(cc, lf, fresh, site, planned.record)) |reason| return .{ .manual = reason };
    const desc = try std.fmt.allocPrint(arena, "{s} row {d}", .{ fo.data_source, fo.row });
    return .{ .row = .{
        .edit = .{
            .data_source = fo.data_source,
            .stem = mox.data.source.arrayName(fo.data_source),
            .row = fo.row,
            .splices = planned.splices,
            .template = loop.template,
            .variable = loop.variable,
            .where = loop.where,
        },
        .desc = desc,
    } };
}

/// Why rendering the row as `planned` writes it through every loop of the
/// file over its data source would not reproduce live, or null when it
/// would: a rendering appearing or disappearing, one with no position, or
/// one that does not equal the live line at its position.
fn elsewhereRefusal(cc: *const ClassCtx, lf: *const LoopFile, fresh: LoopFile.Fresh, site: RowSite, planned: *const mox.data.toml.Record) !?[]const u8 {
    const arena = cc.arena;
    const differently = "data row would render differently elsewhere in the file";
    const unplaced = "data row also renders elsewhere in the file without a position";
    for (fresh.sites, 0..) |loop, si| {
        if (!std.mem.eql(u8, loop.data_source, site.data_source)) continue;
        // Its rendering of the row has no position of its own.
        if (!loop.attributed) return unplaced;
        const ctx = rowCtx(arena, cc, lf.file, loop.variable, planned) catch |e| switch (e) {
            error.OutOfMemory => return e,
        };
        const in_planned = try rowPasses(arena, cc, loop.where, ctx.scope);
        var rendering: ?Segment = null;
        var count: usize = 0;
        for (fresh.segments) |sg| {
            const o = switch (sg.origin) {
                .loop => |o| o,
                else => continue,
            };
            if (o.site != @as(?u32, @intCast(si)) or o.row != site.row) continue;
            rendering = sg;
            count += 1;
        }
        if (in_planned != (count > 0)) return differently;
        if (!in_planned) continue;
        // A rendering a secret line splits has no single position.
        if (count != 1) return unplaced;
        const text = interp.expand(arena, loop.template, planned, ctx) catch |e| switch (e) {
            error.OutOfMemory => return e,
            // A rendering that fails to expand counts as disappearing.
            else => return differently,
        };
        const lines = try mox.diff.lines.splitLines(arena, try std.fmt.allocPrint(arena, "{s}\n", .{text}));
        const fresh_seg = rendering.?;
        if (fresh_seg.out_len != lines.len) return unplaced;
        // Its position: the recorded rendering of this row through the same
        // template, in the same place in output order.
        var nth: usize = 0;
        for (fresh.segments) |sg| {
            if (sg.out_start >= fresh_seg.out_start) break;
            if (sameRowTemplate(sg, site.data_source, site.row, loop.template)) nth += 1;
        }
        const pos = for (lf.segments) |sg| {
            if (!sameRowTemplate(sg, site.data_source, site.row, loop.template)) continue;
            if (nth == 0) break sg;
            nth -= 1;
        } else return unplaced;
        if (pos.out_len != lines.len) return unplaced;
        for (lines, 0..) |line, j| {
            const live = lf.liveLineAt(pos.out_start + @as(u32, @intCast(j)), false) orelse return unplaced;
            if (!std.mem.eql(u8, live, line)) return try std.fmt.allocPrint(arena, "data row also renders at line {d} without this edit", .{pos.out_start + 1});
        }
    }
    return null;
}

fn sameRowTemplate(sg: Segment, data_source: []const u8, row: u32, template: []const u8) bool {
    const o = switch (sg.origin) {
        .loop => |o| o,
        else => return false,
    };
    return o.row == row and std.mem.eql(u8, o.data_source, data_source) and std.mem.eql(u8, o.template, template);
}

/// The loop a row hunk is routed through: the data file and row, the body
/// template, and the variable and `where` of the loop that rendered it. A
/// generator leaf also carries its `into` path template, the directory it
/// renders into, and its live path.
const RowSite = struct {
    data_source: []const u8,
    row: u32,
    template: []const u8,
    variable: []const u8,
    where: ?*const mox.dsl.ast.RowExpr,
    leaf: ?Leaf = null,

    const Leaf = struct { into: []const u8, dir: []const u8, live_path: []const u8 };
};

/// What routing a live line through a row decided: the line matches the
/// template's literal frame in no way, the hunk is manual, or the field
/// splices to write and the row as they leave it.
const RowPlan = union(enum) {
    no_match,
    manual: []const u8,
    write: struct { splices: []const LineEdit, record: *const mox.data.toml.Record },
};

/// A template split for matching against a live line: literal text, where a
/// capture that is not row data stands as its current expansion, or a
/// capture of a row field.
const Piece = struct {
    text: []const u8,
    field: ?[]const u8 = null,
    /// The expander resolves captures inside this field's stored value.
    expands: bool = false,
    /// What this capture renders from the row as it stands.
    current: []const u8 = "",
};

/// Every complete split of a live line into row fields counts toward this
/// limit; past it the line is manual.
const max_row_splits: usize = 256;

/// The capture-expansion context rendering a row of a top-level loop under
/// `variable`, as compose renders it here with secrets as placeholders.
fn rowCtx(arena: std.mem.Allocator, cc: *const ClassCtx, file: mox.source.tree.ManagedFile, variable: []const u8, record: *const mox.data.toml.Record) !interp.Ctx {
    const frames = try arena.dupe(interp.Frame, &.{.{ .name = variable, .value = .{ .record = record } }});
    return .{ .io = cc.io, .machine = cc.m_state, .repo_dir = file.repo_dir, .private_dir = file.private_dir, .scope = frames };
}

/// Whether a row passes a loop's `where`; a predicate that cannot be
/// evaluated passes nothing.
fn rowPasses(arena: std.mem.Allocator, cc: *const ClassCtx, where: ?*const mox.dsl.ast.RowExpr, frames: []const interp.Frame) !bool {
    const w = where orelse return true;
    return mox.dsl.row_expr.evaluate(arena, w, frames, cc.resolver, null) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => false,
    };
}

/// The row field a capture body reads when it is row data: a field of the
/// loop variable or of `entry.`, whose stored value the expander resolves
/// once more, or a bare field, spliced verbatim. Null for a capture with a
/// default or a chain, and for `machine.`, `env.`, `data.` and `secret:`.
fn rowField(inner: []const u8, variable: []const u8) ?struct { name: []const u8, expands: bool } {
    const capture = mox.compose.capture;
    if (std.mem.startsWith(u8, inner, "secret:")) return null;
    const split = capture.splitDefault(inner);
    if (split.default != null or capture.isChain(split.field)) return null;
    const f = split.field;
    for ([_][]const u8{ variable, "entry" }) |head| {
        if (f.len > head.len + 1 and std.mem.startsWith(u8, f, head) and f[head.len] == '.') return .{ .name = f[head.len + 1 ..], .expands = true };
    }
    if (f.len == 0 or capture.hasNamespace(f) or std.mem.eql(u8, f, variable)) return null;
    return .{ .name = f, .expands = false };
}

/// `template` as pieces to match a live line against, with every capture
/// that is not row data expanded against `record`; null when a capture does
/// not expand.
fn templatePieces(arena: std.mem.Allocator, template: []const u8, variable: []const u8, record: *const mox.data.toml.Record, ctx: interp.Ctx) !?[]const Piece {
    var pieces: std.ArrayList(Piece) = .empty;
    var literal: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '<') {
            if (mox.compose.capture.closeIndex(template, i)) |close| {
                const text = template[i .. close + 1];
                const current = interp.expand(arena, text, record, ctx) catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    else => return null,
                };
                if (rowField(template[i + 1 .. close], variable)) |f| {
                    if (literal.items.len > 0) try pieces.append(arena, .{ .text = try literal.toOwnedSlice(arena) });
                    try pieces.append(arena, .{ .text = text, .field = f.name, .expands = f.expands, .current = current });
                } else {
                    try literal.appendSlice(arena, current);
                }
                i = close + 1;
                continue;
            }
        }
        try literal.append(arena, template[i]);
        i += 1;
    }
    if (literal.items.len > 0) try pieces.append(arena, .{ .text = try literal.toOwnedSlice(arena) });
    return try pieces.toOwnedSlice(arena);
}

/// Every way `line` splits against `pieces`, each as the text every piece
/// takes; null past `limit` splits. Only states from which the rest of the
/// line can still match are entered, each counted in `visits`.
fn rowSplits(arena: std.mem.Allocator, pieces: []const Piece, line: []const u8, limit: usize, visits: *usize) !?[]const []const []const u8 {
    const w = line.len + 1;
    // reach[p * w + pos]: pieces[p..] can match line[pos..].
    const reach = try arena.alloc(bool, (pieces.len + 1) * w);
    @memset(reach, false);
    reach[pieces.len * w + line.len] = true;
    var p = pieces.len;
    while (p > 0) {
        p -= 1;
        const piece = pieces[p];
        if (piece.field == null) {
            for (0..w) |pos| {
                reach[p * w + pos] = std.mem.startsWith(u8, line[pos..], piece.text) and reach[(p + 1) * w + pos + piece.text.len];
            }
        } else {
            var any = false;
            var pos = w;
            while (pos > 0) {
                pos -= 1;
                any = any or reach[(p + 1) * w + pos];
                reach[p * w + pos] = any;
            }
        }
    }
    const Walk = struct {
        arena: std.mem.Allocator,
        pieces: []const Piece,
        line: []const u8,
        reach: []const bool,
        w: usize,
        taken: [][]const u8,
        limit: usize,
        visits: *usize,
        out: std.ArrayList([]const []const u8) = .empty,

        fn go(s: *@This(), at: usize, pos: usize) error{ OutOfMemory, TooMany }!void {
            s.visits.* += 1;
            if (at == s.pieces.len) {
                if (s.out.items.len == s.limit) return error.TooMany;
                try s.out.append(s.arena, try s.arena.dupe([]const u8, s.taken));
                return;
            }
            const piece = s.pieces[at];
            if (piece.field == null) {
                s.taken[at] = piece.text;
                return s.go(at + 1, pos + piece.text.len);
            }
            var end = pos;
            while (end <= s.line.len) : (end += 1) {
                if (!s.reach[(at + 1) * s.w + end]) continue;
                s.taken[at] = s.line[pos..end];
                try s.go(at + 1, end);
            }
        }
    };
    var walk: Walk = .{ .arena = arena, .pieces = pieces, .line = line, .reach = reach, .w = w, .taken = try arena.alloc([]const u8, pieces.len), .limit = limit, .visits = visits };
    if (!reach[0]) return &.{};
    walk.go(0, 0) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.TooMany => return null,
    };
    return try walk.out.toOwnedSlice(arena);
}

/// The distinct row fields `pieces` capture, in the order first captured.
fn pieceFields(arena: std.mem.Allocator, pieces: []const Piece) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (pieces) |pc| {
        const f = pc.field orelse continue;
        if (!isOneOf(f, out.items)) try out.append(arena, f);
    }
    return out.toOwnedSlice(arena);
}

const SplitChoice = union(enum) {
    no_match,
    manual: []const u8,
    split: struct { taken: []const []const u8, changed: []const bool },
};

/// The split of `line` into row fields a write follows: of the splits whose
/// captures of one field agree, the one whose changed fields are contained in
/// every other's, when exactly one is and it changes something.
fn chooseSplit(arena: std.mem.Allocator, pieces: []const Piece, fields: []const []const u8, line: []const u8) !SplitChoice {
    const ambiguous = "live line splits into row fields more than one way";
    var visits: usize = 0;
    const all = (try rowSplits(arena, pieces, line, max_row_splits, &visits)) orelse return .{ .manual = ambiguous };
    if (all.len == 0) return .no_match;
    var consistent: std.ArrayList([]const []const u8) = .empty;
    var changed_sets: std.ArrayList([]const bool) = .empty;
    for (all) |taken| {
        const changed = try arena.alloc(bool, fields.len);
        @memset(changed, false);
        if (!splitAgrees(pieces, fields, taken, changed)) continue;
        try consistent.append(arena, taken);
        try changed_sets.append(arena, changed);
    }
    if (consistent.items.len == 0) return .{ .manual = "field captured twice with different values" };
    var least: ?usize = null;
    var n_least: usize = 0;
    for (changed_sets.items, 0..) |mine, si| {
        const within = for (changed_sets.items) |other| {
            if (!isSubset(mine, other)) break false;
        } else true;
        if (!within) continue;
        least = si;
        n_least += 1;
    }
    const chosen = least orelse return .{ .manual = ambiguous };
    if (n_least != 1 or std.mem.indexOfScalar(bool, changed_sets.items[chosen], true) == null) return .{ .manual = ambiguous };
    return .{ .split = .{ .taken = consistent.items[chosen], .changed = changed_sets.items[chosen] } };
}

/// Whether a split's captures of each field agree, marking in `changed`
/// each field a capture takes other text for than the row renders now.
fn splitAgrees(pieces: []const Piece, fields: []const []const u8, taken: []const []const u8, changed: []bool) bool {
    for (fields, changed) |f, *ch| {
        var value: ?[]const u8 = null;
        for (pieces, taken) |pc, t| {
            const pf = pc.field orelse continue;
            if (!std.mem.eql(u8, pf, f)) continue;
            if (value) |v| {
                if (!std.mem.eql(u8, v, t)) return false;
            } else value = t;
            if (!std.mem.eql(u8, t, pc.current)) ch.* = true;
        }
    }
    return true;
}

fn isSubset(a: []const bool, b: []const bool) bool {
    for (a, b) |x, y| {
        if (x and !y) return false;
    }
    return true;
}

/// Every `<...>` of `text` the compose grammar's close index recognizes, as
/// written.
fn captureTexts(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '<')) |open| {
        const close = mox.compose.capture.closeIndex(text, open) orelse {
            i = open + 1;
            continue;
        };
        try out.append(arena, text[open .. close + 1]);
        i = close + 1;
    }
    return out.toOwnedSlice(arena);
}

/// `s` as a TOML basic string: `\`, `"` and control characters escaped.
fn basicString(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (s) |c| switch (c) {
        '\\' => try out.appendSlice(arena, "\\\\"),
        '"' => try out.appendSlice(arena, "\\\""),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\t' => try out.appendSlice(arena, "\\t"),
        '\r' => try out.appendSlice(arena, "\\r"),
        0x08 => try out.appendSlice(arena, "\\b"),
        0x0c => try out.appendSlice(arena, "\\f"),
        0...0x07, 0x0b, 0x0e...0x1f, 0x7f => try out.print(arena, "\\u{X:0>4}", .{c}),
        else => try out.append(arena, c),
    };
    try out.append(arena, '"');
    return out.toOwnedSlice(arena);
}

/// The splice writing `value` over statement `st`'s value in `content`: its
/// whole lines, keeping its key, spacing and trailing comment.
fn valueSplice(arena: std.mem.Allocator, path: []const u8, content: []const u8, st: toml_statements.Statement, value: []const u8) !LineEdit {
    const vs = st.value_span.start;
    const ve = st.value_span.end;
    const line_start = if (std.mem.lastIndexOfScalar(u8, content[0..vs], '\n')) |nl| nl + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, content, ve, '\n') orelse content.len;
    const start: u32 = @intCast(std.mem.count(u8, content[0..vs], "\n"));
    const del: u32 = @intCast(std.mem.count(u8, content[vs..ve], "\n") + 1);
    const line = try std.mem.concat(arena, u8, &.{ content[line_start..vs], value, content[ve..line_end] });
    return .{ .path = path, .start = start, .del = del, .new_lines = try arena.dupe([]const u8, &.{line}) };
}

/// Route `live_line` through the row `site` names: split it into row fields,
/// check each changed field can be written in its own type, splice the
/// writes over the pre-run data file, and require the row as they leave it
/// to render `live_line` (and, for a leaf, at its own path).
fn planRowWrite(cc: *const ClassCtx, file: mox.source.tree.ManagedFile, site: RowSite, live_line: []const u8) !RowPlan {
    const arena = cc.arena;
    const not_table = RowPlan{ .manual = "data row is not a table section" };
    const content = Io.Dir.cwd().readFileAlloc(cc.io, site.data_source, arena, .limited(max_file_bytes)) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return not_table,
    };
    const stem = mox.data.source.arrayName(site.data_source);
    const record = rowRecord(arena, content, stem, site.row) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return not_table,
    } orelse return not_table;
    const ctx = try rowCtx(arena, cc, file, site.variable, record);
    const pieces = (try templatePieces(arena, site.template, site.variable, record, ctx)) orelse return .no_match;
    const fields = try pieceFields(arena, pieces);
    const split = switch (try chooseSplit(arena, pieces, fields, live_line)) {
        .no_match => return .no_match,
        .manual => |reason| return .{ .manual = reason },
        .split => |sp| sp,
    };

    const stmts = toml_statements.scan(arena, content) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.NestingTooDeep => return not_table,
    };
    const section = toml_statements.arrayTableRow(stmts, stem, site.row) orelse return not_table;
    var splices: std.ArrayList(LineEdit) = .empty;
    for (fields, split.changed) |f, changed| {
        if (!changed) continue;
        var new: []const u8 = "";
        var expands = false;
        for (pieces, split.taken) |pc, t| {
            const pf = pc.field orelse continue;
            if (!std.mem.eql(u8, pf, f)) continue;
            new = t;
            expands = expands or pc.expands;
        }
        const st = for (section.body) |st| {
            if (st.key.len == 1 and std.mem.eql(u8, st.key[0], f)) break st;
        } else return not_table;
        const stored = (try mox.data.toml.parseValue(arena, try st.valueText(arena, content))) orelse return .{ .manual = "data value type" };
        const kind = mox.data.toml.kindOf(stored);
        if (kind == .array) return .{ .manual = "data value is an array" };
        if (expands) {
            if (record.get(f)) |v| {
                if ((try captureTexts(arena, try v.format(arena))).len > 0) return .{ .manual = "data value holds a capture" };
            }
        }
        const written = switch (kind) {
            .string => blk: {
                if (!std.unicode.utf8ValidateSlice(new)) return .{ .manual = "data value type" };
                const known = try captureTexts(arena, stored.string);
                for (try captureTexts(arena, new)) |c| {
                    if (!isOneOf(c, known)) return .{ .manual = "new value holds a capture" };
                }
                break :blk try basicString(arena, new);
            },
            .table => return .{ .manual = "data value type" },
            else => (try mox.data.toml.canonicalScalar(arena, kind, new)) orelse return .{ .manual = "data value type" },
        };
        try splices.append(arena, try valueSplice(arena, site.data_source, content, st, written));
    }

    const after = try splicedContent(arena, content, splices.items);
    const planned = rowRecord(arena, after, stem, site.row) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => null,
    } orelse return .{ .manual = "the edited row does not render the edited line" };
    const pctx = try rowCtx(arena, cc, file, site.variable, planned);
    if (!try rowPasses(arena, cc, site.where, pctx.scope)) return .{ .manual = "the edited row is filtered out" };
    const rendered = interp.expand(arena, site.template, planned, pctx) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .manual = "the edited row does not render the edited line" },
    };
    if (!std.mem.eql(u8, rendered, live_line)) return .{ .manual = "the edited row does not render the edited line" };
    if (site.leaf) |leaf| {
        const moved = RowPlan{ .manual = "the edited row moves the leaf" };
        const into = interp.expand(arena, leaf.into, planned, pctx) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return moved,
        };
        const path = try mox.source.path.joinKeyOnto(arena, leaf.dir, into);
        if (!std.mem.eql(u8, try mox.source.path.toKey(arena, path), try mox.source.path.toKey(arena, leaf.live_path))) return moved;
    }
    return .{ .write = .{ .splices = try splices.toOwnedSlice(arena), .record = planned } };
}

/// Row `row` of the `[[stem]]` array `content` holds, as a loop reads it, or
/// null when there is none.
fn rowRecord(arena: std.mem.Allocator, content: []const u8, stem: []const u8, row: u32) !?*const mox.data.toml.Record {
    const rows = try mox.data.toml.parse(arena, content);
    const list = rows.get(stem) orelse return null;
    if (row >= list.len) return null;
    return &list[row];
}

/// Fact name a capture's raw text maps to, when it is a plain `<machine.X>`
/// or `<machine.X | default "...">` reference to a genuine user-defined fact
/// -- never a fallback chain (which member actually produced the value is
/// ambiguous), and never a name `formatMachineField` resolves itself before
/// ever consulting `custom_facts` (writing that as a fact would be silently
/// ineffective). Null for anything else.
fn asMachineCapture(name: []const u8) ?[]const u8 {
    const marker = " | default \"";
    const field = if (std.mem.indexOf(u8, name, marker)) |idx|
        std.mem.trimEnd(u8, name[0..idx], " \t")
    else if (std.mem.indexOf(u8, name, " | ") != null)
        return null
    else
        name;
    if (!std.mem.startsWith(u8, field, "machine.")) return null;
    const fact = field[8..];
    if (isBuiltinMachineField(fact)) return null;
    return fact;
}

/// True when `field` is one of the `MachineState` fields `formatMachineField`
/// (`src/compose/interp.zig`) resolves itself before ever falling through to
/// `custom_facts`.
fn isBuiltinMachineField(field: []const u8) bool {
    return mox.machine.state.isBuiltinField(field);
}

/// Rebuild `template` with the capture spanning `[open, close]` (whose raw
/// text is `inner`) rewritten to carry `value` as its `| default "..."`
/// clause -- replacing an existing default, or adding one when the capture
/// had none.
fn spliceDefault(arena: std.mem.Allocator, template: []const u8, inner: []const u8, open: usize, close: usize, value: []const u8) ![]const u8 {
    const marker = " | default \"";
    const field = if (std.mem.indexOf(u8, inner, marker)) |idx| std.mem.trimEnd(u8, inner[0..idx], " \t") else inner;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, template[0 .. open + 1]);
    try out.appendSlice(arena, field);
    try out.appendSlice(arena, marker);
    try out.appendSlice(arena, value);
    try out.append(arena, '"');
    try out.appendSlice(arena, template[close..]);
    return out.toOwnedSlice(arena);
}

/// `content` with every splice in `edits` applied. Each splice indexes the
/// pre-write lines, so they are applied high-index-first: an earlier splice
/// never shifts a later one's range. The trailing-newline shape is preserved.
fn splicedContent(arena: std.mem.Allocator, content: []const u8, edits: []const LineEdit) ![]const u8 {
    const had_trailing_nl = content.len > 0 and content[content.len - 1] == '\n';

    var lines: std.ArrayList([]const u8) = .empty;
    for (try mox.diff.lines.splitLines(arena, content)) |l| try lines.append(arena, l);

    const ordered = try arena.dupe(LineEdit, edits);
    std.mem.sort(LineEdit, ordered, {}, cmpEditDesc);
    for (ordered) |fe| {
        const start = @min(fe.start, lines.items.len);
        const end = @min(start + fe.del, lines.items.len);
        try lines.replaceRange(arena, start, end - start, fe.new_lines);
    }

    var out: std.ArrayList(u8) = .empty;
    for (lines.items, 0..) |l, idx| {
        if (idx > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, l);
    }
    if (had_trailing_nl and lines.items.len > 0) try out.append(arena, '\n');
    return out.toOwnedSlice(arena);
}

/// The distinct base files the accepted narrowings rewrite, in order.
fn synthBases(arena: std.mem.Allocator, plans: []const SynthDecision) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (plans) |sd| {
        var seen = false;
        for (out.items) |p| {
            if (std.mem.eql(u8, p, sd.base_abs)) seen = true;
        }
        if (!seen) try out.append(arena, sd.base_abs);
    }
    return out.toOwnedSlice(arena);
}

fn isOneOf(path: []const u8, paths: []const []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

fn isSynthFragment(path: []const u8, plans: []const SynthDecision) bool {
    for (plans) |sd| {
        if (std.mem.eql(u8, sd.plan.fragment_path, path)) return true;
    }
    return false;
}

fn cmpEditDesc(_: void, a: LineEdit, b: LineEdit) bool {
    return a.start > b.start;
}

/// Write every routed fact edit to the machine-local facts file in one pass,
/// deduping by name (last edit in `edits` wins) so a batch never asks
/// `persist` to assign the same key twice. This is the `[f]` write path: it
/// touches only `facts_path`, never repo `src`.
fn applyFactEdits(arena: std.mem.Allocator, io: Io, facts_path: []const u8, edits: []const FactEdit) !void {
    if (edits.len == 0) return;
    var answers: std.ArrayList(mox.machine.state.Fact) = .empty;
    outer: for (edits, 0..) |e, i| {
        for (edits[i + 1 ..]) |later| {
            if (std.mem.eql(u8, later.name, e.name)) continue :outer;
        }
        try answers.append(arena, .{ .name = e.name, .value = e.new_value });
    }
    try mox.machine.interview.persist(arena, io, facts_path, answers.items);
}

/// True when any `.secret`-origin segment overlaps the hunk's a-range. This
/// is deliberately broader than `covering()`: a hunk straddling a secret
/// segment and a non-secret one is uncovered (routes to plain `.manual`), but
/// its a-side text still holds the resolved secret and must not be shown --
/// so every overlap counts, not just a hunk fully contained in one segment.
fn hunkTouchesSecret(segments: []const Segment, hunk: Hunk) bool {
    const a_end = hunk.a_start + hunk.a_len;
    for (segments) |s| {
        if (s.origin != .secret) continue;
        const s_end = s.out_start + s.out_len;
        if (s.out_start < a_end and hunk.a_start < s_end) return true;
    }
    return false;
}

/// Safe replacement for `printMiniDiff` on a `.secret`-touching hunk: the new
/// live value only (never the old resolved value), plus the store URI when it
/// can be recovered from a placeholder recompose (`secret_lines`, composed
/// with no secrets context so `<secret:URI>` captures stay as literal
/// `<SECRET:uri>` text instead of resolving) -- or a generic pointer to the
/// source when it cannot.
fn printSecretNotice(cc: *const ClassCtx, secret_lines: ?[]const []const u8, hunk: Hunk, b_lines: []const []const u8) !void {
    var i: u32 = 0;
    while (i < hunk.b_len) : (i += 1) {
        try cc.sty.green(cc.stdout);
        try cc.stdout.print("    + {s}\n", .{b_lines[hunk.b_start + i]});
        try cc.sty.close(cc.stdout);
    }
    if (secretUriAt(secret_lines, hunk.a_start)) |uri| {
        try cc.stdout.print("    old value withheld; set it at the store yourself: {s}\n", .{uri});
    } else {
        try cc.stdout.writeAll("    old value withheld; edit the value at its secret directive directly\n");
    }
}

/// The `<SECRET:URI>` placeholder text at output line `a_start` of a
/// placeholder recompose, or null when there is none to recover (no
/// placeholder available, the line is out of range, or it holds no
/// placeholder marker). `secret_lines` is that recompose's split lines, index-
/// aligned with the real (secrets-resolved) recompose's `a_lines` -- both come
/// from the same base text, differing only in whether `<secret:URI>` resolved,
/// so a secret line's position matches across the two.
fn secretUriAt(secret_lines: ?[]const []const u8, a_start: u32) ?[]const u8 {
    const lines = secret_lines orelse return null;
    if (a_start >= lines.len) return null;
    const line = lines[a_start];
    const marker = "<SECRET:";
    const open = std.mem.indexOf(u8, line, marker) orelse return null;
    const rest = line[open + marker.len ..];
    const close = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
    return rest[0..close];
}

fn printMiniDiff(sty: style.Style, out: *Io.Writer, hunk: Hunk, a_lines: []const []const u8, b_lines: []const []const u8) !void {
    var i: u32 = 0;
    while (i < hunk.a_len) : (i += 1) {
        try sty.red(out);
        try out.print("    - {s}\n", .{a_lines[hunk.a_start + i]});
        try sty.close(out);
    }
    i = 0;
    while (i < hunk.b_len) : (i += 1) {
        try sty.green(out);
        try out.print("    + {s}\n", .{b_lines[hunk.b_start + i]});
        try sty.close(out);
    }
}

/// Per-hunk header for an interactive prompt: `<home-rel path>  hunk N/M  ->
/// <route>` (two spaces before the route), so the prompt reads without
/// cross-referencing the diff.
fn printHunkHeader(out: *Io.Writer, sty: style.Style, rel: []const u8, unit: []const u8, hunk_no: usize, hunk_total: usize, route: []const u8) !void {
    try sty.bold(out);
    try out.print("{s}", .{rel});
    try sty.close(out);
    try out.print("  {s} {d}/{d}  ", .{ unit, hunk_no, hunk_total });
    try sty.dim(out);
    try out.print("->  {s}", .{route});
    try sty.close(out);
    try out.writeAll("\n");
}

/// Destination named in a hunk header: where a routed edit lands and why.
fn routeLabel(arena: std.mem.Allocator, route: Route, file: mox.source.tree.ManagedFile) ![]const u8 {
    return switch (route) {
        .line => |r| lineRouteLabel(arena, r.edit, file),
        .row => |r| std.fmt.allocPrint(arena, "data source {s} (row {d})", .{ r.edit.data_source, r.edit.row }),
        .fact => |r| std.fmt.allocPrint(arena, "interpolated -- machine.{s}", .{r.name}),
        .manual => |reason| std.fmt.allocPrint(arena, "manual -- {s}", .{reason}),
    };
}

fn lineRouteLabel(arena: std.mem.Allocator, edit: LineEdit, file: mox.source.tree.ManagedFile) ![]const u8 {
    if (edit.private) return std.fmt.allocPrint(arena, "private {s}", .{edit.path});
    // `source_base_path` is already repo-relative, e.g. "src/.zshrc".
    if (file.has_base and std.mem.eql(u8, edit.path, file.source_base_abs))
        return std.fmt.allocPrint(arena, "{s} (base)", .{file.source_base_path});
    if (fragmentTuple(file, edit.path)) |t|
        return std.fmt.allocPrint(arena, "fragment {s}", .{try tupleLabel(arena, t)});
    return std.fmt.allocPrint(arena, "fragment {s}", .{edit.path});
}

/// The axis tuple of the region/overlay fragment at `path`, or null when
/// `path` is not one of `file`'s known fragments (a universal include/append
/// fragment carries an empty, i.e. universal, tuple of its own).
fn fragmentTuple(file: mox.source.tree.ManagedFile, path: []const u8) ?mox.source.tree.AxisTuple {
    for (file.regions) |region| {
        for (region.fragments) |frag| {
            if (std.mem.eql(u8, frag.path, path)) return frag.tuple;
        }
    }
    for (file.overlays) |ov| {
        if (std.mem.eql(u8, ov.path, path)) return ov.tuple;
    }
    return null;
}

/// `os=darwin+profile=work` style label for an axis tuple; "universal" for an
/// empty one.
fn tupleLabel(arena: std.mem.Allocator, t: mox.source.tree.AxisTuple) ![]const u8 {
    if (t.pairs.len == 0) return "universal";
    var out: std.ArrayList(u8) = .empty;
    for (t.pairs, 0..) |p, i| {
        if (i > 0) try out.append(arena, '+');
        try out.appendSlice(arena, p.name);
        try out.append(arena, '=');
        try out.appendSlice(arena, p.value);
    }
    return out.toOwnedSlice(arena);
}

/// Colorized, self-describing prompt legend, e.g. `[Y]es  [n]o  [m]anual
/// [q]uit  [?]help `: every choice names its own action, and the default
/// choice's key renders uppercase. Replaces a bare `[Y/n/m/q]` literal.
pub fn legend(arena: std.mem.Allocator, choices: []const prompt.Choice, default_index: usize, sty: style.Style) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    const out = &aw.writer;
    try out.writeAll("  ");
    for (choices, 0..) |c, i| {
        try writeGlyph(out, c, i == default_index and !uppercaseCollides(choices, i), sty);
        try out.writeAll("  ");
    }
    try sty.bold(out);
    try out.writeAll("[q]");
    try sty.close(out);
    try out.writeAll("uit  ");
    try sty.bold(out);
    try out.writeAll("[?]");
    try sty.close(out);
    try out.writeAll("help ");
    return aw.toOwnedSlice();
}

/// True when uppercasing this choice's single-letter key would render it
/// identically to a sibling's exact key (drift's default `s` next to the
/// `S` skip-all): keys are matched case-sensitively first, so the default
/// marker must not manufacture that ambiguity.
fn uppercaseCollides(choices: []const prompt.Choice, idx: usize) bool {
    const c = choices[idx];
    if (c.key.len != 1 or !std.ascii.isAlphabetic(c.key[0])) return false;
    const up = std.ascii.toUpper(c.key[0]);
    for (choices, 0..) |o, j| {
        if (j == idx) continue;
        if (o.key.len == 1 and o.key[0] == up) return true;
    }
    return false;
}

/// Write one choice as `[K]abel` when the label starts with the key's own
/// letter (`y`/`yes` -> `[y]es`), else `[key] label`. The default choice's
/// single-letter key renders uppercase.
fn writeGlyph(out: *Io.Writer, c: prompt.Choice, is_default: bool, sty: style.Style) !void {
    var buf: [1]u8 = undefined;
    const key: []const u8 = if (is_default and c.key.len == 1 and std.ascii.isAlphabetic(c.key[0])) blk: {
        buf[0] = std.ascii.toUpper(c.key[0]);
        break :blk &buf;
    } else c.key;
    try sty.bold(out);
    try out.print("[{s}]", .{key});
    try sty.close(out);
    if (c.key.len == 1 and c.label.len > 0 and std.ascii.toLower(c.label[0]) == std.ascii.toLower(c.key[0])) {
        try out.writeAll(c.label[1..]);
    } else {
        try out.print(" {s}", .{c.label});
    }
}

pub const command = app.command(Spec, .{
    .name = "commit",
    .usage = "mox commit [--flags] [<paths...>]",
    .summary = "Route live-file edits back into their sources",
    .details = "Also offers every untracked package (add / blacklist / skip), recording it in the data/packages manifest; never uninstalls, and a path-scoped commit skips packages entirely. Prompts [y/s] per hunk (--yes: take defaults; --dry-run: report only, exit 1 if edits remain; --abort-on-prompt: strict CI, rc 2 on the first prompt); a structured key change prompts [y/p/s] to accept the winning layer, pick another, or skip. Private-origin edits go only to the private layer, never repo src. A shared edit that would change only some of the file's own configurations prompts to keep it universal or narrow it to an axis (synthesizing a region); a changed token shared by other sources prompts to update them too.",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "PathIds: a file whose identity cannot be read is keyed by its path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "locked");
    try tmp.dir.writeFile(io, .{ .sub_path = "locked/data.toml", .data = "x = 1\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const locked = try std.fs.path.join(a, &.{ root, "locked" });
    const path = try std.fs.path.join(a, &.{ locked, "data.toml" });
    try std.testing.expect(fileIdentity(io, path) != null);

    // A directory that cannot be searched: the file exists, but neither its
    // real path nor its identity can be read.
    try Io.Dir.cwd().setFilePermissions(io, locked, Io.File.Permissions.fromMode(0o000), .{});
    defer Io.Dir.cwd().setFilePermissions(io, locked, Io.File.Permissions.fromMode(0o755), .{}) catch {};
    // Root searches anything; the fallback is about a refused read.
    if (fileIdentity(io, path) != null) return error.SkipZigTest;
    var ids: PathIds = .init(a, io);
    try std.testing.expectEqualStrings(path, try ids.canonical(path));
    try std.testing.expectEqualStrings(path, try ids.of(path));
}

test "linuxDevice: a kernel dev_t splits into statx's major and minor halves" {
    try std.testing.expectEqual((@as(u64, 8) << 32) | 1, linuxDevice(0x801));
    // Major 259, minor 300: the minor's high bits sit above the major's.
    try std.testing.expectEqual((@as(u64, 259) << 32) | 300, linuxDevice(44 | (259 << 8) | (256 << 12)));
}

test "fileIdentity: the fstatat fallback reads the identity statx does" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "x" });
    const path = try tmp.dir.realPathFileAlloc(io, "f", a);
    const z = try std.posix.toPosixPath(path);
    const via_statx = fileIdentity(io, path) orelse return error.SkipZigTest;
    try std.testing.expectEqual(via_statx, linuxStatIdentity(&z).?);
}

test "recoveryName: a path under neither root, or leaving its root, has no rooted name" {
    const roots: RecoveryRoots = .{ .repo = "/r/repo", .private = "/r/priv", .facts = "/h/facts.toml" };
    const repo = recoveryName("/r/repo/src/a.toml", roots).?;
    try std.testing.expectEqualStrings("repo", repo.root);
    try std.testing.expectEqualStrings("src/a.toml", repo.rel);
    try std.testing.expectEqualStrings("private", recoveryName("/r/priv/x", roots).?.root);
    try std.testing.expectEqualStrings("facts", recoveryName("/h/facts.toml", roots).?.root);
    try std.testing.expect(recoveryName("/r/ext/a.toml", roots) == null);
    try std.testing.expect(recoveryName("/r/repo/src/../../ext/a.toml", roots) == null);
    try std.testing.expect(recoveryName("/r/repo", roots) == null);
}

test "atPreRun: an unreadable path is never taken for its pre-run bytes" {
    try std.testing.expect(!atPreRun("", .unreadable));
    try std.testing.expect(!atPreRun(null, .unreadable));
    try std.testing.expect(atPreRun("", .{ .bytes = "" }));
    try std.testing.expect(!atPreRun("a", .{ .bytes = "b" }));
    try std.testing.expect(!atPreRun(null, .{ .bytes = "" }));
    try std.testing.expect(atPreRun(null, .absent));
    try std.testing.expect(!atPreRun("", .absent));
}

test "UndoneBy: a failing coupling target is left to its undone line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var targets = std.StringHashMap([]const usize).init(a);
    try targets.put("/src/t", &.{0});
    var owners: std.ArrayList(Unit) = .empty;
    try owners.append(a, .{ .file = 1 });
    var couplings = [_]Owned(CouplingEdit){.{ .edit = .{ .path = "/src/t", .old = "x", .new = "y" }, .owners = owners }};
    var unrouted = [_]usize{ 0, 0 };
    const u: UndoneBy = .{ .couplings = &couplings, .targets = &targets, .unrouted = &unrouted };

    try std.testing.expect(u.reports(.{ .file = 0 }));
    try std.testing.expect(!u.reports(.{ .file = 1 }));
    try std.testing.expect(!u.reports(.{ .symlink = 0 }));
    unrouted[0] = 1;
    try std.testing.expect(!u.reports(.{ .file = 0 }));
    unrouted[0] = 0;
    couplings[0].owners = .empty;
    try std.testing.expect(!u.reports(.{ .file = 0 }));
}

test "canonicalPath: every spelling of a file is one path, and an absent path keeps its tail" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/Data.toml", .data = "" });
    const real = try std.fs.path.join(a, &.{ root, "src", "Data.toml" });

    try std.testing.expectEqualStrings(real, try canonicalPath(a, io, real));
    try std.testing.expectEqualStrings(real, try canonicalPath(a, io, try std.fs.path.join(a, &.{ root, "src", ".", "Data.toml" })));
    try std.testing.expectEqualStrings(real, try canonicalPath(a, io, try std.fs.path.join(a, &.{ root, "src", "..", "src", "Data.toml" })));
    if (std.Io.File.Permissions.has_executable_bit) {
        try tmp.dir.symLink(io, "src", "data", .{});
        try std.testing.expectEqualStrings(real, try canonicalPath(a, io, try std.fs.path.join(a, &.{ root, "data", "Data.toml" })));
    }
    // On a case-insensitive file system, the spelling on disk.
    const folded = try std.fs.path.join(a, &.{ root, "SRC", "data.TOML" });
    if (Io.Dir.cwd().access(io, folded, .{})) |_| {
        try std.testing.expectEqualStrings(real, try canonicalPath(a, io, folded));
    } else |_| {}

    const absent = try std.fs.path.join(a, &.{ root, "src", "new.d", "os", "x" });
    try std.testing.expectEqualStrings(absent, try canonicalPath(a, io, absent));
    try std.testing.expectEqualStrings(absent, try canonicalPath(a, io, try std.fs.path.join(a, &.{ root, "src", ".", "new.d", "os", "x" })));
}

test "legend: the default key never uppercases into a sibling's exact key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const choices = [_]prompt.Choice{
        .{ .key = "o", .label = "overwrite" },
        .{ .key = "s", .label = "skip" },
        .{ .key = "S", .label = "skip all" },
    };
    const off = style.Style{ .on = false };
    // Default `s` beside the exact-match `S`: `[S]kip` next to `[S]kip all`
    // would be ambiguous, so the default stays lowercase.
    const line = try legend(a, &choices, 1, off);
    try testing.expect(std.mem.indexOf(u8, line, "[s]kip  ") != null);
    try testing.expect(std.mem.indexOf(u8, line, "[S]kip all") != null);
    // Without a colliding sibling the default still renders uppercase.
    const line2 = try legend(a, choices[0..2], 0, off);
    try testing.expect(std.mem.indexOf(u8, line2, "[O]verwrite") != null);
}

fn testPieces(a: std.mem.Allocator, texts: []const []const u8, current: []const []const u8) ![]const Piece {
    var out: std.ArrayList(Piece) = .empty;
    var ci: usize = 0;
    for (texts) |t| {
        if (t.len > 0 and t[0] == '<') {
            try out.append(a, .{ .text = t, .field = t[1 .. t.len - 1], .current = current[ci] });
            ci += 1;
        } else try out.append(a, .{ .text = t });
    }
    return out.toOwnedSlice(a);
}

fn expectManual(reason: []const u8, got: SplitChoice) !void {
    try testing.expect(got == .manual);
    try testing.expectEqualStrings(reason, got.manual);
}

test "chooseSplit: of several splits, the one changing the fewest fields writes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pieces = try testPieces(a, &.{ "<a>", ",", "<b>", ",", "<c>" }, &.{ "1", "2", "3" });
    const fields = try pieceFields(a, pieces);
    const got = try chooseSplit(a, pieces, fields, "1,x,y,3");
    try testing.expectEqualStrings("x,y", got.split.taken[2]);
    try testing.expectEqualSlices(bool, &.{ false, true, false }, got.split.changed);
}

test "chooseSplit: no least changed field set, a split changing nothing, and no split at all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pieces = try testPieces(a, &.{ "<a>", " ", "<b>" }, &.{ "p", "q" });
    const fields = try pieceFields(a, pieces);
    try expectManual("live line splits into row fields more than one way", try chooseSplit(a, pieces, fields, "p  q"));
    try expectManual("live line splits into row fields more than one way", try chooseSplit(a, pieces, fields, "p q"));
    try testing.expect(try chooseSplit(a, pieces, fields, "pq") == .no_match);
}

test "rowSplits: enumeration stops at its limit, having visited only states on the splits it counted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Four fields joined by commas against fourteen commas: 364 splits.
    const pieces = try testPieces(a, &.{ "<f0>", ",", "<f1>", ",", "<f2>", ",", "<f3>" }, &.{ "x", "x", "x", "x" });
    const line = "," ** 14;
    var visits: usize = 0;
    try testing.expectEqual(@as(usize, 364), (try rowSplits(a, pieces, line, 1000, &visits)).?.len);
    const limit = 8;
    visits = 0;
    try testing.expect(try rowSplits(a, pieces, line, limit, &visits) == null);
    try testing.expect(visits <= (limit + 1) * (pieces.len + 1));
    const fields = try pieceFields(a, pieces);
    try expectManual("live line splits into row fields more than one way", try chooseSplit(a, pieces, fields, line));
}

test "chooseSplit: two splits with the same least changed fields are manual" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pieces = try testPieces(a, &.{ "<a>", " ", "<b>", " ", "<c>" }, &.{ "x", "y", "z" });
    const fields = try pieceFields(a, pieces);
    try expectManual("live line splits into row fields more than one way", try chooseSplit(a, pieces, fields, "p y y q"));
}

test "chooseSplit: one field captured twice with different texts is manual" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pieces = try testPieces(a, &.{ "<a>", ":", "<a>" }, &.{ "p", "p" });
    const fields = try pieceFields(a, pieces);
    try expectManual("field captured twice with different values", try chooseSplit(a, pieces, fields, "x:p"));
}

test "valueSplice: replaces a value's whole lines, keeping its key, spacing and comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "[[t]]\nkey  =  'old'   # note\nlong = \"\"\"\nline one\nline two\"\"\" # tail\nnext = 1\n";
    const stmts = try toml_statements.scan(a, src);
    const row = toml_statements.arrayTableRow(stmts, "t", 0).?;
    const key = try valueSplice(a, "p", src, row.body[0], "\"new\"");
    const long = try valueSplice(a, "p", src, row.body[1], "\"x\"");
    try testing.expectEqualStrings("[[t]]\nkey  =  \"new\"   # note\nlong = \"x\" # tail\nnext = 1\n", try splicedContent(a, src, &.{ key, long }));
    try testing.expectEqual(@as(u32, 3), long.del);
}

test "basicString: escapes backslashes, quotes and control characters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("\"a\\\\b \\\"q\\\" \\t\\u0001\"", try basicString(arena.allocator(), "a\\b \"q\" \t\x01"));
}

test "LoopFile.liveLineAt: a matched line, a line inside a one-for-one hunk, and none" {
    const hunks = [_]Hunk{
        .{ .a_start = 1, .a_len = 1, .b_start = 1, .b_len = 1 },
        .{ .a_start = 3, .a_len = 0, .b_start = 3, .b_len = 2 },
        .{ .a_start = 4, .a_len = 2, .b_start = 6, .b_len = 2 },
        .{ .a_start = 6, .a_len = 1, .b_start = 8, .b_len = 0 },
    };
    const b_lines = [_][]const u8{ "l0", "L1", "l2", "i0", "i1", "l3", "L4", "L5", "l7" };
    const lf: LoopFile = .{ .file = undefined, .stored = true, .segments = &.{}, .a_lines = &.{}, .b_lines = &b_lines, .hunks = &hunks };
    try testing.expectEqualStrings("l0", lf.liveLineAt(0, false).?);
    try testing.expectEqualStrings("L1", lf.liveLineAt(1, false).?);
    try testing.expectEqualStrings("l3", lf.liveLineAt(3, false).?);
    try testing.expect(lf.liveLineAt(4, false) == null);
    try testing.expectEqualStrings("L5", lf.liveLineAt(5, true).?);
    try testing.expect(lf.liveLineAt(6, true) == null);
    try testing.expectEqualStrings("l7", lf.liveLineAt(7, false).?);
}

test "replaceTokens: renames only complete-token occurrences, not superstrings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The coupled token appears standalone AND as the prefix of a longer token
    // (`coupledtoken_extra` is one token because `_` is a token char).
    const got = try replaceTokens(arena.allocator(), "value = coupledtoken\nother = coupledtoken_extra\n", &.{.{ .path = "", .old = "coupledtoken", .new = "newtoken" }});

    // Only the standalone token is renamed; the superstring is left intact.
    try testing.expectEqualStrings("value = newtoken\nother = coupledtoken_extra\n", got);
}

/// One configuration with the given label and bindings, for the tests below.
fn testConfig(a: std.mem.Allocator, label: []const u8, pairs: []const [2][]const u8, is_this: bool) !Configuration {
    var b = std.StringHashMap([]const u8).init(a);
    for (pairs) |p| try b.put(p[0], p[1]);
    return .{ .label = label, .bindings = b, .is_this_machine = is_this };
}

test "configsMatchingAxis: scopes a narrowing to the siblings sharing its axis value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // This machine is os=darwin+profile=personal; the other three configurations
    // are its siblings in the {os} x {profile} space.
    const configs = [_]Configuration{
        try testConfig(a, "", &.{ .{ "os", "darwin" }, .{ "profile", "personal" } }, true),
        try testConfig(a, "os=darwin+profile=work", &.{ .{ "os", "darwin" }, .{ "profile", "work" } }, false),
        try testConfig(a, "os=linux+profile=personal", &.{ .{ "os", "linux" }, .{ "profile", "personal" } }, false),
        try testConfig(a, "os=linux+profile=work", &.{ .{ "os", "linux" }, .{ "profile", "work" } }, false),
    };

    // Narrowing to os=darwin may change exactly the OTHER darwin configuration:
    // never this machine (which is not a sibling to verify against), and never a
    // linux one -- naming either would let a real divergence through the guard.
    const darwin = try configsMatchingAxis(a, &configs, "os", "darwin");
    try testing.expectEqual(@as(usize, 1), darwin.len);
    try testing.expectEqualStrings("os=darwin+profile=work", darwin[0]);

    // Narrowing to profile=personal reaches the other personal configuration only.
    const personal = try configsMatchingAxis(a, &configs, "profile", "personal");
    try testing.expectEqual(@as(usize, 1), personal.len);
    try testing.expectEqualStrings("os=linux+profile=personal", personal[0]);
}

test "configsMatchingAxis: a value no sibling holds, and an axis a config lacks, allow nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const configs = [_]Configuration{
        try testConfig(a, "", &.{.{ "os", "darwin" }}, true),
        // A sibling that does not bind `profile` at all (the axis is unset there).
        try testConfig(a, "os=linux", &.{.{ "os", "linux" }}, false),
    };

    // No sibling is os=darwin: a machine-only narrowing may change nothing.
    try testing.expectEqual(@as(usize, 0), (try configsMatchingAxis(a, &configs, "os", "darwin")).len);
    // The sibling has no `profile` binding, so it is not swept in by a
    // profile narrowing (which would silently license a change to it).
    try testing.expectEqual(@as(usize, 0), (try configsMatchingAxis(a, &configs, "profile", "personal")).len);
}

test "resolveCoupling: an occurrence in a protected source is skipped, never offered" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const edited = try std.fs.path.join(a, &.{ base, "edited" });
    const protected_src = try std.fs.path.join(a, &.{ base, "seed" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edited, .data = "old@example.com\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = protected_src, .data = "old@example.com seed\n" });

    const coupling_dir = try std.fs.path.join(a, &.{ base, "coupling" });
    var g = mox.coupling.graph.Graph.init(a);
    try g.addOccurrence("old@example.com", protected_src, 0, 15);
    try mox.coupling.store.saveGraph(a, io, coupling_dir, &g);

    const edit = LineEdit{ .path = edited, .start = 0, .del = 1, .new_lines = &.{"new@example.com"} };
    // "Y" would ACCEPT the update if the occurrence were ever offered.
    var reader = Io.Reader.fixed("Y\n");
    var out_aw: Io.Writer.Allocating = .init(a);
    var protected = std.StringHashMap(void).init(a);
    try protected.put(protected_src, {});

    const bases: []const []const u8 = &.{protected_src};
    var test_ids: PathIds = .init(a, io);
    const accepted: AcceptedTexts = .init(a, &test_ids);
    var err_aw: Io.Writer.Allocating = .init(a);
    const res = try resolveCoupling(a, io, coupling_dir, &.{edit}, &.{0}, &accepted, bases, &protected, .interactive, &reader, &out_aw.writer, &err_aw.writer);

    // Skipped before the prompt: no edit, no announcement, no abort. Without
    // the skip, "Y" would have queued an edit for the protected source.
    try testing.expectEqual(@as(usize, 0), res.edits.len);
    try testing.expect(!res.abort);
    try testing.expect(std.mem.indexOf(u8, out_aw.written(), "update") == null);
}

test "resolveCoupling: a private-origin rename never couples into a shared source" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    // The edited file is a PRIVATE-layer source; the shared repo source holds
    // the same token and is NOT protected (not a symlink/seed source).
    const private_src = try std.fs.path.join(a, &.{ base, "private" });
    const shared_src = try std.fs.path.join(a, &.{ base, "shared" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = private_src, .data = "old@example.com\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = shared_src, .data = "old@example.com base\n" });

    const coupling_dir = try std.fs.path.join(a, &.{ base, "coupling" });
    var g = mox.coupling.graph.Graph.init(a);
    try g.addOccurrence("old@example.com", shared_src, 0, 15);
    try mox.coupling.store.saveGraph(a, io, coupling_dir, &g);

    const edit = LineEdit{ .path = private_src, .start = 0, .del = 1, .new_lines = &.{"new@example.com"}, .private = true };
    // "Y" would ACCEPT the sync into the shared source if it were ever offered:
    // this is the private->shared leak the skip must prevent.
    var reader = Io.Reader.fixed("Y\n");
    var out_aw: Io.Writer.Allocating = .init(a);
    var no_protected = std.StringHashMap(void).init(a);

    const bases: []const []const u8 = &.{shared_src};
    var test_ids: PathIds = .init(a, io);
    const accepted: AcceptedTexts = .init(a, &test_ids);
    var err_aw: Io.Writer.Allocating = .init(a);
    const res = try resolveCoupling(a, io, coupling_dir, &.{edit}, &.{0}, &accepted, bases, &no_protected, .interactive, &reader, &out_aw.writer, &err_aw.writer);

    // Skipped before any prompt: no edit into the shared source, no announcement.
    try testing.expectEqual(@as(usize, 0), res.edits.len);
    try testing.expect(!res.abort);
    try testing.expect(std.mem.indexOf(u8, out_aw.written(), "update") == null);
    // And the read-only reporter must likewise offer nothing.
    var report_protected = std.StringHashMap(void).init(a);
    var report_aw: Io.Writer.Allocating = .init(a);
    const reported = try reportCoupling(a, io, coupling_dir, &.{edit}, &accepted, bases, &report_protected, &report_aw.writer, &err_aw.writer);
    try testing.expectEqual(@as(usize, 0), reported);
}

test "routeHunk: a private-only base file's edit is flagged private by location" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const private_dir = try std.fs.path.join(a, &.{ base, "private" });
    const src_abs = try std.fs.path.join(a, &.{ private_dir, ".token" });
    try Io.Dir.cwd().createDirPath(io, private_dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = src_abs, .data = "key = old\n" });

    // A private-only whole file composes as `.base` origin, yet its source lives
    // under the private root -- the route must still mark it private.
    const file: mox.source.tree.ManagedFile = .{
        .source_base_path = ".token",
        .source_base_abs = src_abs,
        .live_path = try std.fs.path.join(a, &.{ base, "home", ".token" }),
        .has_base = true,
        .overlays = &.{},
        .regions = &.{},
        .private_dir = private_dir,
    };
    var segs = [_]mox.provenance.map.Segment{.{ .out_start = 0, .out_len = 1, .origin = .{ .base = .{ .line = 1 } } }};
    const hunk: mox.diff.lines.Hunk = .{ .a_start = 0, .a_len = 1, .b_start = 0, .b_len = 1 };
    const a_lines = [_][]const u8{"key = old"};
    const b_lines = [_][]const u8{"key = new"};

    const m_state: mox.machine.state.MachineState = .{
        .os = "linux",
        .arch = "x86_64",
        .hostname = "h",
        .username = "u",
        .home = "/home/u",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };
    var lf: LoopFile = .{ .file = file, .stored = true, .segments = &segs, .a_lines = &a_lines, .b_lines = &b_lines, .hunks = &.{hunk} };
    const route = try routeHunk(try testClassCtx(a, io, &m_state), &lf, hunk);
    try testing.expect(route == .line);
    try testing.expect(route.line.edit.private);
}

test "routeHunk: a base file in a sibling directory whose name extends the private root is not flagged private" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const private_dir = try std.fs.path.join(a, &.{ base, "private" });
    const sibling_dir = try std.fs.path.join(a, &.{ base, "private-backup" });
    const src_abs = try std.fs.path.join(a, &.{ sibling_dir, ".token" });
    try Io.Dir.cwd().createDirPath(io, private_dir);
    try Io.Dir.cwd().createDirPath(io, sibling_dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = src_abs, .data = "key = old\n" });

    const file: mox.source.tree.ManagedFile = .{
        .source_base_path = ".token",
        .source_base_abs = src_abs,
        .live_path = try std.fs.path.join(a, &.{ base, "home", ".token" }),
        .has_base = true,
        .overlays = &.{},
        .regions = &.{},
        .private_dir = private_dir,
    };
    var segs = [_]mox.provenance.map.Segment{.{ .out_start = 0, .out_len = 1, .origin = .{ .base = .{ .line = 1 } } }};
    const hunk: mox.diff.lines.Hunk = .{ .a_start = 0, .a_len = 1, .b_start = 0, .b_len = 1 };
    const a_lines = [_][]const u8{"key = old"};
    const b_lines = [_][]const u8{"key = new"};

    const m_state: mox.machine.state.MachineState = .{
        .os = "linux",
        .arch = "x86_64",
        .hostname = "h",
        .username = "u",
        .home = "/home/u",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };
    var lf: LoopFile = .{ .file = file, .stored = true, .segments = &segs, .a_lines = &a_lines, .b_lines = &b_lines, .hunks = &.{hunk} };
    const route = try routeHunk(try testClassCtx(a, io, &m_state), &lf, hunk);
    try testing.expect(route == .line);
    try testing.expect(!route.line.edit.private);
}

/// A routing context over `m_state` with no bindings, secrets or input.
fn testClassCtx(a: std.mem.Allocator, io: Io, m_state: *const mox.machine.state.MachineState) !*const ClassCtx {
    const bindings = try a.create(std.StringHashMap([]const u8));
    bindings.* = .init(a);
    const live = try a.create(mox.dsl.resolver.Resolver.Live);
    live.* = .{ .bindings = bindings };
    const resolver = try a.create(mox.dsl.resolver.Resolver);
    resolver.* = .{ .live = live };
    const secret_map = try a.create(std.process.Environ.Map);
    secret_map.* = .init(a);
    const secret_cache = try a.create(mox.secret.cache.Cache);
    secret_cache.* = .init(a);
    const out = try a.create(Io.Writer.Allocating);
    out.* = .init(a);
    const reader = try a.create(Io.Reader);
    reader.* = Io.Reader.fixed("");
    const claims = try a.create(Claims);
    claims.* = .empty;
    const cc = try a.create(ClassCtx);
    cc.* = .{
        .arena = a,
        .io = io,
        .this_bindings = bindings,
        .resolver = resolver,
        .m_state = m_state,
        .secrets = .{ .env = mox.env.Env{ .map = secret_map }, .cache = secret_cache },
        .machine = mox.machine.bindings.firstLabel(m_state.hostname),
        .stdout = &out.writer,
        .err = &out.writer,
        .input = reader,
        .ask_mode = .assume_default,
        .report_mode = false,
        .interactive = false,
        .sty = .{ .on = false },
        .claims = claims,
    };
    return cc;
}

test "resolveCoupling: a q-abort after a decline persists no decline" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One routed rename (old@example.com -> new@example.com) whose old token
    // still lives in TWO other managed sources, so it yields two coupling
    // prompts. The user declines the first (d) then quits (q).
    const cwd = try std.process.currentPathAlloc(io, a);
    const base = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const edited = try std.fs.path.join(a, &.{ base, "edited" });
    const other1 = try std.fs.path.join(a, &.{ base, "other1" });
    const other2 = try std.fs.path.join(a, &.{ base, "other2" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edited, .data = "old@example.com\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = other1, .data = "old@example.com signing\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = other2, .data = "old@example.com allowed\n" });

    const coupling_dir = try std.fs.path.join(a, &.{ base, "coupling" });
    var g = mox.coupling.graph.Graph.init(a);
    try g.addOccurrence("old@example.com", other1, 0, 15);
    try g.addOccurrence("old@example.com", other2, 0, 15);
    try mox.coupling.store.saveGraph(a, io, coupling_dir, &g);

    const edit = LineEdit{ .path = edited, .start = 0, .del = 1, .new_lines = &.{"new@example.com"} };
    var reader = Io.Reader.fixed("d\nq\n");
    var out_aw: Io.Writer.Allocating = .init(a);
    var no_protected = std.StringHashMap(void).init(a);

    const bases: []const []const u8 = &.{ other1, other2 };
    var test_ids: PathIds = .init(a, io);
    const accepted: AcceptedTexts = .init(a, &test_ids);
    var err_aw: Io.Writer.Allocating = .init(a);
    const res = try resolveCoupling(a, io, coupling_dir, &.{edit}, &.{0}, &accepted, bases, &no_protected, .interactive, &reader, &out_aw.writer, &err_aw.writer);

    // The user quit at the second prompt: the command aborts.
    try testing.expect(res.abort);
    // A decline WAS entered on the first prompt...
    try testing.expect(res.declines.isPairDeclined("old@example.com", edited, other1));
    // ...but because the whole command aborted, nothing may persist: the
    // caller saves the decline list only when save_declines is set.
    try testing.expect(!res.save_declines);
    // No coupling edit was accepted either.
    try testing.expectEqual(@as(usize, 0), res.edits.len);
}

var coupling_restore_fail_target: []const u8 = "";
var coupling_restore_fail_calls: usize = 0;
var coupling_restore_fail_on: usize = 0;
var coupling_restore_fail_real: *const fn (?*anyopaque, Io.Dir, []const u8, Io.Dir.CreateFileOptions) Io.File.OpenError!Io.File = undefined;

fn couplingRestoreFailingCreateFile(userdata: ?*anyopaque, dir: Io.Dir, sub_path: []const u8, opts: Io.Dir.CreateFileOptions) Io.File.OpenError!Io.File {
    if (std.mem.eql(u8, sub_path, coupling_restore_fail_target)) {
        coupling_restore_fail_calls += 1;
        if (coupling_restore_fail_calls == coupling_restore_fail_on) return error.AccessDenied;
    }
    return coupling_restore_fail_real(userdata, dir, sub_path, opts);
}

const CouplingSimRun = struct { result: anyerror!CouplingSim, err: []const u8, path: []const u8, fixture: []const u8, now: []const u8 };

/// `simulateCouplingImpact` over a one-file tree whose rename makes this
/// machine's configuration unable to compose, with the `fail_on`-th create
/// of the source failing (0: none), reading `read_path` instead of the
/// source when given.
fn runCouplingSim(a: std.mem.Allocator, tmp: *std.testing.TmpDir, fail_on: usize, read_path: ?[]const u8) !CouplingSimRun {
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "src");
    // The coupled token sits with token-boundary whitespace around it (an
    // adjoining '=' is itself a token char) so the coupling rename actually
    // replaces it. Post-rename, the axis value carries '@', which the DSL
    // lexer rejects for every configuration -- including this machine's own.
    const fixture = "common\n# mox: when profile= sharedtok\ngated\n# mox: end\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.zshrc", .data = fixture });
    const cwd = try std.process.currentPathAlloc(io, a);
    const src_dir = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "src" });

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    try testing.expectEqual(@as(usize, 1), tree.files.len);
    const file = tree.files[0];
    const path = file.source_base_abs;

    const bindings = try a.create(std.StringHashMap([]const u8));
    bindings.* = .init(a);
    try bindings.put("profile", "personal");
    const configs = try a.dupe(Configuration, &.{.{ .label = "", .bindings = bindings.*, .is_this_machine = true }});

    const m_state = try a.create(mox.machine.state.MachineState);
    m_state.* = .{
        .os = "linux",
        .arch = "x86_64",
        .hostname = "test",
        .username = "tester",
        .home = "/home/me",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };
    const secret_map = try a.create(std.process.Environ.Map);
    secret_map.* = .init(a);
    const secret_cache = try a.create(mox.secret.cache.Cache);
    secret_cache.* = .init(a);

    coupling_restore_fail_target = path;
    coupling_restore_fail_calls = 0;
    coupling_restore_fail_on = fail_on;
    coupling_restore_fail_real = io.vtable.dirCreateFile;
    const vtable = try a.create(Io.VTable);
    vtable.* = io.vtable.*;
    vtable.dirCreateFile = couplingRestoreFailingCreateFile;
    const faulty: Io = .{ .userdata = io.userdata, .vtable = vtable };

    const out_aw = try a.create(Io.Writer.Allocating);
    out_aw.* = .init(a);
    const err_aw = try a.create(Io.Writer.Allocating);
    err_aw.* = .init(a);
    const reader = try a.create(Io.Reader);
    reader.* = Io.Reader.fixed("");
    const claims = try a.create(Claims);
    claims.* = .empty;
    const live = try a.create(mox.dsl.resolver.Resolver.Live);
    live.* = .{ .bindings = bindings };
    const axis_resolver = try a.create(mox.dsl.resolver.Resolver);
    axis_resolver.* = .{ .live = live };
    const cc: ClassCtx = .{
        .arena = a,
        .io = faulty,
        .this_bindings = bindings,
        .resolver = axis_resolver,
        .m_state = m_state,
        .secrets = .{ .env = mox.env.Env{ .map = secret_map }, .cache = secret_cache },
        .machine = mox.machine.bindings.firstLabel(m_state.hostname),
        .stdout = &out_aw.writer,
        .err = &err_aw.writer,
        .input = reader,
        .ask_mode = .assume_default,
        .report_mode = false,
        .interactive = false,
        .sty = .{ .on = false },
        .claims = claims,
    };

    const file_edits = &[_]CouplingEdit{.{ .path = path, .old = "sharedtok", .new = "sharedtok@bad" }};
    const result = simulateCouplingImpact(&cc, file, read_path orelse path, file_edits, configs);
    coupling_restore_fail_target = "";
    return .{
        .result = result,
        .err = err_aw.writer.buffered(),
        .path = path,
        .fixture = fixture,
        .now = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)),
    };
}

test "simulateCouplingImpact: a failed post-simulation restore reports the un-restored path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The first create of the source, the edited-content write, lands; the
    // second, its restore, fails.
    const r = try runCouplingSim(arena.allocator(), &tmp, 2, null);
    try testing.expectError(error.UnexpectedCharacter, r.result);
    try testing.expect(std.mem.indexOf(u8, r.err, r.path) != null);
}

test "simulateCouplingImpact: a failed transient write is a target that cannot take the rename, reverted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try runCouplingSim(arena.allocator(), &tmp, 1, null);
    try testing.expectEqual(error.AccessDenied, (try r.result).unwritable);
    try testing.expectEqualStrings("", r.err);
    try testing.expectEqualStrings(r.fixture, r.now);
}

test "simulateCouplingImpact: a target that cannot be read cannot take the rename" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A directory stands in for a source that cannot be read.
    try tmp.dir.createDirPath(std.testing.io, "src");
    const r = try runCouplingSim(a, &tmp, 0, try tmp.dir.realPathFileAlloc(std.testing.io, "src", a));
    try testing.expectEqual(error.IsDir, (try r.result).unwritable);
    try testing.expectEqualStrings(r.fixture, r.now);
}

test "composesTo: literal tags must match exactly, expanded captures stand for any text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(try composesTo(a, "</b></a>", "</b></a>"));
    try std.testing.expect(!try composesTo(a, "<br>", "anything"));
    try std.testing.expect(try composesTo(a, "export P=<machine.profile>", "export P=work"));
    try std.testing.expect(!try composesTo(a, "export P=<machine.profile>", "export Q=work"));
    try std.testing.expect(try composesTo(a, "<C-h> <machine.key>;", "<C-h> x;"));
    try std.testing.expect(!try composesTo(a, "<C-h> <machine.key>;", "<C-j> x;"));
    try std.testing.expect(try composesTo(a, "p=\"<machine.x | default \"a>b\">\"", "p=\"a>b\""));
    try std.testing.expect(try composesTo(a, "<env.A>-<env.B>", "1-2"));
    try std.testing.expect(!try composesTo(a, "<env.A><env.B>", "12"));
    try std.testing.expect(!try composesTo(a, "ab<env.A>ba", "aba"));
    try std.testing.expect(try composesTo(a, "id = Me <<machine.os>>", "id = Me <darwin>"));
    try std.testing.expect(try composesTo(a, "if a<b; echo <machine.os>", "if a<b; echo darwin"));
    try std.testing.expect(!try composesTo(a, "echo <foo | default \"x\">", "echo hi"));
    try std.testing.expect(!try composesTo(a, "a <b | c> d", "a Z d"));
    try std.testing.expect(!try composesTo(a, "a <env.X | b> d", "a Z d"));
    try std.testing.expect(try composesTo(a, "a <env.X | machine.y> d", "a Z d"));
}

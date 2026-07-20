const std = @import("std");
const source = @import("../source/root.zig");
const category = @import("category.zig");
const catA = @import("catA.zig");
const catB = @import("catB.zig");
const catC = @import("catC.zig");
const interp = @import("interp.zig");
const machine = @import("../machine/root.zig");
const prov_mod = @import("../provenance/root.zig");

const Io = std.Io;
const ManagedFile = source.tree.ManagedFile;
const Segment = prov_mod.map.Segment;

const peek_limit: usize = 4096;
const peek_max_read: usize = 1024 * 1024;

/// Top-level compose: dispatch by category. Returns null if the file
/// should not be materialized (e.g. whole-file when_gate evaluated false
/// in Cat B).
pub fn composeFile(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
) !?[]u8 {
    return composeFileTracked(arena, io, file, bindings, machine_state_opt, secrets, null, null);
}

/// Like `composeFile`, but records line provenance into `prov` when non-null.
/// Cat B attributes each output run to its source; a directive-bearing Cat A
/// single layer routes through Cat B and inherits the same per-line
/// attribution; every other Cat A route and all of Cat C get one whole-file
/// segment (structural / binary line attribution is out of scope), origin
/// `.base` for a single-layer file and `.overlay` when overlays exist, or
/// `.secret` when a resolved secret was inlined.
///
/// `diag`, when non-null, receives the failing capture's text on a Cat A/B
/// resolution error, so the caller can name which capture failed.
pub fn composeFileTracked(
    arena: std.mem.Allocator,
    io: Io,
    file: ManagedFile,
    bindings: *const std.StringHashMap([]const u8),
    machine_state_opt: ?*const machine.state.MachineState,
    secrets: ?catB.SecretCtx,
    prov: ?*std.ArrayList(Segment),
    diag: ?*interp.Diag,
) !?[]u8 {
    // Sniff a sample of the base (or first overlay) to detect category.
    const sample_path: ?[]const u8 = if (file.has_base)
        file.source_base_abs
    else if (file.overlays.len > 0)
        file.overlays[0].path
    else
        null;

    if (sample_path == null) return null;

    const sample = try peekFile(io, arena, sample_path.?);

    const cat = category.detect(file.source_base_path, sample);

    switch (cat) {
        // Cat A owns its own provenance: per-line (via Cat B) for a
        // directive-bearing single layer, whole-file otherwise, `.secret` when
        // a resolved secret was inlined.
        .a => return try catA.compose(arena, io, file, bindings, machine_state_opt, secrets, prov, diag),
        .b => return try catB.composeTracked(arena, io, file, bindings, machine_state_opt, secrets, prov, diag),
        .c => {
            const bytes = (try catC.compose(arena, io, file, bindings, machine_state_opt)) orelse return null;
            try wholeFileSegment(arena, prov, bytes, file);
            return bytes;
        },
    }
}

/// Attribute the whole of `bytes` to a single segment for a Cat C file.
fn wholeFileSegment(arena: std.mem.Allocator, prov: ?*std.ArrayList(Segment), bytes: []const u8, file: ManagedFile) !void {
    const p = prov orelse return;
    const n = prov_mod.map.lineCount(bytes);
    if (n == 0) return;
    const origin: prov_mod.map.Origin = if (file.has_base and file.overlays.len == 0)
        .{ .base = .{ .line = 1 } }
    else
        .{ .overlay = .{ .path = if (file.source_base_abs.len > 0) file.source_base_abs else file.source_base_path } };
    try p.append(arena, .{ .out_start = 0, .out_len = n, .origin = origin });
}

/// Read enough of `path` to sniff the file category. Opens the file and
/// reads only `peek_limit` bytes — large binary files (icons, fonts, etc.)
/// can be tens of MB and we don't want to load them just to detect Cat C.
/// Memory is owned by `arena`.
fn peekFile(io: Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const buf = try arena.alloc(u8, peek_limit);
    var reader_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buf);
    const n = try reader.interface.readSliceShort(buf);
    return buf[0..n];
}

const std = @import("std");

/// The trigger state file's name under the state directory.
pub const state_basename = "triggers.txt";

/// Where a setup script's trigger records wait while it runs, under the state
/// directory. `mox apply` names it to each script it runs in `pending_env`.
pub const pending_basename = "triggers.pending";

/// Set by `mox apply` for the scripts it runs. A trigger check under it reads
/// the run's pending records and writes there, not to the state file, so a
/// script's checks count only once apply sees it exit 0 (`settlePending`).
pub const pending_env = "MOX_TRIGGER_PENDING";

/// Load for a check. With `pending_path` set, the check reads the records a
/// run has pending when there are any and the saved state otherwise, and its
/// save writes to `pending_path`.
pub fn loadForCheck(arena: std.mem.Allocator, io: std.Io, state_path: []const u8, pending_path: ?[]const u8) !State {
    const pending = pending_path orelse return State.loadOrEmpty(arena, io, state_path);
    const has_pending = if (std.Io.Dir.cwd().access(io, pending, .{})) |_| true else |e| switch (e) {
        error.FileNotFound => false,
        else => return e,
    };
    var s = try State.loadOrEmpty(arena, io, if (has_pending) pending else state_path);
    s.path = pending;
    return s;
}

/// End a script run's trigger records: kept, they replace the state file;
/// otherwise they are dropped. A run that recorded nothing leaves no pending
/// file, and either way the state file is untouched.
pub fn settlePending(io: std.Io, state_path: []const u8, pending_path: []const u8, keep: bool) !void {
    if (keep) {
        std.Io.Dir.rename(std.Io.Dir.cwd(), pending_path, std.Io.Dir.cwd(), state_path, io) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    } else {
        std.Io.Dir.cwd().deleteFile(io, pending_path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }
}

/// Persistent state used by trigger predicates so scripts can opt out of
/// expensive work.
///
/// Stores three independent indexes:
/// * `seen_versions`: keys checked once and remembered
/// * `file_hashes`: SHA-256 of files at last successful check
/// * `every_timestamps`: Unix-seconds of the last "true" return per key
///
/// Wire format is one record per line: `<namespace>:<key>=<value>`.
/// Namespaces: `seen` (value empty), `hash` (hex digest), `every` (i64).
pub const State = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    seen_versions: std.StringHashMap(void),
    file_hashes: std.StringHashMap([]const u8),
    every_timestamps: std.StringHashMap(i64),
    dirty: bool,

    const max_state_bytes: usize = 4 * 1024 * 1024;

    pub fn loadOrEmpty(arena: std.mem.Allocator, io: std.Io, path: []const u8) !State {
        var s = State{
            .arena = arena,
            .io = io,
            .path = path,
            .seen_versions = std.StringHashMap(void).init(arena),
            .file_hashes = std.StringHashMap([]const u8).init(arena),
            .every_timestamps = std.StringHashMap(i64).init(arena),
            .dirty = false,
        };

        const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_state_bytes)) catch |e| switch (e) {
            error.FileNotFound => return s,
            else => return e,
        };

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            // Namespace is up to the FIRST ':'; the key/value split is the LAST
            // '='. A key (a file path) may contain both ':' and '='; a value
            // (empty / hex digest / integer) never contains '=', so this parses
            // such keys unambiguously.
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const eq = std.mem.lastIndexOfScalar(u8, line, '=') orelse continue;
            if (eq < colon) continue;
            const namespace = line[0..colon];
            const key = line[colon + 1 .. eq];
            const value = line[eq + 1 ..];

            if (std.mem.eql(u8, namespace, "seen")) {
                try s.seen_versions.put(try arena.dupe(u8, key), {});
            } else if (std.mem.eql(u8, namespace, "hash")) {
                try s.file_hashes.put(try arena.dupe(u8, key), try arena.dupe(u8, value));
            } else if (std.mem.eql(u8, namespace, "every")) {
                const ts = std.fmt.parseInt(i64, value, 10) catch continue;
                try s.every_timestamps.put(try arena.dupe(u8, key), ts);
            }
        }
        return s;
    }

    /// A key must not contain the wire-format delimiter (a newline), or saving
    /// it would inject a spurious record. Keys with a newline are refused.
    fn keyIsWireSafe(key: []const u8) bool {
        return std.mem.indexOfScalar(u8, key, '\n') == null and
            std.mem.indexOfScalar(u8, key, '\r') == null;
    }

    /// Returns true the first time `key` is seen, false thereafter.
    pub fn checkSeenVersion(self: *State, arena: std.mem.Allocator, key: []const u8) !bool {
        if (!keyIsWireSafe(key)) return error.InvalidTriggerKey;
        if (self.seen_versions.contains(key)) return false;
        try self.seen_versions.put(try arena.dupe(u8, key), {});
        self.dirty = true;
        return true;
    }

    /// Returns true if any file in `paths` has a content hash differing
    /// from the last recorded hash. Missing files are skipped.
    pub fn checkHash(self: *State, arena: std.mem.Allocator, paths: []const []const u8) !bool {
        var any_changed = false;
        for (paths) |p| {
            if (!keyIsWireSafe(p)) return error.InvalidTriggerKey;
            // Hash by streaming so an arbitrarily large tracked file neither
            // buffers into memory nor hard-errors the whole check.
            var file = std.Io.Dir.cwd().openFile(self.io, p, .{}) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => return e,
            };
            defer file.close(self.io);
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            var reader_buf: [64 * 1024]u8 = undefined;
            var reader = file.reader(self.io, &reader_buf);
            var chunk: [64 * 1024]u8 = undefined;
            while (true) {
                const n = try reader.interface.readSliceShort(&chunk);
                if (n == 0) break;
                hasher.update(chunk[0..n]);
            }
            var hash_bytes: [32]u8 = undefined;
            hasher.final(&hash_bytes);
            const hex_arr = std.fmt.bytesToHex(hash_bytes, .lower);
            const hex = try arena.dupe(u8, &hex_arr);

            const existing = self.file_hashes.get(p);
            if (existing == null or !std.mem.eql(u8, existing.?, hex)) {
                try self.file_hashes.put(try arena.dupe(u8, p), hex);
                self.dirty = true;
                any_changed = true;
            }
        }
        return any_changed;
    }

    /// Returns true if `interval_secs` have elapsed since the last "true"
    /// return for `key`. Updates the recorded timestamp on true.
    pub fn checkEvery(self: *State, arena: std.mem.Allocator, key: []const u8, interval_secs: i64) !bool {
        if (!keyIsWireSafe(key)) return error.InvalidTriggerKey;
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        const last = self.every_timestamps.get(key) orelse 0;
        if (now - last < interval_secs) return false;
        try self.every_timestamps.put(try arena.dupe(u8, key), now);
        self.dirty = true;
        return true;
    }

    pub fn save(self: *State) !void {
        if (!self.dirty) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.arena);

        var seen_iter = self.seen_versions.keyIterator();
        while (seen_iter.next()) |k| {
            try buf.appendSlice(self.arena, "seen:");
            try buf.appendSlice(self.arena, k.*);
            try buf.append(self.arena, '=');
            try buf.append(self.arena, '\n');
        }

        var hash_iter = self.file_hashes.iterator();
        while (hash_iter.next()) |e| {
            try buf.appendSlice(self.arena, "hash:");
            try buf.appendSlice(self.arena, e.key_ptr.*);
            try buf.append(self.arena, '=');
            try buf.appendSlice(self.arena, e.value_ptr.*);
            try buf.append(self.arena, '\n');
        }

        var every_iter = self.every_timestamps.iterator();
        while (every_iter.next()) |e| {
            const line = try std.fmt.allocPrint(self.arena, "every:{s}={d}\n", .{ e.key_ptr.*, e.value_ptr.* });
            try buf.appendSlice(self.arena, line);
        }

        if (std.fs.path.dirname(self.path)) |parent| {
            std.Io.Dir.cwd().createDirPath(self.io, parent) catch {};
        }

        // Write to a sidecar then rename, so a concurrent invocation or a crash
        // mid-write cannot tear the state file and lose a run-once record.
        const tmp = try std.fmt.allocPrint(self.arena, "{s}.tmp", .{self.path});
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = tmp, .data = buf.items });
        try std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), self.path, self.io);
        self.dirty = false;
    }
};

fn testPaths(arena: std.mem.Allocator, tmp: *std.testing.TmpDir) !struct { state: []const u8, pending: []const u8 } {
    const cwd = try std.process.currentPathAlloc(std.testing.io, arena);
    const dir = try std.fs.path.join(arena, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    return .{
        .state = try std.fs.path.join(arena, &.{ dir, state_basename }),
        .pending = try std.fs.path.join(arena, &.{ dir, pending_basename }),
    };
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch return false;
    return true;
}

test "loadForCheck: with no pending path a check saves straight to the state file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try testPaths(a, &tmp);

    var s = try loadForCheck(a, std.testing.io, p.state, null);
    try std.testing.expect(try s.checkSeenVersion(a, "k"));
    try s.save();
    try std.testing.expect(exists(p.state));
    try std.testing.expect(!exists(p.pending));
}

test "loadForCheck: under a pending path a check reads the state file but saves only to the pending file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try testPaths(a, &tmp);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = p.state, .data = "seen:old=\n" });

    var s = try loadForCheck(a, std.testing.io, p.state, p.pending);
    try std.testing.expect(!try s.checkSeenVersion(a, "old"));
    try std.testing.expect(try s.checkSeenVersion(a, "new"));
    try s.save();

    const state_after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, p.state, a, .limited(1024));
    try std.testing.expectEqualStrings("seen:old=\n", state_after);
    var again = try loadForCheck(a, std.testing.io, p.state, p.pending);
    try std.testing.expect(!try again.checkSeenVersion(a, "new"));
    try std.testing.expect(!try again.checkSeenVersion(a, "old"));
}

test "settlePending: kept records replace the state file; dropped ones leave it as it was" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try testPaths(a, &tmp);
    const io = std.testing.io;

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p.state, .data = "seen:old=\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p.pending, .data = "seen:old=\nseen:new=\n" });
    try settlePending(io, p.state, p.pending, false);
    try std.testing.expect(!exists(p.pending));
    try std.testing.expectEqualStrings("seen:old=\n", try std.Io.Dir.cwd().readFileAlloc(io, p.state, a, .limited(1024)));

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p.pending, .data = "seen:old=\nseen:new=\n" });
    try settlePending(io, p.state, p.pending, true);
    try std.testing.expect(!exists(p.pending));
    try std.testing.expectEqualStrings("seen:old=\nseen:new=\n", try std.Io.Dir.cwd().readFileAlloc(io, p.state, a, .limited(1024)));
}

test "settlePending: a run that recorded nothing is a no-op either way" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try testPaths(a, &tmp);
    const io = std.testing.io;

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p.state, .data = "seen:old=\n" });
    try settlePending(io, p.state, p.pending, true);
    try settlePending(io, p.state, p.pending, false);
    try std.testing.expectEqualStrings("seen:old=\n", try std.Io.Dir.cwd().readFileAlloc(io, p.state, a, .limited(1024)));
}

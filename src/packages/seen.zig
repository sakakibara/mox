//! What each machine was seen holding, of the packages declared for it.
//!
//! A package the user uninstalled on purpose and one this machine never had
//! both read as not installed. The record tells them apart: per backend and
//! per machine, the ids mox has seen installed while they were desired. A
//! desired id that is in the record, not installed, and not on the machine
//! in any form was had here and lost, and apply does not install it again.
//!
//! The record is machine-local state, in `<state>/seen/<backend>-<owner>.txt`:
//!
//!     mox-seen 1
//!     <id>
//!     <id>
//!
//! The owner names the machine, so machines sharing a state directory (an
//! NFS home, a toolbox sharing `$HOME`) each keep their own record and never
//! write over one another's. Two environments sharing one machine identity
//! share a record too.

const std = @import("std");
const builtin = @import("builtin");

const apply_write = @import("../apply/write.zig");
const backend = @import("backend.zig");
const exec = @import("exec.zig");

const Io = std.Io;
const EnvironMap = std.process.Environ.Map;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The directory under the state directory the records live in.
pub const dir_name = "seen";

/// The first line of every record this mox writes and reads.
pub const header = "mox-seen 1";

/// How many hex digits of the identity's hash name the machine.
pub const owner_len = 16;

/// The most a record may be; past it the file is not one mox wrote.
const max_record_bytes: usize = 4 << 20;

/// This machine's identity, as the OS keeps it.
pub const Identity = union(enum) {
    /// The identity; empty where the OS has none, which is as stable as
    /// one, so a container without a machine-id keeps its record.
    known: []const u8,
    /// The source exists but could not be read: why. No record is in effect
    /// and none is written, since an owner guessed here could name another
    /// machine's record.
    failed: []const u8,
};

/// The owner a record of `identity` is filed under: the first `owner_len`
/// lowercase hex digits of its sha256.
pub fn ownerOf(identity: []const u8) [owner_len]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(identity, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return hex[0..owner_len].*;
}

/// This machine's identity, read from the source of the OS mox runs on.
/// `runner` runs the macOS and Windows queries; `env` supplies `SystemRoot`
/// on Windows. An OS with no identity source has the empty identity.
pub fn readIdentity(arena: std.mem.Allocator, io: Io, runner: exec.Runner, env: ?*const EnvironMap) !Identity {
    return switch (builtin.os.tag) {
        .linux => linuxIdentity(arena, io, &linux_identity_paths),
        .macos => macIdentity(arena, runner),
        .windows => windowsIdentity(arena, runner, env),
        else => .{ .known = "" },
    };
}

/// Where Linux keeps the machine id, in the order they are tried: systemd's,
/// then the D-Bus copy a system without systemd may keep.
pub const linux_identity_paths = [_][]const u8{ "/etc/machine-id", "/var/lib/dbus/machine-id" };

/// The first of `paths` that holds an id. A file that is absent, empty, or
/// holds `uninitialized` (systemd's first-boot placeholder, under which it
/// uses a transient id) holds none; when no file does, the identity is
/// empty. A file that exists but cannot be read is a failed read.
pub fn linuxIdentity(arena: std.mem.Allocator, io: Io, paths: []const []const u8) !Identity {
    for (paths) |p| {
        const bytes = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(4096)) catch |e| switch (e) {
            error.FileNotFound => continue,
            error.OutOfMemory => return e,
            else => return .{ .failed = try std.fmt.allocPrint(arena, "{s} could not be read ({s})", .{ p, @errorName(e) }) },
        };
        const id = std.mem.trim(u8, bytes, " \t\r\n");
        if (id.len == 0 or std.mem.eql(u8, id, "uninitialized")) continue;
        return .{ .known = id };
    }
    return .{ .known = "" };
}

/// By absolute path, so launchd's minimal PATH does not matter.
pub const ioreg_argv = [_][]const u8{ "/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice" };

/// `IOPlatformUUID` as ioreg reports it. Every Mac has one, so an answer
/// without it is a failed read, not a machine without an identity.
pub fn macIdentity(arena: std.mem.Allocator, runner: exec.Runner) !Identity {
    const res = switch (try query(arena, runner, &ioreg_argv)) {
        .out => |out| out,
        .failed => |why| return .{ .failed = why },
    };
    var it = std.mem.splitScalar(u8, res, '\n');
    while (it.next()) |line| {
        const key = std.mem.indexOf(u8, line, "\"IOPlatformUUID\"") orelse continue;
        const rest = line[key + "\"IOPlatformUUID\"".len ..];
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        const value = std.mem.trim(u8, rest[eq + 1 ..], " \t\r");
        if (value.len < 3 or value[0] != '"' or value[value.len - 1] != '"') continue;
        return .{ .known = value[1 .. value.len - 1] };
    }
    return .{ .failed = try std.fmt.allocPrint(arena, "{s} reported no IOPlatformUUID", .{ioreg_argv[0]}) };
}

/// `MachineGuid` as reg.exe reports it, reg.exe named under `SystemRoot`
/// rather than found on PATH. Every Windows install has one, so an answer
/// without it, or no `SystemRoot` to find reg.exe under, is a failed read.
pub fn windowsIdentity(arena: std.mem.Allocator, runner: exec.Runner, env: ?*const EnvironMap) !Identity {
    const root = blk: {
        const m = env orelse break :blk "";
        break :blk std.mem.trim(u8, m.get("SystemRoot") orelse "", " \t\r\n");
    };
    if (root.len == 0) return .{ .failed = "SystemRoot is not set, so reg.exe cannot be found" };
    const reg = try std.fmt.allocPrint(arena, "{s}\\System32\\reg.exe", .{std.mem.trimEnd(u8, root, "\\")});
    const argv = [_][]const u8{ reg, "query", "HKLM\\SOFTWARE\\Microsoft\\Cryptography", "/v", "MachineGuid" };
    const res = switch (try query(arena, runner, &argv)) {
        .out => |out| out,
        .failed => |why| return .{ .failed = why },
    };
    var it = std.mem.splitScalar(u8, res, '\n');
    while (it.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = words.next() orelse continue;
        if (!std.ascii.eqlIgnoreCase(name, "MachineGuid")) continue;
        const kind = words.next() orelse continue;
        if (!std.mem.eql(u8, kind, "REG_SZ")) continue;
        const value = words.next() orelse continue;
        return .{ .known = value };
    }
    return .{ .failed = try std.fmt.allocPrint(arena, "{s} reported no MachineGuid", .{reg}) };
}

const Query = union(enum) {
    out: []const u8,
    failed: []const u8,
};

/// The stdout of `argv`, or why there is none: it could not be spawned, it
/// ran past its bound, or it exited nonzero.
fn query(arena: std.mem.Allocator, runner: exec.Runner, argv: []const []const u8) !Query {
    const res = runner.run(arena, argv) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failed = try std.fmt.allocPrint(arena, "{s} could not be run: {s}", .{ argv[0], exec.errorText(e) }) };
    };
    if (res.timed_out) return .{ .failed = try std.fmt.allocPrint(arena, "{s} {s}", .{ argv[0], exec.errorText(error.TimedOut) }) };
    if (!res.ok) return .{ .failed = try std.fmt.allocPrint(arena, "{s} exited {d}", .{ argv[0], res.code }) };
    return .{ .out = res.stdout };
}

/// What a record says.
pub const Read = union(enum) {
    /// No record: this machine has not been seen holding anything through
    /// the backend, or held nothing when it was last written.
    absent,
    /// The ids recorded, in the order the file holds them.
    ids: []const []const u8,
    /// A record mox cannot read: why. The next write replaces it.
    unusable: []const u8,
    /// A record whose header is not this mox's: the header line. It is
    /// neither read nor written, so a newer mox's data is never lost.
    newer: []const u8,
};

/// The path of the record of `backend_name` for `owner` under `state_dir`.
pub fn path(arena: std.mem.Allocator, state_dir: []const u8, backend_name: []const u8, owner: []const u8) ![]const u8 {
    const file = try std.fmt.allocPrint(arena, "{s}-{s}.txt", .{ backend_name, owner });
    return std.fs.path.join(arena, &.{ state_dir, dir_name, file });
}

/// The record of `backend_name` for `owner`. An error is a record that is
/// there but could not be read at all; the caller leaves that backend's
/// record out of effect rather than treating it as absent, which would
/// forget every uninstall it holds.
pub fn read(arena: std.mem.Allocator, io: Io, state_dir: []const u8, backend_name: []const u8, owner: []const u8) !Read {
    const p = try path(arena, state_dir, backend_name, owner);
    const bytes = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(max_record_bytes)) catch |e| switch (e) {
        error.FileNotFound => return .absent,
        error.StreamTooLong => return .{ .unusable = "it is larger than any record mox writes" },
        else => return e,
    };
    return parse(arena, bytes);
}

/// The record held in `bytes`: the header line, then one id per line,
/// each newline-terminated, distinct, and of an id's shape.
fn parse(arena: std.mem.Allocator, bytes: []const u8) !Read {
    if (bytes.len == 0) return .{ .unusable = "it is empty" };
    const first = bytes[0 .. std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len];
    if (!std.mem.eql(u8, first, header)) return .{ .newer = first };
    if (bytes[bytes.len - 1] != '\n') return .{ .unusable = "its last line is not newline-terminated" };

    if (first.len + 1 == bytes.len) return .{ .ids = &.{} };

    var out: std.ArrayList([]const u8) = .empty;
    var distinct: std.StringHashMapUnmanaged(void) = .empty;
    var it = std.mem.splitScalar(u8, bytes[first.len + 1 .. bytes.len - 1], '\n');
    var line_no: usize = 1;
    while (it.next()) |id| {
        line_no += 1;
        if (!backend.idShapeOk(id)) return .{ .unusable = try std.fmt.allocPrint(arena, "line {d} is not a package id", .{line_no}) };
        if ((try distinct.fetchPut(arena, id, {})) != null) return .{ .unusable = try std.fmt.allocPrint(arena, "line {d} repeats {s}", .{ line_no, id }) };
        try out.append(arena, id);
    }
    return .{ .ids = try out.toOwnedSlice(arena) };
}

pub const Error = error{
    /// The record there was written by a newer mox, and is left as it is.
    NewerRecord,
    /// An id that a record could not hold and read back.
    InvalidId,
};

/// Make the record of `backend_name` for `owner` hold exactly `ids`, sorted
/// and without repeats. An empty set removes the record. Atomic: a record
/// that vanished mid-write would forget every uninstall it held. A record a
/// newer mox wrote is never written over.
pub fn replace(arena: std.mem.Allocator, io: Io, state_dir: []const u8, backend_name: []const u8, owner: []const u8, ids: []const []const u8) !void {
    switch (try read(arena, io, state_dir, backend_name, owner)) {
        .newer => return Error.NewerRecord,
        .absent, .ids, .unusable => {},
    }
    const p = try path(arena, state_dir, backend_name, owner);

    const sorted = try arena.dupe([]const u8, ids);
    std.mem.sort([]const u8, sorted, {}, lessThan);
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, header ++ "\n");
    var prev: ?[]const u8 = null;
    for (sorted) |id| {
        if (!backend.idShapeOk(id)) return Error.InvalidId;
        if (prev) |q| if (std.mem.eql(u8, q, id)) continue;
        prev = id;
        try buf.appendSlice(arena, id);
        try buf.append(arena, '\n');
    }

    if (prev == null) {
        Io.Dir.cwd().deleteFile(io, p) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        return;
    }
    try apply_write.writeAtomic(io, p, buf.items, 0o644);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;

fn tmpState(a: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    return std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(testing.io, ".", a), "state" });
}

test "ownerOf: the first 16 lowercase hex digits of the identity's sha256, the empty identity included" {
    try testing.expectEqualStrings("e3b0c44298fc1c14", &ownerOf(""));
    try testing.expectEqualStrings("2c26b46b68ffc68f", &ownerOf("foo"));
}

test "replace then read: ids round-trip, sorted and without repeats, under the header" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state = try tmpState(a, &tmp);
    const owner = ownerOf("machine-a");

    try testing.expect(try read(a, io, state, "brew", &owner) == .absent);
    try replace(a, io, state, "brew", &owner, &.{ "ripgrep", "fd", "ripgrep", "homebrew/cask/firefox" });
    const got = try read(a, io, state, "brew", &owner);
    try testing.expectEqual(@as(usize, 3), got.ids.len);
    try testing.expectEqualStrings("fd", got.ids[0]);
    try testing.expectEqualStrings("homebrew/cask/firefox", got.ids[1]);
    try testing.expectEqualStrings("ripgrep", got.ids[2]);

    const p = try path(a, state, "brew", &owner);
    try testing.expect(std.mem.endsWith(u8, p, try std.fmt.allocPrint(a, "seen{c}brew-{s}.txt", .{ std.fs.path.sep, &owner })));
    const text = try Io.Dir.cwd().readFileAlloc(io, p, a, .limited(4096));
    try testing.expectEqualStrings("mox-seen 1\nfd\nhomebrew/cask/firefox\nripgrep\n", text);
}

test "read: another owner's record is another file, absent to this one; another backend's likewise" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state = try tmpState(a, &tmp);
    const mine = ownerOf("machine-a");
    const theirs = ownerOf("machine-b");

    try replace(a, io, state, "brew", &theirs, &.{"ripgrep"});
    try testing.expect(!std.mem.eql(u8, try path(a, state, "brew", &mine), try path(a, state, "brew", &theirs)));
    try testing.expect(try read(a, io, state, "brew", &mine) == .absent);
    try testing.expect(try read(a, io, state, "apt", &theirs) == .absent);

    try replace(a, io, state, "brew", &mine, &.{"fd"});
    try testing.expectEqualStrings("ripgrep", (try read(a, io, state, "brew", &theirs)).ids[0]);
    try testing.expectEqualStrings("fd", (try read(a, io, state, "brew", &mine)).ids[0]);
}

test "replace: an empty set removes the record, and is no error when there is none" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state = try tmpState(a, &tmp);
    const owner = ownerOf("machine-a");

    try replace(a, io, state, "apt", &owner, &.{});
    try replace(a, io, state, "apt", &owner, &.{"ripgrep"});
    try replace(a, io, state, "apt", &owner, &.{});
    try testing.expect(try read(a, io, state, "apt", &owner) == .absent);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, try path(a, state, "apt", &owner), .{}));
}

test "read and replace: a record under another header is a newer mox's, never read and never written over" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state = try tmpState(a, &tmp);
    const owner = ownerOf("machine-a");
    const p = try path(a, state, "brew", &owner);
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(p).?);

    for ([_][]const u8{ "mox-seen 2\nripgrep\n", "mox-seen 2", "mox-seen 1 \nfd\n" }) |text| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text });
        const got = try read(a, io, state, "brew", &owner);
        try testing.expectEqualStrings(text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], got.newer);
        try testing.expectError(Error.NewerRecord, replace(a, io, state, "brew", &owner, &.{"fd"}));
        try testing.expectError(Error.NewerRecord, replace(a, io, state, "brew", &owner, &.{}));
        try testing.expectEqualStrings(text, try Io.Dir.cwd().readFileAlloc(io, p, a, .limited(4096)));
    }
}

test "read: a broken record is unusable, saying why, and the next replace writes over it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state = try tmpState(a, &tmp);
    const owner = ownerOf("machine-a");
    const p = try path(a, state, "pacman", &owner);
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(p).?);

    const cases = [_]struct { text: []const u8, why: []const u8 }{
        .{ .text = "", .why = "it is empty" },
        .{ .text = "mox-seen 1\nfd", .why = "its last line is not newline-terminated" },
        .{ .text = "mox-seen 1\nfd\n\nripgrep\n", .why = "line 3 is not a package id" },
        .{ .text = "mox-seen 1\nmy notes\n", .why = "line 2 is not a package id" },
        .{ .text = "mox-seen 1\nfd\r\n", .why = "line 2 is not a package id" },
        .{ .text = "mox-seen 1\nfd\nbat\nfd\n", .why = "line 4 repeats fd" },
    };
    for (cases) |c| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = c.text });
        try testing.expectEqualStrings(c.why, (try read(a, io, state, "pacman", &owner)).unusable);
    }
    try replace(a, io, state, "pacman", &owner, &.{"bat"});
    try testing.expectEqualStrings("bat", (try read(a, io, state, "pacman", &owner)).ids[0]);
}

test "read: a header with no ids after it reads as an empty set" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state = try tmpState(a, &tmp);
    const owner = ownerOf("machine-a");
    const p = try path(a, state, "dnf", &owner);
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(p).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "mox-seen 1\n" });
    try testing.expectEqual(@as(usize, 0), (try read(a, io, state, "dnf", &owner)).ids.len);
}

test "replace: an id a record could not read back is refused, and nothing is written" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state = try tmpState(a, &tmp);
    const owner = ownerOf("machine-a");
    try testing.expectError(Error.InvalidId, replace(a, io, state, "apt", &owner, &.{ "fd", "two words" }));
    try testing.expect(try read(a, io, state, "apt", &owner) == .absent);
}

test "linuxIdentity: the first file holding an id; absent, empty and uninitialized files hold none, and none at all is the empty identity" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const etc = try std.fs.path.join(a, &.{ root, "machine-id" });
    const dbus = try std.fs.path.join(a, &.{ root, "dbus-machine-id" });
    const paths = [_][]const u8{ etc, dbus };

    try testing.expectEqualStrings("", (try linuxIdentity(a, io, &paths)).known);
    try tmp.dir.writeFile(io, .{ .sub_path = "dbus-machine-id", .data = "d0d0d0\n" });
    try testing.expectEqualStrings("d0d0d0", (try linuxIdentity(a, io, &paths)).known);
    for ([_][]const u8{ "", "\n", "uninitialized\n" }) |text| {
        try tmp.dir.writeFile(io, .{ .sub_path = "machine-id", .data = text });
        try testing.expectEqualStrings("d0d0d0", (try linuxIdentity(a, io, &paths)).known);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "machine-id", .data = "e7e7e7\n" });
    try testing.expectEqualStrings("e7e7e7", (try linuxIdentity(a, io, &paths)).known);
    try tmp.dir.deleteFile(io, "dbus-machine-id");
    try tmp.dir.writeFile(io, .{ .sub_path = "machine-id", .data = "uninitialized\n" });
    try testing.expectEqualStrings("", (try linuxIdentity(a, io, &paths)).known);
}

test "linuxIdentity: a machine-id that is there but cannot be read is a failed read, not the empty identity" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "machine-id");
    const etc = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(io, ".", a), "machine-id" });
    const got = try linuxIdentity(a, io, &.{etc});
    try testing.expect(std.mem.indexOf(u8, got.failed, "could not be read") != null);
}

const ioreg_line = "/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice";

test "macIdentity: IOPlatformUUID from ioreg, run by absolute path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{.{ .argv = ioreg_line, .stdout = 
        \\+-o J316sAP  <class IOPlatformExpertDevice, id 0x100000213, registered, matched, active, busy 0 (0 ms), retain 39>
        \\  {
        \\    "IOPlatformSerialNumber" = "XYZ123"
        \\    "IOPlatformUUID" = "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"
        \\  }
        \\
    }} };
    try testing.expectEqualStrings("0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", (try macIdentity(a, fake.runner())).known);
}

test "macIdentity: a spawn failure, a timeout, a nonzero exit or an answer without the UUID is a failed read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]exec.Fake.Entry{
        .{ .argv = ioreg_line, .fail = error.FileNotFound },
        .{ .argv = ioreg_line, .timed_out = true },
        .{ .argv = ioreg_line, .code = 1, .stdout = "    \"IOPlatformUUID\" = \"0A1B\"\n" },
        .{ .argv = ioreg_line, .stdout = "    \"IOPlatformSerialNumber\" = \"XYZ123\"\n" },
        .{ .argv = ioreg_line, .stdout = "" },
    };
    for (cases) |c| {
        var fake: exec.Fake = .{ .arena = a, .entries = &.{c} };
        const got = try macIdentity(a, fake.runner());
        try testing.expect(got == .failed);
        try testing.expect(std.mem.startsWith(u8, got.failed, "/usr/sbin/ioreg"));
    }
}

const reg_line = "C:\\Windows\\System32\\reg.exe query HKLM\\SOFTWARE\\Microsoft\\Cryptography /v MachineGuid";

fn windowsEnv(a: std.mem.Allocator, root: ?[]const u8) !EnvironMap {
    var m = EnvironMap.init(a);
    if (root) |r| try m.put("SystemRoot", r);
    return m;
}

test "windowsIdentity: MachineGuid from reg.exe under SystemRoot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: exec.Fake = .{ .arena = a, .entries = &.{.{ .argv = reg_line, .stdout = "\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n    MachineGuid    REG_SZ    6f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0\r\n\r\n" }} };
    for ([_][]const u8{ "C:\\Windows", "C:\\Windows\\" }) |root| {
        var env = try windowsEnv(a, root);
        try testing.expectEqualStrings("6f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", (try windowsIdentity(a, fake.runner(), &env)).known);
    }
}

test "windowsIdentity: no SystemRoot, a spawn failure, a timeout, a nonzero exit or an answer without the value is a failed read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var fake: exec.Fake = .{ .arena = a, .entries = &.{} };
        var env = try windowsEnv(a, null);
        try testing.expect(try windowsIdentity(a, fake.runner(), &env) == .failed);
        try testing.expect(try windowsIdentity(a, fake.runner(), null) == .failed);
        try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    }
    const cases = [_]exec.Fake.Entry{
        .{ .argv = reg_line, .fail = error.FileNotFound },
        .{ .argv = reg_line, .timed_out = true },
        .{ .argv = reg_line, .code = 1, .stdout = "    MachineGuid    REG_SZ    6f1e\r\n" },
        .{ .argv = reg_line, .stdout = "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n" },
        .{ .argv = reg_line, .stdout = "    MachineGuid    REG_SZ\r\n" },
    };
    for (cases) |c| {
        var fake: exec.Fake = .{ .arena = a, .entries = &.{c} };
        var env = try windowsEnv(a, "C:\\Windows");
        const got = try windowsIdentity(a, fake.runner(), &env);
        try testing.expect(got == .failed);
        try testing.expect(std.mem.startsWith(u8, got.failed, "C:\\Windows\\System32\\reg.exe"));
    }
}

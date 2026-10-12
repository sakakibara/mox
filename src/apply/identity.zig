//! What makes two paths one file: device and inode, or on Windows the
//! volume serial number and file id. Every hard link to a file has it, and
//! two files on different devices never share it.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// What makes two paths one file: its device and inode, or on Windows its
/// volume serial number and 128-bit file id. Every hard link to a file has it.
pub const Identity = struct { device: u64, inode: u128 };

/// Whether a symlink at the path itself is identified, or what it names.
pub const Follow = enum { follow, no_follow };

/// The identity of the existing entry at `path`, or null when it cannot be
/// read for any reason (an absent file, a refused open, no call the system
/// allows). POSIX reads it without opening the file, so a FIFO never blocks;
/// Windows opens it, following a link whatever `follow` says.
pub fn of(io: Io, path: []const u8, follow: Follow) ?Identity {
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
            const flags: u32 = if (follow == .follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
            switch (linux.errno(linux.statx(linux.AT.FDCWD, &z, flags, .{ .INO = true }, &stx))) {
                .SUCCESS => return .{ .device = (@as(u64, stx.dev_major) << 32) | stx.dev_minor, .inode = stx.ino },
                // statx refused by a seccomp filter or missing from the kernel.
                .NOSYS, .PERM => return linuxStatIdentity(&z, flags),
                else => return null,
            }
        },
        else => {
            const z = std.posix.toPosixPath(path) catch return null;
            var st: std.c.Stat = undefined;
            if (std.c.fstatat(std.c.AT.FDCWD, &z, &st, if (follow == .follow) 0 else std.c.AT.SYMLINK_NOFOLLOW) != 0) return null;
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
fn windowsFileId(handle: std.os.windows.HANDLE) ?Identity {
    const windows = std.os.windows;
    var info: WindowsFileIdInfo = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    if (windows.ntdll.NtQueryInformationFile(handle, &iosb, &info, @sizeOf(WindowsFileIdInfo), .Id) != .SUCCESS) return null;
    return .{ .device = info.VolumeSerialNumber, .inode = std.mem.readInt(u128, &info.FileId, .little) };
}

/// A file's identity from its volume's 32-bit serial number and its 64-bit
/// index, where no 128-bit id is available.
fn windowsIndexIdentity(io: Io, file: Io.File) ?Identity {
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
fn linuxStatIdentity(z: [*:0]const u8, flags: u32) ?Identity {
    const linux = std.os.linux;
    switch (builtin.cpu.arch) {
        .x86_64, .aarch64, .aarch64_be, .riscv64, .loongarch64, .powerpc64, .powerpc64le, .s390x => {},
        else => return null,
    }
    // Larger than any of those targets' `struct stat`.
    var buf: [256]u8 align(8) = undefined;
    const rc = linux.syscall4(.fstatat64, @as(usize, @bitCast(@as(isize, linux.AT.FDCWD))), @intFromPtr(z), @intFromPtr(&buf), flags);
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

test "linuxDevice: a kernel dev_t splits into statx's major and minor halves" {
    try std.testing.expectEqual((@as(u64, 8) << 32) | 1, linuxDevice(0x801));
    // Major 259, minor 300: the minor's high bits sit above the major's.
    try std.testing.expectEqual((@as(u64, 259) << 32) | 300, linuxDevice(44 | (259 << 8) | (256 << 12)));
}

test "of: the fstatat fallback reads the identity statx does" {
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
    const via_statx = of(io, path, .follow) orelse return error.SkipZigTest;
    try std.testing.expectEqual(via_statx, linuxStatIdentity(&z, 0).?);
}

const std = @import("std");
const builtin = @import("builtin");

/// True when the given POSIX fd number (0 stdin, 1 stdout, 2 stderr) is an
/// interactive terminal. POSIX uses `isatty`; Windows maps the fd to its
/// standard handle and probes it with `GetConsoleMode`, which succeeds only
/// for a real console.
pub fn isInteractive(fd: c_int) bool {
    if (builtin.os.tag == .windows) {
        const params = std.os.windows.peb().ProcessParameters;
        const handle = switch (fd) {
            0 => params.hStdInput,
            1 => params.hStdOutput,
            2 => params.hStdError,
            else => return false,
        };
        var mode: std.os.windows.DWORD = undefined;
        return win.GetConsoleMode(handle, &mode).toBool();
    }
    return std.c.isatty(@intCast(fd)) != 0;
}

// Wrapped in a struct so the winapi extern is analyzed only when referenced,
// i.e. only on the Windows build; a top-level winapi decl would be rejected
// on POSIX targets.
const win = struct {
    extern "kernel32" fn GetConsoleMode(
        hConsoleHandle: std.os.windows.HANDLE,
        lpMode: *std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;
};

test "isInteractive is callable for a standard fd" {
    // A test runner's stdin is typically not a console; assert the call
    // returns without panicking rather than a specific value.
    _ = isInteractive(0);
}

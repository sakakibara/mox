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

    const COORD = extern struct { X: std.os.windows.SHORT, Y: std.os.windows.SHORT };
    const SMALL_RECT = extern struct {
        Left: std.os.windows.SHORT,
        Top: std.os.windows.SHORT,
        Right: std.os.windows.SHORT,
        Bottom: std.os.windows.SHORT,
    };
    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: COORD,
        dwCursorPosition: COORD,
        wAttributes: std.os.windows.WORD,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: COORD,
    };
    extern "kernel32" fn GetConsoleScreenBufferInfo(
        hConsoleOutput: std.os.windows.HANDLE,
        lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
    ) callconv(.winapi) std.os.windows.BOOL;
};

/// Best-effort stdout column count: the terminal's own report when stdout is
/// a real console, `fallback` otherwise (piped, redirected, or the query
/// itself fails). Never blocks and never errors -- a report that cannot
/// learn the real width degrades to the fallback instead of failing.
pub fn terminalWidth(fallback: usize) usize {
    if (!isInteractive(1)) return fallback;
    if (builtin.os.tag == .windows) {
        var info: win.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        const handle = std.os.windows.peb().ProcessParameters.hStdOutput;
        if (!win.GetConsoleScreenBufferInfo(handle, &info).toBool()) return fallback;
        const cols = @as(isize, info.srWindow.Right) - @as(isize, info.srWindow.Left) + 1;
        return if (cols > 0) @intCast(cols) else fallback;
    }
    var ws: std.posix.winsize = undefined;
    if (std.c.ioctl(1, std.c.T.IOCGWINSZ, &ws) != 0) return fallback;
    return if (ws.col > 0) ws.col else fallback;
}

test "isInteractive is callable for a standard fd" {
    // A test runner's stdin is typically not a console; assert the call
    // returns without panicking rather than a specific value.
    _ = isInteractive(0);
}

test "terminalWidth: falls back when stdout is not a console (the test runner's pipe)" {
    try std.testing.expectEqual(@as(usize, 80), terminalWidth(80));
}

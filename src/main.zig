const std = @import("std");
const Io = std.Io;
const mox = @import("mox");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const argv_z = try init.minimal.args.toSlice(arena);
    const argv = try arena.alloc([]const u8, argv_z.len);
    for (argv_z, 0..) |a, i| argv[i] = a;

    const exit_code = mox.cli.app.run(arena, io, argv, &mox.cli.app.command_table, stdout, stderr) catch |e| {
        try stderr.print("mox: internal error: {s}\n", .{@errorName(e)});
        try stdout.flush();
        try stderr.flush();
        return 1;
    };

    try stdout.flush();
    try stderr.flush();
    return exit_code;
}

test "main module compiles" {
    try std.testing.expect(true);
}

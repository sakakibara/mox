const std = @import("std");
const Io = std.Io;
const mox = @import("mox");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    // Streaming, not positional: a positional writer starts at byte 0, so
    // `mox status >> log` would overwrite the log instead of appending.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const argv_z = try init.minimal.args.toSlice(arena);
    const argv = try arena.alloc([]const u8, argv_z.len);
    for (argv_z, 0..) |a, i| argv[i] = a;

    const exit_code = mox.cli.app.run(arena, io, argv, &mox.cli.app.command_table, stdout, stderr) catch |e| {
        try stderr.print("mox: internal error: {s}\n", .{@errorName(e)});
        try stdout.flush();
        try stderr.flush();
        return 2;
    };

    try stdout.flush();
    try stderr.flush();
    return exit_code;
}

test "main: the entry point has the shape the process expects, over a non-empty command table" {
    const info = @typeInfo(@TypeOf(main)).@"fn";
    try std.testing.expectEqual(std.process.Init, info.params[0].type.?);
    try std.testing.expectEqual(u8, @typeInfo(info.return_type.?).error_union.payload);
    try std.testing.expect(mox.cli.app.command_table.len > 0);
}

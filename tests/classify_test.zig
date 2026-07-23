const std = @import("std");
const mox = @import("mox");

const Io = std.Io;

/// A file whose `machine` region's fragment is named for a dotted hostname, in
/// a file that also gates on `os`.
fn writeDottedMachineTree(io: Io, tmp: *std.testing.TmpDir) !void {
    try tmp.dir.createDirPath(io, "src/.zshrc.d/machine");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.zshrc", .data = "export A=1\n" ++
        "# mox: replace from \"machine\"\n" ++
        "export EDITOR=vim\n" ++
        "# mox: end\n" ++
        "# mox: when os=darwin\n" ++
        "export BREW=1\n" ++
        "# mox: end\n" ++
        "# mox: when os=linux\n" ++
        "export APT=1\n" ++
        "# mox: end\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.zshrc.d/machine/host.local", .data = "export EDITOR=nvim\n" });
}

test "config space: a dotted fragment value yields no phantom sibling machine" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try writeDottedMachineTree(io, &tmp);
    const cwd = try std.process.currentPathAlloc(io, a);
    const src_dir = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "src" });

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    const ax = try mox.source.axes.ofFile(a, io, tree.files[0]);

    var this = std.StringHashMap([]const u8).init(a);
    try this.put("os", "darwin");
    try this.put("machine", "host.local");

    const configs = try mox.classify.config_space.enumerate(a, &this, ax, &.{}, &.{});

    // `host.local` IS this machine, not a second one: the `machine` axis has a
    // single value, so the space is exactly {this machine, os=linux}. Reading
    // `.local` as an extension would invent a `machine=host` sibling that
    // composes identically to this machine and taints every impact notice.
    try std.testing.expectEqual(@as(usize, 2), configs.len);
    for (configs) |c| {
        try std.testing.expect(std.mem.indexOf(u8, c.label, "machine=") == null);
        // A configuration that is not this machine IS another machine: it can
        // never carry this machine's hostname, or a region gated "only here"
        // would resolve there too.
        if (c.is_this_machine) {
            try std.testing.expectEqualStrings("host.local", c.bindings.get("machine").?);
        } else {
            try std.testing.expect(c.bindings.get("machine") == null);
        }
    }
}

test "config space: an extension-bearing fragment value is still read by its stem" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try tmp.dir.createDirPath(io, "src/.zshrc.d/os");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.zshrc", .data = "export A=1\n" ++
        "# mox: replace from \"os\"\n" ++
        "export PLATFORM=other\n" ++
        "# mox: end\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.zshrc.d/os/darwin.sh", .data = "export PLATFORM=darwin\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.zshrc.d/os/linux.sh", .data = "export PLATFORM=linux\n" });

    const cwd = try std.process.currentPathAlloc(io, a);
    const src_dir = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "src" });

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    const ax = try mox.source.axes.ofFile(a, io, tree.files[0]);

    var this = std.StringHashMap([]const u8).init(a);
    try this.put("os", "darwin");

    const configs = try mox.classify.config_space.enumerate(a, &this, ax, &.{}, &.{});

    // {os=darwin (this machine), os=linux} -- the `.sh` is an extension here, so
    // it must not enter the space as part of the value.
    try std.testing.expectEqual(@as(usize, 2), configs.len);
    var saw_linux = false;
    for (configs) |c| {
        if (std.mem.eql(u8, c.label, "os=linux")) saw_linux = true;
        try std.testing.expect(std.mem.indexOf(u8, c.label, ".sh") == null);
    }
    try std.testing.expect(saw_linux);
}

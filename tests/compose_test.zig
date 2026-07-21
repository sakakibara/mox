const std = @import("std");
const Env = @import("mox").env.Env;
const mox = @import("mox");

const Io = std.Io;

fn writeFile(io: Io, dir: Io.Dir, sub: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub)) |parent| {
        try dir.createDirPath(io, parent);
    }
    try dir.writeFile(io, .{ .sub_path = sub, .data = content });
}

/// Build the absolute path to `<tmp>/src` using `tmp.parent_dir` to compute the
/// canonical `<cwd>/.zig-cache/tmp/<sub_path>` location.
fn srcPathAlloc(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const io = std.testing.io;
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    return std.fs.path.join(allocator, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path, "src" });
}

test "compose catC: most specific overlay wins" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/icon.png", "BASE");
    try writeFile(io, tmp.dir, "src/icon.png.d/os=darwin.png", "DARWIN");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "darwin");

    const out = (try mox.compose.catC.compose(arena.allocator(), io, tree.files[0], &bindings, null)).?;
    try std.testing.expectEqualStrings("DARWIN", out);
}

test "compose catC: falls back to base when no overlay matches" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/icon.png", "BASE");
    try writeFile(io, tmp.dir, "src/icon.png.d/os=darwin.png", "DARWIN");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "linux");

    const out = (try mox.compose.catC.compose(arena.allocator(), io, tree.files[0], &bindings, null)).?;
    try std.testing.expectEqualStrings("BASE", out);
}

test "compose catC: an overlay named for a dotted value matches this machine's exact binding" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A `machine` value is a hostname, and every macOS hostname ends in
    // `.local`. The overlay filename carries no extension at all -- it IS the
    // literal value -- so the trailing `.local` must not be mistaken for one.
    try writeFile(io, tmp.dir, "src/icon.png", "BASE");
    try writeFile(io, tmp.dir, "src/icon.png.d/machine=host.local", "HOST_LOCAL");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("machine", "host.local");

    const out = (try mox.compose.catC.compose(arena.allocator(), io, tree.files[0], &bindings, null)).?;
    try std.testing.expectEqualStrings("HOST_LOCAL", out);
}

test "compose catC: an extension-bearing overlay still resolves by its stripped value alongside a dotted one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two overlays in the same directory: one whose trailing dot-suffix is a
    // real extension (`.png`, stripped to `darwin`) and one whose trailing
    // dot-suffix is part of the value itself (`host.local`, kept verbatim).
    // Each must resolve to what it stands for, and neither may steal the
    // other's match.
    try writeFile(io, tmp.dir, "src/icon.png", "BASE");
    try writeFile(io, tmp.dir, "src/icon.png.d/os=darwin.png", "DARWIN");
    try writeFile(io, tmp.dir, "src/icon.png.d/machine=host.local", "HOST_LOCAL");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "darwin");
    try bindings.put("machine", "other.example");

    const out = (try mox.compose.catC.compose(arena.allocator(), io, tree.files[0], &bindings, null)).?;
    try std.testing.expectEqualStrings("DARWIN", out);
}

test "compose catC: orphan with no matching overlay is absent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/aerospace/aerospace.png.d/os=darwin.png", "DARWIN");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "linux");

    const result = mox.compose.catC.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect((try result) == null);
}

test "compose catB: simple file with no directives passes through" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/.zshrc", "export EDITOR=nvim\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings("export EDITOR=nvim\n", out.?);
}

test "compose catB: include directive substitutes fragment when axis matches" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/.zshrc", "export EDITOR=nvim\n" ++
        "# mox: include \"extras/wsl.sh\" when env=WSL\n" ++
        "export PATH=$PATH\n");
    try writeFile(io, tmp.dir, "src/.zshrc.d/extras/wsl.sh", "# shellcheck disable=SC2154\n" ++
        "export WSLENV=USERPROFILE\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("env", "WSL");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "WSLENV=USERPROFILE") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "shellcheck") == null);
}

test "compose catB: include drops when axis doesn't match" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/.zshrc", "export EDITOR=nvim\n" ++
        "# mox: include \"extras/wsl.sh\" when env=WSL\n" ++
        "export PATH=$PATH\n");
    try writeFile(io, tmp.dir, "src/.zshrc.d/extras/wsl.sh", "");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "WSL") == null);
}

test "compose catB: replace from shorthand picks matching fragment" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/role.lua", "local M = {}\n" ++
        "-- mox: replace from \"profile\"\n" ++
        "M.kind = \"personal\"\n" ++
        "-- mox: end\n" ++
        "return M\n");
    try writeFile(io, tmp.dir, "src/role.lua.d/profile/work.lua", "---@diagnostic disable\n" ++
        "M.kind = \"work\"\n");
    try writeFile(io, tmp.dir, "src/role.lua.d/profile/personal.lua", "---@diagnostic disable\n" ++
        "M.kind = \"personal\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("profile", "work");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "M.kind = \"work\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "diagnostic") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "return M") != null);
}

test "compose catB: a fragment named exactly for a dotted axis value wins over a stripped extension" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Three fragments in one region: `host.local` is the whole value (a
    // hostname), `host` is a different machine entirely, and `host.sh` is a
    // third whose extension is stripped to reach that same `host`. The
    // filename that matches the binding OUTRIGHT is the one that resolves.
    try writeFile(io, tmp.dir, "src/.zshrc", "export A=1\n" ++
        "# mox: replace from \"machine\"\n" ++
        "export WHO=nobody\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.zshrc.d/machine/host.local", "export WHO=laptop\n");
    try writeFile(io, tmp.dir, "src/.zshrc.d/machine/host", "export WHO=desktop\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");

    var dotted = std.StringHashMap([]const u8).init(a);
    try dotted.put("machine", "host.local");
    const dotted_out = (try mox.compose.catB.compose(a, io, tree.files[0], &dotted, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, dotted_out, "export WHO=laptop") != null);

    // And the undotted machine still resolves its own fragment, not the dotted
    // one's stem.
    var plain = std.StringHashMap([]const u8).init(a);
    try plain.put("machine", "host");
    const plain_out = (try mox.compose.catB.compose(a, io, tree.files[0], &plain, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, plain_out, "export WHO=desktop") != null);

    // A machine named for neither falls back to the region's own body.
    var other = std.StringHashMap([]const u8).init(a);
    try other.put("machine", "elsewhere");
    const other_out = (try mox.compose.catB.compose(a, io, tree.files[0], &other, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, other_out, "export WHO=nobody") != null);
}

test "compose catB: when_gate at file start suppresses output when expr fails" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/darwin-only.sh", "# mox: when os=darwin\n" ++
        "alias hide='chflags hidden'\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "linux");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out == null);
}

test "compose catB: when_gate at file start emits content when expr matches" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/darwin-only.sh", "# mox: when os=darwin\n" ++
        "alias hide='chflags hidden'\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "darwin");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "alias hide") != null);
}

test "compose catB: scoped when...end on line 1 gates only its region, keeps trailing content" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A scoped `when ... end` whose opener is line 1, with content AFTER the
    // end marker. A false condition must drop only the gated region, never the
    // whole file (that would silently lose `always present line`).
    try writeFile(io, tmp.dir, "src/darwin-block.sh", "# mox: when os=darwin\n" ++
        "mac-only line\n" ++
        "# mox: end\n" ++
        "always present line\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "linux");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "always present line") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "mac-only line") == null);
}

test "compose catB: .psm1 gated on os=windows composes to nothing under darwin" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/AesEncrypt.psm1", "# mox: when os=windows\n" ++
        "function Protect-String { }\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "darwin");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out == null);
}

test "compose catB: .psm1 gated on os=windows composes its content under windows" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/AesEncrypt.psm1", "# mox: when os=windows\n" ++
        "function Protect-String { }\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "windows");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "function Protect-String") != null);
}

test "compose catB: .cmd gated with rem marker composes to nothing under darwin" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/setup.cmd", "rem mox: when os=windows\n" ++
        "echo hello\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "darwin");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out == null);
}

test "compose catB: .cmd gated with rem marker composes its content under windows" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/setup.cmd", "rem mox: when os=windows\n" ++
        "echo hello\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "windows");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "echo hello") != null);
}

test "compose catB: .bat gated with rem marker (scoped when...end)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/run.bat", "rem mox: when os=windows\n" ++
        "windows-only line\n" ++
        "rem mox: end\n" ++
        "always present line\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "linux");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "always present line") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "windows-only line") == null);
}

test "composeFile: dispatches Cat C for .png" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/icon.png", "BASE");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings("BASE", out.?);
}

test "composeFile: dispatches Cat B for .lua" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/role.lua", "local M = {}\nreturn M\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "local M") != null);
}

test "composeFile: dispatches Cat A toml and produces valid output" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/config.toml", "[user]\nname = \"foo\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "name = \"foo\"") != null);
}

test "composeFile: dispatches Cat A gitconfig with single layer pass-through" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/.gitconfig", "[user]\n\tname = foo\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings("[user]\n\tname = foo\n", out.?);
}

test "composeFile: Cat A gitconfig with overlays section-merges" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/.gitconfig", "[user]\n\tname = foo\n");
    try writeFile(io, tmp.dir, "src/.gitconfig.d/os=darwin.gitconfig", "[user]\n\tname = mac\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "darwin");

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings("[user]\n\tname = mac\n", out.?);
}

test "compose catB: Dockerfile (un-dotted basename) resolves comment marker" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/Dockerfile", "FROM alpine\n" ++
        "# mox: include \"build/setup.sh\" when env=X\n" ++
        "COPY . /app\n");
    try writeFile(io, tmp.dir, "src/Dockerfile.d/build/setup.sh", "RUN apk add curl\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("env", "X");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "RUN apk add curl") != null);
}

test "compose catB: fragment without trailing newline gets one added" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/.zshrc", "before\n" ++
        "# mox: include \"extras/frag.sh\" when env=X\n" ++
        "after\n");
    try writeFile(io, tmp.dir, "src/.zshrc.d/extras/frag.sh", "no newline at end");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("env", "X");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "no newline at end\nafter") != null);
}

test "compose catB: secret directive resolves env: scheme" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.gitconfig", "[user]\n" ++
        "# mox: secret \"env:MOX_TEST_SECRET\"\n" ++
        "name = test\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    var cache = mox.secret.cache.Cache.init(arena.allocator());

    var map = std.process.Environ.Map.init(arena.allocator());
    try map.put("MOX_TEST_SECRET", "hunter2");

    const out = try mox.compose.catB.composeWithSecrets(
        arena.allocator(),
        io,
        tree.files[0],
        &bindings,
        null,
        .{ .env = Env{ .map = &map }, .cache = &cache },
    );
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "<SECRET:") == null);
}

test "compose catB: secret directive emits placeholder with trailing newline" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/.gitconfig", "[user]\n" ++
        "# mox: secret \"op://Personal/email\"\n" ++
        "name = Ada\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    // Placeholder should be on its own line, not glued to "name".
    try std.testing.expect(std.mem.indexOf(u8, out.?, "<SECRET:op://Personal/email>\nname") != null);
}

test "compose catB: inline <secret:URI> resolves mid-line and marks the line .secret" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.zshrc", "export A=1\n" ++
        "export TOKEN=<secret:env:MOX_TEST_SECRET>-x\n" ++
        "export B=2\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(a);
    var cache = mox.secret.cache.Cache.init(a);
    var map = std.process.Environ.Map.init(a);
    try map.put("MOX_TEST_SECRET", "hunter2");
    const m_state = dataTestMachine();

    var prov: std.ArrayList(mox.provenance.map.Segment) = .empty;
    const out = try mox.compose.catB.composeTracked(
        a,
        io,
        tree.files[0],
        &bindings,
        &m_state,
        .{ .env = Env{ .map = &map }, .cache = &cache },
        &prov,
        null,
    );
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "export TOKEN=hunter2-x") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "<SECRET:") == null);
    // The provenance must carry a `.secret` segment so apply/commit keep the
    // cleartext out of the applied-content cache.
    try std.testing.expect(mox.provenance.map.hasSecret(prov.items));
}

test "compose catB: a directiveless file's inline secret marks only its own line" {
    // Regression: the directiveless passthrough marked the ENTIRE file `.secret`
    // when any line resolved an inline secret, so diffs and snapshots redacted
    // every non-secret line too -- a rollback then restored the redaction
    // placeholder over real content. Only the secret's own line may be redacted.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.apprc", "endpoint = https://example.test\n" ++
        "token = <secret:env:MOX_TEST_SECRET>\n" ++
        "retries = 5\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(a);
    var cache = mox.secret.cache.Cache.init(a);
    var map = std.process.Environ.Map.init(a);
    try map.put("MOX_TEST_SECRET", "hunter2");
    const m_state = dataTestMachine();

    var prov: std.ArrayList(mox.provenance.map.Segment) = .empty;
    const out = try mox.compose.catB.composeTracked(
        a,
        io,
        tree.files[0],
        &bindings,
        &m_state,
        .{ .env = Env{ .map = &map }, .cache = &cache },
        &prov,
        null,
    );
    try std.testing.expect(out != null);

    // Redacting the composed output must blank ONLY the token line; the two
    // non-secret lines must survive verbatim -- what snapshot/rollback relies on.
    const redacted = try mox.provenance.map.redactSecretLines(a, out.?, prov.items);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "endpoint = https://example.test") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "retries = 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, mox.provenance.map.secret_redaction) != null);
}

test "compose catB: an included fragment's inline secret marks only its own line" {
    // Regression: a body emitter (fragment include, region pick, when-gate, loop
    // row, literal body) marked its WHOLE span `.secret` when any line resolved
    // an inline secret, over-redacting the body's non-secret lines from diffs and
    // snapshots (rollback then restored the placeholder over real content). Only
    // the secret's own line may be `.secret`.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.myrc", "# top\n# mox: include \"frag.sh\"\n# bottom\n");
    try writeFile(io, tmp.dir, "src/.myrc.d/frag.sh", "plain_before = keepme\n" ++
        "api = <secret:env:MOX_TEST_SECRET>\n" ++
        "plain_after = alsokeep\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(a);
    var cache = mox.secret.cache.Cache.init(a);
    var map = std.process.Environ.Map.init(a);
    try map.put("MOX_TEST_SECRET", "hunter2");
    const m_state = dataTestMachine();

    var prov: std.ArrayList(mox.provenance.map.Segment) = .empty;
    const out = try mox.compose.catB.composeTracked(
        a,
        io,
        tree.files[0],
        &bindings,
        &m_state,
        .{ .env = Env{ .map = &map }, .cache = &cache },
        &prov,
        null,
    );
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "api = hunter2") != null);

    const redacted = try mox.provenance.map.redactSecretLines(a, out.?, prov.items);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "plain_before = keepme") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "plain_after = alsokeep") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "# top") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "# bottom") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, mox.provenance.map.secret_redaction) != null);
}

test "compose catB: for-loop expands TOML records" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.zabbr", "# zsh-abbr generated\n" ++
        "# mox: for entry in abbreviations.toml\n" ++
        "#   abbr <entry.key>=<entry.expansion>\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.zabbr.d/abbreviations.toml", "[[abbreviations]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n" ++
        "\n[[abbreviations]]\nkey = \"gs\"\nexpansion = \"git status\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "abbr ll=ls -l") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "abbr gs=git status") != null);
}

test "compose catB: a for-loop over a missing data source names the path" {
    // A typo'd `for x in nope.toml` surfaced a bare FileNotFound; it now reports
    // DataSourceNotFound with the looked-for path in the diag.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.zabbr", "# mox: for entry in nope.toml\n" ++
        "#   abbr <entry.key>\n" ++
        "# mox: end\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(a);
    var diag: mox.compose.interp.Diag = .{};
    try std.testing.expectError(error.DataSourceNotFound, mox.compose.catB.composeTracked(a, io, tree.files[0], &bindings, null, null, null, &diag));
    const cap = diag.capture() orelse return error.TestExpectedDiag;
    try std.testing.expect(std.mem.indexOf(u8, cap, "nope.toml") != null);
}

test "compose catB: for-loop with when filter (machine doesn't match) suppresses entire loop" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.zabbr", "# mox: for entry in abbreviations.toml when env=WSL\n" ++
        "#   abbr <entry.key>=<entry.expansion>\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.zabbr.d/abbreviations.toml", "[[abbreviations]]\nkey = \"ll\"\nexpansion = \"ls -l\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    // env=WSL not bound -- loop should be suppressed.

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "abbr") == null);
}

test "compose catB: repo-relative loop data source resolves private layer first" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.zabbr", "# mox: for entry in \"data/ids.toml\"\n" ++
        "#   abbr <entry.key>=<entry.expansion>\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "data/ids.toml", "[[ids]]\nkey = \"repo\"\nexpansion = \"R\"\n");
    try writeFile(io, tmp.dir, "private/data/ids.toml", "[[ids]]\nkey = \"priv\"\nexpansion = \"P\"\n");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, a);
    const tmp_root = try std.fs.path.join(a, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path });
    const base_abs = try std.fs.path.join(a, &.{ tmp_root, "src", ".zabbr" });
    const priv_root = try std.fs.path.join(a, &.{ tmp_root, "private" });

    var bindings = std.StringHashMap([]const u8).init(a);

    const file_priv = mox.source.tree.ManagedFile{
        .source_base_path = "src/.zabbr",
        .source_base_abs = base_abs,
        .live_path = "/home/me/.zabbr",
        .has_base = true,
        .overlays = &.{},
        .regions = &.{},
        .repo_dir = tmp_root,
        .private_dir = priv_root,
    };
    const out_priv = (try mox.compose.catB.compose(a, io, file_priv, &bindings, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out_priv, "abbr priv=P") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_priv, "abbr repo=R") == null);

    const file_repo = mox.source.tree.ManagedFile{
        .source_base_path = "src/.zabbr",
        .source_base_abs = base_abs,
        .live_path = "/home/me/.zabbr",
        .has_base = true,
        .overlays = &.{},
        .regions = &.{},
        .repo_dir = tmp_root,
        .private_dir = "",
    };
    const out_repo = (try mox.compose.catB.compose(a, io, file_repo, &bindings, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out_repo, "abbr repo=R") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_repo, "abbr priv=P") == null);
}

fn dataTestMachine() mox.machine.state.MachineState {
    return .{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "h",
        .username = "u",
        .home = "/home/u",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };
}

fn dataTestFile(base_abs: []const u8, repo_dir: []const u8, private_dir: []const u8) mox.source.tree.ManagedFile {
    return .{
        .source_base_path = "src/.zshrc",
        .source_base_abs = base_abs,
        .live_path = "/home/me/.zshrc",
        .has_base = true,
        .overlays = &.{},
        .regions = &.{},
        .repo_dir = repo_dir,
        .private_dir = private_dir,
    };
}

test "compose catB: data captures render scalars, private shadows repo, default rescues missing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.zshrc", "pub=<data.signing.personal_key>\n" ++
        "count=<data.signing.count>\n" ++
        "flag=<data.signing.enabled>\n" ++
        "sub=<data.signing.keys.work>\n" ++
        "shadowed=<data.ids.k>\n" ++
        "fallback=<data.signing.absent | default \"DFLT\">\n");
    try writeFile(io, tmp.dir, "data/signing.toml", "personal_key = \"AAAApub\"\ncount = 7\nenabled = true\n[keys]\nwork = \"WK\"\n");
    try writeFile(io, tmp.dir, "data/ids.toml", "k = \"repo\"\n");
    try writeFile(io, tmp.dir, "private/data/ids.toml", "k = \"priv\"\n");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, a);
    const tmp_root = try std.fs.path.join(a, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path });
    const base_abs = try std.fs.path.join(a, &.{ tmp_root, "src", ".zshrc" });
    const priv_root = try std.fs.path.join(a, &.{ tmp_root, "private" });

    var bindings = std.StringHashMap([]const u8).init(a);
    const m_state = dataTestMachine();
    const file = dataTestFile(base_abs, tmp_root, priv_root);

    const out = (try mox.compose.catB.compose(a, io, file, &bindings, &m_state)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "pub=AAAApub") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "count=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "flag=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sub=WK") != null);
    // Private layer wins for ids.toml.
    try std.testing.expect(std.mem.indexOf(u8, out, "shadowed=priv") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "shadowed=repo") == null);
    // A missing key with a default is rescued.
    try std.testing.expect(std.mem.indexOf(u8, out, "fallback=DFLT") != null);
}

test "compose catB: missing data key is fatal, but a non-scalar is fatal even with a default" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "data/signing.toml", "k = \"v\"\nlist = [1, 2]\n");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_path = try std.process.currentPathAlloc(io, a);
    const tmp_root = try std.fs.path.join(a, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path });
    const base_abs = try std.fs.path.join(a, &.{ tmp_root, "src", ".zshrc" });
    var bindings = std.StringHashMap([]const u8).init(a);
    const m_state = dataTestMachine();

    try writeFile(io, tmp.dir, "src/.zshrc", "x=<data.signing.absent>\n");
    try std.testing.expectError(
        error.UnknownDataKey,
        mox.compose.catB.compose(a, io, dataTestFile(base_abs, tmp_root, ""), &bindings, &m_state),
    );

    // A non-scalar value never falls back to a default -- it is a type error.
    try writeFile(io, tmp.dir, "src/.zshrc", "y=<data.signing.list | default \"z\">\n");
    try std.testing.expectError(
        error.NonScalarData,
        mox.compose.catB.compose(a, io, dataTestFile(base_abs, tmp_root, ""), &bindings, &m_state),
    );
}

test "compose: a missing data capture names the failing capture in the diagnostic" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "data/signing.toml", "k = \"v\"\n");
    try writeFile(io, tmp.dir, "src/.zshrc", "x=<data.signing.absent>\n");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_path = try std.process.currentPathAlloc(io, a);
    const tmp_root = try std.fs.path.join(a, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path });
    const base_abs = try std.fs.path.join(a, &.{ tmp_root, "src", ".zshrc" });
    var bindings = std.StringHashMap([]const u8).init(a);
    const m_state = dataTestMachine();
    const file = dataTestFile(base_abs, tmp_root, "");

    var diag: mox.compose.interp.Diag = .{};
    try std.testing.expectError(
        error.UnknownDataKey,
        mox.compose.composeFileTracked(a, io, file, &bindings, &m_state, null, null, &diag),
    );
    try std.testing.expectEqualStrings("data.signing.absent", diag.capture().?);
}

test "compose catB: a hyphenated data table and key are captured" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "data/my-config.toml", "api-key = \"SECRET123\"\n[ssh-keys]\npersonal-1 = \"KEYBYTES\"\n");
    try writeFile(io, tmp.dir, "src/.zshrc", "top=<data.my-config.api-key>\n" ++
        "deep=<data.my-config.ssh-keys.personal-1>\n");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_path = try std.process.currentPathAlloc(io, a);
    const tmp_root = try std.fs.path.join(a, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path });
    const base_abs = try std.fs.path.join(a, &.{ tmp_root, "src", ".zshrc" });
    var bindings = std.StringHashMap([]const u8).init(a);
    const m_state = dataTestMachine();

    const out = (try mox.compose.catB.compose(a, io, dataTestFile(base_abs, tmp_root, ""), &bindings, &m_state)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "top=SECRET123") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "deep=KEYBYTES") != null);
}

test "compose catB: a null machine leaves machine and env captures verbatim (gate passthrough)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // With no machine facts the base-content interp is skipped entirely, so a
    // `<machine.X>`/`<env.X>` in base text passes through byte-for-byte instead
    // of erroring -- the invariant the loop-row asymmetry preserves.
    try writeFile(io, tmp.dir, "src/.zshrc", "host=<machine.hostname>\nproxy=<env.HTTPS_PROXY>\n");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_path = try std.process.currentPathAlloc(io, a);
    const tmp_root = try std.fs.path.join(a, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path });
    const base_abs = try std.fs.path.join(a, &.{ tmp_root, "src", ".zshrc" });
    var bindings = std.StringHashMap([]const u8).init(a);

    const out = (try mox.compose.catB.compose(a, io, dataTestFile(base_abs, tmp_root, ""), &bindings, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "host=<machine.hostname>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "proxy=<env.HTTPS_PROXY>") != null);
}

test "compose catB: machine.brew_prefix interpolation in fragment" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/.zshrc", "# before\n" ++
        "# mox: include \"extras/brew.sh\" when env=X\n" ++
        "# after\n");
    try writeFile(io, tmp.dir, "src/.zshrc.d/extras/brew.sh", "# shellcheck disable\n" ++
        "eval \"$(<machine.brew_prefix>/bin/brew shellenv)\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("env=X", "1");

    const m_state = mox.machine.state.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "h",
        .username = "u",
        .home = "/home/u",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "/opt/homebrew",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, &m_state);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "/opt/homebrew/bin/brew shellenv") != null);
}

test "compose catB: a directive fallback body interpolates machine captures" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The replace targets os=linux; on a darwin machine the FALLBACK body wins,
    // and its `<machine.home>` capture must expand, not reach the file literally.
    try writeFile(io, tmp.dir, "src/.zshrc", "# mox: replace \"frag.sh\" when os=linux\n" ++
        "export H=\"<machine.home>/bin\"\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.zshrc.d/frag.sh", "export H=/frag\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "darwin");

    const m_state = mox.machine.state.MachineState{
        .os = "darwin",
        .arch = "aarch64",
        .hostname = "h",
        .username = "u",
        .home = "/home/u",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };

    const out = (try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, &m_state)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "export H=\"/home/u/bin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<machine.home>") == null);
}

test "compose catB: machine.os interpolation in for-loop body" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/.test.sh", "# mox: for entry in items.toml\n" ++
        "#   <machine.os>: <entry.name>\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.test.sh.d/items.toml", "[[items]]\nname = \"foo\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const m_state = mox.machine.state.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "h",
        .username = "u",
        .home = "/home/u",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
    };

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, &m_state);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "linux: foo") != null);
}

test "composeFile: handles files larger than 4 KB" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a file larger than the 4 KB sniff limit.
    var big_buf: [8191]u8 = undefined;
    @memset(&big_buf, 'x');
    big_buf[8190] = '\n';
    try writeFile(io, tmp.dir, "src/big.lua", big_buf[0..]);

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqual(@as(usize, 8191), out.?.len);
}

test "compose catA toml: base + axis overlay deep-merge" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/mise/config.toml", "[tools]\nnode = \"20\"\ngo = \"1.21\"\n");
    try writeFile(io, tmp.dir, "src/.config/mise/config.toml.d/profile=work.toml", "[tools]\ngo = \"1.22\"\nrust = \"1.75\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("profile", "work");

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);

    // Re-parse the composed output and verify the merge.
    const parsed = try mox.toml.parse(arena.allocator(), out.?, .{});
    const tools = parsed.table.get("tools").?.table;
    // Base preserved.
    try std.testing.expectEqualStrings("20", tools.get("node").?.string);
    // Overlay overrode go.
    try std.testing.expectEqualStrings("1.22", tools.get("go").?.string);
    // Overlay-only key added.
    try std.testing.expectEqualStrings("1.75", tools.get("rust").?.string);
}

test "compose catA toml: no matching overlay falls back to base" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/mise/config.toml", "[tools]\nnode = \"20\"\n");
    try writeFile(io, tmp.dir, "src/.config/mise/config.toml.d/profile=work.toml", "[tools]\nnode = \"21\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    // profile not bound — overlay should not match.

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    const parsed = try mox.toml.parse(arena.allocator(), out.?, .{});
    try std.testing.expectEqualStrings("20", parsed.table.get("tools").?.table.get("node").?.string);
}

test "compose catA toml: orphan (no base) with single matching overlay" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // aerospace.toml is darwin-only — no base, only an axis overlay.
    try writeFile(io, tmp.dir, "src/.config/aerospace/aerospace.toml.d/os=darwin.toml", "[gaps]\ninner.horizontal = 8\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "darwin");

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "horizontal") != null);
}

test "compose catA toml: orphan with no matching overlay is absent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/aerospace/aerospace.toml.d/os=darwin.toml", "[gaps]\ninner.horizontal = 8\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "linux");

    const result = mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect((try result) == null);
}

test "compose catA toml: a leading whole-file gate composes structurally when it holds" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/aerospace/aerospace.toml", "# mox: when os=macos\n[gaps]\ninner = 8  # tight\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "macos");

    const out = (try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "# mox: when") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "inner = 8  # tight") != null);
}

test "compose catA toml: a leading whole-file gate makes the file absent when it fails" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/aerospace/aerospace.toml", "# mox: when os=macos\n[gaps]\ninner = 8\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "linux");

    const result = mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect((try result) == null);
}

test "compose catA toml: a leading whole-file gate composes with deep-merging overlays" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/aerospace/aerospace.toml", "# mox: when os=macos\n[gaps]\ninner = 8\nouter = 1\n");
    try writeFile(io, tmp.dir, "src/.config/aerospace/aerospace.toml.d/arch=arm64.toml", "[gaps]\ninner = 4\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");

    var on = std.StringHashMap([]const u8).init(arena.allocator());
    try on.put("os", "macos");
    try on.put("arch", "arm64");
    const merged = (try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &on, null, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, merged, "# mox: when") == null);
    const parsed = try mox.toml.parse(arena.allocator(), merged, .{});
    const gaps = parsed.table.get("gaps").?.table;
    try std.testing.expectEqual(@as(i64, 4), gaps.get("inner").?.integer);
    try std.testing.expectEqual(@as(i64, 1), gaps.get("outer").?.integer);

    var off = std.StringHashMap([]const u8).init(arena.allocator());
    try off.put("os", "linux");
    try off.put("arch", "arm64");
    const result = mox.compose.composeFile(arena.allocator(), io, tree.files[0], &off, null, null);
    try std.testing.expect((try result) == null);
}

test "compose catA toml: a leading gate on an orphan overlay is inert, not a whole-file gate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No base file: `layers[0]` is the least-specific overlay. A stray leading
    // `# mox:` line there must not gate away the whole file (which would also
    // drop the sibling overlay that matched).
    try writeFile(io, tmp.dir, "src/.config/x.toml.d/os=macos.toml", "# mox: when os=linux\n[a]\nx = 1\n");
    try writeFile(io, tmp.dir, "src/.config/x.toml.d/os=macos+arch=arm64.toml", "[b]\ny = 2\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");

    var b = std.StringHashMap([]const u8).init(arena.allocator());
    try b.put("os", "macos");
    try b.put("arch", "arm64");
    const out = (try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &b, null, null)).?;
    const parsed = try mox.toml.parse(arena.allocator(), out, .{});
    try std.testing.expectEqual(@as(i64, 1), parsed.table.get("a").?.table.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 2), parsed.table.get("b").?.table.get("y").?.integer);
}

test "compose catA gitconfig: a leading whole-file gate is stripped in a multi-layer merge" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.gitconfig", "# mox: when os=macos\n[user]\n\temail = a@b.com\n");
    try writeFile(io, tmp.dir, "src/.gitconfig.d/arch=arm64", "[core]\n\tautocrlf = input\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");

    var on = std.StringHashMap([]const u8).init(arena.allocator());
    try on.put("os", "macos");
    try on.put("arch", "arm64");
    const out = (try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &on, null, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "# mox: when") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[user]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[core]") != null);

    var off = std.StringHashMap([]const u8).init(arena.allocator());
    try off.put("os", "linux");
    try off.put("arch", "arm64");
    try std.testing.expect((try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &off, null, null)) == null);
}

test "compose catA toml: a terminated whole-file when...end region is not an existence gate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No trailing newline: `# mox: end` is the final line, so a line-count
    // heuristic would misread this scoped region as a whole-file gate.
    try writeFile(io, tmp.dir, "src/.config/scoped.toml", "# mox: when os=macos\n[gaps]\ninner = 8\n# mox: end");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");

    var on = std.StringHashMap([]const u8).init(arena.allocator());
    try on.put("os", "macos");
    const out = (try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &on, null, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "# mox: end") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# mox: when") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "inner = 8") != null);

    // Region gated off: the file still materializes (empty), it is not absent.
    var off = std.StringHashMap([]const u8).init(arena.allocator());
    try off.put("os", "linux");
    const gated = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &off, null, null);
    try std.testing.expect(gated != null);
    try std.testing.expectEqual(@as(usize, 0), gated.?.len);
}

test "compose catB: extensionless file with #! shebang infers # marker" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ~/.zfunc/macosnotify (no extension, zsh autoloaded by name) needs to
    // support `# mox: when os=darwin` gating. Without an extension the
    // marker table doesn't help, but the shebang on line 1 tells us `#`.
    try writeFile(io, tmp.dir, "src/.zfunc/myfunc", "#!/usr/bin/env zsh\n" ++
        "# mox: when os=darwin\n" ++
        "echo darwin-only\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "darwin");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings(
        "#!/usr/bin/env zsh\necho darwin-only\n",
        out.?,
    );
}

test "compose catB: extensionless file with #! shebang gates off when axis fails" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/.zfunc/myfunc", "#!/usr/bin/env zsh\n" ++
        "# mox: when os=darwin\n" ++
        "echo darwin-only\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "linux");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out == null);
}

test "compose catB: directiveless unknown-extension file with <machine.X> interpolates" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // git/allowed_signers has no extension → marker lookup fails, Gap 1 fix
    // routes to pass-through. The pass-through must still run <machine.X>
    // interp so user-baked facts substitute.
    try writeFile(io, tmp.dir, "src/.config/git/allowed_signers", "<machine.email> namespaces=\"git\" <machine.signing_key>\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const facts = [_]mox.machine.state.Fact{
        .{ .name = "email", .value = "x@y.com" },
        .{ .name = "signing_key", .value = "ssh-ed25519 AAA" },
    };
    const m_state = mox.machine.state.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "h",
        .username = "u",
        .home = "/h",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
        .custom_facts = &facts,
    };

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, &m_state);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings(
        "x@y.com namespaces=\"git\" ssh-ed25519 AAA\n",
        out.?,
    );
}

test "compose catB: directiveless file with unknown extension passes through" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // .gitignore_global is not in the comment-marker table; file has no
    // mox directives. Should pass through verbatim, not fail.
    try writeFile(io, tmp.dir, "src/.gitignore_global", "*.log\n*.swp\n.DS_Store\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings("*.log\n*.swp\n.DS_Store\n", out.?);
}

test "compose catB: directiveless ssh-style basename (no extension) passes through" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // .ssh/config has basename "config" with no extension; not in the table.
    try writeFile(io, tmp.dir, "src/.ssh/config", "Host *\n  StrictHostKeyChecking accept-new\n  AddKeysToAgent yes\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings(
        "Host *\n  StrictHostKeyChecking accept-new\n  AddKeysToAgent yes\n",
        out.?,
    );
}

test "compose catB: <machine.X> in base file content interpolates" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Currently mox interpolates <machine.X> only inside fragments and
    // for-loop bodies. The .zshrc migration use-case needs interpolation in
    // the base file's own content too: `export LANG="<machine.locale>"` etc.
    try writeFile(io, tmp.dir, "src/.zshrc", "export LANG=\"<machine.locale>\"\n" ++
        "export TZ=/usr/share/zoneinfo/<machine.timezone>\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const facts = [_]mox.machine.state.Fact{
        .{ .name = "locale", .value = "en_US.UTF-8" },
        .{ .name = "timezone", .value = "Japan" },
    };
    const m_state = mox.machine.state.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "test",
        .username = "u",
        .home = "/home/u",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
        .custom_facts = &facts,
    };

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, &m_state);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings(
        "export LANG=\"en_US.UTF-8\"\n" ++
            "export TZ=/usr/share/zoneinfo/Japan\n",
        out.?,
    );
}

test "compose catB: <machine.X> resolves a custom fact (Gap 4)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // role.lua-style use case: a fragment that interpolates a custom fact
    // not in the built-in MachineState fields. Without facts support, this
    // would fail with UnknownMachineField.
    try writeFile(io, tmp.dir, "src/role.lua", "-- mox: replace from \"profile\"\n" ++
        "kind = \"fallback\"\n" ++
        "-- mox: end\n");
    try writeFile(io, tmp.dir, "src/role.lua.d/profile/personal.lua", "kind = \"<machine.profile>\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("profile", "personal");

    const facts = [_]mox.machine.state.Fact{
        .{ .name = "profile", .value = "personal" },
    };
    const m_state = mox.machine.state.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "test",
        .username = "u",
        .home = "/home/u",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
        .custom_facts = &facts,
    };

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, &m_state);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings("kind = \"personal\"\n", out.?);
}

test "compose catB: for-loop where-clause filters rows by field membership" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Per-row filter via `where entry.shells has "zsh"`. Rows whose shells
    // array contains "zsh" emit; others are skipped. Mirrors chezmoi's
    // `{{ if has "zsh" .shells }}` semantics.
    try writeFile(io, tmp.dir, "src/.zabbr", "# mox: for entry in abbr.toml where entry.shells has \"zsh\"\n" ++
        "# abbr \"<entry.key>\"=\"<entry.expansion>\"\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.zabbr.d/abbr.toml", "[[abbr]]\nkey = \"a\"\nexpansion = \"alpha\"\nshells = [\"zsh\"]\n\n" ++
        "[[abbr]]\nkey = \"b\"\nexpansion = \"beta\"\nshells = [\"fish\"]\n\n" ++
        "[[abbr]]\nkey = \"c\"\nexpansion = \"gamma\"\nshells = [\"zsh\", \"fish\"]\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "gamma") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "beta") == null);
}

test "compose catB: for-loop where-clause supports `not entry.X` for unset/empty fields" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // `not entry.shells` matches rows where the shells field is unset
    // (or empty). Combined with `or` for chezmoi's "default to applies"
    // behavior: `not entry.shells or entry.shells has "zsh"`.
    try writeFile(io, tmp.dir, "src/.zabbr", "# mox: for entry in abbr.toml where not entry.shells or entry.shells has \"zsh\"\n" ++
        "# abbr \"<entry.key>\"\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.zabbr.d/abbr.toml", "[[abbr]]\nkey = \"default-applies\"\n\n" ++ // shells unset
        "[[abbr]]\nkey = \"zsh-only\"\nshells = [\"zsh\"]\n\n" ++
        "[[abbr]]\nkey = \"fish-only\"\nshells = [\"fish\"]\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "default-applies") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "zsh-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "fish-only") == null);
}

test "compose catB: for-loop where-clause `tool=entry.X` substitutes then axis-checks" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // `tool=<entry.when>` substitutes the `when` field from each row, then
    // checks if the resulting `tool=<value>` axis is set in bindings (i.e.,
    // the binary is on PATH). Mirrors chezmoi's `lookPath entry.when`.
    try writeFile(io, tmp.dir, "src/.zabbr", "# mox: for entry in abbr.toml where not entry.when or tool=entry.when\n" ++
        "# abbr \"<entry.key>\"\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.zabbr.d/abbr.toml", "[[abbr]]\nkey = \"always\"\n\n" ++
        "[[abbr]]\nkey = \"have-fd\"\nwhen = \"fd\"\n\n" ++
        "[[abbr]]\nkey = \"missing-zk\"\nwhen = \"zk\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("tool=fd", "1");
    // tool=zk NOT in bindings — simulates "zk binary not on PATH"

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "always") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "have-fd") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "missing-zk") == null);
}

test "compose catA toml: <machine.X> in base content interpolates" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Cat A TOML files used as `.gitconfig`-equivalents for the migration
    // need <machine.X> interpolation just like Cat B base content.
    try writeFile(io, tmp.dir, "src/.config/mise/config.toml", "[user]\nemail = \"<machine.email>\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const facts = [_]mox.machine.state.Fact{.{ .name = "email", .value = "test@example.com" }};
    const m_state = mox.machine.state.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "h",
        .username = "u",
        .home = "/h",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
        .custom_facts = &facts,
    };

    const out = (try mox.compose.catA.compose(arena.allocator(), io, tree.files[0], &bindings, &m_state, null, null, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "test@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<machine.email>") == null);
}

test "compose catA toml: file with mox directives is processed Cat-B-style" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Cat A TOML files with directives should route through catB so users
    // can express inline conditional sections (mirrors how gitconfig works).
    try writeFile(io, tmp.dir, "src/.config/mise/config.toml", "[tools]\nnode = \"latest\"\n" ++
        "# mox: include \"work-extras.toml\" when profile=work\n");
    try writeFile(io, tmp.dir, "src/.config/mise/config.toml.d/work-extras.toml", "[settings]\nidiomatic_version_file_enable_tools = [\"ruby\"]\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("profile", "work");

    const out = (try mox.compose.catA.compose(arena.allocator(), io, tree.files[0], &bindings, null, null, null, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "node = \"latest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "idiomatic_version_file_enable_tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# mox:") == null);
}

test "compose catA gitconfig: file with mox directives is processed Cat-B-style" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // gitconfig with mox include directives — needs Cat B-style processing
    // for the conditional sections, since the structural Cat A merge can't
    // express "include this block when X axis matches".
    try writeFile(io, tmp.dir, "src/.gitconfig", "[user]\n" ++
        "\tname = Ada\n" ++
        "\temail = <machine.email>\n" ++
        "# mox: include \"signing.gitconfig\" when has_signing_key=true\n");
    try writeFile(io, tmp.dir, "src/.gitconfig.d/signing.gitconfig", "\tsigningkey = <machine.signing_key>\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("has_signing_key", "true");

    const facts = [_]mox.machine.state.Fact{
        .{ .name = "email", .value = "ada@example.com" },
        .{ .name = "signing_key", .value = "ssh-ed25519 AAA" },
        .{ .name = "has_signing_key", .value = "true" },
    };
    const m_state = mox.machine.state.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "h",
        .username = "u",
        .home = "/h",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
        .custom_facts = &facts,
    };

    const out = (try mox.compose.catA.compose(arena.allocator(), io, tree.files[0], &bindings, &m_state, null, null, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "email = ada@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "signingkey = ssh-ed25519 AAA") != null);
    // The directive line itself should not appear in the output.
    try std.testing.expect(std.mem.indexOf(u8, out, "# mox:") == null);
}

test "compose catA gitconfig: single layer passes through verbatim" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Plan 11b minimum: a single-layer .gitconfig (no overlays) should pass
    // through verbatim, with <machine.X> interpolation. Section-merge for
    // multi-layer cases is deferred.
    const original =
        "[init]\n" ++
        "\tdefaultBranch = main\n" ++
        "[user]\n" ++
        "\tname = Ada\n" ++
        "\temail = <machine.email>\n";
    try writeFile(io, tmp.dir, "src/.gitconfig", original);

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const facts = [_]mox.machine.state.Fact{.{ .name = "email", .value = "ada@example.com" }};
    const m_state = mox.machine.state.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "h",
        .username = "u",
        .home = "/h",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
        .custom_facts = &facts,
    };

    const out = (try mox.compose.catA.compose(arena.allocator(), io, tree.files[0], &bindings, &m_state, null, null, null)).?;
    const expected =
        "[init]\n" ++
        "\tdefaultBranch = main\n" ++
        "[user]\n" ++
        "\tname = Ada\n" ++
        "\temail = ada@example.com\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "compose catA toml: single base, no overlays passes through verbatim" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A TOML file with no overlays should be returned byte-for-byte. Going
    // through parse-and-re-emit drops comments and reformats whitespace,
    // which is wrong for a pure pass-through. (Gap 9.)
    const original =
        "# top-level comment\n" ++
        "\n" ++
        "# section comment\n" ++
        "[gaps]\n" ++
        "inner.horizontal = 8\n" ++
        "inner.vertical   = 8  # trailing comment\n";
    try writeFile(io, tmp.dir, "src/.config/aerospace/aerospace.toml", original);

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings(original, out.?);
}

test "compose catA json: base + axis overlay deep-merge" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/Code/settings.json", "{\"editor\": {\"tabSize\": 4, \"fontSize\": 12}, \"telemetry\": false}");
    try writeFile(io, tmp.dir, "src/.config/Code/settings.json.d/profile=work.json", "{\"editor\": {\"tabSize\": 2}, \"proxy\": \"http://proxy.corp:8080\"}");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("profile", "work");

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);

    // Pretty emit is deterministic: base key order, overlay-only keys
    // appended, nested objects merged. Pin exact bytes.
    const expected =
        \\{
        \\  "editor": {
        \\    "tabSize": 2,
        \\    "fontSize": 12
        \\  },
        \\  "telemetry": false,
        \\  "proxy": "http://proxy.corp:8080"
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, out.?);
}

test "compose catA json: no matching overlay falls back to base" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/Code/settings.json", "{\"editor\": {\"tabSize\": 4}}\n");
    try writeFile(io, tmp.dir, "src/.config/Code/settings.json.d/profile=work.json", "{\"editor\": {\"tabSize\": 2}}\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    // profile not bound -- overlay should not match; base passes through.

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings("{\"editor\": {\"tabSize\": 4}}\n", out.?);
}

test "compose catA json: orphan (no base) with single matching overlay" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Darwin-only settings file -- no base, only an axis overlay.
    try writeFile(io, tmp.dir, "src/.config/karabiner/karabiner.json.d/os=darwin.json", "{\"profiles\": [{\"name\": \"Default\"}]}\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "darwin");

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "Default") != null);
}

test "compose catA json: orphan with no matching overlay is absent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/karabiner/karabiner.json.d/os=darwin.json", "{\"profiles\": [{\"name\": \"Default\"}]}\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "linux");

    const result = mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect((try result) == null);
}

test "compose catA json: single base, no overlays passes through verbatim" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A JSON file with no overlays should be returned byte-for-byte,
    // including JSONC comments and original formatting. Going through
    // parse-and-re-emit would drop the comments, which is wrong for a
    // pure pass-through.
    const original =
        "{\n" ++
        "  // theme is intentionally dark\n" ++
        "  \"theme\": \"one-dark\", /* block comment */\n" ++
        "  \"vim_mode\": true,\n" ++
        "}\n";
    try writeFile(io, tmp.dir, "src/.config/zed/settings.json", original);

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings(original, out.?);
}

test "compose catA json: <machine.X> in base content interpolates" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Cat A JSON needs <machine.X> interpolation just like Cat A TOML.
    try writeFile(io, tmp.dir, "src/.config/Code/settings.json", "{\"user\": {\"email\": \"<machine.email>\"}}\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const facts = [_]mox.machine.state.Fact{.{ .name = "email", .value = "test@example.com" }};
    const m_state = mox.machine.state.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "h",
        .username = "u",
        .home = "/h",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
        .custom_facts = &facts,
    };

    const out = (try mox.compose.catA.compose(arena.allocator(), io, tree.files[0], &bindings, &m_state, null, null, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "test@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<machine.email>") == null);
}

test "compose catA json: file with mox directives is processed Cat-B-style" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Cat A JSON files with `// mox:` directives should route through catB
    // so users can express inline conditional sections (mirrors TOML).
    try writeFile(io, tmp.dir, "src/.config/Code/settings.json", "{\n" ++
        "  \"editor\": { \"formatOnSave\": true },\n" ++
        "  // mox: include \"work-extras.json\" when profile=work\n" ++
        "}\n");
    try writeFile(io, tmp.dir, "src/.config/Code/settings.json.d/work-extras.json", "  \"window\": { \"zoomLevel\": 1 },\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("profile", "work");

    const out = (try mox.compose.catA.compose(arena.allocator(), io, tree.files[0], &bindings, null, null, null, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"formatOnSave\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"zoomLevel\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "// mox:") == null);
}

test "compose catA json: jsonc layers merge to plain JSON output" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // JSONC input (comments + trailing commas) is accepted on the merge
    // path, but the merged output is plain pretty-printed JSON with no
    // comments. Pin exact bytes to prove both.
    try writeFile(io, tmp.dir, "src/.config/zed/settings.json", "{\n" ++
        "  // theme set per-machine\n" ++
        "  \"theme\": \"one-dark\",\n" ++
        "  \"vim_mode\": true,\n" ++
        "}\n");
    try writeFile(io, tmp.dir, "src/.config/zed/settings.json.d/profile=work.json", "{\n" ++
        "  \"theme\": \"one-light\", // lighter for the office\n" ++
        "}\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("profile", "work");

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);

    const expected =
        \\{
        \\  "theme": "one-light",
        \\  "vim_mode": true
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, out.?);
}

test "compose catA yaml: base + axis overlay deep-merge" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/app/config.yaml", "editor:\n  tabSize: 4\n  fontSize: 12\ntelemetry: false\n");
    try writeFile(io, tmp.dir, "src/.config/app/config.yaml.d/profile=work.yaml", "editor:\n  tabSize: 2\nproxy: http://proxy.corp:8080\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("profile", "work");

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);

    // Block emit is deterministic: base key order, overlay-only keys
    // appended, nested mappings merged. Pin exact bytes.
    const expected =
        \\editor:
        \\  tabSize: 2
        \\  fontSize: 12
        \\telemetry: false
        \\proxy: http://proxy.corp:8080
        \\
    ;
    try std.testing.expectEqualStrings(expected, out.?);
}

test "compose catA yaml: no matching overlay falls back to base" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/app/config.yaml", "editor:\n  tabSize: 4\n");
    try writeFile(io, tmp.dir, "src/.config/app/config.yaml.d/profile=work.yaml", "editor:\n  tabSize: 2\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    // profile not bound -- overlay should not match; base passes through.

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings("editor:\n  tabSize: 4\n", out.?);
}

test "compose catA yaml: orphan (no base) with single matching overlay" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Darwin-only settings file -- no base, only an axis overlay.
    try writeFile(io, tmp.dir, "src/.config/app/settings.yaml.d/os=darwin.yaml", "profiles:\n  - name: Default\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "darwin");

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "Default") != null);
}

test "compose catA yaml: orphan with no matching overlay is absent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/app/settings.yaml.d/os=darwin.yaml", "profiles:\n  - name: Default\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "linux");

    const result = mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect((try result) == null);
}

test "compose catA yaml: single base, no overlays passes through verbatim" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A YAML file with no overlays should be returned byte-for-byte,
    // including comments and original formatting. Going through
    // parse-and-re-emit would drop the comments, which is wrong for a
    // pure pass-through.
    const original =
        "# theme is intentionally dark\n" ++
        "theme: one-dark\n" ++
        "vim_mode: true\n";
    try writeFile(io, tmp.dir, "src/.config/app/config.yaml", original);

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings(original, out.?);
}

test "compose catA yaml: <machine.X> in base content interpolates" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Cat A YAML needs <machine.X> interpolation just like Cat A TOML/JSON.
    try writeFile(io, tmp.dir, "src/.config/app/config.yaml", "user:\n  email: <machine.email>\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const facts = [_]mox.machine.state.Fact{.{ .name = "email", .value = "test@example.com" }};
    const m_state = mox.machine.state.MachineState{
        .os = "linux",
        .arch = "aarch64",
        .hostname = "h",
        .username = "u",
        .home = "/h",
        .tools_on_path = &.{},
        .defined_envs = &.{},
        .brew_prefix = "",
        .cargo_home = "",
        .gopath = "",
        .pnpm_home = "",
        .xdg_config_home = "",
        .xdg_cache_home = "",
        .xdg_data_home = "",
        .xdg_state_home = "",
        .custom_facts = &facts,
    };

    const out = (try mox.compose.catA.compose(arena.allocator(), io, tree.files[0], &bindings, &m_state, null, null, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "test@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<machine.email>") == null);
}

test "compose catA yaml: file with mox directives is processed Cat-B-style" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Cat A YAML files with `# mox:` directives should route through catB
    // so users can express inline conditional sections (mirrors TOML/JSON).
    try writeFile(io, tmp.dir, "src/.config/app/config.yaml", "editor:\n  formatOnSave: true\n" ++
        "# mox: include \"work-extras.yaml\" when profile=work\n");
    try writeFile(io, tmp.dir, "src/.config/app/config.yaml.d/work-extras.yaml", "window:\n  zoomLevel: 1\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("profile", "work");

    const out = (try mox.compose.catA.compose(arena.allocator(), io, tree.files[0], &bindings, null, null, null, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "formatOnSave: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zoomLevel: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# mox:") == null);
}

test "compose catA yaml: layers merge re-emit drops comments" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Comments are accepted on the merge path, but the merged output is
    // re-emitted block YAML with no comments. Pin exact bytes to prove both.
    try writeFile(io, tmp.dir, "src/.config/app/config.yaml", "# theme set per-machine\ntheme: one-dark\nvim_mode: true\n");
    try writeFile(io, tmp.dir, "src/.config/app/config.yaml.d/profile=work.yaml", "theme: one-light # lighter for the office\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("profile", "work");

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);

    const expected =
        \\theme: one-light
        \\vim_mode: true
        \\
    ;
    try std.testing.expectEqualStrings(expected, out.?);
}

test "compose catB: file with mox directive in unknown extension infers marker" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // .somefile isn't in the marker table, but the `# mox: ...` directive
    // line is itself self-evidence that `#` is the marker. Mox infers and
    // processes the directive rather than failing.
    try writeFile(io, tmp.dir, "src/.somefile", "some content\n" ++
        "# mox: include \"x.sh\"\n" ++
        "more content\n");
    try writeFile(io, tmp.dir, "src/.somefile.d/x.sh", "INCLUDED\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "INCLUDED") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.?, "# mox:") == null);
}

test "composeFile: XDG ~/.config/git/config routes to gitconfig section-merge" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "src/.config/git/config", "[user]\n\tname = foo\n\temail = a@example.com\n");
    try writeFile(io, tmp.dir, "src/.config/git/config.d/profile=work", "[user]\n\temail = w@example.com\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("profile", "work");

    const out = try mox.compose.composeFile(arena.allocator(), io, tree.files[0], &bindings, null, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings("[user]\n\tname = foo\n\temail = w@example.com\n", out.?);
}

test "provenance: segments cover every output line exactly once (when-gate to EOF)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A `when`-gate running to EOF carries its own trailing newline; the
    // compose pop drops the doubled newline and provenance must be trimmed to
    // match, leaving no gap or overlap against the diff line splitter.
    try writeFile(io, tmp.dir, "src/.zfunc/myfunc", "#!/usr/bin/env zsh\n" ++
        "# mox: when os=darwin\n" ++
        "echo darwin-only\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "darwin");

    var prov: std.ArrayList(mox.provenance.map.Segment) = .empty;
    const out = try mox.compose.catB.composeTracked(arena.allocator(), io, tree.files[0], &bindings, null, null, &prov, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings("#!/usr/bin/env zsh\necho darwin-only\n", out.?);

    // Contiguous from 0, no overlap, total == line count of the output.
    var next: u32 = 0;
    var total: u32 = 0;
    for (prov.items) |s| {
        try std.testing.expectEqual(next, s.out_start);
        next = s.out_start + s.out_len;
        total += s.out_len;
    }
    try std.testing.expectEqual(mox.provenance.map.lineCount(out.?), total);
}

test "compose catB: blank line at the start of a when region survives" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The common conditional-section shape: a blank line before a gated
    // TOML/INI/gitconfig block must be preserved for byte-parity.
    try writeFile(io, tmp.dir, "src/.testrc", "A\n" ++
        "# mox: when os=macos\n" ++
        "\n" ++
        "B\n" ++
        "# mox: end\n" ++
        "C\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "macos");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings("A\n\nB\nC\n", out.?);
}

test "compose catB: an empty matched when region emits nothing, not a blank line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // An empty region (opener immediately followed by end) is a no-op: on a
    // match it must add nothing -- distinct from a single-blank-line body, which
    // the test above preserves (both have an empty joined body).
    try writeFile(io, tmp.dir, "src/.testrc", "A\n" ++
        "# mox: when os=macos\n" ++
        "# mox: end\n" ++
        "C\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "macos");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings("A\nC\n", out.?);
}

test "compose catB: CRLF base round-trips as CRLF through a gated region" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A CRLF file with a directive must keep CRLF on both plain and
    // gated-body lines; the directive itself parses despite its trailing \r.
    try writeFile(io, tmp.dir, "src/.testrc", "A\r\n" ++
        "# mox: when os=macos\r\n" ++
        "B\r\n" ++
        "# mox: end\r\n" ++
        "C\r\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("os", "macos");

    const out = try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null);
    try std.testing.expect(out != null);
    try std.testing.expectEqualStrings("A\r\nB\r\nC\r\n", out.?);
}

test "compose catA toml: an inline secret marks only its own line" {
    // Regression: a structural file (e.g. a theme TOML with a secret value)
    // recorded the WHOLE file as one `.secret` segment when any line
    // resolved an inline secret, redacting its non-secret lines from diffs and
    // snapshots -- a rollback then restored the placeholder over real config.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.conf.toml", "theme = \"dark\"\n" ++
        "api_key = \"<secret:env:MOX_TEST_SECRET>\"\n" ++
        "port = 8080\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(a);
    var cache = mox.secret.cache.Cache.init(a);
    var map = std.process.Environ.Map.init(a);
    try map.put("MOX_TEST_SECRET", "hunter2");
    const m_state = dataTestMachine();

    var prov: std.ArrayList(mox.provenance.map.Segment) = .empty;
    const out = (try mox.compose.catA.compose(a, io, tree.files[0], &bindings, &m_state, .{ .env = Env{ .map = &map }, .cache = &cache }, &prov, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "api_key = \"hunter2\"") != null);

    const redacted = try mox.provenance.map.redactSecretLines(a, out, prov.items);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "theme = \"dark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "port = 8080") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, mox.provenance.map.secret_redaction) != null);
}

test "compose catB: for-in-for over a record's array field interpolates both loop vars" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Nested loop: the inner `for url in id.match_urls` iterates an array field
    // of the outer record. The body (uncommented) interpolates BOTH the inner
    // scalar `<url>` and the outer record field `<id.slug>`, flattening to one
    // block per (id, url) pair.
    try writeFile(io, tmp.dir, "src/.gitinc", "# mox: for id in ids.toml\n" ++
        "# mox: for url in id.match_urls\n" ++
        "[includeIf \"url:<url>\"]\n" ++
        "\tpath = id-<id.slug>.inc\n" ++
        "# mox: end\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.gitinc.d/ids.toml", "[[ids]]\nslug = \"personal\"\nmatch_urls = [\"github.com/me\", \"gitlab.com/me\"]\n\n" ++
        "[[ids]]\nslug = \"work\"\nmatch_urls = [\"github.com/corp\"]\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    const out = (try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null)).?;

    try std.testing.expect(std.mem.indexOf(u8, out, "[includeIf \"url:github.com/me\"]\n\tpath = id-personal.inc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[includeIf \"url:gitlab.com/me\"]\n\tpath = id-personal.inc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[includeIf \"url:github.com/corp\"]\n\tpath = id-work.inc") != null);
    // Three flattened blocks (2 urls for personal + 1 for work).
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "includeIf"));
}

test "compose catB: for-in-for over two file data sources, both vars interpolate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.matrix", "# mox: for host in hosts.toml\n" ++
        "# mox: for user in users.toml\n" ++
        "#   <host.name>:<user.name>\n" ++
        "# mox: end\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.matrix.d/hosts.toml", "[[hosts]]\nname = \"a\"\n\n[[hosts]]\nname = \"b\"\n");
    try writeFile(io, tmp.dir, "src/.matrix.d/users.toml", "[[users]]\nname = \"x\"\n\n[[users]]\nname = \"y\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    const out = (try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null)).?;

    // Cartesian product: a:x a:y b:x b:y (commented body prefix-stripped).
    try std.testing.expect(std.mem.indexOf(u8, out, "  a:x") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  a:y") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  b:x") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  b:y") != null);
}

test "compose catB: when-in-for gates per row on a row field and its negation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `when id.signing_key` uses the ROW-expression evaluator (presence of the
    // row field), and `when not id.signing_key` its negation: each row emits
    // exactly one branch.
    try writeFile(io, tmp.dir, "src/.gitconfig", "# mox: for id in ids.toml\n" ++
        "[user <id.slug>]\n" ++
        "# mox: when id.signing_key\n" ++
        "\tsigningkey = <id.signing_key>\n" ++
        "# mox: end\n" ++
        "# mox: when not id.signing_key\n" ++
        "\tgpgsign = false\n" ++
        "# mox: end\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.gitconfig.d/ids.toml", "[[ids]]\nslug = \"personal\"\nsigning_key = \"KEYABC\"\n\n" ++
        "[[ids]]\nslug = \"work\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    const out = (try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null)).?;

    try std.testing.expect(std.mem.indexOf(u8, out, "[user personal]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[user work]") != null);
    // personal has a key -> signingkey; no gpgsign=false for it.
    try std.testing.expect(std.mem.indexOf(u8, out, "signingkey = KEYABC") != null);
    // work has no key -> exactly one gpgsign=false, and no stray signingkey.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "gpgsign = false"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "signingkey"));
}

test "compose catB: an uncommented for-loop body passes through verbatim" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Body lines are NOT comment-prefixed; the lenient strip leaves them as-is.
    try writeFile(io, tmp.dir, "src/.conf", "# mox: for e in items.toml\n" ++
        "[section]\n" ++
        "key = <e.k>\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.conf.d/items.toml", "[[items]]\nk = \"one\"\n\n[[items]]\nk = \"two\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    const out = (try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null)).?;

    try std.testing.expect(std.mem.indexOf(u8, out, "[section]\nkey = one") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[section]\nkey = two") != null);
}

test "compose catB: a nested inline secret marks only its own line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A loop body (with a nested `when`) that resolves an inline secret on ONE
    // line: only that line may be `.secret`; the surrounding per-row lines must
    // survive redaction (the data-safety invariant, now through recursion).
    try writeFile(io, tmp.dir, "src/.svc", "# mox: for s in svcs.toml\n" ++
        "[svc <s.name>]\n" ++
        "# mox: when s.needs_token\n" ++
        "token = <secret:env:MOX_TEST_SECRET>\n" ++
        "# mox: end\n" ++
        "plain = <s.name>\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.svc.d/svcs.toml", "[[svcs]]\nname = \"api\"\nneeds_token = true\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(a);
    var cache = mox.secret.cache.Cache.init(a);
    var map = std.process.Environ.Map.init(a);
    try map.put("MOX_TEST_SECRET", "hunter2");
    const m_state = dataTestMachine();

    var prov: std.ArrayList(mox.provenance.map.Segment) = .empty;
    const out = (try mox.compose.catB.composeTracked(
        a,
        io,
        tree.files[0],
        &bindings,
        &m_state,
        .{ .env = Env{ .map = &map }, .cache = &cache },
        &prov,
        null,
    )).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "token = hunter2") != null);

    const redacted = try mox.provenance.map.redactSecretLines(a, out, prov.items);
    // Only the token line is redacted; the row's other lines survive.
    try std.testing.expect(std.mem.indexOf(u8, redacted, "[svc api]") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "plain = api") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, mox.provenance.map.secret_redaction) != null);
}

test "compose catB: where still filters rows in a nested-body loop" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `where` filters the outer loop even though its body carries a nested when.
    try writeFile(io, tmp.dir, "src/.filt", "# mox: for e in items.toml where e.shells has \"zsh\"\n" ++
        "name = <e.name>\n" ++
        "# mox: when e.tag\n" ++
        "tag = <e.tag>\n" ++
        "# mox: end\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.filt.d/items.toml", "[[items]]\nname = \"keep\"\nshells = [\"zsh\"]\ntag = \"t1\"\n\n" ++
        "[[items]]\nname = \"drop\"\nshells = [\"fish\"]\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    const out = (try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null)).?;

    try std.testing.expect(std.mem.indexOf(u8, out, "name = keep") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tag = t1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "drop") == null);
}

test "compose catB: for inside a top-level when composes when the gate passes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.wf", "# mox: when os=darwin\n" ++
        "# mox: for e in items.toml\n" ++
        "#   item <e.k>\n" ++
        "# mox: end\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.wf.d/items.toml", "[[items]]\nk = \"one\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");

    var on = std.StringHashMap([]const u8).init(arena.allocator());
    try on.put("os", "darwin");
    const out_on = (try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &on, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out_on, "  item one") != null);

    var off = std.StringHashMap([]const u8).init(arena.allocator());
    try off.put("os", "linux");
    const out_off = (try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &off, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out_off, "item") == null);
}

test "compose catB: pathologically deep nesting terminates with RecursionTooDeep" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 300 nested `when os=linux` gates (all pass): each level recurses one
    // frame deeper. The depth cap must fail the compose rather than overflow
    // the stack.
    var src: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < 300) : (i += 1) try src.appendSlice(a, "# mox: when os=linux\n");
    try src.appendSlice(a, "deep\n");
    i = 0;
    while (i < 300) : (i += 1) try src.appendSlice(a, "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.deep", src.items);

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "linux");

    try std.testing.expectError(
        error.RecursionTooDeep,
        mox.compose.catB.compose(a, io, tree.files[0], &bindings, null),
    );
}

test "compose catB: inner-loop variable shadows an equally-named outer field ref path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Innermost frame wins: inside the inner loop `<x>` is the inner scalar,
    // while `<outer.label>` still reaches the outer record.
    try writeFile(io, tmp.dir, "src/.shadow", "# mox: for outer in rows.toml\n" ++
        "# mox: for x in outer.vals\n" ++
        "<outer.label>=<x>\n" ++
        "# mox: end\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.shadow.d/rows.toml", "[[rows]]\nlabel = \"L\"\nvals = [\"1\", \"2\"]\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    const out = (try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null)).?;

    try std.testing.expect(std.mem.indexOf(u8, out, "L=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "L=2") != null);
}

test "compose catB: a nested when resolves an OUTER frame field, not just the innermost" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Inside the inner loop, `when outer.keep` gates on the OUTER record's field.
    // The innermost frame is `x` (a scalar), which has no `keep` field; without
    // scope-aware resolution the gate would look at the wrong frame.
    try writeFile(io, tmp.dir, "src/.nest", "# mox: for outer in rows.toml\n" ++
        "# mox: for x in outer.vals\n" ++
        "# mox: when outer.keep\n" ++
        "<outer.label>=<x>\n" ++
        "# mox: end\n" ++
        "# mox: end\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.nest.d/rows.toml", "[[rows]]\nlabel = \"A\"\nkeep = \"1\"\nvals = [\"1\"]\n\n" ++
        "[[rows]]\nlabel = \"B\"\nvals = [\"2\"]\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    const out = (try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null)).?;

    // Row A has keep -> emitted; row B lacks keep -> its (absent-field) gate is
    // false, so it is skipped, not errored.
    try std.testing.expect(std.mem.indexOf(u8, out, "A=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "B=2") == null);
}

test "compose catB: a typo'd loop variable in an in-loop when errors and names it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `idz` names no in-scope frame (the loop variable is `id`): a silent
    // wrong-frame gate is now a hard error naming the offending variable.
    try writeFile(io, tmp.dir, "src/.gc", "# mox: for id in ids.toml\n" ++
        "# mox: when idz.signing_key\n" ++
        "key = <id.slug>\n" ++
        "# mox: end\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.gc.d/ids.toml", "[[ids]]\nslug = \"personal\"\nsigning_key = \"K\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(a);
    var diag: mox.compose.interp.Diag = .{};
    try std.testing.expectError(
        error.UnknownLoopVariable,
        mox.compose.catB.composeTracked(a, io, tree.files[0], &bindings, null, null, null, &diag),
    );
    const cap = diag.capture() orelse return error.TestExpectedDiag;
    try std.testing.expectEqualStrings("idz", cap);
}

test "compose catB: an in-loop when mixes a machine axis with a row field" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `when os=macos and id.signing_key`: the literal axis resolves against the
    // machine bindings, the dotted ref against the row. Both must hold.
    try writeFile(io, tmp.dir, "src/.gc", "# mox: for id in ids.toml\n" ++
        "[user <id.slug>]\n" ++
        "# mox: when os=macos and id.signing_key\n" ++
        "\tsigningkey = <id.signing_key>\n" ++
        "# mox: end\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.gc.d/ids.toml", "[[ids]]\nslug = \"personal\"\nsigning_key = \"K\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");

    var mac = std.StringHashMap([]const u8).init(a);
    try mac.put("os", "macos");
    const out_on = (try mox.compose.catB.compose(a, io, tree.files[0], &mac, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out_on, "signingkey = K") != null);

    var lin = std.StringHashMap([]const u8).init(a);
    try lin.put("os", "linux");
    const out_off = (try mox.compose.catB.compose(a, io, tree.files[0], &lin, null)).?;
    // Axis fails on linux -> the gate is false even though the row field exists.
    try std.testing.expect(std.mem.indexOf(u8, out_off, "signingkey") == null);
    try std.testing.expect(std.mem.indexOf(u8, out_off, "[user personal]") != null);
}

test "compose catB: a typo'd loop-source field errors; an empty array yields zero rows" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `id.match_urlz` is absent on the record -> a typo, so it errors naming the
    // field. (A present-but-empty `match_urls = []` would instead yield 0 rows.)
    try writeFile(io, tmp.dir, "src/.typo", "# mox: for id in ids.toml\n" ++
        "# mox: for url in id.match_urlz\n" ++
        "<url>\n" ++
        "# mox: end\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.typo.d/ids.toml", "[[ids]]\nslug = \"personal\"\nmatch_urls = [\"a\"]\n");

    // A sibling file whose array is legitimately empty: 0 rows, no error.
    try writeFile(io, tmp.dir, "src/.empty", "# mox: for id in ids.toml\n" ++
        "# mox: for url in id.match_urls\n" ++
        "<url>\n" ++
        "# mox: end\n" ++
        "here\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.empty.d/ids.toml", "[[ids]]\nslug = \"personal\"\nmatch_urls = []\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(a);

    var typo_file: mox.source.tree.ManagedFile = undefined;
    var empty_file: mox.source.tree.ManagedFile = undefined;
    for (tree.files) |f| {
        if (std.mem.endsWith(u8, f.source_base_path, ".typo")) typo_file = f;
        if (std.mem.endsWith(u8, f.source_base_path, ".empty")) empty_file = f;
    }

    var diag: mox.compose.interp.Diag = .{};
    try std.testing.expectError(
        error.LoopSourceFieldNotFound,
        mox.compose.catB.composeTracked(a, io, typo_file, &bindings, null, null, null, &diag),
    );
    const cap = diag.capture() orelse return error.TestExpectedDiag;
    try std.testing.expectEqualStrings("match_urlz", cap);

    // The empty-array file composes cleanly: the inner loop emits nothing, but
    // the surrounding body ("here") survives.
    const out = (try mox.compose.catB.compose(a, io, empty_file, &bindings, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "here") != null);
}

test "compose catB: a for-loop variable that shadows a fixed namespace is rejected" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.bad", "# mox: for machine in rows.toml\n" ++
        "<machine.label>\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.bad.d/rows.toml", "[[rows]]\nlabel = \"L\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(a);
    try std.testing.expectError(
        error.ReservedLoopVariable,
        mox.compose.catB.compose(a, io, tree.files[0], &bindings, null),
    );
}

// -- generator (`for ... into`) fan-out --

/// Find the walked file whose live path ends with `suffix`.
/// `std.mem.endsWith` over a live path, treating '/' and '\' as the same
/// separator so a forward-slash test suffix matches a natively-joined live path
/// (whose component separators are '\' on Windows). A no-op on POSIX, where a
/// live path never contains '\'.
fn pathEndsWith(live_path: []const u8, suffix: []const u8) bool {
    if (suffix.len > live_path.len) return false;
    const tail = live_path[live_path.len - suffix.len ..];
    for (tail, suffix) |h, n| {
        const hh: u8 = if (h == '\\') '/' else h;
        const nn: u8 = if (n == '\\') '/' else n;
        if (hh != nn) return false;
    }
    return true;
}

fn fileEndingWith(tree: mox.source.tree.ManagedTree, suffix: []const u8) mox.source.tree.ManagedFile {
    for (tree.files) |f| {
        if (pathEndsWith(f.live_path, suffix)) return f;
    }
    unreachable;
}

fn outputEndingWith(outputs: []mox.compose.catB.GeneratedFile, suffix: []const u8) ?mox.compose.catB.GeneratedFile {
    for (outputs) |o| {
        if (pathEndsWith(o.live_path, suffix)) return o;
    }
    return null;
}

test "generator: N rows -> N files at rendered paths, with a when-in-body conditional field" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/git/ids.inc",
        \\# mox: for id in "data/ids.toml" into "id-<id.slug>.inc"
        \\[user]
        \\email = <id.email>
        \\# mox: when id.signing_key
        \\signingkey = <id.signing_key>
        \\# mox: end
        \\# mox: end
        \\
    );
    try writeFile(io, tmp.dir, "data/ids.toml",
        \\[[ids]]
        \\slug = "personal"
        \\email = "me@personal.com"
        \\signing_key = "KEY1"
        \\
        \\[[ids]]
        \\slug = "work"
        \\email = "me@work.com"
        \\
    );

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    const gen = fileEndingWith(tree, ".config/git/ids.inc");
    var bindings = std.StringHashMap([]const u8).init(a);

    const outputs = (try mox.compose.catB.composeGenerator(a, io, gen, &bindings, null, null, null)).?;
    try std.testing.expectEqual(@as(usize, 2), outputs.len);

    // Paths are rendered relative to the generator's own target dir.
    const personal = outputEndingWith(outputs, ".config/git/id-personal.inc").?;
    const work = outputEndingWith(outputs, ".config/git/id-work.inc").?;

    // The row with a signing_key includes the gated field; the one without omits it.
    try std.testing.expect(std.mem.indexOf(u8, personal.content, "email = me@personal.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, personal.content, "signingkey = KEY1") != null);
    try std.testing.expect(std.mem.indexOf(u8, work.content, "email = me@work.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, work.content, "signingkey") == null);

    // The generator's own path never appears among the produced files.
    try std.testing.expect(outputEndingWith(outputs, "git/ids.inc") == null);
}

test "generator: a nested for inside a generated file composes per element" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/x.gen",
        \\# mox: for id in "data/ids.toml" into "<id.slug>.conf"
        \\[entry]
        \\# mox: for u in id.urls
        \\url = <u>
        \\# mox: end
        \\# mox: end
        \\
    );
    try writeFile(io, tmp.dir, "data/ids.toml",
        \\[[ids]]
        \\slug = "a"
        \\urls = ["one", "two"]
        \\
    );

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    const gen = fileEndingWith(tree, ".config/x.gen");
    var bindings = std.StringHashMap([]const u8).init(a);

    const outputs = (try mox.compose.catB.composeGenerator(a, io, gen, &bindings, null, null, null)).?;
    try std.testing.expectEqual(@as(usize, 1), outputs.len);
    try std.testing.expect(std.mem.indexOf(u8, outputs[0].content, "url = one") != null);
    try std.testing.expect(std.mem.indexOf(u8, outputs[0].content, "url = two") != null);
}

test "generator: zero rows -> zero outputs (empty, not null)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/x.gen",
        \\# mox: for id in "data/ids.toml" into "<id.slug>.conf"
        \\x = <id.slug>
        \\# mox: end
        \\
    );
    try writeFile(io, tmp.dir, "data/ids.toml", "ids = []\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    const gen = fileEndingWith(tree, ".config/x.gen");
    var bindings = std.StringHashMap([]const u8).init(a);

    const outputs = try mox.compose.catB.composeGenerator(a, io, gen, &bindings, null, null, null);
    try std.testing.expect(outputs != null);
    try std.testing.expectEqual(@as(usize, 0), outputs.?.len);
}

test "generator: two rows rendering the same path are rejected" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Both rows render "same.conf" -- a collision that would silently drop one.
    try writeFile(io, tmp.dir, "src/.config/x.gen",
        \\# mox: for id in "data/ids.toml" into "same.conf"
        \\x = <id.slug>
        \\# mox: end
        \\
    );
    try writeFile(io, tmp.dir, "data/ids.toml",
        \\[[ids]]
        \\slug = "a"
        \\
        \\[[ids]]
        \\slug = "b"
        \\
    );

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    const gen = fileEndingWith(tree, ".config/x.gen");
    var bindings = std.StringHashMap([]const u8).init(a);

    try std.testing.expectError(
        error.DuplicateGeneratedPath,
        mox.compose.catB.composeGenerator(a, io, gen, &bindings, null, null, null),
    );
}

test "generator: a rendered path escaping the target dir is rejected" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.config/x.gen",
        \\# mox: for id in "data/ids.toml" into "<id.slug>"
        \\x = <id.slug>
        \\# mox: end
        \\
    );
    // The slug renders a `..` escape.
    try writeFile(io, tmp.dir, "data/ids.toml",
        \\[[ids]]
        \\slug = "../evil"
        \\
    );

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    const gen = fileEndingWith(tree, ".config/x.gen");
    var bindings = std.StringHashMap([]const u8).init(a);

    try std.testing.expectError(
        error.GeneratedPathEscapes,
        mox.compose.catB.composeGenerator(a, io, gen, &bindings, null, null, null),
    );
}

test "generator: a plain (non-generator) file returns null" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "src/.zshrc", "export EDITOR=nvim\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(a);
    try std.testing.expect((try mox.compose.catB.composeGenerator(a, io, tree.files[0], &bindings, null, null, null)) == null);
}

test "generator: an inline secret in a produced file redacts only its own line and flags contains_secret" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A generated file whose body resolves an inline `<secret:...>` on ONE line.
    // Only that line may be `.secret`; the row's other lines survive redaction,
    // and the produced file reports `contains_secret` so apply keeps the
    // cleartext out of the applied-content cache and snapshots.
    try writeFile(io, tmp.dir, "src/.config/x.gen",
        \\# mox: for id in "data/ids.toml" into "id-<id.slug>.inc"
        \\email = <id.email>
        \\token = <secret:env:MOX_TEST_SECRET>
        \\# mox: end
        \\
    );
    try writeFile(io, tmp.dir, "data/ids.toml",
        \\[[ids]]
        \\slug = "a"
        \\email = "me@a.com"
        \\
    );

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    const gen = fileEndingWith(tree, ".config/x.gen");
    var bindings = std.StringHashMap([]const u8).init(a);
    var cache = mox.secret.cache.Cache.init(a);
    var map = std.process.Environ.Map.init(a);
    try map.put("MOX_TEST_SECRET", "hunter2");
    const m_state = dataTestMachine();

    const outputs = (try mox.compose.catB.composeGenerator(a, io, gen, &bindings, &m_state, .{ .env = Env{ .map = &map }, .cache = &cache }, null)).?;
    try std.testing.expectEqual(@as(usize, 1), outputs.len);
    const o = outputs[0];
    try std.testing.expect(std.mem.indexOf(u8, o.content, "token = hunter2") != null);
    try std.testing.expect(o.contains_secret);

    const redacted = try mox.provenance.map.redactSecretLines(a, o.content, o.prov);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "email = me@a.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, mox.provenance.map.secret_redaction) != null);
}

test "generator: provenance covers every output line exactly once with a when-excluded field" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The row without a signing_key drops the gated line, so its output is
    // shorter than the source body: provenance must still tile the produced
    // lines contiguously (no gap/overlap) or diff/commit misattribute edits.
    try writeFile(io, tmp.dir, "src/.config/x.gen",
        \\# mox: for id in "data/ids.toml" into "id-<id.slug>.inc"
        \\[user]
        \\email = <id.email>
        \\# mox: when id.signing_key
        \\signingkey = <id.signing_key>
        \\# mox: end
        \\# mox: end
        \\
    );
    try writeFile(io, tmp.dir, "data/ids.toml",
        \\[[ids]]
        \\slug = "personal"
        \\email = "me@p.com"
        \\signing_key = "KEY1"
        \\
        \\[[ids]]
        \\slug = "work"
        \\email = "me@w.com"
        \\
    );

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    const gen = fileEndingWith(tree, ".config/x.gen");
    var bindings = std.StringHashMap([]const u8).init(a);

    const outputs = (try mox.compose.catB.composeGenerator(a, io, gen, &bindings, null, null, null)).?;
    try std.testing.expectEqual(@as(usize, 2), outputs.len);

    for (outputs) |o| {
        var next: u32 = 0;
        var total: u32 = 0;
        for (o.prov) |s| {
            try std.testing.expectEqual(next, s.out_start);
            next = s.out_start + s.out_len;
            total += s.out_len;
        }
        try std.testing.expectEqual(mox.provenance.map.lineCount(o.content), total);
    }

    // The work row (no signing_key) really is the shorter one -- proving the
    // when-exclusion happened and provenance still tiled it.
    const work = outputEndingWith(outputs, "id-work.inc").?;
    try std.testing.expect(std.mem.indexOf(u8, work.content, "signingkey") == null);
}

test "generator: an empty rendered path is rejected" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The template is exactly `<id.slug>`; an empty slug renders an empty path,
    // which must be refused rather than joined onto the target dir bare.
    try writeFile(io, tmp.dir, "src/.config/x.gen",
        \\# mox: for id in "data/ids.toml" into "<id.slug>"
        \\x = <id.slug>
        \\# mox: end
        \\
    );
    try writeFile(io, tmp.dir, "data/ids.toml",
        \\[[ids]]
        \\slug = ""
        \\
    );

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    const gen = fileEndingWith(tree, ".config/x.gen");
    var bindings = std.StringHashMap([]const u8).init(a);

    try std.testing.expectError(
        error.GeneratedPathEscapes,
        mox.compose.catB.composeGenerator(a, io, gen, &bindings, null, null, null),
    );
}

test "generator: a backslash-delimited parent escape in a rendered path is rejected" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // On Windows `\` is a path separator, so a data-derived `..\evil` is a parent
    // escape there even though POSIX treats the byte as a literal. `keyEscapes`
    // checks both separators on every platform, so the row is refused regardless
    // of the host running the test.
    try writeFile(io, tmp.dir, "src/.config/x.gen",
        \\# mox: for id in "data/ids.toml" into "<id.slug>"
        \\x = <id.slug>
        \\# mox: end
        \\
    );
    try writeFile(io, tmp.dir, "data/ids.toml",
        \\[[ids]]
        \\slug = "..\\evil"
        \\
    );

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try mox.source.tree.walk(a, io, src_dir, "/home/me");
    const gen = fileEndingWith(tree, ".config/x.gen");
    var bindings = std.StringHashMap([]const u8).init(a);

    try std.testing.expectError(
        error.GeneratedPathEscapes,
        mox.compose.catB.composeGenerator(a, io, gen, &bindings, null, null, null),
    );
}

test "compose catB: three nested for loops resolve fields from all three scope frames" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `for a / for b / for c` over three independent record sources: the body
    // interpolates a field from EACH frame at once (`<a.x>`, `<b.y>`, `<c.z>`),
    // proving deep-scope resolution reaches past the innermost record.
    try writeFile(io, tmp.dir, "src/.triple", "# mox: for a in as.toml\n" ++
        "# mox: for b in bs.toml\n" ++
        "# mox: for c in cs.toml\n" ++
        "<a.x>-<b.y>-<c.z>\n" ++
        "# mox: end\n" ++
        "# mox: end\n" ++
        "# mox: end\n");
    try writeFile(io, tmp.dir, "src/.triple.d/as.toml", "[[as]]\nx = \"A1\"\n\n[[as]]\nx = \"A2\"\n");
    try writeFile(io, tmp.dir, "src/.triple.d/bs.toml", "[[bs]]\ny = \"B\"\n");
    try writeFile(io, tmp.dir, "src/.triple.d/cs.toml", "[[cs]]\nz = \"C\"\n");

    const src_dir = try srcPathAlloc(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(src_dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tree = try mox.source.tree.walk(arena.allocator(), io, src_dir, "/home/me");
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    const out = (try mox.compose.catB.compose(arena.allocator(), io, tree.files[0], &bindings, null)).?;

    try std.testing.expect(std.mem.indexOf(u8, out, "A1-B-C") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "A2-B-C") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "-B-C"));
}

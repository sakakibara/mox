//! `mox upgrade [<version>] [--yes]`: compares the running build against a
//! GitHub release of sakakibara/mox (the latest, or an explicit tag),
//! downloads that release's platform archive, verifies it against the
//! release's published `SHA256SUMS`, and atomically replaces the running
//! binary with the `mox` it contains. A fetched `latest` only installs when it
//! is strictly newer than the running build, so it never auto-downgrades; an
//! explicit `<version>` installs unless it names the same version, so an
//! explicit downgrade is allowed. Version selection and the tag compares
//! (`latestTag`, `isNewer`, `versionsEqual`) are pure and unit tested directly
//! against fixture JSON; the download/verify/extract/replace goes through
//! `curl` and the filesystem, exercised end to end via `file://` fixtures and
//! three env-var seams (`MOX_UPGRADE_API`, `MOX_UPGRADE_DOWNLOAD_BASE`,
//! `MOX_UPGRADE_TARGET_BIN`) so tests never touch the real network or the real
//! test binary.

const std = @import("std");
const builtin = @import("builtin");
const Env = @import("env").Env;
const json = @import("json");
const build_options = @import("build_options");
const cli = @import("cli");
const app = @import("app.zig");
const tty = @import("tty.zig");
const prompt = @import("prompt.zig");
const mox = @import("../root.zig");

const Io = std.Io;
const testing = std.testing;

const Spec = struct {
    version: cli.spec.Pos([]const u8, .{ .optional = true, .help = "install this version instead of the latest release" }),
    yes: cli.spec.Flag(.{ .help = "skip the confirmation prompt" }),
};

pub const command = app.command(Spec, .{
    .name = "upgrade",
    .summary = "Download and install a newer mox release",
    .usage = "mox upgrade [<version>] [--yes]",
    .details = "Fetches the latest sakakibara/mox release (or the given <version>), verifies it against the release's SHA256SUMS, and replaces the running binary. --yes skips the confirmation prompt.",
    .group = .general,
    .needs_context = false,
}, run);

const default_api_url = "https://api.github.com/repos/sakakibara/mox/releases/latest";
const default_download_base = "https://github.com/sakakibara/mox/releases/download";

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const alloc = ctx.alloc;
    const io = ctx.io;
    const env = app.envOf(ctx);

    const version_arg = a.version;
    const auto_yes = a.yes;

    const explicit = version_arg != null;
    const tag = if (version_arg) |v|
        (if (std.mem.startsWith(u8, v, "v")) v else try std.fmt.allocPrint(alloc, "v{s}", .{v}))
    else blk: {
        const api_url = try envOrDefault(alloc, env, "MOX_UPGRADE_API", default_api_url);
        const body = fetch(alloc, io, api_url) catch |err| switch (err) {
            error.OutOfMemory, error.CurlNotFound => return err,
            else => "",
        };
        break :blk (try latestTag(alloc, body)) orelse {
            try ctx.out.writeAll("no releases found\n");
            return 0;
        };
    };

    const up_to_date = if (explicit)
        versionsEqual(build_options.version, tag)
    else
        !isNewer(build_options.version, tag);

    if (up_to_date) {
        try ctx.out.print("mox {s} is up to date\n", .{build_options.version});
        return 0;
    }

    const asset = assetName(alloc, builtin.target.os.tag, builtin.target.cpu.arch) catch |err| switch (err) {
        error.UnsupportedPlatform => {
            try ctx.err.writeAll("mox upgrade: not supported on this platform\n");
            return 1;
        },
        else => return err,
    };

    const target_path = env.getAlloc(alloc, "MOX_UPGRADE_TARGET_BIN") catch |err| switch (err) {
        error.EnvironmentVariableMissing => try std.process.executablePathAlloc(io, alloc),
        else => return err,
    };

    if (!auto_yes) {
        if (!try confirm(ctx, io, alloc, tag)) {
            try ctx.out.writeAll("upgrade cancelled\n");
            return 0;
        }
    }

    const download_base = try envOrDefault(alloc, env, "MOX_UPGRADE_DOWNLOAD_BASE", default_download_base);
    const url = try downloadUrl(alloc, download_base, tag, asset);

    const tmp_dir = try makeTempDir(alloc, io, env);
    defer Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const is_zip = builtin.os.tag == .windows;
    const archive_name: []const u8 = if (is_zip) "asset.zip" else "asset.tar.gz";
    const archive_path = try std.fs.path.join(alloc, &.{ tmp_dir, archive_name });

    try ctx.out.print("mox {s} -> {s}: downloading {s}\n", .{ build_options.version, tag, asset });
    if (!try curlDownload(alloc, io, url, archive_path)) {
        try ctx.err.print("mox upgrade: download failed: {s} ({s})\n", .{ tag, url });
        return 1;
    }

    // Verify the downloaded archive against the release's published
    // SHA256SUMS before it is ever unpacked or installed. A missing checksum
    // file, a missing entry for this asset, or a mismatch all REFUSE the
    // install: an upgrade that replaces the running binary must never trust an
    // unverified download.
    try ctx.out.writeAll("mox upgrade: verifying checksum\n");
    const sums_url = try downloadUrl(alloc, download_base, tag, "SHA256SUMS");
    const sums_body = fetch(alloc, io, sums_url) catch |err| switch (err) {
        error.OutOfMemory, error.CurlNotFound => return err,
        else => {
            try ctx.err.print("mox upgrade: could not fetch checksums ({s})\n", .{sums_url});
            return 1;
        },
    };
    const expected = expectedDigest(sums_body, asset) orelse {
        try ctx.err.print("mox upgrade: no checksum entry for {s}; refusing to install\n", .{asset});
        return 1;
    };
    const archive_bytes = try Io.Dir.cwd().readFileAlloc(io, archive_path, alloc, .unlimited);
    const actual = mox.apply.applied.contentHashHex(archive_bytes);
    if (!std.ascii.eqlIgnoreCase(expected, &actual)) {
        try ctx.err.print("mox upgrade: checksum mismatch for {s}; refusing to install\n", .{asset});
        return 1;
    }

    extractArchive(io, archive_path, tmp_dir, is_zip) catch {
        try ctx.err.writeAll("mox upgrade: extract failed\n");
        return 1;
    };

    const extracted_bin = try std.fs.path.join(alloc, &.{ tmp_dir, assetBinaryName(builtin.os.tag) });
    if (!exists(io, extracted_bin)) {
        try ctx.err.writeAll("mox upgrade: extracted archive did not contain a mox binary\n");
        return 1;
    }

    try ctx.out.print("mox upgrade: replacing {s}\n", .{target_path});
    try replaceBinary(alloc, io, target_path, extracted_bin);

    try ctx.out.print("upgraded to {s}\n", .{tag});
    return 0;
}

/// The `[y/N/q]` upgrade confirmation. Default is NO (empty input declines):
/// this replaces the running binary, so an accidental Enter must not go ahead.
/// A scripted stdin (the test harness) or a real TTY drives the interactive
/// path; a non-interactive run without `--yes` declines rather than block.
fn confirm(ctx: *app.Ctx, io: Io, alloc: std.mem.Allocator, tag: []const u8) !bool {
    const scripted = app.stdin_override;
    const interactive = scripted != null or tty.isInteractive(0);
    const mode: prompt.Mode = if (interactive) .interactive else .report_only;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), io, &stdin_buf);
    const input: *Io.Reader = scripted orelse &stdin_reader.interface;

    const question = try std.fmt.allocPrint(alloc, "Upgrade mox {s} -> {s}? [y/N/q] ", .{ build_options.version, tag });
    const choices = [_]prompt.Choice{
        .{ .key = "y", .label = "yes" },
        .{ .key = "n", .label = "no" },
    };
    return switch (try prompt.ask(mode, &choices, 1, question, input, ctx.out)) {
        .chosen => |i| i == 0,
        else => false,
    };
}

/// Reads `key` from `environ`, falling back to `default` only when the
/// variable is unset (any other error, e.g. invalid encoding, propagates).
fn envOrDefault(alloc: std.mem.Allocator, env: Env, key: []const u8, default: []const u8) ![]const u8 {
    return env.get(alloc, key) orelse default;
}

/// Thin wrapper around a `curl` subprocess capturing stdout; a nonzero exit
/// (network error, 404, anything) surfaces as `error.FetchFailed` so `run` can
/// fold it into the same degrade path as a malformed body.
fn fetch(alloc: std.mem.Allocator, io: Io, url: []const u8) ![]const u8 {
    const res = std.process.run(alloc, io, .{ .argv = &.{ "curl", "-fsSL", url } }) catch |err| switch (err) {
        error.FileNotFound => return error.CurlNotFound,
        else => return err,
    };
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) return error.FetchFailed;
    return res.stdout;
}

/// Downloads `url` to `dest_path` via `curl -o`. Returns false on any nonzero
/// curl exit; a missing `curl` surfaces as `error.CurlNotFound`.
fn curlDownload(alloc: std.mem.Allocator, io: Io, url: []const u8, dest_path: []const u8) !bool {
    const res = std.process.run(alloc, io, .{ .argv = &.{ "curl", "-fsSL", "-o", dest_path, url } }) catch |err| switch (err) {
        error.FileNotFound => return error.CurlNotFound,
        else => return err,
    };
    return switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// Extracts `tag_name` from a GitHub releases-API JSON body. Null (not an
/// error) covers every "nothing to report" shape - an empty body, a 404's
/// `{"message":"Not Found"}`, and malformed JSON alike - so `run` degrades
/// the same way regardless of cause.
pub fn latestTag(alloc: std.mem.Allocator, body: []const u8) !?[]const u8 {
    if (body.len == 0) return null;

    const Payload = struct { tag_name: []const u8 };
    const parsed = json.parseInto(Payload, alloc, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    return parsed.tag_name;
}

/// True if `latest` (optionally "v"-prefixed) outranks `current` as a
/// dotted numeric version. A component that isn't a number (or is absent)
/// counts as 0, so a malformed tag can only ever compare as "not newer",
/// never crash the comparison.
pub fn isNewer(current: []const u8, latest: []const u8) bool {
    const c = if (std.mem.startsWith(u8, current, "v")) current[1..] else current;
    const l = if (std.mem.startsWith(u8, latest, "v")) latest[1..] else latest;

    var cit = std.mem.splitScalar(u8, c, '.');
    var lit = std.mem.splitScalar(u8, l, '.');

    while (true) {
        const cp = cit.next();
        const lp = lit.next();
        if (cp == null and lp == null) return false;

        const cv: u32 = if (cp) |s| std.fmt.parseInt(u32, s, 10) catch 0 else 0;
        const lv: u32 = if (lp) |s| std.fmt.parseInt(u32, s, 10) catch 0 else 0;
        if (cv != lv) return lv > cv;
    }
}

/// True if `current` and `tag` (each optionally "v"-prefixed) name the same
/// version, byte-for-byte once the prefix is stripped.
fn versionsEqual(current: []const u8, tag: []const u8) bool {
    const c = if (std.mem.startsWith(u8, current, "v")) current[1..] else current;
    const t = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    return std.mem.eql(u8, c, t);
}

pub const AssetNameError = error{UnsupportedPlatform} || std.mem.Allocator.Error;

/// Names the release asset for `os_tag`/`arch`: `mox-<arch>-windows.zip` on
/// Windows, `mox-<arch>-<os>.tar.gz` on macOS/Linux. Any platform outside
/// the combos mox ships for is `error.UnsupportedPlatform`.
pub fn assetName(alloc: std.mem.Allocator, os_tag: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) AssetNameError![]const u8 {
    const os_name: []const u8 = switch (os_tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return error.UnsupportedPlatform,
    };
    const arch_name: []const u8 = switch (arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => return error.UnsupportedPlatform,
    };
    const ext: []const u8 = if (os_tag == .windows) "zip" else "tar.gz";
    return std.fmt.allocPrint(alloc, "mox-{s}-{s}.{s}", .{ arch_name, os_name, ext });
}

/// The binary's name inside the release archive (at its root): `mox.exe` on
/// Windows, `mox` elsewhere.
pub fn assetBinaryName(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) "mox.exe" else "mox";
}

/// The expected sha256 hex for `asset` from a `SHA256SUMS` body (lines of
/// `<hex>  <filename>`, the filename optionally `*`-prefixed for coreutils'
/// binary mode). Null when no line names `asset`.
pub fn expectedDigest(body: []const u8, asset: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var toks = std.mem.tokenizeAny(u8, line, " \t");
        const hex = toks.next() orelse continue;
        var name = toks.next() orelse continue;
        if (name.len > 0 and name[0] == '*') name = name[1..];
        if (std.mem.eql(u8, name, asset)) return hex;
    }
    return null;
}

/// Extracts `archive_path` into `dest_dir` in process. A `.zip` (Windows) via
/// `std.zip`; a `.tar.gz` (unix) via gzip-decompress + `std.tar` - no
/// external `tar` binary required.
fn extractArchive(io: Io, archive_path: []const u8, dest_dir: []const u8, is_zip: bool) !void {
    var dest = try Io.Dir.openDirAbsolute(io, dest_dir, .{});
    defer dest.close(io);
    var file = try Io.Dir.openFileAbsolute(io, archive_path, .{});
    defer file.close(io);

    var file_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    if (is_zip) {
        try std.zip.extract(dest, &file_reader, .{});
    } else {
        var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &flate_buf);
        try std.tar.extract(io, dest, &decompress.reader, .{});
    }
}

/// `<base>/<tag>/<asset>`, the GitHub release-asset download URL layout.
pub fn downloadUrl(alloc: std.mem.Allocator, base: []const u8, tag: []const u8, asset: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ base, tag, asset });
}

/// The process temp directory: `TMPDIR` then `/tmp` on POSIX; `TEMP` then
/// `TMP` then `C:\Windows\Temp` on Windows.
fn tempBase(alloc: std.mem.Allocator, env: Env) ![]const u8 {
    if (builtin.os.tag == .windows) {
        if (env.get(alloc, "TEMP")) |v| return v;
        if (env.get(alloc, "TMP")) |v| return v;
        return alloc.dupe(u8, "C:\\Windows\\Temp");
    }
    if (env.get(alloc, "TMPDIR")) |v| return v;
    return alloc.dupe(u8, "/tmp");
}

const temp_name_random_bytes = 12;
const temp_name_len = std.base64.url_safe.Encoder.calcSize(temp_name_random_bytes);

/// Creates a fresh `mox-upgrade-<random>` directory under the platform temp
/// location to stage the downloaded archive in. Caller deletes it when done.
fn makeTempDir(alloc: std.mem.Allocator, io: Io, env: Env) ![]const u8 {
    const base = try tempBase(alloc, env);

    var random_bytes: [temp_name_random_bytes]u8 = undefined;
    io.random(&random_bytes);
    var name_buf: [temp_name_len]u8 = undefined;
    const suffix = std.base64.url_safe.Encoder.encode(&name_buf, &random_bytes);
    const dir_name = try std.fmt.allocPrint(alloc, "mox-upgrade-{s}", .{suffix});

    const path = try std.fs.path.join(alloc, &.{ base, dir_name });
    try Io.Dir.cwd().createDirPath(io, path);
    return path;
}

/// True if `path` exists. Any access error counts as absent.
fn exists(io: Io, path: []const u8) bool {
    Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// Swaps `target_path` for the contents of `new_binary_path`: writes the new
/// bytes to a sibling `<target_path>.new` with mode 0755, then puts it in
/// place at `target_path`. `target_path` is never touched until the staged
/// copy is fully written, so a failure reading or writing it leaves the
/// original binary at `target_path` completely intact - no half-written
/// target, nothing left missing.
///
/// On POSIX this is one atomic rename onto `target_path`. On Windows the
/// running `target_path` is locked and can't be renamed over, but it can be
/// renamed aside: `target_path` -> `<target_path>.old`, then
/// `<target_path>.new` -> `target_path`. If that second rename fails, the
/// `.old` is restored so `target_path` is never left missing; if it
/// succeeds, the now-locked `.old` is left for a later run to reap.
pub fn replaceBinary(alloc: std.mem.Allocator, io: Io, target_path: []const u8, new_binary_path: []const u8) !void {
    const staged_path = try std.fmt.allocPrint(alloc, "{s}.new", .{target_path});

    installBinary(io, alloc, new_binary_path, staged_path) catch |err| {
        Io.Dir.deleteFileAbsolute(io, staged_path) catch {};
        return err;
    };

    if (builtin.os.tag == .windows) {
        const old_path = try std.fmt.allocPrint(alloc, "{s}.old", .{target_path});
        Io.Dir.deleteFileAbsolute(io, old_path) catch {};
        Io.Dir.renameAbsolute(target_path, old_path, io) catch |err| {
            Io.Dir.deleteFileAbsolute(io, staged_path) catch {};
            return err;
        };
        Io.Dir.renameAbsolute(staged_path, target_path, io) catch |err| {
            Io.Dir.renameAbsolute(old_path, target_path, io) catch {};
            Io.Dir.deleteFileAbsolute(io, staged_path) catch {};
            return err;
        };
    } else {
        Io.Dir.renameAbsolute(staged_path, target_path, io) catch |err| {
            Io.Dir.deleteFileAbsolute(io, staged_path) catch {};
            return err;
        };
    }
}

fn installBinary(io: Io, alloc: std.mem.Allocator, new_binary_path: []const u8, staged_path: []const u8) !void {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, new_binary_path, alloc, .unlimited);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = staged_path, .data = bytes });
    // On Windows a .exe is executable by extension; no chmod is needed or possible.
    if (builtin.os.tag != .windows) {
        try Io.Dir.cwd().setFilePermissions(io, staged_path, Io.File.Permissions.fromMode(0o755), .{});
    }
}

test "latestTag: extracts tag_name, ignoring unrelated fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try latestTag(arena, "{\"tag_name\":\"v0.2.0\",\"draft\":false,\"assets\":[]}");
    try testing.expectEqualStrings("v0.2.0", got.?);
}

test "latestTag: a 404 body, empty body, and malformed JSON all degrade to null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(try latestTag(arena, "{\"message\":\"Not Found\",\"documentation_url\":\"https://x\"}") == null);
    try testing.expect(try latestTag(arena, "") == null);
    try testing.expect(try latestTag(arena, "not json at all") == null);
}

test "isNewer: newer, equal, and older tags compare correctly, with or without a v prefix" {
    try testing.expect(isNewer("0.1.0", "v0.2.0"));
    try testing.expect(isNewer("0.1.0", "0.2.0"));
    try testing.expect(!isNewer("0.2.0", "v0.2.0"));
    try testing.expect(!isNewer("0.2.0", "v0.1.0"));
    try testing.expect(isNewer("1.9.0", "1.10.0"));
}

test "isNewer: a malformed latest tag never crashes, just isn't newer" {
    try testing.expect(!isNewer("0.1.0", "not-a-version"));
    try testing.expect(!isNewer("0.1.0", ""));
}

test "assetName: the supported os/arch combos name the right archive, anything else is unsupported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("mox-aarch64-macos.tar.gz", try assetName(arena, .macos, .aarch64));
    try testing.expectEqualStrings("mox-x86_64-macos.tar.gz", try assetName(arena, .macos, .x86_64));
    try testing.expectEqualStrings("mox-aarch64-linux.tar.gz", try assetName(arena, .linux, .aarch64));
    try testing.expectEqualStrings("mox-x86_64-linux.tar.gz", try assetName(arena, .linux, .x86_64));
    try testing.expectError(error.UnsupportedPlatform, assetName(arena, .freebsd, .x86_64));
    try testing.expectError(error.UnsupportedPlatform, assetName(arena, .linux, .riscv64));
}

test "assetName: windows is a .zip, unix is a .tar.gz" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("mox-x86_64-windows.zip", try assetName(arena, .windows, .x86_64));
    try testing.expectEqualStrings("mox-aarch64-windows.zip", try assetName(arena, .windows, .aarch64));
    try testing.expectEqualStrings("mox-aarch64-macos.tar.gz", try assetName(arena, .macos, .aarch64));
    try testing.expectEqualStrings("mox-x86_64-linux.tar.gz", try assetName(arena, .linux, .x86_64));
}

test "assetBinaryName: mox.exe on windows, mox elsewhere" {
    try testing.expectEqualStrings("mox.exe", assetBinaryName(.windows));
    try testing.expectEqualStrings("mox", assetBinaryName(.macos));
    try testing.expectEqualStrings("mox", assetBinaryName(.linux));
}

test "expectedDigest: finds the asset's line, handles a binary-mode star, misses an absent asset" {
    const body =
        "aaaa1111  mox-aarch64-linux.tar.gz\n" ++
        "bbbb2222 *mox-aarch64-macos.tar.gz\n" ++
        "\n" ++
        "cccc3333  mox-x86_64-linux.tar.gz\n";
    try testing.expectEqualStrings("aaaa1111", expectedDigest(body, "mox-aarch64-linux.tar.gz").?);
    // The `*` binary-mode marker is stripped from the filename before matching.
    try testing.expectEqualStrings("bbbb2222", expectedDigest(body, "mox-aarch64-macos.tar.gz").?);
    try testing.expect(expectedDigest(body, "mox-x86_64-windows.zip") == null);
}

test "downloadUrl: joins base, tag, and asset with slashes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try downloadUrl(arena, "https://example.invalid/download", "v1.2.3", "mox-aarch64-macos.tar.gz");
    try testing.expectEqualStrings("https://example.invalid/download/v1.2.3/mox-aarch64-macos.tar.gz", got);
}

test "extractArchive: unpacks a gzip tar into the destination" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const srcdir = try std.fs.path.join(arena, &.{ root, "src" });
    try Io.Dir.cwd().createDirPath(testing.io, srcdir);
    const dest = try std.fs.path.join(arena, &.{ root, "dest" });
    try Io.Dir.cwd().createDirPath(testing.io, dest);

    if (builtin.os.tag == .windows) {
        // GNU tar on windows-latest misparses the C:\ drive-letter path and
        // .tar.gz isn't the format mox extracts on Windows anyway; stage the
        // same .zip fixture the e2e tests use and exercise the .zip arm.
        const archive = try std.fs.path.join(arena, &.{ root, "a.zip" });
        try stageAsset(arena, srcdir, archive, "BINARY");

        try extractArchive(testing.io, archive, dest, true);

        const out = try std.fs.path.join(arena, &.{ dest, "mox.exe" });
        try testing.expectEqualStrings("BINARY", try Io.Dir.cwd().readFileAlloc(testing.io, out, arena, .unlimited));
    } else {
        // Build a real mox-*.tar.gz containing a file named "mox" via the
        // system tar (this is the FIXTURE, not the code under test), then
        // extract it in process and assert the file lands in dest.
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fs.path.join(arena, &.{ srcdir, "mox" }), .data = "BINARY" });
        const archive = try std.fs.path.join(arena, &.{ root, "a.tar.gz" });
        _ = try std.process.run(arena, testing.io, .{ .argv = &.{ "tar", "-C", srcdir, "-czf", archive, "mox" } });

        try extractArchive(testing.io, archive, dest, false);

        const out = try std.fs.path.join(arena, &.{ dest, "mox" });
        try testing.expectEqualStrings("BINARY", try Io.Dir.cwd().readFileAlloc(testing.io, out, arena, .unlimited));
    }
}

test "replaceBinary: swaps in the new binary's bytes; leaves the old image aside on Windows, none on POSIX" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const target_path = try std.fs.path.join(arena, &.{ root, "target" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = target_path, .data = "OLD" });
    const new_path = try std.fs.path.join(arena, &.{ root, "new" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = new_path, .data = "NEW" });

    try replaceBinary(arena, testing.io, target_path, new_path);

    const got = try Io.Dir.cwd().readFileAlloc(testing.io, target_path, arena, .unlimited);
    try testing.expectEqualStrings("NEW", got);

    if (builtin.os.tag != .windows) {
        const st = try Io.Dir.cwd().statFile(testing.io, target_path, .{});
        try testing.expectEqual(@as(std.posix.mode_t, 0o755), st.permissions.toMode() & 0o777);
    }

    const old_path = try std.fmt.allocPrint(arena, "{s}.old", .{target_path});
    if (builtin.os.tag == .windows) {
        try testing.expect(exists(testing.io, old_path));
    } else {
        try testing.expect(!exists(testing.io, old_path));
    }
}

test "replaceBinary: a missing new binary leaves the original target intact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const target_path = try std.fs.path.join(arena, &.{ root, "target" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = target_path, .data = "OLD" });
    const missing_new_path = try std.fs.path.join(arena, &.{ root, "does-not-exist" });

    try testing.expectError(error.FileNotFound, replaceBinary(arena, testing.io, target_path, missing_new_path));

    const got = try Io.Dir.cwd().readFileAlloc(testing.io, target_path, arena, .unlimited);
    try testing.expectEqualStrings("OLD", got);

    const old_path = try std.fmt.allocPrint(arena, "{s}.old", .{target_path});
    try testing.expect(!exists(testing.io, old_path));
}

test "replaceBinary: a failure staging the new binary leaves the original target intact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const bin_dir = try std.fs.path.join(arena, &.{ root, "bin" });
    try Io.Dir.cwd().createDirPath(testing.io, bin_dir);
    const target_path = try std.fs.path.join(arena, &.{ bin_dir, "target" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = target_path, .data = "OLD" });

    const new_path = try std.fs.path.join(arena, &.{ root, "new" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = new_path, .data = "NEW" });

    var root_dir = try Io.Dir.cwd().openDir(testing.io, root, .{ .iterate = true });
    defer root_dir.close(testing.io);

    // Mode bits don't gate access on Windows, so this whole simulation
    // (and the failure it induces) only applies on POSIX.
    if (builtin.os.tag != .windows) {
        // Strips write permission from bin_dir so writing the staged
        // "<target>.new" file fails before the atomic rename is ever reached.
        try root_dir.setFilePermissions(testing.io, "bin", Io.File.Permissions.fromMode(0o555), .{});
        defer root_dir.setFilePermissions(testing.io, "bin", Io.File.Permissions.fromMode(0o755), .{}) catch {};

        try testing.expectError(error.AccessDenied, replaceBinary(arena, testing.io, target_path, new_path));

        const got = try Io.Dir.cwd().readFileAlloc(testing.io, target_path, arena, .unlimited);
        try testing.expectEqualStrings("OLD", got);

        const staged_path = try std.fmt.allocPrint(arena, "{s}.new", .{target_path});
        try testing.expect(!exists(testing.io, staged_path));
    }
}

// End-to-end tests drive `run` through mox's cli-zig dispatcher with the
// `MOX_UPGRADE_*` env seams pointed at `file://` fixtures, so nothing touches
// the network or the real binary.

const RunOut = struct { code: u8, out: []const u8, err: []const u8 };

/// Runs `mox upgrade <argv_tail...>` with `pairs` installed as the process
/// environment for the duration of the call, capturing stdout/stderr/exit.
fn runUpgrade(a: std.mem.Allocator, io: Io, pairs: []const [2][]const u8, argv_tail: []const []const u8) !RunOut {
    const map = try a.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(a);
    for (pairs) |p| try map.put(p[0], p[1]);

    const saved = app.environ_override;
    app.environ_override = .{ .map = map };
    defer app.environ_override = saved;

    var out_aw: Io.Writer.Allocating = .init(a);
    var err_aw: Io.Writer.Allocating = .init(a);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, "mox");
    try argv.append(a, "upgrade");
    for (argv_tail) |t| try argv.append(a, t);

    const code = try app.run(a, io, argv.items, &.{command}, &out_aw.writer, &err_aw.writer);
    return .{ .code = code, .out = try out_aw.toOwnedSlice(), .err = try err_aw.toOwnedSlice() };
}

/// Stages a fake release asset at `asset_path` containing `assetBinaryName`
/// with `contents`, matching what the real release pipeline serves for the
/// current platform: a `.tar.gz` with a `mox` entry via the system `tar` on
/// unix, a `.zip` with a `mox.exe` entry via PowerShell `Compress-Archive`
/// on Windows (`std.zip` cannot write archives, and a bare `tar` on
/// windows-latest may resolve to GNU tar, which cannot write zip).
fn stageAsset(arena: std.mem.Allocator, pkg_dir: []const u8, asset_path: []const u8, contents: []const u8) !void {
    const bin_name = assetBinaryName(builtin.os.tag);
    const bin_path = try std.fs.path.join(arena, &.{ pkg_dir, bin_name });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = bin_path, .data = contents });

    if (builtin.os.tag == .windows) {
        const cmd = try std.fmt.allocPrint(arena, "Compress-Archive -Path '{s}' -DestinationPath '{s}' -Force", .{ bin_path, asset_path });
        const res = try std.process.run(arena, testing.io, .{ .argv = &.{ "powershell", "-NoProfile", "-Command", cmd } });
        try testing.expect(res.term == .exited and res.term.exited == 0);
    } else {
        const res = try std.process.run(arena, testing.io, .{ .argv = &.{ "tar", "-czf", asset_path, "-C", pkg_dir, bin_name } });
        try testing.expect(res.term == .exited and res.term.exited == 0);
    }
}

/// Writes a `SHA256SUMS` fixture in `dl_dir` for `asset`. `digest` null means
/// compute the real sha256 of the staged asset (the happy path); a non-null
/// value plants a deliberately wrong digest to exercise refusal.
fn writeSums(arena: std.mem.Allocator, dl_dir: []const u8, asset: []const u8, digest: ?[]const u8) !void {
    const hex: []const u8 = if (digest) |d| d else blk: {
        const asset_path = try std.fs.path.join(arena, &.{ dl_dir, asset });
        const bytes = try Io.Dir.cwd().readFileAlloc(testing.io, asset_path, arena, .unlimited);
        const h = mox.apply.applied.contentHashHex(bytes);
        break :blk try arena.dupe(u8, &h);
    };
    const body = try std.fmt.allocPrint(arena, "{s}  {s}\n", .{ hex, asset });
    const sums_path = try std.fs.path.join(arena, &.{ dl_dir, "SHA256SUMS" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = sums_path, .data = body });
}

test "run: a release matching the current version reports up to date" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const fixture_path = try std.fs.path.join(arena, &.{ root, "release.json" });
    const content = try std.fmt.allocPrint(arena, "{{\"tag_name\":\"v{s}\"}}", .{build_options.version});
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = fixture_path, .data = content });

    const url = try std.fmt.allocPrint(arena, "file://{s}", .{fixture_path});
    const got = try runUpgrade(arena, testing.io, &.{.{ "MOX_UPGRADE_API", url }}, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "up to date") != null);
}

test "run: an explicit version argument equal to the current version reports up to date without a fetch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try runUpgrade(arena, testing.io, &.{}, &.{build_options.version});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "up to date") != null);
}

test "run: an unreachable MOX_UPGRADE_API degrades cleanly to no releases found" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const url = try std.fmt.allocPrint(arena, "file://{s}/does-not-exist.json", .{root});
    const got = try runUpgrade(arena, testing.io, &.{.{ "MOX_UPGRADE_API", url }}, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("no releases found\n", got.out);
}

test "run: a newer release fetched via MOX_UPGRADE_API downloads, verifies, extracts, and installs with --yes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const tag = "v99.0.0";

    const bin_dir = try std.fs.path.join(arena, &.{ root, "bin" });
    try Io.Dir.cwd().createDirPath(testing.io, bin_dir);
    const target_bin = try std.fs.path.join(arena, &.{ bin_dir, "mox" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = target_bin, .data = "OLD" });

    const asset = try assetName(arena, builtin.target.os.tag, builtin.target.cpu.arch);
    const pkg_dir = try std.fs.path.join(arena, &.{ root, "pkg" });
    try Io.Dir.cwd().createDirPath(testing.io, pkg_dir);

    const dl_dir = try std.fs.path.join(arena, &.{ root, "dl", tag });
    try Io.Dir.cwd().createDirPath(testing.io, dl_dir);
    const asset_path = try std.fs.path.join(arena, &.{ dl_dir, asset });
    try stageAsset(arena, pkg_dir, asset_path, "NEW");
    try writeSums(arena, dl_dir, asset, null);

    const release_path = try std.fs.path.join(arena, &.{ root, "release.json" });
    const release_body = try std.fmt.allocPrint(arena, "{{\"tag_name\":\"{s}\"}}", .{tag});
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = release_path, .data = release_body });

    const api_url = try std.fmt.allocPrint(arena, "file://{s}", .{release_path});
    const download_root = try std.fs.path.join(arena, &.{ root, "dl" });
    const download_base = try std.fmt.allocPrint(arena, "file://{s}", .{download_root});

    const got = try runUpgrade(arena, testing.io, &.{
        .{ "MOX_UPGRADE_API", api_url },
        .{ "MOX_UPGRADE_DOWNLOAD_BASE", download_base },
        .{ "MOX_UPGRADE_TARGET_BIN", target_bin },
    }, &.{"--yes"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "upgraded") != null);

    const installed = try Io.Dir.cwd().readFileAlloc(testing.io, target_bin, arena, .unlimited);
    try testing.expectEqualStrings("NEW", installed);
}

test "run: a checksum mismatch is refused and the target binary is left untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const tag = "v99.0.0";

    const bin_dir = try std.fs.path.join(arena, &.{ root, "bin" });
    try Io.Dir.cwd().createDirPath(testing.io, bin_dir);
    const target_bin = try std.fs.path.join(arena, &.{ bin_dir, "mox" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = target_bin, .data = "OLD" });

    const asset = try assetName(arena, builtin.target.os.tag, builtin.target.cpu.arch);
    const pkg_dir = try std.fs.path.join(arena, &.{ root, "pkg" });
    try Io.Dir.cwd().createDirPath(testing.io, pkg_dir);

    const dl_dir = try std.fs.path.join(arena, &.{ root, "dl", tag });
    try Io.Dir.cwd().createDirPath(testing.io, dl_dir);
    const asset_path = try std.fs.path.join(arena, &.{ dl_dir, asset });
    try stageAsset(arena, pkg_dir, asset_path, "NEW");
    // A deliberately wrong digest: 64 zero hex nibbles.
    try writeSums(arena, dl_dir, asset, "0" ** 64);

    const release_path = try std.fs.path.join(arena, &.{ root, "release.json" });
    const release_body = try std.fmt.allocPrint(arena, "{{\"tag_name\":\"{s}\"}}", .{tag});
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = release_path, .data = release_body });

    const api_url = try std.fmt.allocPrint(arena, "file://{s}", .{release_path});
    const download_root = try std.fs.path.join(arena, &.{ root, "dl" });
    const download_base = try std.fmt.allocPrint(arena, "file://{s}", .{download_root});

    const got = try runUpgrade(arena, testing.io, &.{
        .{ "MOX_UPGRADE_API", api_url },
        .{ "MOX_UPGRADE_DOWNLOAD_BASE", download_base },
        .{ "MOX_UPGRADE_TARGET_BIN", target_bin },
    }, &.{"--yes"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "checksum mismatch") != null);

    // The running binary must be left exactly as it was.
    const untouched = try Io.Dir.cwd().readFileAlloc(testing.io, target_bin, arena, .unlimited);
    try testing.expectEqualStrings("OLD", untouched);
}

test "run: a fetched latest that is not newer than the current build reports up to date without installing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const release_path = try std.fs.path.join(arena, &.{ root, "release.json" });
    const release_body = try std.fmt.allocPrint(arena, "{{\"tag_name\":\"v{s}\"}}", .{build_options.version});
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = release_path, .data = release_body });

    const target_bin = try std.fs.path.join(arena, &.{ root, "target" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = target_bin, .data = "OLD" });

    const api_url = try std.fmt.allocPrint(arena, "file://{s}", .{release_path});
    const got = try runUpgrade(arena, testing.io, &.{
        .{ "MOX_UPGRADE_API", api_url },
        .{ "MOX_UPGRADE_TARGET_BIN", target_bin },
    }, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "up to date") != null);

    const untouched = try Io.Dir.cwd().readFileAlloc(testing.io, target_bin, arena, .unlimited);
    try testing.expectEqualStrings("OLD", untouched);
}

test "run: an explicit older version installs, allowing a downgrade with --yes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const tag = "v0.0.1";

    const bin_dir = try std.fs.path.join(arena, &.{ root, "bin" });
    try Io.Dir.cwd().createDirPath(testing.io, bin_dir);
    const target_bin = try std.fs.path.join(arena, &.{ bin_dir, "mox" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = target_bin, .data = "OLD" });

    const asset = try assetName(arena, builtin.target.os.tag, builtin.target.cpu.arch);
    const pkg_dir = try std.fs.path.join(arena, &.{ root, "pkg" });
    try Io.Dir.cwd().createDirPath(testing.io, pkg_dir);

    const dl_dir = try std.fs.path.join(arena, &.{ root, "dl", tag });
    try Io.Dir.cwd().createDirPath(testing.io, dl_dir);
    const asset_path = try std.fs.path.join(arena, &.{ dl_dir, asset });
    try stageAsset(arena, pkg_dir, asset_path, "NEW");
    try writeSums(arena, dl_dir, asset, null);

    const download_root = try std.fs.path.join(arena, &.{ root, "dl" });
    const download_base = try std.fmt.allocPrint(arena, "file://{s}", .{download_root});

    const got = try runUpgrade(arena, testing.io, &.{
        .{ "MOX_UPGRADE_DOWNLOAD_BASE", download_base },
        .{ "MOX_UPGRADE_TARGET_BIN", target_bin },
    }, &.{ tag, "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "upgraded") != null);

    const installed = try Io.Dir.cwd().readFileAlloc(testing.io, target_bin, arena, .unlimited);
    try testing.expectEqualStrings("NEW", installed);
}

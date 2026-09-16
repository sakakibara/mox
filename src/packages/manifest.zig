//! `data/packages/*.toml`: the package manifest -- `[[packages]]` rows
//! declaring what belongs on a machine, `[[blacklist]]` rows naming what must
//! never be offered for tracking.
//!
//! A DIRECTORY, not a file, because the private layer shadows per file: a
//! single private `packages.toml` would replace the whole repo list, while a
//! private `local.toml` alongside the repo's `darwin.toml` adds rows to it.
//! Same-basename files still shadow, matching every other data source.
//!
//! The core understands `name`, `backend` and `when`, plus a file-level
//! `backend` default. Every other key belongs to the backend adapter, which
//! declares and validates its own key set; this loader only guarantees each
//! is a scalar or string array, and refuses anything it cannot hand over --
//! the template projection silently drops a non-scalar, which would turn a
//! mistyped field into a missing one.

const std = @import("std");
const toml = @import("toml");

const dirent = @import("../source/dirent.zig");
const axis = @import("../dsl/axis.zig");
const diag_mod = @import("../machine/diag.zig");

const Io = std.Io;

pub const Diag = diag_mod.Diag;

const max_file_bytes: usize = 1 << 20;

/// An adapter field's value. A float, date, or time is refused rather than
/// stringified: no adapter needs one, and accepting it would make a mistyped
/// version (`version = 1.2`) read as something the adapter never meant.
pub const Field = union(enum) {
    string: []const u8,
    int: i64,
    boolean: bool,
    strings: []const []const u8,
};

pub const Pair = struct {
    key: []const u8,
    value: Field,
};

pub const Row = struct {
    name: []const u8,
    backend: []const u8,
    /// An axis expression, parsed at load so a malformed gate fails now
    /// rather than silently excluding the row on every machine.
    when: ?[]const u8 = null,
    /// Keys outside the core set, for the adapter to declare and validate.
    fields: []const Pair = &.{},
    /// Absolute path of the file the row came from: a reconciled row is
    /// written back to the layer that owns it.
    origin: []const u8,
    /// `data/packages/<basename>`, for diagnostics.
    label: []const u8,
    /// 0-based index within this file's array, for an in-place row edit.
    index: usize,

    pub fn field(self: Row, key: []const u8) ?Field {
        for (self.fields) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }
};

/// Installed but never offered for tracking. A separate array from
/// `[[packages]]` because desired-state and never-offer are different sets,
/// but the same identity: an entry carries whichever adapter fields it takes
/// to name one package (a brew cask and the formula of the same name are not
/// the same entry). A gate is refused -- a blacklist holds regardless of
/// which machine is asking, so a `when` here would read as meaningful and do
/// nothing.
pub const BlacklistRow = struct {
    name: []const u8,
    backend: []const u8,
    fields: []const Pair = &.{},
    origin: []const u8,
    label: []const u8,
    index: usize,

    /// The same package, shaped for the adapter's `idOf`.
    pub fn asRow(self: BlacklistRow) Row {
        return .{
            .name = self.name,
            .backend = self.backend,
            .when = null,
            .fields = self.fields,
            .origin = self.origin,
            .label = self.label,
            .index = self.index,
        };
    }
};

/// A manifest file that was read, and what it declares by default. Kept so a
/// reconciled row can be appended to a file that already speaks its backend
/// rather than guessed at.
pub const Source = struct {
    path: []const u8,
    label: []const u8,
    default_backend: ?[]const u8,
    private: bool,
};

/// A declared installer for a manager that does not ship with the OS. The
/// URL and digest are data so a pin bump is a repo edit, never a mox release.
pub const BootstrapRow = struct {
    backend: []const u8,
    url: []const u8,
    sha256: []const u8,
    origin: []const u8,
    label: []const u8,
    index: usize,
};

pub const Manifest = struct {
    packages: []const Row = &.{},
    blacklist: []const BlacklistRow = &.{},
    bootstrap: []const BootstrapRow = &.{},
    sources: []const Source = &.{},
    /// How many manifest files were read. Zero means the subsystem is not in
    /// use on this repo, which is not the same as a manifest that declares
    /// nothing: without this, a machine that has never opted in would see
    /// every installed package reported as untracked.
    files: usize = 0,

    pub fn inUse(self: Manifest) bool {
        return self.files > 0;
    }
};

pub const Error = error{
    MalformedPackageFile,
    MalformedPackageRow,
};

const core_keys = [_][]const u8{ "name", "backend", "when" };

/// Load every `data/packages/*.toml` row from the repo and private layers.
/// A missing directory in either layer is not an error. `diag` (when
/// non-null) names the file and row behind any failure.
pub fn load(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    private_dir: []const u8,
    diag: ?*Diag,
) !Manifest {
    const files = try discover(arena, io, repo_dir, private_dir);

    var packages: std.ArrayList(Row) = .empty;
    var blacklist: std.ArrayList(BlacklistRow) = .empty;
    var bootstrap: std.ArrayList(BootstrapRow) = .empty;
    var sources: std.ArrayList(Source) = .empty;

    for (files) |f| {
        const content = Io.Dir.cwd().readFileAlloc(io, f.path, arena, .limited(max_file_bytes)) catch |e| {
            if (diag) |d| d.set("{s}: unreadable: {s}", .{ f.label, @errorName(e) });
            return Error.MalformedPackageFile;
        };
        const doc = toml.parse(arena, content, .{}) catch |e| {
            if (diag) |d| d.set("{s}: TOML parse failed: {s}", .{ f.label, @errorName(e) });
            return Error.MalformedPackageFile;
        };
        if (doc != .table) {
            if (diag) |d| d.set("{s}: not a TOML table", .{f.label});
            return Error.MalformedPackageFile;
        }

        const file_backend: ?[]const u8 = blk: {
            const v = doc.table.get("backend") orelse break :blk null;
            if (v != .string or v.string.len == 0) {
                if (diag) |d| d.set("{s}: file-level \"backend\" must be a non-empty string", .{f.label});
                return Error.MalformedPackageFile;
            }
            break :blk v.string;
        };

        try sources.append(arena, .{
            .path = f.path,
            .label = f.label,
            .default_backend = file_backend,
            .private = f.private,
        });

        if (doc.table.get("packages")) |v| {
            if (v != .array) {
                if (diag) |d| d.set("{s}: \"packages\" must be a [[packages]] array", .{f.label});
                return Error.MalformedPackageFile;
            }
            for (v.array.items, 0..) |el, i| {
                if (el != .table) {
                    if (diag) |d| d.set("{s}: packages row {d} is not a table", .{ f.label, i });
                    return Error.MalformedPackageRow;
                }
                try packages.append(arena, try parseRow(arena, f, el.table, file_backend, i, diag));
            }
        }

        if (doc.table.get("bootstrap")) |v| {
            if (v != .array) {
                if (diag) |d| d.set("{s}: \"bootstrap\" must be a [[bootstrap]] array", .{f.label});
                return Error.MalformedPackageFile;
            }
            for (v.array.items, 0..) |el, i| {
                if (el != .table) {
                    if (diag) |d| d.set("{s}: bootstrap row {d} is not a table", .{ f.label, i });
                    return Error.MalformedPackageRow;
                }
                try bootstrap.append(arena, try parseBootstrapRow(arena, f, el.table, file_backend, i, diag));
            }
        }

        if (doc.table.get("blacklist")) |v| {
            if (v != .array) {
                if (diag) |d| d.set("{s}: \"blacklist\" must be a [[blacklist]] array", .{f.label});
                return Error.MalformedPackageFile;
            }
            for (v.array.items, 0..) |el, i| {
                if (el != .table) {
                    if (diag) |d| d.set("{s}: blacklist row {d} is not a table", .{ f.label, i });
                    return Error.MalformedPackageRow;
                }
                try blacklist.append(arena, try parseBlacklistRow(arena, f, el.table, file_backend, i, diag));
            }
        }
    }

    return .{
        .packages = try packages.toOwnedSlice(arena),
        .blacklist = try blacklist.toOwnedSlice(arena),
        .bootstrap = try bootstrap.toOwnedSlice(arena),
        .sources = try sources.toOwnedSlice(arena),
        .files = files.len,
    };
}

const SourceFile = struct {
    path: []const u8,
    label: []const u8,
    private: bool,
};

/// Every `data/packages/*.toml` across both layers, basename-ordered, a
/// private file replacing the repo file of the same basename.
fn discover(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    private_dir: []const u8,
) ![]const SourceFile {
    const Pick = struct { path: []const u8, private: bool };
    var chosen = std.StringHashMap(Pick).init(arena);
    var names: std.ArrayList([]const u8) = .empty;

    for ([_][]const u8{ repo_dir, private_dir }, 0..) |root, layer| {
        if (root.len == 0) continue;
        const dir_path = try std.fs.path.join(arena, &.{ root, "data", "packages" });
        const entries = try dirent.sortedPath(arena, io, dir_path, .{ .iterate = true });
        for (entries) |e| {
            if (e.kind != .file and e.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, e.name, ".toml")) continue;
            if (!chosen.contains(e.name)) try names.append(arena, e.name);
            try chosen.put(e.name, .{
                .path = try std.fs.path.join(arena, &.{ dir_path, e.name }),
                .private = layer == 1,
            });
        }
    }

    std.mem.sort([]const u8, names.items, {}, lessName);

    var out: std.ArrayList(SourceFile) = .empty;
    for (names.items) |n| {
        const pick = chosen.get(n).?;
        try out.append(arena, .{
            .path = pick.path,
            .label = try std.fmt.allocPrint(arena, "data/packages/{s}", .{n}),
            .private = pick.private,
        });
    }
    return out.toOwnedSlice(arena);
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn parseRow(
    arena: std.mem.Allocator,
    f: SourceFile,
    t: toml.Value.Table,
    file_backend: ?[]const u8,
    index: usize,
    diag: ?*Diag,
) !Row {
    const name = blk: {
        const v = t.get("name") orelse {
            if (diag) |d| d.set("{s}: row {d} has no \"name\"", .{ f.label, index });
            return Error.MalformedPackageRow;
        };
        if (v != .string or v.string.len == 0) {
            if (diag) |d| d.set("{s}: row {d}: \"name\" must be a non-empty string", .{ f.label, index });
            return Error.MalformedPackageRow;
        }
        break :blk v.string;
    };

    const backend = blk: {
        if (t.get("backend")) |v| {
            if (v != .string or v.string.len == 0) {
                if (diag) |d| d.set("{s}: row \"{s}\": \"backend\" must be a non-empty string", .{ f.label, name });
                return Error.MalformedPackageRow;
            }
            break :blk v.string;
        }
        break :blk file_backend orelse {
            if (diag) |d| d.set(
                "{s}: row \"{s}\" has no \"backend\" and the file declares no default",
                .{ f.label, name },
            );
            return Error.MalformedPackageRow;
        };
    };

    const when: ?[]const u8 = blk: {
        const v = t.get("when") orelse break :blk null;
        if (v != .string or v.string.len == 0) {
            if (diag) |d| d.set("{s}: row \"{s}\": \"when\" must be a non-empty string", .{ f.label, name });
            return Error.MalformedPackageRow;
        }
        _ = axis.parseString(arena, v.string) catch {
            if (diag) |d| d.set(
                "{s}: row \"{s}\": \"when\" is not a valid axis expression: {s}",
                .{ f.label, name, v.string },
            );
            return Error.MalformedPackageRow;
        };
        break :blk v.string;
    };

    var fields: std.ArrayList(Pair) = .empty;
    for (t.keys(), t.values()) |k, v| {
        if (isCoreKey(k)) continue;
        const fv = try fieldOf(arena, v) orelse {
            if (diag) |d| d.set(
                "{s}: row \"{s}\": \"{s}\" must be a string, integer, boolean, or array of strings",
                .{ f.label, name, k },
            );
            return Error.MalformedPackageRow;
        };
        try fields.append(arena, .{ .key = k, .value = fv });
    }

    return .{
        .name = name,
        .backend = backend,
        .when = when,
        .fields = try fields.toOwnedSlice(arena),
        .origin = f.path,
        .label = f.label,
        .index = index,
    };
}

fn parseBootstrapRow(
    arena: std.mem.Allocator,
    f: SourceFile,
    t: toml.Value.Table,
    file_backend: ?[]const u8,
    index: usize,
    diag: ?*Diag,
) !BootstrapRow {
    _ = arena;
    const backend = blk: {
        if (t.get("backend")) |v| {
            if (v != .string or v.string.len == 0) {
                if (diag) |d| d.set("{s}: bootstrap row {d}: \"backend\" must be a non-empty string", .{ f.label, index });
                return Error.MalformedPackageRow;
            }
            break :blk v.string;
        }
        break :blk file_backend orelse {
            if (diag) |d| d.set(
                "{s}: bootstrap row {d} has no \"backend\" and the file declares no default",
                .{ f.label, index },
            );
            return Error.MalformedPackageRow;
        };
    };

    const url = try requiredString(t, "url", f, backend, index, diag);
    const sha256 = try requiredString(t, "sha256", f, backend, index, diag);

    for (t.keys()) |k| {
        if (std.mem.eql(u8, k, "backend") or std.mem.eql(u8, k, "url") or std.mem.eql(u8, k, "sha256")) continue;
        if (diag) |d| d.set(
            "{s}: bootstrap row for \"{s}\": unknown key \"{s}\" (a bootstrap row takes \"backend\", \"url\", \"sha256\")",
            .{ f.label, backend, k },
        );
        return Error.MalformedPackageRow;
    }

    return .{
        .backend = backend,
        .url = url,
        .sha256 = sha256,
        .origin = f.path,
        .label = f.label,
        .index = index,
    };
}

fn requiredString(
    t: toml.Value.Table,
    key: []const u8,
    f: SourceFile,
    backend: []const u8,
    index: usize,
    diag: ?*Diag,
) ![]const u8 {
    _ = index;
    const v = t.get(key) orelse {
        if (diag) |d| d.set("{s}: bootstrap row for \"{s}\" has no \"{s}\"", .{ f.label, backend, key });
        return Error.MalformedPackageRow;
    };
    if (v != .string or v.string.len == 0) {
        if (diag) |d| d.set("{s}: bootstrap row for \"{s}\": \"{s}\" must be a non-empty string", .{ f.label, backend, key });
        return Error.MalformedPackageRow;
    }
    return v.string;
}

fn parseBlacklistRow(
    arena: std.mem.Allocator,
    f: SourceFile,
    t: toml.Value.Table,
    file_backend: ?[]const u8,
    index: usize,
    diag: ?*Diag,
) !BlacklistRow {
    const name = blk: {
        const v = t.get("name") orelse {
            if (diag) |d| d.set("{s}: blacklist row {d} has no \"name\"", .{ f.label, index });
            return Error.MalformedPackageRow;
        };
        if (v != .string or v.string.len == 0) {
            if (diag) |d| d.set("{s}: blacklist row {d}: \"name\" must be a non-empty string", .{ f.label, index });
            return Error.MalformedPackageRow;
        }
        break :blk v.string;
    };

    const backend = blk: {
        if (t.get("backend")) |v| {
            if (v != .string or v.string.len == 0) {
                if (diag) |d| d.set("{s}: blacklist row \"{s}\": \"backend\" must be a non-empty string", .{ f.label, name });
                return Error.MalformedPackageRow;
            }
            break :blk v.string;
        }
        break :blk file_backend orelse {
            if (diag) |d| d.set(
                "{s}: blacklist row \"{s}\" has no \"backend\" and the file declares no default",
                .{ f.label, name },
            );
            return Error.MalformedPackageRow;
        };
    };

    var fields: std.ArrayList(Pair) = .empty;
    for (t.keys(), t.values()) |k, v| {
        if (std.mem.eql(u8, k, "name") or std.mem.eql(u8, k, "backend")) continue;
        if (std.mem.eql(u8, k, "when")) {
            if (diag) |d| d.set(
                "{s}: blacklist row \"{s}\": a blacklist row takes no \"when\"",
                .{ f.label, name },
            );
            return Error.MalformedPackageRow;
        }
        const fv = try fieldOf(arena, v) orelse {
            if (diag) |d| d.set(
                "{s}: blacklist row \"{s}\": \"{s}\" must be a string, integer, boolean, or array of strings",
                .{ f.label, name, k },
            );
            return Error.MalformedPackageRow;
        };
        try fields.append(arena, .{ .key = k, .value = fv });
    }

    return .{
        .name = name,
        .backend = backend,
        .fields = try fields.toOwnedSlice(arena),
        .origin = f.path,
        .label = f.label,
        .index = index,
    };
}

fn isCoreKey(k: []const u8) bool {
    for (core_keys) |c| {
        if (std.mem.eql(u8, k, c)) return true;
    }
    return false;
}

fn fieldOf(arena: std.mem.Allocator, v: toml.Value) !?Field {
    return switch (v) {
        .string => |s| .{ .string = s },
        .integer => |i| .{ .int = i },
        .boolean => |b| .{ .boolean = b },
        .array => |a| blk: {
            var out: std.ArrayList([]const u8) = .empty;
            for (a.items) |el| {
                if (el != .string) break :blk null;
                try out.append(arena, el.string);
            }
            break :blk .{ .strings = try out.toOwnedSlice(arena) };
        },
        else => null,
    };
}

const testing = std.testing;

fn tmpAbs(a: std.mem.Allocator, io: Io, sub: []const u8, rel: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", sub, rel });
}

test "load: file-level backend default, row override, and adapter fields" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/darwin.toml", .data =
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
        \\[[packages]]
        \\name = "ghostty"
        \\kind = "cask"
        \\pin = true
        \\
        \\[[packages]]
        \\name = "Xcode"
        \\backend = "mas"
        \\id = 497799835
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    const m = try load(a, io, repo, "", null);
    try testing.expectEqual(@as(usize, 3), m.packages.len);

    try testing.expectEqualStrings("ripgrep", m.packages[0].name);
    try testing.expectEqualStrings("brew", m.packages[0].backend);
    try testing.expectEqual(@as(usize, 0), m.packages[0].fields.len);

    try testing.expectEqualStrings("cask", m.packages[1].field("kind").?.string);
    try testing.expectEqual(true, m.packages[1].field("pin").?.boolean);

    try testing.expectEqualStrings("mas", m.packages[2].backend);
    try testing.expectEqual(@as(i64, 497799835), m.packages[2].field("id").?.int);

    try testing.expectEqualStrings("data/packages/darwin.toml", m.packages[0].label);
    try testing.expectEqual(@as(usize, 2), m.packages[2].index);
}

test "load: a row without backend or file default is an error naming the row" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data =
        \\[[packages]]
        \\name = "ripgrep"
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    var d: Diag = .{};
    try testing.expectError(Error.MalformedPackageRow, load(a, io, repo, "", &d));
    try testing.expectEqualStrings(
        "data/packages/a.toml: row \"ripgrep\" has no \"backend\" and the file declares no default",
        d.capture().?,
    );
}

test "load: a non-scalar field is refused, never silently dropped" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data =
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\opts = { verbose = true }
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    var d: Diag = .{};
    try testing.expectError(Error.MalformedPackageRow, load(a, io, repo, "", &d));
    try testing.expectEqualStrings(
        "data/packages/a.toml: row \"ripgrep\": \"opts\" must be a string, integer, boolean, or array of strings",
        d.capture().?,
    );
}

test "load: a float field is refused rather than stringified" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data =
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\version = 1.2
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    var d: Diag = .{};
    try testing.expectError(Error.MalformedPackageRow, load(a, io, repo, "", &d));
}

test "load: an array of strings is an adapter field" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data =
        \\backend = "winget"
        \\
        \\[[packages]]
        \\name = "Microsoft.PowerShell"
        \\args = ["--silent", "--scope=machine"]
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    const m = try load(a, io, repo, "", null);
    const args = m.packages[0].field("args").?.strings;
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("--silent", args[0]);
}

test "load: a malformed when fails at load, not silently at gate time" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data =
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\when = "os=darwin os=linux"
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    var d: Diag = .{};
    try testing.expectError(Error.MalformedPackageRow, load(a, io, repo, "", &d));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "not a valid axis expression") != null);
}

test "load: a valid when is kept verbatim" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data =
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "steam"
        \\when = "profile=personal and os=darwin"
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    const m = try load(a, io, repo, "", null);
    try testing.expectEqualStrings("profile=personal and os=darwin", m.packages[0].when.?);
}

test "load: a private file shadows the repo file of the same basename" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.createDirPath(io, "private/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/darwin.toml", .data =
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "from-repo"
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "private/data/packages/darwin.toml", .data =
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "from-private"
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");
    const priv = try tmpAbs(a, io, &tmp.sub_path, "private");

    const m = try load(a, io, repo, priv, null);
    try testing.expectEqual(@as(usize, 1), m.packages.len);
    try testing.expectEqualStrings("from-private", m.packages[0].name);
}

test "load: a private file with its own basename adds rows to the repo's" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.createDirPath(io, "private/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/darwin.toml", .data =
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "from-repo"
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "private/data/packages/local.toml", .data =
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "from-private"
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");
    const priv = try tmpAbs(a, io, &tmp.sub_path, "private");

    const m = try load(a, io, repo, priv, null);
    try testing.expectEqual(@as(usize, 2), m.packages.len);
    // Basename order, so `darwin.toml` precedes `local.toml` on every host.
    try testing.expectEqualStrings("from-repo", m.packages[0].name);
    try testing.expectEqualStrings("from-private", m.packages[1].name);
    try testing.expect(std.mem.indexOf(u8, m.packages[1].origin, "private") != null);
}

test "load: blacklist rows carry name and backend only" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data =
        \\backend = "brew"
        \\
        \\[[blacklist]]
        \\name = "usage"
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    const m = try load(a, io, repo, "", null);
    try testing.expectEqual(@as(usize, 1), m.blacklist.len);
    try testing.expectEqualStrings("usage", m.blacklist[0].name);
    try testing.expectEqualStrings("brew", m.blacklist[0].backend);
}

test "load: a gate on a blacklist row is an error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data =
        \\backend = "brew"
        \\
        \\[[blacklist]]
        \\name = "usage"
        \\when = "profile=personal"
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    var d: Diag = .{};
    try testing.expectError(Error.MalformedPackageRow, load(a, io, repo, "", &d));
    try testing.expect(std.mem.indexOf(u8, d.capture().?, "no \"when\"") != null);
}

test "load: an empty manifest directory is in use, an absent one is not" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data =
        \\backend = "brew"
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    // A file that declares nothing still opts in: everything installed is
    // then genuinely untracked.
    const m = try load(a, io, repo, "", null);
    try testing.expect(m.inUse());
    try testing.expectEqual(@as(usize, 0), m.packages.len);
}

test "load: a missing packages directory yields an empty manifest" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    const m = try load(a, io, repo, "", null);
    try testing.expectEqual(@as(usize, 0), m.packages.len);
    try testing.expectEqual(@as(usize, 0), m.blacklist.len);
    try testing.expect(!m.inUse());
}

test "load: files are read in basename order across layers" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    for ([_][]const u8{ "c.toml", "a.toml", "b.toml" }) |n| {
        const body = try std.fmt.allocPrint(
            testing.allocator,
            "backend = \"brew\"\n\n[[packages]]\nname = \"{s}\"\n",
            .{n[0..1]},
        );
        defer testing.allocator.free(body);
        const sub = try std.fmt.allocPrint(testing.allocator, "repo/data/packages/{s}", .{n});
        defer testing.allocator.free(sub);
        try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = body });
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    const m = try load(a, io, repo, "", null);
    try testing.expectEqual(@as(usize, 3), m.packages.len);
    try testing.expectEqualStrings("a", m.packages[0].name);
    try testing.expectEqualStrings("b", m.packages[1].name);
    try testing.expectEqualStrings("c", m.packages[2].name);
}

test "load: a non-toml entry in the packages directory is ignored" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/README.md", .data = "notes\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data =
        \\backend = "brew"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    const m = try load(a, io, repo, "", null);
    try testing.expectEqual(@as(usize, 1), m.packages.len);
}

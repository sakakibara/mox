//! `data/packages/*.toml`: the package manifest -- `[[packages]]` rows
//! declaring what belongs on a machine, `[[blacklist]]` rows naming what must
//! never be offered for tracking, `[[bootstrap]]` rows naming a manager's
//! installer.
//!
//! A DIRECTORY, not a file, because the private layer shadows per file: a
//! single private `packages.toml` would replace the whole repo list, while a
//! private `local.toml` alongside the repo's `darwin.toml` adds rows to it.
//! Same-basename files still shadow, matching every other data source.
//!
//! The core understands `name`, `backend` and `when`, plus a file-level
//! `backend` default and a file-level `when` that gates every `[[packages]]`
//! and `[[bootstrap]]` row in the file. Every other key belongs to the
//! backend adapter, which declares and validates its own key set; this
//! loader only guarantees each is a scalar or string array, and refuses
//! anything it cannot hand over -- the template projection silently drops a
//! non-scalar, which would turn a mistyped field into a missing one.

const std = @import("std");
const toml = @import("toml");

const dirent = @import("../source/dirent.zig");
const junk = @import("../source/junk.zig");
const axis = @import("../dsl/axis.zig");
const diag_mod = @import("../machine/diag.zig");
const backend_mod = @import("backend.zig");

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
    /// `data/packages/<basename>`, plus ` (private layer)` when the file is
    /// the private one: two files of one basename are told apart by nothing
    /// else in a message, and every message carries the label alone.
    label: []const u8,
    /// 0-based position within its file's array.
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
/// nothing. That holds for the file's gate too: a file carrying a top-level
/// `when` takes no blacklist row, since the gate would silently narrow it.
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
    /// The file-level gate, raw. A row appended to a file whose gate does
    /// not hold here would never be desired on the machine that recorded it.
    when: ?[]const u8 = null,
    private: bool,
};

/// A declared installer for a manager that does not ship with the OS. The
/// URL and digest are data so a pin bump is a repo edit, never a mox release.
/// Gated like a package row: an installer for one OS must not run on another.
pub const BootstrapRow = struct {
    backend: []const u8,
    url: []const u8,
    sha256: []const u8,
    when: ?[]const u8 = null,
    origin: []const u8,
    label: []const u8,
    index: usize,
};

pub const Manifest = struct {
    packages: []const Row = &.{},
    blacklist: []const BlacklistRow = &.{},
    bootstrap: []const BootstrapRow = &.{},
    sources: []const Source = &.{},
    /// How many manifest files were read.
    files: usize = 0,
    /// Whether either layer has a `data/packages` directory at all. Creating
    /// it is the opt-in: an empty one means every installed package is
    /// genuinely untracked, while a repo without one has never opted in and
    /// must not have its managers queried.
    directory: bool = false,

    pub fn inUse(self: Manifest) bool {
        return self.files > 0 or self.directory;
    }
};

pub const Error = error{
    MalformedPackageFile,
    MalformedPackageRow,
};

const core_keys = [_][]const u8{ "name", "backend", "when" };
const file_keys = [_][]const u8{ "backend", "when", "packages", "blacklist", "bootstrap" };
const utf8_bom = "\xEF\xBB\xBF";

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
    const found = try discover(arena, io, repo_dir, private_dir, diag);
    const files = found.files;

    var packages: std.ArrayList(Row) = .empty;
    var blacklist: std.ArrayList(BlacklistRow) = .empty;
    var bootstrap: std.ArrayList(BootstrapRow) = .empty;
    var sources: std.ArrayList(Source) = .empty;

    for (files) |f| {
        const content = Io.Dir.cwd().readFileAlloc(io, f.path, arena, .limited(max_file_bytes)) catch |e| {
            if (diag) |d| d.set("{s}: unreadable: {s}", .{ f.label, @errorName(e) });
            return Error.MalformedPackageFile;
        };
        if (std.mem.startsWith(u8, content, utf8_bom)) {
            if (diag) |d| d.set("{s}: begins with a byte order mark; save the file without one", .{f.label});
            return Error.MalformedPackageFile;
        }
        const doc = toml.parse(arena, content, .{}) catch |e| {
            if (diag) |d| d.set("{s}: TOML parse failed: {s}", .{ f.label, @errorName(e) });
            return Error.MalformedPackageFile;
        };
        if (doc != .table) {
            if (diag) |d| d.set("{s}: not a TOML table", .{f.label});
            return Error.MalformedPackageFile;
        }
        // `[[package]]` would otherwise load as zero rows and a clean report.
        for (doc.table.keys()) |k| {
            if (isFileKey(k)) continue;
            if (diag) |d| d.set(
                "{s}: unknown top-level key \"{s}\" (a manifest file takes \"backend\", \"when\", \"packages\", \"blacklist\", \"bootstrap\")",
                .{ f.label, k },
            );
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
        // A file-level gate applies to every packages and bootstrap row in
        // the file, so a manifest organised per OS says `when = "os=darwin"`
        // once rather than on each of a hundred rows. A row's own `when`
        // narrows it further.
        const file_when: ?[]const u8 = blk: {
            const v = doc.table.get("when") orelse break :blk null;
            if (v != .string or v.string.len == 0) {
                if (diag) |d| d.set("{s}: file-level \"when\" must be a non-empty string", .{f.label});
                return Error.MalformedPackageFile;
            }
            _ = axis.parseString(arena, v.string) catch {
                if (diag) |d| d.set("{s}: file-level \"when\" is not a valid axis expression: {s}", .{ f.label, v.string });
                return Error.MalformedPackageFile;
            };
            break :blk v.string;
        };

        try sources.append(arena, .{
            .path = f.path,
            .label = f.label,
            .default_backend = file_backend,
            .when = file_when,
            .private = f.private,
        });

        if (doc.table.get("packages")) |v| {
            if (v != .array) {
                if (diag) |d| d.set("{s}: \"packages\" must be a [[packages]] array", .{f.label});
                return Error.MalformedPackageFile;
            }
            for (v.array.items, 0..) |el, i| {
                if (el != .table) {
                    if (diag) |d| d.set("{s}: row {d} is not a table", .{ f.label, i });
                    return Error.MalformedPackageRow;
                }
                try packages.append(arena, try parseRow(arena, f, el.table, file_backend, file_when, i, diag));
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
                try bootstrap.append(arena, try parseBootstrapRow(arena, f, el.table, file_backend, file_when, i, diag));
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
                try blacklist.append(arena, try parseBlacklistRow(arena, f, el.table, file_backend, file_when, i, diag));
            }
        }
    }

    return .{
        .packages = try packages.toOwnedSlice(arena),
        .blacklist = try blacklist.toOwnedSlice(arena),
        .bootstrap = try bootstrap.toOwnedSlice(arena),
        .sources = try sources.toOwnedSlice(arena),
        .files = files.len,
        .directory = found.directory,
    };
}

const SourceFile = struct {
    path: []const u8,
    label: []const u8,
    private: bool,
};

const Discovered = struct {
    files: []const SourceFile,
    directory: bool,
};

/// Every `data/packages/*.toml` across both layers, basename-ordered, a
/// private file replacing the repo file of the same basename. A missing
/// directory is no files; a `data/packages` that is not a directory is an
/// error naming it.
fn discover(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    private_dir: []const u8,
    diag: ?*Diag,
) !Discovered {
    const Pick = struct { path: []const u8, private: bool };
    var chosen = std.StringHashMap(Pick).init(arena);
    var names: std.ArrayList([]const u8) = .empty;
    var directory = false;

    for ([_][]const u8{ repo_dir, private_dir }, 0..) |root, layer| {
        if (root.len == 0) continue;
        const dir_path = try std.fs.path.join(arena, &.{ root, "data", "packages" });
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => continue,
            error.NotDir => {
                if (diag) |d| d.set("data/packages: not a directory: {s}", .{dir_path});
                return e;
            },
            else => {
                if (diag) |d| d.set("data/packages: cannot open {s}: {s}", .{ dir_path, @errorName(e) });
                return e;
            },
        };
        defer dir.close(io);
        directory = true;
        const entries = dirent.sorted(arena, io, dir) catch |e| {
            if (diag) |d| d.set("data/packages: cannot read {s}: {s}", .{ dir_path, @errorName(e) });
            return e;
        };
        for (entries) |e| {
            if (e.kind != .file and e.kind != .sym_link) continue;
            // Editor and OS noise ends in `.toml` too: emacs's `.#darwin.toml`
            // lock is a dangling symlink, and a copied `._darwin.toml` is not
            // TOML at all. Either would fail every package command while a
            // manifest is merely open in an editor.
            if (junk.isJunk(e.name)) continue;
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
        // Every message about this file interpolates the label, and each is
        // one line; a filename carrying a newline would split them all.
        const shown = try diag_mod.oneLine(arena, n);
        try out.append(arena, .{
            .path = pick.path,
            // The layer is part of the name every message prints: a private
            // file shadowing a repo file of the same basename would otherwise
            // report its faults against the repo file, which is intact.
            .label = if (pick.private)
                try std.fmt.allocPrint(arena, "data/packages/{s} (private layer)", .{shown})
            else
                try std.fmt.allocPrint(arena, "data/packages/{s}", .{shown}),
            .private = pick.private,
        });
    }
    return .{ .files = try out.toOwnedSlice(arena), .directory = directory };
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn parseRow(
    arena: std.mem.Allocator,
    f: SourceFile,
    t: toml.Value.Table,
    file_backend: ?[]const u8,
    file_when: ?[]const u8,
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
        if (!nameShapeOk(v.string)) {
            if (diag) |d| d.set("{s}: row {d}: \"name\" must not be blank or contain whitespace, control characters, or bytes that are not UTF-8, and must be at most 256 bytes", .{ f.label, index });
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

    const own_when: ?[]const u8 = blk: {
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
    const when = combineWhen(arena, file_when, own_when) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            if (diag) |d| d.set(
                "{s}: row \"{s}\": the file gate and this row's \"when\" do not combine into a valid axis expression: ({s}) and ({s})",
                .{ f.label, name, file_when.?, own_when.? },
            );
            return Error.MalformedPackageRow;
        },
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

/// A file gate and a row gate both hold: `(file) and (row)`. The combination
/// is parsed here rather than assumed: the parens it adds cost depth, so two
/// gates that each parse can exceed the limit together, and the refusal has to
/// come from the loader, which knows the file and the row, rather than from an
/// evaluation that knows neither.
fn combineWhen(arena: std.mem.Allocator, file_when: ?[]const u8, own: ?[]const u8) !?[]const u8 {
    if (file_when == null) return own;
    if (own == null) return file_when;
    const combined = try std.fmt.allocPrint(arena, "({s}) and ({s})", .{ file_when.?, own.? });
    _ = try axis.parseString(arena, combined);
    return combined;
}

fn parseBootstrapRow(
    arena: std.mem.Allocator,
    f: SourceFile,
    t: toml.Value.Table,
    file_backend: ?[]const u8,
    file_when: ?[]const u8,
    index: usize,
    diag: ?*Diag,
) !BootstrapRow {
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
    const own_when: ?[]const u8 = blk: {
        const v = t.get("when") orelse break :blk null;
        if (v != .string or v.string.len == 0) {
            if (diag) |d| d.set("{s}: bootstrap row {d} for backend \"{s}\": \"when\" must be a non-empty string", .{ f.label, index, backend });
            return Error.MalformedPackageRow;
        }
        _ = axis.parseString(arena, v.string) catch {
            if (diag) |d| d.set("{s}: bootstrap row {d} for backend \"{s}\": \"when\" is not a valid axis expression: {s}", .{ f.label, index, backend, v.string });
            return Error.MalformedPackageRow;
        };
        break :blk v.string;
    };

    for (t.keys()) |k| {
        if (std.mem.eql(u8, k, "backend") or std.mem.eql(u8, k, "url") or std.mem.eql(u8, k, "sha256") or std.mem.eql(u8, k, "when")) continue;
        if (diag) |d| d.set(
            "{s}: bootstrap row {d} for backend \"{s}\": unknown key \"{s}\" (a bootstrap row takes \"backend\", \"url\", \"sha256\", \"when\")",
            .{ f.label, index, backend, k },
        );
        return Error.MalformedPackageRow;
    }

    const when = combineWhen(arena, file_when, own_when) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            if (diag) |d| d.set(
                "{s}: bootstrap row {d} for backend \"{s}\": the file gate and this row's \"when\" do not combine into a valid axis expression: ({s}) and ({s})",
                .{ f.label, index, backend, file_when.?, own_when.? },
            );
            return Error.MalformedPackageRow;
        },
    };

    return .{
        .backend = backend,
        .url = url,
        .sha256 = sha256,
        .when = when,
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
    const v = t.get(key) orelse {
        if (diag) |d| d.set("{s}: bootstrap row {d} for backend \"{s}\" has no \"{s}\"", .{ f.label, index, backend, key });
        return Error.MalformedPackageRow;
    };
    if (v != .string or v.string.len == 0) {
        if (diag) |d| d.set("{s}: bootstrap row {d} for backend \"{s}\": \"{s}\" must be a non-empty string", .{ f.label, index, backend, key });
        return Error.MalformedPackageRow;
    }
    return v.string;
}

fn parseBlacklistRow(
    arena: std.mem.Allocator,
    f: SourceFile,
    t: toml.Value.Table,
    file_backend: ?[]const u8,
    file_when: ?[]const u8,
    index: usize,
    diag: ?*Diag,
) !BlacklistRow {
    // A row's own `when` is refused because a blacklist holds regardless of
    // which machine asks; a file's gate would narrow it the same way, and
    // silently, so the file cannot hold both.
    if (file_when != null) {
        if (diag) |d| d.set(
            "{s}: blacklist row {d}: this file has a top-level \"when\", which would gate it; a blacklist holds regardless of which machine asks, so it belongs in a file with no \"when\"",
            .{ f.label, index },
        );
        return Error.MalformedPackageRow;
    }

    const name = blk: {
        const v = t.get("name") orelse {
            if (diag) |d| d.set("{s}: blacklist row {d} has no \"name\"", .{ f.label, index });
            return Error.MalformedPackageRow;
        };
        if (v != .string or v.string.len == 0) {
            if (diag) |d| d.set("{s}: blacklist row {d}: \"name\" must be a non-empty string", .{ f.label, index });
            return Error.MalformedPackageRow;
        }
        if (!nameShapeOk(v.string)) {
            if (diag) |d| d.set("{s}: blacklist row {d}: \"name\" must not be blank or contain whitespace, control characters, or bytes that are not UTF-8, and must be at most 256 bytes", .{ f.label, index });
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

fn isFileKey(k: []const u8) bool {
    for (file_keys) |c| {
        if (std.mem.eql(u8, k, c)) return true;
    }
    return false;
}

/// A name a manager could be handed. One rule, in `backend`, shared with the
/// shape a declared row must have: a row an adapter may write is exactly a row
/// this loader will read back, so `mox commit` cannot write a manifest the
/// next command refuses. Checked here so `name = " "` is refused by the file
/// and row it sits in rather than blamed on the adapter it reaches.
fn nameShapeOk(name: []const u8) bool {
    return backend_mod.nameShapeOk(name);
}

pub fn fieldOf(arena: std.mem.Allocator, v: toml.Value) !?Field {
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

test "load: a file gate and a row gate that will not combine is refused, naming the row" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Each gate parses alone; the parens the combination adds cost depth, so
    // together they do not. Refusing at evaluation time would name neither
    // the file nor the row.
    const deep = try std.fmt.allocPrint(a, "{s}os=darwin{s}", .{ "(" ** 63, ")" ** 63 });
    _ = try axis.parseString(a, deep);
    const text = try std.fmt.allocPrint(a,
        \\backend = "brew"
        \\when = "{s}"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\when = "profile=work"
        \\
    , .{deep});
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data = text });
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    var d: Diag = .{};
    try testing.expectError(Error.MalformedPackageRow, load(a, io, repo, "", &d));
    const msg = d.capture().?;
    try testing.expect(std.mem.indexOf(u8, msg, "data/packages/a.toml") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "row \"ripgrep\"") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "do not combine into a valid axis expression") != null);
}

test "load: a bootstrap row whose gate will not combine with the file's is refused by row" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const deep = try std.fmt.allocPrint(a, "{s}os=darwin{s}", .{ "(" ** 63, ")" ** 63 });
    const text = try std.fmt.allocPrint(a,
        \\backend = "brew"
        \\when = "{s}"
        \\
        \\[[bootstrap]]
        \\url = "https://example.invalid/install.sh"
        \\sha256 = "{s}"
        \\when = "profile=work"
        \\
    , .{ deep, "0" ** 64 });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data = text });
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    var d: Diag = .{};
    try testing.expectError(Error.MalformedPackageRow, load(a, io, repo, "", &d));
    const msg = d.capture().?;
    try testing.expect(std.mem.indexOf(u8, msg, "data/packages/a.toml") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "bootstrap row 0 for backend \"brew\"") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "do not combine into a valid axis expression") != null);
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

test "load: a file-level when gates every row, narrowed by a row's own" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/darwin.toml", .data =
        \\backend = "brew"
        \\when = "os=darwin"
        \\
        \\[[bootstrap]]
        \\url = "https://example.invalid/i.sh"
        \\sha256 = "00"
        \\
        \\[[packages]]
        \\name = "ripgrep"
        \\
        \\[[packages]]
        \\name = "steam"
        \\when = "profile=personal"
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    const m = try load(a, io, repo, "", null);
    try testing.expectEqualStrings("os=darwin", m.packages[0].when.?);
    try testing.expectEqualStrings("(os=darwin) and (profile=personal)", m.packages[1].when.?);
    // The installer inherits the gate too: a mac's Homebrew installer must
    // never run on a Linux machine reading the same manifest.
    try testing.expectEqualStrings("os=darwin", m.bootstrap[0].when.?);
}

test "load: blacklist rows parse with no fields" {
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

test "load: an empty manifest directory is in use" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    // Creating the directory is the opt-in, before any file is written:
    // everything installed is then genuinely untracked.
    const m = try load(a, io, repo, "", null);
    try testing.expect(m.inUse());
    try testing.expectEqual(@as(usize, 0), m.files);
    try testing.expectEqual(@as(usize, 0), m.packages.len);
}

test "load: a private-layer directory alone opts in" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.createDirPath(io, "private/data/packages");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");
    const priv = try tmpAbs(a, io, &tmp.sub_path, "private");

    const m = try load(a, io, repo, priv, null);
    try testing.expect(m.inUse());
}

test "load: a data/packages that is a file is named, not a raw error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages", .data = "" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    var d: Diag = .{};
    try testing.expectError(error.NotDir, load(a, io, repo, "", &d));
    try testing.expect(std.mem.startsWith(u8, d.capture().?, "data/packages: not a directory"));
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

test "load: editor and OS junk ending in .toml is not read as a manifest" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest; // no symlinks to create
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
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");
    const dir = try std.fs.path.join(a, &.{ repo, "data", "packages" });

    // An open emacs buffer leaves a dangling lock symlink; a copy off a mac
    // leaves an AppleDouble. Both end in `.toml` and neither is one.
    try Io.Dir.cwd().symLink(io, "user@host.4242:1", try std.fs.path.join(a, &.{ dir, ".#darwin.toml" }), .{});
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(a, &.{ dir, "._darwin.toml" }),
        .data = "\x00\x05\x16\x07\x00\x02\x00\x00Mac OS X",
    });

    var d: Diag = .{};
    const m = try load(a, io, repo, "", &d);
    try testing.expectEqual(@as(usize, 1), m.files);
    try testing.expectEqual(@as(usize, 1), m.packages.len);
    try testing.expectEqualStrings("ripgrep", m.packages[0].name);
    try testing.expect(d.capture() == null);
}

test "load: a blacklist row in a file carrying a top-level when is refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/darwin.toml", .data =
        \\backend = "brew"
        \\when = "os=darwin"
        \\
        \\[[blacklist]]
        \\name = "usage"
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    var d: Diag = .{};
    try testing.expectError(Error.MalformedPackageRow, load(a, io, repo, "", &d));
    try testing.expectEqualStrings(
        "data/packages/darwin.toml: blacklist row 0: this file has a top-level \"when\", which would gate it; a blacklist holds regardless of which machine asks, so it belongs in a file with no \"when\"",
        d.capture().?,
    );
}

test "load: a fault in a private file names the private layer, not the repo file it shadows" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const good = "backend = \"brew\"\n\n[[packages]]\nname = \"ripgrep\"\n";

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "repo/data/packages");
        try tmp.dir.createDirPath(io, "private/data/packages");
        try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/darwin.toml", .data = good });
        try tmp.dir.writeFile(io, .{ .sub_path = "private/data/packages/darwin.toml", .data = "[[package]]\nname = \"ripgrep\"\n" });
        const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");
        const priv = try tmpAbs(a, io, &tmp.sub_path, "private");

        var d: Diag = .{};
        try testing.expectError(Error.MalformedPackageFile, load(a, io, repo, priv, &d));
        try testing.expectEqualStrings(
            "data/packages/darwin.toml (private layer): unknown top-level key \"package\" (a manifest file takes \"backend\", \"when\", \"packages\", \"blacklist\", \"bootstrap\")",
            d.capture().?,
        );
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "repo/data/packages");
        try tmp.dir.createDirPath(io, "private/data/packages");
        try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/darwin.toml", .data = good });
        try tmp.dir.writeFile(io, .{ .sub_path = "private/data/packages/local.toml", .data = "backend = \"brew\"\n\n[[packages]]\nname = \"rip grep\"\n" });
        const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");
        const priv = try tmpAbs(a, io, &tmp.sub_path, "private");

        var d: Diag = .{};
        try testing.expectError(Error.MalformedPackageRow, load(a, io, repo, priv, &d));
        try testing.expectEqualStrings(
            "data/packages/local.toml (private layer): row 0: \"name\" must not be blank or contain whitespace, control characters, or bytes that are not UTF-8, and must be at most 256 bytes",
            d.capture().?,
        );
    }

    if (!Io.File.Permissions.has_executable_bit) return; // no symlinks to create
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "repo/data/packages");
        try tmp.dir.createDirPath(io, "private/data/packages");
        try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/darwin.toml", .data = good });
        const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");
        const priv = try tmpAbs(a, io, &tmp.sub_path, "private");
        // The private file shadows an intact repo file of the same basename.
        try Io.Dir.cwd().symLink(io, "gone.toml", try std.fs.path.join(a, &.{ priv, "data", "packages", "darwin.toml" }), .{});

        var d: Diag = .{};
        try testing.expectError(Error.MalformedPackageFile, load(a, io, repo, priv, &d));
        try testing.expectEqualStrings(
            "data/packages/darwin.toml (private layer): unreadable: FileNotFound",
            d.capture().?,
        );
    }
}

test "load: a bootstrap row missing a key is named by its index, not by its backend alone" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data =
        \\backend = "brew"
        \\
        \\[[bootstrap]]
        \\url = "https://example.invalid/i.sh"
        \\sha256 = "00"
        \\
        \\[[bootstrap]]
        \\sha256 = "00"
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    var d: Diag = .{};
    try testing.expectError(Error.MalformedPackageRow, load(a, io, repo, "", &d));
    try testing.expectEqualStrings(
        "data/packages/a.toml: bootstrap row 1 for backend \"brew\" has no \"url\"",
        d.capture().?,
    );
}

test "load: a byte order mark is named as the cause, not a bare parse error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data = utf8_bom ++ "backend = \"brew\"\n" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    var d: Diag = .{};
    try testing.expectError(Error.MalformedPackageFile, load(a, io, repo, "", &d));
    try testing.expectEqualStrings(
        "data/packages/a.toml: begins with a byte order mark; save the file without one",
        d.capture().?,
    );
}

test "load: an unknown top-level key is refused, so [[package]] cannot load as zero rows" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data =
        \\backend = "brew"
        \\
        \\[[package]]
        \\name = "ripgrep"
        \\
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

    var d: Diag = .{};
    try testing.expectError(Error.MalformedPackageFile, load(a, io, repo, "", &d));
    try testing.expectEqualStrings(
        "data/packages/a.toml: unknown top-level key \"package\" (a manifest file takes \"backend\", \"when\", \"packages\", \"blacklist\", \"bootstrap\")",
        d.capture().?,
    );
}

test "load: a blank name, or one with whitespace or a control character, is refused by file and row" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Written as TOML escapes: a raw control byte is refused by the parser
    // before the row is ever built, which is a different error.
    for ([_][]const u8{ " ", "rip grep", "ripgrep\\t", "rip\\u0001grep" }) |name| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "repo/data/packages");
        const body = try std.fmt.allocPrint(a, "backend = \"brew\"\n\n[[packages]]\nname = \"ok\"\n\n[[packages]]\nname = \"{s}\"\n", .{name});
        try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data = body });
        const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");

        var d: Diag = .{};
        try testing.expectError(Error.MalformedPackageRow, load(a, io, repo, "", &d));
        try testing.expectEqualStrings(
            "data/packages/a.toml: row 1: \"name\" must not be blank or contain whitespace, control characters, or bytes that are not UTF-8, and must be at most 256 bytes",
            d.capture().?,
        );
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/data/packages/a.toml", .data = "backend = \"brew\"\n\n[[blacklist]]\nname = \" \"\n" });
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");
    var d: Diag = .{};
    try testing.expectError(Error.MalformedPackageRow, load(a, io, repo, "", &d));
    try testing.expectEqualStrings(
        "data/packages/a.toml: blacklist row 0: \"name\" must not be blank or contain whitespace, control characters, or bytes that are not UTF-8, and must be at most 256 bytes",
        d.capture().?,
    );
}

test "load: an unreadable data/packages directory is named" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/data/packages");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try tmpAbs(a, io, &tmp.sub_path, "repo");
    const dir_path = try std.fs.path.join(a, &.{ repo, "data", "packages" });
    try Io.Dir.cwd().setFilePermissions(io, dir_path, Io.File.Permissions.fromMode(0o000), .{});
    defer Io.Dir.cwd().setFilePermissions(io, dir_path, Io.File.Permissions.fromMode(0o755), .{}) catch {};

    var d: Diag = .{};
    const got = load(a, io, repo, "", &d);
    // root opens anything; the check is about the wording when the open fails.
    if (got) |_| return error.SkipZigTest else |e| {
        try testing.expectEqual(error.AccessDenied, e);
        const want = try std.fmt.allocPrint(a, "data/packages: cannot open {s}: AccessDenied", .{dir_path});
        try testing.expectEqualStrings(want, d.capture().?);
    }
}

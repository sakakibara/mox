const std = @import("std");
const cli = @import("cli");
const app = @import("app.zig");
const mox = @import("../root.zig");

const Io = std.Io;

pub const Outcome = enum {
    added,
    not_found,
    outside_home,
    is_home,
    is_directory,
    already_managed,
    into_overlay_dir,
    /// The target's source head declares ownership: it is managed per
    /// key-path, so a whole-file add would contradict the contract.
    partial_target,
};

/// True when the target key names a file directly inside a `<base>.d/` overlay
/// directory (its parent segment ends in `.d`). mox reserves those directories
/// for axis overlays and fragments, so writing a captured file there would make
/// the tree walk misread it as an overlay of `<base>` -- refuse instead.
fn intoOverlayDir(key: []const u8) bool {
    const parent = std.fs.path.dirnamePosix(key) orelse return false;
    const last = std.fs.path.basenamePosix(parent);
    return std.mem.endsWith(u8, last, ".d");
}

pub const Result = struct {
    outcome: Outcome,
    /// Absolute source path (valid for `.added` and `.already_managed`).
    src_path: []const u8 = "",
};

/// True when `live_path` names HOME itself (ignoring a trailing separator),
/// which `relUnder` reports as null just like a path outside HOME.
fn isHomeItself(live_path: []const u8, home: []const u8) bool {
    const l = std.mem.trimEnd(u8, live_path, "/\\");
    const h = std.mem.trimEnd(u8, home, "/\\");
    return std.mem.eql(u8, l, h);
}

/// Copy one live file into `src/` as a base file. Returns an Outcome the
/// caller renders. Junk filtering and recursion are the caller's concern (see
/// add-tree). A mode git cannot carry (not 0644/0755) is recorded in
/// `.mox/attributes.toml` so it survives a clone. A live symlink is captured as
/// a regular source file whose content is the link target, flagged there too.
/// `seed_once` records the explicit seed-once intent for this target.
pub fn addFile(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    home: []const u8,
    live_path: []const u8,
    seed_once: bool,
) !Result {
    // lstat, not stat: a live symlink is captured as such, never followed.
    const st = Io.Dir.cwd().statFile(io, live_path, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return .{ .outcome = .not_found },
        else => return e,
    };
    // Single-file add refuses a directory (use add-tree to recurse); reading one
    // would otherwise surface a raw IsDir error.
    if (st.kind == .directory) return .{ .outcome = .is_directory };

    // Boundary-aware home membership, matching the attribute key derivation
    // (relUnder): a raw startsWith would let `/home/me` swallow `/home/meadow`,
    // and the recorded key and the add path would then disagree. `relUnder`
    // returns null for HOME itself, so detect that separately.
    const trimmed = if (try mox.source.path.liveKeyUnderHome(arena, home, live_path)) |rel|
        rel
    else if (isHomeItself(live_path, home))
        return .{ .outcome = .is_home }
    else
        return .{ .outcome = .outside_home };

    // A key with a `..` segment (relUnder matches HOME textually and does not
    // normalize) would resolve outside src/ once joined -- refuse the escape.
    if (mox.source.path.keyEscapes(trimmed)) return .{ .outcome = .outside_home };
    // A file inside a `<base>.d/` directory would be misread as an overlay.
    if (intoOverlayDir(trimmed)) return .{ .outcome = .into_overlay_dir };

    const src_path = try std.fs.path.join(arena, &.{ repo_dir, "src", trimmed });

    if (Io.Dir.cwd().access(io, src_path, .{})) |_| {
        // A source head declaring ownership means the target is partially
        // owned; a whole-file capture of it would sweep the program's
        // region into the source.
        if (try sourceDeclaresOwnership(arena, io, src_path, trimmed)) {
            return .{ .outcome = .partial_target, .src_path = src_path };
        }
        return .{ .outcome = .already_managed, .src_path = src_path };
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }

    if (std.fs.path.dirname(src_path)) |parent| {
        Io.Dir.cwd().createDirPath(io, parent) catch {};
    }

    // A live symlink: write its target string as the source content (a regular
    // file, so no symlink enters the repo) and record `symlink = true`.
    if (st.kind == .sym_link) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try Io.Dir.cwd().readLink(io, live_path, &buf);
        try mox.apply.write.writeAtomic(io, src_path, buf[0..n], 0o644);
        try recordAttrs(arena, io, repo_dir, home, live_path, .{ .symlink = true, .seed_once = seed_once });
        return .{ .outcome = .added, .src_path = src_path };
    }

    const content = try Io.Dir.cwd().readFileAlloc(io, live_path, arena, .limited(64 * 1024 * 1024));
    // Write the source with the live file's mode so git carries the exec bit
    // (100755) natively -- otherwise an added executable would land at the
    // umask default and lose +x on the next clone.
    const mode = mox.apply.write.modeOf(st.permissions);
    try mox.apply.write.writeAtomic(io, src_path, content, mode);

    // Record whatever git cannot carry: a mode that is not 0644/0755 (those
    // travel via git+stat), and the explicit seed-once intent. Keyed by the
    // portable home-relative key, never the native path.
    const recorded_mode: ?u32 = if (mode != 0o644 and mode != 0o755) mode else null;
    try recordAttrs(arena, io, repo_dir, home, live_path, .{ .mode = recorded_mode, .seed_once = seed_once });
    return .{ .outcome = .added, .src_path = src_path };
}

/// True when the managed source at `src_path` declares partial ownership in
/// its head. A malformed head reads as declared: the walk refuses it anyway,
/// and a whole-file add over it must not proceed.
fn sourceDeclaresOwnership(arena: std.mem.Allocator, io: Io, src_path: []const u8, key: []const u8) !bool {
    const format = mox.source.format.formatOfPath(key) orelse return false;
    const content = Io.Dir.cwd().readFileAlloc(io, src_path, arena, .limited(64 * 1024 * 1024)) catch return false;
    const parsed = mox.source.head.parse(arena, content, mox.source.tree.markerForFormat(format)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return true,
    };
    return parsed.ownership != .none;
}

/// Merge `fields` into the target's `.mox/attributes.toml` entry (loading the
/// existing record so a mode/symlink/seed-once capture never clobbers another),
/// then persist. A no-op when `fields` records nothing.
fn recordAttrs(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    home: []const u8,
    live_path: []const u8,
    fields: mox.source.attributes.Entry,
) !void {
    if (fields.mode == null and !fields.symlink and !fields.seed_once) return;
    const key = try mox.source.path.liveKeyRelToHome(arena, home, live_path);
    var attrs = try mox.source.attributes.load(arena, io, repo_dir);
    var entry = attrs.lookup(key) orelse mox.source.attributes.Entry{};
    if (fields.mode) |m| entry.mode = m;
    if (fields.symlink) entry.symlink = true;
    if (fields.seed_once) entry.seed_once = true;
    try attrs.set(key, entry);
    try attrs.write(io, repo_dir);
}

pub const OwnOutcome = enum {
    added,
    not_found,
    outside_home,
    is_home,
    is_directory,
    is_symlink,
    already_managed,
    into_overlay_dir,
    not_structured,
    invalid_path,
    extract_failed,
};

pub const OwnResult = struct {
    outcome: OwnOutcome,
    /// Absolute source path (valid for `.added` and `.already_managed`).
    src_path: []const u8 = "",
    /// Names the offending path or extraction failure for the error outcomes.
    detail: []const u8 = "",
    /// Top-level live entries outside the declaration (valid for `.added`).
    unowned_top: usize = 0,
};

/// Take partial ownership of a live file: extract the declared paths' raw
/// byte spans into a new source file (comments inside owned content survive
/// verbatim), prefixed with `mox: own` head directives so the declaration
/// and the content are created together in one file, and report what
/// remains the program's. Content paths must be present live; `absent_raws`
/// declare enforced absence and contribute no content.
pub fn addOwnFile(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    home: []const u8,
    live_path: []const u8,
    own_raws: []const []const u8,
    absent_raws: []const []const u8,
) !OwnResult {
    const st = Io.Dir.cwd().statFile(io, live_path, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return .{ .outcome = .not_found },
        else => return e,
    };
    if (st.kind == .directory) return .{ .outcome = .is_directory };
    // Partial ownership patches a document in place; a symlinked live file
    // has no document of its own to patch.
    if (st.kind == .sym_link) return .{ .outcome = .is_symlink };

    const trimmed = if (try mox.source.path.liveKeyUnderHome(arena, home, live_path)) |rel|
        rel
    else if (isHomeItself(live_path, home))
        return .{ .outcome = .is_home }
    else
        return .{ .outcome = .outside_home };
    if (mox.source.path.keyEscapes(trimmed)) return .{ .outcome = .outside_home };
    if (intoOverlayDir(trimmed)) return .{ .outcome = .into_overlay_dir };

    const format = mox.source.format.formatOfPath(trimmed) orelse return .{ .outcome = .not_structured };

    const src_path = try std.fs.path.join(arena, &.{ repo_dir, "src", trimmed });
    if (Io.Dir.cwd().access(io, src_path, .{})) |_| {
        return .{ .outcome = .already_managed, .src_path = src_path };
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }

    const partial = mox.apply.partial;
    var bad_raw: []const u8 = "";
    const content_paths = parseOwnRaws(arena, own_raws, &bad_raw) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidOwnPath => return .{ .outcome = .invalid_path, .detail = bad_raw },
    };
    const absent_paths = parseOwnRaws(arena, absent_raws, &bad_raw) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidOwnPath => return .{ .outcome = .invalid_path, .detail = bad_raw },
    };
    const all_paths = try std.mem.concat(arena, mox.source.tree.OwnPath, &.{ content_paths, absent_paths });

    const live = try Io.Dir.cwd().readFileAlloc(io, live_path, arena, .limited(64 * 1024 * 1024));

    var diag: partial.Diag = .{};
    const extracted = partial.extractOwnedSource(arena, format, live, content_paths, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .outcome = .extract_failed, .detail = try arena.dupe(u8, diag.text()) },
    };

    // The extracted text must parse, lie entirely within the declaration,
    // and reproduce the live owned content exactly (canonical-byte), or the
    // capture is refused with nothing written.
    const doc = partial.OwnedDoc.parse(arena, format, extracted) catch {
        return .{ .outcome = .extract_failed, .detail = "extracted source does not parse" };
    };
    if (try partial.undeclaredLeaf(arena, &doc, all_paths)) |leaf| {
        return .{
            .outcome = .extract_failed,
            .detail = try std.fmt.allocPrint(arena, "extracted leaf {s} falls outside the declaration", .{leaf}),
        };
    }
    const live_doc = partial.OwnedDoc.parse(arena, format, live) catch {
        return .{ .outcome = .extract_failed, .detail = "live file does not parse" };
    };
    const want = try mox.apply.canonical.canonicalOwned(arena, &live_doc, content_paths);
    const got = try mox.apply.canonical.canonicalOwned(arena, &doc, content_paths);
    if (!std.mem.eql(u8, want, got)) {
        return .{ .outcome = .extract_failed, .detail = "extracted source does not reproduce the live owned content" };
    }

    if (std.fs.path.dirname(src_path)) |parent| {
        Io.Dir.cwd().createDirPath(io, parent) catch {};
    }
    const mode = mox.apply.write.modeOf(st.permissions);
    const own_list = try std.mem.concat(arena, []const u8, &.{ own_raws, absent_raws });
    const source_text = try std.mem.concat(arena, u8, &.{
        try headDirectiveLines(arena, format, "own", own_list),
        extracted,
    });
    try mox.apply.write.writeAtomic(io, src_path, source_text, mode);

    const recorded_mode: ?u32 = if (mode != 0o644 and mode != 0o755) mode else null;
    try recordAttrs(arena, io, repo_dir, home, live_path, .{ .mode = recorded_mode });

    return .{
        .outcome = .added,
        .src_path = src_path,
        .unowned_top = partial.unownedTopLevelCount(&live_doc, all_paths),
    };
}

/// The head-directive lines declaring `list` under `keyword` (`own` or
/// `disown`), in the format's comment marker.
fn headDirectiveLines(
    arena: std.mem.Allocator,
    format: mox.source.format.Format,
    keyword: []const u8,
    list: []const []const u8,
) ![]const u8 {
    const marker = mox.source.tree.markerForFormat(format);
    var out: std.ArrayList(u8) = .empty;
    for (list) |raw| {
        try out.appendSlice(arena, marker);
        try out.appendSlice(arena, " mox: ");
        try out.appendSlice(arena, keyword);
        try out.append(arena, ' ');
        try out.appendSlice(arena, raw);
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

/// Take DISOWNED ownership of a live file: the whole live file minus the
/// declared paths' raw byte spans becomes the source (comments outside the
/// spans survive verbatim), prefixed with `mox: disown` head directives.
/// Every declared path must be present live: disowning nothing is a typo,
/// not a contract.
pub fn addDisownFile(
    arena: std.mem.Allocator,
    io: Io,
    repo_dir: []const u8,
    home: []const u8,
    live_path: []const u8,
    disown_raws: []const []const u8,
) !OwnResult {
    const st = Io.Dir.cwd().statFile(io, live_path, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return .{ .outcome = .not_found },
        else => return e,
    };
    if (st.kind == .directory) return .{ .outcome = .is_directory };
    if (st.kind == .sym_link) return .{ .outcome = .is_symlink };

    const trimmed = if (try mox.source.path.liveKeyUnderHome(arena, home, live_path)) |rel|
        rel
    else if (isHomeItself(live_path, home))
        return .{ .outcome = .is_home }
    else
        return .{ .outcome = .outside_home };
    if (mox.source.path.keyEscapes(trimmed)) return .{ .outcome = .outside_home };
    if (intoOverlayDir(trimmed)) return .{ .outcome = .into_overlay_dir };

    const format = mox.source.format.formatOfPath(trimmed) orelse return .{ .outcome = .not_structured };

    const src_path = try std.fs.path.join(arena, &.{ repo_dir, "src", trimmed });
    if (Io.Dir.cwd().access(io, src_path, .{})) |_| {
        return .{ .outcome = .already_managed, .src_path = src_path };
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }

    const partial = mox.apply.partial;
    var bad_raw: []const u8 = "";
    const paths = parseOwnRaws(arena, disown_raws, &bad_raw) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidOwnPath => return .{ .outcome = .invalid_path, .detail = bad_raw },
    };

    const live = try Io.Dir.cwd().readFileAlloc(io, live_path, arena, .limited(64 * 1024 * 1024));
    var diag: partial.Diag = .{};
    const loc = partial.locateSpans(arena, format, live, paths, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .outcome = .extract_failed, .detail = try arena.dupe(u8, diag.text()) },
    };
    for (paths, loc.spans) |p, span| {
        if (span == null) {
            return .{
                .outcome = .extract_failed,
                .detail = try std.fmt.allocPrint(arena, "{s}: not present in the live file", .{p.raw}),
            };
        }
    }
    const body = try partial.textWithoutSpans(arena, live, loc);

    // The remainder must parse, define nothing under the declaration, and
    // reproduce the live owned complement exactly (canonical-byte), or the
    // capture is refused with nothing written.
    const doc = partial.OwnedDoc.parse(arena, format, body) catch {
        return .{ .outcome = .extract_failed, .detail = "extracted source does not parse" };
    };
    if (try partial.populatedDisownPath(arena, &doc, paths)) |spelled| {
        return .{
            .outcome = .extract_failed,
            .detail = try std.fmt.allocPrint(arena, "extracted source still defines {s}", .{spelled}),
        };
    }
    const live_doc = partial.OwnedDoc.parse(arena, format, live) catch {
        return .{ .outcome = .extract_failed, .detail = "live file does not parse" };
    };
    const want = try mox.apply.canonical.canonicalComplement(arena, &live_doc, paths);
    const got = try mox.apply.canonical.canonicalComplement(arena, &doc, paths);
    if (!std.mem.eql(u8, want, got)) {
        return .{ .outcome = .extract_failed, .detail = "extracted source does not reproduce the live owned content" };
    }

    if (std.fs.path.dirname(src_path)) |parent| {
        Io.Dir.cwd().createDirPath(io, parent) catch {};
    }
    const mode = mox.apply.write.modeOf(st.permissions);
    const source_text = try std.mem.concat(arena, u8, &.{
        try headDirectiveLines(arena, format, "disown", disown_raws),
        body,
    });
    try mox.apply.write.writeAtomic(io, src_path, source_text, mode);

    const recorded_mode: ?u32 = if (mode != 0o644 and mode != 0o755) mode else null;
    try recordAttrs(arena, io, repo_dir, home, live_path, .{ .mode = recorded_mode });

    return .{ .outcome = .added, .src_path = src_path };
}

fn parseOwnRaws(
    arena: std.mem.Allocator,
    raws: []const []const u8,
    bad: *[]const u8,
) error{ OutOfMemory, InvalidOwnPath }![]mox.source.tree.OwnPath {
    const out = try arena.alloc(mox.source.tree.OwnPath, raws.len);
    for (raws, out) |raw, *o| {
        const segments = mox.source.keypath.parse(arena, raw) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                bad.* = raw;
                return error.InvalidOwnPath;
            },
        };
        o.* = .{ .raw = raw, .segments = segments };
    }
    return out;
}

const Spec = struct {
    path: cli.spec.Pos([]const u8, .{ .help = "live file to start managing" }),
    seed_once: cli.spec.Flag(.{ .help = "seed the target once; never overwrite an existing one" }),
    force: cli.spec.Flag(.{ .help = "add even if the path matches an ignore rule" }),
    own: cli.spec.Opt([]const u8, .{ .value_name = "key-path", .help = "manage only this key-path of the live file (repeatable)" }),
    own_absent: cli.spec.Opt([]const u8, .{ .value_name = "key-path", .help = "declare a key-path mox enforces as absent (repeatable)" }),
    disown: cli.spec.Opt([]const u8, .{ .value_name = "key-path", .help = "manage the whole file except this key-path (repeatable)" }),
};

/// Every value the repeated `--<long>` option was given, in command-line
/// order. cli-zig options are last-wins; the `own` declaration is a list, so
/// the values are collected from the command's own argv (the Spec still
/// declares the option for parsing, help, and completion).
fn collectRepeated(alloc: std.mem.Allocator, argv: []const []const u8, long: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const t = argv[i];
        if (!std.mem.startsWith(u8, t, "--")) continue;
        const body = t[2..];
        if (std.mem.eql(u8, body, long)) {
            if (i + 1 < argv.len) {
                try out.append(alloc, argv[i + 1]);
                i += 1;
            }
        } else if (body.len > long.len and body[long.len] == '=' and std.mem.startsWith(u8, body, long)) {
            try out.append(alloc, body[long.len + 1 ..]);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const context = ctx.context.?;
    const live_path = a.path;
    const home = context.env.getAlloc(ctx.alloc, "HOME") catch {
        try ctx.err.writeAll("mox add: HOME not set\n");
        return 1;
    };

    if (!a.force) {
        const m_state = try mox.machine.state.capture(ctx.alloc, ctx.io, context.env);
        var bindings = try mox.machine.bindings.fromMachineState(ctx.alloc, m_state);
        const ruleset = try mox.source.ignore.load.load(ctx.alloc, ctx.io, context.paths.repo_dir, &bindings, &m_state);
        const rel = try mox.source.path.liveKeyRelToHome(ctx.alloc, home, live_path);
        const is_dir = if (Io.Dir.cwd().statFile(ctx.io, live_path, .{ .follow_symlinks = false })) |st|
            st.kind == .directory
        else |_|
            false;
        if (ruleset.isPathIgnored(rel, is_dir)) {
            try ctx.err.print("mox add: {s} matches an ignore rule; use --force to add it anyway\n", .{rel});
            return 1;
        }
    }

    const own_raws = try collectRepeated(ctx.alloc, ctx.argv, "own");
    const absent_raws = try collectRepeated(ctx.alloc, ctx.argv, "own-absent");
    const disown_raws = try collectRepeated(ctx.alloc, ctx.argv, "disown");
    if (disown_raws.len > 0 and (own_raws.len > 0 or absent_raws.len > 0)) {
        try ctx.err.writeAll("mox add: --disown cannot combine with --own/--own-absent (own and disown are exclusive per file)\n");
        return 1;
    }
    if (own_raws.len > 0 or absent_raws.len > 0 or disown_raws.len > 0) {
        if (a.seed_once) {
            try ctx.err.writeAll("mox add: --own/--disown cannot combine with --seed-once (a seed-once target is never re-composed)\n");
            return 1;
        }
        if (disown_raws.len > 0) return runDisown(ctx, home, live_path, disown_raws);
        return runOwn(ctx, home, live_path, own_raws, absent_raws);
    }

    const result = try addFile(ctx.alloc, ctx.io, context.paths.repo_dir, home, live_path, a.seed_once);
    switch (result.outcome) {
        .added => {
            try ctx.out.print("Added {s} -> {s}\n", .{ live_path, result.src_path });
            if (mox.source.ignore.load.looksLikeSecret(std.fs.path.basename(live_path))) {
                try ctx.out.print("  note: {s} looks like a secret and will be committed\n", .{live_path});
            }
            // Rebuild the coupling graph so the new file's tokens can couple
            // with existing sources on the next commit.
            buildInitialCoupling(ctx) catch {};
            return 0;
        },
        .not_found => {
            try ctx.err.print("mox add: {s}: not found\n", .{live_path});
            return 1;
        },
        .outside_home => {
            try ctx.err.print("mox add: {s}: outside HOME ({s})\n", .{ live_path, home });
            return 1;
        },
        .is_home => {
            try ctx.err.writeAll("mox add: cannot add HOME itself\n");
            return 1;
        },
        .is_directory => {
            try ctx.err.print("mox add: {s}: is a directory (use 'mox add-tree' to add its contents)\n", .{live_path});
            return 1;
        },
        .already_managed => {
            try ctx.err.print("mox add: {s}: already managed (source at {s})\n", .{ live_path, result.src_path });
            return 1;
        },
        .into_overlay_dir => {
            try ctx.err.print("mox add: {s}: sits in a '.d/' overlay directory, which mox reserves for axis overlays\n", .{live_path});
            return 1;
        },
        .partial_target => {
            try ctx.err.print("mox add: {s}: partially owned (its source head declares ownership); edit the source, or remove the declaration first\n", .{live_path});
            return 1;
        },
    }
}

/// The `mox add --own` flow: extract, validate, record, report.
fn runOwn(
    ctx: *app.Ctx,
    home: []const u8,
    live_path: []const u8,
    own_raws: []const []const u8,
    absent_raws: []const []const u8,
) anyerror!u8 {
    const context = ctx.context.?;
    const r = try addOwnFile(ctx.alloc, ctx.io, context.paths.repo_dir, home, live_path, own_raws, absent_raws);
    switch (r.outcome) {
        .added => {
            try ctx.out.print("Added {s} -> {s} (own: {d} key-path(s))\n", .{ live_path, r.src_path, own_raws.len + absent_raws.len });
            if (r.unowned_top > 0) {
                try ctx.out.print("  {d} top-level live entr{s} remain{s} unowned (the program's region)\n", .{
                    r.unowned_top,
                    @as([]const u8, if (r.unowned_top == 1) "y" else "ies"),
                    @as([]const u8, if (r.unowned_top == 1) "s" else ""),
                });
            }
            buildInitialCoupling(ctx) catch {};
            return 0;
        },
        .not_found => {
            try ctx.err.print("mox add: {s}: not found\n", .{live_path});
            return 1;
        },
        .outside_home => {
            try ctx.err.print("mox add: {s}: outside HOME ({s})\n", .{ live_path, home });
            return 1;
        },
        .is_home => {
            try ctx.err.writeAll("mox add: cannot add HOME itself\n");
            return 1;
        },
        .is_directory => {
            try ctx.err.print("mox add: {s}: is a directory\n", .{live_path});
            return 1;
        },
        .is_symlink => {
            try ctx.err.print("mox add: {s}: is a symlink; --own patches a document in place\n", .{live_path});
            return 1;
        },
        .already_managed => {
            try ctx.err.print("mox add: {s}: already managed (source at {s})\n", .{ live_path, r.src_path });
            return 1;
        },
        .into_overlay_dir => {
            try ctx.err.print("mox add: {s}: sits in a '.d/' overlay directory, which mox reserves for axis overlays\n", .{live_path});
            return 1;
        },
        .not_structured => {
            try ctx.err.print("mox add: {s}: --own requires a structured target (toml/json/yaml/ini/gitconfig)\n", .{live_path});
            return 1;
        },
        .invalid_path => {
            try ctx.err.print("mox add: {s}: own path does not parse as a dotted key path\n", .{r.detail});
            return 1;
        },
        .extract_failed => {
            try ctx.err.print("mox add: {s}: cannot extract the declared paths: {s}\n", .{ live_path, r.detail });
            return 1;
        },
    }
}

/// The `mox add --disown` flow: extract the complement, validate, report.
fn runDisown(
    ctx: *app.Ctx,
    home: []const u8,
    live_path: []const u8,
    disown_raws: []const []const u8,
) anyerror!u8 {
    const context = ctx.context.?;
    const r = try addDisownFile(ctx.alloc, ctx.io, context.paths.repo_dir, home, live_path, disown_raws);
    switch (r.outcome) {
        .added => {
            try ctx.out.print("Added {s} -> {s} (disown: {d} key-path(s) left to the program)\n", .{ live_path, r.src_path, disown_raws.len });
            buildInitialCoupling(ctx) catch {};
            return 0;
        },
        .not_found => {
            try ctx.err.print("mox add: {s}: not found\n", .{live_path});
            return 1;
        },
        .outside_home => {
            try ctx.err.print("mox add: {s}: outside HOME ({s})\n", .{ live_path, home });
            return 1;
        },
        .is_home => {
            try ctx.err.writeAll("mox add: cannot add HOME itself\n");
            return 1;
        },
        .is_directory => {
            try ctx.err.print("mox add: {s}: is a directory\n", .{live_path});
            return 1;
        },
        .is_symlink => {
            try ctx.err.print("mox add: {s}: is a symlink; --disown patches a document in place\n", .{live_path});
            return 1;
        },
        .already_managed => {
            try ctx.err.print("mox add: {s}: already managed (source at {s})\n", .{ live_path, r.src_path });
            return 1;
        },
        .into_overlay_dir => {
            try ctx.err.print("mox add: {s}: sits in a '.d/' overlay directory, which mox reserves for axis overlays\n", .{live_path});
            return 1;
        },
        .not_structured => {
            try ctx.err.print("mox add: {s}: --disown requires a structured target (toml/json/yaml/ini/gitconfig)\n", .{live_path});
            return 1;
        },
        .invalid_path => {
            try ctx.err.print("mox add: {s}: disown path does not parse as a dotted key path\n", .{r.detail});
            return 1;
        },
        .extract_failed => {
            try ctx.err.print("mox add: {s}: cannot extract the owned complement: {s}\n", .{ live_path, r.detail });
            return 1;
        },
    }
}

pub const command = app.command(Spec, .{
    .name = "add",
    .summary = "Start managing a live file as a base file in src/",
    .usage = "mox add [--seed-once] [--own <key-path>]... [--own-absent <key-path>]... [--disown <key-path>]... <path>",
    .group = .general,
    .needs_context = true,
}, run);

const testing = std.testing;

test "addFile: a directory is rejected with is_directory, not a raw error" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const home = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "home" });
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    try tmp.dir.createDirPath(io, "home/adir");
    const adir = try std.fs.path.join(a, &.{ home, "adir" });

    const r = try addFile(a, io, repo, home, adir, false);
    try testing.expectEqual(Outcome.is_directory, r.outcome);

    // A regular file under home still adds.
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.zshrc", .data = "x\n" });
    const afile = try std.fs.path.join(a, &.{ home, ".zshrc" });
    const ok = try addFile(a, io, repo, home, afile, false);
    try testing.expectEqual(Outcome.added, ok.outcome);
}

test "addFile: a sibling dir sharing a home prefix is outside_home, not mis-keyed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    // home is `.../me`; `.../meadow` merely shares the `me` prefix and must not
    // be treated as under home (a raw startsWith would wrongly accept it).
    const home = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "me" });
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    try tmp.dir.createDirPath(io, "meadow");
    try tmp.dir.writeFile(io, .{ .sub_path = "meadow/x", .data = "hi\n" });
    const sibling = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "meadow", "x" });

    const r = try addFile(a, io, repo, home, sibling, false);
    try testing.expectEqual(Outcome.outside_home, r.outcome);
}

test "addFile: a '..' path that escapes the source tree is refused" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    const home = try std.fs.path.join(a, &.{ root, "home" });
    const repo = try std.fs.path.join(a, &.{ root, "repo" });
    // A real file OUTSIDE home, reachable from home only via `..`. home must
    // exist for the kernel to resolve the `..` back down to root/secret.
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.writeFile(io, .{ .sub_path = "secret", .data = "outside\n" });
    const escape = try std.fs.path.join(a, &.{ home, "..", "secret" });

    // The path stats fine (it resolves to root/secret), but its derived key
    // carries `..` and must be refused rather than captured outside src/.
    const r = try addFile(a, io, repo, home, escape, false);
    try testing.expectEqual(Outcome.outside_home, r.outcome);
}

const builtin = @import("builtin");

fn chmod(path: []const u8, mode: u32) void {
    var zbuf: [4096]u8 = undefined;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    _ = std.c.chmod(@ptrCast(&zbuf), @intCast(mode));
}

test "addFile: a restrictive mode is recorded in attributes; 0644/0755 are not" {
    // The captured mode comes from the live file's native bits; a filesystem
    // without them cannot express 0600/0755 and there is nothing to record.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const home = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "home" });
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    // A 0600 live file: its mode is recorded.
    try tmp.dir.createDirPath(io, "home/.ssh");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.ssh/config", .data = "Host x\n" });
    const priv = try std.fs.path.join(a, &.{ home, ".ssh", "config" });
    chmod(priv, 0o600);
    try testing.expectEqual(Outcome.added, (try addFile(a, io, repo, home, priv, false)).outcome);

    // A 0755 live file: git+stat carry it, so nothing is recorded.
    try tmp.dir.writeFile(io, .{ .sub_path = "home/tool", .data = "#!/bin/sh\n" });
    const tool = try std.fs.path.join(a, &.{ home, "tool" });
    chmod(tool, 0o755);
    try testing.expectEqual(Outcome.added, (try addFile(a, io, repo, home, tool, false)).outcome);

    // A 0644 live file: nothing to record.
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.zshrc", .data = "x\n" });
    const rc = try std.fs.path.join(a, &.{ home, ".zshrc" });
    chmod(rc, 0o644);
    try testing.expectEqual(Outcome.added, (try addFile(a, io, repo, home, rc, false)).outcome);

    var attrs = try mox.source.attributes.load(a, io, repo);
    try testing.expectEqual(@as(u32, 0o600), attrs.mode(".ssh/config").?);
    try testing.expect(attrs.mode("tool") == null);
    try testing.expect(attrs.mode(".zshrc") == null);
}

test "addFile: --seed-once records seed_once; a plain add does not" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = try std.process.currentPathAlloc(io, a);
    const home = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "home" });
    const repo = try std.fs.path.join(a, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });

    try tmp.dir.createDirPath(io, "home/.config");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.config/app.local", .data = "x\n" });
    const seeded = try std.fs.path.join(a, &.{ home, ".config", "app.local" });
    try testing.expectEqual(Outcome.added, (try addFile(a, io, repo, home, seeded, true)).outcome);

    try tmp.dir.writeFile(io, .{ .sub_path = "home/.zshrc", .data = "x\n" });
    const plain = try std.fs.path.join(a, &.{ home, ".zshrc" });
    try testing.expectEqual(Outcome.added, (try addFile(a, io, repo, home, plain, false)).outcome);

    var attrs = try mox.source.attributes.load(a, io, repo);
    try testing.expect(attrs.seedOnce(".config/app.local"));
    try testing.expect(!attrs.seedOnce(".zshrc"));
}

/// Rebuild and persist the coupling graph over every base source file, keyed by
/// absolute path (matching how `mox commit` and `mox doctor` build it).
fn buildInitialCoupling(ctx: *app.Ctx) !void {
    const context = ctx.context.?;
    const src_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.repo_dir, "src" });
    const tree = mox.source.tree.walk(ctx.alloc, ctx.io, src_dir, "") catch return;
    var inputs: std.ArrayList(mox.coupling.index.FileInput) = .empty;
    for (tree.files) |file| {
        if (!file.has_base or file.source_base_abs.len == 0) continue;
        // A symlink target / seed-once body is never token-synced, so keep it
        // out of the coupling graph entirely (matches doctor's rescanCoupling).
        if (file.is_symlink or file.create_once) continue;
        const content = Io.Dir.cwd().readFileAlloc(ctx.io, file.source_base_abs, ctx.alloc, .limited(64 * 1024 * 1024)) catch continue;
        try inputs.append(ctx.alloc, .{ .id = file.source_base_abs, .content = content });
    }
    var g = try mox.coupling.index.build(ctx.alloc, inputs.items);
    const coupling_dir = try std.fs.path.join(ctx.alloc, &.{ context.paths.state_dir, "coupling" });
    try mox.coupling.store.saveGraph(ctx.alloc, ctx.io, coupling_dir, &g);
}

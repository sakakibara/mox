const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const axis_mod = @import("axis.zig");
const row_expr_mod = @import("row_expr.zig");
const tokens_mod = @import("tokens.zig");

const Token = tokens_mod.Token;

pub const ParseError = error{
    NotALineDirective,
    NotARegionDirective,
    ExpectedKeyword,
    ExpectedString,
    ExpectedIdent,
    ExpectedDataSource,
    RemoveRequiresWhen,
    ExpectedAxisName,
    ExpectedEquals,
    ExpectedAxisValue,
    ExpectedRowAtom,
    ExpectedHasOrEqValue,
    ExpectedFieldRef,
    UnclosedParen,
    ExpressionTooDeep,
    OutOfMemory,
    UnterminatedString,
    UnexpectedCharacter,
    UnexpectedTrailingTokens,
    ReservedLoopVariable,
    IntoOnNestedFor,
    ExpectedShell,
    UnknownShell,
    ReservedAxisName,
    InvalidFactName,
};

/// The fact-name charset a `# mox: default <name>=...` name must satisfy:
/// `[a-z][a-z0-9_]*`, the same charset `source.tuple.isValidAxisName`
/// enforces on axis names and `# mox: needs` enforces on script fact names.
/// Duplicated here (rather than imported) because `dsl` sits below `source`
/// in the module layering and must not depend back up into it.
fn isValidFactName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isLower(name[0])) return false;
    for (name) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    }
    return true;
}

/// Loop-variable names that shadow a fixed interpolation namespace: a frame so
/// named would intercept `<machine.X>` / `<env.X>` / `<data.X>` before the
/// fixed handler. Rejected at parse time. (`entry` is NOT reserved: it is the
/// conventional row variable and collides with nothing -- the legacy `<entry.X>`
/// path and a frame named `entry` resolve to the same record.)
fn isReservedLoopVar(name: []const u8) bool {
    return std.mem.eql(u8, name, "machine") or
        std.mem.eql(u8, name, "env") or
        std.mem.eql(u8, name, "data");
}

const ParserState = struct {
    arena: std.mem.Allocator,
    toks: []const Token,
    pos: usize,

    fn peek(self: *ParserState) *const Token {
        return &self.toks[self.pos];
    }

    fn advance(self: *ParserState) void {
        self.pos += 1;
    }

    fn isKeyword(self: *ParserState, kw: []const u8) bool {
        return switch (self.peek().kind) {
            .keyword => |k| std.mem.eql(u8, k, kw),
            else => false,
        };
    }

    fn expectKeyword(self: *ParserState, kw: []const u8) ParseError!void {
        if (!self.isKeyword(kw)) return error.ExpectedKeyword;
        self.advance();
    }

    fn expectString(self: *ParserState) ParseError![]const u8 {
        return switch (self.peek().kind) {
            .string => |s| blk: {
                self.advance();
                break :blk s;
            },
            else => error.ExpectedString,
        };
    }

    /// Optional `when <expr>` clause. Returns null if no `when` keyword present.
    fn parseOptionalWhen(self: *ParserState) ParseError!?*const ast.AxisExpr {
        if (!self.isKeyword("when")) return null;
        self.advance();
        var ax_parser = axis_mod.Parser.init(self.arena, self.toks[self.pos..]);
        const expr = try ax_parser.parseExpr();
        self.pos += ax_parser.pos;
        return expr;
    }

    fn parseOptionalWhere(self: *ParserState) ParseError!?*const ast.RowExpr {
        if (!self.isKeyword("where")) return null;
        self.advance();
        var rp = row_expr_mod.Parser.init(self.arena, self.toks[self.pos..]);
        const expr = try rp.parseExpr();
        self.pos += rp.pos;
        return expr;
    }

    fn expectEof(self: *ParserState) ParseError!void {
        if (self.peek().kind != .eof) return error.UnexpectedTrailingTokens;
    }
};

pub fn parseLineDirective(arena: std.mem.Allocator, args: []const u8, line_no: u32) ParseError!ast.Directive {
    const toks = try lexer.lex(arena, args);
    var ps = ParserState{ .arena = arena, .toks = toks, .pos = 0 };

    const verb = switch (ps.peek().kind) {
        .keyword => |k| k,
        else => return error.ExpectedKeyword,
    };
    ps.advance();

    if (std.mem.eql(u8, verb, "include")) {
        const path = try ps.expectString();
        const when = try ps.parseOptionalWhen();
        try ps.expectEof();
        return .{
            .kind = .{ .include = .{
                .path = path,
                .when = when,
            } },
            .start_line = line_no,
            .end_line = line_no,
        };
    }
    if (std.mem.eql(u8, verb, "secret")) {
        const uri = try ps.expectString();
        try ps.expectEof();
        return .{
            .kind = .{ .secret = .{ .uri = uri } },
            .start_line = line_no,
            .end_line = line_no,
        };
    }
    if (std.mem.eql(u8, verb, "keep-empty")) {
        try ps.expectEof();
        return .{
            .kind = .keep_empty,
            .start_line = line_no,
            .end_line = line_no,
        };
    }
    if (std.mem.eql(u8, verb, "default")) {
        const name = switch (ps.peek().kind) {
            .ident => |s| s,
            else => return error.ExpectedAxisName,
        };
        ps.advance();
        if (!isValidFactName(name)) return error.InvalidFactName;
        if (ps.peek().kind != .eq) return error.ExpectedEquals;
        ps.advance();
        const value = try ps.expectString();
        try ps.expectEof();
        return .{
            .kind = .{ .default = .{ .name = name, .value = value } },
            .start_line = line_no,
            .end_line = line_no,
        };
    }
    if (std.mem.eql(u8, verb, "completions")) {
        const shell_word = switch (ps.peek().kind) {
            .ident => |s| s,
            else => return error.ExpectedShell,
        };
        ps.advance();
        // Refuse `shell=fish`-style arguments outright: the shell is a typed
        // positional token, never a key=value pair (which would be
        // surface-identical to an axis atom).
        if (ps.peek().kind == .eq) return error.ExpectedShell;
        const shell = std.meta.stringToEnum(ast.Shell, shell_word) orelse
            return error.UnknownShell;
        const registry = try ps.expectString();
        const when = try ps.parseOptionalWhen();
        try ps.expectEof();
        return .{
            .kind = .{ .completions = .{
                .shell = shell,
                .registry = registry,
                .when = when,
            } },
            .start_line = line_no,
            .end_line = line_no,
        };
    }
    return error.NotALineDirective;
}

test "parseLineDirective: include without when" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const dir = try parseLineDirective(fba.allocator(), "include \"foo.sh\"", 5);
    try std.testing.expect(dir.kind == .include);
    try std.testing.expectEqualStrings("foo.sh", dir.kind.include.path);
}

test "parseLineDirective: include with when" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const dir = try parseLineDirective(fba.allocator(), "include \"foo.sh\" when env=WSL", 1);
    try std.testing.expect(dir.kind.include.when != null);
}

test "parseLineDirective: secret" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const dir = try parseLineDirective(fba.allocator(), "secret \"op://foo\"", 1);
    try std.testing.expectEqualStrings("op://foo", dir.kind.secret.uri);
}

test "parseLineDirective: keep-empty" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const dir = try parseLineDirective(fba.allocator(), "keep-empty", 3);
    try std.testing.expect(dir.kind == .keep_empty);
    try std.testing.expectEqual(@as(u32, 3), dir.start_line);
}

test "parseLineDirective: keep-empty rejects trailing tokens" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    try std.testing.expectError(error.UnexpectedTrailingTokens, parseLineDirective(fba.allocator(), "keep-empty please", 1));
}

test "parseLineDirective: default" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const dir = try parseLineDirective(fba.allocator(), "default holt_backend=\"icloud\"", 1);
    try std.testing.expect(dir.kind == .default);
    try std.testing.expectEqualStrings("holt_backend", dir.kind.default.name);
    try std.testing.expectEqualStrings("icloud", dir.kind.default.value);
}

test "parseLineDirective: default rejects a missing equals" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseLineDirective(fba.allocator(), "default holt_backend \"icloud\"", 1);
    try std.testing.expectError(error.ExpectedEquals, result);
}

test "parseLineDirective: default rejects an unquoted value" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseLineDirective(fba.allocator(), "default holt_backend=icloud", 1);
    try std.testing.expectError(error.ExpectedString, result);
}

test "parseLineDirective: default rejects a malformed name charset" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    // Uppercase lexes as a valid ident (the DSL's general axis-name charset
    // is broader) but fails the stricter fact-name charset `default` shares
    // with `# mox: needs` and axis-tuple filenames.
    const result = parseLineDirective(fba.allocator(), "default Holt-Backend=\"icloud\"", 1);
    try std.testing.expectError(error.InvalidFactName, result);
}

test "parseLineDirective: default rejects an empty name" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseLineDirective(fba.allocator(), "default =\"icloud\"", 1);
    try std.testing.expectError(error.ExpectedAxisName, result);
}

test "parseLineDirective: default rejects trailing junk" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseLineDirective(fba.allocator(), "default holt_backend=\"icloud\" extra", 1);
    try std.testing.expectError(error.UnexpectedTrailingTokens, result);
}

test "parseLineDirective: default accepts a quoted UTF-8 value" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const dir = try parseLineDirective(fba.allocator(), "default locale=\"\xe6\x9d\xb1\xe4\xba\xac\"", 1);
    try std.testing.expectEqualStrings("\xe6\x9d\xb1\xe4\xba\xac", dir.kind.default.value);
}

test "parseLineDirective: completions with shell, registry, and when" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const dir = try parseLineDirective(
        fba.allocator(),
        "completions zsh \"data/completions.toml\" when not profile=minimal",
        3,
    );
    try std.testing.expect(dir.kind == .completions);
    try std.testing.expectEqual(ast.Shell.zsh, dir.kind.completions.shell);
    try std.testing.expectEqualStrings("data/completions.toml", dir.kind.completions.registry);
    try std.testing.expect(dir.kind.completions.when != null);
}

test "parseLineDirective: completions without when" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const dir = try parseLineDirective(fba.allocator(), "completions fish \"data/completions.toml\"", 1);
    try std.testing.expectEqual(ast.Shell.fish, dir.kind.completions.shell);
    try std.testing.expect(dir.kind.completions.when == null);
}

test "parseLineDirective: replace is not a line directive" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseLineDirective(fba.allocator(), "replace \"foo\" when os=darwin", 1);
    try std.testing.expectError(error.NotALineDirective, result);
}

pub const RegionOpener = struct {
    kind_tag: KindTag,
    path: ?[]const u8,
    from_dir: ?[]const u8,
    when: ?*const ast.AxisExpr,
    /// Row-expr condition for a standalone `when` gate parsed inside a loop
    /// (mutually exclusive with `when`).
    row_when: ?*const ast.RowExpr = null,
    /// Per-row `where` predicate, only meaningful for `for` directives.
    where: ?*const ast.RowExpr = null,
    /// Fan-out path template from `into "<path>"`, only on a top-level `for`.
    into: ?[]const u8 = null,
    start_line: u32,

    pub const KindTag = enum { replace, append, prepend, remove, from, when_gate, for_loop };
};

/// `in_loop` is true when this opener is being parsed inside an enclosing
/// `for` body: a standalone `when` gate then uses the row-expr grammar (so
/// `when id.signing_key` / `when x has "y"` work) instead of the axis grammar.
pub fn parseRegionOpener(arena: std.mem.Allocator, args: []const u8, line_no: u32, in_loop: bool) ParseError!RegionOpener {
    const toks = try lexer.lex(arena, args);
    var ps = ParserState{ .arena = arena, .toks = toks, .pos = 0 };

    const verb = switch (ps.peek().kind) {
        .keyword => |k| k,
        else => return error.ExpectedKeyword,
    };
    ps.advance();

    var path: ?[]const u8 = null;
    var from_dir: ?[]const u8 = null;
    var when: ?*const ast.AxisExpr = null;
    var kind_tag: RegionOpener.KindTag = undefined;

    if (std.mem.eql(u8, verb, "replace")) {
        kind_tag = .replace;
        if (ps.isKeyword("from")) {
            ps.advance();
            from_dir = try ps.expectString();
        } else {
            path = try ps.expectString();
        }
        when = try ps.parseOptionalWhen();
        try ps.expectEof();
    } else if (std.mem.eql(u8, verb, "append")) {
        kind_tag = .append;
        path = try ps.expectString();
        when = try ps.parseOptionalWhen();
        try ps.expectEof();
    } else if (std.mem.eql(u8, verb, "prepend")) {
        kind_tag = .prepend;
        path = try ps.expectString();
        when = try ps.parseOptionalWhen();
        try ps.expectEof();
    } else if (std.mem.eql(u8, verb, "remove")) {
        kind_tag = .remove;
        when = try ps.parseOptionalWhen() orelse return error.RemoveRequiresWhen;
        try ps.expectEof();
    } else if (std.mem.eql(u8, verb, "from")) {
        kind_tag = .from;
        from_dir = try ps.expectString();
        try ps.expectEof();
    } else if (std.mem.eql(u8, verb, "when")) {
        kind_tag = .when_gate;
        if (in_loop) {
            var rp = row_expr_mod.Parser.init(arena, toks[ps.pos..]);
            const expr = try rp.parseExpr();
            ps.pos += rp.pos;
            try ps.expectEof();
            return .{
                .kind_tag = kind_tag,
                .path = null,
                .from_dir = null,
                .when = null,
                .row_when = expr,
                .start_line = line_no,
            };
        }
        var ax_parser = axis_mod.Parser.init(arena, toks[ps.pos..]);
        const expr = try ax_parser.parseExpr();
        ps.pos += ax_parser.pos;
        when = expr;
        try ps.expectEof();
    } else if (std.mem.eql(u8, verb, "for")) {
        kind_tag = .for_loop;
        const var_name = switch (ps.peek().kind) {
            .ident => |s| s,
            else => return error.ExpectedIdent,
        };
        if (isReservedLoopVar(var_name)) return error.ReservedLoopVariable;
        ps.advance();
        try ps.expectKeyword("in");
        const data = switch (ps.peek().kind) {
            // Bare ident: a per-file data source NAME, resolved to
            // `<file>.d/<name>`. It holds no `/` (not an ident char), so a
            // path must use the quoted form below.
            .ident => |s| s,
            // Quoted string: repo-relative path like `"data/abbreviations.toml"`,
            // resolved against the mox repo root.
            .string => |s| s,
            else => return error.ExpectedDataSource,
        };
        ps.advance();
        when = try ps.parseOptionalWhen();
        const row_where = try ps.parseOptionalWhere();
        // `into "<path>"` marks a GENERATOR loop. Valid only at top level: a
        // nested `for` (parsed with `in_loop` set) rejects it.
        var into: ?[]const u8 = null;
        if (ps.isKeyword("into")) {
            ps.advance();
            into = try ps.expectString();
            if (in_loop) return error.IntoOnNestedFor;
        }
        try ps.expectEof();
        // Stash data source via path field; var name via from_dir field.
        // Driver will reassemble these into the for_loop AST variant.
        path = data;
        from_dir = var_name;
        return .{
            .kind_tag = kind_tag,
            .path = path,
            .from_dir = from_dir,
            .when = when,
            .where = row_where,
            .into = into,
            .start_line = line_no,
        };
    } else {
        return error.NotARegionDirective;
    }

    return .{
        .kind_tag = kind_tag,
        .path = path,
        .from_dir = from_dir,
        .when = when,
        .start_line = line_no,
    };
}

test "parseRegionOpener: replace with path and when" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const op = try parseRegionOpener(fba.allocator(), "replace \"kind/work.lua\" when profile=work", 1, false);
    try std.testing.expect(op.kind_tag == .replace);
    try std.testing.expectEqualStrings("kind/work.lua", op.path.?);
    try std.testing.expect(op.when != null);
}

test "parseRegionOpener: replace from shorthand" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const op = try parseRegionOpener(fba.allocator(), "replace from \"profile\"", 1, false);
    try std.testing.expect(op.kind_tag == .replace);
    try std.testing.expectEqualStrings("profile", op.from_dir.?);
}

test "parseRegionOpener: standalone when" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const op = try parseRegionOpener(fba.allocator(), "when os=darwin", 1, false);
    try std.testing.expect(op.kind_tag == .when_gate);
    try std.testing.expect(op.when != null);
}

test "parseRegionOpener: remove requires when" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseRegionOpener(fba.allocator(), "remove", 1, false);
    try std.testing.expectError(error.RemoveRequiresWhen, result);
}

test "parseLineDirective: trailing junk rejected" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseLineDirective(fba.allocator(), "include \"foo.sh\" extra junk", 1);
    try std.testing.expectError(error.UnexpectedTrailingTokens, result);
}

test "parseLineDirective: trailing junk after when rejected" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseLineDirective(fba.allocator(), "include \"foo.sh\" when os=darwin extra", 1);
    try std.testing.expectError(error.UnexpectedTrailingTokens, result);
}

test "parseLineDirective: trailing junk after secret rejected" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseLineDirective(fba.allocator(), "secret \"op://foo\" extra", 1);
    try std.testing.expectError(error.UnexpectedTrailingTokens, result);
}

test "parseRegionOpener: trailing junk after replace rejected" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseRegionOpener(fba.allocator(), "replace \"x.lua\" extra", 1, false);
    try std.testing.expectError(error.UnexpectedTrailingTokens, result);
}

test "parseRegionOpener: trailing junk after when gate rejected" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseRegionOpener(fba.allocator(), "when os=darwin extra", 1, false);
    try std.testing.expectError(error.UnexpectedTrailingTokens, result);
}

test "parseRegionOpener: a for var shadowing a fixed namespace is rejected" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const a = fba.allocator();
    inline for (.{ "machine", "env", "data" }) |name| {
        try std.testing.expectError(
            error.ReservedLoopVariable,
            parseRegionOpener(a, "for " ++ name ++ " in rows.toml", 1, false),
        );
    }
    // `entry` is the conventional row variable and stays valid.
    const op = try parseRegionOpener(a, "for entry in abbreviations.toml", 1, false);
    try std.testing.expect(op.kind_tag == .for_loop);
    try std.testing.expectEqualStrings("entry", op.from_dir.?);
}

test "parseRegionOpener: for with into captures the path template (top level)" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const op = try parseRegionOpener(fba.allocator(), "for id in \"data/ids.toml\" into \"id-<id.slug>.inc\"", 1, false);
    try std.testing.expect(op.kind_tag == .for_loop);
    try std.testing.expectEqualStrings("id", op.from_dir.?);
    try std.testing.expectEqualStrings("data/ids.toml", op.path.?);
    try std.testing.expectEqualStrings("id-<id.slug>.inc", op.into.?);
}

test "parseRegionOpener: into on a nested for is rejected" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const result = parseRegionOpener(fba.allocator(), "for id in \"data/ids.toml\" into \"x.inc\"", 1, true);
    try std.testing.expectError(error.IntoOnNestedFor, result);
}

test "parseRegionOpener: for without into leaves the template null" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const op = try parseRegionOpener(fba.allocator(), "for entry in abbreviations.toml", 1, false);
    try std.testing.expect(op.into == null);
}

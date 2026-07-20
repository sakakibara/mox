const std = @import("std");
const ast = @import("ast.zig");
const tokens_mod = @import("tokens.zig");
const lexer = @import("lexer.zig");

const AxisExpr = ast.AxisExpr;
const Token = tokens_mod.Token;

pub const ParseError = error{
    ExpectedAxisName,
    ExpectedEquals,
    ExpectedAxisValue,
    UnclosedParen,
    ExpressionTooDeep,
    OutOfMemory,
};

/// Recursion-depth cap for `parseExpr`/`parseNot`. Bounds `not not ...` and
/// `((( ... )))` nesting so a hostile directive line cannot overflow the
/// stack; well past any hand-written expression, far below the crash point.
const max_depth: usize = 128;

pub const Parser = struct {
    arena: std.mem.Allocator,
    toks: []const Token,
    pos: usize,
    depth: usize = 0,

    pub fn init(arena: std.mem.Allocator, toks: []const Token) Parser {
        return .{ .arena = arena, .toks = toks, .pos = 0 };
    }

    fn peek(self: *Parser) *const Token {
        return &self.toks[self.pos];
    }

    fn advance(self: *Parser) void {
        self.pos += 1;
    }

    fn isKeyword(t: *const Token, kw: []const u8) bool {
        return switch (t.kind) {
            .keyword => |k| std.mem.eql(u8, k, kw),
            else => false,
        };
    }

    /// Top-level entry. Parses lowest-precedence (or-expression).
    pub fn parseExpr(self: *Parser) ParseError!*const AxisExpr {
        if (self.depth >= max_depth) return error.ExpressionTooDeep;
        self.depth += 1;
        defer self.depth -= 1;
        return try self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!*const AxisExpr {
        var left = try self.parseAnd();
        while (isKeyword(self.peek(), "or")) {
            self.advance();
            const right = try self.parseAnd();
            const node = try self.arena.create(AxisExpr);
            node.* = .{ .or_ = .{ .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!*const AxisExpr {
        var left = try self.parseNot();
        while (isKeyword(self.peek(), "and")) {
            self.advance();
            const right = try self.parseNot();
            const node = try self.arena.create(AxisExpr);
            node.* = .{ .and_ = .{ .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseNot(self: *Parser) ParseError!*const AxisExpr {
        if (self.depth >= max_depth) return error.ExpressionTooDeep;
        self.depth += 1;
        defer self.depth -= 1;
        if (isKeyword(self.peek(), "not")) {
            self.advance();
            const inner = try self.parseNot();
            const node = try self.arena.create(AxisExpr);
            node.* = .{ .not = inner };
            return node;
        }
        return try self.parseAtom();
    }

    fn parseAtom(self: *Parser) ParseError!*const AxisExpr {
        const t = self.peek();
        // Parenthesized sub-expression for explicit grouping, e.g.
        // `(email and signing_key) or wildcard=true`.
        if (t.kind == .lparen) {
            self.advance();
            const inner = try self.parseExpr();
            if (self.peek().kind != .rparen) return error.UnclosedParen;
            self.advance();
            return inner;
        }
        const axis_name = switch (t.kind) {
            .ident => |s| s,
            else => return error.ExpectedAxisName,
        };
        self.advance();
        // Bare `name` (no `=`) is a presence check: `name` is bound to any
        // non-empty value. Lets users gate sections on "email is set",
        // "signing_key is set", etc., without having to invent a sentinel.
        if (self.peek().kind != .eq) {
            const node = try self.arena.create(AxisExpr);
            node.* = .{ .present = axis_name };
            return node;
        }
        self.advance();
        // A reserved word (in/and/or/not/end/from/has/remove/...) is a keyword
        // only in operator position; on the right of `=` it is a plain value.
        const value = switch (self.peek().kind) {
            .ident => |s| s,
            .keyword => |s| s,
            else => return error.ExpectedAxisValue,
        };
        self.advance();
        const node = try self.arena.create(AxisExpr);
        node.* = .{ .eq = .{ .axis = axis_name, .value = value } };
        return node;
    }
};

/// Lex + parse a COMPLETE expression string: trailing tokens after a valid
/// prefix are an error, exactly as the directive parser treats them. A gate
/// like `when os=darwin os=linux` (a dropped `or`) must fail loudly, never
/// silently evaluate only its prefix.
pub fn parseString(arena: std.mem.Allocator, src: []const u8) !*const AxisExpr {
    const toks = try lexer.lex(arena, src);
    var parser = Parser.init(arena, toks);
    const expr = try parser.parseExpr();
    if (parser.peek().kind != .eof) return error.UnexpectedTrailingTokens;
    return expr;
}

/// Evaluate an axis expression against a bindings map.
/// `bindings` maps axis name (e.g., "os") to value (e.g., "darwin").
/// Missing axes evaluate as false for `eq` comparisons.
pub fn evaluate(expr: *const AxisExpr, bindings: *const std.StringHashMap([]const u8)) bool {
    return switch (expr.*) {
        .eq => |e| eqMatch(e.axis, e.value, bindings),
        .present => |name| presentMatch(name, bindings),
        .not => |inner| !evaluate(inner, bindings),
        .and_ => |a| evaluate(a.left, bindings) and evaluate(a.right, bindings),
        .or_ => |o| evaluate(o.left, bindings) or evaluate(o.right, bindings),
    };
}

pub fn presentMatch(name: []const u8, bindings: *const std.StringHashMap([]const u8)) bool {
    if (bindings.get(name)) |v| return v.len > 0;
    return false;
}

pub fn eqMatch(axis_name: []const u8, value: []const u8, bindings: *const std.StringHashMap([]const u8)) bool {
    // Single-value axes (os, arch, profile, machine, ...): direct lookup
    if (bindings.get(axis_name)) |got| return std.mem.eql(u8, got, value);

    // Multi-value axes (tool, env, path): the binding key is the compound
    // "name=value". Compare against each key without materializing that string,
    // so an over-long axis binding still matches instead of silently missing.
    var it = bindings.keyIterator();
    while (it.next()) |k| {
        const key = k.*;
        if (key.len == axis_name.len + 1 + value.len and
            key[axis_name.len] == '=' and
            std.mem.startsWith(u8, key, axis_name) and
            std.mem.eql(u8, key[axis_name.len + 1 ..], value)) return true;
    }
    return false;
}

test "parse: deeply nested parens returns error instead of crashing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 20000;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendNTimes(a, '(', n);
    try buf.appendSlice(a, "os=darwin");
    try buf.appendNTimes(a, ')', n);
    try std.testing.expectError(error.ExpressionTooDeep, parseString(a, buf.items));
}

test "parse: deeply nested not returns error instead of crashing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 20000;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < n) : (i += 1) try buf.appendSlice(a, "not ");
    try buf.appendSlice(a, "os=darwin");
    try std.testing.expectError(error.ExpressionTooDeep, parseString(a, buf.items));
}

test "evaluate: simple equality" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "os=darwin");
    var bindings = std.StringHashMap([]const u8).init(fba.allocator());
    try bindings.put("os", "darwin");
    try std.testing.expect(evaluate(expr, &bindings));
}

test "evaluate: not negates" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "not os=windows");
    var bindings = std.StringHashMap([]const u8).init(fba.allocator());
    try bindings.put("os", "darwin");
    try std.testing.expect(evaluate(expr, &bindings));
}

test "evaluate: missing axis returns false" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "tool=fdfind");
    var bindings = std.StringHashMap([]const u8).init(fba.allocator());
    try std.testing.expect(!evaluate(expr, &bindings));
}

test "evaluate: complex (a and b) or c" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "os=darwin and profile=work or os=linux");
    var bindings = std.StringHashMap([]const u8).init(fba.allocator());
    try bindings.put("os", "darwin");
    try bindings.put("profile", "work");
    try std.testing.expect(evaluate(expr, &bindings));
}

test "evaluate: complex with linux fallback" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "os=darwin and profile=work or os=linux");
    var bindings = std.StringHashMap([]const u8).init(fba.allocator());
    try bindings.put("os", "linux");
    try std.testing.expect(evaluate(expr, &bindings));
}

test "parse simple equality" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "os=darwin");
    try std.testing.expect(expr.* == .eq);
}

test "parse with not, and, or precedence" {
    var allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "not os=windows and profile=work or os=linux");
    try std.testing.expect(expr.* == .or_);
    try std.testing.expect(expr.or_.left.* == .and_);
    try std.testing.expect(expr.or_.left.and_.left.* == .not);
}

test "parse double not" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "not not os=darwin");
    try std.testing.expect(expr.* == .not);
    try std.testing.expect(expr.not.* == .not);
    try std.testing.expect(expr.not.not.* == .eq);
}

test "evaluate: multi-value axis tool=fd matches via compound key" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "tool=fd");
    var b = std.StringHashMap([]const u8).init(fba.allocator());
    try b.put("tool=fd", "1");
    try std.testing.expect(evaluate(expr, &b));
}

test "evaluate: multi-value axis tool=rg fails when not present" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "tool=rg");
    var b = std.StringHashMap([]const u8).init(fba.allocator());
    try b.put("tool=fd", "1");
    try std.testing.expect(!evaluate(expr, &b));
}

test "evaluate: an over-256-byte multi-value binding still matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = "x" ** 300;
    const expr = try parseString(a, "env=" ++ long);
    var b = std.StringHashMap([]const u8).init(a);
    try b.put("env=" ++ long, "1");
    try std.testing.expect(evaluate(expr, &b));
}

test "evaluate: bare name is presence check (true when bound non-empty)" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "email");
    var b = std.StringHashMap([]const u8).init(fba.allocator());
    try b.put("email", "x@y.com");
    try std.testing.expect(evaluate(expr, &b));
}

test "evaluate: bare name presence false when unbound" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "email");
    var b = std.StringHashMap([]const u8).init(fba.allocator());
    try std.testing.expect(!evaluate(expr, &b));
}

test "evaluate: bare name presence false when bound to empty" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "email");
    var b = std.StringHashMap([]const u8).init(fba.allocator());
    try b.put("email", "");
    try std.testing.expect(!evaluate(expr, &b));
}

test "parse: a reserved word is usable as an axis value" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const a = fba.allocator();
    // `remove`, `end`, `from`, ... are keywords only in operator position; on
    // the right of `=` they are ordinary values.
    inline for (.{ "remove", "end", "from", "in", "has", "and" }) |word| {
        const expr = try parseString(a, "kind=" ++ word);
        try std.testing.expect(expr.* == .eq);
        try std.testing.expectEqualStrings("kind", expr.eq.axis);
        try std.testing.expectEqualStrings(word, expr.eq.value);
    }
}

test "evaluate: env axis multi-value" {
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const expr = try parseString(fba.allocator(), "env=WSL_DISTRO_NAME");
    var b = std.StringHashMap([]const u8).init(fba.allocator());
    try b.put("env=WSL_DISTRO_NAME", "1");
    try std.testing.expect(evaluate(expr, &b));
}

test "parseString: trailing tokens after a valid prefix are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A dropped `or` must fail loudly, never gate on just the prefix.
    try std.testing.expectError(error.UnexpectedTrailingTokens, parseString(arena.allocator(), "os=darwin os=linux"));
    // A parenthesized whole expression still parses.
    const e = try parseString(arena.allocator(), "(os=darwin or os=linux)");
    var b = std.StringHashMap([]const u8).init(arena.allocator());
    defer b.deinit();
    try b.put("os", "linux");
    try std.testing.expect(evaluate(e, &b));
}

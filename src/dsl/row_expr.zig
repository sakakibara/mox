//! Parser and evaluator for for-loop `where` / in-loop `when` row predicates.
//!
//! Grammar (right-recursive, lowest precedence at top):
//!
//!   row_expr  := or_expr
//!   or_expr   := and_expr ("or"  and_expr)*
//!   and_expr  := not_expr ("and" not_expr)*
//!   not_expr  := "not" not_expr | atom
//!   atom      := axis_field    -- e.g. `tool=entry.when`
//!              | axis_eq       -- e.g. `os=macos` (machine axis, in-loop)
//!              | field_present -- e.g. `entry.shells` / bare `os`
//!              | field_has     -- e.g. `entry.shells has "zsh"`
//!              | field_eq      -- e.g. `entry.shells = "zsh"`
//!              | "(" row_expr ")"   (parens optional, axis-grammar style)
//!
//! A `<var>.<field>` reference resolves against the in-scope loop frame named
//! `<var>` (any nesting level, innermost first). A bare identifier (no dot)
//! names a machine axis from the bindings map, so an in-loop `when` mixes row
//! and machine conditions (`when os=macos and id.signing_key`).

const std = @import("std");
const ast = @import("ast.zig");
const tokens_mod = @import("tokens.zig");
const lexer = @import("lexer.zig");
const axis_mod = @import("axis.zig");
const data_value = @import("../data/value.zig");

const RowExpr = ast.RowExpr;
const Token = tokens_mod.Token;

/// A loop-variable binding in the scope: a record loop binds a table row, an
/// array-element loop binds a scalar string. Shared with `compose/interp`,
/// which aliases these as `interp.Binding` / `interp.Frame`.
pub const Binding = union(enum) {
    record: *const std.StringHashMap(data_value.Value),
    scalar: []const u8,
};

/// One frame of the loop scope stack. `name` is the loop variable; the stack is
/// innermost-first, so the first frame whose name matches a reference's head
/// resolves it (inner loops shadow outer ones).
pub const Frame = struct { name: []const u8, value: Binding };

pub const ParseError = error{
    ExpectedRowAtom,
    ExpectedHasOrEqValue,
    ExpectedFieldRef,
    UnclosedParen,
    ExpressionTooDeep,
    OutOfMemory,
};

/// Recursion-depth cap for `parseExpr`/`parseNot`. Bounds `not not ...` and
/// `((( ... )))` nesting so a hostile `where` predicate cannot overflow the
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

    fn isKw(t: *const Token, kw: []const u8) bool {
        return switch (t.kind) {
            .keyword => |k| std.mem.eql(u8, k, kw),
            else => false,
        };
    }

    pub fn parseExpr(self: *Parser) ParseError!*const RowExpr {
        if (self.depth >= max_depth) return error.ExpressionTooDeep;
        self.depth += 1;
        defer self.depth -= 1;
        return try self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!*const RowExpr {
        var left = try self.parseAnd();
        while (isKw(self.peek(), "or")) {
            self.advance();
            const right = try self.parseAnd();
            const node = try self.arena.create(RowExpr);
            node.* = .{ .or_ = .{ .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!*const RowExpr {
        var left = try self.parseNot();
        while (isKw(self.peek(), "and")) {
            self.advance();
            const right = try self.parseNot();
            const node = try self.arena.create(RowExpr);
            node.* = .{ .and_ = .{ .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseNot(self: *Parser) ParseError!*const RowExpr {
        if (self.depth >= max_depth) return error.ExpressionTooDeep;
        self.depth += 1;
        defer self.depth -= 1;
        if (isKw(self.peek(), "not")) {
            self.advance();
            const inner = try self.parseNot();
            const node = try self.arena.create(RowExpr);
            node.* = .{ .not = inner };
            return node;
        }
        return try self.parseAtom();
    }

    fn parseAtom(self: *Parser) ParseError!*const RowExpr {
        const t = self.peek();
        // Parenthesized sub-expression — restores `(A or B) and (C or D)` shape.
        if (t.kind == .lparen) {
            self.advance();
            const inner = try self.parseExpr();
            if (self.peek().kind != .rparen) return error.UnclosedParen;
            self.advance();
            return inner;
        }
        const name = switch (t.kind) {
            .ident => |s| s,
            else => return error.ExpectedRowAtom,
        };
        self.advance();

        // `<axis>=<var>.field` (field-substituted axis), `<axis>=value` (literal
        // machine axis), or `<var>.field = "Y"` (row equality).
        if (self.peek().kind == .eq) {
            self.advance();
            switch (self.peek().kind) {
                .ident => |val_ident| {
                    self.advance();
                    // A dotted RHS substitutes a row field into a machine-axis
                    // check; a bare RHS is a literal axis-value comparison.
                    if (std.mem.indexOfScalar(u8, val_ident, '.') != null) {
                        const node = try self.arena.create(RowExpr);
                        node.* = .{ .axis_with_field = .{ .axis = name, .field_ref = val_ident } };
                        return node;
                    }
                    const node = try self.arena.create(RowExpr);
                    node.* = .{ .eq = .{ .ref = name, .value = val_ident } };
                    return node;
                },
                // A reserved word on the RHS of `=` is a plain value (mirrors
                // the axis grammar): `kind=from`, `os=end`, ...
                .keyword => |val_kw| {
                    self.advance();
                    const node = try self.arena.create(RowExpr);
                    node.* = .{ .eq = .{ .ref = name, .value = val_kw } };
                    return node;
                },
                .string => |val_str| {
                    self.advance();
                    const node = try self.arena.create(RowExpr);
                    node.* = .{ .eq = .{ .ref = name, .value = val_str } };
                    return node;
                },
                else => return error.ExpectedHasOrEqValue,
            }
        }

        // `<var>.field has "Y"` — membership.
        if (isKw(self.peek(), "has")) {
            self.advance();
            const val = switch (self.peek().kind) {
                .string => |s| s,
                else => return error.ExpectedHasOrEqValue,
            };
            self.advance();
            const node = try self.arena.create(RowExpr);
            node.* = .{ .has = .{ .ref = name, .value = val } };
            return node;
        }

        // Bare `<var>.field` / `<axis>` — presence check.
        const node = try self.arena.create(RowExpr);
        node.* = .{ .present = name };
        return node;
    }
};

/// Split a `<var>.<field>` reference into head and optional field; `field` is
/// null when the reference carries no `.` (a bare machine axis).
const Ref = struct { head: []const u8, field: ?[]const u8 };

fn splitRef(ref: []const u8) Ref {
    const dot = std.mem.indexOfScalar(u8, ref, '.') orelse return .{ .head = ref, .field = null };
    return .{ .head = ref[0..dot], .field = ref[dot + 1 ..] };
}

fn findFrame(scope: []const Frame, head: []const u8) ?Frame {
    for (scope) |f| {
        if (std.mem.eql(u8, f.name, head)) return f;
    }
    return null;
}

/// Lex + parse a COMPLETE predicate string: trailing tokens after a valid
/// prefix are an error, matching the directive parser's strictness.
pub fn parseString(arena: std.mem.Allocator, src: []const u8) !*const RowExpr {
    const toks = try lexer.lex(arena, src);
    var parser = Parser.init(arena, toks);
    const expr = try parser.parseExpr();
    if (parser.peek().kind != .eof) return error.UnexpectedTrailingTokens;
    return expr;
}

pub const EvalError = error{ UnknownLoopVariable, OutOfMemory };

/// Evaluate a row predicate against the loop `scope` + machine `bindings`.
///
/// A `<var>.<field>` reference resolves against the in-scope frame named
/// `<var>`: an unknown `<var>` is `error.UnknownLoopVariable` (its name is
/// written to `unknown_var` for diagnostics), while a known frame that simply
/// lacks the field is false (a presence/comparison miss, not an error). A bare
/// `<axis>` (or `<axis>=value`) whose head names no frame is a machine-axis test
/// against `bindings`, matching `axis.evaluate` semantics.
pub fn evaluate(
    arena: std.mem.Allocator,
    expr: *const RowExpr,
    scope: []const Frame,
    bindings: *const std.StringHashMap([]const u8),
    unknown_var: ?*[]const u8,
) EvalError!bool {
    return switch (expr.*) {
        .present => |ref| presentRef(ref, scope, bindings, unknown_var),
        .has => |h| memberRef(h.ref, h.value, scope, bindings, unknown_var),
        .eq => |e| memberRef(e.ref, e.value, scope, bindings, unknown_var),
        .axis_with_field => |a| axisWithField(arena, a.axis, a.field_ref, scope, bindings, unknown_var),
        .not => |inner| !(try evaluate(arena, inner, scope, bindings, unknown_var)),
        .and_ => |a| (try evaluate(arena, a.left, scope, bindings, unknown_var)) and
            (try evaluate(arena, a.right, scope, bindings, unknown_var)),
        .or_ => |o| (try evaluate(arena, o.left, scope, bindings, unknown_var)) or
            (try evaluate(arena, o.right, scope, bindings, unknown_var)),
    };
}

fn noteUnknown(unknown_var: ?*[]const u8, name: []const u8) EvalError {
    if (unknown_var) |u| u.* = name;
    return error.UnknownLoopVariable;
}

fn presentRef(
    ref: []const u8,
    scope: []const Frame,
    bindings: *const std.StringHashMap([]const u8),
    unknown_var: ?*[]const u8,
) EvalError!bool {
    const r = splitRef(ref);
    if (findFrame(scope, r.head)) |frame| {
        return switch (frame.value) {
            .record => |rec| if (r.field) |fld| present(fld, rec) else true,
            .scalar => |s| if (r.field == null) s.len > 0 else false,
        };
    }
    // A dotted ref whose head names no frame is a typo'd loop variable; a bare
    // ref is a machine-axis presence check.
    if (r.field != null) return noteUnknown(unknown_var, r.head);
    return axis_mod.presentMatch(r.head, bindings);
}

fn memberRef(
    ref: []const u8,
    value: []const u8,
    scope: []const Frame,
    bindings: *const std.StringHashMap([]const u8),
    unknown_var: ?*[]const u8,
) EvalError!bool {
    const r = splitRef(ref);
    if (findFrame(scope, r.head)) |frame| {
        return switch (frame.value) {
            .record => |rec| if (r.field) |fld| memberOf(fld, value, rec) else false,
            .scalar => |s| if (r.field == null) std.mem.eql(u8, s, value) else false,
        };
    }
    if (r.field != null) return noteUnknown(unknown_var, r.head);
    return axis_mod.eqMatch(r.head, value, bindings);
}

fn present(field: []const u8, record: *const std.StringHashMap(data_value.Value)) bool {
    const v = record.get(field) orelse return false;
    return !v.isEmpty();
}

fn memberOf(
    field: []const u8,
    value: []const u8,
    record: *const std.StringHashMap(data_value.Value),
) bool {
    const v = record.get(field) orelse return false;
    return v.contains(value);
}

fn axisWithField(
    arena: std.mem.Allocator,
    axis: []const u8,
    field_ref: []const u8,
    scope: []const Frame,
    bindings: *const std.StringHashMap([]const u8),
    unknown_var: ?*[]const u8,
) EvalError!bool {
    const r = splitRef(field_ref);
    const frame = findFrame(scope, r.head) orelse return noteUnknown(unknown_var, r.head);
    const field = r.field orelse return false;
    const rec = switch (frame.value) {
        .record => |rec| rec,
        .scalar => return false, // a scalar has no field to substitute
    };
    const v = rec.get(field) orelse return false;
    if (v.isEmpty()) return false;
    // Format the field value (string for scalars, comma-joined for arrays —
    // arrays in this position are unusual; using the formatted form mirrors
    // how `<entry.X>` substitutes elsewhere).
    const formatted = try v.format(arena);
    return axis_mod.eqMatch(axis, formatted, bindings);
}

test "parse: deeply nested parens returns error instead of crashing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 20000;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendNTimes(a, '(', n);
    try buf.appendSlice(a, "entry.shells");
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
    try buf.appendSlice(a, "entry.shells");
    try std.testing.expectError(error.ExpressionTooDeep, parseString(a, buf.items));
}

test "parse: present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e = try parseString(arena.allocator(), "entry.shells");
    try std.testing.expect(e.* == .present);
    try std.testing.expectEqualStrings("entry.shells", e.present);
}

test "parse: has" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e = try parseString(arena.allocator(), "entry.shells has \"zsh\"");
    try std.testing.expect(e.* == .has);
    try std.testing.expectEqualStrings("entry.shells", e.has.ref);
    try std.testing.expectEqualStrings("zsh", e.has.value);
}

test "parse: axis_with_field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e = try parseString(arena.allocator(), "tool=entry.when");
    try std.testing.expect(e.* == .axis_with_field);
    try std.testing.expectEqualStrings("tool", e.axis_with_field.axis);
    try std.testing.expectEqualStrings("entry.when", e.axis_with_field.field_ref);
}

test "parse: bare axis presence and literal axis eq (machine forms)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseString(a, "signing_key");
    try std.testing.expect(p.* == .present);
    try std.testing.expectEqualStrings("signing_key", p.present);
    const e = try parseString(a, "os=macos");
    try std.testing.expect(e.* == .eq);
    try std.testing.expectEqualStrings("os", e.eq.ref);
    try std.testing.expectEqualStrings("macos", e.eq.value);
}

test "parse: complex `not entry.X or entry.X has Y`" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const e = try parseString(arena.allocator(), "not entry.shells or entry.shells has \"zsh\"");
    try std.testing.expect(e.* == .or_);
    try std.testing.expect(e.or_.left.* == .not);
    try std.testing.expect(e.or_.left.not.* == .present);
    try std.testing.expect(e.or_.right.* == .has);
}

/// A one-frame scope binding record `rec` to the loop variable `entry`.
fn entryScope(rec: *const std.StringHashMap(data_value.Value)) [1]Frame {
    return .{.{ .name = "entry", .value = .{ .record = rec } }};
}

test "evaluate: present false when field unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var record = std.StringHashMap(data_value.Value).init(arena.allocator());
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    const scope = entryScope(&record);
    const e = try parseString(arena.allocator(), "entry.shells");
    try std.testing.expect(!try evaluate(arena.allocator(), e, &scope, &bindings, null));
}

test "evaluate: present true when field set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var record = std.StringHashMap(data_value.Value).init(arena.allocator());
    try record.put("shells", .{ .string = "zsh" });
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    const scope = entryScope(&record);
    const e = try parseString(arena.allocator(), "entry.shells");
    try std.testing.expect(try evaluate(arena.allocator(), e, &scope, &bindings, null));
}

test "evaluate: unknown loop variable errors and records the name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var record = std.StringHashMap(data_value.Value).init(arena.allocator());
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    const scope = entryScope(&record);
    const e = try parseString(arena.allocator(), "id.shells");
    var unknown: []const u8 = "";
    try std.testing.expectError(
        error.UnknownLoopVariable,
        evaluate(arena.allocator(), e, &scope, &bindings, &unknown),
    );
    try std.testing.expectEqualStrings("id", unknown);
}

test "evaluate: a bare axis resolves against bindings, not the row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var record = std.StringHashMap(data_value.Value).init(a);
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("os", "macos");
    const scope = entryScope(&record);
    const present_e = try parseString(a, "os");
    try std.testing.expect(try evaluate(a, present_e, &scope, &bindings, null));
    const eq_e = try parseString(a, "os=macos");
    try std.testing.expect(try evaluate(a, eq_e, &scope, &bindings, null));
    const miss_e = try parseString(a, "os=linux");
    try std.testing.expect(!try evaluate(a, miss_e, &scope, &bindings, null));
}

test "evaluate: an outer frame resolves from an inner scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var outer = std.StringHashMap(data_value.Value).init(a);
    try outer.put("tag", .{ .string = "t" });
    var bindings = std.StringHashMap([]const u8).init(a);
    // Innermost first: `url` scalar shadows nothing; `outer` still reaches the record.
    const scope = [_]Frame{
        .{ .name = "url", .value = .{ .scalar = "x" } },
        .{ .name = "outer", .value = .{ .record = &outer } },
    };
    const e = try parseString(a, "outer.tag");
    try std.testing.expect(try evaluate(a, e, &scope, &bindings, null));
}

test "evaluate: has on string field equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var record = std.StringHashMap(data_value.Value).init(arena.allocator());
    try record.put("shells", .{ .string = "zsh" });
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    const scope = entryScope(&record);
    const e = try parseString(arena.allocator(), "entry.shells has \"zsh\"");
    try std.testing.expect(try evaluate(arena.allocator(), e, &scope, &bindings, null));
    const e2 = try parseString(arena.allocator(), "entry.shells has \"fish\"");
    try std.testing.expect(!try evaluate(arena.allocator(), e2, &scope, &bindings, null));
}

test "evaluate: has on array field membership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var record = std.StringHashMap(data_value.Value).init(arena.allocator());
    const items = try arena.allocator().alloc([]const u8, 2);
    items[0] = "zsh";
    items[1] = "fish";
    try record.put("shells", .{ .array_of_strings = items });
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    const scope = entryScope(&record);
    const e = try parseString(arena.allocator(), "entry.shells has \"zsh\"");
    try std.testing.expect(try evaluate(arena.allocator(), e, &scope, &bindings, null));
    const e2 = try parseString(arena.allocator(), "entry.shells has \"bash\"");
    try std.testing.expect(!try evaluate(arena.allocator(), e2, &scope, &bindings, null));
}

test "evaluate: axis_with_field looks up substituted axis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var record = std.StringHashMap(data_value.Value).init(arena.allocator());
    try record.put("when", .{ .string = "fd" });
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("tool=fd", "1");
    const scope = entryScope(&record);
    const e = try parseString(arena.allocator(), "tool=entry.when");
    try std.testing.expect(try evaluate(arena.allocator(), e, &scope, &bindings, null));
}

test "evaluate: axis_with_field returns false when binding absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var record = std.StringHashMap(data_value.Value).init(arena.allocator());
    try record.put("when", .{ .string = "zk" });
    var bindings = std.StringHashMap([]const u8).init(arena.allocator());
    try bindings.put("tool=fd", "1");
    const scope = entryScope(&record);
    const e = try parseString(arena.allocator(), "tool=entry.when");
    try std.testing.expect(!try evaluate(arena.allocator(), e, &scope, &bindings, null));
}

test "evaluate: axis_with_field matches an over-256-byte field value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = "z" ** 300;
    var record = std.StringHashMap(data_value.Value).init(a);
    try record.put("when", .{ .string = long });
    var bindings = std.StringHashMap([]const u8).init(a);
    try bindings.put("tool=" ++ long, "1");
    const scope = entryScope(&record);
    const e = try parseString(a, "tool=entry.when");
    try std.testing.expect(try evaluate(a, e, &scope, &bindings, null));
}

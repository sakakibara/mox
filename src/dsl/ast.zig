const std = @import("std");

/// Axis expression - used as condition on `when` clauses and standalone gates.
///
/// Lifetime contract: all sub-expression pointers (`not`, `and_.left`, `and_.right`,
/// `or_.left`, `or_.right`) MUST reference storage that outlives the enclosing
/// `ParsedFile`. Typically the parser allocates these in an arena owned by the
/// caller. NEVER point at stack locals - those will dangle when the parser
/// function returns.
pub const AxisExpr = union(enum) {
    /// `axis_name=value` literal.
    eq: struct { axis: []const u8, value: []const u8 },
    /// Bare `axis_name` — true when the axis is bound to any non-empty
    /// value. Used for "include this section if `email` is set" semantics.
    present: []const u8,
    /// `not <expr>`.
    not: *const AxisExpr,
    /// `<expr> and <expr>`.
    and_: struct { left: *const AxisExpr, right: *const AxisExpr },
    /// `<expr> or <expr>`.
    or_: struct { left: *const AxisExpr, right: *const AxisExpr },
};

/// Render `expr` back to its DSL surface syntax (`profile=work`, `not
/// tool=fd`, `a=1 and b=2`, `(a=1 or b=2) and c=3`), parenthesizing only
/// where precedence would otherwise change the reading -- `not` binds
/// tighter than `and`, which binds tighter than `or`. For showing a
/// condition to a human (a facts report, a diagnostic), never for parsing.
pub fn writeExpr(out: *std.Io.Writer, expr: *const AxisExpr) !void {
    try writeExprAt(out, expr, 0);
}

fn exprPrecedence(expr: *const AxisExpr) u8 {
    return switch (expr.*) {
        .eq, .present => 3,
        .not => 2,
        .and_ => 1,
        .or_ => 0,
    };
}

/// True when `value` needs no quoting to round-trip through the DSL's own
/// value grammar (`lexer.isIdentStart`/`isIdentCont`): non-empty and every
/// byte in `[A-Za-z0-9._+-]`.
fn isBareTokenValue(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '+' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn writeExprAt(out: *std.Io.Writer, expr: *const AxisExpr, min_prec: u8) !void {
    const prec = exprPrecedence(expr);
    const needs_parens = prec < min_prec;
    if (needs_parens) try out.writeAll("(");
    switch (expr.*) {
        .eq => |e| if (isBareTokenValue(e.value))
            try out.print("{s}={s}", .{ e.axis, e.value })
        else
            try out.print("{s}=\"{s}\"", .{ e.axis, e.value }),
        .present => |n| try out.writeAll(n),
        .not => |inner| {
            try out.writeAll("not ");
            try writeExprAt(out, inner, 2);
        },
        .and_ => |a| {
            try writeExprAt(out, a.left, 1);
            try out.writeAll(" and ");
            try writeExprAt(out, a.right, 1);
        },
        .or_ => |o| {
            try writeExprAt(out, o.left, 0);
            try out.writeAll(" or ");
            try writeExprAt(out, o.right, 0);
        },
    }
    if (needs_parens) try out.writeAll(")");
}

/// Structural equality: same shape, same axis names/values, same operand
/// order. `not`/`and_`/`or_` compare recursively; `and_`/`or_` are NOT
/// commutative here -- `a and b` and `b and a` compare unequal.
pub fn exprEqual(a: *const AxisExpr, b: *const AxisExpr) bool {
    return switch (a.*) {
        .eq => |ae| switch (b.*) {
            .eq => |be| std.mem.eql(u8, ae.axis, be.axis) and std.mem.eql(u8, ae.value, be.value),
            else => false,
        },
        .present => |an| switch (b.*) {
            .present => |bn| std.mem.eql(u8, an, bn),
            else => false,
        },
        .not => |ai| switch (b.*) {
            .not => |bi| exprEqual(ai, bi),
            else => false,
        },
        .and_ => |aa| switch (b.*) {
            .and_ => |ba| exprEqual(aa.left, ba.left) and exprEqual(aa.right, ba.right),
            else => false,
        },
        .or_ => |ao| switch (b.*) {
            .or_ => |bo| exprEqual(ao.left, bo.left) and exprEqual(ao.right, bo.right),
            else => false,
        },
    };
}

/// Row predicate used by for-loop `where` clauses. Evaluated per record;
/// rows for which the predicate evaluates false are skipped during emit.
///
/// Lifetime contract matches `AxisExpr`: sub-expression pointers must
/// reference arena-owned storage that outlives the enclosing `ParsedFile`.
pub const RowExpr = union(enum) {
    /// `<ref>` presence. A `<var>.<field>` ref checks that field on the frame
    /// named `<var>`; a bare `<axis>` checks a machine binding (in-loop only).
    present: []const u8,
    /// `<var>.<field> has "Y"` - membership on the row field; for string fields
    /// exact equality, for arrays "Y" is a member, for bool/int the formatted
    /// form equals "Y". A bare `<axis> has "Y"` compares a machine binding.
    has: struct { ref: []const u8, value: []const u8 },
    /// `<var>.<field> = "Y"` - same semantics as `has` (chezmoi-friendly alias).
    eq: struct { ref: []const u8, value: []const u8 },
    /// `<axis>=<var>.<field>` - substitute the row's field, then check the
    /// resulting `<axis>=<substituted>` is in the bindings map. Lets users
    /// write `tool=<entry.when>` to mirror chezmoi's `lookPath entry.when`.
    axis_with_field: struct { axis: []const u8, field_ref: []const u8 },
    /// `bound <var>.<field>` - substitute the row's field value, then check
    /// that name is bound as a single-value machine fact (presence, not
    /// equality). The twin of `axis_with_field`: that substitutes into an
    /// `eq` check, this substitutes into a `present` check.
    bound: []const u8,
    not: *const RowExpr,
    and_: struct { left: *const RowExpr, right: *const RowExpr },
    or_: struct { left: *const RowExpr, right: *const RowExpr },
};

/// A line-level or region-level directive.
///
/// String ownership:
/// - Body fields (`body`, `body_template` in for_loop) are arena-allocated copies,
///   self-contained and independent of `src`.
/// - All other `[]const u8` fields (paths, URIs, axis names/values, `from` dir,
///   for-loop variable, for-loop data source) are slices into the original source
///   bytes. The `src` argument passed to `parseFile` MUST outlive the resulting
///   `ParsedFile`. Typical pattern: caller owns both `src` and the arena.
pub const Directive = struct {
    kind: Kind,
    /// Source line number where the directive opens (1-indexed).
    start_line: u32,
    /// For region-level directives: line of the matching `# mox: end`.
    /// For line-level directives: equals `start_line`.
    end_line: u32,

    pub const Kind = union(enum) {
        /// `# mox: include "<path>" when <expr>` - line-level.
        include: struct {
            path: []const u8,
            when: ?*const AxisExpr,
        },
        /// `# mox: replace "<path>" when <expr>` - region-level (path optional with `from`).
        ///
        /// `body` is the inline default content between the opening and closing markers.
        /// May be the empty string `""` when the region has no inline content (typical
        /// of `replace from "<dir>"` shorthand).
        replace: struct {
            path: ?[]const u8,
            when: ?*const AxisExpr,
            from: ?[]const u8,
            /// Body content lines (default content) between open and end markers.
            body: []const u8,
        },
        /// `# mox: append "<path>" when <expr>` - region-level.
        append: struct {
            path: []const u8,
            when: ?*const AxisExpr,
            body: []const u8,
        },
        /// `# mox: prepend "<path>" when <expr>` - region-level.
        prepend: struct {
            path: []const u8,
            when: ?*const AxisExpr,
            body: []const u8,
        },
        /// `# mox: remove when <expr>` - region-level.
        ///
        /// `body` carries the removed inline content. Used only for diagnostics and
        /// round-tripping; consumers replacing the region with empty content can ignore it.
        remove: struct {
            when: *const AxisExpr,
            body: []const u8,
        },
        /// `# mox: from "<dir>"` - region-level shorthand.
        from: struct {
            dir: []const u8,
            body: []const u8,
        },
        /// `# mox: when <expr>` standalone - gates content until `# mox: end` or EOF.
        ///
        /// Exactly one of `when` / `row_when` is set: `when` (axis grammar) when
        /// parsed outside a loop, `row_when` (row-expr grammar, evaluated against
        /// the innermost loop record) when parsed inside one.
        when_gate: struct {
            when: ?*const AxisExpr,
            row_when: ?*const RowExpr = null,
            body: []const u8,
            /// True when the gate closed at EOF with no `# mox: end` marker, so
            /// it governs the rest of the file.
            to_eof: bool,
        },
        /// `# mox: for <var> in <data> [when <expr>] [where <row-expr>] [into "<path>"]` - for loop.
        for_loop: struct {
            variable: []const u8,
            data_source: []const u8,
            when: ?*const AxisExpr,
            /// Per-row predicate. When non-null, rows for which it evaluates
            /// false are skipped during emission.
            where: ?*const RowExpr,
            /// Fan-out path template. Non-null only on a TOP-LEVEL `for`: the
            /// file is then a GENERATOR that writes one file per row at the
            /// rendered path (relative to the source's target dir) and does not
            /// materialize at its own path. Rejected on a nested `for` at parse.
            into: ?[]const u8 = null,
            /// Loop body lines, with the leading line-comment prefix stripped.
            body_template: []const u8,
        },
        /// `# mox: secret "<uri>"` - line-level.
        secret: struct {
            uri: []const u8,
        },
        /// `# mox: keep-empty` - line-level, no arguments. Marks a template to
        /// materialize even when it composes to nothing, instead of being
        /// omitted (the default for a directive-bearing file that renders
        /// empty). Emits and gates nothing; stripped from output. A whole-file
        /// existence gate still wins: an off gate omits the file regardless.
        keep_empty,
        /// `# mox: default <name>="<value>"` - line-level. Declares the
        /// interview default for fact `<name>`; stripped from output, never
        /// gates or emits anything, and compose semantics are otherwise
        /// untouched (an unbound fact still never silently reads as this
        /// value -- only the interview consults it).
        default: struct {
            name: []const u8,
            value: []const u8,
        },
        /// `# mox: completions <shell> "<registry>" [when <expr>]` - generator
        /// directive: the file emits one completion stub per registry row into
        /// its target directory and is not materialized itself. The shell is a
        /// typed positional token, validated at parse.
        completions: struct {
            shell: Shell,
            registry: []const u8,
            when: ?*const AxisExpr,
        },
    };
};

/// Shells the completions generator can emit stubs for.
pub const Shell = enum { fish, zsh, bash, powershell };

/// The complete parsed result of a source file.
pub const ParsedFile = struct {
    /// Directives in source order.
    directives: []const Directive,
    /// Total number of lines in source.
    line_count: u32,
};

test "AST Directive type can be constructed" {
    const dir = Directive{
        .kind = .{ .include = .{ .path = "foo.sh", .when = null } },
        .start_line = 1,
        .end_line = 1,
    };
    try std.testing.expectEqual(@as(u32, 1), dir.start_line);
}

fn writeExprToString(a: std.mem.Allocator, expr: *const AxisExpr) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try writeExpr(&aw.writer, expr);
    return a.dupe(u8, aw.written());
}

test "writeExpr: eq and present render as their literal syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const eq: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "work" } };
    try std.testing.expectEqualStrings("profile=work", try writeExprToString(a, &eq));

    const present: AxisExpr = .{ .present = "signing_key" };
    try std.testing.expectEqualStrings("signing_key", try writeExprToString(a, &present));
}

test "writeExpr: not binds tighter than and/or, no parens needed around a leaf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const eq: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "work" } };
    const not_expr: AxisExpr = .{ .not = &eq };
    try std.testing.expectEqualStrings("not profile=work", try writeExprToString(a, &not_expr));
}

test "writeExpr: and of two comparisons, no parens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const left: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "work" } };
    const right: AxisExpr = .{ .present = "signing_work_key" };
    const and_expr: AxisExpr = .{ .and_ = .{ .left = &left, .right = &right } };
    try std.testing.expectEqualStrings("profile=work and signing_work_key", try writeExprToString(a, &and_expr));
}

test "writeExpr: an or nested inside an and is parenthesized, precedence preserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const left1: AxisExpr = .{ .eq = .{ .axis = "os", .value = "darwin" } };
    const left2: AxisExpr = .{ .eq = .{ .axis = "os", .value = "linux" } };
    const or_expr: AxisExpr = .{ .or_ = .{ .left = &left1, .right = &left2 } };
    const right: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "work" } };
    const and_expr: AxisExpr = .{ .and_ = .{ .left = &or_expr, .right = &right } };
    try std.testing.expectEqualStrings("(os=darwin or os=linux) and profile=work", try writeExprToString(a, &and_expr));
}

test "writeExpr: not wrapping an and is parenthesized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const left: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "work" } };
    const right: AxisExpr = .{ .present = "signing_work_key" };
    const and_expr: AxisExpr = .{ .and_ = .{ .left = &left, .right = &right } };
    const not_expr: AxisExpr = .{ .not = &and_expr };
    try std.testing.expectEqualStrings("not (profile=work and signing_work_key)", try writeExprToString(a, &not_expr));
}

test "writeExpr: a bare-token value stays unquoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const eq: AxisExpr = .{ .eq = .{ .axis = "tool", .value = "fdfind-2.0" } };
    try std.testing.expectEqualStrings("tool=fdfind-2.0", try writeExprToString(a, &eq));
}

test "writeExpr: a value containing a space renders quoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const eq: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "new york" } };
    try std.testing.expectEqualStrings("profile=\"new york\"", try writeExprToString(a, &eq));
}

test "writeExpr: a non-ASCII value renders quoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const eq: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e" } };
    try std.testing.expectEqualStrings("profile=\"\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\"", try writeExprToString(a, &eq));
}

test "exprEqual: identical eq/present/not/and/or expressions compare equal" {
    const eq1: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "work" } };
    const eq2: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "work" } };
    try std.testing.expect(exprEqual(&eq1, &eq2));

    const present1: AxisExpr = .{ .present = "email" };
    const present2: AxisExpr = .{ .present = "email" };
    try std.testing.expect(exprEqual(&present1, &present2));

    const not1: AxisExpr = .{ .not = &eq1 };
    const not2: AxisExpr = .{ .not = &eq2 };
    try std.testing.expect(exprEqual(&not1, &not2));

    const and1: AxisExpr = .{ .and_ = .{ .left = &eq1, .right = &present1 } };
    const and2: AxisExpr = .{ .and_ = .{ .left = &eq2, .right = &present2 } };
    try std.testing.expect(exprEqual(&and1, &and2));

    const or1: AxisExpr = .{ .or_ = .{ .left = &eq1, .right = &present1 } };
    const or2: AxisExpr = .{ .or_ = .{ .left = &eq2, .right = &present2 } };
    try std.testing.expect(exprEqual(&or1, &or2));
}

test "exprEqual: differing axis, value, shape, or operand order compare unequal" {
    const profile_work: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "work" } };
    const profile_personal: AxisExpr = .{ .eq = .{ .axis = "profile", .value = "personal" } };
    try std.testing.expect(!exprEqual(&profile_work, &profile_personal));

    const os_work: AxisExpr = .{ .eq = .{ .axis = "os", .value = "work" } };
    try std.testing.expect(!exprEqual(&profile_work, &os_work));

    const email: AxisExpr = .{ .present = "email" };
    try std.testing.expect(!exprEqual(&profile_work, &email));

    const and_pe: AxisExpr = .{ .and_ = .{ .left = &profile_work, .right = &email } };
    const and_ep: AxisExpr = .{ .and_ = .{ .left = &email, .right = &profile_work } };
    try std.testing.expect(!exprEqual(&and_pe, &and_ep));

    const or_pe: AxisExpr = .{ .or_ = .{ .left = &profile_work, .right = &email } };
    try std.testing.expect(!exprEqual(&and_pe, &or_pe));
}

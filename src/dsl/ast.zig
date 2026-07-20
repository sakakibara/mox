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
    };
};

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

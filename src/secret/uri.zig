const std = @import("std");

pub const Scheme = enum { op, env, pass, file, cmd };

pub const Uri = struct {
    scheme: Scheme,
    payload: []const u8,
};

pub const ParseError = error{
    UnknownScheme,
    EmptyPayload,
};

pub fn parse(uri_str: []const u8) ParseError!Uri {
    if (std.mem.startsWith(u8, uri_str, "op://")) {
        const payload = uri_str[5..];
        if (payload.len == 0) return error.EmptyPayload;
        return .{ .scheme = .op, .payload = payload };
    }
    if (std.mem.startsWith(u8, uri_str, "env:")) {
        const payload = uri_str[4..];
        if (payload.len == 0) return error.EmptyPayload;
        return .{ .scheme = .env, .payload = payload };
    }
    if (std.mem.startsWith(u8, uri_str, "pass://")) {
        const payload = uri_str[7..];
        if (payload.len == 0) return error.EmptyPayload;
        return .{ .scheme = .pass, .payload = payload };
    }
    if (std.mem.startsWith(u8, uri_str, "file://")) {
        const payload = uri_str[7..];
        if (payload.len == 0) return error.EmptyPayload;
        return .{ .scheme = .file, .payload = payload };
    }
    if (std.mem.startsWith(u8, uri_str, "cmd:")) {
        const payload = uri_str[4..];
        if (payload.len == 0) return error.EmptyPayload;
        return .{ .scheme = .cmd, .payload = payload };
    }
    return error.UnknownScheme;
}

test "parse: op" {
    const u = try parse("op://Personal/GitHub/email");
    try std.testing.expect(u.scheme == .op);
    try std.testing.expectEqualStrings("Personal/GitHub/email", u.payload);
}

test "parse: env" {
    const u = try parse("env:GITHUB_TOKEN");
    try std.testing.expect(u.scheme == .env);
    try std.testing.expectEqualStrings("GITHUB_TOKEN", u.payload);
}

test "parse: pass" {
    const u = try parse("pass://github/email");
    try std.testing.expect(u.scheme == .pass);
}

test "parse: file" {
    const u = try parse("file:///etc/secret");
    try std.testing.expect(u.scheme == .file);
    try std.testing.expectEqualStrings("/etc/secret", u.payload);
}

test "parse: cmd" {
    const u = try parse("cmd:pass show github/token");
    try std.testing.expect(u.scheme == .cmd);
    try std.testing.expectEqualStrings("pass show github/token", u.payload);
}

test "parse: cmd empty payload errors" {
    try std.testing.expectError(error.EmptyPayload, parse("cmd:"));
}

test "parse: unknown errors" {
    try std.testing.expectError(error.UnknownScheme, parse("ftp://foo"));
}

test "parse: empty payload errors" {
    try std.testing.expectError(error.EmptyPayload, parse("env:"));
}

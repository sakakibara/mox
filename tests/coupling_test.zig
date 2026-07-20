const std = @import("std");
const mox = @import("mox");

test "coupling integration: realistic email-shared-across-3-files scenario" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const before = [_]mox.coupling.divergence.FileSnapshot{
        .{ .id = "src/.gitconfig", .content =
        \\[user]
        \\    name = Ada Lovelace
        \\    email = ada@example.com
        },
        .{ .id = "src/.config/git/allowed_signers", .content = "ada@example.com namespaces=\"git\"" },
        .{ .id = "src/.zshrc", .content = "export EMAIL=ada@example.com" },
    };

    const after = [_]mox.coupling.divergence.FileSnapshot{
        .{ .id = "src/.gitconfig", .content =
        \\[user]
        \\    name = Ada Lovelace
        \\    email = ada@new-domain.com
        },
        .{ .id = "src/.config/git/allowed_signers", .content = "ada@example.com namespaces=\"git\"" },
        .{ .id = "src/.zshrc", .content = "export EMAIL=ada@example.com" },
    };

    const divs = try mox.coupling.divergence.detect(arena.allocator(), &before, &after, null);
    try std.testing.expectEqual(@as(usize, 1), divs.len);
    try std.testing.expectEqualStrings("ada@example.com", divs[0].token);
    try std.testing.expectEqual(@as(usize, 1), divs[0].files_changed.len);
    try std.testing.expectEqual(@as(usize, 2), divs[0].files_unchanged.len);
}

test "coupling integration: declined globally is silent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const before = [_]mox.coupling.divergence.FileSnapshot{
        .{ .id = "a", .content = "shared-token-1234 in file a" },
        .{ .id = "b", .content = "shared-token-1234 in file b" },
    };
    const after = [_]mox.coupling.divergence.FileSnapshot{
        .{ .id = "a", .content = "different-stuff in file a" },
        .{ .id = "b", .content = "shared-token-1234 in file b" },
    };

    var d = mox.coupling.decline.DeclineList.init(arena.allocator());
    try d.declineGlobal("shared-token-1234");

    const divs = try mox.coupling.divergence.detect(arena.allocator(), &before, &after, &d);
    try std.testing.expectEqual(@as(usize, 0), divs.len);
}

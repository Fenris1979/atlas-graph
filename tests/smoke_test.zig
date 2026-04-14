const std = @import("std");
const schema = @import("../src/graph/schema.zig");

test "language mapping smoke test" {
    try std.testing.expect(schema.languageFromPath("hello.zig") == .zig);
}

const std = @import("std");
const App = @import("app/app.zig").App;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    const repo_path = args.next() orelse ".";

    var app = try App.init(allocator, repo_path);
    defer app.deinit();

    try app.run();
}

test "project boots an application instance" {
    const allocator = std.testing.allocator;
    var app = try App.init(allocator, ".");
    defer app.deinit();

    try std.testing.expect(app.repo_path.len > 0);
}

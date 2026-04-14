const std = @import("std");
const IndexManager = @import("../index/index_manager.zig").IndexManager;
const Store = @import("../storage/store.zig").Store;
const ui_mod = @import("../ui/ui.zig");
const Ui = ui_mod.Ui;
const Spinner = ui_mod.Spinner;
const WebServer = @import("../web/server.zig").WebServer;

pub const App = struct {
    allocator: std.mem.Allocator,
    repo_path: []u8,
    store: Store,
    index_manager: IndexManager,
    ui: Ui,
    web_server: ?*WebServer = null,

    pub fn init(allocator: std.mem.Allocator, repo_path: []const u8) !App {
        const owned_repo_path = try allocator.dupe(u8, repo_path);
        errdefer allocator.free(owned_repo_path);

        var store = Store.init(allocator);
        errdefer store.deinit();

        return .{
            .allocator = allocator,
            .repo_path = owned_repo_path,
            .store = store,
            .index_manager = IndexManager.init(allocator),
            .ui = Ui.init(),
        };
    }

    pub fn deinit(self: *App) void {
        if (self.web_server) |ws| {
            ws.stop();
            self.allocator.destroy(ws);
            self.web_server = null;
        }
        self.ui.deinit();
        self.index_manager.deinit();
        self.store.deinit();
        self.allocator.free(self.repo_path);
    }

    pub fn run(self: *App) !void {
        try self.ui.printBanner();
        var spinner: Spinner = .{};
        spinner.start("Scanning repository...");
        var timer = try std.time.Timer.start();
        try self.store.open(self.repo_path);
        const summary = try self.index_manager.indexRepository(self.repo_path, &self.store);
        const elapsed = timer.read();
        spinner.stop();
        try self.ui.printSummary(self.repo_path, summary, elapsed);
        try self.ui.printSeparator();

        // Show graph stats
        const stats = try self.store.graphStats();
        try self.ui.printStats(stats);
        try self.ui.printHelp();

        // Interactive REPL
        try self.repl();
    }

    fn repl(self: *App) !void {
        const stdin = std.fs.File.stdin();
        var read_buf: [4096]u8 = undefined;
        var stdin_reader = stdin.reader(&read_buf);
        const reader = &stdin_reader.interface;

        while (true) {
            try self.ui.printPrompt();

            const line = reader.takeDelimiter('\n') catch {
                break; // read error, exit
            } orelse break; // EOF

            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            self.dispatch(trimmed) catch |err| {
                try self.ui.printError("Command failed", err);
            };
        }
    }

    fn dispatch(self: *App, line: []const u8) !void {
        // Split into command and argument
        var iter = std.mem.splitScalar(u8, line, ' ');
        const cmd = iter.first();
        const arg = std.mem.trim(u8, iter.rest(), " \t");

        if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "exit") or std.mem.eql(u8, cmd, "q")) {
            std.process.exit(0);
        } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "?")) {
            try self.ui.printHelp();
        } else if (std.mem.eql(u8, cmd, "stats")) {
            const stats = try self.store.graphStats();
            try self.ui.printStats(stats);
        } else if (std.mem.eql(u8, cmd, "find")) {
            if (arg.len == 0) {
                try self.ui.printMessage("Usage: find <name>");
                return;
            }
            const rows = try self.store.findSymbol(arg);
            defer self.store.freeNodeRows(rows);
            try self.ui.printNodeRows(rows, "symbols");
        } else if (std.mem.eql(u8, cmd, "file")) {
            if (arg.len == 0) {
                try self.ui.printMessage("Usage: file <path>");
                return;
            }
            const rows = try self.store.symbolsInFile(arg);
            defer self.store.freeNodeRows(rows);
            try self.ui.printNodeRows(rows, "symbols in file");
        } else if (std.mem.eql(u8, cmd, "imports")) {
            if (arg.len == 0) {
                try self.ui.printMessage("Usage: imports <path>");
                return;
            }
            const rows = try self.store.importsOf(arg);
            defer self.store.freeNodeRows(rows);
            try self.ui.printNodeRows(rows, "imports");
        } else if (std.mem.eql(u8, cmd, "importedby")) {
            if (arg.len == 0) {
                try self.ui.printMessage("Usage: importedby <path>");
                return;
            }
            const rows = try self.store.importedBy(arg);
            defer self.store.freeNodeRows(rows);
            try self.ui.printNodeRows(rows, "imported by");
        } else if (std.mem.eql(u8, cmd, "callers")) {
            if (arg.len == 0) {
                try self.ui.printMessage("Usage: callers <name>");
                return;
            }
            const rows = try self.store.callers(arg);
            defer self.store.freeNodeRows(rows);
            try self.ui.printNodeRows(rows, "callers");
        } else if (std.mem.eql(u8, cmd, "callees")) {
            if (arg.len == 0) {
                try self.ui.printMessage("Usage: callees <name>");
                return;
            }
            const rows = try self.store.callees(arg);
            defer self.store.freeNodeRows(rows);
            try self.ui.printNodeRows(rows, "callees");
        } else if (std.mem.eql(u8, cmd, "node")) {
            if (arg.len == 0) {
                try self.ui.printMessage("Usage: node <id>");
                return;
            }
            var node_opt = try self.store.getNode(arg);
            if (node_opt) |*node| {
                defer node.deinit(self.allocator);
                try self.ui.printNodeDetail(node.*);
            } else {
                try self.ui.printMessage("Node not found.");
            }
        } else if (std.mem.eql(u8, cmd, "edges")) {
            if (arg.len == 0) {
                try self.ui.printMessage("Usage: edges <node-id>");
                return;
            }
            const outgoing = try self.store.edgesFrom(arg);
            defer self.store.freeEdgeRows(outgoing);
            const incoming = try self.store.edgesTo(arg);
            defer self.store.freeEdgeRows(incoming);
            try self.ui.printEdges(outgoing, incoming);
        } else if (std.mem.eql(u8, cmd, "web")) {
            if (self.web_server != null) {
                try self.ui.printMessage("Web server already running.");
                return;
            }
            const port: u16 = if (arg.len > 0)
                std.fmt.parseInt(u16, arg, 10) catch 8080
            else
                8080;
            self.web_server = WebServer.start(self.allocator, &self.store, port) catch |err| {
                try self.ui.printError("Failed to start web server", err);
                return;
            };
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Web UI: http://127.0.0.1:{d}/", .{self.web_server.?.port}) catch "Web UI started";
            try self.ui.printMessage(msg);
        } else if (std.mem.eql(u8, cmd, "webstop")) {
            if (self.web_server) |ws| {
                ws.stop();
                self.allocator.destroy(ws);
                self.web_server = null;
                try self.ui.printMessage("Web server stopped.");
            } else {
                try self.ui.printMessage("Web server is not running.");
            }
        } else {
            try self.ui.printMessage("Unknown command. Type 'help' for usage.");
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────

const builtin = @import("builtin");
const native_os = builtin.os.tag;

/// Redirect stdout to a null device so UI output doesn't corrupt the
/// build-system IPC pipe used by `zig build test`.
/// Returns an opaque handle to pass to restoreStdout().
const SavedStdout = if (native_os == .windows) std.os.windows.HANDLE else std.posix.fd_t;

fn suppressStdout() !SavedStdout {
    if (native_os == .windows) {
        const kernel32 = std.os.windows.kernel32;
        const stdout_handle = kernel32.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) orelse return error.Unexpected;
        const nul = kernel32.CreateFileW(
            std.unicode.utf8ToUtf16LeStringLiteral("NUL"),
            std.os.windows.GENERIC_WRITE,
            0,
            null,
            std.os.windows.OPEN_EXISTING,
            0,
            null,
        ) orelse return error.Unexpected;
        _ = kernel32.SetStdHandle(std.os.windows.STD_OUTPUT_HANDLE, nul);
        return stdout_handle;
    } else {
        const stdout_fd = std.posix.STDOUT_FILENO;
        const saved = try std.posix.dup(stdout_fd);
        const devnull = try std.posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
        defer std.posix.close(devnull);
        try std.posix.dup2(devnull, stdout_fd);
        return saved;
    }
}

fn restoreStdout(saved: SavedStdout) void {
    if (native_os == .windows) {
        _ = std.os.windows.kernel32.SetStdHandle(std.os.windows.STD_OUTPUT_HANDLE, saved);
    } else {
        std.posix.dup2(saved, std.posix.STDOUT_FILENO) catch {};
        std.posix.close(saved);
    }
}

/// Helper: create an App backed by a temp dir with an indexed repo.
fn setupTestApp(tmp: *std.testing.TmpDir) !App {
    const allocator = std.testing.allocator;

    try tmp.dir.makeDir("repo");
    var repo_dir = try tmp.dir.openDir("repo", .{});
    defer repo_dir.close();

    try repo_dir.writeFile(.{
        .sub_path = "main.zig",
        .data =
        \\const lib = @import("lib.zig");
        \\
        \\pub fn main() void {
        \\    lib.helper();
        \\}
        ,
    });
    try repo_dir.writeFile(.{
        .sub_path = "lib.zig",
        .data =
        \\pub fn helper() void {}
        ,
    });

    const repo_path = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_path);

    var app = try App.init(allocator, repo_path);
    errdefer app.deinit();

    try app.store.open(app.repo_path);
    _ = try app.index_manager.indexRepository(app.repo_path, &app.store);

    return app;
}

test "dispatch: help command does not error" {
    const saved = try suppressStdout();
    defer restoreStdout(saved);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try setupTestApp(&tmp);
    defer app.deinit();

    try app.dispatch("help");
    try app.dispatch("?");
}

test "dispatch: stats command does not error" {
    const saved = try suppressStdout();
    defer restoreStdout(saved);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try setupTestApp(&tmp);
    defer app.deinit();

    try app.dispatch("stats");
}

test "dispatch: find command does not error" {
    const saved = try suppressStdout();
    defer restoreStdout(saved);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try setupTestApp(&tmp);
    defer app.deinit();

    try app.dispatch("find main");
    try app.dispatch("find nonexistent_symbol");
    // Missing arg — prints usage, no error
    try app.dispatch("find");
}

test "dispatch: file command does not error" {
    const saved = try suppressStdout();
    defer restoreStdout(saved);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try setupTestApp(&tmp);
    defer app.deinit();

    try app.dispatch("file main.zig");
    try app.dispatch("file");
}

test "dispatch: imports and importedby commands do not error" {
    const saved = try suppressStdout();
    defer restoreStdout(saved);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try setupTestApp(&tmp);
    defer app.deinit();

    try app.dispatch("imports main.zig");
    try app.dispatch("imports");
    try app.dispatch("importedby lib.zig");
    try app.dispatch("importedby");
}

test "dispatch: callers and callees commands do not error" {
    const saved = try suppressStdout();
    defer restoreStdout(saved);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try setupTestApp(&tmp);
    defer app.deinit();

    try app.dispatch("callers helper");
    try app.dispatch("callers");
    try app.dispatch("callees main");
    try app.dispatch("callees");
}

test "dispatch: node and edges commands do not error" {
    const saved = try suppressStdout();
    defer restoreStdout(saved);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try setupTestApp(&tmp);
    defer app.deinit();

    try app.dispatch("node function:main.zig:main");
    try app.dispatch("node nonexistent_id");
    try app.dispatch("node");
    try app.dispatch("edges function:main.zig:main");
    try app.dispatch("edges");
}

test "dispatch: unknown command does not error" {
    const saved = try suppressStdout();
    defer restoreStdout(saved);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var app = try setupTestApp(&tmp);
    defer app.deinit();

    try app.dispatch("totally_unknown_command");
}

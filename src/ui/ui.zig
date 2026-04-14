const std = @import("std");
const IndexSummary = @import("../index/index_manager.zig").IndexSummary;
const Store = @import("../storage/store.zig").Store;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.fs.File.stdout().write(slice) catch {};
}

fn outStr(s: []const u8) void {
    _ = std.fs.File.stdout().write(s) catch {};
}

pub const Spinner = struct {
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

    /// Call on an already-placed var so the thread gets a stable pointer.
    pub fn start(self: *Spinner, message: []const u8) void {
        self.stop_flag.store(false, .release);
        self.thread = std.Thread.spawn(.{}, run, .{ &self.stop_flag, message }) catch null;
    }

    fn run(stop_flag: *std.atomic.Value(bool), message: []const u8) void {
        var i: usize = 0;
        while (!stop_flag.load(.acquire)) {
            var buf: [256]u8 = undefined;
            const frame = frames[i % frames.len];
            const slice = std.fmt.bufPrint(&buf, "\r{s} {s}", .{ frame, message }) catch break;
            _ = std.fs.File.stdout().write(slice) catch {};
            i += 1;
            std.Thread.sleep(80 * std.time.ns_per_ms);
        }
        outStr("\r\x1b[2K"); // clear the spinner line
    }

    pub fn stop(self: *Spinner) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }
};

pub const Ui = struct {
    pub fn init() Ui {
        return .{};
    }

    pub fn deinit(_: *Ui) void {}

    pub fn printBanner(_: *Ui) !void {
        outStr("Atlas Graph\n");
    }

    pub fn printSummary(_: *Ui, repo_path: []const u8, summary: IndexSummary, elapsed_ns: u64) !void {
        const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
        out("\nRepository: {s}\n", .{repo_path});
        out("  Files: {} ({} zig, {} c-family, {} other)\n", .{
            summary.files_seen, summary.zig_files, summary.c_family_files, summary.other_files,
        });
        out("  Graph: {} nodes, {} edges\n", .{ summary.nodes_written, summary.edges_written });
        out("  Extracted: {} symbols, {} imports, {} calls\n", .{ summary.symbols_extracted, summary.imports_extracted, summary.calls_extracted });
        if (elapsed_ms >= 1000) {
            out("  Indexed in {d}.{d:0>3}s\n", .{ elapsed_ms / 1000, elapsed_ms % 1000 });
        } else {
            out("  Indexed in {}ms\n", .{elapsed_ms});
        }
    }

    pub fn printSeparator(_: *Ui) !void {
        outStr("────────────────────────────────────────\n");
    }

    pub fn printStats(_: *Ui, stats: Store.GraphStats) !void {
        out("Graph: {} nodes, {} edges\n", .{ stats.total_nodes, stats.total_edges });
        out("  Files: {}  Functions: {}  Types: {}  Tests: {}\n", .{
            stats.files, stats.functions, stats.structures, stats.tests,
        });
        out("  Edges: {} imports, {} calls\n", .{ stats.imports_edges, stats.calls_edges });
    }

    pub fn printHelp(_: *Ui) !void {
        outStr(
            \\
            \\Commands:
            \\  find <name>        Search symbols by name
            \\  file <path>        List symbols defined in a file
            \\  imports <path>     Show what a file imports
            \\  importedby <path>  Show what files import a file
            \\  callers <name>     Show functions that call <name>
            \\  callees <name>     Show functions that <name> calls
            \\  node <id>          Show details for a node by ID
            \\  edges <id>         Show all edges for a node
            \\  web [port]         Start web UI (default port 8080)
            \\  webstop            Stop web UI
            \\  stats              Show graph statistics
            \\  help               Show this help
            \\  quit               Exit
            \\
            \\
        );
    }

    pub fn printPrompt(_: *Ui) !void {
        outStr("atlas> ");
    }

    pub fn printMessage(_: *Ui, msg: []const u8) !void {
        out("{s}\n", .{msg});
    }

    pub fn printError(_: *Ui, context: []const u8, err: anyerror) !void {
        out("Error: {s}: {}\n", .{ context, err });
    }

    pub fn printNodeRows(_: *Ui, rows: []Store.NodeRow, label: []const u8) !void {
        if (rows.len == 0) {
            out("No {s} found.\n", .{label});
            return;
        }

        out("{} {s}:\n", .{ rows.len, label });
        for (rows) |row| {
            if (row.start_line > 0) {
                out("  {s: <12} {s: <30} {s}:{}\n", .{
                    row.kind, row.name, row.path, row.start_line,
                });
            } else {
                out("  {s: <12} {s: <30} {s}\n", .{
                    row.kind, row.name, row.path,
                });
            }
        }
    }

    pub fn printNodeDetail(_: *Ui, node: Store.NodeRow) !void {
        out("Node: {s}\n", .{node.id});
        out("  Kind: {s}\n", .{node.kind});
        out("  Lang: {s}\n", .{node.lang});
        out("  Name: {s}\n", .{node.name});
        out("  Path: {s}\n", .{node.path});
        if (node.start_line > 0) {
            out("  Lines: {}-{}\n", .{ node.start_line, node.end_line });
        }
    }

    pub fn printEdges(_: *Ui, outgoing: []Store.EdgeRow, incoming: []Store.EdgeRow) !void {
        if (outgoing.len == 0 and incoming.len == 0) {
            outStr("No edges found.\n");
            return;
        }

        if (outgoing.len > 0) {
            out("{} outgoing:\n", .{outgoing.len});
            for (outgoing) |e| {
                out("  --{s}--> {s}\n", .{ e.kind, e.dst_id });
            }
        }
        if (incoming.len > 0) {
            out("{} incoming:\n", .{incoming.len});
            for (incoming) |e| {
                out("  <--{s}-- {s}\n", .{ e.kind, e.src_id });
            }
        }
    }
};

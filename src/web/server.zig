const std = @import("std");
const Store = @import("../storage/store.zig").Store;
const http = std.http;
const net = std.net;
const Io = std.Io;

const index_html = @embedFile("index.html");

pub const WebServer = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    tcp_server: net.Server,
    thread: ?std.Thread = null,
    shutdown: std.atomic.Value(bool),
    port: u16,

    pub fn start(allocator: std.mem.Allocator, store: *Store, requested_port: u16) !*WebServer {
        const address = try net.Address.parseIp("127.0.0.1", requested_port);
        var tcp_server = try address.listen(.{ .reuse_address = true });

        const self = try allocator.create(WebServer);
        self.* = .{
            .allocator = allocator,
            .store = store,
            .tcp_server = tcp_server,
            .shutdown = std.atomic.Value(bool).init(false),
            .port = tcp_server.listen_address.in.getPort(),
        };

        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    pub fn stop(self: *WebServer) void {
        self.shutdown.store(true, .release);
        // Close the listening socket to unblock accept()
        self.tcp_server.stream.close();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn acceptLoop(self: *WebServer) void {
        while (!self.shutdown.load(.acquire)) {
            const conn = self.tcp_server.accept() catch {
                continue;
            };
            const thread = std.Thread.spawn(.{}, handleConnectionThread, .{ self, conn }) catch {
                conn.stream.close();
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnectionThread(self: *WebServer, conn: net.Server.Connection) void {
        defer conn.stream.close();

        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var stream_reader = conn.stream.reader(&read_buf);
        var stream_writer = conn.stream.writer(&write_buf);

        var server = http.Server.init(stream_reader.interface(), &stream_writer.interface);

        // Handle one request per connection (no keep-alive)
        var request = server.receiveHead() catch return;
        self.handleRequest(&request) catch return;
    }

    fn handleRequest(self: *WebServer, request: *http.Server.Request) !void {
        const target = request.head.target;

        // Route: GET /
        if (std.mem.eql(u8, target, "/")) {
            return respondHtml(request, index_html);
        }

        // Route: GET /api/stats
        if (std.mem.eql(u8, target, "/api/stats")) {
            return self.serveStats(request);
        }

        // Route: GET /api/graph
        if (std.mem.eql(u8, target, "/api/graph")) {
            return self.serveGraph(request);
        }

        // Routes with query parameters
        if (std.mem.startsWith(u8, target, "/api/nodes?")) {
            const q = parseQueryParam(target, "q") orelse "";
            return self.serveNodeSearch(request, q);
        }
        if (std.mem.startsWith(u8, target, "/api/node?")) {
            const id = parseQueryParam(target, "id") orelse "";
            return self.serveNode(request, id);
        }
        if (std.mem.startsWith(u8, target, "/api/edges?")) {
            const id = parseQueryParam(target, "id") orelse "";
            return self.serveEdges(request, id);
        }
        if (std.mem.startsWith(u8, target, "/api/callers?")) {
            const name = parseQueryParam(target, "name") orelse "";
            return self.serveCallers(request, name);
        }
        if (std.mem.startsWith(u8, target, "/api/callees?")) {
            const name = parseQueryParam(target, "name") orelse "";
            return self.serveCallees(request, name);
        }
        if (std.mem.startsWith(u8, target, "/api/imports?")) {
            const path = parseQueryParam(target, "path") orelse "";
            return self.serveImports(request, path);
        }
        if (std.mem.startsWith(u8, target, "/api/importedby?")) {
            const path = parseQueryParam(target, "path") orelse "";
            return self.serveImportedBy(request, path);
        }
        if (std.mem.startsWith(u8, target, "/api/file/symbols?")) {
            const path = parseQueryParam(target, "path") orelse "";
            return self.serveFileSymbols(request, path);
        }

        // 404
        try request.respond("Not Found", .{ .status = .not_found, .keep_alive = false });
    }

    // ── Route handlers ──────────────────────────────────────────

    fn serveStats(self: *WebServer, request: *http.Server.Request) !void {
        const stats = try self.store.graphStats();
        var out: Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer };

        try jw.beginObject();
        try jw.objectField("total_nodes");
        try jw.write(stats.total_nodes);
        try jw.objectField("total_edges");
        try jw.write(stats.total_edges);
        try jw.objectField("files");
        try jw.write(stats.files);
        try jw.objectField("functions");
        try jw.write(stats.functions);
        try jw.objectField("structures");
        try jw.write(stats.structures);
        try jw.objectField("tests");
        try jw.write(stats.tests);
        try jw.objectField("imports_edges");
        try jw.write(stats.imports_edges);
        try jw.objectField("calls_edges");
        try jw.write(stats.calls_edges);
        try jw.endObject();

        try respondJson(request, out.written());
    }

    fn serveGraph(self: *WebServer, request: *http.Server.Request) !void {
        const nodes = try self.store.allNodes();
        defer self.store.freeNodeRows(nodes);
        const edges = try self.store.allEdges();
        defer self.store.freeEdgeRows(edges);

        var out: Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer };

        try jw.beginObject();
        try jw.objectField("nodes");
        try writeNodeRowsJson(&jw, nodes);
        try jw.objectField("edges");
        try writeEdgeRowsJson(&jw, edges);
        try jw.endObject();

        try respondJson(request, out.written());
    }

    fn serveNodeSearch(self: *WebServer, request: *http.Server.Request, query: []const u8) !void {
        if (query.len == 0) {
            try respondJson(request, "[]");
            return;
        }
        const decoded = try percentDecode(self.allocator, query);
        defer self.allocator.free(decoded);

        const rows = try self.store.findSymbol(decoded);
        defer self.store.freeNodeRows(rows);

        var out: Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        try writeNodeRowsJson(&jw, rows);
        try respondJson(request, out.written());
    }

    fn serveNode(self: *WebServer, request: *http.Server.Request, id: []const u8) !void {
        if (id.len == 0) {
            try request.respond("{\"error\":\"missing id\"}", .{
                .status = .bad_request,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        }
        const decoded = try percentDecode(self.allocator, id);
        defer self.allocator.free(decoded);

        var node_opt = try self.store.getNode(decoded);
        if (node_opt) |*node| {
            defer node.deinit(self.allocator);
            var out: Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            var jw: std.json.Stringify = .{ .writer = &out.writer };
            try writeOneNodeJson(&jw, node.*);
            try respondJson(request, out.written());
        } else {
            try request.respond("{\"error\":\"not found\"}", .{
                .status = .not_found,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
        }
    }

    fn serveEdges(self: *WebServer, request: *http.Server.Request, id: []const u8) !void {
        if (id.len == 0) {
            try respondJson(request, "{\"outgoing\":[],\"incoming\":[]}");
            return;
        }
        const decoded = try percentDecode(self.allocator, id);
        defer self.allocator.free(decoded);

        const outgoing = try self.store.edgesFrom(decoded);
        defer self.store.freeEdgeRows(outgoing);
        const incoming = try self.store.edgesTo(decoded);
        defer self.store.freeEdgeRows(incoming);

        var out: Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer };

        try jw.beginObject();
        try jw.objectField("outgoing");
        try writeEdgeRowsJson(&jw, outgoing);
        try jw.objectField("incoming");
        try writeEdgeRowsJson(&jw, incoming);
        try jw.endObject();

        try respondJson(request, out.written());
    }

    fn serveCallers(self: *WebServer, request: *http.Server.Request, name: []const u8) !void {
        const decoded = try percentDecode(self.allocator, name);
        defer self.allocator.free(decoded);
        const rows = try self.store.callers(decoded);
        defer self.store.freeNodeRows(rows);
        try respondNodeRows(self, request, rows);
    }

    fn serveCallees(self: *WebServer, request: *http.Server.Request, name: []const u8) !void {
        const decoded = try percentDecode(self.allocator, name);
        defer self.allocator.free(decoded);
        const rows = try self.store.callees(decoded);
        defer self.store.freeNodeRows(rows);
        try respondNodeRows(self, request, rows);
    }

    fn serveImports(self: *WebServer, request: *http.Server.Request, path: []const u8) !void {
        const decoded = try percentDecode(self.allocator, path);
        defer self.allocator.free(decoded);
        const rows = try self.store.importsOf(decoded);
        defer self.store.freeNodeRows(rows);
        try respondNodeRows(self, request, rows);
    }

    fn serveImportedBy(self: *WebServer, request: *http.Server.Request, path: []const u8) !void {
        const decoded = try percentDecode(self.allocator, path);
        defer self.allocator.free(decoded);
        const rows = try self.store.importedBy(decoded);
        defer self.store.freeNodeRows(rows);
        try respondNodeRows(self, request, rows);
    }

    fn serveFileSymbols(self: *WebServer, request: *http.Server.Request, path: []const u8) !void {
        const decoded = try percentDecode(self.allocator, path);
        defer self.allocator.free(decoded);
        const rows = try self.store.symbolsInFile(decoded);
        defer self.store.freeNodeRows(rows);
        try respondNodeRows(self, request, rows);
    }

    // ── Helpers ──────────────────────────────────────────────────

    fn respondNodeRows(self: *WebServer, request: *http.Server.Request, rows: []Store.NodeRow) !void {
        var out: Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        try writeNodeRowsJson(&jw, rows);
        try respondJson(request, out.written());
    }

    fn respondJson(request: *http.Server.Request, body: []const u8) !void {
        try request.respond(body, .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "access-control-allow-origin", .value = "*" },
            },
        });
    }

    fn respondHtml(request: *http.Server.Request, html: []const u8) !void {
        try request.respond(html, .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    // ── JSON serializers ────────────────────────────────────────

    fn writeNodeRowsJson(jw: *std.json.Stringify, rows: []Store.NodeRow) !void {
        try jw.beginArray();
        for (rows) |row| {
            try writeOneNodeJson(jw, row);
        }
        try jw.endArray();
    }

    fn writeOneNodeJson(jw: *std.json.Stringify, row: Store.NodeRow) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(row.id);
        try jw.objectField("kind");
        try jw.write(row.kind);
        try jw.objectField("lang");
        try jw.write(row.lang);
        try jw.objectField("name");
        try jw.write(row.name);
        try jw.objectField("path");
        try jw.write(row.path);
        try jw.objectField("start_line");
        try jw.write(row.start_line);
        try jw.objectField("end_line");
        try jw.write(row.end_line);
        try jw.endObject();
    }

    fn writeEdgeRowsJson(jw: *std.json.Stringify, rows: []Store.EdgeRow) !void {
        try jw.beginArray();
        for (rows) |row| {
            try jw.beginObject();
            try jw.objectField("src_id");
            try jw.write(row.src_id);
            try jw.objectField("dst_id");
            try jw.write(row.dst_id);
            try jw.objectField("kind");
            try jw.write(row.kind);
            try jw.objectField("confidence");
            try jw.write(row.confidence);
            try jw.endObject();
        }
        try jw.endArray();
    }

    // ── URL parsing ─────────────────────────────────────────────

    fn parseQueryParam(target: []const u8, param_name: []const u8) ?[]const u8 {
        const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
        var rest = target[query_start + 1 ..];

        while (rest.len > 0) {
            // Find next & or end
            const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
            const pair = rest[0..amp];

            // Split on =
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
                rest = if (amp < rest.len) rest[amp + 1 ..] else rest[rest.len..];
                continue;
            };

            const key = pair[0..eq];
            const val = pair[eq + 1 ..];

            if (std.mem.eql(u8, key, param_name)) {
                return val;
            }

            rest = if (amp < rest.len) rest[amp + 1 ..] else rest[rest.len..];
        }

        return null;
    }

    fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var result = std.ArrayListUnmanaged(u8){};
        defer result.deinit(allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '%' and i + 2 < input.len) {
                const high = hexDigit(input[i + 1]) orelse {
                    try result.append(allocator, input[i]);
                    i += 1;
                    continue;
                };
                const low = hexDigit(input[i + 2]) orelse {
                    try result.append(allocator, input[i]);
                    i += 1;
                    continue;
                };
                try result.append(allocator, (high << 4) | low);
                i += 3;
            } else if (input[i] == '+') {
                try result.append(allocator, ' ');
                i += 1;
            } else {
                try result.append(allocator, input[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn hexDigit(ch: u8) ?u8 {
        if (ch >= '0' and ch <= '9') return ch - '0';
        if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
        if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
        return null;
    }
};

// ── Tests ──────────────────────────────────────────────────────

test "parseQueryParam extracts values" {
    // Single parameter
    try std.testing.expectEqualStrings("hello", WebServer.parseQueryParam("/api/nodes?q=hello", "q").?);

    // Multiple parameters
    try std.testing.expectEqualStrings("world", WebServer.parseQueryParam("/api/test?a=1&name=world&c=3", "name").?);

    // First parameter among several
    try std.testing.expectEqualStrings("1", WebServer.parseQueryParam("/api/test?a=1&b=2", "a").?);

    // Last parameter
    try std.testing.expectEqualStrings("2", WebServer.parseQueryParam("/api/test?a=1&b=2", "b").?);

    // Missing parameter
    try std.testing.expect(WebServer.parseQueryParam("/api/test?a=1", "missing") == null);

    // No query string
    try std.testing.expect(WebServer.parseQueryParam("/api/test", "q") == null);

    // Empty value
    try std.testing.expectEqualStrings("", WebServer.parseQueryParam("/api/test?q=", "q").?);

    // Parameter with encoded value (raw, not decoded)
    try std.testing.expectEqualStrings("foo%20bar", WebServer.parseQueryParam("/api/test?q=foo%20bar", "q").?);
}

test "percentDecode decodes URL-encoded strings" {
    const allocator = std.testing.allocator;

    // Simple string, no encoding
    const r1 = try WebServer.percentDecode(allocator, "hello");
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("hello", r1);

    // Space encoded as %20
    const r2 = try WebServer.percentDecode(allocator, "hello%20world");
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("hello world", r2);

    // Plus sign decoded as space
    const r3 = try WebServer.percentDecode(allocator, "hello+world");
    defer allocator.free(r3);
    try std.testing.expectEqualStrings("hello world", r3);

    // Multiple encoded characters
    const r4 = try WebServer.percentDecode(allocator, "%48%65%6C%6C%6F");
    defer allocator.free(r4);
    try std.testing.expectEqualStrings("Hello", r4);

    // Mixed encoded and plain
    const r5 = try WebServer.percentDecode(allocator, "foo%2Fbar%3Fbaz");
    defer allocator.free(r5);
    try std.testing.expectEqualStrings("foo/bar?baz", r5);

    // Invalid percent sequence (not enough chars) — passes through
    const r6 = try WebServer.percentDecode(allocator, "abc%2");
    defer allocator.free(r6);
    try std.testing.expectEqualStrings("abc%2", r6);

    // Empty string
    const r7 = try WebServer.percentDecode(allocator, "");
    defer allocator.free(r7);
    try std.testing.expectEqualStrings("", r7);
}

test "hexDigit converts hex characters" {
    // Digits
    try std.testing.expectEqual(@as(u8, 0), WebServer.hexDigit('0').?);
    try std.testing.expectEqual(@as(u8, 9), WebServer.hexDigit('9').?);

    // Lowercase hex
    try std.testing.expectEqual(@as(u8, 10), WebServer.hexDigit('a').?);
    try std.testing.expectEqual(@as(u8, 15), WebServer.hexDigit('f').?);

    // Uppercase hex
    try std.testing.expectEqual(@as(u8, 10), WebServer.hexDigit('A').?);
    try std.testing.expectEqual(@as(u8, 15), WebServer.hexDigit('F').?);

    // Invalid characters
    try std.testing.expect(WebServer.hexDigit('g') == null);
    try std.testing.expect(WebServer.hexDigit('z') == null);
    try std.testing.expect(WebServer.hexDigit(' ') == null);
}

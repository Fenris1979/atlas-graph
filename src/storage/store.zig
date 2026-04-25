const std = @import("std");
const schema = @import("../graph/schema.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});


pub const StoreError = error{
    SqliteOpenFailed,
    SqliteExecFailed,
    SqlitePrepareFailed,
    SqliteStepFailed,
    SqliteBindFailed,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3 = null,
    project_root: ?[]u8 = null,
    db_path: ?[]u8 = null,
    // Cached prepared statements for bulk insert performance
    cached_insert_node: ?*c.sqlite3_stmt = null,
    cached_insert_edge: ?*c.sqlite3_stmt = null,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        self.close();

        if (self.project_root) |root| self.allocator.free(root);
        if (self.db_path) |path| self.allocator.free(path);

        self.project_root = null;
        self.db_path = null;
    }

    pub fn open(self: *Store, repo_path: []const u8) !void {
        self.close();

        if (self.project_root) |root| self.allocator.free(root);
        if (self.db_path) |path| self.allocator.free(path);
        self.project_root = null;
        self.db_path = null;

        self.project_root = try self.allocator.dupe(u8, repo_path);
        errdefer {
            if (self.project_root) |root| self.allocator.free(root);
            self.project_root = null;
        }

        const storage_dir = try std.fs.path.join(self.allocator, &.{ repo_path, ".atlas-graph" });
        defer self.allocator.free(storage_dir);
        try std.fs.cwd().makePath(storage_dir);

        self.db_path = try std.fs.path.join(self.allocator, &.{ storage_dir, "atlas-graph.db" });
        errdefer {
            if (self.db_path) |path| self.allocator.free(path);
            self.db_path = null;
        }

        try self.openDatabase(self.db_path.?);
        errdefer self.close();

        try self.configureDatabase();
        try self.migrate();
        try self.upsertProjectMetadata();
    }

    pub fn close(self: *Store) void {
        if (self.cached_insert_node) |s| _ = c.sqlite3_finalize(s);
        if (self.cached_insert_edge) |s| _ = c.sqlite3_finalize(s);
        self.cached_insert_node = null;
        self.cached_insert_edge = null;
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    pub fn getDatabasePath(self: *const Store) ?[]const u8 {
        return self.db_path;
    }

    pub fn countNodes(self: *Store) !i64 {
        const sql = "SELECT COUNT(*) FROM nodes;";
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_ROW) return StoreError.SqliteStepFailed;

        return c.sqlite3_column_int64(stmt, 0);
    }

    pub fn beginTransaction(self: *Store) !void {
        try self.exec("BEGIN TRANSACTION;");
    }

    pub fn commitTransaction(self: *Store) !void {
        try self.exec("COMMIT;");
    }

    pub fn nodeExists(self: *Store, id: []const u8) !bool {
        const sql = "SELECT 1 FROM nodes WHERE id = ?1 LIMIT 1;";
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, id);
        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }

    pub fn insertNode(self: *Store, node: schema.Node) !void {
        const stmt = self.cached_insert_node orelse blk: {
            const sql =
                \\INSERT INTO nodes(id, kind, lang, name, path, start_line, end_line)
                \\VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
                \\ON CONFLICT(id) DO UPDATE SET
                \\  kind = excluded.kind,
                \\  lang = excluded.lang,
                \\  name = excluded.name,
                \\  path = excluded.path,
                \\  start_line = excluded.start_line,
                \\  end_line = excluded.end_line;
            ;
            const s = try self.prepare(sql);
            self.cached_insert_node = s;
            break :blk s;
        };
        _ = c.sqlite3_reset(stmt);

        try self.bindText(stmt, 1, node.id);
        try self.bindText(stmt, 2, @tagName(node.kind));
        try self.bindText(stmt, 3, @tagName(node.lang));
        try self.bindText(stmt, 4, node.name);
        try self.bindText(stmt, 5, node.path);

        if (c.sqlite3_bind_int(stmt, 6, @as(c_int, @intCast(node.start_line))) != c.SQLITE_OK)
            return StoreError.SqliteBindFailed;
        if (c.sqlite3_bind_int(stmt, 7, @as(c_int, @intCast(node.end_line))) != c.SQLITE_OK)
            return StoreError.SqliteBindFailed;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return StoreError.SqliteStepFailed;
    }

    pub fn insertEdge(self: *Store, edge: schema.Edge) !void {
        const stmt = self.cached_insert_edge orelse blk: {
            const sql =
                \\INSERT OR IGNORE INTO edges(src_id, dst_id, kind, confidence)
                \\VALUES(?1, ?2, ?3, ?4);
            ;
            const s = try self.prepare(sql);
            self.cached_insert_edge = s;
            break :blk s;
        };
        _ = c.sqlite3_reset(stmt);

        try self.bindText(stmt, 1, edge.src_id);
        try self.bindText(stmt, 2, edge.dst_id);
        try self.bindText(stmt, 3, @tagName(edge.kind));

        if (c.sqlite3_bind_double(stmt, 4, @as(f64, edge.confidence)) != c.SQLITE_OK)
            return StoreError.SqliteBindFailed;

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return StoreError.SqliteStepFailed;
    }

    pub fn countEdges(self: *Store) !i64 {
        const sql = "SELECT COUNT(*) FROM edges;";
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_ROW) return StoreError.SqliteStepFailed;

        return c.sqlite3_column_int64(stmt, 0);
    }

    // ── Query methods ──────────────────────────────────────────────

    pub const NodeRow = struct {
        id: []u8,
        kind: []u8,
        lang: []u8,
        name: []u8,
        path: []u8,
        start_line: i32,
        end_line: i32,

        pub fn deinit(self: *NodeRow, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.kind);
            allocator.free(self.lang);
            allocator.free(self.name);
            allocator.free(self.path);
        }
    };

    pub const EdgeRow = struct {
        src_id: []u8,
        dst_id: []u8,
        kind: []u8,
        confidence: f64,

        pub fn deinit(self: *EdgeRow, allocator: std.mem.Allocator) void {
            allocator.free(self.src_id);
            allocator.free(self.dst_id);
            allocator.free(self.kind);
        }
    };

    pub fn freeNodeRows(self: *Store, rows: []NodeRow) void {
        for (rows) |*r| r.deinit(self.allocator);
        self.allocator.free(rows);
    }

    pub fn freeEdgeRows(self: *Store, rows: []EdgeRow) void {
        for (rows) |*r| r.deinit(self.allocator);
        self.allocator.free(rows);
    }

    /// Search nodes by name (case-insensitive substring match). Max 50 results.
    pub fn findSymbol(self: *Store, name: []const u8) ![]NodeRow {
        const pattern = try std.fmt.allocPrint(self.allocator, "%{s}%", .{name});
        defer self.allocator.free(pattern);

        const sql =
            \\SELECT id, kind, lang, name, path, start_line, end_line
            \\FROM nodes
            \\WHERE name LIKE ?1 AND kind != 'repository' AND kind != 'file' AND kind != 'directory'
            \\ORDER BY
            \\  CASE WHEN name = ?2 THEN 0 ELSE 1 END,
            \\  name
            \\LIMIT 50;
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, pattern);
        try self.bindText(stmt, 2, name);

        return self.collectNodeRows(stmt);
    }

    /// All symbols defined in a file (by path substring match).
    pub fn symbolsInFile(self: *Store, path: []const u8) ![]NodeRow {
        const sql =
            \\SELECT n.id, n.kind, n.lang, n.name, n.path, n.start_line, n.end_line
            \\FROM nodes n
            \\JOIN edges e ON e.dst_id = n.id AND e.kind = 'defines'
            \\JOIN nodes f ON f.id = e.src_id AND f.kind = 'file'
            \\WHERE f.path LIKE ?1
            \\ORDER BY n.start_line;
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        const pattern = try std.fmt.allocPrint(self.allocator, "%{s}%", .{path});
        defer self.allocator.free(pattern);
        try self.bindText(stmt, 1, pattern);

        return self.collectNodeRows(stmt);
    }

    /// Files that a given file imports (outgoing import edges).
    pub fn importsOf(self: *Store, path: []const u8) ![]NodeRow {
        const sql =
            \\SELECT dst.id, dst.kind, dst.lang, dst.name, dst.path, dst.start_line, dst.end_line
            \\FROM edges e
            \\JOIN nodes src ON src.id = e.src_id AND src.kind = 'file'
            \\JOIN nodes dst ON dst.id = e.dst_id
            \\WHERE e.kind IN ('imports', 'includes') AND src.path LIKE ?1
            \\ORDER BY dst.path;
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        const pattern = try std.fmt.allocPrint(self.allocator, "%{s}%", .{path});
        defer self.allocator.free(pattern);
        try self.bindText(stmt, 1, pattern);

        return self.collectNodeRows(stmt);
    }

    /// Files that import a given file (incoming import edges).
    pub fn importedBy(self: *Store, path: []const u8) ![]NodeRow {
        const sql =
            \\SELECT src.id, src.kind, src.lang, src.name, src.path, src.start_line, src.end_line
            \\FROM edges e
            \\JOIN nodes src ON src.id = e.src_id
            \\JOIN nodes dst ON dst.id = e.dst_id AND dst.kind = 'file'
            \\WHERE e.kind IN ('imports', 'includes') AND dst.path LIKE ?1
            \\ORDER BY src.path;
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        const pattern = try std.fmt.allocPrint(self.allocator, "%{s}%", .{path});
        defer self.allocator.free(pattern);
        try self.bindText(stmt, 1, pattern);

        return self.collectNodeRows(stmt);
    }

    /// Find function node IDs by exact name. Returns up to `limit` IDs.
    pub fn findFunctionIdsByName(self: *Store, name: []const u8) ![][]u8 {
        const sql =
            \\SELECT id FROM nodes
            \\WHERE kind = 'function' AND name = ?1
            \\LIMIT 10;
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, name);

        var ids: std.ArrayListUnmanaged([]u8) = .{};
        defer ids.deinit(self.allocator);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try ids.append(self.allocator, try self.columnTextAlloc(stmt, 0));
        }

        return ids.toOwnedSlice(self.allocator);
    }

    pub fn freeFunctionIds(self: *Store, ids: [][]u8) void {
        for (ids) |id| self.allocator.free(id);
        self.allocator.free(ids);
    }

    /// Functions that call a given function (by name substring match).
    pub fn callers(self: *Store, name: []const u8) ![]NodeRow {
        const pattern = try std.fmt.allocPrint(self.allocator, "%{s}%", .{name});
        defer self.allocator.free(pattern);

        const sql =
            \\SELECT DISTINCT src.id, src.kind, src.lang, src.name, src.path, src.start_line, src.end_line
            \\FROM edges e
            \\JOIN nodes dst ON dst.id = e.dst_id
            \\JOIN nodes src ON src.id = e.src_id
            \\WHERE e.kind = 'calls' AND dst.name LIKE ?1
            \\ORDER BY src.path, src.start_line;
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, pattern);
        return self.collectNodeRows(stmt);
    }

    /// Functions that a given function calls (by name substring match).
    pub fn callees(self: *Store, name: []const u8) ![]NodeRow {
        const pattern = try std.fmt.allocPrint(self.allocator, "%{s}%", .{name});
        defer self.allocator.free(pattern);

        const sql =
            \\SELECT DISTINCT dst.id, dst.kind, dst.lang, dst.name, dst.path, dst.start_line, dst.end_line
            \\FROM edges e
            \\JOIN nodes src ON src.id = e.src_id
            \\JOIN nodes dst ON dst.id = e.dst_id
            \\WHERE e.kind = 'calls' AND src.name LIKE ?1
            \\ORDER BY dst.path, dst.start_line;
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, pattern);
        return self.collectNodeRows(stmt);
    }

    /// All outgoing edges from a node.
    pub fn edgesFrom(self: *Store, node_id: []const u8) ![]EdgeRow {
        const sql =
            \\SELECT src_id, dst_id, kind, confidence
            \\FROM edges WHERE src_id = ?1
            \\ORDER BY kind, dst_id;
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, node_id);
        return self.collectEdgeRows(stmt);
    }

    /// All incoming edges to a node.
    pub fn edgesTo(self: *Store, node_id: []const u8) ![]EdgeRow {
        const sql =
            \\SELECT src_id, dst_id, kind, confidence
            \\FROM edges WHERE dst_id = ?1
            \\ORDER BY kind, src_id;
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, node_id);
        return self.collectEdgeRows(stmt);
    }

    /// Look up a single node by exact ID.
    pub fn getNode(self: *Store, node_id: []const u8) !?NodeRow {
        const sql =
            \\SELECT id, kind, lang, name, path, start_line, end_line
            \\FROM nodes WHERE id = ?1;
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        try self.bindText(stmt, 1, node_id);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return try self.readNodeRow(stmt);
    }

    /// Graph-wide stats.
    pub const GraphStats = struct {
        total_nodes: i64,
        total_edges: i64,
        files: i64,
        functions: i64,
        structures: i64,
        tests: i64,
        imports_edges: i64,
        calls_edges: i64,
    };

    pub fn graphStats(self: *Store) !GraphStats {
        var stats = GraphStats{
            .total_nodes = try self.countNodes(),
            .total_edges = try self.countEdges(),
            .files = 0,
            .functions = 0,
            .structures = 0,
            .tests = 0,
            .imports_edges = 0,
            .calls_edges = 0,
        };

        const kinds = [_]struct { sql: []const u8, field: enum { files, functions, structures, tests, imports_edges, calls_edges } }{
            .{ .sql = "SELECT COUNT(*) FROM nodes WHERE kind = 'file';", .field = .files },
            .{ .sql = "SELECT COUNT(*) FROM nodes WHERE kind = 'function';", .field = .functions },
            .{ .sql = "SELECT COUNT(*) FROM nodes WHERE kind IN ('structure','enumeration','union_type');", .field = .structures },
            .{ .sql = "SELECT COUNT(*) FROM nodes WHERE kind = 'test_block';", .field = .tests },
            .{ .sql = "SELECT COUNT(*) FROM edges WHERE kind = 'imports';", .field = .imports_edges },
            .{ .sql = "SELECT COUNT(*) FROM edges WHERE kind = 'calls';", .field = .calls_edges },
        };

        for (kinds) |k| {
            const stmt = try self.prepare(k.sql);
            defer _ = c.sqlite3_finalize(stmt);
            if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const val = c.sqlite3_column_int64(stmt, 0);
                switch (k.field) {
                    .files => stats.files = val,
                    .functions => stats.functions = val,
                    .structures => stats.structures = val,
                    .tests => stats.tests = val,
                    .imports_edges => stats.imports_edges = val,
                    .calls_edges => stats.calls_edges = val,
                }
            }
        }

        return stats;
    }

    /// All nodes in the graph (for full graph dump).
    pub fn allNodes(self: *Store) ![]NodeRow {
        const sql =
            \\SELECT id, kind, lang, name, path, start_line, end_line
            \\FROM nodes ORDER BY kind, name;
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        return self.collectNodeRows(stmt);
    }

    /// All edges in the graph (for full graph dump).
    pub fn allEdges(self: *Store) ![]EdgeRow {
        const sql =
            \\SELECT src_id, dst_id, kind, confidence
            \\FROM edges ORDER BY kind;
        ;
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        return self.collectEdgeRows(stmt);
    }

    // ── Internal helpers ──────────────────────────────────────────

    fn readNodeRow(self: *Store, stmt: *c.sqlite3_stmt) !NodeRow {
        return .{
            .id = try self.columnTextAlloc(stmt, 0),
            .kind = try self.columnTextAlloc(stmt, 1),
            .lang = try self.columnTextAlloc(stmt, 2),
            .name = try self.columnTextAlloc(stmt, 3),
            .path = try self.columnTextAlloc(stmt, 4),
            .start_line = c.sqlite3_column_int(stmt, 5),
            .end_line = c.sqlite3_column_int(stmt, 6),
        };
    }

    fn collectNodeRows(self: *Store, stmt: *c.sqlite3_stmt) ![]NodeRow {
        var rows: std.ArrayListUnmanaged(NodeRow) = .{};
        defer rows.deinit(self.allocator);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try rows.append(self.allocator, try self.readNodeRow(stmt));
        }

        return rows.toOwnedSlice(self.allocator);
    }

    fn collectEdgeRows(self: *Store, stmt: *c.sqlite3_stmt) ![]EdgeRow {
        var rows: std.ArrayListUnmanaged(EdgeRow) = .{};
        defer rows.deinit(self.allocator);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try rows.append(self.allocator, .{
                .src_id = try self.columnTextAlloc(stmt, 0),
                .dst_id = try self.columnTextAlloc(stmt, 1),
                .kind = try self.columnTextAlloc(stmt, 2),
                .confidence = c.sqlite3_column_double(stmt, 3),
            });
        }

        return rows.toOwnedSlice(self.allocator);
    }

    fn columnTextAlloc(self: *Store, stmt: *c.sqlite3_stmt, col: c_int) ![]u8 {
        const ptr = c.sqlite3_column_text(stmt, col);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        if (ptr == null or len == 0) return try self.allocator.dupe(u8, "");
        return try self.allocator.dupe(u8, ptr[0..len]);
    }

    fn bindText(self: *Store, stmt: *c.sqlite3_stmt, col: c_int, text: []const u8) !void {
        _ = self;
        if (c.sqlite3_bind_text(stmt, col, text.ptr, @as(c_int, @intCast(text.len)), null) != c.SQLITE_OK)
            return StoreError.SqliteBindFailed;
    }

    fn openDatabase(self: *Store, db_path: []const u8) !void {
        var db: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        const rc = c.sqlite3_open_v2(db_path.ptr, &db, flags, null);
        if (rc != c.SQLITE_OK or db == null) {
            if (db) |bad_db| _ = c.sqlite3_close(bad_db);
            return StoreError.SqliteOpenFailed;
        }

        self.db = db;
    }

    fn configureDatabase(self: *Store) !void {
        try self.exec("PRAGMA foreign_keys = ON;");
        try self.exec("PRAGMA journal_mode = WAL;");
        try self.exec("PRAGMA synchronous = NORMAL;");
    }

    fn migrate(self: *Store) !void {
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS metadata (
            \\  key TEXT PRIMARY KEY,
            \\  value TEXT NOT NULL
            \\);
        );

        try self.exec(
            \\CREATE TABLE IF NOT EXISTS nodes (
            \\  id TEXT PRIMARY KEY,
            \\  kind TEXT NOT NULL,
            \\  lang TEXT,
            \\  name TEXT,
            \\  path TEXT,
            \\  start_line INTEGER DEFAULT 0,
            \\  end_line INTEGER DEFAULT 0
            \\);
        );

        try self.exec(
            \\CREATE TABLE IF NOT EXISTS edges (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  src_id TEXT NOT NULL,
            \\  dst_id TEXT NOT NULL,
            \\  kind TEXT NOT NULL,
            \\  confidence REAL DEFAULT 1.0,
            \\  FOREIGN KEY (src_id) REFERENCES nodes(id) ON DELETE CASCADE,
            \\  FOREIGN KEY (dst_id) REFERENCES nodes(id) ON DELETE CASCADE,
            \\  UNIQUE(src_id, dst_id, kind)
            \\);
        );

        try self.exec(
            \\INSERT INTO metadata(key, value)
            \\VALUES('schema_version', '1')
            \\ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        );
    }

    fn upsertProjectMetadata(self: *Store) !void {
        const db = self.db orelse return StoreError.SqliteOpenFailed;
        const sql =
            \\INSERT INTO metadata(key, value)
            \\VALUES(?1, ?2)
            \\ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        ;

        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt, 1, "project_root".ptr, @as(c_int, @intCast("project_root".len)), null) != c.SQLITE_OK) {
            return StoreError.SqliteBindFailed;
        }

        const root = self.project_root orelse return StoreError.SqliteBindFailed;
        if (c.sqlite3_bind_text(stmt, 2, root.ptr, @as(c_int, @intCast(root.len)), null) != c.SQLITE_OK) {
            return StoreError.SqliteBindFailed;
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return StoreError.SqliteStepFailed;

        const repo_node_id = try std.fmt.allocPrint(self.allocator, "repo:{s}", .{root});
        defer self.allocator.free(repo_node_id);

        const node_stmt = try self.prepare(
            \\INSERT INTO nodes(id, kind, lang, name, path, start_line, end_line)
            \\VALUES(?1, 'repository', 'unknown', ?2, ?3, 0, 0)
            \\ON CONFLICT(id) DO UPDATE SET
            \\  name = excluded.name,
            \\  path = excluded.path;
        );
        defer _ = c.sqlite3_finalize(node_stmt);

        const repo_name = std.fs.path.basename(root);

        if (c.sqlite3_bind_text(node_stmt, 1, repo_node_id.ptr, @as(c_int, @intCast(repo_node_id.len)), null) != c.SQLITE_OK) {
            return StoreError.SqliteBindFailed;
        }
        if (c.sqlite3_bind_text(node_stmt, 2, repo_name.ptr, @as(c_int, @intCast(repo_name.len)), null) != c.SQLITE_OK) {
            return StoreError.SqliteBindFailed;
        }
        if (c.sqlite3_bind_text(node_stmt, 3, root.ptr, @as(c_int, @intCast(root.len)), null) != c.SQLITE_OK) {
            return StoreError.SqliteBindFailed;
        }

        if (c.sqlite3_step(node_stmt) != c.SQLITE_DONE) return StoreError.SqliteStepFailed;
        _ = db;
    }

    fn exec(self: *Store, sql: []const u8) !void {
        const db = self.db orelse return StoreError.SqliteOpenFailed;
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(db, sql.ptr, null, null, &err_msg);
        defer if (err_msg != null) c.sqlite3_free(err_msg);

        if (rc != c.SQLITE_OK) return StoreError.SqliteExecFailed;
    }

    fn prepare(self: *Store, sql: []const u8) !*c.sqlite3_stmt {
        const db = self.db orelse return StoreError.SqliteOpenFailed;
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return StoreError.SqlitePrepareFailed;
        return stmt.?;
    }
};

/// Helper: open a Store backed by a temporary directory.
fn openTestStore(tmp: *std.testing.TmpDir) !Store {
    const allocator = std.testing.allocator;
    try tmp.dir.makeDir("repo");
    const repo_path = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_path);

    var store = Store.init(allocator);
    errdefer store.deinit();
    try store.open(repo_path);
    return store;
}

/// Helper: seed a small graph for query tests.
/// Creates: file:main.zig, file:lib.zig, function:main.zig:main, function:main.zig:helper,
///          function:lib.zig:libInit, structure:main.zig:Config, test_block:main.zig:test_it
/// Edges: file→symbol (defines), file→file (imports), function→function (calls)
fn seedTestGraph(store: *Store) !void {
    // File nodes
    try store.insertNode(.{ .id = "file:main.zig", .kind = .file, .lang = .zig, .name = "main.zig", .path = "main.zig" });
    try store.insertNode(.{ .id = "file:lib.zig", .kind = .file, .lang = .zig, .name = "lib.zig", .path = "lib.zig" });

    // Symbol nodes
    try store.insertNode(.{ .id = "function:main.zig:main", .kind = .function, .lang = .zig, .name = "main", .path = "main.zig", .start_line = 1, .end_line = 10 });
    try store.insertNode(.{ .id = "function:main.zig:helper", .kind = .function, .lang = .zig, .name = "helper", .path = "main.zig", .start_line = 12, .end_line = 20 });
    try store.insertNode(.{ .id = "function:lib.zig:libInit", .kind = .function, .lang = .zig, .name = "libInit", .path = "lib.zig", .start_line = 1, .end_line = 5 });
    try store.insertNode(.{ .id = "structure:main.zig:Config", .kind = .structure, .lang = .zig, .name = "Config", .path = "main.zig", .start_line = 22, .end_line = 30 });
    try store.insertNode(.{ .id = "test_block:main.zig:test_it", .kind = .test_block, .lang = .zig, .name = "test_it", .path = "main.zig", .start_line = 32, .end_line = 35 });

    // Defines edges (file → symbol)
    try store.insertEdge(.{ .src_id = "file:main.zig", .dst_id = "function:main.zig:main", .kind = .defines });
    try store.insertEdge(.{ .src_id = "file:main.zig", .dst_id = "function:main.zig:helper", .kind = .defines });
    try store.insertEdge(.{ .src_id = "file:main.zig", .dst_id = "structure:main.zig:Config", .kind = .defines });
    try store.insertEdge(.{ .src_id = "file:main.zig", .dst_id = "test_block:main.zig:test_it", .kind = .defines });
    try store.insertEdge(.{ .src_id = "file:lib.zig", .dst_id = "function:lib.zig:libInit", .kind = .defines });

    // Imports edge (main.zig imports lib.zig)
    try store.insertEdge(.{ .src_id = "file:main.zig", .dst_id = "file:lib.zig", .kind = .imports });

    // Calls edges (main calls helper, main calls libInit)
    try store.insertEdge(.{ .src_id = "function:main.zig:main", .dst_id = "function:main.zig:helper", .kind = .calls });
    try store.insertEdge(.{ .src_id = "function:main.zig:main", .dst_id = "function:lib.zig:libInit", .kind = .calls });
}

test "store creates a database and seeds repository metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");

    const repo_path = try tmp.dir.realpathAlloc(std.testing.allocator, "repo");
    defer std.testing.allocator.free(repo_path);

    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    try store.open(repo_path);

    try std.testing.expect(store.getDatabasePath() != null);
    try std.testing.expect((try store.countNodes()) >= 1);
}

test "insertNode and getNode round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try openTestStore(&tmp);
    defer store.deinit();

    try store.insertNode(.{ .id = "function:foo.zig:bar", .kind = .function, .lang = .zig, .name = "bar", .path = "foo.zig", .start_line = 5, .end_line = 15 });

    try std.testing.expect(try store.nodeExists("function:foo.zig:bar"));
    try std.testing.expect(!try store.nodeExists("nonexistent"));

    var node = (try store.getNode("function:foo.zig:bar")).?;
    defer node.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("bar", node.name);
    try std.testing.expectEqualStrings("function", node.kind);
    try std.testing.expectEqualStrings("zig", node.lang);
    try std.testing.expectEqualStrings("foo.zig", node.path);
    try std.testing.expectEqual(@as(i32, 5), node.start_line);
    try std.testing.expectEqual(@as(i32, 15), node.end_line);

    // getNode for missing ID returns null
    try std.testing.expect((try store.getNode("nope")) == null);
}

test "insertEdge and edgesFrom / edgesTo" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try openTestStore(&tmp);
    defer store.deinit();

    try store.insertNode(.{ .id = "a", .kind = .function, .lang = .zig, .name = "a", .path = "a.zig" });
    try store.insertNode(.{ .id = "b", .kind = .function, .lang = .zig, .name = "b", .path = "b.zig" });

    try store.insertEdge(.{ .src_id = "a", .dst_id = "b", .kind = .calls, .confidence = 0.9 });

    const outgoing = try store.edgesFrom("a");
    defer store.freeEdgeRows(outgoing);
    try std.testing.expectEqual(@as(usize, 1), outgoing.len);
    try std.testing.expectEqualStrings("a", outgoing[0].src_id);
    try std.testing.expectEqualStrings("b", outgoing[0].dst_id);
    try std.testing.expectEqualStrings("calls", outgoing[0].kind);

    const incoming = try store.edgesTo("b");
    defer store.freeEdgeRows(incoming);
    try std.testing.expectEqual(@as(usize, 1), incoming.len);

    // No edges from b
    const empty = try store.edgesFrom("b");
    defer store.freeEdgeRows(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "transactions commit persists data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try openTestStore(&tmp);
    defer store.deinit();

    try store.beginTransaction();
    try store.insertNode(.{ .id = "tx_node", .kind = .function, .lang = .zig, .name = "txn", .path = "t.zig" });
    try store.commitTransaction();

    try std.testing.expect(try store.nodeExists("tx_node"));
}

test "findSymbol returns matching nodes, excludes file/repo kinds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try openTestStore(&tmp);
    defer store.deinit();
    try seedTestGraph(&store);

    // Search for "main" — should find the function, not the file
    const rows = try store.findSymbol("main");
    defer store.freeNodeRows(rows);
    try std.testing.expect(rows.len >= 1);
    for (rows) |row| {
        try std.testing.expect(!std.mem.eql(u8, row.kind, "file"));
        try std.testing.expect(!std.mem.eql(u8, row.kind, "repository"));
    }

    // Search for "helper"
    const rows2 = try store.findSymbol("helper");
    defer store.freeNodeRows(rows2);
    try std.testing.expectEqual(@as(usize, 1), rows2.len);
    try std.testing.expectEqualStrings("helper", rows2[0].name);

    // Search for non-existent symbol
    const rows3 = try store.findSymbol("zzz_no_match");
    defer store.freeNodeRows(rows3);
    try std.testing.expectEqual(@as(usize, 0), rows3.len);
}

test "symbolsInFile returns symbols defined in a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try openTestStore(&tmp);
    defer store.deinit();
    try seedTestGraph(&store);

    const rows = try store.symbolsInFile("main.zig");
    defer store.freeNodeRows(rows);
    // main.zig defines: main, helper, Config, test_it = 4 symbols
    try std.testing.expectEqual(@as(usize, 4), rows.len);

    const rows2 = try store.symbolsInFile("lib.zig");
    defer store.freeNodeRows(rows2);
    try std.testing.expectEqual(@as(usize, 1), rows2.len);
    try std.testing.expectEqualStrings("libInit", rows2[0].name);
}

test "importsOf and importedBy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try openTestStore(&tmp);
    defer store.deinit();
    try seedTestGraph(&store);

    // main.zig imports lib.zig
    const imports = try store.importsOf("main.zig");
    defer store.freeNodeRows(imports);
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("lib.zig", imports[0].name);

    // lib.zig is imported by main.zig
    const imported_by = try store.importedBy("lib.zig");
    defer store.freeNodeRows(imported_by);
    try std.testing.expectEqual(@as(usize, 1), imported_by.len);
    try std.testing.expectEqualStrings("main.zig", imported_by[0].name);

    // lib.zig imports nothing
    const no_imports = try store.importsOf("lib.zig");
    defer store.freeNodeRows(no_imports);
    try std.testing.expectEqual(@as(usize, 0), no_imports.len);
}

test "callers and callees" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try openTestStore(&tmp);
    defer store.deinit();
    try seedTestGraph(&store);

    // callers of "helper" — main calls helper
    const helper_callers = try store.callers("helper");
    defer store.freeNodeRows(helper_callers);
    try std.testing.expectEqual(@as(usize, 1), helper_callers.len);
    try std.testing.expectEqualStrings("main", helper_callers[0].name);

    // callees of "main" — main calls helper and libInit
    const main_callees = try store.callees("main");
    defer store.freeNodeRows(main_callees);
    try std.testing.expectEqual(@as(usize, 2), main_callees.len);

    // callers of a function nobody calls
    const no_callers = try store.callers("Config");
    defer store.freeNodeRows(no_callers);
    try std.testing.expectEqual(@as(usize, 0), no_callers.len);
}

test "findFunctionIdsByName" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try openTestStore(&tmp);
    defer store.deinit();
    try seedTestGraph(&store);

    const ids = try store.findFunctionIdsByName("main");
    defer store.freeFunctionIds(ids);
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    try std.testing.expectEqualStrings("function:main.zig:main", ids[0]);

    const none = try store.findFunctionIdsByName("nonexistent");
    defer store.freeFunctionIds(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "graphStats counts node and edge kinds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try openTestStore(&tmp);
    defer store.deinit();
    try seedTestGraph(&store);

    const stats = try store.graphStats();
    // 7 symbol nodes + 1 repo node from open() = 8
    try std.testing.expectEqual(@as(i64, 8), stats.total_nodes);
    try std.testing.expectEqual(@as(i64, 2), stats.files);
    try std.testing.expectEqual(@as(i64, 3), stats.functions);  // main, helper, libInit
    try std.testing.expectEqual(@as(i64, 1), stats.structures);  // Config
    try std.testing.expectEqual(@as(i64, 1), stats.tests);  // test_it
    try std.testing.expectEqual(@as(i64, 1), stats.imports_edges);
    try std.testing.expectEqual(@as(i64, 2), stats.calls_edges);
}

test "allNodes and allEdges return full graph" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try openTestStore(&tmp);
    defer store.deinit();
    try seedTestGraph(&store);

    const nodes = try store.allNodes();
    defer store.freeNodeRows(nodes);
    try std.testing.expectEqual(@as(usize, 8), nodes.len);

    const edges = try store.allEdges();
    defer store.freeEdgeRows(edges);
    // 5 defines + 1 imports + 2 calls = 8
    try std.testing.expectEqual(@as(usize, 8), edges.len);
}

test "countNodes and countEdges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try openTestStore(&tmp);
    defer store.deinit();

    // After open(), there's 1 repo node and 0 extra edges
    const initial_nodes = try store.countNodes();
    try std.testing.expect(initial_nodes >= 1);

    try store.insertNode(.{ .id = "n1", .kind = .function, .lang = .zig, .name = "n1", .path = "x.zig" });
    try store.insertNode(.{ .id = "n2", .kind = .function, .lang = .zig, .name = "n2", .path = "x.zig" });
    try std.testing.expectEqual(initial_nodes + 2, try store.countNodes());

    try store.insertEdge(.{ .src_id = "n1", .dst_id = "n2", .kind = .calls });
    try std.testing.expectEqual(@as(i64, 1), try store.countEdges());
}

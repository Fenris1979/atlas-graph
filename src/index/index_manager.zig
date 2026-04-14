const std = @import("std");
const schema = @import("../graph/schema.zig");
const Store = @import("../storage/store.zig").Store;
const zig_indexer = @import("zig_indexer.zig");

pub const IndexSummary = struct {
    files_seen: usize = 0,
    zig_files: usize = 0,
    c_family_files: usize = 0,
    other_files: usize = 0,
    nodes_written: usize = 0,
    edges_written: usize = 0,
    symbols_extracted: usize = 0,
    imports_extracted: usize = 0,
    calls_extracted: usize = 0,
};

/// In-memory index of node IDs built during pass 1, used in pass 2
/// to avoid hitting SQLite for every nodeExists / findFunctionIdsByName call.
const NodeIndex = struct {
    /// Set of all node IDs for fast existence checks
    node_ids: std.StringHashMapUnmanaged(void),
    /// function name → list of full function node IDs
    fn_by_name: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
    /// Owned sym_id allocations (tracked as []u8 for correct freeing)
    owned_ids: std.ArrayListUnmanaged([]u8),

    fn init() NodeIndex {
        return .{
            .node_ids = .{},
            .fn_by_name = .{},
            .owned_ids = .{},
        };
    }

    fn deinit(self: *NodeIndex, allocator: std.mem.Allocator) void {
        for (self.owned_ids.items) |id| allocator.free(id);
        self.owned_ids.deinit(allocator);
        self.node_ids.deinit(allocator);
        var it = self.fn_by_name.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.fn_by_name.deinit(allocator);
    }

    /// Add a node ID we don't own (e.g. file_id owned by file_infos)
    fn addNode(self: *NodeIndex, allocator: std.mem.Allocator, id: []const u8) !void {
        try self.node_ids.put(allocator, id, {});
    }

    /// Add a node ID we own (sym_id allocated for this index)
    fn addOwnedNode(self: *NodeIndex, allocator: std.mem.Allocator, id: []u8) !void {
        try self.node_ids.put(allocator, id, {});
        try self.owned_ids.append(allocator, id);
    }

    fn addFunction(self: *NodeIndex, allocator: std.mem.Allocator, id: []const u8, name: []const u8) !void {
        const gop = try self.fn_by_name.getOrPut(allocator, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(allocator, id);
    }

    fn contains(self: *const NodeIndex, id: []const u8) bool {
        return self.node_ids.contains(id);
    }

    fn functionIdsByName(self: *const NodeIndex, name: []const u8) []const []const u8 {
        if (self.fn_by_name.getPtr(name)) |list| {
            return list.items;
        }
        return &.{};
    }
};

pub const IndexManager = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IndexManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *IndexManager) void {
        _ = self;
    }

    pub fn indexRepository(self: *IndexManager, repo_path: []const u8, store: *Store) !IndexSummary {
        var summary = IndexSummary{};

        const repo_node_id = try std.fmt.allocPrint(self.allocator, "repo:{s}", .{repo_path});
        defer self.allocator.free(repo_node_id);

        var dir = try std.fs.cwd().openDir(repo_path, .{ .iterate = true });
        defer dir.close();

        // Collect file paths first (walker entries are transient)
        var file_paths = std.ArrayListUnmanaged([]u8){};
        defer {
            for (file_paths.items) |p| self.allocator.free(p);
            file_paths.deinit(self.allocator);
        }

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            // Skip hidden directories (e.g. .atlas-graph, .git)
            if (std.mem.indexOf(u8, entry.path, "/.") != null or
                (entry.path.len > 0 and entry.path[0] == '.')) continue;

            const owned = try self.allocator.dupe(u8, entry.path);
            try file_paths.append(self.allocator, owned);
        }

        // Classify files and collect zig paths for parallel parsing
        var zig_paths = std.ArrayListUnmanaged([]const u8){};
        defer zig_paths.deinit(self.allocator);

        for (file_paths.items) |rel_path| {
            const lang = schema.languageFromPath(rel_path);
            summary.files_seen += 1;
            switch (lang) {
                .zig => {
                    summary.zig_files += 1;
                    try zig_paths.append(self.allocator, rel_path);
                },
                .c, .cpp, .objc => summary.c_family_files += 1,
                .unknown => summary.other_files += 1,
            }
        }

        // Parallel phase: read + parse all zig files on thread pool

        const ParseResult = struct {
            analysis: ?zig_indexer.FileAnalysis = null,
            source: ?[:0]u8 = null,
            failed: bool = false,
        };

        const parse_results = try self.allocator.alloc(ParseResult, zig_paths.items.len);
        defer self.allocator.free(parse_results);
        @memset(parse_results, .{});

        // Use a real path for opening files in worker threads
        const repo_dir_path = try std.fs.cwd().realpathAlloc(self.allocator, repo_path);
        defer self.allocator.free(repo_dir_path);

        // Wrap allocator for thread safety during parallel parse
        var ts_allocator = std.heap.ThreadSafeAllocator{
            .child_allocator = self.allocator,
        };
        const ts_alloc = ts_allocator.allocator();

        const ParseContext = struct {
            alloc: std.mem.Allocator,
            zig_paths: []const []const u8,
            parse_results: []ParseResult,
            repo_dir_path: []const u8,

            fn worker(ctx: @This(), start: usize, end: usize) void {
                for (start..end) |i| {
                    ctx.parse_results[i] = parseOneFile(ctx.alloc, ctx.repo_dir_path, ctx.zig_paths[i]);
                }
            }

            fn parseOneFile(alloc: std.mem.Allocator, base_path: []const u8, rel_path: []const u8) ParseResult {
                const full_path = std.fs.path.join(alloc, &.{ base_path, rel_path }) catch return .{ .failed = true };
                defer alloc.free(full_path);

                const file = std.fs.cwd().openFile(full_path, .{}) catch return .{ .failed = true };
                defer file.close();

                const source = file.readToEndAllocOptions(alloc, 10 * 1024 * 1024, null, .@"1", 0) catch return .{ .failed = true };
                const analysis = zig_indexer.analyzeSource(alloc, source) catch {
                    alloc.free(source);
                    return .{ .failed = true };
                };

                return .{ .analysis = analysis, .source = source };
            }
        };

        const ctx = ParseContext{
            .alloc = ts_alloc,
            .zig_paths = zig_paths.items,
            .parse_results = parse_results,
            .repo_dir_path = repo_dir_path,
        };

        // Spawn worker threads
        const num_threads = @min(zig_paths.items.len, 8);
        if (num_threads > 1) {
            const chunk_size = zig_paths.items.len / num_threads;
            var threads: [8]?std.Thread = .{null} ** 8;

            for (0..num_threads) |t| {
                const start = t * chunk_size;
                const end = if (t == num_threads - 1) zig_paths.items.len else (t + 1) * chunk_size;
                threads[t] = std.Thread.spawn(.{}, ParseContext.worker, .{ ctx, start, end }) catch null;
            }
            for (&threads) |*t| {
                if (t.*) |thread| {
                    thread.join();
                    t.* = null;
                }
            }
        } else {
            ctx.worker(0, zig_paths.items.len);
        }

        // Sequential phase: insert all nodes into SQLite + build index
        try store.beginTransaction();
        errdefer store.commitTransaction() catch {};

        const FileInfo = struct {
            rel_path: []const u8,
            file_id: []u8,
            analysis: ?zig_indexer.FileAnalysis,
            source: ?[:0]u8,
        };
        var file_infos = std.ArrayListUnmanaged(FileInfo){};
        defer {
            for (file_infos.items) |*info| {
                self.allocator.free(info.file_id);
                if (info.analysis) |*a| a.deinit(self.allocator);
                if (info.source) |s| self.allocator.free(s);
            }
            file_infos.deinit(self.allocator);
        }

        var node_index = NodeIndex.init();
        defer node_index.deinit(self.allocator);

        // Insert all file nodes (zig + non-zig source files)
        for (file_paths.items) |rel_path| {
            const lang = schema.languageFromPath(rel_path);
            if (lang == .unknown) continue;

            const file_id = try std.fmt.allocPrint(self.allocator, "file:{s}", .{rel_path});

            try store.insertNode(.{
                .id = file_id,
                .kind = .file,
                .lang = lang,
                .name = std.fs.path.basename(rel_path),
                .path = rel_path,
            });
            summary.nodes_written += 1;
            try node_index.addNode(self.allocator, file_id);

            try store.insertEdge(.{
                .src_id = repo_node_id,
                .dst_id = file_id,
                .kind = .contains,
            });
            summary.edges_written += 1;

            try file_infos.append(self.allocator, .{
                .rel_path = rel_path,
                .file_id = file_id,
                .analysis = null,
                .source = null,
            });
        }

        // Insert symbol nodes from parallel parse results
        var zig_idx: usize = 0;
        for (file_infos.items) |*info| {
            const lang = schema.languageFromPath(info.rel_path);
            if (lang != .zig) continue;

            const pr = &parse_results[zig_idx];
            zig_idx += 1;

            if (pr.failed or pr.analysis == null) continue;

            // Transfer ownership from parse_results to file_infos
            info.analysis = pr.analysis;
            info.source = pr.source;
            pr.analysis = null;
            pr.source = null;

            for (info.analysis.?.symbols) |sym| {
                const sym_id = try std.fmt.allocPrint(self.allocator, "{s}:{s}:{s}", .{
                    @tagName(sym.kind), info.rel_path, sym.name,
                });

                try store.insertNode(.{
                    .id = sym_id,
                    .kind = sym.kind,
                    .lang = .zig,
                    .name = sym.name,
                    .path = info.rel_path,
                    .start_line = sym.start_line,
                    .end_line = sym.end_line,
                });
                summary.nodes_written += 1;
                summary.symbols_extracted += 1;

                try node_index.addOwnedNode(self.allocator, sym_id);
                if (sym.kind == .function or sym.kind == .test_block) {
                    try node_index.addFunction(self.allocator, sym_id, sym.name);
                }

                try store.insertEdge(.{
                    .src_id = info.file_id,
                    .dst_id = sym_id,
                    .kind = .defines,
                });
                summary.edges_written += 1;
            }
        }

        // Clean up any failed parse results
        for (parse_results) |*pr| {
            if (pr.analysis) |*a| a.deinit(self.allocator);
            if (pr.source) |s| self.allocator.free(s);
        }

        // Pass 2: Insert all edges (imports + calls) — all nodes now exist
        for (file_infos.items) |info| {
            if (info.analysis) |analysis| {
                try self.insertEdges(info.rel_path, info.file_id, analysis, store, &summary, &node_index);
            }
        }

        try store.commitTransaction();
        return summary;
    }

    /// Pass 2: Insert import and call edges. All nodes already exist in the store.
    fn insertEdges(
        _: *IndexManager,
        rel_path: []const u8,
        file_id: []const u8,
        analysis: zig_indexer.FileAnalysis,
        store: *Store,
        summary: *IndexSummary,
        node_index: *const NodeIndex,
    ) !void {
        var id_buf: [1024]u8 = undefined;
        var id_buf2: [1024]u8 = undefined;
        var path_buf: [1024]u8 = undefined;

        // Insert "imports" edges for local file imports
        for (analysis.imports) |imp| {
            if (std.mem.endsWith(u8, imp.path, ".zig")) {
                const resolved = resolveRelativePathBuf(&path_buf, rel_path, imp.path) orelse continue;
                const target_file_id = std.fmt.bufPrint(&id_buf, "file:{s}", .{resolved}) catch continue;

                if (node_index.contains(target_file_id)) {
                    try store.insertEdge(.{
                        .src_id = file_id,
                        .dst_id = target_file_id,
                        .kind = .imports,
                    });
                    summary.edges_written += 1;
                }
            }
            summary.imports_extracted += 1;
        }

        // Insert "calls" edges between functions
        for (analysis.calls) |call| {
            // caller_id uses id_buf2 so resolveCalleeId can use id_buf
            const caller_id = std.fmt.bufPrint(&id_buf2, "function:{s}:{s}", .{
                rel_path, call.caller_name,
            }) catch continue;

            const resolved_id = resolveCalleeId(
                &id_buf,
                &path_buf,
                rel_path,
                call,
                analysis.imports,
                analysis.fields,
                node_index,
            );

            if (resolved_id) |callee_id| {
                try store.insertEdge(.{
                    .src_id = caller_id,
                    .dst_id = callee_id,
                    .kind = .calls,
                });
                summary.edges_written += 1;
            }
            summary.calls_extracted += 1;
        }
    }

    /// Resolve a call to a concrete function node ID using multiple strategies.
    /// Uses stack buffers instead of allocating.
    fn resolveCalleeId(
        id_buf: *[1024]u8,
        path_buf: *[1024]u8,
        rel_path: []const u8,
        call: zig_indexer.ExtractedCall,
        file_imports: []const zig_indexer.ExtractedImport,
        file_fields: []const zig_indexer.ExtractedField,
        node_index: *const NodeIndex,
    ) ?[]const u8 {
        // Strategy 1: Same-file match
        const local_id = std.fmt.bufPrint(id_buf, "function:{s}:{s}", .{
            rel_path, call.callee_name,
        }) catch return null;
        if (node_index.node_ids.getKey(local_id)) |key| return key;

        // Strategies 2 & 3 require a qualifier
        if (call.qualifier) |qualifier| {
            // Strategy 2: qualifier is a direct import alias
            if (resolveViaImport(id_buf, path_buf, rel_path, qualifier, call.callee_name, file_imports, node_index)) |id| {
                return id;
            }

            // Strategy 3: qualifier is a struct field → look up its type → resolve via import
            for (file_fields) |field| {
                if (std.mem.eql(u8, field.name, qualifier)) {
                    if (field.type_name) |type_name| {
                        if (resolveViaImport(id_buf, path_buf, rel_path, type_name, call.callee_name, file_imports, node_index)) |id| {
                            return id;
                        }
                    }
                    break;
                }
            }
        }

        // Strategy 4: Unambiguous global name match
        const callee_ids = node_index.functionIdsByName(call.callee_name);
        if (callee_ids.len == 1) {
            return callee_ids[0];
        }

        return null;
    }

    fn resolveViaImport(
        id_buf: *[1024]u8,
        path_buf: *[1024]u8,
        rel_path: []const u8,
        type_name: []const u8,
        callee_name: []const u8,
        file_imports: []const zig_indexer.ExtractedImport,
        node_index: *const NodeIndex,
    ) ?[]const u8 {
        for (file_imports) |imp| {
            if (!std.mem.eql(u8, imp.alias, type_name)) continue;
            if (!std.mem.endsWith(u8, imp.path, ".zig")) continue;

            const resolved_path = resolveRelativePathBuf(path_buf, rel_path, imp.path) orelse continue;
            const target_id = std.fmt.bufPrint(id_buf, "function:{s}:{s}", .{
                resolved_path, callee_name,
            }) catch continue;

            if (node_index.node_ids.getKey(target_id)) |key| return key;
        }
        return null;
    }
};

/// Stack-buffer version of resolveRelativePath — no allocation.
/// Returns a slice into buf, or null if the result doesn't fit.
fn resolveRelativePathBuf(buf: *[1024]u8, rel_path: []const u8, import_path: []const u8) ?[]const u8 {
    // Join: file_dir / import_path
    const file_dir = std.fs.path.dirname(rel_path) orelse "";
    var join_len: usize = 0;
    var join_buf: [1024]u8 = undefined;

    if (file_dir.len > 0) {
        if (file_dir.len + 1 + import_path.len > join_buf.len) return null;
        @memcpy(join_buf[0..file_dir.len], file_dir);
        join_buf[file_dir.len] = '/';
        @memcpy(join_buf[file_dir.len + 1 ..][0..import_path.len], import_path);
        join_len = file_dir.len + 1 + import_path.len;
    } else {
        if (import_path.len > join_buf.len) return null;
        @memcpy(join_buf[0..import_path.len], import_path);
        join_len = import_path.len;
    }

    const joined = join_buf[0..join_len];

    // If no ".." just return
    if (std.mem.indexOf(u8, joined, "..") == null) {
        @memcpy(buf[0..join_len], joined);
        return buf[0..join_len];
    }

    // Normalize: collapse ".." components in-place using parts array on stack
    var parts: [64][]const u8 = undefined;
    var part_count: usize = 0;

    var iter = std.mem.splitScalar(u8, joined, '/');
    while (iter.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            if (part_count > 0) part_count -= 1;
        } else if (std.mem.eql(u8, part, ".")) {
            continue;
        } else {
            if (part_count >= parts.len) return null;
            parts[part_count] = part;
            part_count += 1;
        }
    }

    // Rejoin into buf
    var pos: usize = 0;
    for (parts[0..part_count], 0..) |part, idx| {
        if (pos + part.len + 1 > buf.len) return null;
        @memcpy(buf[pos..][0..part.len], part);
        pos += part.len;
        if (idx < part_count - 1) {
            buf[pos] = '/';
            pos += 1;
        }
    }

    return buf[0..pos];
}

/// Resolve an import path relative to the importing file's directory,
/// normalizing away ".." components. E.g.:
///   rel_path="src/app/app.zig", import_path="../ui/ui.zig" → "src/ui/ui.zig"
fn resolveRelativePath(allocator: std.mem.Allocator, rel_path: []const u8, import_path: []const u8) ![]u8 {
    const file_dir = std.fs.path.dirname(rel_path) orelse "";
    const joined = if (file_dir.len > 0)
        try std.fs.path.join(allocator, &.{ file_dir, import_path })
    else
        try allocator.dupe(u8, import_path);

    // Normalize: collapse "foo/../bar" → "bar"
    if (std.mem.indexOf(u8, joined, "..") == null) return joined;
    defer allocator.free(joined);

    var parts: std.ArrayListUnmanaged([]const u8) = .{};
    defer parts.deinit(allocator);

    var iter = std.mem.splitScalar(u8, joined, '/');
    while (iter.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) {
                _ = parts.pop();
            }
        } else if (std.mem.eql(u8, part, ".")) {
            continue;
        } else {
            try parts.append(allocator, part);
        }
    }

    // Rejoin
    var total_len: usize = 0;
    for (parts.items, 0..) |part, idx| {
        total_len += part.len;
        if (idx < parts.items.len - 1) total_len += 1;
    }

    const result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (parts.items, 0..) |part, idx| {
        @memcpy(result[pos .. pos + part.len], part);
        pos += part.len;
        if (idx < parts.items.len - 1) {
            result[pos] = '/';
            pos += 1;
        }
    }

    return result;
}

test "index manager writes file and symbol nodes to store" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    var repo_dir = try tmp.dir.openDir("repo", .{});
    defer repo_dir.close();

    // Zig file with a function, a struct, and an import
    try repo_dir.writeFile(.{
        .sub_path = "main.zig",
        .data =
        \\const std = @import("std");
        \\
        \\pub const Config = struct {
        \\    x: u32,
        \\};
        \\
        \\pub fn main() void {}
        ,
    });
    try repo_dir.writeFile(.{ .sub_path = "helper.c", .data = "void helper() {}" });
    try repo_dir.writeFile(.{ .sub_path = "readme.txt", .data = "hello" });

    const repo_path = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_path);

    var store = Store.init(allocator);
    defer store.deinit();
    try store.open(repo_path);

    var mgr = IndexManager.init(allocator);
    defer mgr.deinit();

    const summary = try mgr.indexRepository(repo_path, &store);

    try std.testing.expectEqual(@as(usize, 3), summary.files_seen);
    try std.testing.expectEqual(@as(usize, 1), summary.zig_files);
    try std.testing.expectEqual(@as(usize, 1), summary.c_family_files);
    try std.testing.expectEqual(@as(usize, 1), summary.other_files);
    // 2 source file nodes + 2 symbols (Config struct + main fn)
    try std.testing.expectEqual(@as(usize, 4), summary.nodes_written);
    try std.testing.expectEqual(@as(usize, 2), summary.symbols_extracted);
    try std.testing.expectEqual(@as(usize, 1), summary.imports_extracted);

    // 1 repo + 2 files + 2 symbols = 5 nodes
    try std.testing.expectEqual(@as(i64, 5), try store.countNodes());
    // 2 contains (repo->file) + 2 defines (file->symbol) = 4 edges
    try std.testing.expectEqual(@as(i64, 4), try store.countEdges());
}

test "indexRepository resolves import edges between zig files" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    var repo_dir = try tmp.dir.openDir("repo", .{});
    defer repo_dir.close();

    // lib.zig defines a function
    try repo_dir.writeFile(.{
        .sub_path = "lib.zig",
        .data =
        \\pub fn libHelper() void {}
        ,
    });

    // main.zig imports lib.zig
    try repo_dir.writeFile(.{
        .sub_path = "main.zig",
        .data =
        \\const lib = @import("lib.zig");
        \\
        \\pub fn start() void {
        \\    lib.libHelper();
        \\}
        ,
    });

    const repo_path = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_path);

    var store = Store.init(allocator);
    defer store.deinit();
    try store.open(repo_path);

    var mgr = IndexManager.init(allocator);
    defer mgr.deinit();

    const summary = try mgr.indexRepository(repo_path, &store);

    // Both zig files seen
    try std.testing.expectEqual(@as(usize, 2), summary.zig_files);
    // Import edge: main.zig → lib.zig
    try std.testing.expect(summary.imports_extracted >= 1);
    // Call edge: start → libHelper (cross-file via import)
    try std.testing.expect(summary.calls_extracted >= 1);

    // Verify import edge in store
    const imports = try store.importsOf("main.zig");
    defer store.freeNodeRows(imports);
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualStrings("lib.zig", imports[0].name);
}

test "indexRepository resolves same-file call edges" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    var repo_dir = try tmp.dir.openDir("repo", .{});
    defer repo_dir.close();

    // Single file with two functions where one calls the other
    try repo_dir.writeFile(.{
        .sub_path = "app.zig",
        .data =
        \\fn helper() void {}
        \\
        \\pub fn run() void {
        \\    helper();
        \\}
        ,
    });

    const repo_path = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_path);

    var store = Store.init(allocator);
    defer store.deinit();
    try store.open(repo_path);

    var mgr = IndexManager.init(allocator);
    defer mgr.deinit();

    const summary = try mgr.indexRepository(repo_path, &store);

    try std.testing.expectEqual(@as(usize, 2), summary.symbols_extracted); // helper + run
    try std.testing.expect(summary.calls_extracted >= 1);

    // Verify call edge: run → helper
    const callees = try store.callees("run");
    defer store.freeNodeRows(callees);
    try std.testing.expectEqual(@as(usize, 1), callees.len);
    try std.testing.expectEqualStrings("helper", callees[0].name);
}

test "indexRepository handles nested directories and skips hidden dirs" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    var repo_dir = try tmp.dir.openDir("repo", .{});
    defer repo_dir.close();

    try repo_dir.makePath("src");
    try repo_dir.makePath(".hidden");

    try repo_dir.writeFile(.{
        .sub_path = "src/util.zig",
        .data = "pub fn doWork() void {}",
    });
    // Hidden directory file should be skipped
    try repo_dir.writeFile(.{
        .sub_path = ".hidden/secret.zig",
        .data = "pub fn secret() void {}",
    });

    const repo_path = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(repo_path);

    var store = Store.init(allocator);
    defer store.deinit();
    try store.open(repo_path);

    var mgr = IndexManager.init(allocator);
    defer mgr.deinit();

    const summary = try mgr.indexRepository(repo_path, &store);

    // Only src/util.zig should be indexed, not .hidden/secret.zig
    try std.testing.expectEqual(@as(usize, 1), summary.zig_files);
    try std.testing.expectEqual(@as(usize, 1), summary.symbols_extracted);
}

test "resolveRelativePathBuf normalizes parent references" {
    var buf: [1024]u8 = undefined;

    // Simple join without ..
    const r1 = resolveRelativePathBuf(&buf, "src/app/app.zig", "helper.zig").?;
    try std.testing.expectEqualStrings("src/app/helper.zig", r1);

    // With .. normalization
    var buf2: [1024]u8 = undefined;
    const r2 = resolveRelativePathBuf(&buf2, "src/app/app.zig", "../ui/ui.zig").?;
    try std.testing.expectEqualStrings("src/ui/ui.zig", r2);

    // File at root level
    var buf3: [1024]u8 = undefined;
    const r3 = resolveRelativePathBuf(&buf3, "main.zig", "lib.zig").?;
    try std.testing.expectEqualStrings("lib.zig", r3);
}

test "resolveRelativePath allocating version" {
    const allocator = std.testing.allocator;

    const r1 = try resolveRelativePath(allocator, "src/app/app.zig", "../ui/ui.zig");
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("src/ui/ui.zig", r1);

    const r2 = try resolveRelativePath(allocator, "main.zig", "lib.zig");
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("lib.zig", r2);
}

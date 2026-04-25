const std = @import("std");
const schema = @import("../graph/schema.zig");
const analysis_types = @import("analysis.zig");
const Ast = std.zig.Ast;

pub const ExtractedSymbol = analysis_types.ExtractedSymbol;
pub const ExtractedImport = analysis_types.ExtractedImport;
pub const ExtractedCall = analysis_types.ExtractedCall;
pub const ExtractedField = analysis_types.ExtractedField;
pub const FileAnalysis = analysis_types.FileAnalysis;

pub fn analyzeSource(allocator: std.mem.Allocator, source: [:0]const u8) !FileAnalysis {
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var symbols: std.ArrayList(ExtractedSymbol) = .{};
    defer symbols.deinit(allocator);

    var imports: std.ArrayList(ExtractedImport) = .{};
    defer imports.deinit(allocator);

    var calls: std.ArrayList(ExtractedCall) = .{};
    defer calls.deinit(allocator);

    var fields: std.ArrayList(ExtractedField) = .{};
    defer fields.deinit(allocator);

    try processDecls(tree, tree.rootDecls(), &symbols, &imports, &fields, allocator);

    // Extract calls using flat iteration — needs symbols to map calls to enclosing functions
    const owned_symbols = try symbols.toOwnedSlice(allocator);
    try extractAllCalls(tree, owned_symbols, &calls, allocator);

    return .{
        .symbols = owned_symbols,
        .imports = try imports.toOwnedSlice(allocator),
        .calls = try calls.toOwnedSlice(allocator),
        .fields = try fields.toOwnedSlice(allocator),
    };
}

/// Process a list of declaration nodes, extracting symbols and imports.
/// Recurses into container bodies (struct/enum/union) to find nested declarations.
fn processDecls(
    tree: Ast,
    decls: []const Ast.Node.Index,
    symbols: *std.ArrayList(ExtractedSymbol),
    imports: *std.ArrayList(ExtractedImport),
    fields: *std.ArrayList(ExtractedField),
    allocator: std.mem.Allocator,
) !void {
    for (decls) |decl_idx| {
        const tag = tree.nodeTag(decl_idx);

        switch (tag) {
            .fn_decl, .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => {
                var buf: [1]Ast.Node.Index = undefined;
                if (tree.fullFnProto(&buf, decl_idx)) |fn_proto| {
                    const name = if (fn_proto.name_token) |nt|
                        tree.tokenSlice(nt)
                    else
                        "(anonymous)";

                    const start_loc = tree.tokenLocation(0, fn_proto.ast.fn_token);
                    const end_line = if (tag == .fn_decl) blk: {
                        const body_node = tree.nodeData(decl_idx).node_and_node[1];
                        const end_token = tree.lastToken(body_node);
                        break :blk tree.tokenLocation(0, end_token).line;
                    } else start_loc.line;

                    try symbols.append(allocator, .{
                        .name = name,
                        .kind = .function,
                        .is_public = fn_proto.visib_token != null,
                        .start_line = @intCast(start_loc.line + 1),
                        .end_line = @intCast(end_line + 1),
                    });
                }
            },

            .simple_var_decl, .global_var_decl, .aligned_var_decl => {
                if (tree.fullVarDecl(decl_idx)) |var_decl| {
                    const name_token = var_decl.ast.mut_token + 1;
                    const name = tree.tokenSlice(name_token);
                    const start_loc = tree.tokenLocation(0, var_decl.ast.mut_token);
                    const is_public = var_decl.visib_token != null;

                    // Check if the init expression is a container (struct/enum/union)
                    if (var_decl.ast.init_node.unwrap()) |init_node| {
                        // Check for @import — handles both:
                        //   const std = @import("std");
                        //   const Store = @import("../storage/store.zig").Store;
                        if (tryExtractImport(tree, init_node)) |import_path| {
                            try imports.append(allocator, .{
                                .path = import_path,
                                .alias = name,
                                .line = @intCast(start_loc.line + 1),
                            });
                            continue;
                        }

                        const init_tag = tree.nodeTag(init_node);
                        const container_kind = classifyContainer(tree, init_tag);
                        if (container_kind) |kind| {
                            const end_token = tree.lastToken(init_node);
                            const end_loc = tree.tokenLocation(0, end_token);
                            try symbols.append(allocator, .{
                                .name = name,
                                .kind = kind,
                                .is_public = is_public,
                                .start_line = @intCast(start_loc.line + 1),
                                .end_line = @intCast(end_loc.line + 1),
                            });

                            // Recurse into container members and extract fields
                            var container_buf: [2]Ast.Node.Index = undefined;
                            if (tree.fullContainerDecl(&container_buf, init_node)) |container| {
                                try extractFields(tree, container.ast.members, fields, allocator);
                                try processDecls(tree, container.ast.members, symbols, imports, fields, allocator);
                            }
                            continue;
                        }
                    }

                    // Generic const/var declaration
                    try symbols.append(allocator, .{
                        .name = name,
                        .kind = .variable,
                        .is_public = is_public,
                        .start_line = @intCast(start_loc.line + 1),
                        .end_line = @intCast(start_loc.line + 1),
                    });
                }
            },

            .test_decl => {
                const data = tree.nodeData(decl_idx).opt_token_and_node;
                const name = if (data[0].unwrap()) |name_token|
                    stripQuotes(tree.tokenSlice(name_token))
                else
                    "(unnamed test)";

                const main_token = tree.nodeMainToken(decl_idx);
                const start_loc = tree.tokenLocation(0, main_token);
                const end_token = tree.lastToken(data[1]);
                const end_loc = tree.tokenLocation(0, end_token);

                try symbols.append(allocator, .{
                    .name = name,
                    .kind = .test_block,
                    .is_public = false,
                    .start_line = @intCast(start_loc.line + 1),
                    .end_line = @intCast(end_loc.line + 1),
                });
            },

            else => {},
        }
    }
}

/// Extract struct field names and their type names from container members.
fn extractFields(
    tree: Ast,
    members: []const Ast.Node.Index,
    fields: *std.ArrayList(ExtractedField),
    allocator: std.mem.Allocator,
) !void {
    for (members) |member| {
        if (tree.fullContainerField(member)) |field| {
            if (field.ast.tuple_like) continue;

            const field_name = tree.tokenSlice(field.ast.main_token);

            // Try to resolve a simple type name from the type expression
            const type_name: ?[]const u8 = if (field.ast.type_expr.unwrap()) |type_node| blk: {
                const type_tag = tree.nodeTag(type_node);
                if (type_tag == .identifier) {
                    break :blk tree.tokenSlice(tree.nodeMainToken(type_node));
                }
                // Handle pointer types: *Store, *const Store
                if (type_tag == .ptr_type_aligned or type_tag == .ptr_type or
                    type_tag == .ptr_type_sentinel)
                {
                    // child_type is the second element of opt_node_and_node
                    const child_node = tree.nodeData(type_node).opt_node_and_node[1];
                    if (tree.nodeTag(child_node) == .identifier) {
                        break :blk tree.tokenSlice(tree.nodeMainToken(child_node));
                    }
                }
                break :blk null;
            } else null;

            try fields.append(allocator, .{
                .name = field_name,
                .type_name = type_name,
            });
        }
    }
}

/// Extract all call expressions from the AST, mapping each to its enclosing function.
/// Uses flat iteration over all nodes rather than recursive tree walking.
fn extractAllCalls(
    tree: Ast,
    symbols: []const ExtractedSymbol,
    calls: *std.ArrayList(ExtractedCall),
    allocator: std.mem.Allocator,
) !void {
    const tags = tree.nodes.items(.tag);
    const num_nodes = tags.len;

    var i: u32 = 0;
    while (i < num_nodes) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        const tag = tags[i];

        // Only look at call nodes
        if (tag != .call and tag != .call_comma and
            tag != .call_one and tag != .call_one_comma) {
            continue;
        }

        var call_buf: [1]Ast.Node.Index = undefined;
        const call_info = tree.fullCall(&call_buf, node) orelse continue;

        // Resolve the callee name and qualifier
        const resolved = resolveCallTarget(tree, call_info.ast.fn_expr) orelse continue;

        // Skip builtins
        if (resolved.callee[0] == '@') continue;

        // Determine which function this call is inside by line number
        const loc = tree.tokenLocation(0, call_info.ast.lparen);
        const call_line: u32 = @intCast(loc.line + 1);

        const caller = findEnclosingFunction(symbols, call_line) orelse continue;

        try calls.append(allocator, .{
            .caller_name = caller,
            .callee_name = resolved.callee,
            .qualifier = resolved.qualifier,
            .line = call_line,
        });
    }
}

/// Find the name of the function whose line range contains the given line.
fn findEnclosingFunction(symbols: []const ExtractedSymbol, line: u32) ?[]const u8 {
    var best_name: ?[]const u8 = null;
    var best_span: u32 = std.math.maxInt(u32);

    for (symbols) |sym| {
        if (sym.kind != .function) continue;
        if (line >= sym.start_line and line <= sym.end_line) {
            const span = sym.end_line - sym.start_line;
            if (span < best_span) {
                best_span = span;
                best_name = sym.name;
            }
        }
    }
    return best_name;
}

const CallTarget = struct {
    callee: []const u8,
    qualifier: ?[]const u8,
};

/// Given the fn_expr of a call node, resolve the callee name and qualifier.
/// - foo()              → callee="foo", qualifier=null
/// - Store.init()       → callee="init", qualifier="Store"
/// - self.store.open()  → callee="open", qualifier="store"
/// - self.run()         → callee="run", qualifier=null (self is skipped)
fn resolveCallTarget(tree: Ast, fn_expr: Ast.Node.Index) ?CallTarget {
    const tag = tree.nodeTag(fn_expr);
    switch (tag) {
        .identifier => return .{
            .callee = tree.tokenSlice(tree.nodeMainToken(fn_expr)),
            .qualifier = null,
        },
        .field_access => {
            const data = tree.nodeData(fn_expr).node_and_token;
            const callee = tree.tokenSlice(data[1]);
            const obj_node = data[0];

            // Check what the object is
            const obj_tag = tree.nodeTag(obj_node);
            if (obj_tag == .identifier) {
                const obj_name = tree.tokenSlice(tree.nodeMainToken(obj_node));
                // self.method() — no useful qualifier
                if (std.mem.eql(u8, obj_name, "self")) {
                    return .{ .callee = callee, .qualifier = null };
                }
                // Type.method() or module.func()
                return .{ .callee = callee, .qualifier = obj_name };
            }

            // self.field.method() — the object is another field_access
            if (obj_tag == .field_access) {
                const inner_data = tree.nodeData(obj_node).node_and_token;
                const field_name = tree.tokenSlice(inner_data[1]);
                return .{ .callee = callee, .qualifier = field_name };
            }

            // Fallback: can't determine qualifier
            return .{ .callee = callee, .qualifier = null };
        },
        else => return null,
    }
}

/// Try to extract an import path from a node that might be:
///   @import("path")             — builtin_call_two with string literal arg
///   @import("path").Something   — field_access whose object is the above
fn tryExtractImport(tree: Ast, node: Ast.Node.Index) ?[]const u8 {
    // Direct @import("path")
    if (extractImportPath(tree, node)) |path| return path;

    // @import("path").Something — field_access wrapping the builtin call
    const tag = tree.nodeTag(node);
    if (tag == .field_access) {
        const obj_node = tree.nodeData(node).node_and_token[0];
        if (extractImportPath(tree, obj_node)) |path| return path;
    }

    return null;
}

/// Extract the string literal path from a direct @import("path") node.
fn extractImportPath(tree: Ast, node: Ast.Node.Index) ?[]const u8 {
    const tag = tree.nodeTag(node);
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) return null;

    const main_token = tree.nodeMainToken(node);
    const builtin_name = tree.tokenSlice(main_token);
    if (!std.mem.eql(u8, builtin_name, "@import")) return null;

    const args = tree.nodeData(node).opt_node_and_opt_node;
    const arg_node = args[0].unwrap() orelse return null;
    if (tree.nodeTag(arg_node) != .string_literal) return null;

    const raw = tree.tokenSlice(tree.nodeMainToken(arg_node));
    if (raw.len < 2) return null;
    return raw[1 .. raw.len - 1];
}

fn classifyContainer(tree: Ast, tag: Ast.Node.Tag) ?schema.NodeKind {
    // The main_token for container decls is the keyword: struct, enum, union
    _ = tree;
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        => .structure, // could be struct or enum — need to check keyword
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => .union_type,
        else => null,
    };
}

/// Refine a container_decl* node by checking if its keyword token is
/// `struct`, `enum`, or `union`.
pub fn classifyContainerByKeyword(tree: Ast, init_node: Ast.Node.Index) ?schema.NodeKind {
    const init_tag = tree.nodeTag(init_node);
    switch (init_tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        => {
            const keyword_token = tree.nodeMainToken(init_node);
            const keyword = tree.tokenSlice(keyword_token);
            if (std.mem.eql(u8, keyword, "struct")) return .structure;
            if (std.mem.eql(u8, keyword, "enum")) return .enumeration;
            if (std.mem.eql(u8, keyword, "union")) return .union_type;
            return .structure;
        },
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => return .union_type,
        else => return null,
    }
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

test "extract functions from zig source" {
    const source =
        \\const std = @import("std");
        \\
        \\pub fn hello() void {}
        \\
        \\fn helper() void {}
        \\
        \\test "basic" {
        \\    _ = helper;
        \\}
    ;

    var analysis = try analyzeSource(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), analysis.symbols.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.imports.len);

    // First symbol should be hello (pub fn)
    try std.testing.expectEqualStrings("hello", analysis.symbols[0].name);
    try std.testing.expect(analysis.symbols[0].kind == .function);
    try std.testing.expect(analysis.symbols[0].is_public);

    // Second should be helper (private fn)
    try std.testing.expectEqualStrings("helper", analysis.symbols[1].name);
    try std.testing.expect(!analysis.symbols[1].is_public);

    // Third should be the test block
    try std.testing.expectEqualStrings("basic", analysis.symbols[2].name);
    try std.testing.expect(analysis.symbols[2].kind == .test_block);

    // Import
    try std.testing.expectEqualStrings("std", analysis.imports[0].path);
    try std.testing.expectEqualStrings("std", analysis.imports[0].alias);
}

test "extract structs and enums" {
    const source =
        \\pub const MyStruct = struct {
        \\    x: u32,
        \\    y: u32,
        \\};
        \\
        \\const Color = enum { red, green, blue };
    ;

    var analysis = try analyzeSource(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), analysis.symbols.len);
    try std.testing.expectEqualStrings("MyStruct", analysis.symbols[0].name);
    try std.testing.expectEqualStrings("Color", analysis.symbols[1].name);
}

test "extract test declarations" {
    const source =
        \\test "something works" {
        \\    const x = 1;
        \\    _ = x;
        \\}
    ;

    var analysis = try analyzeSource(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), analysis.symbols.len);
    try std.testing.expectEqualStrings("something works", analysis.symbols[0].name);
    try std.testing.expect(analysis.symbols[0].kind == .test_block);
}

test "extract call expressions" {
    const source =
        \\fn helper() void {}
        \\
        \\fn caller() void {
        \\    helper();
        \\    helper();
        \\}
        \\
        \\fn another() void {
        \\    helper();
        \\}
    ;

    var analysis = try analyzeSource(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), analysis.symbols.len);
    try std.testing.expectEqual(@as(usize, 3), analysis.calls.len);

    // First two calls are from "caller" to "helper"
    try std.testing.expectEqualStrings("caller", analysis.calls[0].caller_name);
    try std.testing.expectEqualStrings("helper", analysis.calls[0].callee_name);
    try std.testing.expectEqualStrings("caller", analysis.calls[1].caller_name);
    try std.testing.expectEqualStrings("helper", analysis.calls[1].callee_name);

    // Third call is from "another" to "helper"
    try std.testing.expectEqualStrings("another", analysis.calls[2].caller_name);
    try std.testing.expectEqualStrings("helper", analysis.calls[2].callee_name);
}

test "extract struct fields and qualified calls" {
    const source =
        \\const Store = @import("../storage/store.zig").Store;
        \\const Ui = @import("../ui/ui.zig").Ui;
        \\
        \\pub const App = struct {
        \\    store: Store,
        \\    ui: Ui,
        \\
        \\    pub fn run(self: *App) void {
        \\        self.ui.printHelp();
        \\        self.store.open();
        \\    }
        \\};
    ;

    var analysis = try analyzeSource(std.testing.allocator, source);
    defer analysis.deinit(std.testing.allocator);

    // Should have 2 imports (Store, Ui)
    try std.testing.expectEqual(@as(usize, 2), analysis.imports.len);
    try std.testing.expectEqualStrings("Store", analysis.imports[0].alias);
    try std.testing.expectEqualStrings("../storage/store.zig", analysis.imports[0].path);
    try std.testing.expectEqualStrings("Ui", analysis.imports[1].alias);
    try std.testing.expectEqualStrings("../ui/ui.zig", analysis.imports[1].path);

    // Should have struct fields: store (Store), ui (Ui)
    try std.testing.expectEqual(@as(usize, 2), analysis.fields.len);
    try std.testing.expectEqualStrings("store", analysis.fields[0].name);
    try std.testing.expectEqualStrings("Store", analysis.fields[0].type_name.?);
    try std.testing.expectEqualStrings("ui", analysis.fields[1].name);
    try std.testing.expectEqualStrings("Ui", analysis.fields[1].type_name.?);

    // Should have 2 calls with qualifiers
    try std.testing.expectEqual(@as(usize, 2), analysis.calls.len);
    try std.testing.expectEqualStrings("run", analysis.calls[0].caller_name);
    try std.testing.expectEqualStrings("printHelp", analysis.calls[0].callee_name);
    try std.testing.expectEqualStrings("ui", analysis.calls[0].qualifier.?);
    try std.testing.expectEqualStrings("run", analysis.calls[1].caller_name);
    try std.testing.expectEqualStrings("open", analysis.calls[1].callee_name);
    try std.testing.expectEqualStrings("store", analysis.calls[1].qualifier.?);
}

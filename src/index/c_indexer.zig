//! C source indexer — produces a FileAnalysis via tree-sitter-c.
//!
//! Extracted: function definitions, struct/union/enum specifiers (including
//! those named via typedef), `#include "..."` imports (quoted only), and
//! call expressions mapped to their enclosing function by line range.
//!
//! Not yet extracted: macros, system headers, typedef aliases of primitive
//! types, qualified calls via pointer types (requires type resolution).

const std = @import("std");
const schema = @import("../graph/schema.zig");
const analysis = @import("analysis.zig");
const ts = @import("tree_sitter.zig");

pub const FileAnalysis = analysis.FileAnalysis;

extern fn tree_sitter_c() *const ts.Language;

/// Thread-local parser — tree-sitter parsers are not cheap to create, but
/// they are also not thread-safe. Each worker thread gets its own.
threadlocal var tl_parser: ?ts.Parser = null;

fn getParser() !*ts.Parser {
    if (tl_parser == null) {
        var p = try ts.Parser.init();
        try p.setLanguage(tree_sitter_c());
        tl_parser = p;
    }
    return &tl_parser.?;
}

pub fn analyzeSource(allocator: std.mem.Allocator, source: []const u8) !FileAnalysis {
    const parser = try getParser();
    var tree = try parser.parseString(source);
    defer tree.deinit();

    var symbols: std.ArrayListUnmanaged(analysis.ExtractedSymbol) = .{};
    defer symbols.deinit(allocator);

    var imports: std.ArrayListUnmanaged(analysis.ExtractedImport) = .{};
    defer imports.deinit(allocator);

    var calls_raw: std.ArrayListUnmanaged(RawCall) = .{};
    defer calls_raw.deinit(allocator);

    var fields: std.ArrayListUnmanaged(analysis.ExtractedField) = .{};
    defer fields.deinit(allocator);

    const root = tree.rootNode();
    try walk(root, source, allocator, &symbols, &imports, &calls_raw);

    // Pass 2: resolve each raw call to its enclosing function by line range.
    var calls: std.ArrayListUnmanaged(analysis.ExtractedCall) = .{};
    defer calls.deinit(allocator);

    const sym_slice = symbols.items;
    for (calls_raw.items) |rc| {
        const caller = findEnclosingFunction(sym_slice, rc.line) orelse continue;
        if (rc.callee_name.len == 0) continue;
        try calls.append(allocator, .{
            .caller_name = caller,
            .callee_name = rc.callee_name,
            .qualifier = rc.qualifier,
            .line = rc.line,
        });
    }

    return .{
        .symbols = try symbols.toOwnedSlice(allocator),
        .imports = try imports.toOwnedSlice(allocator),
        .calls = try calls.toOwnedSlice(allocator),
        .fields = try fields.toOwnedSlice(allocator),
    };
}

const RawCall = struct {
    callee_name: []const u8,
    qualifier: ?[]const u8,
    line: u32,
};

fn walk(
    node: ts.Node,
    source: []const u8,
    allocator: std.mem.Allocator,
    symbols: *std.ArrayListUnmanaged(analysis.ExtractedSymbol),
    imports: *std.ArrayListUnmanaged(analysis.ExtractedImport),
    calls: *std.ArrayListUnmanaged(RawCall),
) !void {
    const kind = node.kind();

    if (std.mem.eql(u8, kind, "function_definition")) {
        try extractFunction(node, source, allocator, symbols);
        // Still recurse into the body to find nested call_expressions.
    } else if (std.mem.eql(u8, kind, "preproc_include")) {
        try extractInclude(node, source, allocator, imports);
        return;
    } else if (std.mem.eql(u8, kind, "struct_specifier") or
        std.mem.eql(u8, kind, "union_specifier") or
        std.mem.eql(u8, kind, "enum_specifier"))
    {
        try extractRecord(node, source, allocator, symbols, kind);
        // Recurse — nested records are rare in C but legal.
    } else if (std.mem.eql(u8, kind, "type_definition")) {
        try extractTypedef(node, source, allocator, symbols);
        // Recurse so the inner struct body itself (if named) is also seen
        // once; duplicates are naturally deduped because the same name
        // produces the same node ID.
    } else if (std.mem.eql(u8, kind, "call_expression")) {
        try extractCall(node, source, allocator, calls);
        // Recurse to catch calls in arguments: foo(bar())
    }

    const count = node.namedChildCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try walk(node.namedChild(i), source, allocator, symbols, imports, calls);
    }
}

fn extractFunction(
    node: ts.Node,
    source: []const u8,
    allocator: std.mem.Allocator,
    symbols: *std.ArrayListUnmanaged(analysis.ExtractedSymbol),
) !void {
    const declarator = node.childByFieldName("declarator");
    if (declarator.isNull()) return;

    const name_node = findFunctionName(declarator);
    if (name_node.isNull()) return;

    const name = name_node.text(source);
    if (name.len == 0) return;

    const start_line: u32 = node.startPoint().row + 1;
    const end_line: u32 = node.endPoint().row + 1;

    try symbols.append(allocator, .{
        .name = name,
        .kind = .function,
        .is_public = !hasStaticSpecifier(node, source),
        .start_line = start_line,
        .end_line = end_line,
    });
}

/// A function declarator can be:
///   function_declarator { declarator: identifier "foo" }
///   pointer_declarator { declarator: function_declarator { ... } }   // returns pointer
/// Walk through pointer_declarator / parenthesized_declarator wrappers down
/// to the identifier.
fn findFunctionName(declarator: ts.Node) ts.Node {
    var cur = declarator;
    var guard: u32 = 0;
    while (!cur.isNull() and guard < 16) : (guard += 1) {
        const k = cur.kind();
        if (std.mem.eql(u8, k, "identifier") or std.mem.eql(u8, k, "field_identifier")) {
            return cur;
        }
        const next = cur.childByFieldName("declarator");
        if (next.isNull()) return .{ .raw = next.raw };
        cur = next;
    }
    return cur;
}

/// Look at the function's storage class specifier, if any, to decide whether
/// it is public (externally linkable) — a `static` function is private.
fn hasStaticSpecifier(node: ts.Node, source: []const u8) bool {
    const count = node.namedChildCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const ch = node.namedChild(i);
        if (std.mem.eql(u8, ch.kind(), "storage_class_specifier")) {
            if (std.mem.eql(u8, ch.text(source), "static")) return true;
        }
    }
    return false;
}

fn extractInclude(
    node: ts.Node,
    source: []const u8,
    allocator: std.mem.Allocator,
    imports: *std.ArrayListUnmanaged(analysis.ExtractedImport),
) !void {
    const path_node = node.childByFieldName("path");
    if (path_node.isNull()) return;

    // Only quoted includes produce a resolvable path.
    if (!std.mem.eql(u8, path_node.kind(), "string_literal")) return;

    const raw = path_node.text(source);
    if (raw.len < 2) return;
    // Strip surrounding quotes
    const path = raw[1 .. raw.len - 1];
    if (path.len == 0) return;

    const line: u32 = node.startPoint().row + 1;
    try imports.append(allocator, .{
        .path = path,
        .alias = path,
        .line = line,
    });
}

fn extractRecord(
    node: ts.Node,
    source: []const u8,
    allocator: std.mem.Allocator,
    symbols: *std.ArrayListUnmanaged(analysis.ExtractedSymbol),
    kind_str: []const u8,
) !void {
    const name_node = node.childByFieldName("name");
    if (name_node.isNull()) return;

    const name = name_node.text(source);
    if (name.len == 0) return;

    const node_kind: schema.NodeKind = if (std.mem.eql(u8, kind_str, "struct_specifier"))
        .structure
    else if (std.mem.eql(u8, kind_str, "union_specifier"))
        .union_type
    else
        .enumeration;

    try symbols.append(allocator, .{
        .name = name,
        .kind = node_kind,
        .is_public = true,
        .start_line = node.startPoint().row + 1,
        .end_line = node.endPoint().row + 1,
    });
}

/// typedef struct { ... } Foo; — pick up "Foo" as a structure symbol.
fn extractTypedef(
    node: ts.Node,
    source: []const u8,
    allocator: std.mem.Allocator,
    symbols: *std.ArrayListUnmanaged(analysis.ExtractedSymbol),
) !void {
    // type_definition has a `type` field (struct_specifier etc.) and one or
    // more `declarator` fields containing the typedef-name identifier.
    const type_node = node.childByFieldName("type");
    var node_kind: schema.NodeKind = .structure;
    if (!type_node.isNull()) {
        const tk = type_node.kind();
        if (std.mem.eql(u8, tk, "union_specifier")) node_kind = .union_type;
        if (std.mem.eql(u8, tk, "enum_specifier")) node_kind = .enumeration;
    }

    // Walk declarator chain to find the final identifier (typedef name).
    var declarator = node.childByFieldName("declarator");
    var guard: u32 = 0;
    while (!declarator.isNull() and guard < 16) : (guard += 1) {
        const k = declarator.kind();
        if (std.mem.eql(u8, k, "type_identifier") or std.mem.eql(u8, k, "identifier")) {
            const name = declarator.text(source);
            if (name.len == 0) return;
            try symbols.append(allocator, .{
                .name = name,
                .kind = node_kind,
                .is_public = true,
                .start_line = node.startPoint().row + 1,
                .end_line = node.endPoint().row + 1,
            });
            return;
        }
        const inner = declarator.childByFieldName("declarator");
        if (inner.isNull()) return;
        declarator = inner;
    }
}

fn extractCall(
    node: ts.Node,
    source: []const u8,
    allocator: std.mem.Allocator,
    calls: *std.ArrayListUnmanaged(RawCall),
) !void {
    const fn_expr = node.childByFieldName("function");
    if (fn_expr.isNull()) return;

    const k = fn_expr.kind();
    var callee: []const u8 = "";
    var qualifier: ?[]const u8 = null;

    if (std.mem.eql(u8, k, "identifier")) {
        callee = fn_expr.text(source);
    } else if (std.mem.eql(u8, k, "field_expression")) {
        // obj.field() or obj->field()
        const field = fn_expr.childByFieldName("field");
        const arg = fn_expr.childByFieldName("argument");
        if (!field.isNull()) callee = field.text(source);
        if (!arg.isNull() and std.mem.eql(u8, arg.kind(), "identifier")) {
            qualifier = arg.text(source);
        }
    } else {
        return;
    }

    try calls.append(allocator, .{
        .callee_name = callee,
        .qualifier = qualifier,
        .line = node.startPoint().row + 1,
    });
}

fn findEnclosingFunction(symbols: []const analysis.ExtractedSymbol, line: u32) ?[]const u8 {
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

// ── Tests ──────────────────────────────────────────────────────

test "c_indexer: extracts a simple function" {
    const src = "int add(int a, int b) { return a + b; }";
    var a = try analyzeSource(std.testing.allocator, src);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), a.symbols.len);
    try std.testing.expectEqualStrings("add", a.symbols[0].name);
    try std.testing.expect(a.symbols[0].kind == .function);
    try std.testing.expect(a.symbols[0].is_public);
}

test "c_indexer: static function marked non-public" {
    const src = "static int helper(void) { return 0; }";
    var a = try analyzeSource(std.testing.allocator, src);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), a.symbols.len);
    try std.testing.expectEqualStrings("helper", a.symbols[0].name);
    try std.testing.expect(!a.symbols[0].is_public);
}

test "c_indexer: quoted include becomes an import" {
    const src =
        \\#include "foo.h"
        \\#include <stdio.h>
    ;
    var a = try analyzeSource(std.testing.allocator, src);
    defer a.deinit(std.testing.allocator);

    // <stdio.h> is a system include and is skipped.
    try std.testing.expectEqual(@as(usize, 1), a.imports.len);
    try std.testing.expectEqualStrings("foo.h", a.imports[0].path);
}

test "c_indexer: struct, union, enum specifiers" {
    const src =
        \\struct Point { int x; int y; };
        \\union Value { int i; float f; };
        \\enum Color { RED, GREEN, BLUE };
    ;
    var a = try analyzeSource(std.testing.allocator, src);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), a.symbols.len);
    try std.testing.expect(a.symbols[0].kind == .structure);
    try std.testing.expectEqualStrings("Point", a.symbols[0].name);
    try std.testing.expect(a.symbols[1].kind == .union_type);
    try std.testing.expect(a.symbols[2].kind == .enumeration);
}

test "c_indexer: typedef struct picks up the alias" {
    const src =
        \\typedef struct { int x; } Foo;
    ;
    var a = try analyzeSource(std.testing.allocator, src);
    defer a.deinit(std.testing.allocator);

    // Should find the typedef alias "Foo" as a structure.
    var saw_foo = false;
    for (a.symbols) |s| {
        if (std.mem.eql(u8, s.name, "Foo") and s.kind == .structure) saw_foo = true;
    }
    try std.testing.expect(saw_foo);
}

test "c_indexer: call expressions mapped to enclosing function" {
    const src =
        \\static int helper(int x) { return x + 1; }
        \\
        \\int caller(void) {
        \\    int a = helper(1);
        \\    return helper(a);
        \\}
    ;
    var a = try analyzeSource(std.testing.allocator, src);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), a.calls.len);
    for (a.calls) |c| {
        try std.testing.expectEqualStrings("caller", c.caller_name);
        try std.testing.expectEqualStrings("helper", c.callee_name);
        try std.testing.expect(c.qualifier == null);
    }
}

test "c_indexer: field call captures qualifier" {
    const src =
        \\struct S { int x; };
        \\int run(struct S *s) {
        \\    return foo(s);
        \\}
        \\int use(void) {
        \\    struct S s;
        \\    return s.method(1);
        \\}
    ;
    var a = try analyzeSource(std.testing.allocator, src);
    defer a.deinit(std.testing.allocator);

    var saw_qualified = false;
    for (a.calls) |c| {
        if (std.mem.eql(u8, c.callee_name, "method")) {
            try std.testing.expect(c.qualifier != null);
            try std.testing.expectEqualStrings("s", c.qualifier.?);
            saw_qualified = true;
        }
    }
    try std.testing.expect(saw_qualified);
}

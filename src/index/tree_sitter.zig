//! Minimal Zig wrapper over the tree-sitter C API.
//!
//! Exposes only what the atlas-graph indexers need: parsing a source string
//! into a tree, walking nodes, and extracting byte ranges + node types.

const std = @import("std");

pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub const Language = c.TSLanguage;
pub const Point = c.TSPoint;

pub const Parser = struct {
    raw: *c.TSParser,

    pub fn init() !Parser {
        const p = c.ts_parser_new() orelse return error.ParserInitFailed;
        return .{ .raw = p };
    }

    pub fn deinit(self: *Parser) void {
        c.ts_parser_delete(self.raw);
    }

    pub fn setLanguage(self: *Parser, lang: *const Language) !void {
        if (!c.ts_parser_set_language(self.raw, lang)) {
            return error.LanguageVersionMismatch;
        }
    }

    /// Parse a UTF-8 source slice. Returned Tree must be deinit'd by caller.
    pub fn parseString(self: *Parser, source: []const u8) !Tree {
        const t = c.ts_parser_parse_string(
            self.raw,
            null,
            source.ptr,
            @intCast(source.len),
        ) orelse return error.ParseFailed;
        return .{ .raw = t };
    }
};

pub const Tree = struct {
    raw: *c.TSTree,

    pub fn deinit(self: *Tree) void {
        c.ts_tree_delete(self.raw);
    }

    pub fn rootNode(self: Tree) Node {
        return .{ .raw = c.ts_tree_root_node(self.raw) };
    }
};

pub const Node = struct {
    raw: c.TSNode,

    pub fn isNull(self: Node) bool {
        return c.ts_node_is_null(self.raw);
    }

    /// Grammar symbol name, e.g. "function_definition", "identifier".
    pub fn kind(self: Node) []const u8 {
        const ptr = c.ts_node_type(self.raw);
        return std.mem.span(ptr);
    }

    pub fn startByte(self: Node) u32 {
        return c.ts_node_start_byte(self.raw);
    }

    pub fn endByte(self: Node) u32 {
        return c.ts_node_end_byte(self.raw);
    }

    pub fn startPoint(self: Node) Point {
        return c.ts_node_start_point(self.raw);
    }

    pub fn endPoint(self: Node) Point {
        return c.ts_node_end_point(self.raw);
    }

    pub fn childCount(self: Node) u32 {
        return c.ts_node_child_count(self.raw);
    }

    pub fn namedChildCount(self: Node) u32 {
        return c.ts_node_named_child_count(self.raw);
    }

    pub fn child(self: Node, i: u32) Node {
        return .{ .raw = c.ts_node_child(self.raw, i) };
    }

    pub fn namedChild(self: Node, i: u32) Node {
        return .{ .raw = c.ts_node_named_child(self.raw, i) };
    }

    pub fn childByFieldName(self: Node, name: []const u8) Node {
        return .{ .raw = c.ts_node_child_by_field_name(
            self.raw,
            name.ptr,
            @intCast(name.len),
        ) };
    }

    /// Byte-range text slice into the original source buffer.
    pub fn text(self: Node, source: []const u8) []const u8 {
        const s = self.startByte();
        const e = self.endByte();
        if (e > source.len or s > e) return "";
        return source[s..e];
    }
};

// ── Tests ──────────────────────────────────────────────────────

extern fn tree_sitter_c() *const Language;

test "parser parses a trivial C function" {
    var parser = try Parser.init();
    defer parser.deinit();

    try parser.setLanguage(tree_sitter_c());

    const src = "int add(int a, int b) { return a + b; }";
    var tree = try parser.parseString(src);
    defer tree.deinit();

    const root = tree.rootNode();
    try std.testing.expectEqualStrings("translation_unit", root.kind());
    try std.testing.expect(root.namedChildCount() >= 1);

    const func = root.namedChild(0);
    try std.testing.expectEqualStrings("function_definition", func.kind());
}

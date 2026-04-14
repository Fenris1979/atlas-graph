const std = @import("std");

pub const Language = enum {
    zig,
    c,
    cpp,
    objc,
    unknown,
};

pub const NodeKind = enum {
    repository,
    directory,
    file,
    module,
    function,
    method,
    structure,
    enumeration,
    union_type,
    class,
    protocol,
    variable,
    field,
    test_block,
    external_symbol,
};

pub const EdgeKind = enum {
    contains,
    imports,
    includes,
    defines,
    references,
    calls,
    depends_on,
    reachable_from,
    same_cluster,
};

pub const Node = struct {
    id: []const u8,
    kind: NodeKind,
    lang: Language,
    name: []const u8,
    path: []const u8,
    start_line: u32 = 0,
    end_line: u32 = 0,
};

pub const Edge = struct {
    src_id: []const u8,
    dst_id: []const u8,
    kind: EdgeKind,
    confidence: f32 = 1.0,
};

pub fn languageFromPath(path: []const u8) Language {
    if (std.mem.endsWith(u8, path, ".zig")) return .zig;
    if (std.mem.endsWith(u8, path, ".c") or std.mem.endsWith(u8, path, ".h")) return .c;
    if (
        std.mem.endsWith(u8, path, ".cc") or
        std.mem.endsWith(u8, path, ".cpp") or
        std.mem.endsWith(u8, path, ".cxx") or
        std.mem.endsWith(u8, path, ".hpp") or
        std.mem.endsWith(u8, path, ".hh")
    ) return .cpp;
    if (std.mem.endsWith(u8, path, ".m") or std.mem.endsWith(u8, path, ".mm")) return .objc;
    return .unknown;
}

test "languageFromPath detects languages" {
    try std.testing.expect(languageFromPath("src/main.zig") == .zig);
    try std.testing.expect(languageFromPath("src/a.cpp") == .cpp);
    try std.testing.expect(languageFromPath("src/a.m") == .objc);
}

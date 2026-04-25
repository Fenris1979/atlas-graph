//! Language-agnostic analysis types produced by per-language indexers
//! and consumed by the index manager to write nodes and edges.

const std = @import("std");
const schema = @import("../graph/schema.zig");

pub const ExtractedSymbol = struct {
    name: []const u8,
    kind: schema.NodeKind,
    is_public: bool,
    start_line: u32,
    end_line: u32,
};

pub const ExtractedImport = struct {
    /// The import path string — e.g. "std", "../foo.zig", "foo.h".
    path: []const u8,
    /// The local name bound to the import (Zig: `const alias = @import(...)`;
    /// for C #includes, this equals the path since there's no alias).
    alias: []const u8,
    line: u32,
};

pub const ExtractedCall = struct {
    caller_name: []const u8,
    callee_name: []const u8,
    /// Qualifier before the callee, if any. e.g. `Store.init()` → "Store",
    /// `self.ui.printHelp()` → "ui", `ptr->foo()` → "ptr".
    qualifier: ?[]const u8 = null,
    line: u32,
};

pub const ExtractedField = struct {
    name: []const u8,
    type_name: ?[]const u8,
};

pub const FileAnalysis = struct {
    symbols: []ExtractedSymbol,
    imports: []ExtractedImport,
    calls: []ExtractedCall,
    fields: []ExtractedField,

    pub fn deinit(self: *FileAnalysis, allocator: std.mem.Allocator) void {
        allocator.free(self.symbols);
        allocator.free(self.imports);
        allocator.free(self.calls);
        allocator.free(self.fields);
    }
};

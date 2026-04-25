const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Compile vendored SQLite from source for zero-dependency cross-platform builds
    const sqlite_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION" },
    });

    const sqlite_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "sqlite3",
        .root_module = sqlite_mod,
    });
    sqlite_lib.installHeader(b.path("vendor/sqlite/sqlite3.h"), "sqlite3.h");

    // Compile vendored tree-sitter runtime + C grammar
    const tree_sitter_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tree_sitter_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    tree_sitter_mod.addIncludePath(b.path("vendor/tree-sitter/src"));
    tree_sitter_mod.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/src/lib.c"),
        .flags = &.{ "-std=c11", "-fvisibility=hidden" },
    });
    tree_sitter_mod.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter-c/src/parser.c"),
        .flags = &.{"-std=c11"},
    });

    const tree_sitter_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "tree-sitter",
        .root_module = tree_sitter_mod,
    });
    tree_sitter_lib.installHeader(b.path("vendor/tree-sitter/include/tree_sitter/api.h"), "tree_sitter/api.h");

    const exe = b.addExecutable(.{
        .name = "atlas-graph",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.linkLibrary(sqlite_lib);
    exe.root_module.linkLibrary(tree_sitter_lib);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run Atlas Graph");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.linkLibrary(sqlite_lib);
    unit_tests.root_module.linkLibrary(tree_sitter_lib);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

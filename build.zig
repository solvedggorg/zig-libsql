const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_flags = [_][]const u8{
        "-std=c99",
        // Thread-safe default (matches multi-threaded Zig consumers).
        "-DSQLITE_THREADSAFE=1",
        // Compatibility contract: the next two flags change default SQL
        // semantics for EVERY local database opened through this library, so
        // consumers relying on stock SQLite defaults must account for them:
        //   * SQLITE_DEFAULT_FOREIGN_KEYS=1 enforces foreign-key constraints by
        //     default (upstream SQLite ships them off).
        //   * SQLITE_DQS=0 disables the double-quoted-string misfeature, so a
        //     "..." token is always an identifier, never a string literal.
        "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
        // Embedded: no dynamic extension loading unless we opt in later.
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        // Quieter / smaller for library use (see contract note above).
        "-DSQLITE_DQS=0",
    };

    const mod = b.addModule("zig_libsql", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &sqlite_flags,
    });
    mod.addIncludePath(b.path("vendor"));

    const exe = b.addExecutable(.{
        .name = "zig_libsql",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_libsql", .module = mod },
            },
            .link_libc = true,
        }),
    });
    // Executable needs the amalgamation too when it only imports the module —
    // the module's C sources are linked through the import graph.
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the demo CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run library and CLI tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

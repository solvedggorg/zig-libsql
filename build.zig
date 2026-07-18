const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_rust_bridge = b.option(
        bool,
        "enable-rust-bridge",
        "Load rusty-built libsql_bridge cdylib for classic embedded replica sync",
    ) orelse false;
    const rust_bridge_lib = b.option(
        []const u8,
        "rust-bridge-lib",
        "Path to liblibsql_bridge shared library (empty = platform default name / loader path)",
    ) orelse "";

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_rust_bridge", enable_rust_bridge);
    build_options.addOption([]const u8, "rust_bridge_lib", rust_bridge_lib);

    const sqlite_flags = [_][]const u8{
        "-std=c99",
        // Thread-safe default (matches multi-threaded Zig consumers).
        "-DSQLITE_THREADSAFE=1",
        // Compatibility contract: enforces foreign-key constraints by default
        // for EVERY local database opened through this library (upstream SQLite
        // ships them off), so consumers relying on stock defaults must account
        // for it.
        "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
        // Embedded: no dynamic extension loading unless we opt in later.
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        // Compatibility contract: disables the double-quoted-string misfeature,
        // changing SQL parsing semantics so a "..." token is always an
        // identifier, never a string literal. Affects every local database
        // opened through this library.
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
    mod.addOptions("build_options", build_options);
    // DynLib for optional rust bridge.
    if (enable_rust_bridge) {
        mod.link_libcpp = false;
    }

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

    // Tests live in `src/tests.zig` so that `src/root.zig` stays limited to
    // public exports + version. The test module links the amalgamation itself
    // and imports `root.zig` (public surface) plus submodules for unit tests.
    // Note: cannot also `addImport("zig_libsql", mod)` here — Zig forbids the
    // same source file existing in two modules of one compilation.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &sqlite_flags,
    });
    test_mod.addIncludePath(b.path("vendor"));
    test_mod.addOptions("build_options", build_options);

    const mod_tests = b.addTest(.{
        .root_module = test_mod,
    });
    // DynLib needs libdl on Linux.
    if (enable_rust_bridge and target.result.os.tag == .linux) {
        mod_tests.root_module.linkSystemLibrary("dl", .{});
        // Also for the library module consumers — link on the module used by tests.
        test_mod.linkSystemLibrary("dl", .{});
        mod.linkSystemLibrary("dl", .{});
    }
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run library and CLI tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // --- rusty bridge (optional) ---
    const bridge_step = b.step("bridge", "Build libsql_bridge cdylib with rusty");
    const rusty_build = b.addSystemCommand(&.{ "rusty", "build" });
    rusty_build.setCwd(b.path("bridge"));
    rusty_build.setEnvironmentVariable("CARGO_TERM_COLOR", "always");
    bridge_step.dependOn(&rusty_build.step);
}

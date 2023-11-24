const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mcdata_dep = b.dependency("minecraft-data", .{});

    // TODO: follow this instead https://ziglang.org/learn/build-system/#generating-zig-source-code
    //     currently made referencing https://codeberg.org/dude_the_builder/zig_in_depth/src/branch/main/code_gen_build/build.zig
    const gen_exe = b.addExecutable(.{
        .name = "gen",
        .root_source_file = .{ .path = "src/gen.zig" },
    });

    const run_gen_exe = b.addRunArtifact(gen_exe);
    run_gen_exe.step.dependOn(&gen_exe.step);
    run_gen_exe.addDirectoryArg(mcdata_dep.path("data"));
    const generated_file = run_gen_exe.addOutputFileArg("generated.zig");

    const gen_write_files = b.addWriteFiles();
    gen_write_files.addCopyFileToSource(generated_file, "src/generated.zig");
    b.getInstallStep().dependOn(&gen_write_files.step);

    const uuid6_mod = b.dependency("uuid6", .{
        .optimize = optimize,
        .target = target,
    }).module("uuid6");

    const mcp_mod = b.addModule("mcp", .{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &.{
            .{ .name = "uuid6", .module = uuid6_mod },
        },
    });
    _ = mcp_mod;

    const lib = b.addStaticLibrary(.{
        .name = "zigmcp",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib.addModule("uuid6", uuid6_mod);

    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    main_tests.addModule("uuid6", uuid6_mod);

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}

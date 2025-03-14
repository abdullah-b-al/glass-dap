const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    build_gen(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "glass-dap",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    build_exe(b, exe, target, optimize, true);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    // This is where the interesting part begins.
    // As you can see we are re-defining the same
    // executable but we're binding it to a
    // dedicated build step.
    const exe_check = b.addExecutable(.{
        .name = "glass-dap",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    build_exe(b, exe_check, target, optimize, false);
    const check = b.step("check", "Check if main compiles");
    check.dependOn(&exe_check.step);

    const ini_unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_ini_unit_tests = b.addRunArtifact(ini_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_ini_unit_tests.step);
}

fn build_gen(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const exe = b.addExecutable(.{
        .name = "gen",
        .root_source_file = b.path("gen/gen.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&exe.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run-gen", "Generate zig code from json schema");
    run_step.dependOn(&run_cmd.step);
}

fn build_exe(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, install: bool) void {
    const assets = b.addModule("assets", .{
        .root_source_file = b.path("assets/assets.zig"),
    });
    exe.root_module.addImport("assets", assets);

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.linkLibrary(zglfw.artifact("glfw"));

    const zopengl = b.dependency("zopengl", .{
        .target = target,
    });
    exe.root_module.addImport("zopengl", zopengl.module("root"));

    const zgui = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .glfw_opengl3,
        .with_freetype = true,
        .with_implot = true,
        .use_wchar32 = true,
    });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    const known_folders = b.dependency("known_folders", .{}).module("known-folders");
    exe.root_module.addImport("known-folders", known_folders);

    if (install) {
        b.installArtifact(exe);
    }
}

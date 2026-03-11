const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ziggy_piai_dep = b.dependency("ziggy_piai", .{
        .target = target,
        .optimize = optimize,
    });
    const ziggy_piai_module = ziggy_piai_dep.module("ziggypiai");
    const spider_protocol_dep = b.dependency("spider_protocol", .{
        .target = target,
        .optimize = optimize,
    });
    const spider_protocol_module = spider_protocol_dep.module("spider-protocol");
    const ziggy_memory_store_dep = b.dependency("ziggy_memory_store", .{
        .target = target,
        .optimize = optimize,
    });
    const ziggy_memory_store_module = ziggy_memory_store_dep.module("ziggy-memory-store");
    const ziggy_tool_runtime_dep = b.dependency("ziggy_tool_runtime", .{
        .target = target,
        .optimize = optimize,
    });
    const ziggy_tool_runtime_module = ziggy_tool_runtime_dep.module("ziggy-tool-runtime");

    const ziggy_run_orchestrator_module = b.createModule(.{
        .root_source_file = b.path("deps/ziggy-run-orchestrator/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    ziggy_run_orchestrator_module.addImport("ziggy-memory-store", ziggy_memory_store_module);

    const ziggy_runtime_hooks_module = b.createModule(.{
        .root_source_file = b.path("deps/ziggy-runtime-hooks/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    ziggy_runtime_hooks_module.addImport("ziggy-memory-store", ziggy_memory_store_module);
    ziggy_runtime_hooks_module.addImport("ziggy-run-orchestrator", ziggy_run_orchestrator_module);

    const monkey_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    monkey_mod.addImport("ziggy-piai", ziggy_piai_module);
    monkey_mod.addImport("spider-protocol", spider_protocol_module);
    monkey_mod.addImport("ziggy-memory-store", ziggy_memory_store_module);
    monkey_mod.addImport("ziggy-tool-runtime", ziggy_tool_runtime_module);
    monkey_mod.addImport("ziggy-runtime-hooks", ziggy_runtime_hooks_module);
    monkey_mod.addImport("ziggy-run-orchestrator", ziggy_run_orchestrator_module);

    const monkey = b.addExecutable(.{
        .name = "spider-monkey",
        .root_module = monkey_mod,
    });
    monkey.linkLibC();
    b.installArtifact(monkey);

    const run_cmd = b.addRunArtifact(monkey);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run Spider Monkey");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Spider Monkey tests");
    test_step.dependOn(&run_tests.step);
}

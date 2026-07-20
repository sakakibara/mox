const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });
    const toml_mod = toml_dep.module("toml");

    const json_dep = b.dependency("json", .{
        .target = target,
        .optimize = optimize,
    });
    const json_mod = json_dep.module("json");

    const yaml_dep = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });
    const yaml_mod = yaml_dep.module("yaml");

    const ini_dep = b.dependency("ini", .{
        .target = target,
        .optimize = optimize,
    });
    const ini_mod = ini_dep.module("ini");

    const env_dep = b.dependency("env", .{
        .target = target,
        .optimize = optimize,
    });
    const env_mod = env_dep.module("env");

    const cli_dep = b.dependency("cli", .{
        .target = target,
        .optimize = optimize,
    });
    const cli_mod = cli_dep.module("cli");

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // for std.c.chmod (no portable Zig wrapper in 0.16)
    });
    lib_mod.addImport("toml", toml_mod);
    lib_mod.addImport("json", json_mod);
    lib_mod.addImport("yaml", yaml_mod);
    lib_mod.addImport("ini", ini_mod);
    lib_mod.addImport("cli", cli_mod);
    lib_mod.addImport("env", env_mod);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    lib_mod.addOptions("build_options", build_options);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("mox", lib_mod);

    const exe = b.addExecutable(.{
        .name = "mox",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run mox");
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const exe_tests = b.addTest(.{ .root_module = exe_mod });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // Integration tests at tests/dsl_test.zig.
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/dsl_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_mod.addImport("mox", lib_mod);
    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);

    // Source tree integration tests at tests/source_test.zig.
    const source_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/source_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    source_tests_mod.addImport("mox", lib_mod);
    const source_tests = b.addTest(.{ .root_module = source_tests_mod });
    test_step.dependOn(&b.addRunArtifact(source_tests).step);

    // Compose integration tests at tests/compose_test.zig.
    const compose_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/compose_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    compose_tests_mod.addImport("mox", lib_mod);
    const compose_tests = b.addTest(.{ .root_module = compose_tests_mod });
    test_step.dependOn(&b.addRunArtifact(compose_tests).step);

    // Apply integration tests at tests/apply_test.zig.
    const apply_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/apply_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    apply_tests_mod.addImport("mox", lib_mod);
    const apply_tests = b.addTest(.{ .root_module = apply_tests_mod });
    test_step.dependOn(&b.addRunArtifact(apply_tests).step);

    // CLI test harness (shared by apply/commit/lifecycle) canaries at
    // tests/testutil.zig.
    const testutil_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/testutil.zig"),
        .target = target,
        .optimize = optimize,
    });
    testutil_tests_mod.addImport("mox", lib_mod);
    const testutil_tests = b.addTest(.{ .root_module = testutil_tests_mod });
    test_step.dependOn(&b.addRunArtifact(testutil_tests).step);

    // Coupling integration tests at tests/coupling_test.zig.
    const coupling_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/coupling_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    coupling_tests_mod.addImport("mox", lib_mod);
    const coupling_tests = b.addTest(.{ .root_module = coupling_tests_mod });
    test_step.dependOn(&b.addRunArtifact(coupling_tests).step);

    // Classify integration tests at tests/classify_test.zig.
    const classify_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/classify_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    classify_tests_mod.addImport("mox", lib_mod);
    const classify_tests = b.addTest(.{ .root_module = classify_tests_mod });
    test_step.dependOn(&b.addRunArtifact(classify_tests).step);

    // Secret integration tests at tests/secret_test.zig.
    const secret_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/secret_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    secret_tests_mod.addImport("mox", lib_mod);
    const secret_tests = b.addTest(.{ .root_module = secret_tests_mod });
    test_step.dependOn(&b.addRunArtifact(secret_tests).step);

    // Private-layer integration tests at tests/private_test.zig.
    const private_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/private_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    private_tests_mod.addImport("mox", lib_mod);
    const private_tests = b.addTest(.{ .root_module = private_tests_mod });
    test_step.dependOn(&b.addRunArtifact(private_tests).step);

    // Trigger integration tests at tests/trigger_test.zig.
    const trigger_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/trigger_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    trigger_tests_mod.addImport("mox", lib_mod);
    const trigger_tests = b.addTest(.{ .root_module = trigger_tests_mod });
    test_step.dependOn(&b.addRunArtifact(trigger_tests).step);

    // Commit integration tests at tests/commit_test.zig.
    const commit_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/commit_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    commit_tests_mod.addImport("mox", lib_mod);
    const commit_tests = b.addTest(.{ .root_module = commit_tests_mod });
    test_step.dependOn(&b.addRunArtifact(commit_tests).step);

    // DSL rejection tests at tests/dsl_rejection_test.zig.
    const dsl_rejection_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/dsl_rejection_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    dsl_rejection_tests_mod.addImport("mox", lib_mod);
    const dsl_rejection_tests = b.addTest(.{ .root_module = dsl_rejection_tests_mod });
    test_step.dependOn(&b.addRunArtifact(dsl_rejection_tests).step);

    // Lifecycle-command integration tests at tests/lifecycle_test.zig.
    const lifecycle_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/lifecycle_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lifecycle_tests_mod.addImport("mox", lib_mod);
    const lifecycle_tests = b.addTest(.{ .root_module = lifecycle_tests_mod });
    test_step.dependOn(&b.addRunArtifact(lifecycle_tests).step);

    // Generator-prune property + fuzz test at tests/prune_property_test.zig.
    // The deterministic property test runs on every `zig build test`; its Smith
    // target also fuzzes continuously under `zig build fuzz --fuzz`.
    const prune_prop_mod = b.createModule(.{
        .root_source_file = b.path("tests/prune_property_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    prune_prop_mod.addImport("mox", lib_mod);
    const prune_prop_tests = b.addTest(.{ .root_module = prune_prop_mod });
    test_step.dependOn(&b.addRunArtifact(prune_prop_tests).step);

    // Fuzz targets at tests/fuzz_test.zig. Run once as smoke tests under the
    // normal test step; fuzz continuously with `zig build fuzz --fuzz`.
    const fuzz_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_tests_mod.addImport("mox", lib_mod);
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_tests_mod });
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    const fuzz_step = b.step("fuzz", "Run the fuzz targets (add --fuzz to fuzz continuously)");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);
    fuzz_step.dependOn(&b.addRunArtifact(prune_prop_tests).step);
}

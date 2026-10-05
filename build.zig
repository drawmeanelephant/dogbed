const std = @import("std");

/// The binary name here and in the scaffold's usage hints.
const exe_name = "dogbed";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", packageVersion(b));
    // Where `zig build` installs the dogbed binary, and where the repo root
    // is: the tests run the real binary through the real build scripts
    // (scaffold + docs), which need both. The test step depends on the
    // install below, so the binary exists and is fresh whenever tests run.
    build_options.addOption([]const u8, "dogbed_exe", b.getInstallPath(.bin, exe_name));
    build_options.addOption([]const u8, "repo_root", b.build_root.path orelse ".");
    const build_options_mod = build_options.createModule();

    const k4o_dep = b.dependency("k4o", .{
        .target = target,
        .optimize = optimize,
    });
    const oliver_dep = b.dependency("oliver", .{
        .target = target,
        .optimize = optimize,
    });

    // Embedded starter templates printed by `dogbed template <name>`.
    const templates_mod = b.createModule(.{
        .root_source_file = b.path("share/templates.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Embedded site scaffold written by `dogbed init`.
    const scaffold_mod = b.createModule(.{
        .root_source_file = b.path("share/scaffold.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "k4o", .module = k4o_dep.module("k4o") },
            .{ .name = "oliver", .module = oliver_dep.module("oliver") },
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "templates", .module = templates_mod },
            .{ .name = "scaffold", .module = scaffold_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = cli_mod,
    });
    // One install step, shared by `zig build` and `zig build test`: the
    // build-script tests spawn the installed binary.
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "k4o", .module = k4o_dep.module("k4o") },
            .{ .name = "oliver", .module = oliver_dep.module("oliver") },
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "templates", .module = templates_mod },
            .{ .name = "scaffold", .module = scaffold_mod },
            .{ .name = "main", .module = cli_mod },
        },
    });
    const tests = b.addTest(.{
        .root_module = tests_mod,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&install_exe.step);
}

/// Reads `.version = "..."` from build.zig.zon at configure time (single
/// source of truth for the version string).
fn packageVersion(b: *std.Build) []const u8 {
    const marker = ".version = \"";
    const zon = std.Io.Dir.readFileAlloc(.cwd(), b.graph.io, "build.zig.zon", b.allocator, .limited(1 << 20)) catch return "0.0.0";
    const start = std.mem.indexOf(u8, zon, marker) orelse return "0.0.0";
    const rest = zon[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "0.0.0";
    return b.dupe(rest[0..end]);
}

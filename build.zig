const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", packageVersion(b));
    const build_options_mod = build_options.createModule();

    const k4o_dep = b.dependency("k4o", .{
        .target = target,
        .optimize = optimize,
    });
    const oliver_dep = b.dependency("oliver", .{
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
        },
    });

    const exe = b.addExecutable(.{
        .name = "dogbed",
        .root_module = cli_mod,
    });
    b.installArtifact(exe);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "k4o", .module = k4o_dep.module("k4o") },
            .{ .name = "oliver", .module = oliver_dep.module("oliver") },
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "main", .module = cli_mod },
        },
    });
    const tests = b.addTest(.{
        .root_module = tests_mod,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&run_tests.step);
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

//! radar: line-anchored reports for a pull workspace (CLI, web UI, MCP),
//! stored as cpull issues through cpull's HTTP API.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const theme_dep = b.dependency("theme", .{ .target = target, .optimize = optimize, .highlight = true });
    mod.addImport("theme", theme_dep.module("theme"));
    mod.addImport("discovery", theme_dep.module("discovery"));
    mod.addImport("highlight", theme_dep.module("highlight"));
    mod.addImport("clap", b.dependency("clap", .{ .target = target, .optimize = optimize }).module("clap"));
    mod.addImport("parley", b.dependency("parley", .{ .target = target, .optimize = optimize }).module("parley"));

    // the highlighter links tree-sitter (C)
    const exe = b.addExecutable(.{ .name = "radar", .root_module = mod, .use_llvm = true });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run radar").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod, .filters = test_filters, .use_llvm = true });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}

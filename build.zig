const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const libraries_build = b.lazyImport(@This(), "r4os_libraries") orelse return;
    const libraries_dep = b.dependencyFromBuildZig(libraries_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MFWithOptions(b.path("module.R4MF"), .{
        .zig_module_roots = &.{libraries_dep.namedLazyPath("r4std_zig_binding"), libraries_dep.namedLazyPath("r4img_zig_binding")},
    });

    const model_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/model.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_model_tests = b.addRunArtifact(model_tests);
    const test_step = b.step("test", "Run Appearance model tests");
    test_step.dependOn(&run_model_tests.step);
}

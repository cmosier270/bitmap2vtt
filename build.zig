const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "dvdsub-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.linkLibC();
    const ffmpeg_libs = [_][]const u8{
        "avformat",
        "avcodec",
        "avutil",
        "swresample",
        "swscale",
    };
    for (ffmpeg_libs) |lib| {
        exe.linkSystemLibrary(lib);
    }

    // Link Tesseract OCR library
    exe.linkSystemLibrary("tesseract");
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run dvdsub-tool");
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const unit_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
